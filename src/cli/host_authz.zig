const std = @import("std");
const host_authz = @import("../policy/host_authz.zig");
const fs_util = @import("../util/fs.zig");

// 读取并校验可选本地主机授权文件。
pub fn validateOptional(io: std.Io, allocator: std.mem.Allocator, path: ?[]const u8, operator: []const u8, host: []const u8, writer: anytype) !void {
    const file_path = path orelse return;
    const bytes = try fs_util.readFileAlloc(io, allocator, file_path, 1024 * 1024);
    defer allocator.free(bytes);
    const parsed = try host_authz.parseFromSlice(allocator, bytes);
    defer parsed.deinit();
    const report = host_authz.evaluate(parsed.value, operator, host);
    try writer.print(
        "Host authorization: valid={} operator_matched={} host_allowed={}\n",
        .{ report.valid, report.operator_matched, report.host_allowed },
    );
    if (!report.valid) return error.HostAuthorizationDenied;
}
