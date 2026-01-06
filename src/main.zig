const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const assert = std.debug.assert;
const Stream = @import("./Stream.zig");
const Uring = @import("./Uring.zig");

fn resolve_upstream_addr(allocator: Allocator, name: []const u8, port: u16) !std.net.Address {
    const list = try std.net.getAddressList(allocator, name, port);
    defer list.deinit();
    for (list.addrs) |addr| {
        if (addr.any.family == posix.AF.INET6) continue;
        return addr;
    }

    if (list.addrs.len > 0) return error.Ipv6NotSupported;
    return error.InvalidHostname;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const upstream_addr = try resolve_upstream_addr(allocator, "localhost", 3030);
    try proxy(allocator, upstream_addr, null);
}

fn setup_listener_sock() !i32 {
    const addr: std.net.Address = .{ .in = std.net.Ip4Address.parse("127.0.0.1", 8080) catch unreachable };

    const optval: u32 = 1;
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&optval));
    try posix.bind(sockfd, &addr.any, addr.getOsSockLen());
    try posix.listen(sockfd, 50);

    return sockfd;
}

pub fn proxy(allocator: Allocator, upstream_addr: std.net.Address, running: ?*std.atomic.Value(bool)) !void {
    var uring: Uring = try .init(16);
    const sockfd = try setup_listener_sock();
    var accept_data = try allocator.create(Stream);
    accept_data.init(sockfd, .Accept);
    defer allocator.destroy(accept_data);

    uring.prep_multishot_accept(accept_data);

    while (running == null or running.?.load(.monotonic)) {
        const nflushed = uring.flush_sq();
        _ = try uring.submit_and_wait(nflushed, 1);
        for (0..uring.cq_ready()) |_| {
            const cqe = uring.read().?;
            if (cqe.user_data == 0) @panic("null pointer in user_data");
            const cqe_data: *Stream = @ptrFromInt(cqe.user_data);

            switch (cqe_data.state) {
                .Accept => {
                    const connfd = cqe.res;
                    const bytes: *const [4]u8 = @ptrCast(&accept_data.addr.addr);
                    std.debug.print("Got connection from {d}.{d}.{d}.{d}:{d}\n", .{ bytes[0], bytes[1], bytes[2], bytes[3], accept_data.addr.port });

                    var conn_data = try allocator.create(Stream);
                    conn_data.init(connfd, .Recv);
                    conn_data.addr = accept_data.addr;
                    conn_data.addrlen = accept_data.addrlen;

                    uring.prep_recv(conn_data);
                },
                .Recv => {
                    const nb = cqe.res;
                    if (nb > 0) {
                        const pos = cqe_data.pos;
                        cqe_data.pos += @intCast(nb);
                        std.debug.print("READ {d} bytes from sock {d} : {s}\n", .{ nb, cqe_data.fd, cqe_data.buf[pos..cqe_data.pos] });
                        cqe_data.state = .Send;
                        if (cqe_data.opposing != null) {
                            uring.prep_send(cqe_data);
                        } else {
                            var opposing_socket = try allocator.create(Stream);
                            opposing_socket.init(0, .Socket);
                            opposing_socket.opposing = cqe_data;
                            cqe_data.opposing = opposing_socket;
                            uring.prep_socket(opposing_socket);
                        }
                    } else if (nb == 0) {
                        assert(cqe_data.opposing != null);
                        std.debug.print("Socket closed connection, closing reciprocal socket\n", .{});
                        cqe_data.state = .Close;
                        uring.prep_close(cqe_data.opposing.?);
                    } else {
                        const err: linux.E = @enumFromInt(-nb);
                        std.debug.print("ERROR : {any}\n", .{err});
                        @panic("SHOULD HANDLE ERROR BETTER");
                    }
                },
                .Socket => {
                    std.debug.print("Created socket {d}\n", .{cqe.res});
                    assert(cqe_data.opposing != null);
                    cqe_data.fd = cqe.res;
                    cqe_data.addr = upstream_addr.in.sa;
                    cqe_data.addrlen = upstream_addr.getOsSockLen();
                    assert(cqe.res > 0); // TODO: handle errors
                    uring.prep_connect(cqe_data);
                },
                .Connect => {
                    assert(cqe_data.opposing != null);
                    if (cqe.err() != .SUCCESS) {
                        std.debug.print("Error Connecting to upstream: {any}\n", .{cqe.err()});
                        assert(cqe_data.opposing != null);
                        cqe_data.state = .Close;
                        uring.prep_close(cqe_data.opposing.?);
                    } else {
                        std.debug.print("Connected to upstream on socket {d}: response {d}\n", .{ cqe_data.fd, cqe.res });
                        uring.prep_send(cqe_data.opposing.?);
                    }
                },
                .Send => {
                    if (cqe.err() != .SUCCESS) {
                        std.debug.print("Error sending to sockfd: {any}\n", .{cqe.err()});
                    } else {
                        std.debug.print("SENT {d} bytes to sockfd\n", .{cqe.res});
                        assert(cqe_data.opposing != null);
                        cqe_data.state = .Recv;
                        cqe_data.flush();
                        uring.prep_recv(cqe_data.opposing.?);
                    }
                },
                .Close => {
                    assert(cqe_data.opposing != null);
                    std.debug.print("Connection {d} {d} successfully closed\n", .{ cqe_data.fd, cqe_data.opposing.?.fd });
                    allocator.destroy(cqe_data.opposing.?);
                    allocator.destroy(cqe_data);
                },
            }
        }
    }
}
