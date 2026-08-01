const std = @import("std");

pub const schema_version = "hostlift.workload_report.v1";

// 工作负载类型，第一版覆盖可从现有 inventory 稳定识别的应用主体。
pub const WorkloadKind = enum {
    systemd_service,
    project,
    app_data,
    container,
    unmanaged_resource,
};

// 工作负载组件类型，用于让 AI 理解一个应用由哪些事实组成。
pub const ComponentKind = enum {
    service,
    config,
    code,
    data,
    secret,
    port,
    runtime,
    health,
};

// 完成度状态；unknown 表示事实不足，不能当成成功。
pub const Status = enum {
    complete,
    pending,
    blocked,
    unknown,
};

// 当前结论的可信度，反映 scanner 的事实粒度而不是主观成功率。
pub const Confidence = enum {
    high,
    medium,
    low,
};

// 阻塞原因类型，供 AI 在不解析自然语言的情况下选择后续任务。
pub const BlockerKind = enum {
    manual_action,
    critical_action,
    target_fact_missing,
    scan_incomplete,
    incompatible_target,
};

// 证据来源类型。
pub const EvidenceKind = enum {
    source_inventory,
    target_inventory,
    migration_action,
};

// 一个工作负载组件及其关联迁移动作。
pub const Component = struct {
    kind: ComponentKind,
    source_ref: []const u8,
    target_present: bool,
    action_ids: []const []const u8,
};

// 一个结构化阻塞项；action_id 为空时表示 inventory 或兼容性层面的阻塞。
pub const Blocker = struct {
    kind: BlockerKind,
    ref: []const u8,
    action_id: ?[]const u8 = null,
};

// 支撑完成度结论的 inventory 或 plan 证据引用。
pub const Evidence = struct {
    kind: EvidenceKind,
    ref: []const u8,
};

// 单个应用工作负载的组件、状态、阻塞项和证据。
pub const Workload = struct {
    id: []const u8,
    name: []const u8,
    kind: WorkloadKind,
    components: []const Component,
    status: Status,
    blockers: []const Blocker,
    confidence: Confidence,
    evidence: []const Evidence,
};

// 报告级状态计数，避免使用无法证明的迁移百分比。
pub const Summary = struct {
    total: usize = 0,
    complete: usize = 0,
    pending: usize = 0,
    blocked: usize = 0,
    unknown: usize = 0,
    plan_actions: usize = 0,
    unassigned_actions: usize = 0,
};

// 完整工作负载报告；host_status 还会纳入未归属 action 和全局扫描事实。
pub const Report = struct {
    schema_version: []const u8,
    source_host: []const u8,
    target_host: []const u8,
    compatible: bool,
    host_status: Status,
    all_workloads_complete: bool,
    summary: Summary,
    workloads: []const Workload,
    global_blockers: []const Blocker,
    unassigned_action_ids: []const []const u8,

    // 释放工作负载报告持有的全部字符串和嵌套数组。
    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.schema_version);
        allocator.free(self.source_host);
        allocator.free(self.target_host);
        for (self.workloads) |workload| deinitWorkload(allocator, workload);
        allocator.free(self.workloads);
        deinitBlockers(allocator, self.global_blockers);
        for (self.unassigned_action_ids) |action_id| allocator.free(action_id);
        allocator.free(self.unassigned_action_ids);
    }
};

// 释放单个工作负载及其组件、阻塞项和证据。
pub fn deinitWorkload(allocator: std.mem.Allocator, workload: Workload) void {
    allocator.free(workload.id);
    allocator.free(workload.name);
    for (workload.components) |component| {
        allocator.free(component.source_ref);
        for (component.action_ids) |action_id| allocator.free(action_id);
        allocator.free(component.action_ids);
    }
    allocator.free(workload.components);
    deinitBlockers(allocator, workload.blockers);
    for (workload.evidence) |evidence| allocator.free(evidence.ref);
    allocator.free(workload.evidence);
}

fn deinitBlockers(allocator: std.mem.Allocator, blockers: []const Blocker) void {
    for (blockers) |blocker| {
        allocator.free(blocker.ref);
        if (blocker.action_id) |action_id| allocator.free(action_id);
    }
    allocator.free(blockers);
}
