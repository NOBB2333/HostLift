const std = @import("std");
const audit_log = @import("log.zig");
const audit_verify = @import("verify.zig");

test "audit verifier accepts chained JSONL" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    var chain: audit_log.Chain = .{};
    try audit_log.writeChainedEvent(std.testing.allocator, &writer.writer, &chain, .{
        .timestamp = 123,
        .phase = .apply,
        .result = .started,
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .action_id = "packages/install/nginx",
        .action_type = "install_package",
        .module = "packages",
        .message = "started",
    });
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

    const report = try audit_verify.verifyJsonl(std.testing.allocator, buffer.items);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.valid);
    try std.testing.expectEqual(@as(usize, 2), report.events);
    try std.testing.expectEqual(@as(u32, 0), report.errors);
    try std.testing.expect(report.tail_hash != null);
    try std.testing.expectEqualStrings(&chain.previous_event_hash.?, report.tail_hash.?);
}

test "audit verifier rejects modified event contents" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    var chain: audit_log.Chain = .{};
    try audit_log.writeChainedEvent(std.testing.allocator, &writer.writer, &chain, .{
        .timestamp = 123,
        .phase = .apply,
        .result = .started,
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .action_id = "packages/install/nginx",
        .action_type = "install_package",
        .module = "packages",
        .message = "started",
    });
    buffer = writer.toArrayList();

    const tampered = try std.mem.replaceOwned(u8, std.testing.allocator, buffer.items, "started", "failed");
    defer std.testing.allocator.free(tampered);
    const report = try audit_verify.verifyJsonl(std.testing.allocator, tampered);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(u32, 1), report.errors);
}

test "audit verifier accepts legacy JSONL without credential source" {
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
    const event_hash = try audit_log.hashLegacyEvent(std.testing.allocator, event, null);
    const jsonl = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":\"hostlift.audit.v1\",\"timestamp\":123,\"phase\":\"apply\",\"result\":\"started\",\"operator\":\"ops/alice\",\"host\":\"root@192.0.2.10\",\"action_id\":\"packages/install/nginx\",\"action_type\":\"install_package\",\"module\":\"packages\",\"plan_created_at\":null,\"plan_hash\":null,\"approval_ticket\":null,\"rollback_manifest\":null,\"prev_event_hash\":null,\"event_hash\":\"{s}\",\"message\":\"started\"}}\n",
        .{event_hash},
    );
    defer std.testing.allocator.free(jsonl);

    const report = try audit_verify.verifyJsonl(std.testing.allocator, jsonl);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.valid);
    try std.testing.expectEqual(@as(usize, 1), report.events);
    try std.testing.expectEqual(@as(u32, 0), report.errors);
    try std.testing.expectEqualStrings(&event_hash, report.tail_hash.?);
}

test "audit verifier accepts JSONL without policy hash" {
    const event = audit_log.Event{
        .timestamp = 123,
        .phase = .apply,
        .result = .started,
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .action_id = "packages/install/nginx",
        .action_type = "install_package",
        .module = "packages",
        .credential_source = .identity_file,
        .message = "started",
    };
    const event_hash = try audit_log.hashEventWithoutPolicyHash(std.testing.allocator, event, null);
    const jsonl = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":\"hostlift.audit.v1\",\"timestamp\":123,\"phase\":\"apply\",\"result\":\"started\",\"operator\":\"ops/alice\",\"host\":\"root@192.0.2.10\",\"action_id\":\"packages/install/nginx\",\"action_type\":\"install_package\",\"module\":\"packages\",\"plan_created_at\":null,\"plan_hash\":null,\"approval_ticket\":null,\"credential_source\":\"identity_file\",\"rollback_manifest\":null,\"prev_event_hash\":null,\"event_hash\":\"{s}\",\"message\":\"started\"}}\n",
        .{event_hash},
    );
    defer std.testing.allocator.free(jsonl);

    const report = try audit_verify.verifyJsonl(std.testing.allocator, jsonl);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.valid);
    try std.testing.expectEqual(@as(usize, 1), report.events);
    try std.testing.expectEqual(@as(u32, 0), report.errors);
    try std.testing.expectEqualStrings(&event_hash, report.tail_hash.?);
}

test "audit verifier accepts ssh agent credential source" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    var chain: audit_log.Chain = .{};
    try audit_log.writeChainedEvent(std.testing.allocator, &writer.writer, &chain, .{
        .timestamp = 123,
        .phase = .apply,
        .result = .started,
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .action_id = "remote/exec/whoami",
        .action_type = "remote_command",
        .module = "remote",
        .credential_source = .ssh_agent,
        .message = "started",
    });
    buffer = writer.toArrayList();

    const report = try audit_verify.verifyJsonl(std.testing.allocator, buffer.items);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.valid);
    try std.testing.expectEqual(@as(usize, 1), report.events);
    try std.testing.expectEqual(@as(u32, 0), report.errors);
}

test "audit verifier accepts env credential source" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    var chain: audit_log.Chain = .{};
    try audit_log.writeChainedEvent(std.testing.allocator, &writer.writer, &chain, .{
        .timestamp = 123,
        .phase = .apply,
        .result = .started,
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .action_id = "remote/exec/whoami",
        .action_type = "remote_command",
        .module = "remote",
        .credential_source = .env,
        .message = "started",
    });
    buffer = writer.toArrayList();

    const report = try audit_verify.verifyJsonl(std.testing.allocator, buffer.items);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.valid);
    try std.testing.expectEqual(@as(usize, 1), report.events);
    try std.testing.expectEqual(@as(u32, 0), report.errors);
}

test "audit verifier reports invalid enum fields without aborting" {
    const jsonl =
        "{\"schema_version\":\"hostlift.audit.v1\",\"timestamp\":123,\"phase\":\"unknown\",\"result\":\"started\",\"operator\":\"ops/alice\",\"host\":\"root@192.0.2.10\",\"action_id\":\"packages/install/nginx\",\"action_type\":\"install_package\",\"module\":\"packages\",\"plan_created_at\":null,\"plan_hash\":null,\"approval_ticket\":null,\"credential_source\":\"default_ssh\",\"rollback_manifest\":null,\"prev_event_hash\":null,\"event_hash\":\"00\",\"message\":\"started\"}\n";

    const report = try audit_verify.verifyJsonl(std.testing.allocator, jsonl);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(usize, 1), report.events);
    try std.testing.expectEqual(@as(u32, 1), report.errors);
    try std.testing.expect(report.tail_hash == null);
}
