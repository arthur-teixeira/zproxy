const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const assert = std.debug.assert;
const Stream = @import("./Stream.zig");
const Uring = @import("./Uring.zig");
const Config = @import("./config.zig");
const UpstreamManager = @import("./upstreams.zig");

pub const test_sync = if (builtin.is_test)
    struct {
        pub var cond = std.Thread.Condition{};
        pub var ready = false;
        pub var mutex = std.Thread.Mutex{};
    }
else
    struct {};

fn setup_listener_sock(cfg: Config.Value) !i32 {
    const addr: std.net.Address = try std.net.Address.resolveIp(cfg.proxy.address, cfg.proxy.port);

    var optval: u32 = 1;
    const sockfd = try posix.socket(addr.any.family, posix.SOCK.STREAM, 0);
    if (addr.any.family == posix.AF.INET6) {
        try posix.setsockopt(sockfd, posix.IPPROTO.IPV6, linux.IPV6.V6ONLY, std.mem.asBytes(&optval));
    }
    try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&optval));
    optval = 0;
    try posix.bind(sockfd, &addr.any, addr.getOsSockLen());
    try posix.listen(sockfd, 1024);

    return sockfd;
}

pub fn proxy(allocator: Allocator, config: Config.Value, running: ?*std.atomic.Value(bool)) !void {
    var uring: Uring = try .init(256, config.proxy.timeout.?);
    defer uring.deinit();
    const sockfd = try setup_listener_sock(config);
    defer posix.close(sockfd);

    var upstream_manager: UpstreamManager = try .init(allocator, config);

    var conn_pool = try Stream.Pool.init(allocator, 4096);
    defer conn_pool.deinit();

    const accept_key = try conn_pool.reserve();
    var accept_data = conn_pool.get(accept_key).?;
    try accept_data.init(sockfd, .Accept);

    uring.prep_multishot_accept(accept_key, accept_data);

    while (true) {
        const nflushed = uring.flush_sq();
        _ = try uring.submit_and_wait(nflushed, 1);
        if (builtin.is_test and !test_sync.ready) {
            test_sync.mutex.lock();
            test_sync.ready = true;
            test_sync.mutex.unlock();
            test_sync.cond.signal();
        }
        for (0..uring.cq_ready()) |_| {
            const cqe = uring.read().?;
            const completion = Uring.unpack_user_data(cqe.user_data);
            const cqe_key = completion.key;
            try conn_pool.ensure_free_slots(1);
            accept_data = conn_pool.get(accept_key).?;
            const cqe_ptr = conn_pool.get(cqe_key);
            if (cqe_ptr == null) {
                continue;
            }
            const cqe_data = cqe_ptr.?;

            switch (completion.op) {
                .Accept => {
                    if (cqe.err() != .SUCCESS) {
                        continue;
                    }
                    const connfd = cqe.res;
                    const conn_key = try conn_pool.reserve();
                    const conn_data = conn_pool.get(conn_key).?;
                    try conn_data.init(connfd, .Read);
                    conn_data.addr = accept_data.addr;
                    conn_data.addrlen = accept_data.addrlen;

                    const opposing = try conn_pool.reserve();
                    const opposing_socket = conn_pool.get(opposing).?;
                    try opposing_socket.init(0, .Socket);

                    const upstream_addr = upstream_manager.select_upstream();
                    opposing_socket.set_upstream(upstream_addr);

                    opposing_socket.opposing = cqe_key;
                    conn_data.opposing = opposing;
                    opposing_socket.opposing = conn_key;

                    uring.prep_socket(opposing, opposing_socket);
                },
                .Socket => {
                    if (cqe.err() != .SUCCESS) {
                        continue;
                    }

                    assert(cqe_data.opposing != null);
                    cqe_data.fd = cqe.res;
                    uring.prep_connect(cqe_key, cqe_data);
                },
                .Shutdown => {
                    uring.prep_close(cqe_key, cqe_data);
                },
                .Connect => {
                    assert(cqe_data.opposing != null);
                    const opp_key = cqe_data.opposing.?;
                    assert(opp_key != cqe_key);
                    const opposing = conn_pool.get(opp_key).?;

                    if (cqe.err() != .SUCCESS) {
                        std.debug.print("Could not connect to {any}\n", .{cqe_data.upstream_key});
                        upstream_manager.report_health(cqe_data.upstream_key.?, false);
                        const upstream_addr = upstream_manager.select_upstream();
                        cqe_data.set_upstream(upstream_addr);
                        uring.prep_connect(cqe_key, cqe_data);
                        continue;
                    }

                    std.debug.print("Connected successfully to {any}\n", .{cqe_data.upstream_key});
                    upstream_manager.report_health(cqe_data.upstream_key.?, true);

                    cqe_data.state = .Read;
                    uring.prep_splice_read(cqe_key, cqe_data);

                    opposing.state = .Read;
                    uring.prep_splice_read(opp_key, opposing);
                },
                .Read => {
                    if (cqe_data.state == .Shutdown or cqe_data.state == .Close) {
                        continue;
                    }
                    if (cqe.err() != .SUCCESS) {
                        uring.prep_shutdown(cqe_key, cqe_data);
                        continue;
                    }
                    const opp_key = cqe_data.opposing.?;
                    assert(opp_key != cqe_key);
                    const opposing = conn_pool.get(opp_key).?;

                    if (cqe.res == 0) {
                        uring.prep_shutdown(cqe_key, cqe_data);
                        uring.prep_shutdown(opp_key, opposing);
                        continue;
                    }

                    uring.prep_splice_write(cqe_key, cqe_data, opposing);
                },
                .Write => {
                    if (cqe_data.state == .Shutdown or cqe_data.state == .Close) {
                        continue;
                    }
                    if (cqe.err() != .SUCCESS) {
                        uring.prep_shutdown(cqe_key, cqe_data);
                        continue;
                    }
                    uring.prep_splice_read(cqe_key, cqe_data);
                },
                .Timeout => {
                    const timed_out = cqe.err() == .TIME;
                    if (!timed_out) {
                        continue;
                    }

                    const opp_key = cqe_data.opposing.?;
                    assert(opp_key != cqe_key);
                    if (conn_pool.get(opp_key)) |opposing| {
                        uring.prep_shutdown(opp_key, opposing);
                    }

                    uring.prep_shutdown(cqe_key, cqe_data);
                },
                .Close => {
                    conn_pool.release(cqe_key);
                },
                .Cancel => {
                    return;
                },
            }
        }

        if (running) |v| {
            if (!v.load(.monotonic) and accept_data.state != .Cancel) {
                accept_data.state = .Cancel;
                try uring.prep_cancel(accept_key);
            }
        }
    }
}
