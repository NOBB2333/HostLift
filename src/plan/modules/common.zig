const std = @import("std");
const plan = @import("../schema.zig");

// manual task 的借用输入；构造 action 时会深拷贝 value 或 secret_ref。
pub const ManualInputSpec = struct {
    name: []const u8,
    value: ?[]const u8 = null,
    secret_ref: ?[]const u8 = null,
    required: bool = true,
};

// manual task 的借用探针；构造 action 时会深拷贝 target。
pub const ManualProbeSpec = struct {
    kind: plan.ManualProbeKind,
    target: []const u8,
    required: bool = true,
};

// manual task 的 provider 专属补充合同；未提供探针覆盖时仍使用 kind 对应的默认探针。
pub const ManualTaskSpec = struct {
    provider: ?[]const u8 = null,
    inputs: []const ManualInputSpec = &.{},
    secret_refs: []const []const u8 = &.{},
    verify_probes: ?[]const ManualProbeSpec = null,
};

// 迁移动作输入参数结构体，统一各模块的动作构造字段。
pub const ActionInput = struct {
    id_prefix: []const u8,
    name: []const u8,
    subject: ?[]const u8 = null,
    module: plan.ModuleName,
    action_type: plan.ActionType,
    uid: ?u32 = null,
    gid: ?u32 = null,
    home: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    risk: plan.RiskLevel,
    requires_confirmation: bool,
    description: []const u8,
    recursive: bool = false,
    file_count: u64 = 0,
    phase: ?plan.ActionPhase = null,
    depends_on: []const []const u8 = &.{},
    manual_task_spec: ?ManualTaskSpec = null,
};

// 构造并追加一条迁移动作，统一 action id、subject 和描述生成规则。
pub fn appendAction(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    input: ActionInput,
) !void {
    const id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ input.id_prefix, input.name });
    errdefer allocator.free(id);
    const subject = try allocator.dupe(u8, input.subject orelse input.name);
    errdefer allocator.free(subject);
    const description = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ input.description, input.name });
    errdefer allocator.free(description);
    const home = if (input.home) |home_value| try allocator.dupe(u8, home_value) else null;
    errdefer if (home) |value| allocator.free(value);
    const shell = if (input.shell) |shell_value| try allocator.dupe(u8, shell_value) else null;
    errdefer if (shell) |value| allocator.free(value);
    const owner = if (input.owner) |owner_value| try allocator.dupe(u8, owner_value) else null;
    errdefer if (owner) |value| allocator.free(value);
    const dependencies = try duplicateStringsOrNull(allocator, input.depends_on);
    errdefer if (dependencies) |values| freeStrings(allocator, values);
    const manual_task = if (input.action_type == .manual_step)
        try buildManualTask(allocator, input.id_prefix, input.module, subject, input.manual_task_spec orelse .{})
    else
        null;
    errdefer if (manual_task) |task| plan.deinitManualTask(allocator, task);

    try actions.append(allocator, .{
        .id = id,
        .module = input.module,
        .action_type = input.action_type,
        .subject = subject,
        .uid = input.uid,
        .gid = input.gid,
        .home = home,
        .shell = shell,
        .owner = owner,
        .description = description,
        .risk = input.risk,
        .requires_confirmation = input.requires_confirmation,
        .recursive = input.recursive,
        .file_count = input.file_count,
        .phase = input.phase orelse phaseForAction(input.action_type, input.id_prefix),
        .depends_on = dependencies,
        .manual_task = manual_task,
    });
}

fn buildManualTask(
    allocator: std.mem.Allocator,
    id_prefix: []const u8,
    module: plan.ModuleName,
    subject: []const u8,
    spec: ManualTaskSpec,
) !plan.ManualTask {
    const kind = manualKind(id_prefix);
    const provider = try allocator.dupe(u8, spec.provider orelse @tagName(module));
    errdefer allocator.free(provider);
    const schema_version = try allocator.dupe(u8, plan.manual_task_schema_version);
    errdefer allocator.free(schema_version);
    const evidence_schema = try allocator.dupe(u8, plan.manual_evidence_schema_version);
    errdefer allocator.free(evidence_schema);

    const inputs = try allocator.alloc(plan.ManualInput, 1 + spec.inputs.len);
    var initialized_inputs: usize = 0;
    errdefer {
        for (inputs[0..initialized_inputs]) |input| deinitManualInput(allocator, input);
        allocator.free(inputs);
    }
    inputs[0] = try duplicateManualInput(allocator, .{ .name = "subject", .value = subject });
    initialized_inputs += 1;
    for (spec.inputs, 1..) |input, index| {
        inputs[index] = try duplicateManualInput(allocator, input);
        initialized_inputs += 1;
    }

    const secret_refs = try duplicateStringsOrNull(allocator, spec.secret_refs);
    errdefer if (secret_refs) |values| freeStrings(allocator, values);

    const preconditions = try allocator.alloc(plan.ManualCondition, 1);
    errdefer allocator.free(preconditions);
    preconditions[0] = .{
        .kind = conditionForKind(kind),
        .target = try allocator.dupe(u8, subject),
    };
    errdefer allocator.free(preconditions[0].target);

    const outputs = try allocator.alloc(plan.ManualOutput, 1);
    errdefer allocator.free(outputs);
    outputs[0] = .{ .name = try allocator.dupe(u8, outputForKind(kind)) };
    errdefer allocator.free(outputs[0].name);

    const probes = if (spec.verify_probes) |probe_specs|
        try duplicateManualProbes(allocator, probe_specs)
    else blk: {
        const defaults = [_]ManualProbeSpec{.{ .kind = probeForKind(kind), .target = subject }};
        break :blk try duplicateManualProbes(allocator, &defaults);
    };
    errdefer {
        for (probes) |probe| allocator.free(probe.target);
        allocator.free(probes);
    }

    return .{
        .schema_version = schema_version,
        .kind = kind,
        .provider = provider,
        .inputs = inputs,
        .secret_refs = secret_refs,
        .preconditions = preconditions,
        .expected_outputs = outputs,
        .verify_probes = probes,
        .rollback_policy = rollbackForKind(kind),
        .evidence_schema = evidence_schema,
    };
}

fn duplicateManualProbes(allocator: std.mem.Allocator, specs: []const ManualProbeSpec) ![]plan.ManualProbe {
    if (specs.len == 0) return error.InvalidManualTaskProbeSpec;
    const probes = try allocator.alloc(plan.ManualProbe, specs.len);
    var initialized: usize = 0;
    errdefer {
        for (probes[0..initialized]) |probe| allocator.free(probe.target);
        allocator.free(probes);
    }
    for (specs, 0..) |spec, index| {
        if (spec.target.len == 0) return error.InvalidManualTaskProbeSpec;
        probes[index] = .{
            .kind = spec.kind,
            .target = try allocator.dupe(u8, spec.target),
            .required = spec.required,
        };
        initialized += 1;
    }
    return probes;
}

fn duplicateManualInput(allocator: std.mem.Allocator, input: ManualInputSpec) !plan.ManualInput {
    if (input.name.len == 0) return error.InvalidManualTaskInputSpec;
    if ((input.value == null) == (input.secret_ref == null)) return error.InvalidManualTaskInputSpec;
    const name = try allocator.dupe(u8, input.name);
    errdefer allocator.free(name);
    const value = if (input.value) |item| try allocator.dupe(u8, item) else null;
    errdefer if (value) |item| allocator.free(item);
    const secret_ref = if (input.secret_ref) |item| try allocator.dupe(u8, item) else null;
    errdefer if (secret_ref) |item| allocator.free(item);
    return .{
        .name = name,
        .value = value,
        .secret_ref = secret_ref,
        .required = input.required,
    };
}

fn deinitManualInput(allocator: std.mem.Allocator, input: plan.ManualInput) void {
    allocator.free(input.name);
    if (input.value) |value| allocator.free(value);
    if (input.secret_ref) |secret_ref| allocator.free(secret_ref);
}

fn manualKind(id_prefix: []const u8) plan.ManualTaskKind {
    if (std.mem.indexOf(u8, id_prefix, "reinstall") != null) return .reinstall;
    if (std.mem.indexOf(u8, id_prefix, "dump-restore") != null) return .data_restore;
    if (std.mem.indexOf(u8, id_prefix, "stop-writers") != null) return .quiesce;
    if (std.mem.indexOf(u8, id_prefix, "check-status") != null or
        std.mem.indexOf(u8, id_prefix, "check-container") != null or
        std.mem.indexOf(u8, id_prefix, "health") != null) return .health_check;
    if (std.mem.indexOf(u8, id_prefix, "merge") != null) return .merge;
    if (std.mem.startsWith(u8, id_prefix, "scan-warning")) return .rescan;
    if (std.mem.indexOf(u8, id_prefix, "capacity") != null) return .capacity_review;
    if (std.mem.indexOf(u8, id_prefix, "review-start") != null) return .service_start;
    if (std.mem.indexOf(u8, id_prefix, "cleanup") != null) return .cleanup;
    return .review;
}

fn phaseForAction(action_type: plan.ActionType, id_prefix: []const u8) plan.ActionPhase {
    if (action_type == .manual_step) return switch (manualKind(id_prefix)) {
        .quiesce => .quiesce,
        .data_restore => .restore,
        .service_start => .start,
        .health_check => .verify,
        else => .prepare,
    };
    return switch (action_type) {
        .postgresql_dump, .postgresql_target_baseline => .quiesce,
        .write_file, .merge_file, .install_cron_entry, .copy_home_config, .copy_data_path, .copy_project_path, .postgresql_transfer, .reinstall_download, .add_authorized_key, .install_systemd_unit, .apply_firewall_config => .transfer,
        .postgresql_restore, .reinstall_execute => .restore,
        .postgresql_verify, .reinstall_verify => .verify,
        .enable_systemd_unit, .enable_user_systemd_unit, .enable_openrc_service, .disable_openrc_service, .enable_sysv_init, .disable_sysv_init => .configure,
        .start_compose_project => .start,
        .verify_compose_project => .verify,
        else => .prepare,
    };
}

fn conditionForKind(kind: plan.ManualTaskKind) plan.ManualConditionKind {
    return switch (kind) {
        .quiesce => .writers_stopped,
        .data_restore => .backup_verified,
        .capacity_review => .capacity_verified,
        .review, .reinstall, .health_check, .merge, .rescan, .service_start, .cleanup => .approval,
    };
}

fn outputForKind(kind: plan.ManualTaskKind) []const u8 {
    return switch (kind) {
        .reinstall => "installed_artifact",
        .data_restore => "restored_dataset",
        .quiesce => "writers_stopped",
        .health_check => "health_result",
        .merge => "merged_artifact",
        .rescan => "inventory_evidence",
        .capacity_review => "capacity_decision",
        .service_start => "service_state",
        .cleanup => "cleanup_decision",
        .review => "review_decision",
    };
}

fn probeForKind(kind: plan.ManualTaskKind) plan.ManualProbeKind {
    return switch (kind) {
        .service_start => .systemd,
        .health_check => .manual_evidence,
        .reinstall, .data_restore, .quiesce, .merge, .rescan, .capacity_review, .cleanup, .review => .manual_evidence,
    };
}

fn rollbackForKind(kind: plan.ManualTaskKind) plan.ManualRollbackPolicy {
    return switch (kind) {
        .review, .health_check, .rescan, .capacity_review, .cleanup => .none,
        .service_start => .compensating_action,
        .data_restore => .provider_required,
        .reinstall, .quiesce, .merge => .manual,
    };
}

fn duplicateStringsOrNull(allocator: std.mem.Allocator, values: []const []const u8) !?[]const []const u8 {
    if (values.len == 0) return null;
    const result = try allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
        allocator.free(result);
    }
    for (values, 0..) |value, index| {
        result[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

// 判断字符串列表是否包含指定值。
pub fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

test "manual task provider spec preserves value and secret inputs" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer {
        for (actions.items) |action| plan.deinitAction(std.testing.allocator, action);
        actions.deinit(std.testing.allocator);
    }
    const inputs = [_]ManualInputSpec{
        .{ .name = "source_url", .value = "https://example.invalid/install.sh", .required = false },
        .{ .name = "api_token", .secret_ref = "env:APP_TOKEN" },
    };
    const secret_refs = [_][]const u8{"env:APP_TOKEN"};
    const probes = [_]ManualProbeSpec{.{ .kind = .http, .target = "https://example.invalid/health" }};
    try appendAction(std.testing.allocator, &actions, .{
        .id_prefix = "resources/reinstall",
        .name = "app",
        .module = .resources,
        .action_type = .manual_step,
        .risk = .high,
        .requires_confirmation = true,
        .description = "Reinstall app",
        .manual_task_spec = .{
            .provider = "resource_reinstall",
            .inputs = &inputs,
            .secret_refs = &secret_refs,
            .verify_probes = &probes,
        },
    });

    const task = actions.items[0].manual_task.?;
    try std.testing.expectEqual(plan.ManualTaskKind.reinstall, task.kind);
    try std.testing.expectEqualStrings("resource_reinstall", task.provider);
    try std.testing.expectEqual(@as(usize, 3), task.inputs.len);
    try std.testing.expectEqualStrings("https://example.invalid/install.sh", task.inputs[1].value.?);
    try std.testing.expectEqualStrings("env:APP_TOKEN", task.inputs[2].secret_ref.?);
    try std.testing.expectEqualStrings("env:APP_TOKEN", task.secret_refs.?[0]);
    try std.testing.expectEqual(plan.ManualProbeKind.http, task.verify_probes[0].kind);
    try std.testing.expectEqualStrings("https://example.invalid/health", task.verify_probes[0].target);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &json);
    try std.json.Stringify.value(task, .{ .whitespace = .indent_2 }, &writer.writer);
    json = writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"provider\": \"resource_reinstall\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"source_url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"secret_ref\": \"env:APP_TOKEN\"") != null);
}

test "manual task provider spec rejects ambiguous input values" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer actions.deinit(std.testing.allocator);
    const inputs = [_]ManualInputSpec{.{
        .name = "ambiguous",
        .value = "plain",
        .secret_ref = "env:SECRET",
    }};
    try std.testing.expectError(error.InvalidManualTaskInputSpec, appendAction(std.testing.allocator, &actions, .{
        .id_prefix = "resources/reinstall",
        .name = "app",
        .module = .resources,
        .action_type = .manual_step,
        .risk = .high,
        .requires_confirmation = true,
        .description = "Reinstall app",
        .manual_task_spec = .{ .inputs = &inputs },
    }));
    try std.testing.expectEqual(@as(usize, 0), actions.items.len);
}
