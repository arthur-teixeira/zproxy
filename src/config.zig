const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const Config = @This();

const Value = struct {
    upstream: []Upstream,
};

allocator: Allocator,
parsed: json.Parsed(Value),

const Upstream = struct {
    address: []const u8,
    port: ?u32 = null,
    name: []const u8,
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
    const p = try json.parseFromSlice(Config.Value, allocator, json_string, .{});

    return .{
        .allocator = allocator,
        .parsed = p,
    };
}

fn deinit(self: *Config) void {
    self.parsed.deinit();
}

fn value(self: *Config) Config.Value {
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
        .port = 8080,
        .name = "server1",
    }, .{
        .address = "localhost",
        .port = 8081,
        .name = "server2",
    } };

    try std.testing.expectEqualDeep(Config.Value{
        .upstream = &upstreams,
    }, config.value());
}
