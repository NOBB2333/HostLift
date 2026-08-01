const std = @import("std");
const manifest_hash = @import("../manifest/hash.zig");
const plan_filter = @import("../plan/filter.zig");
const plan_schema = @import("../plan/schema.zig");
const validation = @import("../security/validation.zig");
const fs_util = @import("../util/fs.zig");

pub const schema_version = "hostlift.apply.run_state.v1";
const max_state_bytes = 64 * 1024 * 1024;

// 迁移 action 的持久状态；skipped 只用于记录恢复时跳过了已证明成功的 action。
pub const ActionStatus = enum {
    started,
    rollback_prepared,
    succeeded,
    failed,
    skipped,
};

const RecordType = enum {
    run,
    action,
};

const Record = struct {
    schema_version: []const u8,
    record_type: RecordType,
    run_id: []const u8,
    timestamp: i64,
    plan_hash: ?[]const u8 = null,
    host: ?[]const u8 = null,
    selection_hash: ?[]const u8 = null,
    rollback_manifest: ?[]const u8 = null,
    action_id: ?[]const u8 = null,
    status: ?ActionStatus = null,
    error_name: ?[]const u8 = null,
    prev_event_hash: ?[]const u8 = null,
    event_hash: ?[]const u8 = null,
};

// 恢复运行时必须与状态文件头完全一致的执行身份。
pub const Expected = struct {
    plan_hash: []const u8,
    host: []const u8,
    selection_hash: []const u8,
};

// 持有迁移状态文件锁、hash chain 和各 action 的最后状态。
pub const Session = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    writer: std.Io.File.Writer,
    path: []u8,
    run_id: []u8,
    rollback_manifest_path: []u8,
    previous_hash: ?[64]u8 = null,
    statuses: std.StringHashMap(ActionStatus),
    rollback_prepared: std.StringHashMap(void),

    // 关闭状态文件并释放解析出的运行元数据。
    pub fn deinit(self: *Session) void {
        self.writer.interface.flush() catch {};
        self.file.unlock(self.io);
        self.file.close(self.io);
        var iterator = self.statuses.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.statuses.deinit();
        var prepared_iterator = self.rollback_prepared.iterator();
        while (prepared_iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.rollback_prepared.deinit();
        self.allocator.free(self.rollback_manifest_path);
        self.allocator.free(self.run_id);
        self.allocator.free(self.path);
    }

    // 判断 action 是否已有成功或安全跳过证据。
    pub fn isCompleted(self: Session, action_id: []const u8) bool {
        const status = self.statuses.get(action_id) orelse return false;
        return status == .succeeded or status == .skipped;
    }

    // 判断 action 是否已完成 rollback 预备，恢复时据此保留首次备份证据。
    pub fn isRollbackPrepared(self: Session, action_id: []const u8) bool {
        return self.rollback_prepared.contains(action_id);
    }

    // 返回已完成 action id 的临时切片，调用方只释放切片本身。
    pub fn completedActionIdsAlloc(self: Session, allocator: std.mem.Allocator) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(allocator);
        var iterator = self.statuses.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* == .succeeded or entry.value_ptr.* == .skipped) {
                try result.append(allocator, entry.key_ptr.*);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    // 追加 action 状态并立即 flush；成功状态只有在 apply 和 verify 都完成后才允许写入。
    pub fn appendAction(self: *Session, action_id: []const u8, status: ActionStatus, error_name: ?[]const u8) !void {
        if (status == .skipped and !self.isCompleted(action_id)) return error.UnprovenSkippedAction;
        const record = Record{
            .schema_version = schema_version,
            .record_type = .action,
            .run_id = self.run_id,
            .timestamp = std.Io.Timestamp.now(self.io, .real).toSeconds(),
            .action_id = action_id,
            .status = status,
            .error_name = error_name,
        };
        try appendRecord(self.allocator, &self.writer.interface, &self.previous_hash, record);
        if (status == .rollback_prepared) {
            try rememberPrepared(self, action_id);
        } else {
            try rememberStatus(self, action_id, status);
        }
    }
};

// 计算选中 action 集合的稳定 SHA-256；恢复时同一 plan 使用不同选择集合会失败关闭。
pub fn selectionHashAlloc(
    allocator: std.mem.Allocator,
    actions: []const plan_schema.Action,
    filter: plan_filter.ActionFilter,
) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    for (actions) |action| {
        if (!filter.matches(action)) continue;
        try bytes.appendSlice(allocator, action.id);
        try bytes.append(allocator, 0);
        try bytes.appendSlice(allocator, @tagName(action.module));
        try bytes.append(allocator, 0);
        try bytes.appendSlice(allocator, @tagName(action.action_type));
        try bytes.append(allocator, '\n');
    }
    return manifest_hash.sha256BytesHexAlloc(allocator, bytes.items);
}

// 在任何远程 preflight 前检查显式新状态路径没有被占用；真正创建时仍使用 exclusive 防竞争。
pub fn ensureNewPathAvailable(io: std.Io, requested_path: ?[]const u8) !void {
    const path = requested_path orelse return;
    try validatePath(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.RunStateAlreadyExists;
}

// 独占创建新的迁移状态文件并写入绑定 plan、host、选择集合和 rollback manifest 的头记录。
pub fn create(
    io: std.Io,
    allocator: std.mem.Allocator,
    requested_path: ?[]const u8,
    expected: Expected,
    rollback_manifest_path: []const u8,
    timestamp: i64,
    writer_buffer: []u8,
) !Session {
    const path = if (requested_path) |value|
        try allocator.dupe(u8, value)
    else
        try defaultPathAlloc(io, allocator, timestamp);
    errdefer allocator.free(path);
    try validatePath(path);
    try validatePath(rollback_manifest_path);

    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.RunStateAlreadyExists,
        else => return err,
    };
    errdefer file.close(io);
    try file.lock(io, .exclusive);
    errdefer file.unlock(io);

    const run_id = try randomRunIdAlloc(io, allocator);
    errdefer allocator.free(run_id);
    const rollback_path = try allocator.dupe(u8, rollback_manifest_path);
    errdefer allocator.free(rollback_path);
    var session = Session{
        .io = io,
        .allocator = allocator,
        .file = file,
        .writer = file.writer(io, writer_buffer),
        .path = path,
        .run_id = run_id,
        .rollback_manifest_path = rollback_path,
        .statuses = std.StringHashMap(ActionStatus).init(allocator),
        .rollback_prepared = std.StringHashMap(void).init(allocator),
    };
    errdefer {
        session.statuses.deinit();
        session.rollback_prepared.deinit();
    }

    try appendRecord(allocator, &session.writer.interface, &session.previous_hash, .{
        .schema_version = schema_version,
        .record_type = .run,
        .run_id = session.run_id,
        .timestamp = timestamp,
        .plan_hash = expected.plan_hash,
        .host = expected.host,
        .selection_hash = expected.selection_hash,
        .rollback_manifest = rollback_manifest_path,
    });
    return session;
}

// 打开并验证已有迁移状态；hash chain、plan、host 或选择集合不匹配时拒绝恢复。
pub fn openForResume(
    io: std.Io,
    allocator: std.mem.Allocator,
    path_value: []const u8,
    expected: Expected,
    selected_actions: []const plan_schema.Action,
    filter: plan_filter.ActionFilter,
    writer_buffer: []u8,
) !Session {
    try validatePath(path_value);
    const path = try allocator.dupe(u8, path_value);
    errdefer allocator.free(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return error.RunStateNotFound,
        else => return err,
    };
    errdefer file.close(io);
    try file.lock(io, .exclusive);
    errdefer file.unlock(io);

    var reader = file.readerStreaming(io, &.{});
    const state_bytes = reader.interface.allocRemaining(allocator, .limited(max_state_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.StreamTooLong => return error.RunStateTooLarge,
        else => return err,
    };
    defer allocator.free(state_bytes);

    const stat = try file.stat(io);
    var session = try parseSession(io, allocator, file, path, state_bytes, writer_buffer, expected, selected_actions, filter);
    session.writer.seekTo(stat.size) catch |err| {
        deinitStatuses(allocator, &session.statuses);
        deinitPrepared(allocator, &session.rollback_prepared);
        allocator.free(session.rollback_manifest_path);
        allocator.free(session.run_id);
        return err;
    };
    return session;
}

fn parseSession(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    path: []u8,
    state_bytes: []const u8,
    writer_buffer: []u8,
    expected: Expected,
    selected_actions: []const plan_schema.Action,
    filter: plan_filter.ActionFilter,
) !Session {
    var run_id: ?[]u8 = null;
    errdefer if (run_id) |value| allocator.free(value);
    var rollback_path: ?[]u8 = null;
    errdefer if (rollback_path) |value| allocator.free(value);
    var previous_hash: ?[64]u8 = null;
    var statuses = std.StringHashMap(ActionStatus).init(allocator);
    errdefer deinitStatuses(allocator, &statuses);
    var rollback_prepared = std.StringHashMap(void).init(allocator);
    errdefer deinitPrepared(allocator, &rollback_prepared);
    var records: usize = 0;

    var lines = std.mem.splitScalar(u8, state_bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(Record, allocator, line, .{}) catch return error.InvalidRunState;
        defer parsed.deinit();
        const record = parsed.value;
        try verifyRecord(allocator, record, previous_hash);
        previous_hash = try requiredHash(record.event_hash);

        if (records == 0) {
            if (record.record_type != .run) return error.InvalidRunState;
            try validateRunRecord(record);
            if (!std.mem.eql(u8, record.plan_hash.?, expected.plan_hash)) return error.RunStatePlanMismatch;
            if (!std.mem.eql(u8, record.host.?, expected.host)) return error.RunStateHostMismatch;
            if (!std.mem.eql(u8, record.selection_hash.?, expected.selection_hash)) return error.RunStateSelectionMismatch;
            run_id = try allocator.dupe(u8, record.run_id);
            rollback_path = try allocator.dupe(u8, record.rollback_manifest.?);
        } else {
            if (record.record_type != .action or record.action_id == null or record.status == null) return error.InvalidRunState;
            try validateActionRecord(record);
            if (!std.mem.eql(u8, record.run_id, run_id.?)) return error.InvalidRunState;
            if (!selectedActionExists(selected_actions, filter, record.action_id.?)) return error.RunStateSelectionMismatch;
            if (record.status.? == .rollback_prepared) {
                try rememberPreparedInMap(allocator, &rollback_prepared, record.action_id.?);
            } else {
                const existing = statuses.get(record.action_id.?);
                if (record.status.? == .skipped and (existing == null or (existing.? != .succeeded and existing.? != .skipped))) return error.InvalidRunStateTransition;
                try rememberStatusInMap(allocator, &statuses, record.action_id.?, record.status.?);
            }
        }
        records += 1;
    }
    if (records == 0 or run_id == null or rollback_path == null or previous_hash == null) return error.InvalidRunState;
    try validatePath(rollback_path.?);

    return .{
        .io = io,
        .allocator = allocator,
        .file = file,
        .writer = file.writer(io, writer_buffer),
        .path = path,
        .run_id = run_id.?,
        .rollback_manifest_path = rollback_path.?,
        .previous_hash = previous_hash,
        .statuses = statuses,
        .rollback_prepared = rollback_prepared,
    };
}

fn validateRunRecord(record: Record) !void {
    if (!std.mem.eql(u8, record.schema_version, schema_version)) return error.UnsupportedRunStateSchema;
    if (record.plan_hash == null or record.host == null or record.selection_hash == null or record.rollback_manifest == null) return error.InvalidRunState;
    if (record.action_id != null or record.status != null or record.error_name != null) return error.InvalidRunState;
    _ = try manifest_hash.parseSha256Hex(record.plan_hash.?);
    _ = try manifest_hash.parseSha256Hex(record.selection_hash.?);
    try validateRunId(record.run_id);
}

fn validateActionRecord(record: Record) !void {
    if (record.plan_hash != null or record.host != null or record.selection_hash != null or record.rollback_manifest != null) return error.InvalidRunState;
    try validateRunId(record.run_id);
    switch (record.status.?) {
        .started, .rollback_prepared, .succeeded, .skipped => if (record.error_name != null) return error.InvalidRunState,
        .failed => if (record.error_name == null or record.error_name.?.len == 0) return error.InvalidRunState,
    }
}

fn verifyRecord(allocator: std.mem.Allocator, record: Record, previous_hash: ?[64]u8) !void {
    if (!std.mem.eql(u8, record.schema_version, schema_version)) return error.UnsupportedRunStateSchema;
    if (!matchesOptionalHash(record.prev_event_hash, previous_hash)) return error.RunStateHashChainMismatch;
    const actual_hash = try requiredHash(record.event_hash);
    const expected_hash = try hashRecord(allocator, record, previous_hash);
    if (!std.mem.eql(u8, &actual_hash, &expected_hash)) return error.RunStateHashMismatch;
}

fn appendRecord(allocator: std.mem.Allocator, writer: *std.Io.Writer, previous_hash: *?[64]u8, record: Record) !void {
    const event_hash = try hashRecord(allocator, record, previous_hash.*);
    try writeRecord(writer, record, previous_hash.*, event_hash);
    try writer.flush();
    previous_hash.* = event_hash;
}

fn hashRecord(allocator: std.mem.Allocator, record: Record, previous_hash: ?[64]u8) ![64]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &bytes);
    try writeRecord(&writer.writer, record, previous_hash, null);
    bytes = writer.toArrayList();
    const hash_text = try manifest_hash.sha256BytesHexAlloc(allocator, bytes.items);
    defer allocator.free(hash_text);
    var result: [64]u8 = undefined;
    @memcpy(&result, hash_text);
    return result;
}

fn writeRecord(writer: anytype, record: Record, previous_hash: ?[64]u8, event_hash: ?[64]u8) !void {
    const JsonRecord = struct {
        schema_version: []const u8,
        record_type: []const u8,
        run_id: []const u8,
        timestamp: i64,
        plan_hash: ?[]const u8,
        host: ?[]const u8,
        selection_hash: ?[]const u8,
        rollback_manifest: ?[]const u8,
        action_id: ?[]const u8,
        status: ?[]const u8,
        error_name: ?[]const u8,
        prev_event_hash: ?[]const u8,
        event_hash: ?[]const u8,
    };
    try std.json.Stringify.value(JsonRecord{
        .schema_version = record.schema_version,
        .record_type = @tagName(record.record_type),
        .run_id = record.run_id,
        .timestamp = record.timestamp,
        .plan_hash = record.plan_hash,
        .host = record.host,
        .selection_hash = record.selection_hash,
        .rollback_manifest = record.rollback_manifest,
        .action_id = record.action_id,
        .status = if (record.status) |status| @tagName(status) else null,
        .error_name = record.error_name,
        .prev_event_hash = if (previous_hash) |hash| &hash else null,
        .event_hash = if (event_hash) |hash| &hash else null,
    }, .{}, writer);
    try writer.writeByte('\n');
}

fn matchesOptionalHash(value: ?[]const u8, expected: ?[64]u8) bool {
    if (value) |text| {
        const hash = expected orelse return false;
        return std.mem.eql(u8, text, &hash);
    }
    return expected == null;
}

fn requiredHash(value: ?[]const u8) ![64]u8 {
    const text = value orelse return error.InvalidRunState;
    _ = manifest_hash.parseSha256Hex(text) catch return error.InvalidRunStateHash;
    var hash: [64]u8 = undefined;
    @memcpy(&hash, text);
    return hash;
}

fn rememberStatus(session: *Session, action_id: []const u8, status: ActionStatus) !void {
    try rememberStatusInMap(session.allocator, &session.statuses, action_id, status);
}

fn rememberPrepared(session: *Session, action_id: []const u8) !void {
    try rememberPreparedInMap(session.allocator, &session.rollback_prepared, action_id);
}

fn rememberStatusInMap(allocator: std.mem.Allocator, statuses: *std.StringHashMap(ActionStatus), action_id: []const u8, status: ActionStatus) !void {
    if (statuses.getPtr(action_id)) |existing| {
        existing.* = status;
        return;
    }
    const owned_id = try allocator.dupe(u8, action_id);
    errdefer allocator.free(owned_id);
    try statuses.put(owned_id, status);
}

fn deinitStatuses(allocator: std.mem.Allocator, statuses: *std.StringHashMap(ActionStatus)) void {
    var iterator = statuses.iterator();
    while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
    statuses.deinit();
}

fn rememberPreparedInMap(allocator: std.mem.Allocator, prepared: *std.StringHashMap(void), action_id: []const u8) !void {
    if (prepared.contains(action_id)) return;
    const owned_id = try allocator.dupe(u8, action_id);
    errdefer allocator.free(owned_id);
    try prepared.put(owned_id, {});
}

fn deinitPrepared(allocator: std.mem.Allocator, prepared: *std.StringHashMap(void)) void {
    var iterator = prepared.iterator();
    while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
    prepared.deinit();
}

fn selectedActionExists(actions: []const plan_schema.Action, filter: plan_filter.ActionFilter, action_id: []const u8) bool {
    for (actions) |action| {
        if (filter.matches(action) and std.mem.eql(u8, action.id, action_id)) return true;
    }
    return false;
}

fn validatePath(path: []const u8) !void {
    validation.validatePath(path) catch return error.InvalidRunStatePath;
    if (path.len == 0) return error.InvalidRunStatePath;
}

fn validateRunId(run_id: []const u8) !void {
    if (run_id.len != 32) return error.InvalidRunState;
    for (run_id) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidRunState;
    }
}

fn randomRunIdAlloc(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    const text = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &text);
}

fn defaultPathAlloc(io: std.Io, allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    var bytes: [8]u8 = undefined;
    try io.randomSecure(&bytes);
    const nonce = std.mem.readInt(u64, &bytes, .little);
    return std.fmt.allocPrint(allocator, "/tmp/hostlift-run-{d}-{x}.jsonl", .{ timestamp, nonce });
}

test "selection hash binds the selected action set" {
    const actions = [_]plan_schema.Action{
        .{ .id = "packages/install/nginx", .module = .packages, .action_type = .install_package, .description = "install", .risk = .low, .requires_confirmation = false },
        .{ .id = "services/enable/nginx", .module = .services, .action_type = .enable_systemd_unit, .description = "enable", .risk = .low, .requires_confirmation = false },
    };
    const all_hash = try selectionHashAlloc(std.testing.allocator, &actions, .empty);
    defer std.testing.allocator.free(all_hash);
    var filter: plan_filter.ActionFilter = .empty;
    defer filter.deinit(std.testing.allocator);
    try filter.appendModuleList(std.testing.allocator, .include, "packages");
    const package_hash = try selectionHashAlloc(std.testing.allocator, &actions, filter);
    defer std.testing.allocator.free(package_hash);
    try std.testing.expect(!std.mem.eql(u8, all_hash, package_hash));
}

test "run state resumes only matching runs and skips proven successes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/run.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(state_path);
    const rollback_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/rollback.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(rollback_path);
    const actions = [_]plan_schema.Action{
        .{ .id = "packages/install/nginx", .module = .packages, .action_type = .install_package, .description = "install", .risk = .low, .requires_confirmation = false },
        .{ .id = "services/enable/nginx", .module = .services, .action_type = .enable_systemd_unit, .description = "enable", .risk = .low, .requires_confirmation = false },
    };
    const selection_hash = try selectionHashAlloc(std.testing.allocator, &actions, .empty);
    defer std.testing.allocator.free(selection_hash);
    const expected = Expected{
        .plan_hash = "ab" ** 32,
        .host = "root@192.0.2.10",
        .selection_hash = selection_hash,
    };

    var create_buffer: [4096]u8 = undefined;
    var created = try create(std.testing.io, std.testing.allocator, state_path, expected, rollback_path, 123, &create_buffer);
    try created.appendAction(actions[0].id, .started, null);
    try created.appendAction(actions[0].id, .rollback_prepared, null);
    try created.appendAction(actions[0].id, .succeeded, null);
    try created.appendAction(actions[1].id, .started, null);
    try created.appendAction(actions[1].id, .failed, "RemoteCommandFailed");
    created.deinit();

    var resume_buffer: [4096]u8 = undefined;
    var resumed = try openForResume(std.testing.io, std.testing.allocator, state_path, expected, &actions, .empty, &resume_buffer);
    try std.testing.expect(resumed.isCompleted(actions[0].id));
    try std.testing.expect(resumed.isRollbackPrepared(actions[0].id));
    try std.testing.expect(!resumed.isCompleted(actions[1].id));
    try resumed.appendAction(actions[0].id, .skipped, null);
    resumed.deinit();

    var mismatch_buffer: [4096]u8 = undefined;
    try std.testing.expectError(
        error.RunStateHostMismatch,
        openForResume(std.testing.io, std.testing.allocator, state_path, .{
            .plan_hash = expected.plan_hash,
            .host = "root@192.0.2.99",
            .selection_hash = expected.selection_hash,
        }, &actions, .empty, &mismatch_buffer),
    );

    var plan_mismatch_buffer: [4096]u8 = undefined;
    try std.testing.expectError(
        error.RunStatePlanMismatch,
        openForResume(std.testing.io, std.testing.allocator, state_path, .{
            .plan_hash = "cd" ** 32,
            .host = expected.host,
            .selection_hash = expected.selection_hash,
        }, &actions, .empty, &plan_mismatch_buffer),
    );

    var package_filter: plan_filter.ActionFilter = .empty;
    defer package_filter.deinit(std.testing.allocator);
    try package_filter.appendModuleList(std.testing.allocator, .include, "packages");
    const package_selection_hash = try selectionHashAlloc(std.testing.allocator, &actions, package_filter);
    defer std.testing.allocator.free(package_selection_hash);
    var selection_mismatch_buffer: [4096]u8 = undefined;
    try std.testing.expectError(
        error.RunStateSelectionMismatch,
        openForResume(std.testing.io, std.testing.allocator, state_path, .{
            .plan_hash = expected.plan_hash,
            .host = expected.host,
            .selection_hash = package_selection_hash,
        }, &actions, package_filter, &selection_mismatch_buffer),
    );

    const state_bytes = try fs_util.readFileAlloc(std.testing.io, std.testing.allocator, state_path, max_state_bytes);
    defer std.testing.allocator.free(state_bytes);
    const action_offset = std.mem.indexOf(u8, state_bytes, "packages/install/nginx") orelse return error.MissingTestAction;
    var tamper_file = try std.Io.Dir.cwd().openFile(std.testing.io, state_path, .{ .mode = .read_write });
    try tamper_file.writePositionalAll(std.testing.io, "X", action_offset + "packages/install/ngin".len);
    tamper_file.close(std.testing.io);
    var tamper_buffer: [4096]u8 = undefined;
    try std.testing.expectError(
        error.RunStateHashMismatch,
        openForResume(std.testing.io, std.testing.allocator, state_path, expected, &actions, .empty, &tamper_buffer),
    );
}
