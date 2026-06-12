const std = @import("std");
const module_registry = @import("../modules/registry.zig");
const packages_scanner = @import("packages.zig");
const platform = @import("platform.zig");
const scan_filter = @import("scan_filter.zig");
const scan_runner = @import("scan_runner.zig");
const schema = @import("schema.zig");

pub const ModuleFilterMode = scan_filter.ModuleFilterMode;
pub const ModuleFilter = scan_filter.ModuleFilter;

// 本机扫描选项，支持按模块 include/exclude 过滤。
pub const ScanOptions = struct {
    filter: ModuleFilter = .empty,
};

// 扫描本机并组装完整 inventory；这里只收集事实，不决定迁移动作。
pub fn scanLocal(io: std.Io, allocator: std.mem.Allocator) !schema.Inventory {
    return scanLocalWithOptions(io, allocator, .{});
}

// 按给定选项扫描本机 inventory，支持按模块 include/exclude。
pub fn scanLocalWithOptions(io: std.Io, allocator: std.mem.Allocator, options: ScanOptions) !schema.Inventory {
    const host = try platform.readHostInfo(io, allocator);
    const distro = try platform.readOsRelease(io, allocator);
    const package_manager = try packages_scanner.detectManager(io, allocator);
    try scan_filter.validateRequestedScanModules(options.filter, module_registry.allScan());
    const scanned_inventory = try scan_runner.scanModules(io, allocator, options.filter);
    return .{
        .schema_version = schema.schema_version,
        .host = host,
        .distro = distro,
        .package_manager = package_manager,
        .modules = scanned_inventory.modules,
        .scan = .{
            .scanned_at_unix = std.Io.Timestamp.now(io, .real).toSeconds(),
            .warnings = scanned_inventory.warnings,
        },
    };
}
