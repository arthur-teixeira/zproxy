const std = @import("std");
const linux = std.os.linux;

const QUEUE_DEPTH = 1;
var offset: usize = 0;

const Uring = struct {
    scratch: [1024]u8,
    nb: u32,
    fd: i32,
    sq: Sq,
    cq: Cq,

    const Sq = struct {
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

    fn init() Uring {
        var params: linux.io_uring_params = std.mem.zeroes(linux.io_uring_params);
        const ring_fd = linux.io_uring_setup(QUEUE_DEPTH, &params);
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
        var cq_int: usize = @intFromPtr(cq_ptr);
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

        const sring_tail: *u32 = @ptrFromInt(sq_int + @as(usize, params.sq_off.tail));
        const sring_mask: *u32 = @ptrFromInt(sq_int + @as(usize, params.sq_off.ring_mask));
        const sring_array: [*]u32 = @ptrFromInt(sq_int + @as(usize, params.sq_off.array));

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

        const cring_head: *u32 = @ptrFromInt(cq_int + @as(usize, params.cq_off.head));
        const cring_tail: *u32 = @ptrFromInt(cq_int + @as(usize, params.cq_off.tail));
        const cring_mask: *u32 = @ptrFromInt(cq_int + @as(usize, params.cq_off.ring_mask));

        const cqes: [*]linux.io_uring_cqe = @ptrFromInt(cq_int + @as(usize, params.cq_off.cqes));

        return .{
            .scratch = @splat(0),
            .nb = 0,
            .fd = @intCast(ring_fd),
            .cq = .{
                .head = cring_head,
                .tail = cring_tail,
                .mask = cring_mask,
                .cqes = cqes,
            },
            .sq = .{
                .tail = sring_tail,
                .mask = sring_mask,
                .array = sring_array,
                .sqes = sqes,
            },
        };
    }

    fn submit(self: *Uring, fd: i32, op: linux.IORING_OP) usize {
        var tail = self.sq.tail.*;
        const index = tail & self.sq.mask.*;
        var sqe: *linux.io_uring_sqe = &self.sq.sqes[index];
        sqe.opcode = op;
        sqe.fd = fd;
        sqe.addr = @intFromPtr(&self.scratch);
        if (op == linux.IORING_OP.READ) {
            @memset(&self.scratch, 0);
            sqe.len = self.scratch.len;
        } else {
            sqe.len = self.nb;
        }
        sqe.off = offset;
        self.sq.array[index] = index;
        tail += 1;
        @atomicStore(u32, self.sq.tail, tail, .release);

        const ret = linux.io_uring_enter(self.fd, 1, 1, linux.IORING_ENTER_GETEVENTS, null);
        switch (linux.E.init(ret)) {
            .SUCCESS => {},
            else => perror(ret, "io_uring_enter", .{}),
        }

        return ret;
    }

    fn read(self: *Uring) i32 {
        var head = @atomicLoad(u32, self.cq.head, .acquire);
        if (head == self.cq.tail.*) {
            return -1;
        }
        const cqe = &self.cq.cqes[head & self.cq.mask.*];
        if (cqe.res < 0) {
            perror(@intCast(cqe.res), "cqe_read", .{});
        }
        head += 1;
        @atomicStore(u32, self.cq.head, head, .release);

        return cqe.res;
    }
};

pub fn main() !void {
    var uring: Uring = .init();

    while (true) {
        _ = uring.submit(linux.STDIN_FILENO, .READ);
        const res = uring.read();
        if (res > 0) {
            uring.nb = @intCast(res);
            _ = uring.submit(linux.STDOUT_FILENO, .WRITE);
            _ = uring.read();
            offset += @intCast(res);
            continue;
        }
        if (res == 0) {
            break;
        }

        unreachable;
    }
}

pub fn perror(err: usize, comptime fmt: []const u8, args: anytype) noreturn {
    const e = linux.E.init(err);
    std.debug.print(fmt, args);
    std.debug.print(": {any}\n", .{e});
    linux.exit(1);
}
