# HostLift 代码质量与架构评估

## 总体结论

HostLift 当前已经具备一个可运行的早期产品核心：能扫描 Linux 主机、生成清单、比较源/目标、输出迁移计划，并在显式 `--approve` 后执行一部分远程 apply、transfer 和 rollback 操作。

但它还不是企业级迁移平台。现在更准确的定位是 **可验证的原型 / v0.1 工程核心**：安全边界方向正确，schema 和规划思路清晰，已经有单元测试、基础 smoke、第一版 fake remote smoke 和 GitHub Actions 基础质量门禁，但模块隔离、测试矩阵、传输可靠性、回滚完整性和远程执行模型还需要继续拆分和加固。

最新进展：本地 manifest 的 schema、构建、验证、JSON 输出和 SHA-256 工具已经从 `src/cli.zig` 拆到 `src/manifest/*.zig`；CLI 的 `scan`、`manifest`、`plan`、`validate`、`apply`、`remote exec` 命令处理已经拆到 `src/cli/*.zig`，其中 apply 参数解析、policy 评估输出、dry-run 输出和 action 审计事件写入分别拆到 `src/cli/apply_options.zig`、`apply_policy.zig`、`apply_dry_run.zig` 和 `apply_audit.zig`，apply/rollback 共享的 operator、审批凭证、审计 sink、host-authz 和远程执行元数据解析已进一步抽到 `src/cli/common_options.zig`；transfer argv 解析、默认值和传输后端解析已拆到 `src/transfer/options.zig`，source manifest 需求判断、manifest 选项约束、本地/远程源 manifest 构建、manifest 输出和远程目标 manifest 校验已拆到 `src/transfer/manifest_flow.zig`，scp/rsync 执行、传输子进程 runner、远程探针、远程 manifest、chunk staging adapter 和 chunk index 契约已拆到 `src/transport/*.zig`，其中 `src/transport/runner.zig` 已复用 remote cancel file 检查，`src/transport/remote_probe.zig` 承载远程 `find/stat/sha256sum`，`src/transport/manifest.zig` 只聚合远程 manifest 并保留 checksum API 兼容导出，`src/transport/chunk_index.zig` 定义 `hostlift.transport.chunk_index.v1` 并从 manifest 生成第一版文件到 chunk 映射；host、远程命令 token 和传输路径校验集中到 `src/security/validation.zig`，凭据来源元数据和 identity file 校验入口拆到 `src/credentials/source.zig`，action 策略门禁、RuleSet schema/校验、匹配 helper、策略测试和策略文件读取拆到 `src/policy/*.zig`，其中 `src/policy/ruleset.zig` 承载 policy schema、RuleSet 校验和子规则派生，`src/policy/action.zig` 保留动作级和执行入口策略评估；remote 层已把默认 timeout、命令计划构建、传输计划构建、传输后端组合规则、命令风险分类、执行选项、SSH argv、子进程 runner、远程状态探针、operation id/cancel file 校验、远程依赖预检和执行门面拆到 `src/remote/*.zig`，其中 `src/remote/transfer_rules.zig` 承载 rsync partial/resume、bwlimit、source-host + rsync/chunk 和非递归 chunk 的失败关闭规则，`apply`、`rollback`、`remote exec` 和 `transfer` 已能通过 `ExecutionOptions` 传递 operation/cancel 元数据，`src/remote/planner.zig` 和 `src/remote/exec.zig` 只保留兼容导出；rollback manifest 的 entry 契约校验、契约测试、JSONL 写入和兼容门面拆到 `src/rollback/schema.zig`、`schema_tests.zig`、`codec.zig` 和 `manifest.zig`，rollback 参数解析和模块分发拆到 `src/rollback/options.zig` 和 `dispatcher.zig`；approved apply/rollback 的本地 JSONL 审计日志已拆到 `src/audit/*.zig`，其中 event schema、apply/rollback 事件适配、hash chain、sink target、file sink、writer sink、sink 兼容门面、sink 测试、audit verify、audit replay 和 replay sink adapter 已经分离；防火墙 backend 推断、配置校验 argv、reload argv、恢复脚本和 systemd-run 恢复 argv 已拆到 `src/firewall/backend.zig`，延迟恢复任务上传、调度和取消已拆到 `src/firewall/recovery.zig`；apply action 构造拆成 `src/apply/actions.zig` 兼容门面和 `src/apply/action/*.zig` domain 模块，包管理器 apply 命令前缀已拆到 `src/apply/action/package_provider.zig`，action 级远程依赖预检已拆到 `src/apply/preflight.zig`，preflight 行为测试已拆到 `src/apply/preflight_tests.zig` 并纳入主测试入口，命令型 rollback entry 写入已拆到 `src/apply/rollback_entries.zig`；模块处理器契约已经移到 `src/modules/handler.zig`，scan registry、plan registry、apply support 和兼容门面已拆到 `src/modules/*.zig`，第一版 scan、plan、approved apply、部分 verify 和多类 rollback 通过 handler registry 分发；host、kernel、machine-id hash 和 os-release 读取已从 `src/inventory/scanner.zig` 拆到 `src/inventory/platform.zig`，包管理器检测/版本/仓库/显式包/hold 包命令映射已拆到 `src/inventory/package_manager.zig`，开发环境扫描已拆成 `dev_env.zig` 聚合入口和 `dev_env_tools.zig`、`dev_env_configs.zig`、`dev_env_proxy.zig` 三个子扫描器，scan include/exclude 解析与 scan handler/warning 聚合又拆到 `src/inventory/scan_filter.zig` 和 `src/inventory/scan_runner.zig`；inventory schema 已拆成兼容门面、`module_inventory.zig` 和 `schema_parts`；plan 过滤匹配契约已拆到 `src/plan/filter_match.zig`，输入哈希、规则聚合和各模块规则已经拆到 `src/plan/*.zig` 与 `src/plan/modules/*.zig`；inventory 摘要已拆成兼容入口、overview、details、counts 和 system/dev/runtime 详情模块；新增 `scripts/smoke-fake-remote.sh` 和 `scripts/check.sh`，CI 已调用统一质量门禁。这些改动让 manifest、transport、security、credentials、policy、remote、rollback、audit、firewall、apply 执行链、apply 远程依赖预检、apply 审计边界、remote session 基础边界、inventory 扫描器、dev env 子扫描器、package manager provider、plan filter 契约、plan 规则、transfer options、transfer manifest flow、transfer rules、chunk index 契约、输出层、handler 契约、CLI 命令层、基础远程 smoke 验证和 CI 质量门禁成为更清晰的模块。

高风险人工审查模块也已从单个大文件继续拆分：`manual_common.zig` 负责 `manual_step` 公共构造，`sudoers_review.zig`、`acl_review.zig`、`security_policy_review.zig`、`storage_review.zig` 和 `container_review.zig` 分别承载各自领域的 plan-only 审查规则，`manual_review.zig` 只保留薄门面和聚合测试。这让 sudoers、ACL、SELinux/AppArmor、storage 和容器事实保持可拆卸边界，同时继续失败关闭，不进入自动 apply。

## 做得好的部分

- 默认安全：`remote exec`、`transfer`、`apply` 默认只生成计划，必须显式 `--approve` 才会执行远程 SSH/scp 操作。
- 类型化建模：inventory、plan、remote plan 都有明确 schema，后续扩展比较容易。
- 先规划后执行：扫描、计划、校验、apply、rollback 的阶段拆得比较清楚。
- 失败关闭：不支持的 action 不会静默执行，防火墙 reload 也需要额外开关。
- 已有基础回滚：文件型覆盖前会备份目标路径并写 rollback manifest；包安装、用户/组创建、系统级/用户级 systemd enable 和 Compose up 会写命令型 rollback entry。
- 输入边界保守：host、远程命令 token、传输路径都有白名单式校验。
- 覆盖范围广：包、service、systemd timer、systemd socket、用户级 systemd unit、XDG autostart、SysV init、OpenRC、cron、用户、SSH、home 配置、项目、Docker/Podman 可用性、Docker 容器、volume/network 元数据、Compose 文件候选路径、防火墙、进程和网络监听都已有扫描能力。

## 主要问题

- `src/cli.zig` 已从约 584 行降到约 70 行。`scan`、`manifest`、`plan`、`validate`、`apply`、`remote exec` 已拆到 `src/cli/*.zig`，help 文本也已拆到 `src/cli/help.zig`，主文件目前只承担一级分发、版本输出和顶层错误报告包装。
- `src/inventory/scanner.zig` 已从约 1515 行降到约 80 行，现在只做 host/distro/package manager 顶层事实读取和 inventory 组装。host/kernel/machine-id hash 和 os-release 读取已经拆到 `src/inventory/platform.zig`，scan include/exclude 解析和 registry 支持校验拆到 `src/inventory/scan_filter.zig`，scan handler 执行和 warning 聚合拆到 `src/inventory/scan_runner.zig`，包管理器探测、版本命令、仓库来源、显式包和 hold 包命令映射已拆到 `src/inventory/package_manager.zig`。scan handler 失败会保留该模块空默认值并写入 warning，其他模块继续扫描。下一步重点应转向模块级 fixture 测试、更细的失败分级和多发行版包管理器验证。
- `src/inventory/schema.zig` 已从约 527 行降到约 196 行。它现在主要是兼容门面和顶层 `Inventory`，继续导出原有 public 类型名、`ModuleInventory`、`emptyModules` 和 `Inventory.deinit`；模块聚合类型、空模块 fixture 和模块内存释放已拆到 `src/inventory/module_inventory.zig`，纯领域类型已拆到 `src/inventory/schema_parts/host.zig`、`packages.zig`、`services.zig`、`users.zig`、`configs.zig`、`runtime.zig`、`sudoers.zig`、`acl.zig`、`storage.zig` 和 `security_policy.zig`。
- `src/inventory/services.zig` 已从约 514 行的混合扫描器降到约 30 行聚合入口。systemd service/timer/socket 扫描拆到 `src/inventory/services_systemd.zig`，用户级 systemd unit、XDG autostart、SysV init 和 OpenRC 又分别拆到 `src/inventory/services_user_units.zig`、`services_xdg.zig`、`services_sysv.zig` 和 `services_openrc.zig`，`services_startup.zig` 只保留薄聚合门面。plan 侧 `src/plan/modules/services.zig` 已从约 551 行降到约 22 行聚合入口，systemd service/timer/socket 规则、用户级 systemd 规则、XDG autostart 规则、SysV 规则和 OpenRC 规则分别拆到 `src/plan/modules/services_systemd.zig`、`services_user_systemd.zig`、`services_xdg.zig`、`services_sysv.zig` 和 `services_openrc.zig`。执行侧 `src/modules/handlers/services.zig` 也已从约 336 行降到约 132 行，用户级 systemd enable/verify/rollback provider 拆到 `src/modules/handlers/services_user_systemd.zig`，SysV provider 探测、`chkconfig`/`update-rc.d` 命令选择、runlevel verify 和 rollback 后置验证拆到 `src/modules/handlers/services_sysv.zig`，OpenRC `rc-update add/del`、runlevel verify 和 rollback 后置验证拆到 `src/modules/handlers/services_openrc.zig`，避免 services scanner、planner、handler、command handler 和 rollback dispatcher 复制同一类启动项逻辑。这样各类启动入口后续可以单独做 plan/apply/verify/rollback provider，不会继续堆回同一个主文件。
- `src/util/json.zig` 已降到约 86 行，只负责机器可读 JSON；`src/util/summary.zig` 约 20 行，只做输出门面；`src/util/inventory_summary.zig` 已从约 593 行降到约 115 行，只保留摘要兼容入口和公共入口测试；概览输出在 `src/util/inventory_summary_overview.zig`，计数逻辑在 `src/util/inventory_summary_counts.zig`，详情入口在 `src/util/inventory_summary_details.zig`，system/dev/runtime 详情分别在 `src/util/inventory_summary_system.zig`、`inventory_summary_dev.zig` 和 `inventory_summary_runtime.zig`；`src/util/plan_summary.zig` 约 145 行。摘要层职责已经比较清楚，后续重点是避免新的输出逻辑回流到兼容入口。
- `src/plan/builder.zig` 已从约 808 行降到约 45 行，只负责兼容性检查、调用规则聚合和组装 `MigrationPlan`；输入哈希已拆到 `src/plan/hash.zig`，builder 行为测试已拆到 `src/plan/builder_tests.zig`；`src/plan/rules.zig` 约 33 行，只做模块规则聚合；具体 action 构建规则已拆到 `src/plan/modules/*.zig`，模块/action 过滤匹配规则已拆到 `src/plan/filter_match.zig`，`src/plan/filter.zig` 只保留过滤器结构和 plan action 裁剪。
- `src/manifest/local.zig` 已从约 344 行降到约 129 行，只保留兼容导出、本地 manifest 构建和文件写入；manifest schema、SHA-256 工具、校验/摘要输出已拆到 `src/manifest/schema.zig`、`src/manifest/hash.zig` 和 `src/manifest/verify.zig`。
- `src/inventory/docker.zig` 已从约 365 行降到约 35 行，只做 Docker/Podman 扫描聚合。运行时检测在 `src/inventory/docker_runtime.zig`，运行中容器扫描和 parser 测试在 `docker_containers.zig`，volume/network 元数据扫描和 parser 测试在 `docker_resources.zig`，Compose 候选路径扫描在 `docker_compose.zig`，通用扫描结果在 `docker_common.zig`。后续如果继续做容器自动迁移，应新增 container provider/apply/verify/rollback，而不是把执行逻辑塞回 inventory。
- 当前最大生产文件依次是 `src/inventory/services_systemd.zig` 约 304 行、`src/transport/chunk_index.zig` 约 296 行、`src/inventory/module_inventory.zig` 约 283 行、`src/remote/transfer_plan.zig` 约 271 行、`src/plan/modules/services_systemd.zig` 约 244 行、`src/policy/approval_receipt.zig` 约 238 行、`src/rollback/dispatcher.zig` 约 232 行、`src/cli/apply_options.zig` 约 230 行、`src/util/inventory_summary_system.zig` 约 226 行、`src/apply/action/services.zig` 约 208 行、`src/apply/actions.zig` 约 206 行、`src/transport/chunk.zig` 约 200 行和 `src/inventory/schema.zig` 约 196 行。测试文件里 `src/plan/builder_tests.zig`、`src/apply/actions_tests.zig`、`src/policy/action_tests.zig`、`src/modules/registry_tests.zig`、`src/apply/preflight_tests.zig`、`src/rollback/schema_tests.zig` 和 `src/audit/verify_tests.zig` 行数更高，但它们是行为覆盖，不是首要拆分对象。services plan provider 已拆成 `services_systemd.zig`、`services_user_systemd.zig`、`services_xdg.zig`、`services_sysv.zig` 和 `services_openrc.zig`，主入口只有约 22 行；apply preflight 生产文件已从约 319 行降到约 103 行，行为测试迁到 `preflight_tests.zig` 并被主测试入口显式导入。下一步服务领域更值得做的是 start/stop/restart 的受控语义，而不是继续机械拆 plan 文件。`src/remote/transfer_plan.zig` 已把 transport validation、resume/bwlimit 和 chunk 限制规则拆到 `src/remote/transfer_rules.zig`；后续如果继续缩短该文件，应优先拆计划构建测试或 manifest verification 规则。`src/policy/action.zig` 已把 RuleSet schema、整体校验和 plan hash/approval 子规则派生拆到约 88 行的 `src/policy/ruleset.zig`，当前保留 plan/action/execution 策略评估；下一步如继续增长，可把 plan report 构造和 execution report 构造继续拆成评估子域。`src/cli/apply_options.zig` 已把 apply/rollback 共享解析抽到约 148 行的 `src/cli/common_options.zig`，当前主要保留 apply 专属过滤、凭据和执行选项装配；`src/rollback/options.zig` 约 147 行，也已复用同一套公共解析，减少两条执行入口的参数语义分叉。`src/cli/apply.zig` 已把 action 审计上下文、policy 和 dry-run 输出拆到 `src/cli/apply_audit.zig`、`src/cli/apply_policy.zig` 和 `src/cli/apply_dry_run.zig`，自身退出最大文件列表；`src/inventory/dev_env.zig` 已把工具扫描、配置路径扫描和代理变量扫描拆到 `src/inventory/dev_env_tools.zig`、`dev_env_configs.zig` 和 `dev_env_proxy.zig`；`src/inventory/schema.zig` 已把模块聚合类型、空模块 fixture 和模块 deinit 拆到 `src/inventory/module_inventory.zig`；`src/rollback/schema.zig` 已把行为测试拆到 `src/rollback/schema_tests.zig`；`src/transfer/command.zig` 已把 argv 解析和 source/target manifest 编排拆到 `src/transfer/options.zig` 和 `src/transfer/manifest_flow.zig`；`src/util/inventory_summary.zig` 已把概览、计数和详情输出拆到多个摘要模块；`src/audit/log.zig` 已把 apply/rollback 事件适配拆到 `src/audit/action_event.zig` 和 `src/audit/rollback_event.zig`；`src/audit/replay.zig` 已把 file/syslog/HTTPS replay adapter 拆到 `src/audit/replay_sink.zig`；`src/audit/mirror_sink.zig` 已把 syslog/HTTPS 主 sink 与本地 file sink 的双写逻辑隔离出来；`src/rollback/command.zig` 已把 action id 到模块 handler 的分发拆到 `src/rollback/dispatcher.zig`。后续更值得拆的是 inventory systemd scanner parser、transfer plan 测试、rollback 后置验证子域、policy 执行评估子域、apply 执行编排、inventory probe 扫描边界、远程 session/cancel 模型和未来 chunk transport。相关测试模块都已由 `zig build test` 覆盖。
- scan/apply/rollback 执行编排已经初步从 CLI 层分离：扫描聚合通过 `src/modules/scan_registry.zig`，规划和生命周期 handler 注册在 `src/modules/plan_registry.zig`，approved apply 支持判断在 `src/modules/apply_support.zig`，兼容导出在 `src/modules/registry.zig`；命令映射门面在 `src/apply/actions.zig`，包/service/用户/Docker Compose/subject 逻辑在 `src/apply/action/*.zig`，apply 执行入口在 `src/apply/executor.zig`，远程备份在 `src/apply/backup.zig`，权限修复在 `src/apply/permissions.zig`，本地审计写入在 `src/audit/log.zig`，第一版 handler 契约在 `src/modules/handler.zig`，具体 handler 在 `src/modules/handlers/*.zig`。下一步应接入更深的内容级 verify、其余非文件副作用 rollback 和集中审计/操作人身份。
- rollback 还不完整。当前文件型覆盖、包安装、用户/组创建、系统级/用户级 systemd enable 和 Docker Compose up 已经通过模块 handler 恢复；包安装 rollback 的卸载和后置验证已复用远端包管理器探测，apt 使用 `dpkg-query -W`，dnf/yum/zypper 使用 `rpm -q`，pacman 使用 `pacman -Q`。sudoers、ACL、SELinux/AppArmor 和 storage 已有只读事实扫描，并会在 plan 阶段生成 `manual_step` 人工审查项，但这些深度身份/权限/存储策略还没有自动 apply/rollback。
- 传输层已有 `scp`、`rsync --partial`、rsync `--append-verify` 续传边界和统一的传输带宽限制。`--resume` 会自动启用 partial，并在计划构建阶段拒绝 scp；`--bwlimit` / `--transfer-bwlimit` 会进入 `TransferPlan.bandwidth_limit_kbps` 并由 scp/rsync adapter 转成各自 argv。chunk 已作为第三个 transport 进入计划契约，`TransferPlan.chunk_size_bytes` 默认 8 MiB，`transport/chunk_index.zig` 已有第一版 manifest 到 chunk index 映射和 missing/changed/extra diff 逻辑，`transport/chunk.zig` 已把 diff 接入 approved 执行路径，按整文件 chunk 上传目标缺失或内容变更的文件到 staging 后用远端 `rsync -a` 合并；但字节块级强断点续传、目标多余文件安全清理和远程源到远程目标的 rsync/P2P/agent 传输仍未完成。
- 防火墙安全已有第一层恢复窗口和 backend helper。当前有 SSH 端口文本预检、backend 配置校验、reload 后检查和 systemd-run 延迟恢复任务，但还不是完整防锁死证明。
- 测试以单元测试、基础 smoke、第一版 fake remote smoke 和 GitHub Actions 基础门禁为主。企业级还需要 handler 级 fake command fixture、Linux 容器/虚拟机集成测试、不同发行版矩阵、故障注入和端到端迁移演练。

## 推荐目标架构

建议按职责拆成更清晰的模块边界：

```text
src/
  cli/
    scan.zig
    manifest.zig
    plan.zig
    validate.zig
    apply.zig
    rollback.zig
    remote.zig
    transfer.zig

  inventory/
    schema.zig
    platform.zig
    scan_filter.zig
    scan_runner.zig
    scanner.zig
    host.zig
    dev_env.zig
    packages.zig
    services.zig
    cron.zig
    users.zig
    ssh.zig
    configs.zig
    home_configs.zig
    appdata.zig
    projects.zig
    processes.zig
    network.zig
    docker.zig
    firewall.zig

  plan/
    schema.zig
    builder.zig
    filter.zig
    rules.zig
    validator.zig
    compatibility.zig
    modules/
      packages.zig
      services.zig
      cron.zig
      users.zig
      ssh.zig
      configs.zig
      home_configs.zig
      appdata.zig
      projects.zig
      firewall.zig
      services_systemd.zig
      services_user_systemd.zig
      services_xdg.zig
      services_sysv.zig
      services_openrc.zig

  apply/
    executor.zig
    backup.zig
    rollback.zig
    verifier.zig
    handlers/

  transport/
    ssh.zig
    scp.zig
    rsync.zig
    manifest.zig

  security/
    validation.zig
    firewall.zig
    approvals.zig

  output/
    json.zig
    inventory_summary.zig
    plan_summary.zig
    summary.zig
```

## 模块插件边界

为了做到可拆卸，每个迁移模块建议提供统一接口：

```zig
pub const ModuleHandler = struct {
    name: ModuleName,
    scan: *const fn (ctx: ScanContext) anyerror!ModuleInventory,
    plan: *const fn (ctx: PlanContext) anyerror![]Action,
    apply: *const fn (ctx: ApplyContext, action: Action) anyerror!ApplyResult,
    verify: *const fn (ctx: VerifyContext, action: Action) anyerror!VerifyResult,
    rollback: *const fn (ctx: RollbackContext, entry: RollbackEntry) anyerror!RollbackResult,
};
```

这样包、用户、防火墙、项目、Docker、home 配置都可以独立开发、测试和禁用。CLI 只负责参数和编排，不再知道每个模块的细节。

## 企业级差距清单

| 能力 | 当前状态 | 企业级要求 |
| --- | --- | --- |
| 扫描和人工审查计划 | 较广，sudoers 已有只读元数据扫描，记录 `/etc/sudoers` 和 `/etc/sudoers.d` 路径、类型、大小、权限 mode 和有效行数，不输出授权规则内容；ACL 已有只读扫描，记录常见迁移路径是否存在扩展 POSIX ACL，不输出 ACL 条目正文；security_policy 已有 SELinux/AppArmor 只读扫描，记录状态、配置路径存在性和 profile/policy 计数，不输出策略正文；storage 已有只读扫描，记录 `/etc/fstab` 和当前 mountinfo 的 device/source、mount point、文件系统类型和挂载选项；这些模块已有 `manual_step` plan 审查项 | 需要发行版矩阵、可配置探针、更多权限策略事实、存储设备映射，以及从 manual_step 升级到可验证 apply/rollback 的设计 |
| 迁移计划 | 可用 | 需要更强 diff、冲突解释和影响评估 |
| 选择性迁移 | 已有基础 filter | 需要交互式选择、依赖关系和批次执行 |
| 远程执行 | 保守 argv 模式，已有基础 timeout/retry，支持 `--identity-file`、`--credential-provider ssh-agent` 和 `env:<name>`；SSH argv、runner、状态探针、credential source、operation id、本地 cancel file、本地 operation state JSONL、session control 和远程依赖 preflight 边界已拆分；remote exec approved 执行前会检查 argv[0]，transfer approved 执行前会检查 checksum 所需的 `sha256sum`，approved apply 通过 handler `applyRequirements` 按 action 类型和 apply options 检查包管理器、`systemctl`、`useradd`、`groupadd`、`docker`、备份/权限修复和防火墙 reload/recovery 入口命令 | 仍需要真正 session manager、远端进程取消、连接复用、批次控制和更细的 provider 级依赖声明 |
| 文件传输 | scp/rsync 可用，已有基础 timeout/retry、rsync partial、rsync `--append-verify` 续传边界、传输带宽限制和统一 SSH identity file 传递；chunk 已有 dry-run 计划字段、默认 8 MiB `chunk_size_bytes`、`hostlift.transport.chunk_index.v1` 索引契约、missing/changed/extra diff 逻辑和文件粒度 missing/changed approved 上传；计划层会拒绝 scp resume、当前不支持的 source-host + rsync、source-host + chunk 和非递归 chunk | 需要字节块级强断点续传、目标多余文件安全清理、远程到远程 rsync/P2P/agent 传输和强一致校验 |
| 凭据 | 可显式指定本地 SSH identity file，也可使用 `--credential-provider ssh-agent`；`env:<name>` provider 已可读取环境变量中的 identity file 路径并传给 SSH/scp/rsync，审计只记录 `env`；`vault:` provider 仍解析后失败关闭；`credentials/source.zig` 统一记录来源元数据并避免把私钥路径或 provider ref 写入审计 | 需要真实集中凭据托管、短期凭据、密钥轮换、凭据租约审计和审批绑定 |
| 审批和主机授权 | approved apply/rollback 可记录 `approval_ticket` 和 operator；policy 可要求 apply/rollback 必须提供 ticket，并可用 ticket 精确值/前缀 allow/deny 规则限制审批票据；policy 可用 `allow_plan_hashes`/`deny_plan_hashes` 绑定已审查 plan，也可用 `allow_hosts`/`deny_hosts` 限制 approved apply/rollback 目标 host、用 `allow_operators`/`deny_operators` 限制本地 operator 字符串；`approval_scopes` 可把 ticket 或前缀绑定到 host/operator/module/action/risk，apply 逐 action 检查，rollback 支持 host/operator/ticket 级 scope；`--approval-receipt` 已支持本地审批凭证 JSON，绑定 ticket/operator/host/purpose/过期时间，apply 还绑定 plan hash；receipt 可选 HMAC-SHA256 signature，并通过 `--approval-receipt-key-env` 从本地环境变量读取密钥校验；`--host-authz` 已支持本地主机授权 JSON，把 operator 绑定到精确 host、host prefix 或显式 allow_all_hosts，并在 audit/remote 前失败关闭；policy source 已统一策略读取和 `policy_hash` 绑定 | 需要可信审批系统在线校验、集中资产授权、真实身份认证/RBAC、非对称签名或 KMS 验签和 policy 签名 |
| 容器 | 已有 scan-only 增量事实：Docker/Podman 可用性、运行中 Docker 容器、Docker volume/network 元数据和 Compose 文件候选路径；这些事实会生成 `manual_step` 人工审查项；Compose up 有初步 apply/rollback 边界 | 需要 Docker/Podman provider、镜像/volume/network 差异解释、停机一致性、volume 备份恢复、容器网络验证和更完整 rollback |
| 回滚 | 文件型、包安装、用户/组创建、系统级/用户级 systemd enable 和 Compose up 初步支持；rollback handler 返回 restored 后会做后置验证，覆盖文件原路径存在、包缺失、用户/组缺失、系统级 systemd disabled 和用户级 `systemctl --user is-enabled` 失败；包缺失验证已按远端包管理器选择 `dpkg-query`、`rpm` 或 `pacman` | 需要每个 action 的 rollback contract，以及 Docker volume/network、sudoers、ACL、SELinux/AppArmor、防火墙等更深副作用恢复 |
| 启动项和定时任务 | systemd service 已能扫描 unit-file 状态和 active/reloading/activating/inactive/failed 等运行态；源端运行中而目标端未运行的 service 会生成 high-risk `manual_step`，不自动 start/restart；cron 已有来源扫描；systemd timer/socket 已记录 enabled 状态，自定义 timer/socket 缺失时可安装 unit，enabled timer/socket 可启用并复用 verify/rollback；目标缺失的 XDG autostart、用户级 systemd unit、SysV init 脚本和 OpenRC service 脚本已可复用文件型 action、verify 和 rollback；enabled 用户级 unit 已可通过 `runuser` 执行 `systemctl --user enable/is-enabled/disable` 并写 rollback，执行侧 provider 已拆到 `services_user_systemd.zig`；SysV init 已可通过 `chkconfig` 或 `update-rc.d` provider 收敛 runlevel 差异并做 verify/rollback，执行侧 provider 已拆到 `services_sysv.zig`；OpenRC service 已可通过 `rc-update add/del` 和 `/etc/runlevels` 链接存在性检查收敛 runlevel 差异并做 verify/rollback，执行侧 provider 已拆到 `services_openrc.zig`；复杂 timer/socket/autostart 差异仍生成 `manual_step` 人工审查项 | 需要受控 systemd/SysV/OpenRC start/stop/restart 语义、复杂 timer/socket/autostart 差异处理、用户级 unit start/session/linger provider、更多发行版 fixture 和复杂启动脚本语义处理 |
| 防火墙 | SSH 端口预检、backend helper、reload 后检查、systemd-run 恢复窗口；backend argv 生命周期已用内联结构固定，fake remote 覆盖 nftables reload/recovery 主路径 | 需要连接保活、云安全组提示、非 systemd fallback 和更多 backend 级 fixture |
| 用户/权限 | 能扫描和创建基础用户；create_user 执行后会用 `getent passwd` 校验用户名、UID、GID、home 和 shell，避免只检查账号存在；sudoers、ACL、security_policy 和 storage 已有 scan-only 事实模块和 plan-only `manual_step` 审查项，不输出规则、ACL 条目或策略正文 | 需要 sudoers 自动 apply/rollback、ACL 自动 apply/rollback、SELinux/AppArmor 自动 apply/rollback 和策略差异评估 |
| 测试 | 单元、基础 smoke、`scripts/smoke-fake-remote.sh` 和 GitHub Actions 基础门禁 | 需要 handler 级 fake fixture、容器集成测试、真实 SSH 测试、故障注入 |
| 审计 | approved apply/rollback 有本地 JSONL 日志，已记录 operator、approval_ticket、credential_source、policy_hash 和 hash chain；approved apply 已记录 plan_hash；已有 `audit verify` 本地校验入口并输出 tail_hash，且兼容缺少 credential_source/policy_hash 的历史日志；`audit replay` 会先校验 hash chain，再把原始 JSONL 行重放到 file/syslog/HTTPS sink，并拒绝 file sink 覆盖输入日志；syslog/HTTPS sink 支持 `--audit-mirror-log` 同步写本地 JSONL 镜像，便于本地校验和后续 replay；event schema、hash chain 和事件 JSONL/hash 已拆到 `audit/event.zig`、`audit/chain.zig` 和 `audit/codec.zig`，sink target 解析已拆到 `audit/sink_target.zig`，sink 执行计划和 fail-closed 判断已拆到 `audit/sink_plan.zig`，verify 单事件校验已拆到 `audit/verify_event.zig`；本地文件写入、任意 writer 写入、本机 syslog 写入、HTTPS POST 写入、mirror sink 和 replay sink adapter 已拆到 `audit/file_sink.zig`、`audit/writer_sink.zig`、`audit/syslog_sink.zig`、`audit/http_sink.zig`、`audit/mirror_sink.zig` 和 `audit/replay_sink.zig`，`audit/combined_sink.zig` 统一 file/syslog/HTTP/mirror open/write/flush/tailHash | 仍需要 SIEM 级集中存储、可靠离线队列、外部签名/时间戳锚定、mTLS/RBAC 和凭据隔离 |

## Linux 换机遗漏评估

你列出的遗漏大多成立，但不应该全部自动同步。推荐按三类处理：

| 类别 | 结论 | 处理方式 |
| --- | --- | --- |
| locale/timezone、NTP、sysctl、logrotate、tmpfiles.d、limits、PAM、SSSD/LDAP、NSS、DNS 解析链 | 当前覆盖不足或只有弱配置存在性扫描 | 先新增 system baseline scan-only 模块，输出结构化事实和 `manual_step`；sysctl 只能在 allowlist 下自动 apply |
| LVM/ZFS/Btrfs、NFS/CIFS/autofs、内核模块、crypttab、RAID | 当前 storage 只覆盖 fstab 和 mountinfo，不足以迁移真实存储语义 | 只读扫描和人工审查；自动迁移必须等设备映射、目标能力校验、dry-run 和 rollback 设计完成 |
| `/etc/hosts`、`/etc/resolv.conf`、`/etc/nsswitch.conf` | `/etc/hosts` 当前作为普通 configs 路径覆盖，未结构化解析；DNS/NSS 未系统覆盖 | `/etc/hosts` 后续应做 merge-aware provider；DNS/NSS 先 scan-only/manual_step，不默认覆盖 |
| Docker 镜像、volume、network、运行中容器 | 当前只扫描 runtime、运行容器、volume/network 元数据和 Compose 候选路径 | 镜像列表可以 scan-only；volume/network 自动迁移需要单独 provider、停机一致性和 rollback |
| UID/GID 冲突 | 当前 create_user 会执行后校验，但 plan 阶段冲突解释不足 | 应在 users plan 阶段检测 UID/GID/name 冲突并生成 high-risk manual_step 或阻断 |
| 远程到远程传输和 chunk | `scp -3` 中转和整文件 chunk 都是已知限制 | 需要 P2P/agent/rsync source-host provider，以及真正字节块级 chunk |
| 扫描器失败语义 | scan_runner 能保留 warning，但用户/认证类扫描失败的业务含义还不够强 | 用户、PAM、SSSD/LDAP 等关键模块失败应升级为显式 warning/manual_step，避免误判“无需迁移” |
| 并发安全 | operation state JSONL 当前无锁 | 需要 lock file 或单 operation state writer，避免多实例同时写坏 JSONL |
| Zig 0.16 API 稳定性 | 真实风险 | 需要固定 Zig 版本、CI 构建矩阵和升级专项，不应把 std API 假定为稳定 |

工具链 home 配置这次已经补齐第一批轻量路径：`~/.m2/settings.xml`、`~/.cargo/config.toml`、`~/.cargo/config`、`~/.gradle/gradle.properties` 和 `~/.config/go/env` 会进入 home/dev config 扫描。`~/.m2/repository`、`~/.cargo/registry`、`~/.gradle/caches`、Go module cache、pip cache 和 npm cache 仍不应默认迁移，应该由对应工具重建。

curl 脚本安装的应用不应按“复制二进制目录”默认自动迁移。更合适的设计是新增 `script_installed_apps` scan-only/provider：识别 `~/.local/bin`、`~/.cargo/bin`、`~/.nvm`、`~/.modular`、Homebrew Linuxbrew、shell profile PATH 片段和安装痕迹，生成 reinstall/manual_step 建议；只有在有可审计安装来源、版本、校验和和可回滚策略时，才允许自动重装或同步配置。

## 分阶段重构建议

1. **机械拆分，不改行为**：manifest schema/hash/verify、transfer options、transfer manifest flow、transport、transfer rules、chunk index 契约、security、远程执行、remote session 基础边界、rollback schema/codec/options/dispatcher/command/schema tests、防火墙 backend/reload/recovery、audit event/action/rollback/chain/codec/sink、本地文件工具、通用路径工具、policy ruleset/action/match、apply action domain 模块、apply audit、apply executor/备份/权限修复、apply options/common options/policy/dry-run、inventory 扫描器、scan filter、scan runner、dev env 子扫描器、package manager provider、inventory schema 类型、module inventory、plan builder/hash/filter match/模块规则、机器 JSON 输出、摘要输出、registry lifecycle，以及 `scan`/`manifest`/`plan`/`validate`/`apply`/`remote` CLI 入口都已经拆到独立文件。下一步继续拆真正远程 session manager、apply 执行编排、inventory probe 扫描边界和 chunk 可执行 transport。
2. **模块处理器接口**：`src/modules/handler.zig` 已有第一版类型契约，`src/modules/scan_registry.zig`、`plan_registry.zig` 和 `apply_support.zig` 已接入 scan 聚合、scan 模块 include/exclude、规划阶段、approved apply 阶段、handler 级 apply 依赖声明、包管理器存在性 verify、service/user/project/file verify、文件型 rollback、包安装 rollback、用户/组创建 rollback、系统级/用户级 systemd enable rollback 和 Compose up rollback；scan 失败降级已落地。下一步让每个 handler 自己负责内容级深度 verify、其余非文件副作用 rollback、更细的失败分级、provider 级依赖声明和策略化模块禁用。
3. **强化测试**：在 `scripts/smoke-fake-remote.sh` 基础上，为每个 handler 建 fake command fixture，再补 Linux container 集成测试，覆盖 Ubuntu/Debian/Fedora/Arch 等关键路径。
4. **传输层升级**：保留 scp 和 rsync 作为基础实现，当前 rsync resume 已落到 `TransferPlan.resumable` 和 `--append-verify`，带宽限制已落到 `TransferPlan.bandwidth_limit_kbps`，chunk 计划、索引契约、index diff 和文件粒度增量执行 adapter 已落到 `TransferPlan.chunk_size_bytes`、`transport/chunk_index.zig`、`transport/chunk.zig`、`transport/chunk_paths.zig` 和 `transport/chunk_upload.zig`；下一步继续补字节块级切分/上传、目标多余文件安全清理、远程到远程代理传输和真正的大目录强续传。
5. **企业安全层**：把 approvals、命令白名单、路径校验、凭据来源、防火墙预检、审计日志集中到 `security/`、`credentials/` 和 `transport/` 边界。

## 当前优先级

最高优先级不是继续堆功能，而是先拆边界：

- `plan/builder.zig` 已收敛为纯组装入口，handler 类型契约已在 `src/modules/handler.zig` 定义，scan/plan/approved apply registry 已拆到 `src/modules/scan_registry.zig`、`plan_registry.zig` 和 `apply_support.zig`；scan 阶段已支持按模块 include/exclude，approved apply 已通过 handler `applyRequirements` 支持基础依赖声明。下一步应让 registry 支持策略化模块禁用、更细的失败分级、provider 级依赖和更深的 verify/rollback 分发。
- `cli.zig` 已完成第一轮命令拆分，help 文本已移到 `src/cli/help.zig`；`transport/security` 已完成第一层落地，当前更重要的是模块 handler contract、provider 级依赖声明和传输可靠性扩展。
- `inventory/schema.zig` 已经完成第一轮分组拆分和 module inventory 拆分，后续不要再让新的 domain 类型回流到门面文件；新增类型应优先进入 `src/inventory/schema_parts/*.zig`、`src/inventory/module_inventory.zig` 或更明确的模块 schema 文件。
- `apply/actions.zig` 当前约 206 行，仍主要承担兼容门面和 action 分发；packages、services、users、projects、subjects 等 domain 模块和 `actions_tests.zig` 已分离。下一步应继续把新增执行语义放进模块 handler/provider，而不是让 `actions.zig` 重新膨胀。
- 继续拆真正远程 session manager、apply 执行编排、apply backup 远程备份边界、inventory probe 扫描边界和未来 chunk transport；remote exec 已有 operation id、本地 cancel file 和本地 operation state JSONL 第一层边界；transfer options 与 manifest flow 已拆出；rollback schema 测试已拆出；dev env 子扫描器已拆出；package manager provider 第一层已落地，rollback 执行和后置验证已复用远端包管理器探测，下一步补多发行版 fixture 和包管理器失败注入；plan filter 过滤契约已拆到 `filter_match.zig`；inventory summary 已拆成 overview/details/counts/system/dev/runtime 和兼容入口，后续避免把新输出逻辑写回门面文件。
- 建立模块 handler contract，让“防火墙、用户、项目、Docker、home 配置”各自独立。
- 最后补集成测试和传输可靠性，进入企业级可用阶段。
