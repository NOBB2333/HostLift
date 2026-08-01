const plan_schema = @import("../plan/schema.zig");

pub const schema_version = "hostlift.manual_evidence.v1";
pub const validation_report_schema_version = "hostlift.manual_evidence.validation.v1";
pub const completeness_report_schema_version = "hostlift.manual_evidence.completeness.v1";

// evidence 文件只表达结构化状态和摘要，不提供保存 stdout、命令文本或 secret 原值的字段。
pub const Status = enum {
    succeeded,
    failed,
};

pub const ConditionStatus = enum {
    satisfied,
    not_satisfied,
    skipped,
};

pub const OutputStatus = enum {
    produced,
    missing,
    skipped,
};

pub const ProbeStatus = enum {
    passed,
    failed,
    skipped,
};

pub const ConditionEvidence = struct {
    kind: plan_schema.ManualConditionKind,
    target: []const u8,
    status: ConditionStatus,
    observed_at: i64,
};

pub const OutputEvidence = struct {
    name: []const u8,
    status: OutputStatus,
    artifact_sha256: ?[]const u8 = null,
};

pub const ProbeEvidence = struct {
    kind: plan_schema.ManualProbeKind,
    target: []const u8,
    status: ProbeStatus,
    observed_at: i64,
    evidence_sha256: ?[]const u8 = null,
};

// 单个 manual action 的证据；plan hash 和合同身份阻止证据跨计划或跨 provider 复用。
pub const Evidence = struct {
    schema_version: []const u8,
    plan_sha256: []const u8,
    action_id: []const u8,
    task_kind: plan_schema.ManualTaskKind,
    provider: []const u8,
    status: Status,
    operator: []const u8,
    recorded_at: i64,
    preconditions: []const ConditionEvidence,
    outputs: []const OutputEvidence,
    probes: []const ProbeEvidence,
};

// 验证报告把计划绑定、合同覆盖和结果失败分开，便于 AI 精确修正证据文件。
pub const ValidationReport = struct {
    schema_version: []const u8 = validation_report_schema_version,
    valid: bool,
    errors: u32,
    binding_errors: u32,
    contract_errors: u32,
    result_errors: u32,
    preconditions_checked: usize,
    outputs_checked: usize,
    probes_checked: usize,
};

// 完整度报告只声明合同覆盖，不把本地 evidence 视为已验签的可信执行结果。
pub const TrustLevel = enum {
    contract_only,
};

pub const CoverageStatus = enum {
    valid,
    missing,
    duplicate,
    invalid,
};

pub const ActionCoverage = struct {
    action_id: []const u8,
    provider: ?[]const u8,
    task_kind: ?plan_schema.ManualTaskKind,
    status: CoverageStatus,
    evidence_count: usize,
};

pub const EvidenceCheck = struct {
    source_ref: []const u8,
    action_id: []const u8,
    valid: bool,
    expected_manual_action: bool,
    binding_errors: u32,
    contract_errors: u32,
    result_errors: u32,
};

pub const CompletenessReport = struct {
    schema_version: []const u8 = completeness_report_schema_version,
    contract_complete: bool,
    trust_level: TrustLevel = .contract_only,
    manual_actions: usize,
    valid_actions: usize,
    missing_actions: usize,
    duplicate_actions: usize,
    invalid_actions: usize,
    evidence_files: usize,
    valid_evidence_files: usize,
    invalid_evidence_files: usize,
    unexpected_evidence_files: usize,
    actions: []ActionCoverage,
    evidence: []EvidenceCheck,

    // 释放完整度报告拥有的 action/provider/source 字符串和数组。
    pub fn deinit(self: *CompletenessReport, allocator: @import("std").mem.Allocator) void {
        for (self.actions) |action| {
            allocator.free(action.action_id);
            if (action.provider) |provider| allocator.free(provider);
        }
        allocator.free(self.actions);
        for (self.evidence) |item| {
            allocator.free(item.source_ref);
            allocator.free(item.action_id);
        }
        allocator.free(self.evidence);
    }
};
