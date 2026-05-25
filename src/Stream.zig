const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Upstream = @import("./upstreams.zig").Upstream;
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
    Socket,
    Connect,
    Read,
    Write,
    Timeout,
    Shutdown,
    Close,
    Cancel,
};

const Stream = @This();

upstream_key: ?usize,
state: State,
opposing: ?Key,
addr: linux.sockaddr.storage,
pipefds: [2]i32,
fd: i32,
addrlen: linux.socklen_t,
buf: [4096]u8,
pos: u32,

pub fn init(self: *Stream, connfd: i32, state: State) !void {
    self.* = .{
        .state = state,
        .pipefds = try posix.pipe(),
        .pos = 0,
        .buf = @splat(0),
        .addr = std.mem.zeroes(linux.sockaddr.storage),
        .addrlen = linux.sockaddr.SS_MAXSIZE,
        .opposing = null,
        .upstream_key = null,
        .fd = connfd,
    };
}

pub fn clear(self: *Stream) void {
    self.buf = @splat(0);
    self.pos = 0;
}

pub fn set_upstream(self: *Stream, upstream: Upstream) void {
    const n = upstream.addr.getOsSockLen();
    @memcpy(std.mem.asBytes(&self.addr)[0..n], std.mem.asBytes(&upstream.addr)[0..n]);
    self.upstream_key = upstream.key;
    self.addrlen = n;
}

pub const Key = enum(u64) {
    _,
};

pub const Slot = struct {
    in_use: bool,
    stream: Stream,
};

pub const Pool = struct {
    buckets: std.ArrayList([]Slot),
    capacity: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !Pool {
        const slots: std.ArrayList([]Slot) = try .initCapacity(allocator, 1);
        var p: Pool = .{
            .buckets = slots,
            .capacity = capacity,
            .allocator = allocator,
        };
        try p.alloc_bucket();
        return p;
    }

    fn alloc_bucket(self: *Pool) !void {
        const new_bucket = try self.allocator.alloc(Slot, self.capacity);
        try self.buckets.append(self.allocator, new_bucket);
    }

    pub fn deinit(self: *Pool) void {
        for (self.buckets.items) |bucket| {
            self.allocator.free(bucket);
        }

        self.buckets.deinit(self.allocator);
    }

    pub fn ensure_free_slots(self: *Pool, n: usize) !void {
        var free: usize = 0;
        for (self.buckets.items) |bucket| {
            for (bucket) |slot| {
                if (!slot.in_use) {
                    free += 1;
                    if (free == n) {
                        return;
                    }
                }
            }
        }
        try self.alloc_bucket();
    }

    pub fn reserve(self: *Pool) !Key {
        try self.ensure_free_slots(10);
        for (self.buckets.items, 0..) |bucket, i| {
            for (bucket, 0..) |slot, j| {
                if (!slot.in_use) {
                    bucket[j].in_use = true;
                    return @enumFromInt(i * self.capacity + j);
                }
            }
        }

        return error.Full;
    }

    pub fn release(self: *Pool, key: Key) void {
        const bucket_i = @divTrunc(@intFromEnum(key), self.capacity);
        const slot_i = @rem(@intFromEnum(key), self.capacity);
        var bucket = self.buckets.items[bucket_i];
        bucket[slot_i].in_use = false;
        bucket[slot_i].stream.clear();
    }

    pub fn get(self: Pool, key: Key) ?*Stream {
        const bucket_i = @divTrunc(@intFromEnum(key), self.capacity);
        const slot_i = @rem(@intFromEnum(key), self.capacity);
        var bucket = self.buckets.items[bucket_i];
        if (!bucket[slot_i].in_use) {
            return null;
        }
        return &bucket[slot_i].stream;
    }
};
