const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");
const users_scanner = @import("users.zig");

// 扫描常见应用、数据、数据库和 home 数据路径。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.AppDataInventory {
    var paths: std.ArrayList(schema.DataPath) = .empty;
    errdefer {
        for (paths.items) |path| freePath(allocator, path);
        paths.deinit(allocator);
    }

    try appendPath(io, allocator, &paths, .{ .path = "/srv", .kind = .app_data });
    try appendPath(io, allocator, &paths, .{ .path = "/opt", .kind = .app_data });
    try appendPath(io, allocator, &paths, .{ .path = "/var/www", .kind = .web_root });
    try appendPath(io, allocator, &paths, statefulPath("/var/lib/mysql", "mysql/mariadb", "mysqldump --single-transaction --all-databases > mysql-all.sql; use mariabackup/xtrabackup for very large datasets", "restore with mysql < mysql-all.sql or the matching physical backup restore flow", "stop writes or use transaction-safe dump; capture users, grants, config, binlog position if replication matters"));
    try appendPath(io, allocator, &paths, statefulPath("/var/lib/postgresql", "postgresql", "pg_dumpall > postgres-all.sql, or pg_dump per database for selective restore", "restore with psql -f postgres-all.sql after matching major version and roles review", "avoid hot-copying PGDATA; use dump, pg_basebackup, or storage snapshot with PostgreSQL consistency rules"));
    try appendPath(io, allocator, &paths, statefulPath("/var/lib/redis", "redis", "redis-cli SAVE or BGSAVE, then capture RDB/AOF after writes are stopped or quiesced", "restore by placing dump.rdb/AOF files with matching redis.conf and ownership", "confirm appendonly/RDB settings and stop writes before copying persistence files"));
    try appendPath(io, allocator, &paths, statefulPath("/var/lib/mongodb", "mongodb", "mongodump --oplog --out <dir> for replica set, or filesystem snapshot with fsync/lock discipline", "restore with mongorestore, using --oplogReplay when applicable", "do not hot-copy WiredTiger files without MongoDB-consistent backup procedure"));
    try appendPath(io, allocator, &paths, statefulPath("/var/lib/elasticsearch", "elasticsearch", "create repository snapshot with the Elasticsearch snapshot API", "restore snapshot into a compatible cluster and review index settings/plugins", "do not copy live data directories between clusters as the primary migration path"));
    try appendPath(io, allocator, &paths, statefulPath("/var/lib/rabbitmq", "rabbitmq", "rabbitmqctl export_definitions plus message durability/snapshot plan if queues must be preserved", "restore definitions with rabbitmqctl import_definitions and restore data only from a stopped consistent backup", "review Erlang cookie, vhost/user/policy definitions, plugins and queue durability"));
    try appendPath(io, allocator, &paths, statefulPath("/var/lib/kafka", "kafka", "prefer MirrorMaker/replication or stop brokers and take a consistent log directory snapshot", "restore only with matching cluster metadata, broker ids and log directory ownership", "Kafka log dirs are not portable hot-copy state; plan broker downtime or replication"));
    try appendPath(io, allocator, &paths, .{
        .path = "/var/lib/docker/volumes",
        .kind = .docker_data,
        .engine_hint = "docker/podman volumes",
        .dump_hint = "stop writers, compose down, or take application-level dumps before archiving volume mountpoints",
        .restore_hint = "recreate volume definitions first, then restore contents with ownership and labels reviewed",
        .consistency_hint = "running containers can keep writing; use docker/stop-writers plan step when volume is mounted",
    });

    const users = try users_scanner.parsePasswd(io, allocator);
    defer users_scanner.freeUsers(allocator, users);

    for (users) |user| {
        if (user.system) continue;
        if (user.home.len == 0 or std.mem.eql(u8, user.home, "/nonexistent")) continue;
        try appendPath(io, allocator, &paths, .{ .path = user.home, .kind = .home_data });
    }

    return .{ .paths = try paths.toOwnedSlice(allocator) };
}

fn freePath(allocator: std.mem.Allocator, path: schema.DataPath) void {
    allocator.free(path.path);
    if (path.engine_hint) |hint| allocator.free(hint);
    if (path.dump_hint) |hint| allocator.free(hint);
    if (path.restore_hint) |hint| allocator.free(hint);
    if (path.consistency_hint) |hint| allocator.free(hint);
}

// 检查并追加应用/数据路径记录。
fn appendPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: *std.ArrayList(schema.DataPath),
    input: DataPathInput,
) !void {
    const maybe_size = probe.fileSize(io, input.path);
    try paths.append(allocator, .{
        .path = try allocator.dupe(u8, input.path),
        .present = probe.pathExists(io, input.path),
        .kind = input.kind,
        .size = maybe_size orelse 0,
        .engine_hint = if (input.engine_hint) |hint| try allocator.dupe(u8, hint) else null,
        .dump_hint = if (input.dump_hint) |hint| try allocator.dupe(u8, hint) else null,
        .restore_hint = if (input.restore_hint) |hint| try allocator.dupe(u8, hint) else null,
        .consistency_hint = if (input.consistency_hint) |hint| try allocator.dupe(u8, hint) else null,
    });
}

const DataPathInput = struct {
    path: []const u8,
    kind: schema.DataPathKind,
    engine_hint: ?[]const u8 = null,
    dump_hint: ?[]const u8 = null,
    restore_hint: ?[]const u8 = null,
    consistency_hint: ?[]const u8 = null,
};

fn statefulPath(
    path: []const u8,
    engine_hint: []const u8,
    dump_hint: []const u8,
    restore_hint: []const u8,
    consistency_hint: []const u8,
) DataPathInput {
    return .{
        .path = path,
        .kind = .database_data,
        .engine_hint = engine_hint,
        .dump_hint = dump_hint,
        .restore_hint = restore_hint,
        .consistency_hint = consistency_hint,
    };
}
