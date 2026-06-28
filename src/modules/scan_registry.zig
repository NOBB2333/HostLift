const handler = @import("handler.zig");

const acl_scanner = @import("../inventory/acl.zig");
const appdata_scanner = @import("../inventory/appdata.zig");
const configs_scanner = @import("../inventory/configs.zig");
const cron_scanner = @import("../inventory/cron.zig");
const dev_env_scanner = @import("../inventory/dev_env.zig");
const docker_scanner = @import("../inventory/docker.zig");
const firewall_scanner = @import("../inventory/firewall.zig");
const home_configs_scanner = @import("../inventory/home_configs.zig");
const network_scanner = @import("../inventory/network.zig");
const packages_scanner = @import("../inventory/packages.zig");
const processes_scanner = @import("../inventory/processes.zig");
const projects_scanner = @import("../inventory/projects.zig");
const resources_scanner = @import("../inventory/resources.zig");
const security_policy_scanner = @import("../inventory/security_policy.zig");
const services_scanner = @import("../inventory/services.zig");
const ssh_scanner = @import("../inventory/ssh.zig");
const storage_scanner = @import("../inventory/storage.zig");
const system_baseline_scanner = @import("../inventory/system_baseline.zig");
const sudoers_scanner = @import("../inventory/sudoers.zig");
const users_scanner = @import("../inventory/users.zig");

const ScanContext = handler.ScanContext;
const ModuleHandler = handler.ModuleHandler;

const scan_handlers = [_]ModuleHandler{
    .{ .name = .packages, .scan = scanPackages },
    .{ .name = .services, .scan = scanServices },
    .{ .name = .cron, .scan = scanCron },
    .{ .name = .users, .scan = scanUsers },
    .{ .name = .ssh, .scan = scanSsh },
    .{ .name = .sudoers, .scan = scanSudoers },
    .{ .name = .acl, .scan = scanAcl },
    .{ .name = .configs, .scan = scanConfigs },
    .{ .name = .dev_env, .scan = scanDevEnv },
    .{ .name = .home_configs, .scan = scanHomeConfigs },
    .{ .name = .appdata, .scan = scanAppData },
    .{ .name = .projects, .scan = scanProjects },
    .{ .name = .processes, .scan = scanProcesses },
    .{ .name = .network, .scan = scanNetwork },
    .{ .name = .docker, .scan = scanDocker },
    .{ .name = .firewall, .scan = scanFirewall },
    .{ .name = .resources, .scan = scanResources },
    .{ .name = .storage, .scan = scanStorage },
    .{ .name = .system_baseline, .scan = scanSystemBaseline },
    .{ .name = .security_policy, .scan = scanSecurityPolicy },
};

// 返回所有已接入扫描生命周期的模块处理器。
pub fn allScan() []const ModuleHandler {
    return &scan_handlers;
}

// 以下为各模块扫描器到 ScanContext 的适配函数。
fn scanPackages(ctx: ScanContext) !void {
    ctx.modules.packages = try packages_scanner.scan(ctx.io, ctx.allocator);
}
fn scanServices(ctx: ScanContext) !void {
    ctx.modules.services = try services_scanner.scan(ctx.io, ctx.allocator);
}
fn scanCron(ctx: ScanContext) !void {
    ctx.modules.cron = try cron_scanner.scan(ctx.io, ctx.allocator);
}
fn scanUsers(ctx: ScanContext) !void {
    ctx.modules.users = try users_scanner.scan(ctx.io, ctx.allocator);
}
fn scanSsh(ctx: ScanContext) !void {
    ctx.modules.ssh = try ssh_scanner.scan(ctx.io, ctx.allocator);
}
fn scanSudoers(ctx: ScanContext) !void {
    ctx.modules.sudoers = try sudoers_scanner.scan(ctx.io, ctx.allocator);
}
fn scanAcl(ctx: ScanContext) !void {
    ctx.modules.acl = try acl_scanner.scan(ctx.io, ctx.allocator);
}
fn scanConfigs(ctx: ScanContext) !void {
    ctx.modules.configs = try configs_scanner.scan(ctx.io, ctx.allocator);
}
fn scanDevEnv(ctx: ScanContext) !void {
    ctx.modules.dev_env = try dev_env_scanner.scan(ctx.io, ctx.allocator);
}
fn scanHomeConfigs(ctx: ScanContext) !void {
    ctx.modules.home_configs = try home_configs_scanner.scan(ctx.io, ctx.allocator);
}
fn scanAppData(ctx: ScanContext) !void {
    ctx.modules.appdata = try appdata_scanner.scan(ctx.io, ctx.allocator);
}
fn scanProjects(ctx: ScanContext) !void {
    ctx.modules.projects = try projects_scanner.scan(ctx.io, ctx.allocator);
}
fn scanProcesses(ctx: ScanContext) !void {
    ctx.modules.processes = try processes_scanner.scan(ctx.io, ctx.allocator);
}
fn scanNetwork(ctx: ScanContext) !void {
    ctx.modules.network = try network_scanner.scan(ctx.io, ctx.allocator);
}
fn scanDocker(ctx: ScanContext) !void {
    ctx.modules.docker = try docker_scanner.scan(ctx.io, ctx.allocator);
}
fn scanFirewall(ctx: ScanContext) !void {
    ctx.modules.firewall = try firewall_scanner.scan(ctx.io, ctx.allocator);
}
fn scanResources(ctx: ScanContext) !void {
    ctx.modules.resources = try resources_scanner.scan(ctx.io, ctx.allocator, ctx.modules.*);
}
fn scanStorage(ctx: ScanContext) !void {
    ctx.modules.storage = try storage_scanner.scan(ctx.io, ctx.allocator);
}
fn scanSystemBaseline(ctx: ScanContext) !void {
    ctx.modules.system_baseline = try system_baseline_scanner.scan(ctx.io, ctx.allocator);
}
fn scanSecurityPolicy(ctx: ScanContext) !void {
    ctx.modules.security_policy = try security_policy_scanner.scan(ctx.io, ctx.allocator);
}
