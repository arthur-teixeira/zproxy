const std = @import("std");
const Stream = @import("./Stream.zig");
const Config = @import("./config.zig");

const Allocator = std.mem.Allocator;

const UpstreamManager = @This();

pub const Upstream = struct {
    addr: std.net.Address,
    key: usize,
};

allocator: Allocator,
counter: usize,
addresses: []std.net.Address,
healthy: []bool,

pub fn init(allocator: Allocator, config: Config.Value) !UpstreamManager {
    const upstreams = try resolve_upstreams(allocator, config);
    var healthy = try allocator.alloc(bool, upstreams.len);
    @memset(healthy[0..], true);

    return .{
        .addresses = upstreams,
        .healthy = healthy,
        .counter = 0,
        .allocator = allocator,
    };
}

pub fn select_upstream(self: *UpstreamManager) Upstream {
    self.counter += 1;
    var i = self.counter % self.addresses.len;

    var seen: usize = 0;
    while (!self.healthy[i] and seen < self.addresses.len) : (self.counter += 1) {
        seen += 1;
        i = self.counter % self.addresses.len;
    }

    if (!self.healthy[i]) {
        std.debug.print("No healthy upstreams, trying an unhealthy one\n", .{});
    }

    return .{
        .addr = self.addresses[i],
        .key = i,
    };
}

pub fn report_health(self: *UpstreamManager, upstream_key: usize, healthy: bool) void {
    self.healthy[upstream_key] = healthy;
}

fn resolve_upstreams(allocator: Allocator, config: Config.Value) ![]std.net.Address {
    var addresses = try allocator.alloc(std.net.Address, config.upstream.len);
    for (config.upstream, 0..) |u, i| {
        const list = try std.net.getAddressList(allocator, u.address, u.port);
        defer list.deinit();

        if (list.addrs.len == 0) {
            return error.NoUpstreamAddresses;
        }
        addresses[i] = list.addrs[0];
    }

    return addresses;
}
