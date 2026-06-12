const std = @import("std");
const configs = @import("dev_env_configs.zig");
const proxy = @import("dev_env_proxy.zig");
const schema = @import("schema.zig");
const tools = @import("dev_env_tools.zig");

// 扫描开发工具、开发配置和代理环境变量。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.DevEnvInventory {
    return .{
        .tools = try tools.scan(io, allocator),
        .configs = try configs.scan(io, allocator),
        .proxy_vars = try proxy.scan(io, allocator),
    };
}
