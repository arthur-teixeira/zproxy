const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;

fn setup_listener_sock() !i32 {
    const addr: std.net.Address = .{ .in = std.net.Ip4Address.parse("127.0.0.1", 8080) catch unreachable };

    const optval: u32 = 1;
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&optval));
    try posix.bind(sockfd, &addr.any, addr.getOsSockLen());
    try posix.listen(sockfd, 50);

    return sockfd;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var uring: Uring = .init(16);

    const sockfd = try setup_listener_sock();
    var accept_data = try allocator.create(Data);
    accept_data.init(sockfd, .Accept);
    defer allocator.destroy(accept_data);

    var accept_sqe = uring.prep_accept(sockfd, @ptrCast(&accept_data.addr), &accept_data.addrlen);
    accept_sqe.user_data = @intFromPtr(accept_data);

    while (true) {
        const nevents = uring.wait(1, 1);
        if (nevents == 0) {
            std.debug.print("Zero events\n", .{});
            continue;
        }

        const cqe = try uring.read();
        const cqe_data: *Data = @ptrFromInt(cqe.user_data);

        switch (cqe_data.data_type) {
            .Accept => {
                const connfd = cqe.res;
                const bytes: *const [4]u8 = @ptrCast(&accept_data.addr.addr);
                std.debug.print("Got connection from {d}.{d}.{d}.{d}:{d}\n", .{ bytes[0], bytes[1], bytes[2], bytes[3], accept_data.addr.port });

                var recv_data = try allocator.create(Data);
                recv_data.init(connfd, .Recv);
                recv_data.addr = accept_data.addr;

                var recv_sqe = uring.prep_recv(connfd, &recv_data.buf);
                recv_sqe.user_data = @intFromPtr(recv_data);

                accept_sqe = uring.prep_accept(sockfd, @ptrCast(&accept_data.addr), &accept_data.addrlen);
                accept_sqe.user_data = @intFromPtr(accept_data);
            },
            .Recv => {
                const nb = cqe.res;
                std.debug.print("READ {d} bytes from conn: {s}", .{ nb, cqe_data.buf[0..@intCast(nb)] });
                posix.close(cqe_data.connfd);
                allocator.destroy(cqe_data);

                // uring.prep_send(cqe., read_buf[0..@intCast(cqe_res.res)]);
                // _ = uring.wait(1, 1);
                // const written = try uring.read();
                // std.debug.assert(cqe_res.res == written.res);
            },
        }
    }

    // Create TCP socket
    // submit ACCEPT
    // for each accepted connection, submit READ
    // for each READ, submit WRITE to downstream
    // submit downstream READ, WRITE to upstream
}

const SqType = enum {
    Accept,
    Recv,
};

const Data = struct {
    addr: linux.sockaddr.in,
    addrlen: linux.socklen_t,
    data_type: SqType,
    buf: [4096]u8,
    connfd: i32,

    fn init(self: *Data, connfd: i32, data_type: SqType) void {
        self.buf = @splat(0);
        self.addr = std.mem.zeroes(linux.sockaddr.in);
        self.addrlen = linux.sockaddr.SS_MAXSIZE;
        self.connfd = connfd;
        self.data_type = data_type;
    }
};

const Uring = struct {
    fd: i32,
    sq: Sq,
    cq: Cq,

    const Sq = struct {
        off: u64,
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

    fn init(size: u32) Uring {
        var params: linux.io_uring_params = std.mem.zeroes(linux.io_uring_params);
        const ring_fd = linux.io_uring_setup(size, &params);
        switch (linux.E.init(ring_fd)) {
            .SUCCESS => {},
            else => |err| perror(err, "io_uring_setup", .{}),
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
                .off = 0,
                .tail = sring_tail,
                .mask = sring_mask,
                .array = sring_array,
                .sqes = sqes,
            },
        };
    }

    inline fn get_sqe(self: *Uring) *linux.io_uring_sqe {
        const tail = self.sq.tail.*;
        const index = tail & self.sq.mask.*;
        return &self.sq.sqes[index];
    }

    inline fn release_sqe(self: *Uring) void {
        const tail = self.sq.tail.*;
        const index = tail & self.sq.mask.*;
        self.sq.array[index] = index;
        @atomicStore(u32, self.sq.tail, tail + 1, .release);
    }

    fn prep_accept(self: *Uring, fd: i32, addr: ?*posix.sockaddr, addrlen: ?*posix.socklen_t) *linux.io_uring_sqe {
        var sqe = self.get_sqe();
        defer self.release_sqe();
        sqe.prep_accept(fd, addr, addrlen, 0);
        return sqe;
    }

    fn prep_recv(self: *Uring, fd: i32, buf: []u8) *linux.io_uring_sqe {
        var sqe = self.get_sqe();
        defer self.release_sqe();
        sqe.prep_recv(fd, buf, 0);
        return sqe;

        // TODO: multishot with zero copy
        // sqe.ioprio |= linux.IORING_RECV_MULTISHOT;
        // sqe.prep_rw(.RECV_ZC, fd, @intFromPtr(buf.ptr), buf.len, 0);
        // sqe->zcrx_ifq_idx = zcrx_id;
    }

    fn prep_send(self: *Uring, fd: i32, buf: []u8) *linux.io_uring_sqe {
        var sqe = self.get_sqe();
        defer self.release_sqe();
        sqe.prep_send(fd, buf, 0);

        return sqe;
    }

    fn read(self: *Uring) !*linux.io_uring_cqe {
        var head = @atomicLoad(u32, self.cq.head, .acquire);
        if (head == self.cq.tail.*) {
            return error.EmptyCqRing;
        }
        const cqe = &self.cq.cqes[head & self.cq.mask.*];
        const err = cqe.err();
        // TODO: Improve error handling and return enum
        if (err != .SUCCESS) {
            perror(err, "cqe_read", .{});
        }

        head += 1;
        @atomicStore(u32, self.cq.head, head, .release);
        return cqe;
    }

    fn wait(self: *Uring, num_submit: u32, num_wait: u32) usize {
        const ret = linux.io_uring_enter(self.fd, num_submit, num_wait, linux.IORING_ENTER_GETEVENTS, null);
        // TODO: Improve error handling and return error enum
        switch (linux.E.init(ret)) {
            .SUCCESS => return ret,
            else => |err| perror(err, "io_uring_enter", .{}),
        }
    }
};

pub fn perror(e: linux.E, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.debug.print(": {any}\n", .{e});
    linux.exit(1);
}
