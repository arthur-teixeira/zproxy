const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const net = std.net;
const assert = std.debug.assert;
const p = @import("./proxy.zig");
const proxy = p.proxy;
const opts = @import("build_options");

const MESSAGE_SIZE = 40960;
const PROXY_ADDR: std.net.Address = .{ .in = std.net.Ip4Address.parse("127.0.0.1", 8080) catch unreachable };

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
    defer conn.stream.close();

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
        const conn = server.accept() catch |err| {
            std.debug.print("Error accepting connection: {any}\n", .{err});
            continue;
        };
        ts[accepted] = std.Thread.spawn(.{}, handle_conn, .{conn}) catch |err| {
            std.debug.print("Error spawning connection thread: {any}\n", .{err});
            continue;
        };
    }

    for (ts) |t| {
        t.join();
    }
}

const Test = struct {
    allocator: Allocator,
    server_thread: std.Thread,
    server_addr: std.net.Address,
    proxy_thread: std.Thread,
    proxy_signal: std.atomic.Value(bool),

    const Client = struct {
        req: []const u8,
        res: []const u8,
        scratch: [40960]u8,
        sock: std.net.Stream,

        fn init(req: []const u8, res: []const u8) Client {
            return .{
                .req = req,
                .res = res,
                .scratch = @splat(0),
                .sock = undefined,
            };
        }

        fn run(self: *Client, addr: std.net.Address) !void {
            self.sock = try std.net.tcpConnectToAddress(addr);
            var wtr = self.sock.writer(&self.scratch);
            const nb = try wtr.interface.write(self.req);
            if (nb != self.req.len) {
                std.debug.print("Could not write buffer\n", .{});
                return error.IncompleteWrite;
            }
            try wtr.interface.flush();
        }

        fn get_response(self: *Client) !void {
            self.scratch = @splat(0);
            var rdr = self.sock.reader(&self.scratch);
            const res = try rdr.interface().peek(self.res.len);
            if (!std.mem.eql(u8, res, self.res)) {
                std.debug.print("Got wrong response: expected \"{s}\", got \"{s}\"\n", .{ self.res, res });
                return error.InvalidResponse;
            }
            self.sock.close();
        }
    };

    fn init(allocator: Allocator, server_addr: std.net.Address) Test {
        return .{
            .allocator = allocator,
            .proxy_signal = .init(true),
            .server_addr = server_addr,
            .server_thread = undefined,
            .proxy_thread = undefined,
        };
    }

    fn start(self: *Test, comptime num_clients: usize) !void {
        self.server_thread = try std.Thread.spawn(.{}, spawn_server, .{ self.server_addr, num_clients });
        self.proxy_thread = try std.Thread.spawn(.{}, proxy, .{ self.allocator, self.server_addr, &self.proxy_signal });
        self.wait_proxy();
    }

    fn wait_proxy(_: Test) void {
        p.test_sync.mutex.lock();
        defer p.test_sync.mutex.unlock();
        while (!p.test_sync.ready) {
            p.test_sync.cond.wait(&p.test_sync.mutex);
        }
    }

    fn wait_completion(self: *Test) void {
        self.server_thread.join();
        self.proxy_signal.store(false, .monotonic);
        self.proxy_thread.join();
        p.test_sync.mutex.lock();
        p.test_sync.ready = false;
        p.test_sync.mutex.unlock();
    }
};

pub fn main() !void {
    var dba = std.heap.DebugAllocator(.{}){};
    defer _ = dba.deinit();
    const allocator = dba.allocator();

    try test_concurrent(allocator);
    try test_serial(allocator);
    try test_connection_pool_exhaustion(allocator);
    try test_large_messages(allocator);
    _ = dba.detectLeaks();
}

fn run_client(client: *Test.Client) !void {
    try client.run(PROXY_ADDR);
    try client.get_response();
}

fn test_concurrent(allocator: Allocator) !void {
    const addr = get_addr(allocator) catch unreachable;

    const num_clients: usize = 10;
    var test_case: Test = .init(allocator, addr);
    try test_case.start(num_clients);

    var clients: [num_clients]Test.Client = undefined;
    var threads: [num_clients]std.Thread = undefined;

    for (0..num_clients) |i| {
        const msg = try std.fmt.allocPrint(allocator, "client-{d}", .{i});
        clients[i] = .init(msg, msg);
        threads[i] = try std.Thread.spawn(.{}, run_client, .{&clients[i]});
    }

    for (threads) |t| t.join();
    for (clients) |c| allocator.free(c.req);

    test_case.wait_completion();
}

fn test_serial(allocator: Allocator) !void {
    const addr = get_addr(allocator) catch unreachable;

    const num_clients: usize = 10;
    var test_case: Test = .init(allocator, addr);
    try test_case.start(num_clients);

    for (0..num_clients) |i| {
        const msg = try std.fmt.allocPrint(allocator, "client-{d}", .{i});
        var c: Test.Client = .init(msg, msg);
        try c.run(PROXY_ADDR);
        try c.get_response();
        allocator.free(c.req);
    }

    test_case.wait_completion();
}

fn test_connection_pool_exhaustion(allocator: Allocator) !void {
    const addr = get_addr(allocator) catch unreachable;

    const num_clients: usize = 5000;
    var test_case: Test = .init(allocator, addr);
    try test_case.start(num_clients);

    for (0..num_clients) |i| {
        const msg = try std.fmt.allocPrint(allocator, "client-{d}", .{i});
        var c: Test.Client = .init(msg, msg);
        try c.run(PROXY_ADDR);
        try c.get_response();
        allocator.free(msg);
    }

    test_case.wait_completion();
}

fn generate_msg(allocator: Allocator, size: usize) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    const buf = try allocator.alloc(u8, size);
    rand.bytes(buf);
    return buf;
}

fn test_large_messages(allocator: Allocator) !void {
    const addr = get_addr(allocator) catch unreachable;

    const num_clients: usize = 128;
    var test_case: Test = .init(allocator, addr);
    try test_case.start(num_clients);

    for (0..num_clients) |_| {
        const msg = try generate_msg(allocator, 40960);
        var c: Test.Client = .init(msg, msg);
        try c.run(PROXY_ADDR);
        try c.get_response();
        allocator.free(c.req);
    }

    test_case.wait_completion();
}
