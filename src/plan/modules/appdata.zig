const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");
const manual_common = @import("manual_common.zig");

// 规划应用/数据路径复制动作，并根据数据类型设置风险等级。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.AppDataInventory,
    target: inventory.AppDataInventory,
) !void {
    for (source.paths) |path| {
        if (!path.present) continue;
        if (path.kind == .database_data or path.kind == .docker_data) {
            const description = try dumpRestoreDescription(allocator, path);
            defer allocator.free(description);
            const task_inputs = [_]common.ManualInputSpec{
                .{ .name = "data_path", .value = path.path },
                .{ .name = "data_kind", .value = @tagName(path.kind) },
                .{ .name = "engine", .value = path.engine_hint orelse @tagName(path.kind) },
                .{ .name = "dump_command_hint", .value = path.dump_hint orelse "use application-native dump, backup, or snapshot procedure" },
                .{ .name = "restore_command_hint", .value = path.restore_hint orelse "restore with the matching application-native procedure" },
                .{ .name = "consistency_requirement", .value = path.consistency_hint orelse "stop writes or create an application-consistent snapshot before copying files" },
            };
            try manual_common.appendManualStep(allocator, actions, .{
                .id_prefix = "appdata/dump-restore",
                .name = path.path,
                .subject = path.path,
                .module = .appdata,
                .risk = .high,
                .description = description,
                .task_provider = "appdata_restore",
                .task_inputs = &task_inputs,
            });
            continue;
        }
        if (dataPathPresent(target.paths, path.path)) continue;
        try common.appendAction(allocator, actions, .{
            .id_prefix = "appdata/copy",
            .name = path.path,
            .module = .appdata,
            .action_type = .copy_data_path,
            .risk = .medium,
            .requires_confirmation = true,
            .description = "Copy selected app data path after size and service review",
        });
    }
}

// 判断目标清单中指定数据路径是否存在。
fn dataPathPresent(paths: []const inventory.DataPath, needle: []const u8) bool {
    for (paths) |path| {
        if (path.present and std.mem.eql(u8, path.path, needle)) return true;
    }
    return false;
}

fn dumpRestoreDescription(allocator: std.mem.Allocator, path: inventory.DataPath) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Prepare stateful dump/restore plan; engine={s}; dump={s}; restore={s}; consistency={s}; HostLift does not hot-copy this data path by default",
        .{
            path.engine_hint orelse @tagName(path.kind),
            path.dump_hint orelse "use application-native dump, backup, or snapshot procedure",
            path.restore_hint orelse "restore with the matching application-native procedure",
            path.consistency_hint orelse "stop writes or create an application-consistent snapshot before copying files",
        },
    );
}
