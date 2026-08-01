const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");
const manual_common = @import("manual_common.zig");

// 规划系统基线差异的人工审查动作；这些项目默认不自动写入目标机。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.SystemBaselineInventory,
    target: inventory.SystemBaselineInventory,
) !void {
    for (source.paths) |path| {
        if (!path.present) continue;
        const target_path = findPath(target.paths, path.path);
        if (target_path) |existing| {
            if (!pathDiffers(path, existing)) continue;
        }
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "system-baseline/review-path",
            .name = path.path,
            .subject = path.path,
            .module = .system_baseline,
            .risk = riskForPath(path.kind),
            .description = descriptionForPathFact(path),
        });
    }

    for (source.hosts_entries) |entry| {
        if (findHostsEntry(target.hosts_entries, entry)) |_| continue;
        if (!hasHostsCopyAction(actions.items)) {
            try @import("common.zig").appendAction(allocator, actions, .{
                .id_prefix = "configs/write",
                .name = "/etc/hosts",
                .subject = "/etc/hosts",
                .module = .configs,
                .action_type = .write_file,
                .risk = .high,
                .requires_confirmation = true,
                .description = "Copy or manually merge /etc/hosts after reviewing host mappings",
            });
        }
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "system-baseline/review-hosts",
            .name = entry.address,
            .subject = entry.names,
            .module = .system_baseline,
            .risk = .medium,
            .description = "Review /etc/hosts mapping before manual merge",
        });
    }

    for (source.config_facts) |fact| {
        if (findConfigFact(target.config_facts, fact)) |_| continue;
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "system-baseline/review-config-fact",
            .name = fact.key,
            .subject = fact.source,
            .module = .system_baseline,
            .risk = riskForPath(fact.kind),
            .description = descriptionForConfigFact(fact),
        });
    }

    for (source.commands) |command| {
        if (!command.present or command.line_count == 0) continue;
        if (commandIsCoveredByPathFacts(command.name)) continue;
        const target_command = findCommand(target.commands, command.name);
        if (target_command) |existing| {
            if (existing.present and existing.line_count == command.line_count) continue;
        }
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "system-baseline/review-command",
            .name = command.name,
            .subject = command.name,
            .module = .system_baseline,
            .risk = riskForCommand(command.name),
            .description = descriptionForCommand(command.name),
        });
    }

    for (source.script_apps) |app| {
        if (!app.present) continue;
        if (findScriptApp(target.script_apps, app)) |_| continue;
        var task_inputs: [8]common.ManualInputSpec = undefined;
        var input_count: usize = 0;
        task_inputs[input_count] = .{ .name = "install_path", .value = app.path };
        input_count += 1;
        task_inputs[input_count] = .{ .name = "install_kind", .value = @tagName(app.kind) };
        input_count += 1;
        appendOptionalTaskInput(&task_inputs, &input_count, "source_url", app.source_hint);
        appendOptionalTaskInput(&task_inputs, &input_count, "version", app.version_hint);
        appendOptionalTaskInput(&task_inputs, &input_count, "checksum", app.checksum_hint);
        appendOptionalTaskInput(&task_inputs, &input_count, "config_path", app.config_hint);
        appendOptionalTaskInput(&task_inputs, &input_count, "discovery_evidence", app.evidence);
        task_inputs[input_count] = .{ .name = "reinstall_hint", .value = app.reinstall_hint, .required = false };
        input_count += 1;
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "system-baseline/reinstall-script-app",
            .name = app.path,
            .subject = app.name,
            .module = .system_baseline,
            .risk = .high,
            .description = app.reinstall_hint,
            .task_provider = "script_reinstall",
            .task_inputs = task_inputs[0..input_count],
        });
    }

    if (source.at_jobs_present and source.at_jobs_count != target.at_jobs_count) {
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "system-baseline/review-at-jobs",
            .name = "atq",
            .subject = "at jobs",
            .module = .system_baseline,
            .risk = .high,
            .description = "Review one-shot at jobs before migration; HostLift does not replay them automatically",
        });
    }

    if (source.truncated) {
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "system-baseline/review-truncated",
            .name = "scanner-limit",
            .subject = "system baseline",
            .module = .system_baseline,
            .risk = .high,
            .description = "Review truncated system baseline scan results before migration",
        });
    }
}

fn appendOptionalTaskInput(
    inputs: *[8]common.ManualInputSpec,
    count: *usize,
    name: []const u8,
    value: ?[]const u8,
) void {
    const present = value orelse return;
    inputs[count.*] = .{ .name = name, .value = present, .required = false };
    count.* += 1;
}

// 检查是否已生成 /etc/hosts 写入动作，避免重复。
fn hasHostsCopyAction(actions: []const plan.Action) bool {
    for (actions) |action| {
        if (action.action_type == .write_file and std.mem.eql(u8, action.subject, "/etc/hosts")) return true;
    }
    return false;
}

// 在目标路径列表中查找指定路径。
fn findPath(paths: []const inventory.SystemPathFact, path: []const u8) ?inventory.SystemPathFact {
    for (paths) |candidate| {
        if (std.mem.eql(u8, candidate.path, path)) return candidate;
    }
    return null;
}

// 比较源和目标路径事实是否不同。
fn pathDiffers(source: inventory.SystemPathFact, target: inventory.SystemPathFact) bool {
    return source.present != target.present or
        source.directory != target.directory or
        source.kind != target.kind or
        source.size != target.size or
        source.meaningful_lines != target.meaningful_lines;
}

// 在目标 hosts 条目中查找匹配项。
fn findHostsEntry(entries: []const inventory.HostsEntry, needle: inventory.HostsEntry) ?inventory.HostsEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.address, needle.address) and std.mem.eql(u8, entry.names, needle.names)) return entry;
    }
    return null;
}

// 在目标配置事实中查找完全匹配项。
fn findConfigFact(facts: []const inventory.SystemConfigFact, needle: inventory.SystemConfigFact) ?inventory.SystemConfigFact {
    for (facts) |fact| {
        if (fact.kind == needle.kind and
            std.mem.eql(u8, fact.source, needle.source) and
            std.mem.eql(u8, fact.key, needle.key) and
            std.mem.eql(u8, fact.value, needle.value))
        {
            return fact;
        }
    }
    return null;
}

// 在目标命令列表中查找指定名称。
fn findCommand(commands: []const inventory.CommandFact, name: []const u8) ?inventory.CommandFact {
    for (commands) |command| {
        if (std.mem.eql(u8, command.name, name)) return command;
    }
    return null;
}

// 在目标脚本应用列表中查找匹配项。
fn findScriptApp(apps: []const inventory.ScriptInstallCandidate, needle: inventory.ScriptInstallCandidate) ?inventory.ScriptInstallCandidate {
    for (apps) |app| {
        if (app.kind == needle.kind and std.mem.eql(u8, app.name, needle.name) and std.mem.eql(u8, app.path, needle.path)) return app;
    }
    return null;
}

// 判断命令输出是否已被路径事实覆盖（避免重复审查）。
fn commandIsCoveredByPathFacts(name: []const u8) bool {
    return std.mem.eql(u8, name, "timedatectl") or
        std.mem.eql(u8, name, "locale") or
        std.mem.eql(u8, name, "lsmod") or
        std.mem.eql(u8, name, "atq");
}

// 根据路径类型返回风险等级。
fn riskForPath(kind: inventory.SystemPathKind) plan.RiskLevel {
    return switch (kind) {
        .pam, .identity, .security, .storage, .remote_mount => .critical,
        .kernel_module, .limits, .ntp, .sysctl, .dns, .nss, .network, .timezone, .locale, .system_env, .runtime_env => .high,
        .logrotate, .profile, .tmpfiles, .script_app => .medium,
    };
}

// 根据命令名称返回风险等级。
fn riskForCommand(name: []const u8) plan.RiskLevel {
    if (std.mem.eql(u8, name, "vgs") or
        std.mem.eql(u8, name, "lvs") or
        std.mem.eql(u8, name, "zpool") or
        std.mem.eql(u8, name, "zfs") or
        std.mem.eql(u8, name, "btrfs"))
    {
        return .critical;
    }
    if (std.mem.startsWith(u8, name, "ip-") or
        std.mem.eql(u8, name, "nmcli-connections") or
        std.mem.eql(u8, name, "networkctl"))
    {
        return .high;
    }
    return .high;
}

// 根据路径类型返回审查描述。
fn descriptionForPath(kind: inventory.SystemPathKind) []const u8 {
    return switch (kind) {
        .locale => "Review locale configuration before migration; mismatched locale can change application behavior",
        .timezone => "Review timezone configuration before migration; HostLift does not run timedatectl automatically",
        .storage => "Review storage configuration before migration; device names and encryption mappings are host-specific",
        .remote_mount => "Review NFS/CIFS/autofs configuration before manual migration",
        .kernel_module => "Review kernel module configuration before migration; module availability is kernel-specific",
        .limits => "Review security limits before manual migration",
        .pam => "Review PAM configuration before manual migration; incorrect PAM can break authentication",
        .ntp => "Review NTP/time sync configuration before manual migration",
        .sysctl => "Review sysctl kernel tuning before manual migration",
        .identity => "Review LDAP/SSSD/Kerberos identity configuration before manual migration",
        .logrotate => "Review logrotate configuration before manual migration",
        .profile => "Review system profile scripts before manual migration",
        .tmpfiles => "Review tmpfiles.d configuration before manual migration",
        .dns => "Review DNS resolver configuration before manual migration",
        .nss => "Review NSS lookup chain before manual migration",
        .network => "Review static network configuration before manual migration; HostLift does not reconfigure IP addresses automatically",
        .security => "Review certificates or sensitive security material manually; HostLift does not migrate secrets by default",
        .system_env => "Review system environment variables before migration; global PATH, proxy and runtime variables can change application behavior",
        .runtime_env => "Review language runtime manager state before migration; prefer reinstall or manifest export instead of copying caches blindly",
        .script_app => "Review script-installed application path before reinstalling",
    };
}

fn descriptionForPathFact(path: inventory.SystemPathFact) []const u8 {
    if (path.kind == .security) {
        if (std.mem.startsWith(u8, path.path, "/etc/letsencrypt")) {
            return "Review Let's Encrypt certs, renewal config and account keys manually; decide whether to migrate private keys or issue new certs on target";
        }
        if (std.mem.startsWith(u8, path.path, "/etc/ssl")) {
            return "Review CA bundle, business certificates and private key paths separately; do not copy private keys without explicit confirmation";
        }
        if (std.mem.startsWith(u8, path.path, "/etc/nginx") or
            std.mem.startsWith(u8, path.path, "/etc/caddy") or
            std.mem.startsWith(u8, path.path, "/etc/traefik"))
        {
            return "Review web proxy TLS references and certificate/key dependencies before migration; merge config without blindly copying secrets";
        }
    }
    return descriptionForPath(path.kind);
}

fn descriptionForConfigFact(fact: inventory.SystemConfigFact) []const u8 {
    if (fact.kind == .runtime_env) {
        return "Review language runtime rebuild facts; prefer reinstall/export manifests and avoid copying package caches blindly";
    }
    return descriptionForPath(fact.kind);
}

// 根据命令名称返回审查描述。
fn descriptionForCommand(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "vgs") or std.mem.eql(u8, name, "lvs")) {
        return "Review LVM volume groups and logical volumes before manual migration";
    }
    if (std.mem.eql(u8, name, "zpool") or std.mem.eql(u8, name, "zfs")) {
        return "Review ZFS pools and datasets before manual migration";
    }
    if (std.mem.eql(u8, name, "btrfs")) {
        return "Review Btrfs filesystems and subvolumes before manual migration";
    }
    if (std.mem.startsWith(u8, name, "ip-") or
        std.mem.eql(u8, name, "nmcli-connections") or
        std.mem.eql(u8, name, "networkctl"))
    {
        return "Review network addresses, routes and link definitions before migration; HostLift does not apply network changes automatically";
    }
    return "Review command-derived system baseline fact before migration";
}

test "system baseline review creates manual step for risky source-only path" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer {
        for (actions.items) |action| plan.deinitAction(std.testing.allocator, action);
        actions.deinit(std.testing.allocator);
    }

    var source_paths = [_]inventory.SystemPathFact{.{
        .path = "/etc/pam.d",
        .present = true,
        .directory = true,
        .kind = .pam,
    }};
    try appendActions(std.testing.allocator, &actions, .{ .paths = source_paths[0..] }, .{});

    try std.testing.expectEqual(@as(usize, 1), actions.items.len);
    try std.testing.expectEqual(plan.RiskLevel.critical, actions.items[0].risk);
    try std.testing.expectEqual(plan.ModuleName.system_baseline, actions.items[0].module);
}

test "system baseline script app emits provider-specific reinstall inputs" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer {
        for (actions.items) |action| plan.deinitAction(std.testing.allocator, action);
        actions.deinit(std.testing.allocator);
    }
    var apps = [_]inventory.ScriptInstallCandidate{.{
        .name = "tool",
        .path = "/home/alice/.local/bin/tool",
        .kind = .user_binary,
        .present = true,
        .source_hint = "https://example.invalid/install.sh",
        .version_hint = "1.2.3",
        .checksum_hint = "sha256:abc",
        .config_hint = "/home/alice/.config/tool",
        .reinstall_hint = "download verified artifact",
    }};

    try appendActions(std.testing.allocator, &actions, .{ .script_apps = &apps }, .{});
    try std.testing.expectEqual(@as(usize, 1), actions.items.len);
    try std.testing.expectEqualStrings("system-baseline/reinstall-script-app//home/alice/.local/bin/tool", actions.items[0].id);
    const task = actions.items[0].manual_task.?;
    try std.testing.expectEqual(plan.ManualTaskKind.reinstall, task.kind);
    try std.testing.expectEqualStrings("script_reinstall", task.provider);
    try std.testing.expectEqualStrings("https://example.invalid/install.sh", manualInputValue(task, "source_url").?);
    try std.testing.expectEqualStrings("1.2.3", manualInputValue(task, "version").?);
    try std.testing.expectEqualStrings("sha256:abc", manualInputValue(task, "checksum").?);
    try std.testing.expectEqualStrings("/home/alice/.config/tool", manualInputValue(task, "config_path").?);
}

fn manualInputValue(task: plan.ManualTask, name: []const u8) ?[]const u8 {
    for (task.inputs) |input| {
        if (std.mem.eql(u8, input.name, name)) return input.value;
    }
    return null;
}
