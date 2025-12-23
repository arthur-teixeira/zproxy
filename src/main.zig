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

fn resolve_upstream_addr(allocator: Allocator, name: []const u8, port: u16) !std.net.Ip4Address {
    const list = try std.net.getAddressList(allocator, name, port);
    defer list.deinit();
    for (list.addrs) |addr| {
        if (addr.any.family == posix.AF.INET6) continue;
        return addr.in;
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
            const cqn = uring.read();
            std.debug.assert(cqn != null);
            const cqe = cqn.?;

            if (cqe.user_data == 0) @panic("null pointer in user_data");
            const cqe_data: *Data = @ptrFromInt(cqe.user_data);

            switch (cqe_data.state) {
                .AcceptDown => {
                    const connfd = cqe.res;
                    const bytes: *const [4]u8 = @ptrCast(&accept_data.downstream.addr.addr);
                    std.debug.print("Got connection from {d}.{d}.{d}.{d}:{d}\n", .{ bytes[0], bytes[1], bytes[2], bytes[3], accept_data.downstream.addr.port });

                    var recv_data = try allocator.create(Data);
                    recv_data.init(connfd, .RecvUp);
                    recv_data.downstream.addr = accept_data.downstream.addr;
                    recv_data.downstream.addrlen = accept_data.downstream.addrlen;

                    uring.prep_recv(&recv_data.downstream.buf, recv_data);
                },
                .RecvUp => {
                    const nb = cqe.res;
                    std.debug.print("READ {d} bytes from sock {d} : {s}\n", .{ nb, cqe_data.downstream.fd, cqe_data.downstream.buf[0..@intCast(nb)] });
                    if (nb > 0) {
                        uring.prep_send(cqe_data.downstream.buf[0..@intCast(nb)], cqe_data);
                    } else {
                        uring.prep_close(cqe_data);
                    }
                },
                .SendUp => {
                    std.debug.print("SENT {d} bytes to sockfd, closing connection.\n", .{cqe.res});
                    uring.prep_close(cqe_data);
                },
                .Close => {
                    std.debug.print("Connection to sock {d} successfully closed\n", .{cqe_data.downstream.fd});
                    allocator.destroy(cqe_data);
                },
                else => unreachable,
            }
        }
    }
}

// Downstream => requesting client
// Upstream => destination server(s)
// (Ideal) State sequence
// Accept (downstream) -> Socket(upstream) -> Connect (upstream) -> Send (upstream) -> Recv (upstream) -> Send (downstream) -> Close(upstream)
//                     -> Recv (upstream)                                                                                   -> Close(downstream)
//
// (Current) State sequence
// Accept (downstream) -> Recv (downstream) -> Socket (upstream) -> Connect (upstream) -> Send (upstream) -> Recv (upstream) -> Send (downstream) -> Close(downstream)
//                                                                                                                           -> Close(upstream)
const SqState = enum {
    AcceptDown,
    RecvDown,
    SocketUp,
    ConnectUp,
    SendUp,
    RecvUp,
    SendDown,
    Close,
};

const Data = struct {
    const Stream = struct {
        addr: linux.sockaddr.in,
        addrlen: linux.socklen_t,
        buf: [4096]u8,
        fd: i32,
    };

    state: SqState,
    downstream: Stream,
    upstream: Stream,

    fn init(self: *Data, connfd: i32, state: SqState) void {
        self.state = state;
        self.downstream = .{
            .buf = @splat(0),
            .addr = std.mem.zeroes(linux.sockaddr.in),
            .addrlen = linux.sockaddr.SS_MAXSIZE,
            .fd = connfd,
        };
        self.upstream = undefined;
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
        var sqe = self.get_sqe();
        sqe.prep_close(data.downstream.fd);
        data.state = .Close;
        sqe.user_data = @intFromPtr(data);
    }

    fn prep_recv(self: *Uring, buf: []u8, data: *Data) void {
        var sqe = self.get_sqe();
        sqe.prep_recv(data.downstream.fd, buf, 0);
        data.state = .RecvUp;
        sqe.user_data = @intFromPtr(data);
    }

    fn prep_socket(self: *Uring, data: *Data) void {
        assert(data.state == .AcceptDown);
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
    }

    fn prep_send(self: *Uring, buf: []u8, data: *Data) void {
        var sqe = self.get_sqe();
        sqe.prep_send(data.downstream.fd, buf, 0);
        data.state = .SendUp;
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
