const std = @import("std");
const audit_log = @import("log.zig");
const verify_event = @import("verify_event.zig");

pub const report_schema_version = "hostlift.audit.verify.v1";

// 审计日志校验报告。
pub const Report = struct {
    schema_version: []const u8 = report_schema_version,
    valid: bool,
    events: usize,
    errors: u32,
    tail_hash: ?[]const u8 = null,

    // 释放 verify 报告中由 verifier 持有的字符串。
    pub fn deinit(self: Report, allocator: std.mem.Allocator) void {
        if (self.tail_hash) |value| allocator.free(value);
    }
};

// 校验审计 JSONL 的 schema、event_hash 和 prev_event_hash 链接。
pub fn verifyJsonl(allocator: std.mem.Allocator, bytes: []const u8) !Report {
    var report: Report = .{
        .valid = true,
        .events = 0,
        .errors = 0,
    };

    var previous_hash: ?[64]u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        report.events += 1;

        const parsed = verify_event.parseLine(allocator, line) catch {
            report.errors += 1;
            report.valid = false;
            continue;
        };
        defer parsed.deinit();
        const event = parsed.value.value;

        if (!std.mem.eql(u8, event.schema_version, audit_log.schema_version)) {
            report.errors += 1;
            report.valid = false;
            continue;
        }
        if (!verify_event.matchesOptionalHash(event.prev_event_hash, previous_hash)) {
            report.errors += 1;
            report.valid = false;
            continue;
        }
        const expected_hash = verify_event.hashEvent(allocator, event, parsed.has_credential_source, parsed.has_policy_hash) catch |err| switch (err) {
            error.InvalidAuditPhase, error.InvalidAuditResult, error.InvalidAuditCredentialSource, error.InvalidAuditHash => {
                report.errors += 1;
                report.valid = false;
                continue;
            },
            else => return err,
        };
        if (!verify_event.matchesRequiredHash(event.event_hash, expected_hash)) {
            report.errors += 1;
            report.valid = false;
            continue;
        }

        previous_hash = expected_hash;
    }

    if (previous_hash) |hash| report.tail_hash = try allocator.dupe(u8, &hash);
    return report;
}
