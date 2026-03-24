const std = @import("std");
const linux = std.os.linux;
const posix = std.os.posix;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

// (Ideal) State sequence
//                                                                         ----------------------
//                                                                         v                    |
// Accept (downstream) -> Socket(upstream) -> Connect (upstream) -> Recv (upstream) -> Send (downstream)
//                     -> Recv (downstream)                      -> Send (upstream)
//                                  |                                     ^
//                                  ---------------------------------------
//
// (Current) State sequence
//                                  ------------------------------------------------------------------------------------------------------
//                                  |                                                                                                    |
//                                  v                                                                                                    |
// Accept (downstream) -> Recv (downstream) -> Socket (upstream) -> Connect (upstream) -> Send (upstream) -> Recv (upstream) -> Send (downstream)
//                                  |                                                          ^
//                                  |                                                          |
//                                  ------------------------------------------------------------
pub const State = enum {
    Accept,
    Recv,
    Socket,
    Connect,
    Send,
    Close,
    Cancel,
};

const Stream = @This();

state: State,
opposing: ?Key,
addr: linux.sockaddr.in,
fd: i32,
addrlen: linux.socklen_t,
buf: [4096]u8,
pos: u32,

pub fn init(self: *Stream, connfd: i32, state: State) void {
    self.* = .{
        .state = state,
        .pos = 0,
        .buf = @splat(0),
        .addr = std.mem.zeroes(linux.sockaddr.in),
        .addrlen = linux.sockaddr.SS_MAXSIZE,
        .opposing = null,
        .fd = connfd,
    };
}

pub fn flush(self: *Stream) void {
    self.buf = @splat(0);
    self.pos = 0;
}

pub const Key = enum(u64) {
    _,
};

pub const Slot = struct {
    in_use: bool,
    stream: Stream,
};

pub const Pool = struct {
    slots: []Slot,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !Pool {
        const slots = try allocator.alloc(Slot, capacity);
        return .{
            .slots = slots,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.allocator.free(self.slots);
    }

    pub fn reserve(self: *Pool) !Key {
        for (self.slots, 0..) |slot, i| {
            if (!slot.in_use) {
                self.slots[i].in_use = true;
                return @enumFromInt(i);
            }
        }

        const last_i = self.slots.len;

        self.slots = try self.allocator.realloc(self.slots, self.slots.len * 2);
        self.slots[last_i + 1].in_use = true;
        return @enumFromInt(last_i + 1);
    }

    pub fn release(self: *Pool, key: Key) void {
        self.slots[@intFromEnum(key)].in_use = false;
    }

    pub fn get(self: Pool, key: Key) *Stream {
        assert(self.slots[@intFromEnum(key)].in_use);
        return &self.slots[@intFromEnum(key)].stream;
    }
};
