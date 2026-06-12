const inventory = @import("../inventory/schema.zig");

// 输出开发工具、开发配置和代理变量摘要。
pub fn writeDevEnvSummary(writer: anytype, dev_env: inventory.DevEnvInventory) !void {
    var wrote_tools = false;
    for (dev_env.tools) |tool| {
        if (!tool.present) continue;
        if (!wrote_tools) {
            try writer.writeAll("\nDeveloper tools:\n");
            wrote_tools = true;
        }
        try writer.print("  - {s}: {s}\n", .{ tool.name, tool.version });
    }

    var wrote_configs = false;
    for (dev_env.configs) |config| {
        if (!config.present) continue;
        if (!wrote_configs) {
            try writer.writeAll("\nDeveloper config paths:\n");
            wrote_configs = true;
        }
        try writer.print("  - {s}: {s} ({d} bytes)\n", .{ config.tool, config.path, config.size });
    }

    var wrote_proxy = false;
    for (dev_env.proxy_vars) |proxy| {
        if (!proxy.present) continue;
        if (!wrote_proxy) {
            try writer.writeAll("\nProxy environment variables present:\n");
            wrote_proxy = true;
        }
        try writer.print("  - {s}\n", .{proxy.name});
    }
}

// 输出 home 配置路径摘要。
pub fn writeHomeConfigSummary(writer: anytype, home_configs: inventory.HomeConfigInventory) !void {
    var wrote_header = false;
    for (home_configs.configs[0..@min(home_configs.configs.len, 60)]) |config| {
        if (!config.present) continue;
        if (!wrote_header) {
            try writer.writeAll("\nHome config paths:\n");
            wrote_header = true;
        }
        try writer.print(
            "  - {s}: {s} [{s}{s}] size={d}\n",
            .{ config.user, config.path, @tagName(config.kind), if (config.directory) ", directory" else "", config.size },
        );
    }
    if (home_configs.configs.len > 60) try writer.print("  ... {d} more\n", .{home_configs.configs.len - 60});
    if (home_configs.truncated) try writer.writeAll("  ... home config list truncated at scanner limit\n");
}

// 输出应用/数据路径摘要。
pub fn writeAppDataSummary(writer: anytype, appdata: inventory.AppDataInventory) !void {
    var wrote_header = false;
    for (appdata.paths) |path| {
        if (!path.present) continue;
        if (!wrote_header) {
            try writer.writeAll("\nApp/data paths:\n");
            wrote_header = true;
        }
        try writer.print("  - {s} [{s}] size={d}\n", .{ path.path, @tagName(path.kind), path.size });
    }
}
