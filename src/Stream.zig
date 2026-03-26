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

pub fn clear(self: *Stream) void {
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

    pub fn ensure_free_slots(self: *Pool, n: usize) !void {
        var free: usize = 0;
        for (self.slots) |slot| {
            if (!slot.in_use) {
                free += 1;
                if (free == n) {
                    return;
                }
            }
        }

        self.slots = try self.allocator.realloc(self.slots, self.slots.len * 2);
    }

    pub fn reserve(self: *Pool) !Key {
        for (self.slots, 0..) |slot, i| {
            if (!slot.in_use) {
                self.slots[i].in_use = true;
                return @enumFromInt(i);
            }
        }

        return error.Full;
    }

    pub fn release(self: *Pool, key: Key) void {
        self.slots[@intFromEnum(key)].in_use = false;
        self.slots[@intFromEnum(key)].stream.clear();
    }

    pub fn get(self: Pool, key: Key) *Stream {
        assert(self.slots[@intFromEnum(key)].in_use);
        return &self.slots[@intFromEnum(key)].stream;
    }
};
