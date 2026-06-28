const inventory = @import("../inventory/schema.zig");
const counts = @import("inventory_summary_counts.zig");

// 输出仓库配置文件摘要。
pub fn writeRepositorySummary(writer: anytype, repos: []const inventory.RepositoryRef) !void {
    if (repos.len == 0) return;
    try writer.writeAll("\nRepository config files:\n");
    for (repos[0..@min(repos.len, 12)]) |repo| {
        try writer.print("  - {s}\n", .{repo.id});
    }
    if (repos.len > 12) try writer.print("  ... {d} more\n", .{repos.len - 12});
}

// 输出显式安装包摘要。
pub fn writePackageSummary(writer: anytype, packages: []const []const u8) !void {
    if (packages.len == 0) return;
    try writer.writeAll("\nExplicit packages (first 30):\n");
    for (packages[0..@min(packages.len, 30)]) |pkg| {
        try writer.print("  - {s}\n", .{pkg});
    }
    if (packages.len > 30) try writer.print("  ... {d} more\n", .{packages.len - 30});
}

// 输出启用或自定义 service 摘要。
pub fn writeCustomServiceSummary(writer: anytype, units: []const inventory.ServiceUnit) !void {
    var wrote_header = false;
    var shown: usize = 0;
    var total: usize = 0;
    for (units) |unit| {
        if (!unit.custom and unit.state != .enabled and !isActiveLike(unit.active_state)) continue;
        total += 1;
        if (shown >= 40) continue;
        if (!wrote_header) {
            try writer.writeAll("\nEnabled or custom services:\n");
            wrote_header = true;
        }
        try writer.print("  - {s} [{s}, {s}{s}]", .{ unit.name, @tagName(unit.state), @tagName(unit.active_state), if (unit.custom) ", custom" else "" });
        if (unit.dependency_summary) |summary| try writer.print(" deps={s}", .{summary});
        try writer.writeByte('\n');
        shown += 1;
    }
    if (total > shown) try writer.print("  ... {d} more\n", .{total - shown});
}

// 判断 systemd 活跃状态是否属于 "运行中" 类别。
fn isActiveLike(state: inventory.ServiceActiveState) bool {
    return switch (state) {
        .active, .reloading, .activating => true,
        .inactive, .failed, .deactivating, .maintenance, .unknown => false,
    };
}

// 输出 systemd timer 和它激活的 unit。
pub fn writeSystemdTimerSummary(writer: anytype, timers: []const inventory.SystemdTimer) !void {
    if (timers.len == 0) return;
    try writer.writeAll("\nSystemd timers:\n");
    for (timers[0..@min(timers.len, 40)]) |timer| {
        try writer.print("  - {s} -> {s} [{s}, {s}{s}]\n", .{ timer.name, timer.activates, @tagName(timer.state), timer.schedule, if (timer.custom) ", custom" else "" });
    }
    if (timers.len > 40) try writer.print("  ... {d} more\n", .{timers.len - 40});
}

// 输出 systemd socket 和它激活的 unit。
pub fn writeSystemdSocketSummary(writer: anytype, sockets: []const inventory.SystemdSocket) !void {
    if (sockets.len == 0) return;
    try writer.writeAll("\nSystemd sockets:\n");
    for (sockets[0..@min(sockets.len, 40)]) |socket| {
        if (socket.activates) |activates| {
            try writer.print("  - {s} -> {s} [{s}{s}]\n", .{ socket.name, activates, @tagName(socket.state), if (socket.custom) ", custom" else "" });
        } else {
            try writer.print("  - {s} [{s}{s}]\n", .{ socket.name, @tagName(socket.state), if (socket.custom) ", custom" else "" });
        }
    }
    if (sockets.len > 40) try writer.print("  ... {d} more\n", .{sockets.len - 40});
}

// 输出用户级 systemd unit 摘要，不读取 unit 文件正文。
pub fn writeUserSystemdUnitSummary(writer: anytype, units: []const inventory.UserSystemdUnit) !void {
    if (units.len == 0) return;
    try writer.writeAll("\nUser systemd units:\n");
    for (units[0..@min(units.len, 40)]) |unit| {
        try writer.print("  - {s}:{s} [{s}{s}] {s}\n", .{
            unit.user,
            unit.name,
            @tagName(unit.kind),
            if (unit.enabled) ", enabled" else "",
            unit.path,
        });
    }
    if (units.len > 40) try writer.print("  ... {d} more\n", .{units.len - 40});
}

// 输出 XDG autostart 条目摘要，不读取 desktop 文件正文。
pub fn writeXdgAutostartSummary(writer: anytype, entries: []const inventory.XdgAutostartEntry) !void {
    if (entries.len == 0) return;
    try writer.writeAll("\nXDG autostart entries:\n");
    for (entries[0..@min(entries.len, 40)]) |entry| {
        if (entry.user) |user| {
            try writer.print("  - {s}:{s} [{s}] {s}\n", .{ user, entry.name, @tagName(entry.scope), entry.path });
        } else {
            try writer.print("  - {s} [{s}] {s}\n", .{ entry.name, @tagName(entry.scope), entry.path });
        }
    }
    if (entries.len > 40) try writer.print("  ... {d} more\n", .{entries.len - 40});
}

// 输出 SysV init 脚本摘要，不读取脚本正文。
pub fn writeSysvInitSummary(writer: anytype, scripts: []const inventory.SysvInitScript) !void {
    if (scripts.len == 0) return;
    try writer.writeAll("\nSysV init scripts:\n");
    for (scripts[0..@min(scripts.len, 40)]) |script| {
        try writer.print("  - {s} [{s}] {s}\n", .{ script.name, if (script.enabled) script.runlevels else "disabled", script.path });
    }
    if (scripts.len > 40) try writer.print("  ... {d} more\n", .{scripts.len - 40});
}

// 输出 OpenRC service 摘要，不读取脚本正文。
pub fn writeOpenRcSummary(writer: anytype, services: []const inventory.OpenRcService) !void {
    if (services.len == 0) return;
    try writer.writeAll("\nOpenRC services:\n");
    for (services[0..@min(services.len, 40)]) |service| {
        try writer.print("  - {s} [{s}] {s}\n", .{ service.name, if (service.enabled) service.runlevels else "disabled", service.path });
    }
    if (services.len > 40) try writer.print("  ... {d} more\n", .{services.len - 40});
}

// 输出非系统用户摘要。
pub fn writeUserSummary(writer: anytype, users: []const inventory.UserAccount) !void {
    var wrote_header = false;
    for (users) |user| {
        if (counts.isNoiseUser(user)) continue;
        if (!wrote_header) {
            try writer.writeAll("\nNon-system users:\n");
            wrote_header = true;
        }
        try writer.print("  - {s} uid={d} gid={d} home={s} shell={s}\n", .{ user.name, user.uid, user.gid, user.home, user.shell });
    }
}

// 输出 sshd_config 关键指令摘要，不输出私钥或 HostKey 内容。
pub fn writeSshdConfigSummary(writer: anytype, ssh: inventory.SshInventory) !void {
    if (ssh.sshd_config.len == 0) return;
    try writer.writeAll("\nsshd_config key directives:\n");
    for (ssh.sshd_config[0..@min(ssh.sshd_config.len, 40)]) |fact| {
        try writer.print("  - {s} {s}\n", .{ fact.key, fact.value });
    }
    if (ssh.sshd_config.len > 40) try writer.print("  ... {d} more\n", .{ssh.sshd_config.len - 40});
}

// 输出 cron 来源摘要。
pub fn writeCronSummary(writer: anytype, entries: []const inventory.CronEntry) !void {
    if (entries.len == 0) return;
    try writer.writeAll("\nCron sources:\n");
    for (entries) |entry| {
        if (entry.owner) |owner| {
            try writer.print("  - {s} owner={s} lines={d}\n", .{ entry.source, owner, entry.line_count });
        } else {
            try writer.print("  - {s} lines={d}\n", .{ entry.source, entry.line_count });
        }
    }
}

// 输出 sudoers 路径摘要，不输出授权规则内容。
pub fn writeSudoersSummary(writer: anytype, sudoers: inventory.SudoersInventory) !void {
    var wrote_header = false;
    for (sudoers.entries) |entry| {
        if (!entry.present) continue;
        if (!wrote_header) {
            try writer.writeAll("\nSudoers paths:\n");
            wrote_header = true;
        }
        if (entry.mode) |mode| {
            try writer.print("  - {s} [{s}] mode={o} lines={d} size={d}\n", .{ entry.path, @tagName(entry.kind), mode, entry.meaningful_lines, entry.size });
        } else {
            try writer.print("  - {s} [{s}] lines={d} size={d}\n", .{ entry.path, @tagName(entry.kind), entry.meaningful_lines, entry.size });
        }
    }
    if (sudoers.truncated) try writer.writeAll("  ... sudoers.d truncated\n");
}

// 输出扩展 ACL 路径摘要，不输出 ACL 条目正文。
pub fn writeAclSummary(writer: anytype, acl: inventory.AclInventory) !void {
    if (!acl.getfacl_available and acl.paths.len == 0) return;
    try writer.print("\nACL scan:\n  getfacl available: {}\n", .{acl.getfacl_available});
    var shown = false;
    for (acl.paths) |path| {
        if (!path.present or !path.has_extended_acl) continue;
        if (!shown) {
            try writer.writeAll("  Paths with extended ACL:\n");
            shown = true;
        }
        try writer.print("    - {s}{s}\n", .{ path.path, if (path.directory) " [dir]" else "" });
    }
    if (acl.truncated) try writer.writeAll("  ... ACL path list truncated\n");
}

// 输出 SELinux/AppArmor 状态摘要，不输出策略正文。
pub fn writeSecurityPolicySummary(writer: anytype, policy: inventory.SecurityPolicyInventory) !void {
    if (!policy.selinux.present and !policy.apparmor.present) return;
    try writer.writeAll("\nSecurity policy:\n");
    if (policy.selinux.present) {
        try writer.print(
            "  - SELinux status={s} config_present={} policy_dirs={d}\n",
            .{ @tagName(policy.selinux.status), policy.selinux.config_present, policy.selinux.policy_dirs },
        );
    }
    if (policy.apparmor.present) {
        try writer.print(
            "  - AppArmor status={s} profiles_loaded={d} config_dirs={d}\n",
            .{ @tagName(policy.apparmor.status), policy.apparmor.profiles_loaded, policy.apparmor.config_dirs },
        );
    }
}

// 输出系统基线路径、hosts 和脚本安装应用摘要，不输出敏感配置正文。
pub fn writeSystemBaselineSummary(writer: anytype, baseline: inventory.SystemBaselineInventory) !void {
    var wrote_paths = false;
    for (baseline.paths) |path| {
        if (!path.present) continue;
        if (!wrote_paths) {
            try writer.writeAll("\nSystem baseline paths:\n");
            wrote_paths = true;
        }
        try writer.print("  - {s} [{s}{s}] size={d} lines={d}\n", .{
            path.path,
            @tagName(path.kind),
            if (path.directory) ", directory" else "",
            path.size,
            path.meaningful_lines,
        });
    }
    if (baseline.config_facts.len > 0) {
        try writer.writeAll("\nSystem baseline config facts:\n");
        for (baseline.config_facts[0..@min(baseline.config_facts.len, 60)]) |fact| {
            try writer.print("  - [{s}] {s}: {s}={s}\n", .{ @tagName(fact.kind), fact.source, fact.key, fact.value });
        }
        if (baseline.config_facts.len > 60) try writer.print("  ... {d} more\n", .{baseline.config_facts.len - 60});
    }
    if (baseline.hosts_entries.len > 0) {
        try writer.writeAll("\n/etc/hosts entries:\n");
        for (baseline.hosts_entries[0..@min(baseline.hosts_entries.len, 40)]) |entry| {
            try writer.print("  - {s} {s}\n", .{ entry.address, entry.names });
        }
        if (baseline.hosts_entries.len > 40) try writer.print("  ... {d} more\n", .{baseline.hosts_entries.len - 40});
    }
    if (baseline.script_apps.len > 0) {
        try writer.writeAll("\nScript-installed app candidates:\n");
        for (baseline.script_apps[0..@min(baseline.script_apps.len, 40)]) |app| {
            try writer.print("  - {s} [{s}] {s}", .{ app.name, @tagName(app.kind), app.path });
            if (app.evidence) |evidence| try writer.print(" evidence={s}", .{evidence});
            if (app.source_hint) |hint| try writer.print(" source={s}", .{hint});
            if (app.version_hint) |hint| try writer.print(" version={s}", .{hint});
            if (app.checksum_hint) |hint| try writer.print(" checksum={s}", .{hint});
            if (app.config_hint) |hint| try writer.print(" config={s}", .{hint});
            try writer.writeByte('\n');
        }
        if (baseline.script_apps.len > 40) try writer.print("  ... {d} more\n", .{baseline.script_apps.len - 40});
    }
    if (baseline.at_jobs_present) {
        try writer.print("\nAt jobs:\n  - queued jobs: {d}\n", .{baseline.at_jobs_count});
    }
    if (baseline.truncated) try writer.writeAll("  ... system baseline list truncated\n");
}

// 输出存在的配置路径摘要。
pub fn writeConfigSummary(writer: anytype, files: []const inventory.ConfigFile) !void {
    var wrote_header = false;
    for (files) |file| {
        if (!file.present) continue;
        if (!wrote_header) {
            try writer.writeAll("\nPresent config paths:\n");
            wrote_header = true;
        }
        try writer.print("  - {s} ({d} bytes)\n", .{ file.path, file.size });
    }
}

// 输出防火墙配置路径摘要。
pub fn writeFirewallSummary(writer: anytype, firewall: inventory.FirewallInventory) !void {
    var wrote_header = false;
    for (firewall.configs) |config| {
        if (!config.present) continue;
        if (!wrote_header) {
            try writer.writeAll("\nFirewall config paths:\n");
            wrote_header = true;
        }
        try writer.print("  - {s} ({d} bytes)\n", .{ config.path, config.size });
    }
}
