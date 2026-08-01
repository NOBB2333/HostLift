const std = @import("std");
const schema = @import("schema.zig");

// 输出 manifest 校验的人类可读摘要。
pub fn writeVerificationSummary(writer: anytype, report: schema.VerificationReport) !void {
    try writer.print(
        \\HostLift manifest verification
        \\Valid: {}
        \\Checked entries: {d}
        \\Missing: {d}
        \\Changed: {d}
        \\Extra: {d}
        \\Source truncated: {}
        \\Target truncated: {}
        \\
    , .{
        report.valid,
        report.checked,
        report.missing,
        report.changed,
        report.extra,
        report.expected_truncated,
        report.actual_truncated,
    });
}

// 用路径哈希索引比较两个 manifest，线性统计缺失、变更和额外条目；内存不足时失败关闭。
pub fn verify(allocator: std.mem.Allocator, expected: schema.Manifest, actual: schema.Manifest) !schema.VerificationReport {
    var missing: usize = 0;
    var changed: usize = 0;
    var extra: usize = 0;

    var unmatched_actual = std.StringHashMap(schema.Entry).init(allocator);
    defer unmatched_actual.deinit();
    try unmatched_actual.ensureTotalCapacity(@intCast(actual.entries.len));
    for (actual.entries) |actual_entry| {
        const result = try unmatched_actual.getOrPut(actual_entry.path);
        if (result.found_existing) {
            extra += 1;
        } else {
            result.value_ptr.* = actual_entry;
        }
    }

    for (expected.entries) |expected_entry| {
        const removed = unmatched_actual.fetchRemove(expected_entry.path) orelse {
            missing += 1;
            continue;
        };
        if (!entriesEquivalent(expected_entry, removed.value)) changed += 1;
    }
    extra += unmatched_actual.count();

    return .{
        .valid = !expected.truncated and !actual.truncated and missing == 0 and changed == 0 and extra == 0,
        .checked = expected.entries.len,
        .missing = missing,
        .changed = changed,
        .extra = extra,
        .expected_truncated = expected.truncated,
        .actual_truncated = actual.truncated,
    };
}

// 校验内容 manifest 没有截断且只包含普通文件、目录或已哈希链接目标的符号链接。
pub fn ensureCompleteContent(value: schema.Manifest) !void {
    if (value.truncated) return error.ManifestTruncated;
    for (value.entries) |entry| {
        if (std.mem.eql(u8, entry.kind, "file") and entry.sha256 != null) continue;
        if (std.mem.eql(u8, entry.kind, "directory") and entry.sha256 == null) continue;
        if (std.mem.eql(u8, entry.kind, "sym_link") and entry.sha256 != null) continue;
        return error.UnsupportedManifestEntryKind;
    }
}

// 判断两个 manifest 文件条目是否大小和 SHA-256 都一致。
fn entriesEquivalent(expected: schema.Entry, actual: schema.Entry) bool {
    if (!std.mem.eql(u8, expected.kind, actual.kind)) return false;
    if (expected.size != actual.size) return false;
    if (expected.sha256) |expected_hash| {
        if (actual.sha256) |actual_hash| return std.mem.eql(u8, expected_hash, actual_hash);
        return false;
    }
    return actual.sha256 == null;
}

test "local manifest verification detects changed missing and extra entries" {
    var expected_entries = [_]schema.Entry{
        .{ .path = "app", .kind = "directory", .size = 0, .sha256 = null },
        .{ .path = "app/main", .kind = "file", .size = 3, .sha256 = "abc" },
    };
    var matching_entries = [_]schema.Entry{
        .{ .path = "app", .kind = "directory", .size = 0, .sha256 = null },
        .{ .path = "app/main", .kind = "file", .size = 3, .sha256 = "abc" },
    };
    var changed_entries = [_]schema.Entry{
        .{ .path = "app", .kind = "directory", .size = 0, .sha256 = null },
        .{ .path = "app/main", .kind = "file", .size = 4, .sha256 = "def" },
        .{ .path = "app/extra", .kind = "file", .size = 1, .sha256 = "aaa" },
    };

    const expected = schema.Manifest{
        .root = "/srv/app",
        .entries = expected_entries[0..],
        .file_count = 1,
        .dir_count = 1,
        .total_bytes = 3,
        .truncated = false,
    };
    const matching = schema.Manifest{
        .root = "/srv/app-copy",
        .entries = matching_entries[0..],
        .file_count = 1,
        .dir_count = 1,
        .total_bytes = 3,
        .truncated = false,
    };
    const changed_manifest = schema.Manifest{
        .root = "/srv/app-copy",
        .entries = changed_entries[0..],
        .file_count = 2,
        .dir_count = 1,
        .total_bytes = 5,
        .truncated = false,
    };

    const ok = try verify(std.testing.allocator, expected, matching);
    try std.testing.expect(ok.valid);

    const bad = try verify(std.testing.allocator, expected, changed_manifest);
    try std.testing.expect(!bad.valid);
    try std.testing.expectEqual(@as(usize, 1), bad.changed);
    try std.testing.expectEqual(@as(usize, 1), bad.extra);

    var truncated_expected = expected;
    truncated_expected.truncated = true;
    const truncated_report = try verify(std.testing.allocator, truncated_expected, changed_manifest);
    try std.testing.expect(!truncated_report.valid);
    try std.testing.expectEqual(@as(usize, 1), truncated_report.changed);
    try std.testing.expectEqual(@as(usize, 1), truncated_report.extra);

    var truncated_actual = matching;
    truncated_actual.truncated = true;
    try std.testing.expect(!(try verify(std.testing.allocator, expected, truncated_actual)).valid);
}

test "manifest verification rejects duplicate paths" {
    var expected_entries = [_]schema.Entry{.{ .path = "app", .kind = "file", .size = 3, .sha256 = "abc" }};
    var actual_entries = [_]schema.Entry{
        .{ .path = "app", .kind = "file", .size = 3, .sha256 = "abc" },
        .{ .path = "app", .kind = "file", .size = 3, .sha256 = "abc" },
    };
    const expected = schema.Manifest{ .root = "/source", .entries = &expected_entries, .file_count = 1, .dir_count = 0, .total_bytes = 3, .truncated = false };
    const actual = schema.Manifest{ .root = "/target", .entries = &actual_entries, .file_count = 2, .dir_count = 0, .total_bytes = 6, .truncated = false };
    const report = try verify(std.testing.allocator, expected, actual);
    try std.testing.expect(!report.valid);
    try std.testing.expectEqual(@as(usize, 1), report.extra);
}

test "complete content manifest rejects special files and unhashed symlinks" {
    var supported_entries = [_]schema.Entry{
        .{ .path = "app", .kind = "directory", .size = 0 },
        .{ .path = "app/main", .kind = "file", .size = 3, .sha256 = "abc" },
        .{ .path = "current", .kind = "sym_link", .size = 3, .sha256 = "def" },
    };
    var value = schema.Manifest{
        .root = "/srv/app",
        .entries = &supported_entries,
        .file_count = 1,
        .dir_count = 1,
        .total_bytes = 3,
        .truncated = false,
    };
    try ensureCompleteContent(value);

    supported_entries[2].sha256 = null;
    try std.testing.expectError(error.UnsupportedManifestEntryKind, ensureCompleteContent(value));
    supported_entries[2] = .{ .path = "current", .kind = "sym_link", .size = 3, .sha256 = "def" };
    supported_entries[1].sha256 = null;
    try std.testing.expectError(error.UnsupportedManifestEntryKind, ensureCompleteContent(value));
    supported_entries[1].sha256 = "abc";
    supported_entries[2] = .{ .path = "pipe", .kind = "named_pipe", .size = 0 };
    try std.testing.expectError(error.UnsupportedManifestEntryKind, ensureCompleteContent(value));
    value.truncated = true;
    try std.testing.expectError(error.ManifestTruncated, ensureCompleteContent(value));
}
