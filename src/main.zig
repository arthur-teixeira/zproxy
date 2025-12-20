const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;

pub fn main() !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // const allocator = gpa.allocator();
    // defer _ = gpa.deinit();

    // const uring: Uring = .init(16);
    const addr: std.net.Address = .{ .in = std.net.Ip4Address.parse("127.0.0.1", 8080) catch unreachable };

    const optval: u32 = 1;
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    try posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&optval));
    try posix.bind(sockfd, &addr.any, addr.getOsSockLen());
    try posix.listen(sockfd, 50);

    while (true) {
        var remoteaddr: posix.sockaddr.in = undefined;
        var addrlen: posix.socklen_t = posix.sockaddr.SS_MAXSIZE;
        const connfd = try posix.accept(sockfd, @ptrCast(&remoteaddr), &addrlen, 0);
        defer posix.close(connfd);
        const bytes: *const [4]u8 = @ptrCast(&remoteaddr.addr);
        std.debug.print("Got connection from {d}.{d}.{d}.{d}:{d} at sock {d}\n", .{ bytes[0], bytes[1], bytes[2], bytes[3], remoteaddr.port, connfd });

        var read_buf: [4096]u8 = undefined;
        const nb = try posix.read(connfd, &read_buf);
        std.debug.print("READ from conn: {s}", .{read_buf[0..nb]});
    }

    // Create TCP socket
    // submit ACCEPT
    // for each accepted connection, submit READ
    // for each READ, submit WRITE to downstream
    // submit downstream READ, WRITE to upstream
}

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
            else => perror(ring_fd, "io_uring_setup", .{}),
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
            else => perror(sq_int, "mmap", .{}),
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
                else => perror(cq_int, "mmap", .{}),
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
            else => perror(sqes_int, "mmap", .{}),
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

    fn submit(self: *Uring, fd: i32, op: linux.IORING_OP) void {
        var tail = self.sq.tail.*;
        const index = tail & self.sq.mask.*;
        var sqe: *linux.io_uring_sqe = &self.sq.sqes[index];
        sqe.opcode = op;
        sqe.fd = fd;
        sqe.addr = @intFromPtr(&self.scratch);
        sqe.len = 0;
        sqe.off = self.sq.off;
        self.sq.array[index] = index;
        tail += 1;
        @atomicStore(u32, self.sq.tail, tail, .release);
    }
};

pub fn perror(err: u64, comptime fmt: []const u8, args: anytype) noreturn {
    const e = linux.E.init(err);
    std.debug.print(fmt, args);
    std.debug.print(": {any}\n", .{e});
    linux.exit(1);
}
