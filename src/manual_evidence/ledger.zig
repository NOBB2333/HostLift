const std = @import("std");
const evidence_schema = @import("schema.zig");
const evidence_validator = @import("validator.zig");
const manifest_hash = @import("../manifest/hash.zig");
const plan_schema = @import("../plan/schema.zig");
const validation = @import("../security/validation.zig");
const fs_util = @import("../util/fs.zig");

pub const schema_version = "hostlift.manual_evidence.ledger.v1";
pub const verify_schema_version = "hostlift.manual_evidence.ledger.verify.v1";
const max_ledger_bytes = 64 * 1024 * 1024;

pub const TrustLevel = enum {
    hash_chain_only,
};

const RecordType = enum {
    ledger,
    evidence,
};

const Record = struct {
    schema_version: []const u8,
    record_type: RecordType,
    ledger_id: []const u8,
    timestamp: i64,
    plan_sha256: ?[]const u8 = null,
    action_id: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    task_kind: ?plan_schema.ManualTaskKind = null,
    operator: ?[]const u8 = null,
    evidence_recorded_at: ?i64 = null,
    evidence_sha256: ?[]const u8 = null,
    prev_event_hash: ?[]const u8 = null,
    event_hash: ?[]const u8 = null,
};

pub const VerifyReport = struct {
    schema_version: []const u8 = verify_schema_version,
    valid: bool,
    chain_valid: bool,
    plan_match: bool,
    trust_level: TrustLevel = .hash_chain_only,
    errors: u32,
    records: usize,
    evidence_records: usize,
    manual_actions: usize,
    missing_actions: usize,
    ledger_contract_complete: bool,
    ledger_id: ?[]const u8,
    plan_sha256: ?[]const u8,
    tail_hash: ?[]const u8,
    recorded_action_ids: []const []const u8,
    missing_action_ids: []const []const u8,

    // 释放 ledger verify 报告拥有的 hash、ledger id 和 action id 数组。
    pub fn deinit(self: *VerifyReport, allocator: std.mem.Allocator) void {
        if (self.ledger_id) |value| allocator.free(value);
        if (self.plan_sha256) |value| allocator.free(value);
        if (self.tail_hash) |value| allocator.free(value);
        freeStrings(allocator, self.recorded_action_ids);
        freeStrings(allocator, self.missing_action_ids);
    }
};

const State = struct {
    ledger_id: []u8,
    plan_sha256: []u8,
    previous_hash: [64]u8,
    records: usize,
    evidence_records: usize,
    actions: std.StringHashMap(void),

    fn deinit(self: *State, allocator: std.mem.Allocator) void {
        allocator.free(self.ledger_id);
        allocator.free(self.plan_sha256);
        var iterator = self.actions.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        self.actions.deinit();
    }
};

// 严格解析并校验原始 evidence 字节，再在独占锁下把其真实 SHA-256 追加到 ledger。
pub fn appendEvidenceBytes(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    plan: plan_schema.MigrationPlan,
    plan_sha256: []const u8,
    evidence_bytes: []const u8,
    timestamp: i64,
    writer_buffer: []u8,
) !void {
    const parsed_evidence = try std.json.parseFromSlice(evidence_schema.Evidence, allocator, evidence_bytes, .{ .ignore_unknown_fields = false });
    defer parsed_evidence.deinit();
    const evidence = parsed_evidence.value;
    if (!evidence_validator.validate(plan, plan_sha256, evidence).valid) return error.InvalidManualEvidence;
    const evidence_sha256 = try manifest_hash.sha256BytesHexAlloc(allocator, evidence_bytes);
    defer allocator.free(evidence_sha256);
    try validatePath(path);
    try validateEvidenceIdentity(plan, plan_sha256, evidence, evidence_sha256, timestamp);

    const file = try openOrCreate(io, path);
    defer file.close(io);
    try file.lock(io, .exclusive);
    defer file.unlock(io);

    var reader = file.readerStreaming(io, &.{});
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_ledger_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.StreamTooLong => return error.ManualEvidenceLedgerTooLarge,
        else => return err,
    };
    defer allocator.free(bytes);

    const stat = try file.stat(io);
    var writer = file.writer(io, writer_buffer);
    try writer.seekTo(stat.size);
    if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) {
        const ledger_id = try randomLedgerIdAlloc(io, allocator);
        defer allocator.free(ledger_id);
        var previous_hash: ?[64]u8 = null;
        try appendRecord(allocator, &writer.interface, &previous_hash, .{
            .schema_version = schema_version,
            .record_type = .ledger,
            .ledger_id = ledger_id,
            .timestamp = timestamp,
            .plan_sha256 = plan_sha256,
        });
        try appendEvidenceRecord(allocator, &writer.interface, &previous_hash, ledger_id, evidence, evidence_sha256, timestamp);
        return;
    }

    var state = try parseState(allocator, plan, plan_sha256, bytes);
    defer state.deinit(allocator);
    if (state.actions.contains(evidence.action_id)) return error.ManualEvidenceActionAlreadyRecorded;
    var previous_hash: ?[64]u8 = state.previous_hash;
    try appendEvidenceRecord(allocator, &writer.interface, &previous_hash, state.ledger_id, evidence, evidence_sha256, timestamp);
}

// 校验 ledger hash chain、plan/manual task 绑定和 action 唯一性，并报告尚未登记的 manual action。
pub fn verifyBytes(
    allocator: std.mem.Allocator,
    plan: plan_schema.MigrationPlan,
    plan_sha256: []const u8,
    bytes: []const u8,
) !VerifyReport {
    var state = parseState(allocator, plan, plan_sha256, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return invalidReport(allocator, plan),
    };
    defer state.deinit(allocator);

    var recorded: std.ArrayList([]const u8) = .empty;
    errdefer deinitStringList(allocator, &recorded);
    var missing: std.ArrayList([]const u8) = .empty;
    errdefer deinitStringList(allocator, &missing);
    var manual_actions: usize = 0;
    for (plan.actions) |action| {
        if (action.action_type != .manual_step) continue;
        manual_actions += 1;
        if (state.actions.contains(action.id)) {
            try recorded.append(allocator, try allocator.dupe(u8, action.id));
        } else {
            try missing.append(allocator, try allocator.dupe(u8, action.id));
        }
    }

    const recorded_slice = try recorded.toOwnedSlice(allocator);
    errdefer freeStrings(allocator, recorded_slice);
    const missing_slice = try missing.toOwnedSlice(allocator);
    errdefer freeStrings(allocator, missing_slice);
    const ledger_id = try allocator.dupe(u8, state.ledger_id);
    errdefer allocator.free(ledger_id);
    const bound_plan_hash = try allocator.dupe(u8, state.plan_sha256);
    errdefer allocator.free(bound_plan_hash);
    const tail_hash = try allocator.dupe(u8, &state.previous_hash);
    errdefer allocator.free(tail_hash);
    return .{
        .valid = true,
        .chain_valid = true,
        .plan_match = true,
        .errors = 0,
        .records = state.records,
        .evidence_records = state.evidence_records,
        .manual_actions = manual_actions,
        .missing_actions = missing_slice.len,
        .ledger_contract_complete = missing_slice.len == 0,
        .ledger_id = ledger_id,
        .plan_sha256 = bound_plan_hash,
        .tail_hash = tail_hash,
        .recorded_action_ids = recorded_slice,
        .missing_action_ids = missing_slice,
    };
}

// 持有共享文件锁读取并校验 ledger，避免与另一个 record 进程的追加发生半记录竞态。
pub fn verifyFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    plan: plan_schema.MigrationPlan,
    plan_sha256: []const u8,
) !VerifyReport {
    try validatePath(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ManualEvidenceLedgerNotFound,
        else => return err,
    };
    defer file.close(io);
    try file.lock(io, .shared);
    defer file.unlock(io);
    var reader = file.readerStreaming(io, &.{});
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_ledger_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.StreamTooLong => return error.ManualEvidenceLedgerTooLarge,
        else => return err,
    };
    defer allocator.free(bytes);
    return verifyBytes(allocator, plan, plan_sha256, bytes);
}

fn appendEvidenceRecord(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    previous_hash: *?[64]u8,
    ledger_id: []const u8,
    evidence: evidence_schema.Evidence,
    evidence_sha256: []const u8,
    timestamp: i64,
) !void {
    try appendRecord(allocator, writer, previous_hash, .{
        .schema_version = schema_version,
        .record_type = .evidence,
        .ledger_id = ledger_id,
        .timestamp = timestamp,
        .action_id = evidence.action_id,
        .provider = evidence.provider,
        .task_kind = evidence.task_kind,
        .operator = evidence.operator,
        .evidence_recorded_at = evidence.recorded_at,
        .evidence_sha256 = evidence_sha256,
    });
}

fn parseState(
    allocator: std.mem.Allocator,
    plan: plan_schema.MigrationPlan,
    plan_sha256: []const u8,
    bytes: []const u8,
) !State {
    var ledger_id: ?[]u8 = null;
    errdefer if (ledger_id) |value| allocator.free(value);
    var bound_plan_hash: ?[]u8 = null;
    errdefer if (bound_plan_hash) |value| allocator.free(value);
    var previous_hash: ?[64]u8 = null;
    var actions = std.StringHashMap(void).init(allocator);
    errdefer deinitActions(allocator, &actions);
    var records: usize = 0;
    var evidence_records: usize = 0;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(Record, allocator, line, .{ .ignore_unknown_fields = false }) catch return error.InvalidManualEvidenceLedger;
        defer parsed.deinit();
        const record = parsed.value;
        try verifyRecord(allocator, record, previous_hash);
        previous_hash = try requiredHash(record.event_hash);

        if (records == 0) {
            try validateHeaderRecord(record, plan_sha256);
            ledger_id = try allocator.dupe(u8, record.ledger_id);
            bound_plan_hash = try allocator.dupe(u8, record.plan_sha256.?);
        } else {
            try validateEvidenceRecord(record);
            if (!std.mem.eql(u8, record.ledger_id, ledger_id.?)) return error.ManualEvidenceLedgerIdMismatch;
            const action = findAction(plan.actions, record.action_id.?) orelse return error.ManualEvidenceLedgerActionMismatch;
            if (action.action_type != .manual_step) return error.ManualEvidenceLedgerActionMismatch;
            const task = action.manual_task orelse return error.ManualEvidenceLedgerActionMismatch;
            if (!std.mem.eql(u8, task.provider, record.provider.?) or task.kind != record.task_kind.?) return error.ManualEvidenceLedgerActionMismatch;
            if (actions.contains(record.action_id.?)) return error.ManualEvidenceLedgerDuplicateAction;
            const action_id = try allocator.dupe(u8, record.action_id.?);
            errdefer allocator.free(action_id);
            try actions.put(action_id, {});
            evidence_records += 1;
        }
        records += 1;
    }
    if (records == 0 or ledger_id == null or bound_plan_hash == null or previous_hash == null) return error.InvalidManualEvidenceLedger;

    return .{
        .ledger_id = ledger_id.?,
        .plan_sha256 = bound_plan_hash.?,
        .previous_hash = previous_hash.?,
        .records = records,
        .evidence_records = evidence_records,
        .actions = actions,
    };
}

fn validateEvidenceIdentity(
    plan: plan_schema.MigrationPlan,
    plan_sha256: []const u8,
    evidence: evidence_schema.Evidence,
    evidence_sha256: []const u8,
    timestamp: i64,
) !void {
    _ = manifest_hash.parseSha256Hex(plan_sha256) catch return error.InvalidManualEvidenceLedgerHash;
    _ = manifest_hash.parseSha256Hex(evidence_sha256) catch return error.InvalidManualEvidenceLedgerHash;
    if (!std.mem.eql(u8, evidence.plan_sha256, plan_sha256)) return error.ManualEvidenceLedgerPlanMismatch;
    if (timestamp <= 0 or evidence.recorded_at <= 0 or evidence.recorded_at > timestamp) return error.InvalidManualEvidenceLedgerTimestamp;
    const action = findAction(plan.actions, evidence.action_id) orelse return error.ManualEvidenceLedgerActionMismatch;
    if (action.action_type != .manual_step) return error.ManualEvidenceLedgerActionMismatch;
    const task = action.manual_task orelse return error.ManualEvidenceLedgerActionMismatch;
    if (!std.mem.eql(u8, task.provider, evidence.provider) or task.kind != evidence.task_kind) return error.ManualEvidenceLedgerActionMismatch;
}

fn validateHeaderRecord(record: Record, plan_sha256: []const u8) !void {
    if (record.record_type != .ledger or record.timestamp <= 0 or record.plan_sha256 == null) return error.InvalidManualEvidenceLedger;
    if (record.action_id != null or record.provider != null or record.task_kind != null or record.operator != null or record.evidence_recorded_at != null or record.evidence_sha256 != null) return error.InvalidManualEvidenceLedger;
    try validateLedgerId(record.ledger_id);
    _ = manifest_hash.parseSha256Hex(record.plan_sha256.?) catch return error.InvalidManualEvidenceLedgerHash;
    if (!std.mem.eql(u8, record.plan_sha256.?, plan_sha256)) return error.ManualEvidenceLedgerPlanMismatch;
}

fn validateEvidenceRecord(record: Record) !void {
    if (record.record_type != .evidence or record.timestamp <= 0 or record.plan_sha256 != null) return error.InvalidManualEvidenceLedger;
    if (record.action_id == null or record.action_id.?.len == 0 or record.provider == null or record.provider.?.len == 0 or record.task_kind == null or record.operator == null or record.operator.?.len == 0 or record.evidence_recorded_at == null or record.evidence_sha256 == null) return error.InvalidManualEvidenceLedger;
    if (record.evidence_recorded_at.? <= 0 or record.evidence_recorded_at.? > record.timestamp) return error.InvalidManualEvidenceLedgerTimestamp;
    try validateLedgerId(record.ledger_id);
    _ = manifest_hash.parseSha256Hex(record.evidence_sha256.?) catch return error.InvalidManualEvidenceLedgerHash;
}

fn verifyRecord(allocator: std.mem.Allocator, record: Record, previous_hash: ?[64]u8) !void {
    if (!std.mem.eql(u8, record.schema_version, schema_version)) return error.UnsupportedManualEvidenceLedgerSchema;
    if (!matchesOptionalHash(record.prev_event_hash, previous_hash)) return error.ManualEvidenceLedgerHashChainMismatch;
    const actual_hash = try requiredHash(record.event_hash);
    const expected_hash = try hashRecord(allocator, record, previous_hash);
    if (!std.mem.eql(u8, &actual_hash, &expected_hash)) return error.ManualEvidenceLedgerHashMismatch;
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
        ledger_id: []const u8,
        timestamp: i64,
        plan_sha256: ?[]const u8,
        action_id: ?[]const u8,
        provider: ?[]const u8,
        task_kind: ?[]const u8,
        operator: ?[]const u8,
        evidence_recorded_at: ?i64,
        evidence_sha256: ?[]const u8,
        prev_event_hash: ?[]const u8,
        event_hash: ?[]const u8,
    };
    try std.json.Stringify.value(JsonRecord{
        .schema_version = record.schema_version,
        .record_type = @tagName(record.record_type),
        .ledger_id = record.ledger_id,
        .timestamp = record.timestamp,
        .plan_sha256 = record.plan_sha256,
        .action_id = record.action_id,
        .provider = record.provider,
        .task_kind = if (record.task_kind) |kind| @tagName(kind) else null,
        .operator = record.operator,
        .evidence_recorded_at = record.evidence_recorded_at,
        .evidence_sha256 = record.evidence_sha256,
        .prev_event_hash = if (previous_hash) |hash| &hash else null,
        .event_hash = if (event_hash) |hash| &hash else null,
    }, .{}, writer);
    try writer.writeByte('\n');
}

fn invalidReport(allocator: std.mem.Allocator, plan: plan_schema.MigrationPlan) !VerifyReport {
    var missing: std.ArrayList([]const u8) = .empty;
    errdefer deinitStringList(allocator, &missing);
    var manual_actions: usize = 0;
    for (plan.actions) |action| {
        if (action.action_type != .manual_step) continue;
        manual_actions += 1;
        try missing.append(allocator, try allocator.dupe(u8, action.id));
    }
    const recorded_slice = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(recorded_slice);
    const missing_slice = try missing.toOwnedSlice(allocator);
    errdefer freeStrings(allocator, missing_slice);
    return .{
        .valid = false,
        .chain_valid = false,
        .plan_match = false,
        .errors = 1,
        .records = 0,
        .evidence_records = 0,
        .manual_actions = manual_actions,
        .missing_actions = manual_actions,
        .ledger_contract_complete = false,
        .ledger_id = null,
        .plan_sha256 = null,
        .tail_hash = null,
        .recorded_action_ids = recorded_slice,
        .missing_action_ids = missing_slice,
    };
}

fn openOrCreate(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |open_err| switch (open_err) {
        error.FileNotFound => std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false, .exclusive = true }) catch |create_err| switch (create_err) {
            error.PathAlreadyExists => try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }),
            else => return create_err,
        },
        else => return open_err,
    };
}

fn findAction(actions: []const plan_schema.Action, action_id: []const u8) ?plan_schema.Action {
    for (actions) |action| if (std.mem.eql(u8, action.id, action_id)) return action;
    return null;
}

fn matchesOptionalHash(value: ?[]const u8, expected: ?[64]u8) bool {
    if (value) |text| {
        const hash = expected orelse return false;
        return std.mem.eql(u8, text, &hash);
    }
    return expected == null;
}

fn requiredHash(value: ?[]const u8) ![64]u8 {
    const text = value orelse return error.InvalidManualEvidenceLedger;
    _ = manifest_hash.parseSha256Hex(text) catch return error.InvalidManualEvidenceLedgerHash;
    var hash: [64]u8 = undefined;
    @memcpy(&hash, text);
    return hash;
}

fn validatePath(path: []const u8) !void {
    validation.validatePath(path) catch return error.InvalidManualEvidenceLedgerPath;
    if (path.len == 0) return error.InvalidManualEvidenceLedgerPath;
}

fn validateLedgerId(value: []const u8) !void {
    if (value.len != 32) return error.InvalidManualEvidenceLedger;
    for (value) |char| if (!std.ascii.isHex(char) or std.ascii.isUpper(char)) return error.InvalidManualEvidenceLedger;
}

fn randomLedgerIdAlloc(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    const text = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &text);
}

fn deinitActions(allocator: std.mem.Allocator, actions: *std.StringHashMap(void)) void {
    var iterator = actions.iterator();
    while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
    actions.deinit();
}

fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn deinitStringList(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8)) void {
    for (values.items) |value| allocator.free(value);
    values.deinit(allocator);
}

test "ledger appends validated evidence and reports plan completeness" {
    var actions = fixtureActions();
    const plan = fixturePlan(&actions);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/evidence.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var buffer_a: [4096]u8 = undefined;
    const evidence_a = try fixtureEvidenceBytes(std.testing.allocator, "manual/a", "provider_a", "01" ** 32);
    defer std.testing.allocator.free(evidence_a);
    try appendEvidenceBytes(std.testing.io, std.testing.allocator, path, plan, "01" ** 32, evidence_a, 20, &buffer_a);
    const first_bytes = try fs_util.readFileAlloc(std.testing.io, std.testing.allocator, path, max_ledger_bytes);
    defer std.testing.allocator.free(first_bytes);
    var first_report = try verifyBytes(std.testing.allocator, plan, "01" ** 32, first_bytes);
    defer first_report.deinit(std.testing.allocator);
    try std.testing.expect(first_report.valid);
    try std.testing.expectEqual(@as(usize, 2), first_report.records);
    try std.testing.expectEqual(@as(usize, 1), first_report.missing_actions);
    try std.testing.expectEqualStrings("manual/a", first_report.recorded_action_ids[0]);

    var buffer_b: [4096]u8 = undefined;
    const evidence_b = try fixtureEvidenceBytes(std.testing.allocator, "manual/b", "provider_b", "01" ** 32);
    defer std.testing.allocator.free(evidence_b);
    try appendEvidenceBytes(std.testing.io, std.testing.allocator, path, plan, "01" ** 32, evidence_b, 21, &buffer_b);
    const complete_bytes = try fs_util.readFileAlloc(std.testing.io, std.testing.allocator, path, max_ledger_bytes);
    defer std.testing.allocator.free(complete_bytes);
    var complete_report = try verifyBytes(std.testing.allocator, plan, "01" ** 32, complete_bytes);
    defer complete_report.deinit(std.testing.allocator);
    try std.testing.expect(complete_report.ledger_contract_complete);
    try std.testing.expectEqual(@as(usize, 3), complete_report.records);
    try std.testing.expectEqual(TrustLevel.hash_chain_only, complete_report.trust_level);

    var duplicate_buffer: [4096]u8 = undefined;
    try std.testing.expectError(
        error.ManualEvidenceActionAlreadyRecorded,
        appendEvidenceBytes(std.testing.io, std.testing.allocator, path, plan, "01" ** 32, evidence_a, 22, &duplicate_buffer),
    );

    var cross_plan_buffer: [4096]u8 = undefined;
    const cross_plan_evidence = try fixtureEvidenceBytes(std.testing.allocator, "manual/a", "provider_a", "02" ** 32);
    defer std.testing.allocator.free(cross_plan_evidence);
    try std.testing.expectError(
        error.ManualEvidenceLedgerPlanMismatch,
        appendEvidenceBytes(std.testing.io, std.testing.allocator, path, plan, "02" ** 32, cross_plan_evidence, 22, &cross_plan_buffer),
    );
}

test "ledger detects content tampering before verify or append" {
    var actions = fixtureActions();
    const plan = fixturePlan(&actions);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/tampered.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    var writer_buffer: [4096]u8 = undefined;
    const evidence_a = try fixtureEvidenceBytes(std.testing.allocator, "manual/a", "provider_a", "01" ** 32);
    defer std.testing.allocator.free(evidence_a);
    try appendEvidenceBytes(std.testing.io, std.testing.allocator, path, plan, "01" ** 32, evidence_a, 20, &writer_buffer);
    const original = try fs_util.readFileAlloc(std.testing.io, std.testing.allocator, path, max_ledger_bytes);
    defer std.testing.allocator.free(original);
    const tampered = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(tampered);
    const operator_offset = std.mem.indexOf(u8, tampered, "ai-agent") orelse return error.TestExpectedEqual;
    tampered[operator_offset] = 'b';
    try writeTestFile(path, tampered);

    var report = try verifyBytes(std.testing.allocator, plan, "01" ** 32, tampered);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.valid);
    try std.testing.expect(!report.chain_valid);

    var append_buffer: [4096]u8 = undefined;
    const evidence_b = try fixtureEvidenceBytes(std.testing.allocator, "manual/b", "provider_b", "01" ** 32);
    defer std.testing.allocator.free(evidence_b);
    try std.testing.expectError(
        error.ManualEvidenceLedgerHashMismatch,
        appendEvidenceBytes(std.testing.io, std.testing.allocator, path, plan, "01" ** 32, evidence_b, 21, &append_buffer),
    );
}

test "ledger rejects invalid evidence before creating a file" {
    var actions = fixtureActions();
    const plan = fixturePlan(&actions);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/not-created.jsonl", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const invalid_evidence = try fixtureEvidenceBytesWithStatus(std.testing.allocator, "manual/a", "provider_a", "01" ** 32, .failed);
    defer std.testing.allocator.free(invalid_evidence);

    var writer_buffer: [4096]u8 = undefined;
    try std.testing.expectError(
        error.InvalidManualEvidence,
        appendEvidenceBytes(std.testing.io, std.testing.allocator, path, plan, "01" ** 32, invalid_evidence, 20, &writer_buffer),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));
}

var fixture_inputs = [_]plan_schema.ManualInput{.{ .name = "subject", .value = "test" }};
var fixture_conditions = [_]plan_schema.ManualCondition{.{ .kind = .approval, .target = "test" }};
var fixture_outputs = [_]plan_schema.ManualOutput{.{ .name = "review_decision" }};
var fixture_probes = [_]plan_schema.ManualProbe{.{ .kind = .manual_evidence, .target = "test" }};
var fixture_evidence_conditions = [_]evidence_schema.ConditionEvidence{.{ .kind = .approval, .target = "test", .status = .satisfied, .observed_at = 8 }};
var fixture_evidence_outputs = [_]evidence_schema.OutputEvidence{.{ .name = "review_decision", .status = .produced }};
var fixture_evidence_probes = [_]evidence_schema.ProbeEvidence{.{ .kind = .manual_evidence, .target = "test", .status = .passed, .observed_at = 9 }};

fn fixtureTask(provider: []const u8) plan_schema.ManualTask {
    return .{
        .schema_version = plan_schema.manual_task_schema_version,
        .kind = .review,
        .provider = provider,
        .inputs = &fixture_inputs,
        .preconditions = &fixture_conditions,
        .expected_outputs = &fixture_outputs,
        .verify_probes = &fixture_probes,
        .rollback_policy = .none,
        .evidence_schema = evidence_schema.schema_version,
    };
}

fn fixtureActions() [2]plan_schema.Action {
    return .{
        .{ .id = "manual/a", .module = .resources, .action_type = .manual_step, .description = "a", .risk = .high, .requires_confirmation = true, .phase = .prepare, .manual_task = fixtureTask("provider_a") },
        .{ .id = "manual/b", .module = .appdata, .action_type = .manual_step, .description = "b", .risk = .high, .requires_confirmation = true, .phase = .prepare, .manual_task = fixtureTask("provider_b") },
    };
}

fn fixturePlan(actions: []plan_schema.Action) plan_schema.MigrationPlan {
    return .{
        .schema_version = plan_schema.schema_version_v2,
        .source_inventory_hash = [_]u8{0} ** 32,
        .target_inventory_hash = [_]u8{1} ** 32,
        .compatibility = .{ .compatible = true, .same_distro = true, .same_version = true, .same_package_manager = true, .same_arch = true, .reason = "compatible" },
        .actions = actions,
        .created_at = 1,
    };
}

fn fixtureEvidenceBytes(allocator: std.mem.Allocator, action_id: []const u8, provider: []const u8, plan_sha256: []const u8) ![]u8 {
    return fixtureEvidenceBytesWithStatus(allocator, action_id, provider, plan_sha256, .succeeded);
}

fn fixtureEvidenceBytesWithStatus(
    allocator: std.mem.Allocator,
    action_id: []const u8,
    provider: []const u8,
    plan_sha256: []const u8,
    status: evidence_schema.Status,
) ![]u8 {
    const evidence = evidence_schema.Evidence{
        .schema_version = evidence_schema.schema_version,
        .plan_sha256 = plan_sha256,
        .action_id = action_id,
        .task_kind = .review,
        .provider = provider,
        .status = status,
        .operator = "ai-agent",
        .recorded_at = 10,
        .preconditions = &fixture_evidence_conditions,
        .outputs = &fixture_evidence_outputs,
        .probes = &fixture_evidence_probes,
    };
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &bytes);
    try std.json.Stringify.value(evidence, .{ .emit_null_optional_fields = true }, &writer.writer);
    bytes = writer.toArrayList();
    return bytes.toOwnedSlice(allocator);
}

fn writeTestFile(path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.flush();
}
