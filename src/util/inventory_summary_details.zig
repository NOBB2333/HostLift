const inventory = @import("../inventory/schema.zig");
const dev = @import("inventory_summary_dev.zig");
const runtime = @import("inventory_summary_runtime.zig");
const system = @import("inventory_summary_system.zig");

// 输出所有清单详情章节，顶层摘要之外的明细都集中在这里。
pub fn writeDetails(writer: anytype, value: inventory.Inventory) !void {
    const modules = value.modules;
    try system.writeRepositorySummary(writer, value.package_manager.repos);
    try system.writePackageSummary(writer, modules.packages.explicit);
    try system.writeCustomServiceSummary(writer, modules.services.units);
    try system.writeSystemdTimerSummary(writer, modules.services.timers);
    try system.writeSystemdSocketSummary(writer, modules.services.sockets);
    try system.writeUserSystemdUnitSummary(writer, modules.services.user_units);
    try system.writeXdgAutostartSummary(writer, modules.services.xdg_autostart);
    try system.writeSysvInitSummary(writer, modules.services.sysv_init);
    try system.writeOpenRcSummary(writer, modules.services.openrc);
    try system.writeUserSummary(writer, modules.users.users);
    try system.writeSshdConfigSummary(writer, modules.ssh);
    try system.writeCronSummary(writer, modules.cron.entries);
    try system.writeSudoersSummary(writer, modules.sudoers);
    try system.writeAclSummary(writer, modules.acl);
    try system.writeSecurityPolicySummary(writer, modules.security_policy);
    try system.writeSystemBaselineSummary(writer, modules.system_baseline);
    try system.writeConfigSummary(writer, modules.configs.files);
    try dev.writeDevEnvSummary(writer, modules.dev_env);
    try dev.writeHomeConfigSummary(writer, modules.home_configs);
    try dev.writeAppDataSummary(writer, modules.appdata);
    try runtime.writeProjectSummary(writer, modules.projects, modules.docker);
    try runtime.writeProcessSummary(writer, modules.processes);
    try runtime.writeNetworkSummary(writer, modules.network);
    try runtime.writeDockerSummary(writer, modules.docker);
    try runtime.writeStorageSummary(writer, modules.storage);
    try system.writeFirewallSummary(writer, modules.firewall);
}
