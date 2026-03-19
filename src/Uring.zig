const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Stream = @import("./Stream.zig");
const assert = std.debug.assert;

const Uring = @This();

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

pub fn init(size: u32) !Uring {
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
    try mmap_error(sq_int);
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
        try mmap_error(cq_int);
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
    try mmap_error(sqes_int);

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

pub inline fn get_sqe(self: *Uring) *linux.io_uring_sqe {
    const next = self.sq.sq_tail +% 1;
    const sqe = &self.sq.sqes[self.sq.sq_tail & self.sq.mask.*];
    self.sq.sq_tail = next;
    return sqe;
}

pub fn prep_multishot_accept(self: *Uring, key: Stream.Key, data: *Stream) void {
    assert(data.state == .Accept);
    var sqe = self.get_sqe();
    sqe.prep_multishot_accept(data.fd, @ptrCast(&data.addr), &data.addrlen, 0);
    sqe.user_data = @intFromEnum(key);
}

pub fn prep_close(self: *Uring, key: Stream.Key, data: *Stream) void {
    // should only close an end if the other end closed first
    data.state = .Close;
    var sqe = self.get_sqe();
    sqe.prep_close(data.fd);
    sqe.user_data = @intFromEnum(key);
}

pub fn prep_recv(self: *Uring, key: Stream.Key, data: *Stream) void {
    data.state = .Recv;
    var sqe = self.get_sqe();
    sqe.prep_recv(data.fd, &data.buf, data.pos);
    sqe.user_data = @intFromEnum(key);
}

pub fn prep_socket(self: *Uring, key: Stream.Key, data: *Stream) void {
    assert(data.fd == 0);
    var sqe = self.get_sqe();
    data.state = .Socket;
    sqe.prep_socket(linux.AF.INET, linux.SOCK.STREAM, 0, 0);
    sqe.user_data = @intFromEnum(key);
}

pub fn prep_connect(self: *Uring, key: Stream.Key, data: *Stream) void {
    assert(data.state == .Socket);
    assert(data.fd > 0);
    assert(data.addr.family == linux.AF.INET);
    var sqe = self.get_sqe();
    data.state = .Connect;
    sqe.prep_connect(data.fd, @ptrCast(&data.addr), data.addrlen);
    sqe.user_data = @intFromEnum(key);
}

pub fn prep_send(self: *Uring, key: Stream.Key, data: *Stream, opposing: ?*Stream) void {
    // SEND data buf to OPPOSING fd
    assert(opposing != null);
    assert(data.pos > 0);
    data.state = .Send;
    var sqe = self.get_sqe();
    sqe.prep_send(opposing.?.fd, data.buf[0..@intCast(data.pos)], 0);
    sqe.user_data = @intFromEnum(key);
}

pub fn cq_ready(self: *Uring) u32 {
    return @atomicLoad(u32, self.cq.tail, .acquire) -% self.cq.head.*;
}

// TODO: Probably better to copy CQEs to a slice and call atomic load/store only once since we know how many CQEs are ready with cq_ready()
pub fn read(self: *Uring) ?*linux.io_uring_cqe {
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

pub fn submit_and_wait(self: *Uring, num_submit: u32, num_wait: u32) !usize {
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

fn mmap_error(result: usize) !void {
    return switch (linux.E.init(result)) {
        .SUCCESS => {},
        .INVAL => error.InvalidMmapCall,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .OPNOTSUPP => error.SystemSupport,
        .NXIO => error.InvalidRange,
        .OVERFLOW => error.WouldOverflow,
        else => |errno| return posix.unexpectedErrno(errno),
    };
}
