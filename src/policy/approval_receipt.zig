const std = @import("std");
const audit_operator = @import("../audit/operator.zig");
const fs_util = @import("../util/fs.zig");
const plan_hash_policy = @import("plan_hash.zig");
const security_validation = @import("../security/validation.zig");

pub const schema_version = "hostlift.approval_receipt.v1";
pub const max_receipt_bytes = 256 * 1024;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

// 审批凭证数据结构。
pub const Receipt = struct {
    schema_version: []const u8 = schema_version,
    ticket: []const u8,
    operator: []const u8,
    host: []const u8,
    plan_hash: ?[]const u8 = null,
    purpose: []const u8 = "apply",
    issued_at: ?i64 = null,
    expires_at: ?i64 = null,
    issuer: ?[]const u8 = null,
    signature: ?[]const u8 = null,
};

// 审批凭证校验上下文。
pub const Context = struct {
    ticket: ?[]const u8,
    operator: []const u8,
    host: []const u8,
    plan_hash: ?[]const u8 = null,
    purpose: []const u8,
    now: i64,
    signature_key: ?[]const u8 = null,
};

// 从 JSON bytes 解析审批凭证文件。
pub fn parseFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Receipt) {
    return std.json.parseFromSlice(Receipt, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

// 读取并解析审批凭证文件。
pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Receipt) {
    const bytes = try fs_util.readFileAlloc(io, allocator, path, max_receipt_bytes);
    defer allocator.free(bytes);
    return parseFromSlice(allocator, bytes);
}

// 校验审批凭证是否绑定当前执行上下文。
pub fn validate(receipt: Receipt, context: Context) !void {
    if (!std.mem.eql(u8, receipt.schema_version, schema_version)) return error.InvalidApprovalReceipt;
    try security_validation.validateApprovalTicket(receipt.ticket);
    try audit_operator.validate(receipt.operator);
    try security_validation.validateHost(receipt.host);
    if (!purposeValid(receipt.purpose)) return error.InvalidApprovalReceipt;
    if (receipt.plan_hash) |hash| {
        if (!plan_hash_policy.allows(.{ .allow_hashes = &.{hash} }, hash)) return error.InvalidApprovalReceipt;
    }
    if (receipt.issuer) |issuer| try audit_operator.validate(issuer);
    if (receipt.signature) |signature| try validateSignatureHex(signature);
    if (receipt.signature != null) {
        const key = context.signature_key orelse return error.MissingApprovalReceiptKey;
        if (key.len == 0) return error.InvalidApprovalReceiptKey;
        try verifySignature(receipt, key);
    }
    if (receipt.issued_at) |issued_at| {
        if (receipt.expires_at) |expires_at| {
            if (expires_at < issued_at) return error.ExpiredApprovalReceipt;
        }
    }
    if (receipt.expires_at) |expires_at| {
        if (context.now > expires_at) return error.ExpiredApprovalReceipt;
    }
    const ticket = context.ticket orelse return error.ApprovalReceiptMismatch;
    if (!std.mem.eql(u8, receipt.ticket, ticket)) return error.ApprovalReceiptMismatch;
    if (!std.mem.eql(u8, receipt.operator, context.operator)) return error.ApprovalReceiptMismatch;
    if (!std.mem.eql(u8, receipt.host, context.host)) return error.ApprovalReceiptMismatch;
    if (!std.mem.eql(u8, receipt.purpose, context.purpose)) return error.ApprovalReceiptMismatch;
    if (receipt.plan_hash) |hash| {
        const context_hash = context.plan_hash orelse return error.ApprovalReceiptMismatch;
        if (!std.mem.eql(u8, hash, context_hash)) return error.ApprovalReceiptMismatch;
    }
}

// 生成审批凭证的规范签名 payload，避免依赖 JSON 字段顺序。
pub fn signaturePayloadAlloc(allocator: std.mem.Allocator, receipt: Receipt) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &buffer);
    try writer.writer.print(
        "schema_version={s}\nticket={s}\noperator={s}\nhost={s}\nplan_hash={s}\npurpose={s}\nissued_at={?d}\nexpires_at={?d}\nissuer={s}\n",
        .{
            receipt.schema_version,
            receipt.ticket,
            receipt.operator,
            receipt.host,
            receipt.plan_hash orelse "",
            receipt.purpose,
            receipt.issued_at,
            receipt.expires_at,
            receipt.issuer orelse "",
        },
    );
    return writer.toOwnedSlice();
}

// 计算审批凭证 HMAC-SHA256 签名十六进制文本。
pub fn signatureHexAlloc(allocator: std.mem.Allocator, receipt: Receipt, key: []const u8) ![]const u8 {
    const payload = try signaturePayloadAlloc(allocator, receipt);
    defer allocator.free(payload);
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, payload, key);
    const hex = std.fmt.bytesToHex(mac, .lower);
    return allocator.dupe(u8, &hex);
}

// 使用 HMAC-SHA256 校验审批凭证签名，采用常量时间比较。
fn verifySignature(receipt: Receipt, key: []const u8) !void {
    const expected = try signatureHexAlloc(std.heap.smp_allocator, receipt, key);
    defer std.heap.smp_allocator.free(expected);
    const actual = receipt.signature orelse return error.MissingApprovalReceiptSignature;
    if (actual.len != HmacSha256.mac_length * 2) return error.InvalidApprovalReceiptSignature;
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length * 2]u8, expected[0..HmacSha256.mac_length * 2].*, actual[0..HmacSha256.mac_length * 2].*)) return error.InvalidApprovalReceiptSignature;
}

// 校验审批凭证 purpose 是否为合法值。
fn purposeValid(value: []const u8) bool {
    return std.mem.eql(u8, value, "apply") or std.mem.eql(u8, value, "rollback");
}

// 校验签名十六进制文本的长度和字符合法性。
fn validateSignatureHex(value: []const u8) !void {
    if (value.len != HmacSha256.mac_length * 2) return error.InvalidApprovalReceipt;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return error.InvalidApprovalReceipt;
    }
}

test "approval receipt validates ticket operator host plan hash and expiry" {
    const receipt: Receipt = .{
        .ticket = "OPS-123",
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .plan_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .purpose = "apply",
        .issued_at = 100,
        .expires_at = 200,
        .issuer = "change/platform",
    };

    try validate(receipt, .{
        .ticket = "OPS-123",
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .plan_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .purpose = "apply",
        .now = 150,
    });
    try std.testing.expectError(error.ApprovalReceiptMismatch, validate(receipt, .{
        .ticket = "OPS-124",
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .plan_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .purpose = "apply",
        .now = 150,
    }));
    try std.testing.expectError(error.ExpiredApprovalReceipt, validate(receipt, .{
        .ticket = "OPS-123",
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .plan_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .purpose = "apply",
        .now = 201,
    }));
}

test "approval receipt parser ignores future additive fields" {
    const bytes =
        \\{
        \\  "schema_version": "hostlift.approval_receipt.v1",
        \\  "ticket": "OPS-123",
        \\  "operator": "ops/alice",
        \\  "host": "root@192.0.2.10",
        \\  "purpose": "rollback",
        \\  "unknown_future_field": true
        \\}
    ;

    const parsed = try parseFromSlice(std.testing.allocator, bytes);
    defer parsed.deinit();
    try validate(parsed.value, .{
        .ticket = "OPS-123",
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .purpose = "rollback",
        .now = 123,
    });
}

test "approval receipt verifies hmac signature when present" {
    var receipt: Receipt = .{
        .ticket = "OPS-123",
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .plan_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .purpose = "apply",
        .issued_at = 100,
        .expires_at = 200,
        .issuer = "change/platform",
    };
    const signature = try signatureHexAlloc(std.testing.allocator, receipt, "test-secret");
    defer std.testing.allocator.free(signature);
    receipt.signature = signature;

    try validate(receipt, .{
        .ticket = "OPS-123",
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .plan_hash = receipt.plan_hash,
        .purpose = "apply",
        .now = 150,
        .signature_key = "test-secret",
    });
    try std.testing.expectError(error.InvalidApprovalReceiptSignature, validate(receipt, .{
        .ticket = "OPS-123",
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .plan_hash = receipt.plan_hash,
        .purpose = "apply",
        .now = 150,
        .signature_key = "wrong-secret",
    }));
    try std.testing.expectError(error.MissingApprovalReceiptKey, validate(receipt, .{
        .ticket = "OPS-123",
        .operator = "ops/alice",
        .host = "root@192.0.2.10",
        .plan_hash = receipt.plan_hash,
        .purpose = "apply",
        .now = 150,
    }));
}
