const std = @import("std");
const probe = @import("probe.zig");
const schema = @import("schema.zig");

// 扫描监听 socket，尽量提取协议、地址、端口和进程名。
pub fn scan(io: std.Io, allocator: std.mem.Allocator) !schema.NetworkInventory {
    const lines = probe.runLines(io, allocator, &.{ "ss", "-H", "-lntup" }, 2 * 1024 * 1024) catch return .{
        .listeners = try allocator.alloc(schema.ListeningSocket, 0),
        .truncated = false,
    };
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    var listeners: std.ArrayList(schema.ListeningSocket) = .empty;
    errdefer {
        for (listeners.items) |listener| {
            allocator.free(listener.protocol);
            allocator.free(listener.address);
            if (listener.process) |process| allocator.free(process);
        }
        listeners.deinit(allocator);
    }

    var truncated = false;
    for (lines) |line| {
        if (listeners.items.len >= 512) {
            truncated = true;
            break;
        }
        const parsed = parseListeningSocketLine(line) orelse continue;
        try listeners.append(allocator, .{
            .protocol = try allocator.dupe(u8, parsed.protocol),
            .address = try allocator.dupe(u8, parsed.address),
            .port = parsed.port,
            .process = if (parsed.process) |process| try allocator.dupe(u8, process) else null,
        });
    }

    return .{
        .listeners = try listeners.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

// 解析后的监听 socket 信息，含协议、地址、端口和进程。
const ParsedListeningSocket = struct {
    protocol: []const u8,
    address: []const u8,
    port: u16,
    process: ?[]const u8,
};

// 解析 ss -lntup 的单行监听 socket 输出。
fn parseListeningSocketLine(line: []const u8) ?ParsedListeningSocket {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    const protocol = tokens.next() orelse return null;
    var endpoint: ?[]const u8 = null;
    while (tokens.next()) |token| {
        if (std.mem.startsWith(u8, token, "users:")) break;
        if (parseEndpoint(token)) |_| {
            endpoint = token;
        }
    }
    const local_endpoint = endpoint orelse return null;
    const parsed_endpoint = parseEndpoint(local_endpoint) orelse return null;
    return .{
        .protocol = protocol,
        .address = parsed_endpoint.address,
        .port = parsed_endpoint.port,
        .process = parseSocketProcess(line),
    };
}

// 解析后的网络端点，含地址和端口。
const ParsedEndpoint = struct {
    address: []const u8,
    port: u16,
};

// 解析监听地址和端口。
fn parseEndpoint(endpoint: []const u8) ?ParsedEndpoint {
    const colon = std.mem.lastIndexOfScalar(u8, endpoint, ':') orelse return null;
    if (colon + 1 >= endpoint.len) return null;
    const port_text = endpoint[colon + 1 ..];
    if (std.mem.eql(u8, port_text, "*")) return null;
    const port = std.fmt.parseUnsigned(u16, port_text, 10) catch return null;
    var address = endpoint[0..colon];
    if (address.len >= 2 and address[0] == '[' and address[address.len - 1] == ']') {
        address = address[1 .. address.len - 1];
    }
    return .{ .address = address, .port = port };
}

// 从 ss 输出中提取进程名。
fn parseSocketProcess(line: []const u8) ?[]const u8 {
    const users_index = std.mem.indexOf(u8, line, "users:((\"") orelse return null;
    const start = users_index + "users:((\"".len;
    const rest = line[start..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

test "listening socket parser extracts endpoint and process" {
    const line = "tcp LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:* users:((\"nginx\",pid=123,fd=7))";
    const parsed = parseListeningSocketLine(line).?;
    try std.testing.expectEqualStrings("tcp", parsed.protocol);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.address);
    try std.testing.expectEqual(@as(u16, 8080), parsed.port);
    try std.testing.expectEqualStrings("nginx", parsed.process.?);

    const ipv6 = parseEndpoint("[::]:443").?;
    try std.testing.expectEqualStrings("::", ipv6.address);
    try std.testing.expectEqual(@as(u16, 443), ipv6.port);
}
