const std = @import("std");
const options_mod = @import("options.zig");
const runner = @import("runner.zig");
const ssh_argv = @import("ssh_argv.zig");
const validation = @import("../security/validation.zig");

pub const Query = enum {
    server_version_num,
    client_count,
    custom_database_count,
    custom_role_count,
    database_bytes,
    data_directory,
    postgres_admin_count,
    database_catalog,
    role_catalog,
};

pub const RestoreResult = struct {
    allowed_bootstrap_conflicts: usize,
};

// 执行封闭枚举中的 PostgreSQL 只读查询；SQL 不能由 inventory、plan 或调用方自由传入。
pub fn queryOutput(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    query: Query,
    options: options_mod.ExecutionOptions,
    stdout_limit: usize,
) ![]u8 {
    try validation.validateHost(host);
    const normalized = try options_mod.normalize(options);
    const fixed_argv = [_][]const u8{
        "sudo",
        "-n",
        "-u",
        "postgres",
        "env",
        "LC_ALL=C",
        "psql",
        "--no-psqlrc",
        "--tuples-only",
        "--no-align",
        "--set=ON_ERROR_STOP=1",
        "--set=VERBOSITY=terse",
        "--dbname=postgres",
        "--command",
        sqlForQuery(query),
    };
    const command = try quoteCommandAlloc(allocator, &fixed_argv);
    defer allocator.free(command);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try ssh_argv.appendSshPrefix(allocator, &argv, normalized.ssh_identity_file, null, host);
    try argv.append(allocator, command);
    return runner.runForOutput(io, allocator, argv.items, normalized.timeout_seconds, stdout_limit);
}

// 从受控 dump artifact 恢复 PostgreSQL，并拒绝除 fresh cluster 的 postgres role/database 冲突之外的全部 SQL 错误。
pub fn restoreCluster(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    dump_path: []const u8,
    options: options_mod.ExecutionOptions,
) !RestoreResult {
    try validation.validateHost(host);
    try validation.validatePath(dump_path);
    const normalized = try options_mod.normalize(options);

    var remote_argv = [_][]const u8{
        "sudo",
        "-n",
        "-u",
        "postgres",
        "env",
        "LC_ALL=C",
        "psql",
        "--no-psqlrc",
        "--set=ON_ERROR_STOP=0",
        "--set=VERBOSITY=terse",
        "--file",
        dump_path,
        "postgres",
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try ssh_argv.appendSshPrefix(allocator, &argv, normalized.ssh_identity_file, null, host);
    try argv.appendSlice(allocator, &remote_argv);

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(8 * 1024 * 1024),
        .timeout = options_mod.ioTimeout(normalized.timeout_seconds),
    }) catch |err| switch (err) {
        error.Timeout => return error.RemoteCommandTimedOut,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.PostgresqlRestoreCommandFailed,
        else => return error.PostgresqlRestoreCommandFailed,
    }
    return .{ .allowed_bootstrap_conflicts = try validateRestoreStderr(result.stderr) };
}

fn sqlForQuery(query: Query) []const u8 {
    return switch (query) {
        .server_version_num => "SHOW server_version_num",
        .client_count => "SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND backend_type = 'client backend'",
        .custom_database_count => "SELECT count(*) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'",
        .custom_role_count => "SELECT count(*) FROM pg_roles WHERE rolname <> 'postgres' AND left(rolname, 3) <> 'pg_'",
        .database_bytes => "SELECT COALESCE(sum(pg_database_size(datname)), 0) FROM pg_database WHERE datallowconn",
        .data_directory => "SHOW data_directory",
        .postgres_admin_count => "SELECT count(*) FROM pg_roles WHERE rolname = 'postgres' AND rolsuper AND rolcanlogin",
        .database_catalog => "SELECT COALESCE(json_agg(datname ORDER BY datname)::text, '[]') FROM pg_database WHERE NOT datistemplate",
        .role_catalog => "SELECT COALESCE(json_agg(rolname ORDER BY rolname)::text, '[]') FROM pg_roles WHERE left(rolname, 3) <> 'pg_'",
    };
}

fn quoteCommandAlloc(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try result.append(allocator, ' ');
        try appendPosixQuoted(allocator, &result, arg);
    }
    return result.toOwnedSlice(allocator);
}

fn appendPosixQuoted(allocator: std.mem.Allocator, output: *std.ArrayList(u8), arg: []const u8) !void {
    try output.append(allocator, '\'');
    for (arg) |byte| {
        if (byte == '\'') {
            try output.appendSlice(allocator, "'\"'\"'");
        } else {
            try output.append(allocator, byte);
        }
    }
    try output.append(allocator, '\'');
}

fn validateRestoreStderr(stderr: []const u8) !usize {
    var allowed: usize = 0;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const marker = std.mem.indexOf(u8, line, "ERROR:") orelse continue;
        const message = std.mem.trim(u8, line[marker + "ERROR:".len ..], " \t");
        if (std.mem.eql(u8, message, "role \"postgres\" already exists") or
            std.mem.eql(u8, message, "database \"postgres\" already exists"))
        {
            allowed += 1;
            continue;
        }
        return error.PostgresqlRestoreSqlError;
    }
    return allowed;
}

test "postgresql fixed query command quotes SQL as one remote shell argument" {
    const command = try quoteCommandAlloc(std.testing.allocator, &.{ "psql", "--command", "SELECT 'value'" });
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("'psql' '--command' 'SELECT '\"'\"'value'\"'\"''", command);
}

test "postgresql restore stderr only permits fresh cluster bootstrap conflicts" {
    try std.testing.expectEqual(@as(usize, 2), try validateRestoreStderr(
        "psql: ERROR: role \"postgres\" already exists\npsql: ERROR: database \"postgres\" already exists\n",
    ));
    try std.testing.expectError(
        error.PostgresqlRestoreSqlError,
        validateRestoreStderr("psql: ERROR: relation \"orders\" does not exist\n"),
    );
}
