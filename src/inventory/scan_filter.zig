const std = @import("std");
const module_registry = @import("../modules/registry.zig");
const plan_schema = @import("../plan/schema.zig");

// 模块过滤模式：包含或排除。
pub const ModuleFilterMode = enum { include, exclude };

// 扫描模块过滤器；用于 scan 阶段选择要采集的模块。
pub const ModuleFilter = struct {
    include_modules: std.ArrayList(plan_schema.ModuleName) = .empty,
    exclude_modules: std.ArrayList(plan_schema.ModuleName) = .empty,

    pub const empty: ModuleFilter = .{};

    // 释放扫描过滤器中保存的模块列表。
    pub fn deinit(self: *ModuleFilter, allocator: std.mem.Allocator) void {
        self.include_modules.deinit(allocator);
        self.exclude_modules.deinit(allocator);
    }

    // 判断扫描过滤器是否没有任何 include/exclude 条件。
    pub fn isEmpty(self: ModuleFilter) bool {
        return self.include_modules.items.len == 0 and self.exclude_modules.items.len == 0;
    }

    // 解析逗号分隔模块列表，并加入扫描过滤器。
    pub fn appendModuleList(self: *ModuleFilter, allocator: std.mem.Allocator, mode: ModuleFilterMode, value: []const u8) !void {
        var parts = std.mem.splitScalar(u8, value, ',');
        var appended = false;
        while (parts.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t\r\n");
            if (part.len == 0) continue;
            const module_name = try parseModuleName(part);
            switch (mode) {
                .include => try self.include_modules.append(allocator, module_name),
                .exclude => try self.exclude_modules.append(allocator, module_name),
            }
            appended = true;
        }
        if (!appended) return error.MissingFilterValue;
    }

    // 判断指定模块是否应该执行扫描。
    pub fn matches(self: ModuleFilter, module_name: plan_schema.ModuleName) bool {
        if (containsModule(self.exclude_modules.items, module_name)) return false;
        return self.include_modules.items.len == 0 or containsModule(self.include_modules.items, module_name);
    }
};

// 确认 include/exclude 中的模块已经接入 scan lifecycle。
pub fn validateRequestedScanModules(filter: ModuleFilter, handlers: []const module_registry.ModuleHandler) !void {
    for (filter.include_modules.items) |module_name| {
        if (!hasScanHandler(handlers, module_name)) return error.UnsupportedScanModule;
    }
    for (filter.exclude_modules.items) |module_name| {
        if (!hasScanHandler(handlers, module_name)) return error.UnsupportedScanModule;
    }
}

// 判断模块是否在 scan registry 中有可用 handler。
pub fn hasScanHandler(handlers: []const module_registry.ModuleHandler, module_name: plan_schema.ModuleName) bool {
    for (handlers) |module_handler| {
        if (module_handler.name == module_name and module_handler.scan != null) return true;
    }
    return false;
}

// 将命令行模块名解析为统一模块枚举。
pub fn parseModuleName(value: []const u8) !plan_schema.ModuleName {
    if (std.mem.eql(u8, value, "security")) return .dev_env;
    if (std.mem.eql(u8, value, "kernel")) return .processes;
    inline for (std.meta.fields(plan_schema.ModuleName)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidFilterModule;
}

// 判断模块列表中是否包含指定模块。
pub fn containsModule(values: []const plan_schema.ModuleName, needle: plan_schema.ModuleName) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

test "scan module filter accepts storage observation module" {
    var filter: ModuleFilter = .empty;
    defer filter.deinit(std.testing.allocator);
    try filter.appendModuleList(std.testing.allocator, .include, "storage,system_baseline");

    try validateRequestedScanModules(filter, module_registry.allScan());
}
