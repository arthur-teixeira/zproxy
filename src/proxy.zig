const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const assert = std.debug.assert;
const Stream = @import("./Stream.zig");
const Uring = @import("./Uring.zig");
const Config = @import("./config.zig");

pub const test_sync = if (builtin.is_test)
    struct {
        pub var cond = std.Thread.Condition{};
        pub var ready = false;
        pub var mutex = std.Thread.Mutex{};
    }
else
    struct {};

fn setup_listener_sock(cfg: Config.Value) !i32 {
    const addr: std.net.Address = .{ .in = std.net.Ip4Address.parse(cfg.proxy.address, cfg.proxy.port) catch unreachable };

    const optval: u32 = 1;
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&optval));
    try posix.bind(sockfd, &addr.any, addr.getOsSockLen());
    try posix.listen(sockfd, 50);

    return sockfd;
}

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

pub fn proxy(allocator: Allocator, config: Config.Value, running: ?*std.atomic.Value(bool)) !void {
    var uring: Uring = try .init(16);
    defer uring.deinit();
    const sockfd = try setup_listener_sock(config);
    defer posix.close(sockfd);

    // TODO: multiple upstream addresses
    assert(config.upstream.len > 0);
    assert(config.upstream[0].port != null);

    std.debug.print("Starting proxy with upstream {s}:{d}\n", .{ config.upstream[0].address, config.upstream[0].port.? });

    const upstream_addr = try resolve_upstream_addr(allocator, config.upstream[0].address, config.upstream[0].port.?);

    var conn_pool = try Stream.Pool.init(allocator, 32);
    defer conn_pool.deinit();

    const accept_key = try conn_pool.reserve();
    var accept_data = conn_pool.get(accept_key);
    accept_data.init(sockfd, .Accept);

    uring.prep_multishot_accept(accept_key, accept_data);

    while (true) {
        const nflushed = uring.flush_sq();
        _ = try uring.submit_and_wait(nflushed, 0);
        if (builtin.is_test and !test_sync.ready) {
            test_sync.mutex.lock();
            test_sync.ready = true;
            test_sync.mutex.unlock();
            test_sync.cond.signal();
        }
        for (0..uring.cq_ready()) |_| {
            const cqe = uring.read().?;
            const cqe_key: Stream.Key = @enumFromInt(cqe.user_data);
            try conn_pool.ensure_free_slots(1);
            accept_data = conn_pool.get(accept_key);
            const cqe_data: *Stream = conn_pool.get(cqe_key);

            switch (cqe_data.state) {
                .Accept => {
                    const connfd = cqe.res;

                    const bytes: *const [4]u8 = @ptrCast(&accept_data.addr.addr);
                    std.debug.print("Got connection {d} from {d}.{d}.{d}.{d}:{d}\n", .{ cqe_data.fd, bytes[0], bytes[1], bytes[2], bytes[3], accept_data.addr.port });

                    const conn_key = try conn_pool.reserve();
                    const conn_data = conn_pool.get(conn_key);
                    conn_data.init(connfd, .Recv);
                    conn_data.addr = accept_data.addr;
                    conn_data.addrlen = accept_data.addrlen;

                    uring.prep_recv(conn_key, conn_data);
                },
                .Recv => {
                    if (cqe.err() != .SUCCESS) {
                        std.debug.print("Error receiving from sockfd {d}: {any}\n", .{ cqe_data.fd, cqe.err() });
                    }

                    const nb = cqe.res;
                    if (nb > 0) {
                        cqe_data.pos += @intCast(nb);
                        std.debug.print("READ {d} bytes from sock {d}\n", .{ nb, cqe_data.fd });
                        cqe_data.state = .Send;
                        if (cqe_data.opposing != null) {
                            assert(cqe_data.opposing.? != cqe_key);
                            uring.prep_send(cqe_key, cqe_data, conn_pool.get(cqe_data.opposing.?));
                        } else {
                            const opposing = try conn_pool.reserve();
                            const opposing_socket = conn_pool.get(opposing);
                            opposing_socket.init(0, .Socket);
                            opposing_socket.opposing = cqe_key;
                            cqe_data.opposing = opposing;
                            uring.prep_socket(opposing, opposing_socket);
                        }
                    } else if (nb == 0) {
                        std.debug.print("Socket closed connection\n", .{});
                        cqe_data.state = .Close;
                        if (cqe_data.opposing) |opp| {
                            std.debug.print("Closing reciprocal socket\n", .{});
                            uring.prep_close(opp, conn_pool.get(opp));
                        }
                    }
                },
                .Socket => {
                    std.debug.print("Created socket {d}\n", .{cqe.res});
                    assert(cqe_data.opposing != null);
                    cqe_data.fd = cqe.res;
                    cqe_data.addr = upstream_addr.in.sa;
                    cqe_data.addrlen = upstream_addr.getOsSockLen();
                    assert(cqe.res > 0); // TODO: handle errors
                    uring.prep_connect(cqe_key, cqe_data);
                },
                .Connect => {
                    assert(cqe_data.opposing != null);
                    const opp_key = cqe_data.opposing.?;
                    assert(opp_key != cqe_key);
                    const opposing = conn_pool.get(opp_key);
                    if (cqe.err() != .SUCCESS) {
                        std.debug.print("Error Connecting to upstream: {any}\n", .{cqe.err()});
                        cqe_data.state = .Close;
                        uring.prep_close(opp_key, opposing);
                    } else {
                        std.debug.print("Connected to upstream on socket {d}: response {d}\n", .{ cqe_data.fd, cqe.res });
                        uring.prep_send(opp_key, opposing, cqe_data);
                    }
                },
                .Send => {
                    if (cqe.err() != .SUCCESS) {
                        std.debug.print("Error sending to sockfd: {any}\n", .{cqe.err()});
                    } else {
                        std.debug.print("SENT {d} bytes to sockfd\n", .{cqe.res});
                        assert(cqe_data.opposing != null);
                        assert(cqe_data.opposing.? != cqe_key);
                        cqe_data.state = .Recv;
                        cqe_data.clear();
                        const opp_key = cqe_data.opposing.?;
                        uring.prep_recv(opp_key, conn_pool.get(opp_key));
                    }
                },
                .Close => {
                    std.debug.print("Connection {d} successfully closed\n", .{cqe_data.fd});
                    conn_pool.release(cqe_data.opposing.?);
                    conn_pool.release(cqe_key);
                },
                .Cancel => {
                    std.debug.print("Ring cancelled and all operations processed\n", .{});
                    return;
                },
            }
        }

        if (running) |v| {
            if (!v.load(.monotonic) and accept_data.state != .Cancel) {
                std.debug.print("Got an interrupt signal, cancelling the ring\n", .{});
                accept_data.state = .Cancel;
                try uring.prep_cancel(accept_key);
            }
        }
    }
}
