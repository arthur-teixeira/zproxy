const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const assert = std.debug.assert;

fn setup_listener_sock() !i32 {
    const addr: std.net.Address = .{ .in = std.net.Ip4Address.parse("127.0.0.1", 8080) catch unreachable };

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const upstream_addr = try resolve_upstream_addr(allocator, "localhost", 3030);
    std.debug.print("Upstream is {any}\n", .{upstream_addr});

    var uring: Uring = try .init(16);

    const sockfd = try setup_listener_sock();
    var accept_data = try allocator.create(Data);
    accept_data.init(sockfd, .AcceptDown);
    defer allocator.destroy(accept_data);

    uring.prep_multishot_accept(sockfd, @ptrCast(&accept_data.downstream.addr), &accept_data.downstream.addrlen, accept_data);

    while (true) {
        const nflushed = uring.flush_sq();
        _ = try uring.submit_and_wait(nflushed, 1);
        for (0..uring.cq_ready()) |_| {
            const cqe = uring.read().?;

            if (cqe.user_data == 0) @panic("null pointer in user_data");
            const cqe_data: *Data = @ptrFromInt(cqe.user_data);

            switch (cqe_data.state) {
                .AcceptDown => {
                    const connfd = cqe.res;
                    const bytes: *const [4]u8 = @ptrCast(&accept_data.downstream.addr.addr);
                    std.debug.print("Got connection from {d}.{d}.{d}.{d}:{d}\n", .{ bytes[0], bytes[1], bytes[2], bytes[3], accept_data.downstream.addr.port });

                    var conn_data = try allocator.create(Data);
                    conn_data.init(connfd, .RecvDown);
                    conn_data.downstream.addr = accept_data.downstream.addr;
                    conn_data.downstream.addrlen = accept_data.downstream.addrlen;

                    assert(upstream_addr.any.family == linux.AF.INET);
                    conn_data.upstream.addr = upstream_addr.in.sa;
                    conn_data.upstream.addrlen = upstream_addr.getOsSockLen();

                    uring.prep_recv(conn_data);
                },
                .RecvUp => {
                    const nb = cqe.res;
                    if (nb > 0) {
                        std.debug.print("READ {d} bytes from upstream sock {d} : {s}\n", .{ nb, cqe_data.upstream.fd, cqe_data.upstream.buf[0..@intCast(nb)] });
                        cqe_data.upstream.pos += @intCast(nb);
                        cqe_data.state = .SendDown;
                        uring.prep_send(cqe_data);
                    } else if (nb == 0) {
                        std.debug.print("Upstream closed connection, closing reciprocal downstream socket\n", .{});
                        cqe_data.state = .CloseDown;
                        uring.prep_close(cqe_data);
                    } else {
                        const err: linux.E = @enumFromInt(-nb);
                        std.debug.print("ERROR : {any}\n", .{err});
                        @panic("SHOULD HANDLE ERROR BETTER");
                    }
                },
                .RecvDown => {
                    const nb = cqe.res;
                    if (nb > 0) {
                        std.debug.print("READ {d} bytes from downstream sock {d} : {s}\n", .{ nb, cqe_data.downstream.fd, cqe_data.downstream.buf[0..@intCast(nb)] });
                        cqe_data.downstream.pos += @intCast(nb);
                        //TODO: concurrently start `uring.prep_recv(cqe_data)`
                        //TODO: create upstream socket as soon as downstream is accepted
                        if (cqe_data.upstream.fd > 0) {
                            cqe_data.state = .SendUp;
                            uring.prep_send(cqe_data);
                        } else {
                            uring.prep_socket(cqe_data);
                        }
                    } else if (nb == 0) {
                        std.debug.print("Downstream closed connection, closing reciprocal upstream socket\n", .{});
                        cqe_data.state = .CloseUp;
                        uring.prep_close(cqe_data);
                    } else {
                        const err: linux.E = @enumFromInt(-nb);
                        std.debug.print("ERROR : {any}\n", .{err});
                        @panic("SHOULD HANDLE ERROR BETTER");
                    }
                },
                .SocketUp => {
                    std.debug.print("Created upstream socket {d}\n", .{cqe.res});
                    assert(cqe.res > 0); // TODO: handle errors
                    cqe_data.init_upstream(cqe.res);
                    uring.prep_connect(cqe_data);
                },
                .ConnectUp => {
                    std.debug.print("Connected to upstream on socket {d}: response {d}\n", .{ cqe_data.upstream.fd, cqe.res });
                    // FIXME: This will possible be false when we start socket + recv concurrently if we connect before we recv from downstream
                    assert(cqe_data.downstream.pos > 0);
                    cqe_data.state = .SendUp;
                    uring.prep_send(cqe_data);
                },
                .SendUp => {
                    std.debug.print("SENT {d} bytes to UPSTREAM sockfd {d}.\n", .{ cqe.res, cqe_data.upstream.fd });
                    cqe_data.flush_downstream();
                    cqe_data.state = .RecvUp;
                    uring.prep_recv(cqe_data);
                },
                .SendDown => {
                    std.debug.print("SENT {d} bytes to DOWNSTREAM sockfd\n", .{cqe.res});
                    cqe_data.state = .RecvDown;
                    cqe_data.flush_upstream();
                    uring.prep_recv(cqe_data);
                },
                .CloseUp, .CloseDown => {
                    std.debug.print("Connection {d} {d} successfully closed\n", .{ cqe_data.downstream.fd, cqe_data.upstream.fd });
                    allocator.destroy(cqe_data);
                },
            }
        }
    }
}

// Downstream => requesting client
// Upstream => destination server(s)
// (Ideal) State sequence
// Accept (downstream) -> Socket(upstream) -> Connect (upstream) -> Send (upstream) -> Recv (upstream) -> Send (downstream)
//                     -> Recv (downstream)
//
// (Current) State sequence
// Accept (downstream) -> Recv (downstream) -> Socket (upstream) -> Connect (upstream) -> Send (upstream) -> Recv (upstream) -> Send (downstream)
//                               | ^
//                               |_|
const SqState = enum { AcceptDown, RecvDown, SocketUp, ConnectUp, SendUp, RecvUp, SendDown, CloseUp, CloseDown };

const Data = struct {
    const Stream = struct {
        addr: linux.sockaddr.in,
        addrlen: linux.socklen_t,
        buf: [4096]u8,
        pos: u32,
        fd: i32,
    };

    state: SqState,
    downstream: Stream,
    upstream: Stream,

    fn init(self: *Data, connfd: i32, state: SqState) void {
        self.state = state;
        self.downstream = .{
            .pos = 0,
            .buf = @splat(0),
            .addr = std.mem.zeroes(linux.sockaddr.in),
            .addrlen = linux.sockaddr.SS_MAXSIZE,
            .fd = connfd,
        };
        self.upstream = .{
            .pos = 0,
            .buf = @splat(0),
            .addr = std.mem.zeroes(linux.sockaddr.in),
            .addrlen = linux.sockaddr.SS_MAXSIZE,
            .fd = 0,
        };
    }

    fn init_upstream(self: *Data, connfd: i32) void {
        self.flush_upstream();
        self.upstream.fd = connfd;
    }

    fn flush_upstream(self: *Data) void {
        self.upstream.pos = 0;
        self.upstream.buf = @splat(0);
    }

    fn flush_downstream(self: *Data) void {
        self.downstream.pos = 0;
        self.downstream.buf = @splat(0);
    }
};

const Uring = struct {
    fd: i32,
    sq: Sq,
    cq: Cq,

    const Sq = struct {
        sq_tail: u32,
        sq_head: u32,
        off: u64,
        head: *u32,
        tail: *u32,
        mask: *u32,
        array: [*]u32,
        sqes: [*]linux.io_uring_sqe,
    };
    const Cq = struct {
        head: *u32,
        tail: *u32,
        mask: *u32,
        cqes: [*]linux.io_uring_cqe,
    };

    fn init(size: u32) !Uring {
        var params: linux.io_uring_params = std.mem.zeroes(linux.io_uring_params);
        const ring_fd = linux.io_uring_setup(size, &params);
        switch (linux.E.init(ring_fd)) {
            .SUCCESS => {},
            .FAULT => return error.ParamsOutsideAccessibleAddressSpace,
            .INVAL => return error.ArgumentsInvalid,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .PERM => return error.PermissionDenied,
            .NOSYS => return error.SystemOutdated,
            else => |errno| return posix.unexpectedErrno(errno),
        }

        var sq_ring_size = params.sq_off.array + params.sq_entries * @sizeOf(c_uint);
        var cq_ring_size = params.cq_off.cqes + params.cq_entries * @sizeOf(linux.io_uring_cqe);

        if (params.features & linux.IORING_FEAT_SINGLE_MMAP > 0) {
            if (cq_ring_size > sq_ring_size) {
                sq_ring_size = cq_ring_size;
            }
            cq_ring_size = sq_ring_size;
        }

        const sq_int = linux.mmap(
            null,
            sq_ring_size,
            linux.PROT.READ | linux.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            @intCast(ring_fd),
            linux.IORING_OFF_SQ_RING,
        );
        switch (linux.E.init(sq_int)) {
            .SUCCESS => {},
            else => |err| perror(err, "mmap", .{}),
        }

        const sq_ptr: *anyopaque = @ptrFromInt(sq_int);

        var cq_ptr: *anyopaque = sq_ptr;
        var cq_int: u64 = @intFromPtr(cq_ptr);
        if (params.features & linux.IORING_FEAT_SINGLE_MMAP == 0) {
            cq_int = linux.mmap(
                null,
                cq_ring_size,
                linux.PROT.READ | linux.PROT.WRITE,
                .{ .TYPE = .SHARED, .POPULATE = true },
                @intCast(ring_fd),
                linux.IORING_OFF_CQ_RING,
            );
            switch (linux.E.init(cq_int)) {
                .SUCCESS => {},
                else => |err| perror(err, "mmap", .{}),
            }
            cq_ptr = @ptrFromInt(cq_int);
        }

        const sring_head: *u32 = @ptrFromInt(cq_int + @as(u64, params.sq_off.head));
        const sring_tail: *u32 = @ptrFromInt(sq_int + @as(u64, params.sq_off.tail));
        const sring_mask: *u32 = @ptrFromInt(sq_int + @as(u64, params.sq_off.ring_mask));
        const sring_array: [*]u32 = @ptrFromInt(sq_int + @as(u64, params.sq_off.array));

        const sqes_int = linux.mmap(
            null,
            params.sq_entries * @sizeOf(linux.io_uring_sqe),
            linux.PROT.READ | linux.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            @intCast(ring_fd),
            linux.IORING_OFF_SQES,
        );
        switch (linux.E.init(sqes_int)) {
            .SUCCESS => {},
            else => |err| perror(err, "mmap", .{}),
        }

        const sqes: [*]linux.io_uring_sqe = @ptrFromInt(sqes_int);

        const cring_head: *u32 = @ptrFromInt(cq_int + @as(u64, params.cq_off.head));
        const cring_tail: *u32 = @ptrFromInt(cq_int + @as(u64, params.cq_off.tail));
        const cring_mask: *u32 = @ptrFromInt(cq_int + @as(u64, params.cq_off.ring_mask));

        const cqes: [*]linux.io_uring_cqe = @ptrFromInt(cq_int + @as(u64, params.cq_off.cqes));

        return .{
            .fd = @intCast(ring_fd),
            .cq = .{
                .head = cring_head,
                .tail = cring_tail,
                .mask = cring_mask,
                .cqes = cqes,
            },
            .sq = .{
                .sq_tail = 0,
                .sq_head = 0,
                .off = 0,
                .head = sring_head,
                .tail = sring_tail,
                .mask = sring_mask,
                .array = sring_array,
                .sqes = sqes,
            },
        };
    }

    inline fn get_sqe(self: *Uring) *linux.io_uring_sqe {
        const next = self.sq.sq_tail +% 1;
        const sqe = &self.sq.sqes[self.sq.sq_tail & self.sq.mask.*];
        self.sq.sq_tail = next;
        return sqe;
    }

    fn prep_multishot_accept(self: *Uring, fd: i32, addr: ?*posix.sockaddr, addrlen: ?*posix.socklen_t, data: *Data) void {
        var sqe = self.get_sqe();
        data.state = .AcceptDown;
        sqe.prep_multishot_accept(fd, addr, addrlen, 0);
        sqe.user_data = @intFromPtr(data);
    }

    fn prep_close(self: *Uring, data: *Data) void {
        assert(data.state == .CloseDown or data.state == .CloseUp);
        var sqe = self.get_sqe();
        const fd = if (data.state == .CloseUp) data.upstream.fd else data.downstream.fd;
        sqe.prep_close(fd);
        sqe.user_data = @intFromPtr(data);
    }

    fn prep_recv(self: *Uring, data: *Data) void {
        assert(data.state == .RecvDown or data.state == .RecvUp);
        var sqe = self.get_sqe();
        const fd = if (data.state == .RecvUp) data.upstream.fd else data.downstream.fd;
        const buf = if (data.state == .RecvUp) &data.upstream.buf else &data.downstream.buf;
        const pos = if (data.state == .RecvUp) data.upstream.pos else data.downstream.pos;
        sqe.prep_recv(fd, buf, pos);
        sqe.user_data = @intFromPtr(data);
    }

    fn prep_socket(self: *Uring, data: *Data) void {
        var sqe = self.get_sqe();
        data.state = .SocketUp;
        sqe.prep_socket(linux.AF.INET, linux.SOCK.STREAM, 0, 0);
        sqe.user_data = @intFromPtr(data);
    }

    fn prep_connect(self: *Uring, data: *Data) void {
        assert(data.state == .SocketUp);
        assert(data.upstream.fd > 0);
        assert(data.upstream.addr.family == linux.AF.INET);

        var sqe = self.get_sqe();
        data.state = .ConnectUp;
        sqe.prep_connect(data.upstream.fd, @ptrCast(&data.upstream.addr), data.upstream.addrlen);
        sqe.user_data = @intFromPtr(data);
    }

    fn prep_send(self: *Uring, data: *Data) void {
        assert(data.state == .SendUp or data.state == .SendDown);
        const fd = if (data.state == .SendUp) data.upstream.fd else data.downstream.fd;
        const buf = if (data.state == .SendUp) data.downstream.buf else data.upstream.buf;
        const pos = if (data.state == .SendUp) data.downstream.pos else data.upstream.pos;

        var sqe = self.get_sqe();
        sqe.prep_send(fd, buf[0..@intCast(pos)], 0);
        sqe.user_data = @intFromPtr(data);
    }

    fn cq_ready(self: *Uring) u32 {
        return @atomicLoad(u32, self.cq.tail, .acquire) -% self.cq.head.*;
    }

    // TODO: Probably better to copy CQEs to a slice and call atomic load/store only once since we know how many CQEs are ready with cq_ready()
    fn read(self: *Uring) ?*linux.io_uring_cqe {
        var head = @atomicLoad(u32, self.cq.head, .acquire);
        if (head == self.cq.tail.*) {
            return null;
        }

        const cqe = &self.cq.cqes[head & self.cq.mask.*];

        head += 1;
        @atomicStore(u32, self.cq.head, head, .release);
        return cqe;
    }

    pub fn flush_sq(self: *Uring) u32 {
        if (self.sq.sq_head != self.sq.sq_tail) {
            const to_submit = self.sq.sq_tail -% self.sq.sq_head;
            var tail = self.sq.tail.*;
            var i: usize = 0;
            while (i < to_submit) : (i += 1) {
                self.sq.array[tail & self.sq.mask.*] = self.sq.sq_head & self.sq.mask.*;
                tail +%= 1;
                self.sq.sq_head +%= 1;
            }
            @atomicStore(u32, self.sq.tail, tail, .release);
        }

        return self.sq_ready();
    }

    pub fn sq_ready(self: Uring) u32 {
        return self.sq.sq_tail -% @atomicLoad(u32, self.sq.head, .acquire);
    }

    fn submit_and_wait(self: *Uring, num_submit: u32, num_wait: u32) !usize {
        const res = linux.io_uring_enter(self.fd, num_submit, num_wait, linux.IORING_ENTER_GETEVENTS, null);
        switch (linux.E.init(res)) {
            .SUCCESS => {},
            .AGAIN => return error.SystemResources,
            .BADF => return error.FileDescriptorInvalid,
            .BADFD => return error.FileDescriptorInBadState,
            .BUSY => return error.CompletionQueueOvercommitted,
            .INVAL => return error.SubmissionQueueEntryInvalid,
            .FAULT => return error.BufferInvalid,
            .NXIO => return error.RingShuttingDown,
            .OPNOTSUPP => return error.OpcodeNotSupported,
            .INTR => return error.SignalInterrupt,
            else => |errno| return posix.unexpectedErrno(errno),
        }
        return @as(u32, @intCast(res));
    }
};

pub fn perror(e: linux.E, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.debug.print(": {any}\n", .{e});
    linux.exit(1);
}
