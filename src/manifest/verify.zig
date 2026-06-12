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
        \\Extra: {d}{s}
        \\
    , .{
        report.valid,
        report.checked,
        report.missing,
        report.changed,
        report.extra,
        if (report.expected_truncated) " (ignored because expected manifest is truncated)" else "",
    });
}

// 比较两个 manifest，统计缺失、变更和额外条目。
pub fn verify(expected: schema.Manifest, actual: schema.Manifest) schema.VerificationReport {
    var missing: usize = 0;
    var changed: usize = 0;
    var extra: usize = 0;

    for (expected.entries) |expected_entry| {
        const actual_entry = findEntry(actual.entries, expected_entry.path) orelse {
            missing += 1;
            continue;
        };
        if (!entriesEquivalent(expected_entry, actual_entry)) changed += 1;
    }

    for (actual.entries) |actual_entry| {
        if (findEntry(expected.entries, actual_entry.path) == null) extra += 1;
    }

    return .{
        .valid = missing == 0 and changed == 0 and (extra == 0 or expected.truncated),
        .checked = expected.entries.len,
        .missing = missing,
        .changed = changed,
        .extra = extra,
        .expected_truncated = expected.truncated,
    };
}

// 按相对路径在 manifest 条目中查找文件记录。
fn findEntry(entries: []const schema.Entry, path: []const u8) ?schema.Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
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

    const ok = verify(expected, matching);
    try std.testing.expect(ok.valid);

    const bad = verify(expected, changed_manifest);
    try std.testing.expect(!bad.valid);
    try std.testing.expectEqual(@as(usize, 1), bad.changed);
    try std.testing.expectEqual(@as(usize, 1), bad.extra);

    var truncated_expected = expected;
    truncated_expected.truncated = true;
    const truncated_report = verify(truncated_expected, changed_manifest);
    try std.testing.expect(!truncated_report.valid);
    try std.testing.expectEqual(@as(usize, 1), truncated_report.changed);
    try std.testing.expectEqual(@as(usize, 1), truncated_report.extra);
}
