const std = @import("std");

// 计算文件 SHA-256，并返回堆分配的十六进制字符串。
pub fn sha256FileHexAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const hash = try sha256File(io, path);
    const hex = hexSha256(hash);
    return allocator.dupe(u8, &hex);
}

// 在已打开目录内计算文件 SHA-256，避免重复拼接根路径。
pub fn sha256FileInDirHexAlloc(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ![]const u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);

    const hash = try sha256OpenFile(io, file);
    const hex = hexSha256(hash);
    return allocator.dupe(u8, &hex);
}

// 计算本地文件 SHA-256。
pub fn sha256File(io: std.Io, path: []const u8) ![32]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    return sha256OpenFile(io, file);
}

// 计算内存 bytes 的 SHA-256，并返回堆分配的十六进制字符串。
pub fn sha256BytesHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const hex = hexSha256(hash);
    return allocator.dupe(u8, &hex);
}

// 将 64 位十六进制 SHA-256 文本解析为字节数组。
pub fn parseSha256Hex(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidSha256;
    var hash: [32]u8 = undefined;
    for (&hash, 0..) |*byte, index| {
        byte.* = try std.fmt.parseUnsigned(u8, text[index * 2 .. index * 2 + 2], 16);
    }
    return hash;
}

// 将 SHA-256 字节数组编码成十六进制文本。
pub fn hexSha256(hash: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(hash, .lower);
}

// 对已打开的文件流式计算 SHA-256。
fn sha256OpenFile(io: std.Io, file: std.Io.File) ![32]u8 {
    var file_reader = file.readerStreaming(io, &.{});
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read = try file_reader.interface.readSliceShort(&buffer);
        if (read == 0) break;
        hasher.update(buffer[0..read]);
        if (read < buffer.len) break;
    }

    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    return hash;
}

test "sha256 hex helpers round trip lowercase hashes" {
    const parsed = try parseSha256Hex("ab" ** 32);
    for (parsed) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);

    const encoded = hexSha256(parsed);
    try std.testing.expectEqualStrings("ab" ** 32, &encoded);
}

test "sha256 bytes helper hashes exact input bytes" {
    const encoded = try sha256BytesHexAlloc(std.testing.allocator, "hostlift");
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("557583f803bdc5f49644091bee1be8491c88d7da5e7467c9d6d2fcf1cb8ead63", encoded);
}
