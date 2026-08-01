const std = @import("std");
const inventory_schema = @import("../inventory/schema.zig");
const plan_builder = @import("../plan/builder.zig");
const plan_schema = @import("../plan/schema.zig");
const plan_filter = @import("../plan/filter.zig");
const plan_validator = @import("../plan/validator.zig");
const workloads = @import("../plan/workloads.zig");
const fs_util = @import("../util/fs.zig");
const json_util = @import("../util/json.zig");
const summary_util = @import("../util/summary.zig");
const reinstall_schema = @import("../reinstall/schema.zig");

// 读取源/目标 inventory，构建 plan，并输出完整计划、摘要或未过滤的工作负载报告。
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    var source_path: ?[]const u8 = null;
    var target_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var summary = false;
    var selection = false;
    var health_report = false;
    var workload_report = false;
    var force = false;
    var postgresql_auto = false;
    var postgresql_writers_stopped = false;
    var reinstall_recipes_path: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, arg, "--workloads")) {
            workload_report = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--postgresql-auto")) {
            postgresql_auto = true;
        } else if (std.mem.eql(u8, arg, "--postgresql-writers-stopped")) {
            postgresql_writers_stopped = true;
        } else if (std.mem.eql(u8, arg, "--reinstall-recipes")) {
            index += 1;
            if (index >= args.len) return error.MissingReinstallRecipesPath;
            reinstall_recipes_path = args[index];
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
    if (workload_report) output_modes += 1;
    if (output_modes > 1) return error.ConflictingPlanOutputMode;
    if (workload_report and !filter.isEmpty()) return error.WorkloadReportRequiresFullPlan;

    const source_bytes = try fs_util.readFileAlloc(io, allocator, source_file, 16 * 1024 * 1024);
    defer allocator.free(source_bytes);
    const target_bytes = try fs_util.readFileAlloc(io, allocator, target_file, 16 * 1024 * 1024);
    defer allocator.free(target_bytes);

    const source_parsed = try std.json.parseFromSlice(inventory_schema.Inventory, allocator, source_bytes, .{ .ignore_unknown_fields = true });
    defer source_parsed.deinit();
    const target_parsed = try std.json.parseFromSlice(inventory_schema.Inventory, allocator, target_bytes, .{ .ignore_unknown_fields = true });
    defer target_parsed.deinit();

    var reinstall_bytes: ?[]u8 = null;
    defer if (reinstall_bytes) |bytes| allocator.free(bytes);
    var reinstall_parsed: ?std.json.Parsed(reinstall_schema.RecipeSet) = null;
    defer if (reinstall_parsed) |*parsed| parsed.deinit();
    if (reinstall_recipes_path) |path| {
        reinstall_bytes = try fs_util.readFileAlloc(io, allocator, path, 4 * 1024 * 1024);
        reinstall_parsed = try std.json.parseFromSlice(reinstall_schema.RecipeSet, allocator, reinstall_bytes.?, .{ .ignore_unknown_fields = false });
        try reinstall_schema.validateSet(reinstall_parsed.?.value);
    }

    var migration_plan = try plan_builder.buildWithOptions(
        allocator,
        source_parsed.value,
        target_parsed.value,
        std.Io.Timestamp.now(io, .real).toSeconds(),
        .{
            .postgresql_auto = postgresql_auto,
            .postgresql_writers_stopped = postgresql_writers_stopped,
            .reinstall_recipes = if (reinstall_parsed) |parsed| parsed.value else null,
        },
    );
    defer migration_plan.deinit(allocator);
    try plan_validator.validateSelection(migration_plan.actions, filter);
    if (!workload_report) try plan_filter.filterPlanActions(allocator, &migration_plan, filter);

    var workload_result: ?workloads.Report = null;
    defer if (workload_result) |*value| value.deinit(allocator);
    if (workload_report) {
        workload_result = try workloads.build(allocator, source_parsed.value, target_parsed.value, migration_plan);
    }

    if (output_path) |path| {
        if (!force and fs_util.pathExists(io, path)) return error.OutputFileExists;
        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);

        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        if (workload_report) {
            try json_util.writeWorkloadReport(&file_writer.interface, workload_result.?);
        } else if (selection) {
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
        if (workload_report) {
            try json_util.writeWorkloadReport(writer, workload_result.?);
        } else if (selection) {
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

test "plan CLI parses verified reinstall recipes and emits the three-step DAG" {
    var source_resources = [_]inventory_schema.ResourceRef{.{
        .path = "/usr/local/bin/tool",
        .kind = .unmanaged_executable,
        .default_action = .review,
    }};
    var source_modules = inventory_schema.emptyModules();
    source_modules.resources.resources = &source_resources;
    const source = testInventory("source", source_modules);
    const target = testInventory("target", inventory_schema.emptyModules());
    const recipes =
        \\{
        \\  "schema_version": "hostlift.reinstall_recipes.v1",
        \\  "recipes": [{
        \\    "id": "tool-v1",
        \\    "manual_action_id": "resources/reinstall//usr/local/bin/tool",
        \\    "kind": "verified_binary",
        \\    "source_url": "https://downloads.example.test/tool/tool",
        \\    "sha256": "0101010101010101010101010101010101010101010101010101010101010101",
        \\    "artifact_size_bytes": 4096,
        \\    "target_distro_id": "ubuntu",
        \\    "target_distro_version": "24.04",
        \\    "target_arch": "x86_64",
        \\    "install_argv": ["install", "-m", "0755", "{artifact}", "/usr/local/bin/tool"],
        \\    "verify_argv": ["test", "-x", "/usr/local/bin/tool"],
        \\    "verify_stdout_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        \\    "managed_paths": ["/usr/local/bin/tool"]
        \\  }]
        \\}
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source_path = try testPath(std.testing.allocator, &tmp.sub_path, "source.json");
    defer std.testing.allocator.free(source_path);
    const target_path = try testPath(std.testing.allocator, &tmp.sub_path, "target.json");
    defer std.testing.allocator.free(target_path);
    const recipes_path = try testPath(std.testing.allocator, &tmp.sub_path, "recipes.json");
    defer std.testing.allocator.free(recipes_path);
    try writeTestInventory(source_path, source);
    try writeTestInventory(target_path, target);
    try writeTestBytes(recipes_path, recipes);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &output);
    try run(std.testing.io, std.testing.allocator, &.{ "--source", source_path, "--target", target_path, "--reinstall-recipes", recipes_path }, &writer.writer);
    output = writer.toArrayList();

    const parsed = try std.json.parseFromSlice(plan_schema.MigrationPlan, std.testing.allocator, output.items, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.actions.len);
    try std.testing.expectEqual(plan_schema.ActionType.reinstall_download, parsed.value.actions[0].action_type);
    try std.testing.expectEqual(plan_schema.ActionType.reinstall_execute, parsed.value.actions[1].action_type);
    try std.testing.expectEqual(plan_schema.ActionType.reinstall_verify, parsed.value.actions[2].action_type);
    try std.testing.expectEqual(@as(u64, 4096), parsed.value.actions[0].reinstall.?.artifact_size_bytes);
    try std.testing.expect(plan_validator.validate(parsed.value).valid);
}

fn testInventory(hostname: []const u8, modules: inventory_schema.ModuleInventory) inventory_schema.Inventory {
    return .{
        .schema_version = inventory_schema.schema_version,
        .host = .{ .hostname = hostname, .machine_id_hash = null, .kernel_release = "test", .arch = .x86_64 },
        .distro = .{ .id = "ubuntu", .id_like = &.{}, .version_id = "24.04", .pretty_name = "Ubuntu 24.04 LTS" },
        .package_manager = .{ .kind = .apt, .version = "apt", .repos = &.{} },
        .modules = modules,
        .scan = .{ .scanned_at_unix = 0, .warnings = &.{} },
    };
}

fn testPath(allocator: std.mem.Allocator, sub_path: []const u8, filename: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ sub_path, filename });
}

fn writeTestInventory(path: []const u8, value: inventory_schema.Inventory) !void {
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    try json_util.writeInventory(&writer.interface, value);
    try writer.flush();
}

fn writeTestBytes(path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.flush();
}
