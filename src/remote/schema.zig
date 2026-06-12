const plan = @import("../plan/schema.zig");
const credentials = @import("../credentials/source.zig");

pub const command_plan_schema_version = "hostlift.remote.command.v1";
pub const transfer_plan_schema_version = "hostlift.remote.transfer.v1";

// 文件传输后端类型。
pub const TransferTransport = enum {
    scp,
    rsync,
    chunk,
};

// 远程命令执行计划。
pub const CommandPlan = struct {
    schema_version: []const u8,
    host: []const u8,
    argv: []const []const u8,
    timeout_seconds: u32,
    retries: u8 = 0,
    ssh_identity_file: ?[]const u8 = null,
    credential_source: credentials.SourceKind = .default_ssh,
    operation_id: ?[]const u8 = null,
    cancel_file: ?[]const u8 = null,
    operation_state_file: ?[]const u8 = null,
    risk: plan.RiskLevel,
    requires_approval: bool,
};

// 远程文件传输计划。
pub const TransferPlan = struct {
    schema_version: []const u8,
    source_host: ?[]const u8 = null,
    host: []const u8,
    source_path: []const u8,
    target_path: []const u8,
    recursive: bool = false,
    preserve_metadata: bool,
    verify_checksum: bool,
    transport: TransferTransport = .scp,
    partial: bool = false,
    resumable: bool = false,
    bandwidth_limit_kbps: ?u32 = null,
    chunk_size_bytes: ?u64 = null,
    timeout_seconds: u32 = 60,
    retries: u8 = 0,
    ssh_identity_file: ?[]const u8 = null,
    credential_source: credentials.SourceKind = .default_ssh,
    operation_id: ?[]const u8 = null,
    cancel_file: ?[]const u8 = null,
    operation_state_file: ?[]const u8 = null,
    risk: plan.RiskLevel,
    requires_approval: bool,
};
