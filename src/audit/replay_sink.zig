const std = @import("std");
const http_sink = @import("http_sink.zig");
const sink_target = @import("sink_target.zig");
const syslog_sink = @import("syslog_sink.zig");

pub const RawSink = union(enum) {
    file: FileReplaySink,
    http: HttpReplaySink,
    syslog: SyslogReplaySink,

    // 打开审计重放 sink，用于写入已验证的原始 JSONL 行。
    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        target: sink_target.Target,
        file_buffer: []u8,
    ) !RawSink {
        return switch (target) {
            .file => |path| .{ .file = try FileReplaySink.open(io, path, file_buffer) },
            .http => |endpoint| .{ .http = HttpReplaySink.open(io, allocator, endpoint) },
            .syslog => |facility| .{ .syslog = SyslogReplaySink.open(io, allocator, facility) },
        };
    }

    // 关闭重放 sink。
    pub fn close(self: *RawSink) void {
        switch (self.*) {
            .file => |*sink| sink.close(),
            .http => |*sink| sink.close(),
            .syslog => |*sink| sink.close(),
        }
    }

    // 刷新重放 sink。
    pub fn flush(self: *RawSink) !void {
        switch (self.*) {
            .file => |*sink| try sink.flush(),
            .http => |*sink| try sink.flush(),
            .syslog => |*sink| try sink.flush(),
        }
    }

    // 写入一条原始审计 JSONL 行。
    pub fn writeLine(self: *RawSink, line: []const u8) !void {
        switch (self.*) {
            .file => |*sink| try sink.writeLine(line),
            .http => |*sink| try sink.writeLine(line),
            .syslog => |*sink| try sink.writeLine(line),
        }
    }
};

// 本地文件重放 sink，写入原始审计 JSONL 行。
const FileReplaySink = struct {
    io: std.Io,
    file: std.Io.File,
    writer: std.Io.File.Writer,

    // 打开文件重放 sink。
    fn open(io: std.Io, path: []const u8, file_buffer: []u8) !FileReplaySink {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        return .{
            .io = io,
            .file = file,
            .writer = file.writer(io, file_buffer),
        };
    }

    // 关闭文件 sink。
    fn close(self: *FileReplaySink) void {
        self.file.close(self.io);
    }

    // 刷新文件写入缓冲。
    fn flush(self: *FileReplaySink) !void {
        try self.writer.flush();
    }

    // 写入一行 JSONL 到文件。
    fn writeLine(self: *FileReplaySink, line: []const u8) !void {
        try self.writer.interface.writeAll(line);
        try self.writer.interface.writeByte('\n');
    }
};

// HTTPS 远程重放 sink，通过 curl 发送原始审计行。
const HttpReplaySink = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    endpoint: []const u8,

    // 打开 HTTPS 重放 sink。
    fn open(io: std.Io, allocator: std.mem.Allocator, endpoint: []const u8) HttpReplaySink {
        return .{ .io = io, .allocator = allocator, .endpoint = endpoint };
    }

    // 关闭 HTTPS sink（无状态，空操作）。
    fn close(self: *HttpReplaySink) void {
        _ = self;
    }

    // 刷新 HTTPS sink（无状态，空操作）。
    fn flush(self: *HttpReplaySink) !void {
        _ = self;
    }

    // 通过 curl 发送一行 JSONL 到 HTTPS 端点。
    fn writeLine(self: *HttpReplaySink, line: []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try http_sink.appendCurlArgv(self.allocator, &argv, self.endpoint, line);
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.HttpAuditSinkFailed,
            else => return error.HttpAuditSinkFailed,
        }
    }
};

// syslog 重放 sink，通过 logger 写入本机 syslog。
const SyslogReplaySink = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    facility: []const u8,

    // 打开 syslog 重放 sink。
    fn open(io: std.Io, allocator: std.mem.Allocator, facility: []const u8) SyslogReplaySink {
        return .{ .io = io, .allocator = allocator, .facility = facility };
    }

    // 关闭 syslog sink（无状态，空操作）。
    fn close(self: *SyslogReplaySink) void {
        _ = self;
    }

    // 刷新 syslog sink（无状态，空操作）。
    fn flush(self: *SyslogReplaySink) !void {
        _ = self;
    }

    // 通过 logger 发送一行到 syslog。
    fn writeLine(self: *SyslogReplaySink, line: []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer {
            if (argv.items.len >= 3) self.allocator.free(argv.items[2]);
            argv.deinit(self.allocator);
        }
        try syslog_sink.appendLoggerArgv(self.allocator, &argv, self.facility, line);
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(16 * 1024),
            .stderr_limit = .limited(16 * 1024),
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.SyslogAuditSinkFailed,
            else => return error.SyslogAuditSinkFailed,
        }
    }
};
