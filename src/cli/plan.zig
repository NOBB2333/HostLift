const std = @import("std");
const inventory_schema = @import("../inventory/schema.zig");
const plan_builder = @import("../plan/builder.zig");
const plan_filter = @import("../plan/filter.zig");
const fs_util = @import("../util/fs.zig");
const json_util = @import("../util/json.zig");
const summary_util = @import("../util/summary.zig");

// 读取源/目标 inventory，构建 migration plan，并按用户选择过滤输出。
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var source_path: ?[]const u8 = null;
    var target_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var summary = false;
    var selection = false;
    var health_report = false;
    var force = false;
    var filter: plan_filter.ActionFilter = .empty;
    defer filter.deinit(allocator);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--source")) {
            index += 1;
            if (index >= args.len) return error.MissingSourcePath;
            source_path = args[index];
        } else if (std.mem.eql(u8, arg, "--target")) {
            index += 1;
            if (index >= args.len) return error.MissingTargetPath;
            target_path = args[index];
        } else if (std.mem.eql(u8, arg, "--output")) {
            index += 1;
            if (index >= args.len) return error.MissingOutputPath;
            output_path = args[index];
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else if (std.mem.eql(u8, arg, "--selection")) {
            selection = true;
        } else if (std.mem.eql(u8, arg, "--health-report")) {
            health_report = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--include-module")) {
            index += 1;
            if (index >= args.len) return error.MissingFilterValue;
            try filter.appendModuleList(allocator, .include, args[index]);
        } else if (std.mem.eql(u8, arg, "--exclude-module")) {
            index += 1;
            if (index >= args.len) return error.MissingFilterValue;
            try filter.appendModuleList(allocator, .exclude, args[index]);
        } else if (std.mem.eql(u8, arg, "--include-action")) {
            index += 1;
            if (index >= args.len) return error.MissingFilterValue;
            try filter.appendActionPattern(allocator, .include, args[index]);
        } else if (std.mem.eql(u8, arg, "--exclude-action")) {
            index += 1;
            if (index >= args.len) return error.MissingFilterValue;
            try filter.appendActionPattern(allocator, .exclude, args[index]);
        } else {
            return error.UnknownPlanArgument;
        }
    }

    const source_file = source_path orelse return error.MissingSourcePath;
    const target_file = target_path orelse return error.MissingTargetPath;
    var output_modes: u8 = 0;
    if (summary) output_modes += 1;
    if (selection) output_modes += 1;
    if (health_report) output_modes += 1;
    if (output_modes > 1) return error.ConflictingPlanOutputMode;

    const source_bytes = try fs_util.readFileAlloc(io, allocator, source_file, 16 * 1024 * 1024);
    defer allocator.free(source_bytes);
    const target_bytes = try fs_util.readFileAlloc(io, allocator, target_file, 16 * 1024 * 1024);
    defer allocator.free(target_bytes);

    const source_parsed = try std.json.parseFromSlice(inventory_schema.Inventory, allocator, source_bytes, .{ .ignore_unknown_fields = true });
    defer source_parsed.deinit();
    const target_parsed = try std.json.parseFromSlice(inventory_schema.Inventory, allocator, target_bytes, .{ .ignore_unknown_fields = true });
    defer target_parsed.deinit();

    var migration_plan = try plan_builder.build(
        allocator,
        source_parsed.value,
        target_parsed.value,
        std.Io.Timestamp.now(io, .real).toSeconds(),
    );
    defer migration_plan.deinit(allocator);
    try plan_filter.filterPlanActions(allocator, &migration_plan, filter);

    if (output_path) |path| {
        if (!force and fs_util.pathExists(io, path)) return error.OutputFileExists;
        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);

        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        if (selection) {
            try summary_util.writePlanSelection(&file_writer.interface, migration_plan);
        } else if (health_report) {
            try summary_util.writePlanHealthReport(&file_writer.interface, migration_plan);
        } else if (summary) {
            try summary_util.writePlanSummary(&file_writer.interface, migration_plan);
        } else {
            try json_util.writePlan(&file_writer.interface, migration_plan);
        }
        try file_writer.flush();
    } else {
        if (selection) {
            try summary_util.writePlanSelection(writer, migration_plan);
        } else if (health_report) {
            try summary_util.writePlanHealthReport(writer, migration_plan);
        } else if (summary) {
            try summary_util.writePlanSummary(writer, migration_plan);
        } else {
            try json_util.writePlan(writer, migration_plan);
        }
    }
}
