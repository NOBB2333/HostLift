# HostLift - 技术架构

## 1. 架构目标

HostLift 围绕一个规则设计：**先规划，后变更**。

初始产品仅支持在运行相同 Linux 发行版和版本的服务器之间进行迁移。这使得该工具可以避免不可靠的跨发行版包映射，同时解决云服务器到期需要迁移到新替换服务器的常见场景。

技术目标：

- 生成源主机和目标主机的完整清单。
- 在更改目标之前生成明确的迁移计划。
- 按风险、兼容性和回滚支持对每个操作进行分类。
- 通过类型化操作而不是原始文件复制来应用更改。
- 保留足够的元数据以进行验证和回滚。
- 使用单个 Zig 二进制文件保持部署简单。

## 2. 高层架构

```
┌─────────────────────────────────────────────────────────────────┐
│                            HostLift                              │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │  TUI     │  │  CLI     │  │  扫描器   │  │  规划器   │       │
│  │  界面层   │  │  命令层   │  │ (Scanner)│  │ (Planner)│       │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘       │
│       │             │             │             │               │
│  ┌────┴─────────────┴─────────────┴─────────────┴─────┐        │
│  │                    核心引擎 (Engine)                 │        │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌────────┐│        │
│  │  │ 编排器   │  │ 阶段运行 │  │ 策略评估 │  │ 报告器 ││        │
│  │  │Orchestr.│  │  Phase  │  │ Policy  │  │ Report ││        │
│  │  └─────────┘  └─────────┘  └─────────┘  └────────┘│        │
│  └────────────────────────┬───────────────────────────┘        │
│                           │                                     │
│  ┌────────────────────────┴───────────────────────────┐        │
│  │                 清单层 (Inventory)                    │        │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌────────┐│        │
│  │  │ 发行版   │  │  包     │  │  服务   │  │  用户  ││        │
│  │  │ Distro  │  │Packages │  │Services │  │ Users  ││        │
│  │  └─────────┘  └─────────┘  └─────────┘  └────────┘│        │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐            │        │
│  │  │  SSH    │  │  配置   │  │  数据   │            │        │
│  │  │  SSH    │  │ Configs │  │  Data   │            │        │
│  │  └─────────┘  └─────────┘  └─────────┘            │        │
│  └────────────────────────────────────────────────────┘        │
│                           │                                     │
│  ┌────────────────────────┴───────────────────────────┐        │
│  │                 规划层 (Planning)                     │        │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌────────┐│        │
│  │  │ 兼容性   │  │  差异   │  │ 风险分类 │  │操作构建││        │
│  │  │ Compat  │  │  Diff   │  │  Risk   │  │Builder ││        │
│  │  └─────────┘  └─────────┘  └─────────┘  └────────┘│        │
│  └────────────────────────────────────────────────────┘        │
│                           │                                     │
│  ┌────────────────────────┴───────────────────────────┐        │
│  │                 应用层 (Apply)                        │        │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌────────┐│        │
│  │  │ 操作执行 │  │ 备份管理 │  │  验证器  │  │  回滚  ││        │
│  │  │Executor │  │ Backup  │  │ Verifier│  │Rollback││        │
│  │  └─────────┘  └─────────┘  └─────────┘  └────────┘│        │
│  └────────────────────────────────────────────────────┘        │
│                           │                                     │
│  ┌────────────────────────┴───────────────────────────┐        │
│  │                 传输层 (Transport)                    │        │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐            │        │
│  │  │ 在线P2P │  │ 离线包   │  │ 分块存储 │            │        │
│  │  │  P2P    │  │ Bundle  │  │  Chunk  │            │        │
│  │  └─────────┘  └─────────┘  └─────────┘            │        │
│  └────────────────────────────────────────────────────┘        │
│                           │                                     │
│  ┌────────────────────────┴───────────────────────────┐        │
│  │                 平台层 (Platform)                     │        │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐            │        │
│  │  │ 文件系统 │  │ 进程管理 │  │ 包管理器 │            │        │
│  │  │  FS     │  │ Process │  │ Pkg Mgr │            │        │
│  │  └─────────┘  └─────────┘  └─────────┘            │        │
│  └────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────┘
```

扫描器不决定更改什么。它只产生事实。规划器将事实转换为提议的操作。执行器仅应用已批准的操作。

## 3. 当前仓库布局

```text
hostlift/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig
│   ├── cli.zig
│   ├── cli/
│   │   ├── apply.zig
│   │   ├── apply_audit.zig
│   │   ├── apply_dry_run.zig
│   │   ├── apply_options.zig
│   │   ├── apply_policy.zig
│   │   ├── common_options.zig
│   │   ├── manifest.zig
│   │   ├── plan.zig
│   │   ├── remote.zig
│   │   ├── scan.zig
│   │   └── validate.zig
│   ├── apply/
│   │   ├── action/
│   │   │   ├── common.zig
│   │   │   ├── packages.zig
│   │   │   ├── package_provider.zig
│   │   │   ├── projects.zig
│   │   │   ├── services.zig
│   │   │   ├── subjects.zig
│   │   │   └── users.zig
│   │   ├── actions.zig
│   │   ├── backup.zig
│   │   ├── executor.zig
│   │   ├── permissions.zig
│   │   ├── preflight.zig
│   │   ├── preflight_tests.zig
│   │   └── rollback_entries.zig
│   ├── audit/
│   │   ├── action_event.zig
│   │   ├── combined_sink.zig
│   │   ├── codec.zig
│   │   ├── event.zig
│   │   ├── file_sink.zig
│   │   ├── http_sink.zig
│   │   ├── rollback_event.zig
│   │   ├── replay.zig
│   │   ├── replay_sink.zig
│   │   ├── sink.zig
│   │   ├── sink_plan.zig
│   │   ├── sink_target.zig
│   │   ├── syslog_sink.zig
│   │   ├── verify.zig
│   │   ├── verify_event.zig
│   │   ├── writer_sink.zig
│   │   └── log.zig
│   ├── modules/
│   │   ├── apply_support.zig
│   │   ├── handler.zig
│   │   ├── handlers/
│   │   │   ├── appdata.zig
│   │   │   ├── command.zig
│   │   │   ├── postgresql.zig
│   │   │   ├── projects.zig
│   │   │   ├── reinstall.zig
│   │   │   ├── resources.zig
│   │   │   ├── rollback.zig
│   │   │   ├── services.zig
│   │   │   └── transfer.zig
│   │   ├── plan_registry.zig
│   │   ├── registry.zig
│   │   ├── registry_tests.zig
│   │   └── scan_registry.zig
│   ├── postgresql/
│   │   └── artifacts.zig
│   ├── reinstall/
│   │   ├── artifacts.zig
│   │   └── schema.zig
│   ├── firewall/
│   │   ├── backend.zig
│   │   ├── recovery.zig
│   │   └── reload.zig
│   ├── inventory/
│   │   ├── module_inventory.zig
│   │   ├── schema.zig
│   │   ├── schema_parts/
│   │   │   ├── configs.zig
│   │   │   ├── host.zig
│   │   │   ├── packages.zig
│   │   │   ├── runtime.zig
│   │   │   ├── acl.zig
│   │   │   ├── security_policy.zig
│   │   │   ├── services.zig
│   │   │   ├── storage.zig
│   │   │   ├── sudoers.zig
│   │   │   └── users.zig
│   │   ├── package_manager.zig
│   │   ├── platform.zig
│   │   ├── scan_filter.zig
│   │   ├── scan_runner.zig
│   │   ├── scanner.zig
│   │   ├── probe.zig
│   │   ├── appdata.zig
│   │   ├── configs.zig
│   │   ├── cron.zig
│   │   ├── dev_env.zig
│   │   ├── dev_env_configs.zig
│   │   ├── dev_env_proxy.zig
│   │   ├── dev_env_tools.zig
│   │   ├── docker.zig
│   │   ├── docker_common.zig
│   │   ├── docker_compose.zig
│   │   ├── docker_containers.zig
│   │   ├── docker_resources.zig
│   │   ├── docker_runtime.zig
│   │   ├── firewall.zig
│   │   ├── home_configs.zig
│   │   ├── acl.zig
│   │   ├── network.zig
│   │   ├── packages.zig
│   │   ├── processes.zig
│   │   ├── projects.zig
│   │   ├── security_policy.zig
│   │   ├── services_openrc.zig
│   │   ├── services.zig
│   │   ├── services_startup.zig
│   │   ├── services_sysv.zig
│   │   ├── services_systemd.zig
│   │   ├── services_user_units.zig
│   │   ├── services_xdg.zig
│   │   ├── storage.zig
│   │   ├── sudoers.zig
│   │   ├── ssh.zig
│   │   └── users.zig
│   ├── manifest/
│   │   ├── hash.zig
│   │   ├── schema.zig
│   │   ├── local.zig
│   │   └── verify.zig
│   ├── plan/
│   │   ├── schema.zig
│   │   ├── compatibility.zig
│   │   ├── action_compatibility.zig
│   │   ├── builder.zig
│   │   ├── builder_tests.zig
│   │   ├── filter.zig
│   │   ├── filter_match.zig
│   │   ├── hash.zig
│   │   ├── postgresql_provider.zig
│   │   ├── workload_schema.zig
│   │   ├── workloads.zig
│   │   ├── workloads_tests.zig
│   │   ├── modules/
│   │   │   ├── appdata.zig
│   │   │   ├── acl_review.zig
│   │   │   ├── common.zig
│   │   │   ├── container_review.zig
│   │   │   ├── configs.zig
│   │   │   ├── cron.zig
│   │   │   ├── firewall.zig
│   │   │   ├── home_configs.zig
│   │   │   ├── manual_common.zig
│   │   │   ├── manual_review.zig
│   │   │   ├── packages.zig
│   │   │   ├── projects.zig
│   │   │   ├── security_policy_review.zig
│   │   │   ├── services.zig
│   │   │   ├── services_openrc.zig
│   │   │   ├── services_sysv.zig
│   │   │   ├── services_systemd.zig
│   │   │   ├── services_user_systemd.zig
│   │   │   ├── services_xdg.zig
│   │   │   ├── storage_review.zig
│   │   │   ├── sudoers_review.zig
│   │   │   ├── ssh.zig
│   │   │   └── users.zig
│   │   ├── rules.zig
│   │   └── validator.zig
│   ├── remote/
│   │   ├── command_plan.zig
│   │   ├── defaults.zig
│   │   ├── exec.zig
│   │   ├── planner.zig
│   │   ├── postgresql.zig
│   │   ├── options.zig
│   │   ├── operation_state.zig
│   │   ├── package_manager.zig
│   │   ├── probe.zig
│   │   ├── risk.zig
│   │   ├── runner.zig
│   │   ├── session.zig
│   │   ├── transfer_plan.zig
│   │   ├── transfer_rules.zig
│   │   ├── ssh_argv.zig
│   │   └── schema.zig
│   ├── rollback/
│   │   ├── codec.zig
│   │   ├── command.zig
│   │   ├── dispatcher.zig
│   │   ├── options.zig
│   │   ├── schema_tests.zig
│   │   ├── schema.zig
│   │   └── manifest.zig
│   ├── security/
│   │   └── validation.zig
│   ├── credentials/
│   │   └── source.zig
│   ├── policy/
│   │   ├── action.zig
│   │   ├── action_tests.zig
│   │   ├── approval.zig
│   │   ├── approval_receipt.zig
│   │   ├── host_authz.zig
│   │   ├── match.zig
│   │   ├── plan_hash.zig
│   │   ├── ruleset.zig
│   │   ├── scope.zig
│   │   └── source.zig
│   ├── transport/
│   │   ├── chunk.zig
│   │   ├── chunk_index.zig
│   │   ├── chunk_paths.zig
│   │   ├── chunk_upload.zig
│   │   ├── manifest.zig
│   │   ├── remote_probe.zig
│   │   ├── rsync.zig
│   │   ├── runner.zig
│   │   └── scp.zig
│   ├── transfer/
│   │   ├── command.zig
│   │   ├── manifest_flow.zig
│   │   └── options.zig
│   └── util/
│       ├── fs.zig
│       ├── inventory_summary_counts.zig
│       ├── inventory_summary_dev.zig
│       ├── inventory_summary_details.zig
│       ├── inventory_summary_overview.zig
│       ├── inventory_summary_runtime.zig
│       ├── inventory_summary_system.zig
│       ├── inventory_summary.zig
│       ├── json.zig
│       ├── plan_summary.zig
│       ├── paths.zig
│       └── summary.zig
├── README.md
├── PRD_zh.md
├── ARCHITECTURE_zh.md
└── CODE_QUALITY_zh.md
```

`src/security/validation.zig`、`src/credentials/source.zig`、`src/policy/*.zig`、`src/remote/*.zig`、`src/transport/*.zig`、`src/modules/*`、`src/rollback/*` 和 `src/audit/*` 已经形成第一轮清晰边界：安全层集中 host/path/argv/identity 校验，凭据层只描述 SSH identity 来源，策略层处理本地 allow/deny/risk/host/operator/ticket 约束，remote/transport 层是 SSH、scp、rsync、chunk 和远程 manifest 的唯一出口，module handler 负责 scan/plan/apply/verify/rollback 生命周期分发，rollback/audit 负责补偿记录和执行证据。项目未正式发布，后续边界冲突时直接重构调用点，不新增旧 API 兼容层；下一步重点是围绕个人服务器迁移补元数据保真、有状态 provider/cutover、远程源 chunk/agent、字节块级 chunk 和剩余非文件副作用 rollback。

## 4. 核心工作流程

### 4.1 两阶段设计

**阶段一：独立扫描（无需连接）**

```
源主机 (Source)                              目标主机 (Target)
     |                                            |
     |  hostlift scan                             |  hostlift scan
     |  扫描本地系统状态                            |  扫描本地系统状态
     |  生成 source-inventory.json                 |  生成 target-inventory.json
     |                                            |
     |  [扫描完成，可以离线保存清单]                  |  [扫描完成，可以离线保存清单]
```

**阶段二：规划与迁移**

```
控制机或操作者工作目录
     |
     |  hostlift plan --source source-inventory.json --target target-inventory.json
     |  生成 hostlift-plan.json，包含 action、risk、manual_step 和 plan hash
     |
     |  hostlift plan --selection
     |  输出按个人迁移批次分组的选择清单
     |
     |  hostlift validate --plan hostlift-plan.json
     |  校验 schema、风险、manual_step 和本地 policy
     |
     |  hostlift apply --plan hostlift-plan.json --dry-run
     |  预览真实远程副作用
     |
     |  hostlift apply --plan hostlift-plan.json --source-host OLD --host NEW --approve
     |  通过 remote/transport 边界执行已批准 action，写 audit 和 rollback manifest
     |
     |  hostlift audit verify / hostlift rollback
     |  校验证据链，必要时按动作级 rollback manifest 恢复
```

当前架构没有常驻源端服务，也没有 `export/import` 在线握手协议。跨主机数据传输通过 `transfer` 或 `apply` 内部文件型 action 进入 `transport/*`，远程命令只能从 `remote/*` 出去。

### 4.2 离线式迁移

当前已支持“清单离线、执行受控”的工作方式：源/目标 inventory 可以用任意安全方式带到控制机，plan 和审查不需要连接远程主机；真正复制文件时再使用 `apply --source-host` 或 `transfer --source-host`。

**源主机操作：**
```bash
# 扫描源主机并保存清单
hostlift scan --output source-inventory.json --summary --force
```

**目标主机操作：**
```bash
# 扫描目标主机
hostlift scan --output target-inventory.json --summary --force
```

**控制机操作：**
```bash
# 生成迁移计划
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --output hostlift-plan.json \
  --summary \
  --force

# 验证迁移计划
hostlift validate --plan hostlift-plan.json --summary

# 源机推目标机复制文件型 action
hostlift apply \
  --plan hostlift-plan.json \
  --source-host root@OLD \
  --host root@NEW \
  --run-state ./hostlift-run.jsonl \
  --transfer-transport rsync \
  --approve
```

approved apply 会先对全部未完成 action 做只读 preflight，再创建或恢复 `hostlift.apply.run_state.v1`。run state 是带 hash chain 的 JSONL，持有独占文件锁，头记录绑定 plan hash、目标 host、过滤后的 action 集合和 rollback manifest；action 记录保存 `started`、`rollback_prepared`、`succeeded`、`failed` 和恢复时的 `skipped`。`--resume-run` 只跳过有成功证据的 action，并复用首次 rollback 预备，任何绑定或链校验不一致都会在远程 mutation 前拒绝。

PostgreSQL 是第一个专属有状态 provider。默认 plan 仍输出 `appdata_restore`；只有同时提供 `--postgresql-auto --postgresql-writers-stopped` 才生成固定 DAG：

```text
dump(source, quiesce)
  -> target-baseline(target, quiesce)
  -> transfer(source -> target)
  -> restore(target)
  -> catalog-verify(source == target)
```

五个 action 通过同一 `/var/lib/hostlift/artifacts/postgresql/<source-inventory-hash>` subject 绑定。validator 检查 ID、数量、phase、依赖、risk、subject 后缀与 plan 的 source inventory hash 完全一致，以及链内 subject 一致性；apply handler 再做相同 hash 绑定检查，并执行 root/peer auth、同 major、源端零其它 client backend、fresh target、容量和 artifact 冲突门禁。dump/restore 命令不能来自 inventory hint，固定 SQL 只能从 `remote/postgresql.zig` 的 enum 出去。

可信 reinstall 是 resources 模块内的专属 provider。普通 plan 先由 `plan/modules/resources.zig` 生成 `script_reinstall`/`resource_reinstall` 人工合同；只有 `cli/plan.zig` 严格解析独立 `hostlift.reinstall_recipes.v1` 后，`plan/reinstall_provider.zig` 才会把精确 action 替换为固定三步 DAG：

```text
recipe JSON
  -> reinstall/schema.zig
  -> plan/reinstall_provider.zig
  -> plan/validator.zig
  -> modules/handlers/resources.zig
  -> modules/handlers/reinstall.zig
  -> remote/*
  -> apply/backup.zig + rollback/*
```

artifact subject 由 `reinstall/artifacts.zig` 同时绑定 source inventory hash 和 recipe ID；plan 内三条 action 必须携带完全相同的 spec。apply 全批次 preflight 会实时核对 root、目标 distro/version/arch、命令入口和全部路径冲突。download 固定写 `0700`/`0600` artifact，并同时执行 curl 字节上限、精确大小和 SHA-256 校验；execute 只允许经过 schema 校验的 script/install argv；verify 再检查 artifact、声明路径和原始 stdout hash。rollback 只能删除 recipe 声明的新路径，安装脚本的未声明副作用不在自动恢复范围。

文件型模块中，`copy_data_path`/`copy_project_path` 的 preflight 会通过 `manifest/local.zig` 或 `transport/manifest.zig` 构建完整源 manifest；`transport/remote_probe.zig` 批量执行远端 stat/hash，并读取符号链接目标。mutation 完成后，CLI 先写入新建路径 rollback baseline，再调用模块 verify 构建目标 manifest。截断、special file、缺项、额外项、类型/大小/hash/link target 不一致都会阻止 `succeeded` 状态。

真正的离线 bundle、对象存储 staging 或常驻 agent 可以作为后续增强，但不属于当前个人迁移默认主线。

## 5. 数据模型

### 5.1 清单

清单是一个仅包含事实的文档。它不包含应用决策。

```zig
const Inventory = struct {
    schema_version: []const u8,
    host: HostInfo,
    distro: DistroInfo,
    package_manager: PackageManagerInfo,
    modules: ModuleInventory,
    scan: ScanMetadata,
};

const HostInfo = struct {
    hostname: []const u8,
    machine_id_hash: ?[32]u8,
    kernel_release: []const u8,
    arch: CpuArch,
};

const DistroInfo = struct {
    id: []const u8,
    id_like: [][]const u8,
    version_id: []const u8,
    pretty_name: []const u8,
};

const PackageManagerInfo = struct {
    kind: PackageManagerKind,
    version: []const u8,
    repos: []RepositoryRef,
};
```

清单应可序列化为规范 JSON，以便可以进行差异比较、归档和在测试中使用。

### 5.2 迁移项

```zig
const MigrationItem = struct {
    id: []const u8,
    module: ModuleName,
    kind: ItemKind,
    source_ref: SourceRef,
    target_ref: ?TargetRef,
    size: u64,
    checksum: ?[32]u8,
    metadata: ItemMetadata,
    compatibility: Compatibility,
    risk: RiskLevel,
    secret: bool,
};

const Compatibility = struct {
    same_distro_required: bool,
    same_version_required: bool,
    arch: ArchCompatibility,
    host_identity_bound: bool,
    cloud_provider_bound: bool,
    hardware_bound: bool,
};

const ArchCompatibility = enum {
    independent,
    rebuild_required,
    incompatible,
    unknown,
};

const RiskLevel = enum {
    low,
    medium,
    high,
    critical,
};
```

### 5.3 计划

计划是审查和执行之间的契约。

```zig
const MigrationPlan = struct {
    schema_version: []const u8,
    source_inventory_hash: [32]u8,
    target_inventory_hash: [32]u8,
    compatibility: CompatibilityResult,
    actions: []Action,
    unresolved: []UnresolvedItem,
    warnings: []PlanWarning,
    created_at: i64,
};
```

### 5.4 操作

操作是类型化的，并且在可能的情况下是可逆的。

```zig
const Action = struct {
    id: []const u8,
    module: ModuleName,
    action_type: ActionType,
    description: []const u8,
    risk: RiskLevel,
    requires_confirmation: bool,
    phase: ?ActionPhase,
    depends_on: ?[]const []const u8,
    manual_task: ?ManualTask,
};

const ManualTask = struct {
    schema_version: []const u8, // hostlift.manual_task.v2
    kind: ManualTaskKind,
    provider: []const u8,
    inputs: []ManualInput,
    secret_refs: ?[]const []const u8,
    preconditions: []ManualCondition,
    expected_outputs: []ManualOutput,
    verify_probes: []ManualProbe,
    rollback_policy: ManualRollbackPolicy,
    evidence_schema: []const u8,
};

const ActionType = enum {
    install_package,
    add_repository,
    write_file,
    merge_file,
    create_directory,
    create_user,
    create_group,
    add_authorized_key,
    install_systemd_unit,
    enable_systemd_unit,
    enable_user_systemd_unit,
    enable_sysv_init,
    disable_sysv_init,
    enable_openrc_service,
    disable_openrc_service,
    install_cron_entry,
    copy_home_config,
    copy_data_path,
    copy_project_path,
    start_compose_project,
    verify_compose_project,
    apply_firewall_config,
    run_command,
    manual_step,
};
```

任何模块都不应直接从扫描结果执行 shell 命令。模块生成操作，执行器验证并运行它们。

当前 builder 输出 `hostlift.plan.v2`，同时保留 v1 读取兼容。`src/plan/dag.zig` 为可确定的生命周期补依赖边；validator 要求依赖已存在且出现在当前 action 之前，拒绝环和阶段逆序。plan/apply 过滤器只验证闭包，不自动扩大选择范围。manual task 已具备通用机器合同，`common.ManualTaskSpec` 允许 planner 追加深拷贝的 provider inputs 和 verify probe override；script/resource reinstall、appdata restore、systemd status 和 container status 已接入，secret 专属合同仍需扩展。

reinstall recipe 不是 manual evidence 的替代物：它在 plan 构建时把一条人工任务升级为可执行 action，因此 validator 必须证明原 manual action 已移除、每个 recipe 恰有 download/execute/verify 三条 action、链内 spec/subject 完全一致，并拒绝手写 plan 中重复 recipe、重复 manual action 或重叠 managed paths。scanner 中的 URL/checksum 字段只作为 AI 研究线索，不能直接进入执行路径。

`src/manual_evidence/schema.zig` 定义 `hostlift.manual_evidence.v1`，`src/manual_evidence/validator.zig` 负责把单份 evidence 绑定到原始 plan 字节 SHA-256、manual action、task kind 和 provider，并逐项校验 precondition、expected output 和 verify probe。`src/manual_evidence/completeness.zig` 再按 plan 中全部 manual action 聚合单文件校验摘要，生成 `hostlift.manual_evidence.completeness.v1`，失败关闭区分 missing、duplicate、invalid 和 unexpected evidence。CLI 的 `evidence validate/completeness` 只负责读取文件和输出报告；schema 不含 stdout、命令文本或 secret value 字段，解析时拒绝未知字段。

完整度报告固定输出 `trust_level=contract_only`。这两个验证路径都不连接远程主机、不执行 probe、不验签、不写 apply run-state，也不改变 executor 对 `manual_step` 的原子拒绝；即使 `contract_complete=true`，仍不能把 workload 或业务健康状态改成 complete。

`src/manual_evidence/ledger.zig` 提供 `hostlift.manual_evidence.ledger.v1` JSONL 持久层。`evidence record` 在任何 ledger 写入前从原始 evidence bytes 重新严格解析、运行 validator 并计算 SHA-256；文件打开后持有 exclusive lock，已有 ledger 必须通过全链、plan hash、ledger id、manual action、provider/task kind 和 action 唯一性校验，随后才追加摘要并立即 flush。新 ledger 使用 exclusive create，现有 ledger 不允许跨 plan 或为同一 action 追加第二份记录。

`evidence verify-ledger` 使用 shared advisory lock 读取，避免与 record 的 exclusive lock 追加形成半记录；输出 `hostlift.manual_evidence.ledger.verify.v1`，按 plan 顺序列出已登记和缺失的 manual action。`valid` 只描述链与绑定，`ledger_contract_complete` 描述覆盖，`trust_level=hash_chain_only` 明确它没有外部签名、可信时间戳或不可变存储锚点。ledger 不保存 evidence 正文，也不接入 run-state/workload/apply。

可信只读 probe 继续遵守原有分层，而不是从 evidence CLI 直接拼 SSH：

```text
cli/evidence.zig（子命令分发）
  -> cli/evidence_probe.zig（probe/validate-probed 参数、文件读写和输出）
  -> security/validation.zig（host 和 provider target）
  -> remote/manual_probe.zig（固定只读 argv、SSH、丢弃原始输出）
  -> manual_evidence/probe_schema.zig（hostlift.manual_probe_report.v1）
  -> manual_evidence/probed_validator.zig（report 原始 SHA-256 + host + task/probe 绑定）
```

首批 executor 支持 systemd、Docker/Podman container、TCP 和 HTTP；command/log/manual_evidence 失败关闭为 unsupported。自动 planner 当前为 systemd start/status review 和 container check 生成可执行 probe，其它 TCP/HTTP target 需要后续 scanner/provider 结构化提供。probe 是只读 SSH，不需要 apply `--approve`，但必须显式给出 host 和独占 output；它不写 apply run-state、workload 或 rollback，也不执行 manual action。报告未签名，`hostlift_remote_read_only` 只说明固定执行路径，不证明作者身份或阻止整份本地文件被重建。

### 5.5 工作负载完成度报告

`src/plan/workload_schema.zig` 定义 `hostlift.workload_report.v1`，`src/plan/workloads.zig` 只读聚合 source inventory、target inventory 和完整 migration plan。当前按 systemd 服务、项目/Compose、应用数据路径、Docker/Podman 容器和未托管资源建立工作负载；组件 action id 用于把模块动作重新关联到应用主体，无法可靠归属的 action 保留在 `unassigned_action_ids`，仍影响 `host_status`。

状态顺序按失败关闭设计：非完整 scan、扫描 warning/truncated 或组件事实不足为 `unknown`；不满足 action 兼容要求、`compatibility_review`、其它 manual/critical action 为 `blocked`；可移植普通未决 action 为 `pending`；只有所有已建模组件匹配且无 action 才是 `complete`。全局 `compatibility.compatible=false` 本身不再阻断所有 workload。scanner 用可选 `scan.full_scan` 区分完整扫描、过滤扫描和缺少该元数据的旧 inventory；CLI 的 `plan --workloads` 禁止 action/module filter，避免裁掉未决动作后误报完整。

这个报告仍是离线事实收敛视图，不是执行 ledger。迁移后需要重新扫描目标机；当前单文件 validator、plan 级 completeness 和 hash-chain evidence ledger 都尚未接入 workload。后续如果合并 run-state、manual evidence 和健康探针，应在 plan/workload 领域层增加显式 evidence 合并合同，不能让 CLI 直接猜测 JSONL 或绕过 audit/verify 边界。

## 6. 兼容性规则

### 6.1 完整主机兼容与 action 门控

`compatibility.compatible` 只在发行版 ID、版本、已知包管理器和已知 CPU 架构四项全部相同时为 true。plan v2 不再把这个聚合值当作整份 plan 的开关：builder 先生成候选 action，再由 `src/plan/action_compatibility.zig` 按 action 类型和模块分类。

```text
portable                 project/appdata/home/user/authorized_keys/manual
same_package_manager     package install
same_distro_version      system config/cron/init/firewall
same_arch                resources/container volume/Compose runtime
full_host                repository/通用命令
```

不满足最低要求的候选动作会原位改写为 `compatibility_review` 结构化人工任务，保留原 action ID、类型、模块、要求和 mismatch。validator 对 v2 逐 action 复核，apply executor 在远程 preflight 前再次复核；旧 v1 仍要求完整主机兼容。

### 6.2 架构门控

如果架构不同：

- 文本文件可以迁移。
- 如果目标仓库为目标架构提供包，则包意图可以迁移。
- Docker 镜像引用可以迁移，但拉取/应用需要目标架构可用。
- `/opt` install root、未托管资源、容器 volume 和 Compose runtime action 不自动放行，其中资源复制会转为兼容性人工任务。

当前门禁仍是粗粒度第一阶段：它没有证明 ELF interpreter、glibc/musl、SONAME、目标动态库、CPU feature 或镜像 manifest 可用。`same_arch=true` 不是二进制兼容证明。

### 6.3 云提供商门控

以下默认为 `manual`：

- 静态 IP 配置。
- 默认路由。
- 云初始化数据源配置。
- 提供商代理配置。
- 非替换模式下的主机名。
- 机器 ID。
- SSH 主机密钥。

## 7. 模块设计

每个模块实现相同的生命周期：

```zig
const Module = struct {
    name: ModuleName,
    scan: fn (ctx: ScanContext) !ModuleInventory,
    diff: fn (ctx: PlanContext, source: ModuleInventory, target: ModuleInventory) ![]Action,
    validate: fn (ctx: ValidateContext, action: Action) !ValidationResult,
    apply: fn (ctx: ApplyContext, action: Action) !ApplyResult,
    verify: fn (ctx: VerifyContext, action: Action) !VerifyResult,
    rollback: fn (ctx: RollbackContext, entry: RollbackEntry) !RollbackResult,
};
```

扫描必须无副作用。差异必须是确定性的。应用必须尽可能幂等。

### 7.1 包

扫描器命令：

```
apt:  apt-mark showmanual
      apt-mark showhold
      apt-cache policy
      find /etc/apt/sources.list /etc/apt/sources.list.d -type f

dnf:  dnf repoquery --userinstalled
      dnf repolist --all
      find /etc/yum.repos.d -type f

pacman: pacman -Qqe
        pacman -Qqm
        cat /etc/pacman.conf

zypper: zypper search --installed-only
        zypper repos
```

规划器：

```
1. 首先添加仓库操作
2. 刷新包元数据
3. 检查目标包可用性
4. 为显式包生成安装操作
5. 为缺失的包生成未解决项
```

执行器：

```
1. 使用包管理器命令包装器
2. 不直接编辑包数据库文件
3. 在应用前后记录已安装的包列表
```

### 7.2 服务

扫描器：

```
systemctl list-unit-files --type=service --no-pager --plain
systemctl list-units --type=service --all --no-pager --plain
systemctl list-timers --all --no-pager --plain
find /etc/systemd/system -type f
```

规划器：

```
1. 迁移自定义单元和覆盖
2. 如果可能，验证引用的路径
3. 仅在单元验证后启用服务
4. 对源端运行中、目标端未运行的 service 生成 `services/review-start/<unit>` 和 `services/check-status/<unit>` 高风险人工步骤，默认不自动启动服务
```

验证器：

```
systemd-analyze verify <unit>
systemctl is-enabled <unit>
```

默认情况下不启动服务。

### 7.3 用户和组

扫描器解析：

```
/etc/passwd
/etc/group
/etc/subuid
/etc/subgid
/etc/sudoers
/etc/sudoers.d
```

规则：

```
1. 默认不选择系统用户
2. UID/GID 保留需要无冲突
3. 默认排除密码哈希
4. Sudo 更改作为片段写入，并使用 visudo -c 检查
```

### 7.4 SSH

扫描器：

```
~/.ssh/authorized_keys
~/.ssh/config
/etc/ssh/sshd_config
/etc/ssh/sshd_config.d
```

规则：

```
1. authorized_keys 可以安全合并
2. 私钥是秘密，默认关闭
3. 主机密钥是手动的
4. 在应用服务器配置之前需要 sshd -t
```

### 7.5 配置

配置模块使用配置文件：

```
nginx:
  paths: /etc/nginx
  validate: nginx -t
  reload: systemctl reload nginx

apache:
  paths: /etc/apache2, /etc/httpd
  validate: apachectl configtest

redis:
  paths: /etc/redis, /etc/redis.conf
  validate: redis-server --test-memory 2
```

配置文件定义路径、排除项、验证命令和服务关系。

### 7.6 应用数据

数据复制使用清单：

```zig
const DataManifestEntry = struct {
    path: []const u8,
    file_type: FileType,
    size: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    mtime: i64,
    checksum: [32]u8,
};
```

大路径作为块传输。接收器在最终重命名前验证校验和。

### 7.6.1 PostgreSQL Provider

PostgreSQL provider 只支持 PostgreSQL 10+、源/目标同 major、root SSH、`postgres` OS 用户 peer 认证和无业务对象的 fresh target。它执行逻辑 dump，不复制 PGDATA。源端业务必须在 dump 前停写并保持维护窗口；运行时只读探针会拒绝除 HostLift 自身查询外仍有任何 client backend，但不声称能阻止之后的新连接。

artifact 正文可能包含 role password hash，因此目录为 `0700`、文件为 `0600`，正文不会写进 JSON/JSONL。rollback manifest 只记录 target baseline 路径和 SHA-256；dispatcher 对 `postgresql_manual_recovery` 返回 `ManualRollbackRequired`。这条边界使恢复证据可审计，但不会把逻辑 dump 误报为事务级自动回滚。

### 7.7 Docker

规则：

- `/etc/docker/daemon.json` 是配置项。
- Compose 文件是配置/数据项。
- 镜像引用是类似包的重建项。
- 扫描会报告 Docker/Podman 可用性、运行中 Docker 容器、Docker volume/network 元数据和 Compose 文件候选路径。
- 扫描实现已拆成 `docker_runtime.zig`、`docker_containers.zig`、`docker_resources.zig` 和 `docker_compose.zig`，`docker.zig` 只做聚合入口。
- 规划阶段会为 runtime、volume、network、运行中容器和 Compose 文件生成人工审查项。
- 卷和网络被报告，但不自动复制或重建。
- `/var/lib/docker` 不支持自动迁移。

### 7.8 防火墙和网络

防火墙应用需要后端匹配。网络应用默认关闭。

在应用防火墙更改之前：

- 检测活动的 SSH 端口。
- 检查生成的规则是否允许该端口。
- 对锁定风险要求明确确认。

## 8. 执行器设计

### 8.1 操作执行流程

```
对每个已批准的操作:
  1. 检查前置条件
  2. 如果需要，创建备份
  3. 应用操作
  4. 验证操作
  5. 记录结果
  6. 根据失败策略决定停止或继续
```

### 8.2 原子文件写入

文件写入必须：

```
1. 写入同一文件系统中的临时文件
2. 设置模式、所有者、组
3. 在支持的情况下对临时文件进行 fsync
4. 重命名到位
5. 在支持的情况下对父目录进行 fsync
```

### 8.3 备份布局

```text
/var/lib/hostlift/
├── inventories/
├── plans/
├── bundles/
├── rollback/
│   └── 2026-05-26T12-00-00Z/
│       ├── rollback.json
│       └── files/
└── state/
```

### 8.4 回滚条目

```zig
const RollbackEntry = struct {
    action_id: []const u8,
    action_type: ActionType,
    support: RollbackSupport,
    target: []const u8,
    previous_state: ?PreviousState,
    backup_path: ?[]const u8,
    applied_at: i64,
};

const RollbackSupport = enum {
    full,
    partial,
    none,
};
```

## 9. 传输设计

### 9.1 离线包

离线包是一个类似 tar 的归档，带有清单：

```text
hostlift-bundle/
├── manifest.json
├── source-inventory.json
├── files/
├── chunks/
└── checksums.txt
```

秘密包必须加密。

### 9.2 在线 P2P

P2P 传输用于便利性，但内部使用相同的清单和块模型。

消息：

```zig
const MessageType = enum(u8) {
    hello = 0x01,
    auth_challenge = 0x02,
    auth_response = 0x03,
    auth_ok = 0x04,
    inventory = 0x10,
    plan_request = 0x11,
    manifest = 0x20,
    chunk = 0x21,
    chunk_ack = 0x22,
    error = 0x30,
    done = 0xF0,
};
```

认证应使用高熵一次性令牌或基于 PAKE 的配对流程。仅短数字代码不足以用于根级迁移通道。

### 9.3 可恢复性

块传输状态：

```zig
const ChunkState = struct {
    file_id: []const u8,
    chunk_size: u64,
    total_chunks: u64,
    received_bitmap: []u8,
    file_checksum: [32]u8,
};
```

重连后目标请求缺失的块。

## 10. 安全设计

### 10.1 威胁

| 威胁 | 缓解措施 |
|---|---|
| 未授权的目标连接到源 | 过期的高熵配对令牌、会话绑定 |
| 网络窃听 | 加密传输 |
| 包被盗 | 可选包加密；包含秘密时必需 |
| 日志中的秘密泄露 | 在序列化和日志层进行编辑 |
| SSH 锁定 | 预检和应用后锁定检查 |
| 目标损坏 | 计划审查、备份、验证、回滚元数据 |
| 命令注入 | 不使用不受信任的 shell 插值；进程参数是结构化的 |

### 10.2 秘密模型

秘密值永远不会完整打印。秘密项元数据可能包括：

- 路径。
- 大小。
- 哈希。
- 所有者和模式。
- 编辑后的预览标记。

### 10.3 命令执行

命令必须使用 argv 数组执行，而不是 shell 字符串，除非命令明确需要 shell 语义并且已经过审查。

错误：

```text
sh -c "systemctl enable " + unit_name
```

正确：

```text
execve("/bin/systemctl", ["systemctl", "enable", unit_name])
```

## 11. 错误处理

失败策略是可配置的：

| 策略 | 行为 |
|------|------|
| `stop` | 在第一个失败的操作时停止 |
| `continue_module` | 在安全的情况下在模块内继续 |
| `continue_all` | 继续所有独立操作 |

默认情况下，高风险操作为 `stop`，低风险独立操作为 `continue_module`。

每个失败的操作必须记录：

```
1. 错误类型
2. 命令和退出代码（如果适用）
3. 编辑后的 stderr/stdout
4. 是否尝试了回滚
5. 手动恢复提示
```

## 12. 测试策略

### 12.1 单元测试

覆盖：

```
- /etc/os-release 解析器
- 包管理器输出解析器
- passwd/group/sudoers 解析
- 计划差异逻辑
- 风险分类
- 操作序列化
- 路径包含/排除匹配
```

### 12.2 固定测试

固定测试应代表：

```
- Ubuntu 24.04 到 Ubuntu 24.04
- Debian 12 到 Debian 12
- Rocky Linux 9 到 Rocky Linux 9
- 相同发行版但不同架构
- 用户、包、服务和配置文件的目标冲突
```

### 12.3 集成测试

使用容器或虚拟机进行：

```
- 包安装干运行
- 在 systemd 可用的地方进行 systemd 单元验证
- 文件备份和回滚
- 应用数据块传输
- 离线包导入
```

容器不是完美的 systemd 测试环境，因此在 v1 之前需要基于虚拟机的测试。

### 12.4 手动测试矩阵

在 v1 之前：

| 源 | 目标 | 架构 | 必需结果 |
|---|---|---|---|
| Ubuntu 24.04 | Ubuntu 24.04 | x86_64 到 x86_64 | 完整支持的模块通过 |
| Ubuntu 24.04 | Ubuntu 24.04 | x86_64 到 aarch64 | 二进制项标记为重建/手动 |
| Debian 12 | Debian 12 | x86_64 到 x86_64 | 完整支持的模块通过 |
| Rocky 9 | Rocky 9 | x86_64 到 x86_64 | DNF 包路径通过 |

## 13. 构建和依赖

### 13.1 构建目标

```zig
const targets = [_]TargetSpec{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .arm, .os_tag = .linux },
};
```

工件：

```text
hostlift-x86_64-linux
hostlift-aarch64-linux
hostlift-armv7-linux
```

### 13.2 依赖指导

优先选择小型、可审计的依赖：

| 依赖 | 用途 | 备注 |
|---|---|---|
| TLS/加密库 | 在线传输加密 | 必须支持现代 TLS 或经过审查的 Noise/PAKE 设计 |
| zstd | 压缩 | 用于包和传输 |
| TOML 解析器 | 配置 | 如果需要，可以替换为小型本地解析器 |
| JSON 序列化器/解析器 | 清单和计划 | 需要规范输出 |

不要仅因为 TLS 库小而选择它。协议支持、维护和安全状况对此工具更重要。

## 14. 设计决策

### 14.1 首先支持相同发行版和版本

**决策：** 已接受

**理由：** 跨发行版迁移很有价值，但需要包映射、配置路径映射和语义服务迁移。v1 首先解决高置信度场景。

### 14.2 清单和计划作为一等工件

**决策：** 已接受

**理由：** 这使得工具可审计、可测试且更安全。它还支持离线迁移。

### 14.3 基于操作的应用和回滚

**决策：** 已接受

**理由：** 文件级回滚对于包安装、用户、服务、防火墙和命令来说是不够的。

### 14.4 网络迁移默认关闭

**决策：** 已接受

**理由：** 云提供商网络是锁定用户新服务器的最简单方法之一。HostLift 报告网络状态，但仅应用选定的安全项。

### 14.5 数据库默认人工，专属 Provider 显式开放

**决策：** 已接受

**理由：** 数据库数据目录仍不得走通用文件复制。MySQL/Redis 等默认继续使用本机转储、快照或人工 provider；PostgreSQL 只在双 opt-in、停写、同 major 和 fresh target 条件下开放固定逻辑迁移 DAG，并保留 manual recovery，而不是宣称通用自动迁移。
