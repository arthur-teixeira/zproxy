const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const assert = std.debug.assert;
const Stream = @import("./Stream.zig");
const Uring = @import("./Uring.zig");
const proxy = @import("./proxy.zig").proxy;

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
    try proxy(allocator, upstream_addr, null);
}
