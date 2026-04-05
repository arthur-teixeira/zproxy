const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const assert = std.debug.assert;
const Stream = @import("./Stream.zig");
const Uring = @import("./Uring.zig");
const proxy = @import("./proxy.zig").proxy;
const Config = @import("./config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // TODO: get path from CLI args or default to cwd "zproxy.json"
    // TODO: Validate config before starting proxy
    var cfg = try Config.init_from_file(allocator, "zproxy.json");
    defer cfg.deinit();

    try proxy(allocator, cfg.value(), null);
}
