const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const net = std.net;
const assert = std.debug.assert;
const proxy = @import("./proxy.zig").proxy;

const MESSAGE_SIZE = 256;

fn get_addr(allocator: Allocator) !net.Address {
    const list = try std.net.getAddressList(allocator, "localhost", 3030);
    defer list.deinit();
    for (list.addrs) |addr| {
        if (addr.any.family == posix.AF.INET6) continue;
        return addr;
    }
    if (list.addrs.len > 0) return error.Ipv6NotSupported;
    return error.InvalidHostname;
}

fn handle_conn(conn: net.Server.Connection) !void {
    errdefer conn.stream.close();

    while (true) {
        var buf: [MESSAGE_SIZE]u8 = undefined;
        const fd = conn.stream.handle;

        const nb = try posix.read(fd, &buf);
        if (nb == 0) break;

        const nw = try conn.stream.write(buf[0..nb]);
        assert(nb == nw);
    }
}

fn spawn_server(addr: std.net.Address, comptime num_incoming: usize) !void {
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    var accepted: usize = 0;

    var ts: [num_incoming]std.Thread = undefined;
    while (accepted < num_incoming) : (accepted += 1) {
        const conn = try server.accept();
        ts[accepted] = try std.Thread.spawn(.{}, handle_conn, .{conn});
    }

    for (ts) |t| {
        t.join();
    }
}

pub fn main() !void {
    var dba = std.heap.DebugAllocator(.{}){};
    defer _ = dba.deinit();
    const allocator = dba.allocator();

    const addr = get_addr(allocator) catch unreachable;

    var proxy_signal = std.atomic.Value(bool).init(true);

    const server_thread = try std.Thread.spawn(.{}, spawn_server, .{ addr, 2 });
    const proxy_thread = try std.Thread.spawn(.{}, proxy, .{ allocator, addr, &proxy_signal });

    server_thread.join();
    std.debug.print("Server finished running, killing proxy\n", .{});
    proxy_signal.store(false, .monotonic);
    proxy_thread.join();
}
