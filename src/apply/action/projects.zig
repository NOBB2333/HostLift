const std = @import("std");
const remote_planner = @import("../../remote/planner.zig");
const common = @import("common.zig");

// 生成 Docker Compose 后台启动命令。
pub fn composeUpCommand(allocator: std.mem.Allocator, compose_file: []const u8) !common.Command {
    if (compose_file.len == 0) return error.MissingApplySubject;
    try remote_planner.validatePath(compose_file);
    const argv = try allocator.alloc([]const u8, 6);
    argv[0] = "docker";
    argv[1] = "compose";
    argv[2] = "-f";
    argv[3] = compose_file;
    argv[4] = "up";
    argv[5] = "-d";
    return common.commandWithoutOwned(allocator, argv);
}

// 生成 Docker Compose 状态检查命令。
pub fn composePsCommand(allocator: std.mem.Allocator, compose_file: []const u8) !common.Command {
    if (compose_file.len == 0) return error.MissingApplySubject;
    try remote_planner.validatePath(compose_file);
    const argv = try allocator.alloc([]const u8, 5);
    argv[0] = "docker";
    argv[1] = "compose";
    argv[2] = "-f";
    argv[3] = compose_file;
    argv[4] = "ps";
    return common.commandWithoutOwned(allocator, argv);
}

// 生成 Docker Compose 停止并移除项目容器的回滚命令。
pub fn composeDownCommand(allocator: std.mem.Allocator, compose_file: []const u8) !common.Command {
    if (compose_file.len == 0) return error.MissingApplySubject;
    try remote_planner.validatePath(compose_file);
    const argv = try allocator.alloc([]const u8, 5);
    argv[0] = "docker";
    argv[1] = "compose";
    argv[2] = "-f";
    argv[3] = compose_file;
    argv[4] = "down";
    return common.commandWithoutOwned(allocator, argv);
}
