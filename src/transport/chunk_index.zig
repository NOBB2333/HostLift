const std = @import("std");
const manifest_schema = @import("../manifest/schema.zig");

pub const schema_version = "hostlift.transport.chunk_index.v1";

// 单个 chunk 的引用信息，记录路径、偏移、大小和内容哈希。
pub const ChunkRef = struct {
    path: []const u8,
    offset: u64,
    size: u64,
    sha256_hex: []const u8,
};

// 单个文件的引用信息，记录路径、大小及所属 chunk 范围。
pub const FileRef = struct {
    path: []const u8,
    size: u64,
    chunks_start: usize,
    chunks_len: usize,
};

// chunk 索引，保存分块大小、文件列表和 chunk 列表。
pub const Index = struct {
    schema_version: []const u8 = schema_version,
    chunk_size_bytes: u64,
    files: []FileRef,
    chunks: []ChunkRef,
};

// 拥有内存所有权的 chunk 索引，deinit 时释放容器。
pub const OwnedIndex = struct {
    index: Index,
    files: std.ArrayList(FileRef),
    chunks: std.ArrayList(ChunkRef),

    // 释放 chunk index 的 owned 切片容器；字段内容引用 manifest，不单独释放。
    pub fn deinit(self: *OwnedIndex, allocator: std.mem.Allocator) void {
        self.files.deinit(allocator);
        self.chunks.deinit(allocator);
    }
};

// chunk 索引差异，分类为缺失、变更和多余。
pub const Diff = struct {
    missing: []ChunkRef,
    changed: []ChunkRef,
    extra: []ChunkRef,
};

// 拥有内存所有权的 chunk 索引差异，deinit 时释放容器。
pub const OwnedDiff = struct {
    diff: Diff,
    missing: std.ArrayList(ChunkRef),
    changed: std.ArrayList(ChunkRef),
    extra: std.ArrayList(ChunkRef),

    // 释放 chunk index diff 的 owned 切片容器；字段内容引用输入 index。
    pub fn deinit(self: *OwnedDiff, allocator: std.mem.Allocator) void {
        self.missing.deinit(allocator);
        self.changed.deinit(allocator);
        self.extra.deinit(allocator);
    }
};

// 计算目标索引中缺失或内容不一致的源 chunk。
pub fn missingChunks(
    allocator: std.mem.Allocator,
    source: Index,
    target: Index,
) ![]ChunkRef {
    var diff = try diffIndexes(allocator, source, target);
    defer diff.deinit(allocator);

    var result: std.ArrayList(ChunkRef) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, diff.diff.missing);
    try result.appendSlice(allocator, diff.diff.changed);
    return result.toOwnedSlice(allocator);
}

// 比较源和目标 chunk index，区分缺失、变更和目标多余 chunk。
pub fn diffIndexes(
    allocator: std.mem.Allocator,
    source: Index,
    target: Index,
) !OwnedDiff {
    var missing: std.ArrayList(ChunkRef) = .empty;
    errdefer missing.deinit(allocator);
    var changed: std.ArrayList(ChunkRef) = .empty;
    errdefer changed.deinit(allocator);
    var extra: std.ArrayList(ChunkRef) = .empty;
    errdefer extra.deinit(allocator);

    for (source.chunks) |chunk| {
        const target_chunk = findChunkByIdentity(target.chunks, chunk) orelse {
            try missing.append(allocator, chunk);
            continue;
        };
        if (!chunkContentEquivalent(chunk, target_chunk)) {
            try changed.append(allocator, chunk);
        }
    }

    for (target.chunks) |chunk| {
        if (findChunkByIdentity(source.chunks, chunk) == null) {
            try extra.append(allocator, chunk);
        }
    }

    return .{
        .diff = .{
            .missing = missing.items,
            .changed = changed.items,
            .extra = extra.items,
        },
        .missing = missing,
        .changed = changed,
        .extra = extra,
    };
}

// 从 manifest 构建第一版 chunk index；当前按整文件 chunk 记录，后续再接真实分块哈希。
pub fn buildFromManifest(
    allocator: std.mem.Allocator,
    manifest: manifest_schema.Manifest,
    chunk_size_bytes: u64,
) !OwnedIndex {
    if (chunk_size_bytes == 0) return error.InvalidChunkSize;
    var files: std.ArrayList(FileRef) = .empty;
    errdefer files.deinit(allocator);
    var chunks: std.ArrayList(ChunkRef) = .empty;
    errdefer chunks.deinit(allocator);

    for (manifest.entries) |entry| {
        if (!std.mem.eql(u8, entry.kind, "file")) continue;
        const hash = entry.sha256 orelse return error.MissingChunkHash;
        const start = chunks.items.len;
        try chunks.append(allocator, .{
            .path = entry.path,
            .offset = 0,
            .size = entry.size,
            .sha256_hex = hash,
        });
        try files.append(allocator, .{
            .path = entry.path,
            .size = entry.size,
            .chunks_start = start,
            .chunks_len = 1,
        });
    }

    return .{
        .index = .{
            .chunk_size_bytes = chunk_size_bytes,
            .files = files.items,
            .chunks = chunks.items,
        },
        .files = files,
        .chunks = chunks,
    };
}

// 按路径和偏移在 chunk 列表中查找匹配项。
fn findChunkByIdentity(chunks: []const ChunkRef, expected: ChunkRef) ?ChunkRef {
    for (chunks) |candidate| {
        if (!std.mem.eql(u8, candidate.path, expected.path)) continue;
        if (candidate.offset != expected.offset) continue;
        return candidate;
    }
    return null;
}

// 比较两个 chunk 的内容是否等价（大小和哈希一致）。
fn chunkContentEquivalent(left: ChunkRef, right: ChunkRef) bool {
    return left.size == right.size and std.mem.eql(u8, left.sha256_hex, right.sha256_hex);
}

test "chunk index builds file-to-chunk mapping from manifest" {
    var entries = [_]manifest_schema.Entry{
        .{
            .path = "/srv/app/a.txt",
            .kind = "file",
            .size = 12,
            .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
        .{
            .path = "/srv/app/cache",
            .kind = "directory",
            .size = 0,
            .sha256 = "",
        },
    };
    const manifest: manifest_schema.Manifest = .{
        .schema_version = manifest_schema.schema_version,
        .root = "/srv/app",
        .entries = entries[0..],
        .file_count = 1,
        .dir_count = 1,
        .total_bytes = 12,
        .truncated = false,
    };

    var owned = try buildFromManifest(std.testing.allocator, manifest, 8 * 1024 * 1024);
    defer owned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(schema_version, owned.index.schema_version);
    try std.testing.expectEqual(@as(usize, 1), owned.index.files.len);
    try std.testing.expectEqual(@as(usize, 1), owned.index.chunks.len);
    try std.testing.expectEqualStrings("/srv/app/a.txt", owned.index.files[0].path);
    try std.testing.expectEqualStrings(entries[0].sha256.?, owned.index.chunks[0].sha256_hex);
}

test "chunk index diff reports missing changed and extra chunks" {
    var source_chunks = [_]ChunkRef{
        .{ .path = "a.txt", .offset = 0, .size = 12, .sha256_hex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .{ .path = "b.txt", .offset = 0, .size = 8, .sha256_hex = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        .{ .path = "c.txt", .offset = 0, .size = 4, .sha256_hex = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" },
    };
    var target_chunks = [_]ChunkRef{
        .{ .path = "a.txt", .offset = 0, .size = 12, .sha256_hex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .{ .path = "b.txt", .offset = 0, .size = 8, .sha256_hex = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" },
        .{ .path = "old.txt", .offset = 0, .size = 2, .sha256_hex = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" },
    };
    const source = Index{
        .chunk_size_bytes = 8 * 1024 * 1024,
        .files = &.{},
        .chunks = source_chunks[0..],
    };
    const target = Index{
        .chunk_size_bytes = 8 * 1024 * 1024,
        .files = &.{},
        .chunks = target_chunks[0..],
    };

    var diff = try diffIndexes(std.testing.allocator, source, target);
    defer diff.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), diff.diff.missing.len);
    try std.testing.expectEqual(@as(usize, 1), diff.diff.changed.len);
    try std.testing.expectEqual(@as(usize, 1), diff.diff.extra.len);
    try std.testing.expectEqualStrings("c.txt", diff.diff.missing[0].path);
    try std.testing.expectEqualStrings("b.txt", diff.diff.changed[0].path);
    try std.testing.expectEqualStrings(source_chunks[1].sha256_hex, diff.diff.changed[0].sha256_hex);
    try std.testing.expectEqualStrings("old.txt", diff.diff.extra[0].path);
}

test "chunk index missing chunks includes missing and changed source chunks" {
    var source_chunks = [_]ChunkRef{
        .{ .path = "a.txt", .offset = 0, .size = 12, .sha256_hex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .{ .path = "b.txt", .offset = 0, .size = 8, .sha256_hex = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
    };
    var target_chunks = [_]ChunkRef{
        .{ .path = "a.txt", .offset = 0, .size = 13, .sha256_hex = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" },
    };
    const source = Index{
        .chunk_size_bytes = 8 * 1024 * 1024,
        .files = &.{},
        .chunks = source_chunks[0..],
    };
    const target = Index{
        .chunk_size_bytes = 8 * 1024 * 1024,
        .files = &.{},
        .chunks = target_chunks[0..],
    };

    const missing = try missingChunks(std.testing.allocator, source, target);
    defer std.testing.allocator.free(missing);

    try std.testing.expectEqual(@as(usize, 2), missing.len);
    try std.testing.expectEqualStrings("b.txt", missing[0].path);
    try std.testing.expectEqualStrings("a.txt", missing[1].path);
}

test "chunk index reports no missing chunks for matching indexes" {
    var chunks = [_]ChunkRef{.{
        .path = "a.txt",
        .offset = 0,
        .size = 12,
        .sha256_hex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }};
    const index = Index{
        .chunk_size_bytes = 8 * 1024 * 1024,
        .files = &.{},
        .chunks = chunks[0..],
    };

    const missing = try missingChunks(std.testing.allocator, index, index);
    defer std.testing.allocator.free(missing);

    try std.testing.expectEqual(@as(usize, 0), missing.len);
}

test "chunk index rejects zero chunk size" {
    const manifest: manifest_schema.Manifest = .{
        .schema_version = manifest_schema.schema_version,
        .root = "/srv/app",
        .entries = &.{},
        .file_count = 0,
        .dir_count = 0,
        .total_bytes = 0,
        .truncated = false,
    };
    try std.testing.expectError(error.InvalidChunkSize, buildFromManifest(std.testing.allocator, manifest, 0));
}
