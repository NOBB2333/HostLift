const std = @import("std");
const module_registry = @import("../modules/registry.zig");
const scan_filter = @import("scan_filter.zig");
const schema = @import("schema.zig");

// 模块扫描结果，包含模块清单和扫描警告。
pub const ScanModulesResult = struct {
    modules: schema.ModuleInventory,
    warnings: [][]const u8,
};

// 汇总所有模块扫描结果，保持 scanner 层只负责观测当前主机状态。
pub fn scanModules(io: std.Io, allocator: std.mem.Allocator, filter: scan_filter.ModuleFilter) !ScanModulesResult {
    return scanModulesWithHandlers(io, allocator, module_registry.allScan(), filter);
}

// 按给定 handler 列表执行扫描，供生产 registry 和测试 fixture 复用。
pub fn scanModulesWithHandlers(
    io: std.Io,
    allocator: std.mem.Allocator,
    handlers: []const module_registry.ModuleHandler,
    filter: scan_filter.ModuleFilter,
) !ScanModulesResult {
    var modules = schema.emptyModules();
    var warnings: std.ArrayList([]const u8) = .empty;
    var services_scanned = false;
    errdefer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
        if (services_scanned) {
            schema.deinitModules(allocator, modules);
        } else {
            var partially_scanned = modules;
            partially_scanned.services.init_system = &.{};
            schema.deinitModules(allocator, partially_scanned);
        }
    }

    for (handlers) |module_handler| {
        if (!filter.matches(module_handler.name)) continue;
        const scan = module_handler.scan orelse continue;
        const ctx = module_registry.ScanContext{
            .io = io,
            .allocator = allocator,
            .modules = &modules,
        };
        scan(ctx) catch |err| {
            try warnings.append(allocator, try std.fmt.allocPrint(
                allocator,
                "scan module {s} failed: {s}",
                .{ @tagName(module_handler.name), @errorName(err) },
            ));
        };
        if (module_handler.name == .services) services_scanned = true;
    }
    if (!services_scanned) modules.services.init_system = try allocator.dupe(u8, "unknown");
    return .{
        .modules = modules,
        .warnings = try warnings.toOwnedSlice(allocator),
    };
}

test "scan registry keeps successful modules when one scanner fails" {
    const handlers = [_]module_registry.ModuleHandler{
        .{ .name = .packages, .scan = failingScan },
        .{ .name = .configs, .scan = successfulConfigScan },
    };

    const test_io: std.Io = undefined;
    const result = try scanModulesWithHandlers(test_io, std.testing.allocator, handlers[0..], .empty);
    defer {
        for (result.warnings) |warning| std.testing.allocator.free(warning);
        std.testing.allocator.free(result.warnings);
        std.testing.allocator.free(result.modules.services.init_system);
        for (result.modules.configs.files) |file| std.testing.allocator.free(file.path);
        std.testing.allocator.free(result.modules.configs.files);
    }

    try std.testing.expectEqual(@as(usize, 1), result.warnings.len);
    try std.testing.expect(std.mem.indexOf(u8, result.warnings[0], "scan module packages failed") != null);
    try std.testing.expectEqual(@as(usize, 1), result.modules.configs.files.len);
    try std.testing.expectEqualStrings("/etc/hosts", result.modules.configs.files[0].path);
}

test "scan module filter includes observation-only modules" {
    const handlers = [_]module_registry.ModuleHandler{
        .{ .name = .packages, .scan = failingScan },
        .{ .name = .network, .scan = successfulNetworkScan },
        .{ .name = .configs, .scan = successfulConfigScan },
    };

    var filter: scan_filter.ModuleFilter = .empty;
    defer filter.deinit(std.testing.allocator);
    try filter.appendModuleList(std.testing.allocator, .include, "network");

    const test_io: std.Io = undefined;
    const result = try scanModulesWithHandlers(test_io, std.testing.allocator, handlers[0..], filter);
    defer {
        for (result.warnings) |warning| std.testing.allocator.free(warning);
        std.testing.allocator.free(result.warnings);
        std.testing.allocator.free(result.modules.services.init_system);
        std.testing.allocator.free(result.modules.network.listeners);
    }

    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
    try std.testing.expectEqual(@as(usize, 1), result.modules.network.listeners.len);
    try std.testing.expectEqual(@as(usize, 0), result.modules.configs.files.len);
}

test "scan module filter excludes selected modules" {
    const handlers = [_]module_registry.ModuleHandler{
        .{ .name = .packages, .scan = failingScan },
        .{ .name = .configs, .scan = successfulConfigScan },
    };

    var filter: scan_filter.ModuleFilter = .empty;
    defer filter.deinit(std.testing.allocator);
    try filter.appendModuleList(std.testing.allocator, .exclude, "packages");

    const test_io: std.Io = undefined;
    const result = try scanModulesWithHandlers(test_io, std.testing.allocator, handlers[0..], filter);
    defer {
        for (result.warnings) |warning| std.testing.allocator.free(warning);
        std.testing.allocator.free(result.warnings);
        std.testing.allocator.free(result.modules.services.init_system);
        for (result.modules.configs.files) |file| std.testing.allocator.free(file.path);
        std.testing.allocator.free(result.modules.configs.files);
    }

    try std.testing.expectEqual(@as(usize, 0), result.warnings.len);
    try std.testing.expectEqual(@as(usize, 1), result.modules.configs.files.len);
}

// 测试用：模拟扫描失败的模块处理器。
fn failingScan(ctx: module_registry.ScanContext) !void {
    _ = ctx;
    return error.IntentionalScanFailure;
}

// 测试用：模拟返回单个配置文件的扫描处理器。
fn successfulConfigScan(ctx: module_registry.ScanContext) !void {
    const files = try ctx.allocator.alloc(schema.ConfigFile, 1);
    files[0] = .{
        .path = try ctx.allocator.dupe(u8, "/etc/hosts"),
        .present = true,
        .size = 42,
    };
    ctx.modules.configs = .{ .files = files };
}

// 测试用：模拟返回单个监听 socket 的扫描处理器。
fn successfulNetworkScan(ctx: module_registry.ScanContext) !void {
    const listeners = try ctx.allocator.alloc(schema.ListeningSocket, 1);
    listeners[0] = .{
        .protocol = "tcp",
        .address = "0.0.0.0",
        .port = 22,
        .process = null,
    };
    ctx.modules.network = .{ .listeners = listeners, .truncated = false };
}
