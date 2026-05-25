const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const Config = @This();
const FIVE_MINUTES = 10000 * 60 * 5;

pub const Value = struct {
    upstream: []Upstream,
    proxy: Proxy,
};

allocator: Allocator,
parsed: json.Parsed(Value),

pub const Upstream = struct {
    address: []const u8,
    port: u16,
    name: ?[]const u8,
};

pub const Proxy = struct {
    address: []const u8,
    timeout: ?u64 = FIVE_MINUTES,
    port: u16,
};

pub fn init_from_file(allocator: Allocator, file_path: []const u8) !Config {
    const cwd = std.fs.cwd();
    const f = try cwd.openFile(file_path, .{ .mode = .read_only });
    var buf: [4096]u8 = undefined;
    var rdr = f.reader(&buf);
    try rdr.interface.fillMore();

    return from_json(allocator, buf[0..rdr.interface.end]);
}

fn from_json(allocator: Allocator, json_string: []const u8) !Config {
    const p = try json.parseFromSlice(Config.Value, allocator, json_string, .{ .allocate = .alloc_always });

    return .{
        .allocator = allocator,
        .parsed = p,
    };
}

pub fn deinit(self: *Config) void {
    self.parsed.deinit();
}

pub inline fn value(self: Config) Config.Value {
    return self.parsed.value;
}

const assert = std.debug.assert;
const test_alloc = std.testing.allocator;

test "parse file" {
    const path = "./src/tests/zproxy.json";
    var config = try Config.init_from_file(test_alloc, path);
    defer config.deinit();
    var upstreams = [_]Upstream{ .{
        .address = "localhost",
        .port = 3030,
        .name = "server1",
    }, .{
        .address = "localhost",
        .port = 3031,
        .name = "server2",
    } };

    try std.testing.expectEqualDeep(Config.Value{ .upstream = &upstreams, .proxy = .{
        .address = "127.0.0.1",
        .port = 8080,
    } }, config.value());

    try std.testing.expectEqualStrings("localhost", config.parsed.value.upstream[0].address);
    try std.testing.expectEqualStrings("localhost", config.parsed.value.upstream[1].address);
}
