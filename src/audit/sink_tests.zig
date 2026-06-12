const std = @import("std");
const file_sink = @import("file_sink.zig");
const mirror_sink = @import("mirror_sink.zig");
const audit_verify = @import("verify.zig");
const writer_sink = @import("writer_sink.zig");
const fs_util = @import("../util/fs.zig");
const plan_schema = @import("../plan/schema.zig");

test "file sink writes chained action events without second initialization" {
    const path = try std.fmt.allocPrint(std.testing.allocator, "zig-cache-hostlift-audit-sink-test-{x}.jsonl", .{std.testing.random_seed});
    defer std.testing.allocator.free(path);
    var buffer: [4096]u8 = undefined;
    var sink = try file_sink.FileSink.open(std.testing.io, path, &buffer);
    defer {
        sink.close();
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    }

    const action = plan_schema.Action{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .description = "Install nginx",
        .risk = .low,
        .requires_confirmation = false,
    };
    try sink.writeAction(
        std.testing.allocator,
        123,
        .started,
        "ops/alice",
        "root@192.0.2.10",
        action,
        100,
        "ab" ** 32,
        null,
        "OPS-123",
        .identity_file,
        "/tmp/rollback.jsonl",
        "started",
    );
    try sink.flush();
    try std.testing.expect(sink.tailHash() != null);

    const bytes = try fs_util.readFileAlloc(std.testing.io, std.testing.allocator, path, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"credential_source\":\"identity_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"event_hash\":\"") != null);
}

test "writer sink writes chained action events to memory" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buffer);
    var sink: writer_sink.WriterSink = .{ .writer = &writer.writer };

    const action = plan_schema.Action{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .description = "Install nginx",
        .risk = .low,
        .requires_confirmation = false,
    };
    try sink.writeAction(
        std.testing.allocator,
        123,
        .started,
        "ops/alice",
        "root@192.0.2.10",
        action,
        100,
        "ab" ** 32,
        null,
        "OPS-123",
        .default_ssh,
        "/tmp/rollback.jsonl",
        "started",
    );
    buffer = writer.toArrayList();

    try std.testing.expect(sink.tailHash() != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"event_hash\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"credential_source\":\"default_ssh\"") != null);
}

test "mirrored sink writes identical verifiable local audit log" {
    const path = try std.fmt.allocPrint(std.testing.allocator, "zig-cache-hostlift-audit-mirror-test-{x}.jsonl", .{std.testing.random_seed});
    defer std.testing.allocator.free(path);
    var mirror_buffer: [4096]u8 = undefined;
    var primary_bytes: std.ArrayList(u8) = .empty;
    defer primary_bytes.deinit(std.testing.allocator);
    var primary_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &primary_bytes);

    const Primary = writer_sink.WriterSink;
    var sink = mirror_sink.MirroredSink(Primary){
        .primary = .{ .writer = &primary_writer.writer },
        .mirror = try file_sink.FileSink.open(std.testing.io, path, &mirror_buffer),
    };
    defer {
        sink.close();
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    }

    const action = plan_schema.Action{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .description = "Install nginx",
        .risk = .low,
        .requires_confirmation = false,
    };
    try sink.writeAction(
        std.testing.allocator,
        123,
        .started,
        "ops/alice",
        "root@192.0.2.10",
        action,
        100,
        "ab" ** 32,
        null,
        "OPS-123",
        .ssh_agent,
        "/tmp/rollback.jsonl",
        "started",
    );
    try sink.writeAction(
        std.testing.allocator,
        124,
        .succeeded,
        "ops/alice",
        "root@192.0.2.10",
        action,
        100,
        "ab" ** 32,
        null,
        "OPS-123",
        .ssh_agent,
        "/tmp/rollback.jsonl",
        "succeeded",
    );
    try sink.flush();
    primary_bytes = primary_writer.toArrayList();
    try std.testing.expect(sink.tailHash() != null);
    try std.testing.expectEqualStrings(&sink.primary.tailHash().?, &sink.mirror.tailHash().?);

    const mirror_bytes = try fs_util.readFileAlloc(std.testing.io, std.testing.allocator, path, 1024 * 1024);
    defer std.testing.allocator.free(mirror_bytes);
    try std.testing.expectEqualStrings(primary_bytes.items, mirror_bytes);

    const report = try audit_verify.verifyJsonl(std.testing.allocator, mirror_bytes);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.valid);
    try std.testing.expectEqual(@as(usize, 2), report.events);
}
