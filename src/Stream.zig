const std = @import("std");
const linux = std.os.linux;
const posix = std.os.posix;
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
};

const Stream = @This();

state: State,
opposing: ?*Stream,
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
