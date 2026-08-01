const std = @import("std");
const handler = @import("../handler.zig");
const plan = @import("../../plan/schema.zig");
const recipe_schema = @import("../../reinstall/schema.zig");
const artifacts = @import("../../reinstall/artifacts.zig");
const remote_exec = @import("../../remote/exec.zig");
const remote_planner = @import("../../remote/planner.zig");
const remote_preflight = @import("../../remote/preflight.zig");
const remote_file = @import("../../transport/remote_probe.zig");

const verify_output_limit: usize = 1024 * 1024;

// 返回可信重装 provider 的固定目标依赖；动态 install/verify 入口会在模块 preflight 另行检查。
pub fn applyRequirements(_: handler.ApplyRequirementsContext, action: plan.Action) []const []const u8 {
    if (!isAction(action.action_type)) return &.{};
    return &.{ "curl", "install", "sha256sum", "id", "uname", "cat", "test", "du", "find", "stat", "df" };
}

// 在 mutation 前验证 plan 绑定、root SSH、目标平台、动态命令入口和所有目标路径冲突。
pub fn preflight(ctx: handler.ApplyPreflightContext, action: plan.Action) !void {
    const spec = try validateAction(action, ctx.migration_plan.source_inventory_hash);
    try ensureRoot(ctx);
    try ensureTargetPlatform(ctx, spec);
    try remote_preflight.runCheck(ctx.io, ctx.allocator, .{
        .host = ctx.target_host,
        .commands = &.{ spec.install_argv[0], spec.verify_argv[0] },
    }, ctx.options.execution);
    switch (action.action_type) {
        .reinstall_download => {
            try ensureAbsent(ctx, action.subject);
            try ensureArtifactCapacity(ctx, spec.artifact_size_bytes);
        },
        .reinstall_execute => for (spec.managed_paths) |path| try ensureAbsent(ctx, path),
        .reinstall_verify => {},
        else => unreachable,
    }
}

// 下载或执行已经通过 recipe validator 的重装动作；verify action 本身不产生 mutation。
pub fn apply(ctx: handler.ApplyContext, action: plan.Action) !handler.ApplyResult {
    const spec = try validateAction(action, ctx.migration_plan.source_inventory_hash);
    const artifact_path = try artifacts.artifactPath(ctx.allocator, action.subject, ctx.migration_plan.source_inventory_hash, spec.recipe_id);
    defer ctx.allocator.free(artifact_path);
    switch (action.action_type) {
        .reinstall_download => {
            var root_argv = [_][]const u8{ "install", "-d", "-m", "0700", "-o", "root", "-g", "root", action.subject };
            try execute(ctx, action.id, &root_argv);
            var file_argv = [_][]const u8{ "install", "-m", "0600", "-o", "root", "-g", "root", "/dev/null", artifact_path };
            try execute(ctx, action.id, &file_argv);
            const size_text = try std.fmt.allocPrint(ctx.allocator, "{d}", .{spec.artifact_size_bytes});
            defer ctx.allocator.free(size_text);
            var curl_argv = [_][]const u8{
                "curl", "--disable", "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2", "--fail", "--show-error", "--silent", "--location", "--max-filesize", size_text, "--output", artifact_path, spec.source_url,
            };
            try execute(ctx, action.id, &curl_argv);
            return .{ .changed = true };
        },
        .reinstall_execute => {
            try verifyArtifactSize(ctx.io, ctx.allocator, ctx.target_host, artifact_path, spec.artifact_size_bytes, ctx.options.execution);
            try verifyArtifactHash(ctx.io, ctx.allocator, ctx.target_host, artifact_path, spec.sha256, ctx.options.execution);
            const argv = try substituteArtifactArgv(ctx.allocator, spec.install_argv, artifact_path);
            defer ctx.allocator.free(argv);
            try execute(ctx, action.id, argv);
            return .{ .changed = true };
        },
        .reinstall_verify => return .{ .changed = false },
        else => unreachable,
    }
}

// 验证 artifact 摘要、声明的新建路径和固定 verify argv 的原始 stdout 摘要。
pub fn verify(ctx: handler.VerifyContext, action: plan.Action) !handler.VerifyResult {
    const spec = try validateAction(action, ctx.migration_plan.source_inventory_hash);
    const artifact_path = try artifacts.artifactPath(ctx.allocator, action.subject, ctx.migration_plan.source_inventory_hash, spec.recipe_id);
    defer ctx.allocator.free(artifact_path);
    switch (action.action_type) {
        .reinstall_download => {
            try verifyArtifactSize(ctx.io, ctx.allocator, ctx.target_host, artifact_path, spec.artifact_size_bytes, ctx.execution);
            try verifyArtifactHash(ctx.io, ctx.allocator, ctx.target_host, artifact_path, spec.sha256, ctx.execution);
            try ctx.stdout.print("  verify {s}: pinned artifact size and SHA-256 matched\n", .{action.id});
        },
        .reinstall_execute => {
            try verifyManagedPaths(ctx, spec);
            try ctx.stdout.print("  verify {s}: all declared managed paths exist\n", .{action.id});
        },
        .reinstall_verify => {
            try verifyArtifactSize(ctx.io, ctx.allocator, ctx.target_host, artifact_path, spec.artifact_size_bytes, ctx.execution);
            try verifyArtifactHash(ctx.io, ctx.allocator, ctx.target_host, artifact_path, spec.sha256, ctx.execution);
            try verifyManagedPaths(ctx, spec);
            const output = try remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, ctx.target_host, spec.verify_argv, ctx.execution, verify_output_limit);
            defer ctx.allocator.free(output);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.mem.eql(u8, &hex, spec.verify_stdout_sha256)) return error.ReinstallVerifyOutputMismatch;
            try ctx.stdout.print("  verify {s}: command output SHA-256 matched {s}\n", .{ action.id, &hex });
        },
        else => unreachable,
    }
    return .{ .ok = true, .message = "verified reinstall provider check passed" };
}

fn verifyManagedPaths(ctx: handler.VerifyContext, spec: plan.ReinstallSpec) !void {
    for (spec.managed_paths) |path| {
        if (!try remote_exec.pathExistsWithOptions(ctx.io, ctx.allocator, ctx.target_host, path, ctx.execution)) return error.ReinstallManagedPathMissing;
    }
}

fn isAction(action_type: plan.ActionType) bool {
    return switch (action_type) {
        .reinstall_download, .reinstall_execute, .reinstall_verify => true,
        else => false,
    };
}

fn validateAction(action: plan.Action, source_inventory_hash: [32]u8) !plan.ReinstallSpec {
    if (action.module != .resources or !isAction(action.action_type)) return error.InvalidReinstallAction;
    const spec = action.reinstall orelse return error.MissingReinstallSpec;
    const recipe = recipe_schema.Recipe{
        .id = spec.recipe_id,
        .manual_action_id = spec.source_manual_action_id,
        .kind = @enumFromInt(@intFromEnum(spec.kind)),
        .source_url = spec.source_url,
        .sha256 = spec.sha256,
        .artifact_size_bytes = spec.artifact_size_bytes,
        .target_distro_id = spec.target_distro_id,
        .target_distro_version = spec.target_distro_version,
        .target_arch = spec.target_arch,
        .install_argv = spec.install_argv,
        .verify_argv = spec.verify_argv,
        .verify_stdout_sha256 = spec.verify_stdout_sha256,
        .managed_paths = spec.managed_paths,
    };
    if (!std.mem.eql(u8, spec.schema_version, recipe_schema.schema_version)) return error.InvalidReinstallSpecSchema;
    try recipe_schema.validateRecipe(recipe);
    try artifacts.validateRoot(action.subject, source_inventory_hash, spec.recipe_id);
    return spec;
}

fn ensureRoot(ctx: handler.ApplyPreflightContext) !void {
    var argv = [_][]const u8{ "id", "-u" };
    const output = try remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, ctx.target_host, &argv, ctx.options.execution, 1024);
    defer ctx.allocator.free(output);
    if (!std.mem.eql(u8, std.mem.trim(u8, output, " \t\r\n"), "0")) return error.ReinstallRootSshRequired;
}

fn ensureTargetPlatform(ctx: handler.ApplyPreflightContext, spec: plan.ReinstallSpec) !void {
    var uname_argv = [_][]const u8{ "uname", "-m" };
    const arch_output = try remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, ctx.target_host, &uname_argv, ctx.options.execution, 1024);
    defer ctx.allocator.free(arch_output);
    if (!std.mem.eql(u8, normalizeArch(std.mem.trim(u8, arch_output, " \t\r\n")), spec.target_arch)) return error.ReinstallTargetArchMismatch;

    var os_release_argv = [_][]const u8{ "cat", "/etc/os-release" };
    const os_release = try remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, ctx.target_host, &os_release_argv, ctx.options.execution, 64 * 1024);
    defer ctx.allocator.free(os_release);
    const distro_id = osReleaseValue(os_release, "ID") orelse return error.ReinstallTargetDistroUnavailable;
    const distro_version = osReleaseValue(os_release, "VERSION_ID") orelse return error.ReinstallTargetDistroUnavailable;
    if (!std.mem.eql(u8, distro_id, spec.target_distro_id) or !std.mem.eql(u8, distro_version, spec.target_distro_version)) {
        return error.ReinstallTargetDistroMismatch;
    }
}

fn normalizeArch(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "amd64")) return "x86_64";
    if (std.mem.eql(u8, value, "arm64")) return "aarch64";
    return value;
}

fn osReleaseValue(contents: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len <= key.len or !std.mem.startsWith(u8, line, key) or line[key.len] != '=') continue;
        var value = std.mem.trim(u8, line[key.len + 1 ..], " \t\r");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
            value = value[1 .. value.len - 1];
        }
        return value;
    }
    return null;
}

fn ensureAbsent(ctx: handler.ApplyPreflightContext, path: []const u8) !void {
    if (try remote_exec.pathExistsWithOptions(ctx.io, ctx.allocator, ctx.target_host, path, ctx.options.execution)) return error.ReinstallTargetPathExists;
    var symlink_argv = [_][]const u8{ "test", "-L", path };
    if (try remote_exec.commandSucceededWithOptions(ctx.io, ctx.allocator, ctx.target_host, &symlink_argv, ctx.options.execution)) return error.ReinstallTargetPathExists;
}

fn ensureArtifactCapacity(ctx: handler.ApplyPreflightContext, required: u64) !void {
    var argv = [_][]const u8{ "df", "-PB1", "/var/lib" };
    const output = try remote_exec.commandOutputWithOptions(ctx.io, ctx.allocator, ctx.target_host, &argv, ctx.options.execution, 16 * 1024);
    defer ctx.allocator.free(output);
    const available = parseDfAvailable(output) orelse return error.ReinstallCapacityUnavailable;
    if (available <= required) return error.ReinstallCapacityInsufficient;
}

fn parseDfAvailable(output: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    _ = lines.next() orelse return null;
    var last: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0) last = line;
    }
    var fields = std.mem.tokenizeAny(u8, last orelse return null, " \t");
    _ = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    return std.fmt.parseUnsigned(u64, fields.next() orelse return null, 10) catch null;
}

fn substituteArtifactArgv(allocator: std.mem.Allocator, argv: []const []const u8, artifact_path: []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, argv.len);
    for (argv, 0..) |arg, index| result[index] = if (std.mem.eql(u8, arg, recipe_schema.artifact_placeholder)) artifact_path else arg;
    return result;
}

fn verifyArtifactHash(io: std.Io, allocator: std.mem.Allocator, host: []const u8, path: []const u8, expected: []const u8, execution: @import("../../remote/options.zig").ExecutionOptions) !void {
    const digest = try remote_file.sha256FileWithOptions(io, allocator, host, path, execution);
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, expected)) return error.ReinstallArtifactChecksumMismatch;
}

fn verifyArtifactSize(io: std.Io, allocator: std.mem.Allocator, host: []const u8, path: []const u8, expected: u64, execution: @import("../../remote/options.zig").ExecutionOptions) !void {
    var argv = [_][]const u8{ "stat", "-c", "%s", "--", path };
    const output = try remote_exec.commandOutputWithOptions(io, allocator, host, &argv, execution, 1024);
    defer allocator.free(output);
    const actual = std.fmt.parseUnsigned(u64, std.mem.trim(u8, output, " \t\r\n"), 10) catch return error.ReinstallArtifactSizeUnavailable;
    if (actual != expected) return error.ReinstallArtifactSizeMismatch;
}

fn execute(ctx: handler.ApplyContext, action_id: []const u8, argv: []const []const u8) !void {
    const command_plan = try remote_planner.buildCommandPlanWithOptions(ctx.target_host, argv, ctx.options.execution);
    try ctx.stdout.print("  - {s}: ", .{action_id});
    try remote_exec.executePlan(ctx.io, ctx.allocator, command_plan, ctx.stdout, ctx.stderr);
}

test "os-release parser and architecture normalization are strict" {
    const contents = "NAME=Ubuntu\nID=ubuntu\nVERSION_ID=\"24.04\"\n";
    try std.testing.expectEqualStrings("ubuntu", osReleaseValue(contents, "ID").?);
    try std.testing.expectEqualStrings("24.04", osReleaseValue(contents, "VERSION_ID").?);
    try std.testing.expectEqualStrings("x86_64", normalizeArch("amd64"));
    try std.testing.expectEqual(@as(u64, 999_999), parseDfAvailable(
        "Filesystem 1B-blocks Used Available Capacity Mounted on\n/dev/fake 1000000 1 999999 1% /\n",
    ).?);
}
