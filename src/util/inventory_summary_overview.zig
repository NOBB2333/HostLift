const inventory = @import("../inventory/schema.zig");
const counts = @import("inventory_summary_counts.zig");

// 输出清单摘要的主机、包、服务、用户和运行时概览。
pub fn writeOverview(writer: anytype, value: inventory.Inventory) !void {
    const modules = value.modules;
    const service_counts = counts.countServices(modules.services.units);

    try writer.print(
        \\HostLift inventory summary
        \\Host: {s}
        \\Distro: {s} {s} ({s})
        \\Kernel: {s}
        \\Arch: {s}
        \\Package manager: {s} - {s}
        \\
    , .{
        value.host.hostname,
        value.distro.id,
        value.distro.version_id,
        value.distro.pretty_name,
        value.host.kernel_release,
        @tagName(value.host.arch),
        @tagName(value.package_manager.kind),
        value.package_manager.version,
    });

    try writer.print(
        \\Packages:
        \\  Explicit packages: {d}
        \\  Held packages: {d}
        \\  Repository config files: {d}
        \\
    , .{
        modules.packages.explicit.len,
        modules.packages.held.len,
        value.package_manager.repos.len,
    });

    try writer.print(
        \\Services:
        \\  Init system: {s}
        \\  Total units: {d}
        \\  Enabled: {d}
        \\  Disabled: {d}
        \\  Static/generated/indirect: {d}
        \\  Masked: {d}
        \\  Active/running: {d}
        \\  Custom units: {d}
        \\  Timers: {d}
        \\  Sockets: {d}
        \\  User systemd units: {d}
        \\  XDG autostart entries: {d}
        \\  SysV init scripts: {d}
        \\  OpenRC services: {d}
        \\
    , .{
        modules.services.init_system,
        modules.services.units.len,
        service_counts.enabled,
        service_counts.disabled,
        service_counts.static_like,
        service_counts.masked,
        service_counts.active_like,
        service_counts.custom,
        modules.services.timers.len,
        modules.services.sockets.len,
        modules.services.user_units.len,
        modules.services.xdg_autostart.len,
        modules.services.sysv_init.len,
        modules.services.openrc.len,
    });

    try writer.print(
        \\Users and SSH:
        \\  Users: {d} ({d} non-system)
        \\  Groups: {d} ({d} non-system)
        \\  authorized_keys files: {d}
        \\  sshd_config present: {}
        \\  sudoers paths present: {d}{s}
        \\  Paths with extended ACL: {d}
        \\  SELinux: {s}
        \\  AppArmor: {s}
        \\
    , .{
        modules.users.users.len,
        counts.countNonSystemUsers(modules.users.users),
        modules.users.groups.len,
        counts.countNonSystemGroups(modules.users.groups),
        modules.ssh.authorized_keys.len,
        modules.ssh.sshd_config_present,
        counts.countPresentSudoersEntries(modules.sudoers.entries),
        if (modules.sudoers.truncated) " (truncated)" else "",
        counts.countExtendedAclPaths(modules.acl.paths),
        @tagName(modules.security_policy.selinux.status),
        @tagName(modules.security_policy.apparmor.status),
    });

    try writer.print(
        \\Cron and configs:
        \\  Cron sources: {d}
        \\  Present config paths: {d}
        \\  System baseline paths present: {d}{s}
        \\  System baseline config facts: {d}
        \\  /etc/hosts entries: {d}
        \\  Script-installed app candidates: {d}
        \\  at jobs: {d}
        \\
    , .{
        modules.cron.entries.len,
        counts.countPresentConfigs(modules.configs.files),
        counts.countPresentSystemBaselinePaths(modules.system_baseline.paths),
        if (modules.system_baseline.truncated) " (truncated)" else "",
        modules.system_baseline.config_facts.len,
        modules.system_baseline.hosts_entries.len,
        counts.countPresentScriptApps(modules.system_baseline.script_apps),
        modules.system_baseline.at_jobs_count,
    });

    try writer.print(
        \\Developer environment:
        \\  Tools detected: {d}
        \\  Present dev config paths: {d}
        \\  Present home config paths: {d}{s}
        \\  Proxy environment variables present: {d}
        \\
    , .{
        counts.countPresentDevTools(modules.dev_env.tools),
        counts.countPresentDevConfigs(modules.dev_env.configs),
        counts.countPresentHomeConfigs(modules.home_configs.configs),
        if (modules.home_configs.truncated) " (truncated)" else "",
        counts.countPresentProxyVars(modules.dev_env.proxy_vars),
    });

    try writer.print(
        \\App data and processes:
        \\  Present app/data paths: {d}
        \\  Detected projects: {d}{s}
        \\  Process summaries: {d}{s}
        \\  Listening sockets: {d}{s}
        \\  Container runtimes detected: {d}
        \\  Running containers: {d}{s}
        \\  Container volumes: {d}
        \\  Container networks: {d}
        \\  Container images: {d}
        \\  Compose files: {d}
        \\  fstab entries: {d}
        \\  Physical/remote mounts: {d}{s}
        \\
    , .{
        counts.countPresentDataPaths(modules.appdata.paths),
        modules.projects.projects.len,
        if (modules.projects.truncated) " (truncated)" else "",
        modules.processes.processes.len,
        if (modules.processes.truncated) " (truncated)" else "",
        modules.network.listeners.len,
        if (modules.network.truncated) " (truncated)" else "",
        counts.countAvailableContainerRuntimes(modules.docker.runtimes),
        modules.docker.containers.len,
        if (modules.docker.truncated) " (truncated)" else "",
        modules.docker.volumes.len,
        modules.docker.networks.len,
        modules.docker.images.len,
        modules.docker.compose_files.len,
        modules.storage.fstab_entries.len,
        counts.countPhysicalOrRemoteMounts(modules.storage.mounts),
        if (modules.storage.truncated) " (truncated)" else "",
    });

    try writer.print(
        \\Firewall:
        \\  Backend: {s}
        \\  Present config paths: {d}
        \\
    , .{
        @tagName(modules.firewall.backend),
        counts.countPresentFirewallConfigs(modules.firewall.configs),
    });
}
