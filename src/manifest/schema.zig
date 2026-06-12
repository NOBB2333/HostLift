const std = @import("std");

pub const schema_version = "hostlift.local_manifest.v1";

// 本地 manifest 中的单个文件或目录条目。
pub const Entry = struct {
    path: []const u8,
    kind: []const u8,
    size: u64,
    sha256: ?[]const u8 = null,
};

// 本地 manifest，描述源目录的文件树结构和校验值。
pub const Manifest = struct {
    schema_version: []const u8 = schema_version,
    root: []const u8,
    entries: []Entry,
    file_count: usize,
    dir_count: usize,
    total_bytes: u64,
    truncated: bool,

    // 释放本地 manifest 中分配的路径和校验值。
    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        for (self.entries) |entry| {
            allocator.free(entry.path);
            if (entry.sha256) |hash| allocator.free(hash);
        }
        allocator.free(self.entries);
    }
};

// manifest 校验报告，记录有效性和缺失/变更/多余的统计。
pub const VerificationReport = struct {
    valid: bool,
    checked: usize,
    missing: usize,
    changed: usize,
    extra: usize,
    expected_truncated: bool,
};

test "local manifest schema constant is stable" {
    try std.testing.expectEqualStrings("hostlift.local_manifest.v1", schema_version);
}
