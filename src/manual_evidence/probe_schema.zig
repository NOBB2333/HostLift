const plan_schema = @import("../plan/schema.zig");

pub const schema_version = "hostlift.manual_probe_report.v1";
pub const validation_schema_version = "hostlift.manual_evidence.probed_validation.v1";

pub const TrustLevel = enum {
    hostlift_remote_read_only,
};

pub const ResultStatus = enum {
    passed,
    failed,
    unsupported,
    @"error",
};

pub const Executor = enum {
    none,
    systemctl_is_active,
    docker_inspect_state,
    podman_inspect_state,
    tcp_connect,
    http_request,
};

pub const Result = struct {
    kind: plan_schema.ManualProbeKind,
    target: []const u8,
    required: bool,
    status: ResultStatus,
    executor: Executor,
    observed_at: i64,
    observation_sha256: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
};

// HostLift 只读远程探针报告；原始 stdout、stderr 和命令正文不进入合同。
pub const Report = struct {
    schema_version: []const u8 = schema_version,
    plan_sha256: []const u8,
    action_id: []const u8,
    task_kind: plan_schema.ManualTaskKind,
    provider: []const u8,
    host: []const u8,
    probed_at: i64,
    all_required_passed: bool,
    trust_level: TrustLevel = .hostlift_remote_read_only,
    results: []const Result,
};

// 联合校验报告同时呈现原 evidence 合同结果和可信探针绑定结果。
pub const ProbedValidationReport = struct {
    schema_version: []const u8 = validation_schema_version,
    valid: bool,
    trust_level: TrustLevel = .hostlift_remote_read_only,
    probe_report_sha256: []const u8,
    evidence_valid: bool,
    evidence_errors: u32,
    probe_binding_errors: u32,
    probe_contract_errors: u32,
    probe_result_errors: u32,
    required_probes_checked: usize,
};
