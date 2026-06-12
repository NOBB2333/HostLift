const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const plan = @import("../plan/schema.zig");
const plan_validator = @import("../plan/validator.zig");
const remote = @import("../remote/schema.zig");

// 将主机清单按稳定的缩进 JSON 输出。
pub fn writeInventory(writer: anytype, value: inventory.Inventory) !void {
    try std.json.Stringify.value(value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = true,
    }, writer);
    try writer.writeByte('\n');
}

// 将迁移计划按稳定的缩进 JSON 输出。
pub fn writePlan(writer: anytype, value: plan.MigrationPlan) !void {
    try std.json.Stringify.value(value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = true,
    }, writer);
    try writer.writeByte('\n');
}

// 将远程命令计划输出为 JSON，便于 dry-run 审核。
pub fn writeCommandPlan(writer: anytype, value: remote.CommandPlan) !void {
    try std.json.Stringify.value(value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = true,
    }, writer);
    try writer.writeByte('\n');
}

// 将文件传输计划输出为 JSON，便于执行前确认来源和目标。
pub fn writeTransferPlan(writer: anytype, value: remote.TransferPlan) !void {
    try std.json.Stringify.value(value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = true,
    }, writer);
    try writer.writeByte('\n');
}

// 将迁移计划校验结果输出为机器可读 JSON。
pub fn writePlanValidationReport(writer: anytype, value: plan_validator.ValidationReport) !void {
    try std.json.Stringify.value(value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = true,
    }, writer);
    try writer.writeByte('\n');
}

test "inventory json includes schema version" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);

    const value = inventory.Inventory{
        .schema_version = inventory.schema_version,
        .host = .{
            .hostname = "source",
            .machine_id_hash = null,
            .kernel_release = "test",
            .arch = .x86_64,
        },
        .distro = .{
            .id = "ubuntu",
            .id_like = &.{},
            .version_id = "24.04",
            .pretty_name = "Ubuntu 24.04 LTS",
        },
        .package_manager = .{
            .kind = .apt,
            .version = "test",
            .repos = &.{},
        },
        .modules = inventory.emptyModules(),
        .scan = .{
            .scanned_at_unix = 0,
            .warnings = &.{},
        },
    };

    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    try writeInventory(&writer.writer, value);
    buffer = writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, inventory.schema_version) != null);
}
