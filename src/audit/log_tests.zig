const std = @import("std");
const audit_log = @import("log.zig");
const plan_schema = @import("../plan/schema.zig");

test "audit path uses batch timestamp" {
    const path = try audit_log.pathForBatch(std.testing.allocator, 123);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/hostlift-audit-123.jsonl", path);
}

test "audit event writes JSONL" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    try audit_log.writeEvent(&writer.writer, .{
        .timestamp = 123,
        .phase = .apply,
        .result = .succeeded,
        .host = "root@192.0.2.10",
        .action_id = "packages/install/nginx",
        .action_type = "install_package",
        .module = "packages",
        .plan_created_at = 100,
        .rollback_manifest = "/tmp/rollback.jsonl",
        .message = "ok",
    });
    buffer = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"schema_version\":\"hostlift.audit.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"result\":\"succeeded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"operator\":\"unknown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"plan_hash\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"approval_ticket\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"event_hash\":null") != null);
    try std.testing.expect(std.mem.endsWith(u8, buffer.items, "\n"));
}

test "audit action event includes plan hash" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    const action = plan_schema.Action{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .description = "Install explicit package on target: nginx",
        .risk = .low,
        .requires_confirmation = false,
    };

    try audit_log.writeActionEvent(
        &writer.writer,
        123,
        .started,
        "ops/alice",
        "root@192.0.2.10",
        action,
        100,
        "ab" ** 32,
        "cd" ** 32,
        "OPS-123",
        .identity_file,
        "/tmp/rollback.jsonl",
        "started",
    );
    buffer = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"plan_hash\":\"" ++ "ab" ** 32 ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"policy_hash\":\"" ++ "cd" ** 32 ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"approval_ticket\":\"OPS-123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"credential_source\":\"identity_file\"") != null);
}

test "audit chained events link previous event hash" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    var chain: audit_log.Chain = .{};
    const event = audit_log.Event{
        .timestamp = 123,
        .phase = .apply,
        .result = .started,
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .action_id = "packages/install/nginx",
        .action_type = "install_package",
        .module = "packages",
        .message = "started",
    };

    try audit_log.writeChainedEvent(std.testing.allocator, &writer.writer, &chain, event);
    const first_hash = chain.previous_event_hash.?;
    try audit_log.writeChainedEvent(std.testing.allocator, &writer.writer, &chain, .{
        .timestamp = 124,
        .phase = .apply,
        .result = .succeeded,
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .action_id = "packages/install/nginx",
        .action_type = "install_package",
        .module = "packages",
        .message = "succeeded",
    });
    buffer = writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"prev_event_hash\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"event_hash\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"prev_event_hash\":\"" ++ first_hash ++ "\"") != null);
}
