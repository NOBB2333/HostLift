# HostLift 技术设计

## 1. 文档定位

README 说明怎么使用 HostLift。本文说明 HostLift 的代码设计思路、架构分层、关键数据流、模块边界和后续扩展方式。

本文可以按三层来读：

1. **实现方案**：HostLift 如何把两台 Linux 主机迁移拆成 scan、plan、validate、apply、audit 和 rollback。
2. **代码架构**：CLI、inventory、plan、modules、apply、remote、transport、policy、audit、rollback 各自负责什么。
3. **扩展规则**：新增一个模块、传输后端、凭据 provider、审计 sink 或企业审批能力时，应该改哪些文件，哪些边界不能绕过。

HostLift 的目标不是做一个长期驻留 agent，也不是做整盘克隆。它的核心是把 Linux 迁移过程变成一条可落盘、可审查、可批准、可审计、可回滚的结构化流水线：

```text
source inventory
  + target inventory
  -> migration plan
  -> validate / policy
  -> dry-run
  -> approved apply
  -> audit log + rollback manifest
```

这个设计让人工或 AI 可以先离线审查 inventory、plan 和 dry-run 输出。真正修改远程机器时，执行路径必须经过 `--approve`、policy、registry、security、remote/transport、audit 和 rollback 边界。

本文从代码实现角度解释三件事：

1. 用户命令怎么进入 HostLift，并转成结构化 options。
2. inventory、plan、policy、audit 和 rollback 这些文件型协议怎么贯穿系统。
3. 新增 Linux 迁移能力时，代码应该放在哪一层，怎样避免把远程执行、安全校验和领域逻辑混在一起。

一句话概括当前实现：**HostLift 是一个单二进制 CLI，靠文件型协议保存迁移状态，靠 registry 声明模块能力，靠 remote/transport adapter 集中所有外部副作用，靠 audit/rollback 保存执行证据和恢复路径。**

## 1.0 技术方案总览

HostLift 的技术方案可以概括为“单二进制 CLI + 文件型协议 + provider/adapter 边界”。它不要求两台 Linux 主机常驻 agent，也不需要先部署中心服务。控制机通过 SSH、scp、rsync 或后续 transport provider 编排迁移；旧机器和新机器只需要能运行 HostLift 二进制并允许必要的远程命令。

核心实现思路如下：

```text
本机 CLI
  -> 解析 argv，读取 policy/receipt/host-authz
  -> scan 在源/目标主机本地生成 inventory JSON
  -> plan 在控制机离线比较 inventory
  -> validate/dry-run 做 schema、风险、policy 和依赖预览
  -> apply --approve 通过 handler 调用 remote/transport adapter
  -> audit 写 JSONL hash chain
  -> rollback 写 JSONL 补偿 manifest
```

这套方案的关键取舍是：

- **迁移状态落盘**：inventory、plan、audit 和 rollback 都是文件，方便人工审查、AI 分析、工单归档和失败复盘。
- **执行必须显式批准**：`scan`、`plan`、`validate`、`dry-run` 都不修改远端，只有 `apply --approve`、`transfer --approve`、`remote exec --approve` 和 `rollback --approve` 会产生副作用。
- **副作用集中出口**：SSH 命令只走 `src/remote/*`，文件传输只走 `src/transport/*`，审计只走 `src/audit/*`，避免各模块散落 shell 拼接。
- **模块按生命周期拆分**：一个能力从 scan-only 到 plan、apply、verify、rollback 可以分阶段演进，不要求一开始就自动迁移所有高风险资源。
- **企业能力用 provider 接入**：凭据、审批、主机授权、审计 sink、传输后端和防火墙后端都应通过 provider/adapter 扩展，而不是写死在 CLI 或 action 里。

从用户视角看，HostLift 是一个命令行工具；从代码视角看，真正稳定的接口是下面这些契约：

| 契约 | 落盘形态 | 作用 |
| --- | --- | --- |
| Inventory | JSON | 描述一台主机上扫描到的事实 |
| MigrationPlan | JSON | 描述准备执行哪些迁移动作 |
| Policy / HostAuthorization / ApprovalReceipt | JSON | 描述执行前允许范围、操作者、主机和审批上下文 |
| CommandPlan / TransferPlan | JSON 或内部结构 | 描述远程命令和文件传输怎么执行 |
| AuditEvent | JSONL | 描述 approved 执行证据和 hash chain |
| RollbackManifest | JSONL | 描述已执行副作用如何补偿恢复 |

因此后续如果新增 Web 控制台、TUI、HTTP API 或 AI 控制面，也应该调用同一套 schema、registry、policy、remote/transport、audit 和 rollback 代码，而不是绕过 CLI 重新拼远程命令。

## 1.0.1 核心代码边界

从工程实现看，HostLift 最重要的不是某个单独命令，而是边界是否稳定。当前边界如下：

| 边界 | 代码位置 | 说明 |
| --- | --- | --- |
| 用户入口 | `src/main.zig`、`src/cli.zig`、`src/cli/*.zig` | 只解析 argv、读写文件、打印摘要 |
| 主机事实 | `src/inventory/*.zig`、`src/inventory/schema_parts/*.zig` | 只读扫描 Linux 事实，失败写 warning |
| 迁移计划 | `src/plan/*.zig`、`src/plan/modules/*.zig` | 把 source/target 差异转成 action |
| 模块生命周期 | `src/modules/*.zig`、`src/modules/handlers/*.zig` | 声明 scan/plan/apply/verify/rollback 能力 |
| 受控执行 | `src/apply/*.zig`、`src/apply/action/*.zig` | approved 后分发 action、备份、verify、写 rollback |
| 远程命令 | `src/remote/*.zig` | SSH argv、风险、timeout、retry、operation state |
| 文件传输 | `src/transport/*.zig`、`src/transfer/*.zig` | scp、rsync、chunk、远程 manifest |
| 执行门禁 | `src/security/*.zig`、`src/policy/*.zig`、`src/credentials/*.zig` | host/path/argv/identity 校验，本地策略、审批凭证、凭据来源 |
| 审计恢复 | `src/audit/*.zig`、`src/rollback/*.zig` | JSONL hash chain、sink、replay、rollback manifest |

这张表是后续开发的约束：CLI 不能直接 SSH，inventory 不能生成副作用，plan 不能连接远程主机，业务 handler 不能自己写审计 sink，凭据材料不能进入 inventory、plan、audit 或 rollback。

## 1.0.2 迁移执行链路

一次完整迁移在代码里按下面顺序流动：

```text
cli/scan
  -> inventory/scanner + scan_registry
  -> source-inventory.json / target-inventory.json

cli/plan
  -> plan/builder + plan/modules
  -> hostlift-plan.json

cli/validate 或 cli/apply --dry-run
  -> plan/validator
  -> policy/action
  -> readable report

cli/apply --approve
  -> common_options / credentials / host_authz
  -> apply/preflight
  -> apply/executor
  -> modules/handlers/*
  -> remote/* 或 transport/*
  -> verify
  -> audit JSONL
  -> rollback JSONL
```

这条链路同时服务人工、脚本和 AI：AI 可以读取前半段产物做建议；真正修改目标机时，必须进入后半段受控执行路径。

## 1.1 代码设计入口图

开发时可以按下面的入口快速定位代码：

| 想改的能力 | 先看文件 | 再看文件 |
| --- | --- | --- |
| 新增命令参数 | `src/cli/<command>.zig` | 对应 `options.zig`、`security/validation.zig` |
| 新增扫描项 | `src/inventory/<module>.zig` | `src/inventory/schema_parts/*.zig`、`src/inventory/scan_runner.zig` |
| 新增 plan action | `src/plan/modules/<module>.zig` | `src/plan/schema.zig`、`src/plan/validator.zig` |
| 新增自动 apply | `src/modules/apply_support.zig` | `src/modules/handlers/<module>.zig`、`src/apply/action/<module>.zig` |
| 新增远程命令 | `src/remote/command_plan.zig` | `src/remote/runner.zig`、`src/remote/preflight.zig` |
| 新增传输后端 | `src/remote/transfer_plan.zig` | `src/transport/*.zig`、`src/transfer/manifest_flow.zig` |
| 新增审计输出 | `src/audit/sink_target.zig` | `src/audit/combined_sink.zig`、`src/audit/replay_sink.zig` |
| 新增 rollback 类型 | `src/rollback/schema.zig` | `src/rollback/dispatcher.zig`、模块 handler |
| 新增高风险模块 | `src/inventory/<module>.zig` | `src/plan/modules/*_review.zig`，先生成 `manual_step` |

新增能力时的最小闭环是：先有 schema 和 scan，再有 plan 和 validator，最后才接 apply、verify、rollback。高风险模块，例如 sudoers、ACL、防火墙、用户、存储、SELinux/AppArmor、Docker/Podman 和服务启动项，应该先做 scan-only 或 manual_step，再逐步补自动执行。

## 1.2 实现设计速读

HostLift 的实现可以先按一条主线理解：CLI 只负责把用户输入变成结构化参数；inventory 只负责采集事实；plan 只负责把差异变成动作；apply 只在显式批准后执行动作；remote/transport 是唯一外部副作用出口；audit/rollback 保存证据和恢复信息。

```text
src/main.zig
  -> src/cli.zig
  -> src/cli/<command>.zig
  -> options / schema / policy
  -> inventory 或 plan 或 apply
  -> modules registry
  -> remote / transport
  -> audit / rollback
```

最核心的设计判断是：HostLift 不把迁移写成一批临时 shell 脚本，而是把每一步都变成结构化契约。用户、AI、工单系统和测试都应该读写这些契约，而不是依赖某个临时输出文本。

当前 README 面向使用者，说明如何扫描、规划、传输、远程执行、审批、审计和回滚；本文面向开发者，说明这些命令在代码里如何分层实现，以及新增能力时应该改哪些文件。

| 契约 | 文件形态 | 代码位置 | 作用 |
| --- | --- | --- | --- |
| Inventory | JSON | `src/inventory/schema.zig`、`src/inventory/module_inventory.zig`、`src/inventory/schema_parts/*.zig` | 描述一台机器有什么 |
| MigrationPlan | JSON | `src/plan/schema.zig`、`src/plan/builder.zig`、`src/plan/modules/*.zig` | 描述准备执行哪些迁移动作 |
| Policy | JSON | `src/policy/*.zig` | 在执行前限制 host、operator、模块、action、风险和审批 |
| ApprovalReceipt | JSON | `src/policy/approval_receipt.zig` | 把本地审批凭证绑定到 ticket、operator、host、plan hash 和 purpose |
| HostAuthorization | JSON | `src/policy/host_authz.zig` | 把本地 operator 字符串限制到可操作 host |
| CommandPlan | JSON/内部结构 | `src/remote/command_plan.zig` | 描述一次 SSH 命令执行 |
| TransferPlan | JSON/内部结构 | `src/remote/transfer_plan.zig`、`src/transport/*.zig` | 描述一次文件传输 |
| AuditEvent | JSONL | `src/audit/*.zig` | 记录 approved 执行证据和 hash chain |
| RollbackManifest | JSONL | `src/rollback/*.zig` | 记录已执行副作用如何恢复 |

代码设计上有四个固定边界：

1. **入口边界**：`src/cli/*.zig` 解析参数、读写文件、打印摘要，不直接拼远程 shell。
2. **领域边界**：`src/inventory/*`、`src/plan/*`、`src/apply/action/*` 表达 Linux 迁移语义，不保存私钥、不写审计 sink。
3. **副作用边界**：SSH 只走 `src/remote/*`，文件传输只走 `src/transport/*`，审计输出只走 `src/audit/*`。
4. **恢复边界**：approved apply 产生可恢复副作用时必须写 rollback manifest；rollback 自身也必须经过 approve、policy 和 audit。

因此新增能力时，不应把所有逻辑塞进一个命令文件。以新增 `sudoers apply` 为例，正确拆分是：

```text
inventory/sudoers.zig                  扫描 sudoers 元数据
inventory/schema_parts/sudoers.zig     定义 inventory 结构
plan/modules/sudoers.zig               生成 sudoers action
plan/validator.zig                     校验 action payload 和风险
modules/apply_support.zig              声明支持的 action
modules/handlers/sudoers.zig           模块级分发
apply/action/sudoers.zig               上传临时文件、visudo 校验和原子替换
rollback/schema.zig                    增加 rollback entry 契约
rollback/dispatcher.zig                恢复备份并再次校验
audit/*.zig                            复用通用审计事件，不在 sudoers 模块自写 sink
```

这套拆分让每一部分都能单独测试，也能在后续接入 TUI、HTTP API、AI 控制面、Vault、RBAC 或 SIEM 时复用同一套核心契约。

## 1.3 一页式架构总览

HostLift 的代码按“输入、事实、计划、门禁、执行、证据”六段组织。每段都有清晰边界，避免把 Linux 迁移写成一组不可审查的远程 shell：

```text
CLI 输入层
  -> src/main.zig
  -> src/cli.zig
  -> src/cli/*.zig

事实采集层
  -> src/inventory/*.zig
  -> src/inventory/schema_parts/*.zig
  -> source-inventory.json / target-inventory.json

计划生成层
  -> src/plan/*.zig
  -> src/plan/modules/*.zig
  -> hostlift-plan.json

执行门禁层
  -> src/security/*.zig
  -> src/policy/*.zig
  -> src/credentials/*.zig
  -> src/modules/*registry*.zig

副作用边界层
  -> src/apply/*.zig
  -> src/remote/*.zig
  -> src/transport/*.zig
  -> src/firewall/*.zig

证据和恢复层
  -> src/audit/*.zig
  -> src/rollback/*.zig
  -> src/manifest/*.zig
```

端到端数据流如下：

```text
argv
  -> CLI options
  -> inventory JSON
  -> migration plan JSON
  -> validate / policy / dry-run
  -> approved executor
  -> remote command plan 或 transfer plan
  -> ssh/scp/rsync/chunk adapter
  -> audit JSONL + rollback JSONL
```

这套分层的核心约束是：

- `scan` 只写事实，不表达迁移意图。
- `plan` 只写动作计划，不连接远程主机。
- `validate` 和 `apply --dry-run` 只做校验和预览，不产生远程副作用。
- `apply --approve` 才允许修改目标机，并且必须经过 policy、host-authz、registry、preflight、audit 和 rollback。
- SSH 命令只能从 `src/remote/*` 出去，文件传输只能从 `src/transport/*` 出去。
- 新增高风险能力时，必须拆成 schema、scanner、planner、handler、action、verify、rollback 和测试几个切面，不能堆在 CLI 里。

从代码维护角度看，HostLift 的稳定接口不是某个内部函数，而是这些文件型协议和结构化计划：

| 协议或契约 | 落盘形态 | 主要消费者 |
| --- | --- | --- |
| Inventory | JSON | 人工、AI、plan builder、测试 fixture |
| MigrationPlan | JSON | validate、dry-run、apply、policy、audit |
| Policy | JSON | validate、apply、rollback |
| ApprovalReceipt | JSON | apply、rollback |
| CommandPlan | JSON 或内部结构 | remote exec、apply、rollback |
| TransferPlan | JSON 或内部结构 | transfer、apply、transport adapter |
| AuditEvent | JSONL | audit verify、audit replay、工单和审计系统 |
| RollbackManifest | JSONL | rollback、故障复盘 |

因此未来新增 TUI、HTTP API、AI 控制面或 agent 时，也应该复用这些契约。CLI 可以变，provider 可以换，文件协议和执行门禁链路不应被绕过。

## 1.4 设计目标和非目标

HostLift 当前的设计目标是做“受控迁移执行器”，不是做一个直接替代运维平台的全功能系统。

设计目标：

- 两台 Linux 主机之间迁移配置、服务、cron、用户、SSH、home 配置、项目目录、应用数据和部分运行时信息。
- 所有迁移动作都先变成可落盘、可审查、可过滤的 plan。
- 真实执行必须经过显式批准、策略校验、安全边界、审计和 rollback 记录。
- 支持 AI 或自动化系统读取 inventory、plan、dry-run 和 audit，但不让 AI 绕过执行边界直接 SSH 批量操作。
- 保持单个 Zig 二进制可部署，优先适配无中心服务、无 agent 的迁移场景。
- 通过 provider/adapter 边界给后续 RBAC、审批、凭据托管、SIEM 审计和更强传输能力留接口。

当前非目标：

- 不做整盘克隆，不保证系统级 bit-for-bit 还原。
- 不做实时双向同步。
- 不直接保证数据库、消息队列、Docker volume 等正在写入数据的一致性。
- 不内置企业身份、RBAC、堡垒机、密钥托管和审批系统。
- 不把所有发行版差异一次性自动抹平，跨发行版迁移仍需要人工审查 plan。

因此代码架构优先服务四件事：结构化事实、结构化计划、受控副作用、可审计恢复。

## 2. 技术实现摘要

HostLift 是单个 Zig 二进制。当前没有常驻服务，没有中心端数据库，也不要求两台机器安装 agent。

从技术实现看，HostLift 把 Linux 迁移拆成三类问题：

1. 发现问题：扫描源主机和目标主机，把系统事实写成 inventory。
2. 决策问题：比较两份 inventory，把“应该迁什么”写成 migration plan。
3. 执行问题：只有在显式批准后，按 policy、security、registry、audit 和 rollback 边界执行远程副作用。

这三类问题在代码里分别落到不同目录，避免把“扫描事实、生成建议、执行命令”写成一团远程 shell：

```text
src/cli/*       用户入口，把 argv 变成结构化 options
src/inventory/* 主机事实采集
src/plan/*      迁移动作生成、过滤、校验和 plan hash
src/modules/*   模块生命周期注册和 handler 分发
src/apply/*     approved apply 编排、备份、权限和 action 执行
src/remote/*    SSH 命令计划、风险、timeout、retry 和 runner
src/transport/* scp/rsync/远程 manifest 传输边界
src/policy/*    本地策略、审批凭证和主机授权
src/audit/*     审计事件、hash chain、sink、verify 和 replay
src/rollback/*  rollback manifest、恢复分发和后置校验
```

也就是说，用户看到的是 CLI 命令；真正稳定的内部契约是 inventory、plan、policy、approval receipt、command plan、transfer plan、audit event 和 rollback manifest。未来即使增加 TUI、HTTP API、AI 控制面或 agent，也应该复用这些契约，而不是重新定义一套迁移格式。

核心实现机制：

- `scan` 在 Linux 主机本地读取系统事实，生成 inventory JSON。
- `plan` 比较源/目标 inventory，生成 migration plan JSON，不连接远程主机。
- `validate` 校验 plan 结构、兼容性、风险和可选 policy。
- `apply --dry-run` 只预览动作。
- `apply --approve` 通过 registry 分发到模块 handler，再调用 remote/transport 执行 SSH、scp 或 rsync。
- approved apply 写审计日志和 rollback manifest。
- `rollback --approve` 读取 rollback manifest，执行恢复动作，并继续写审计日志。
- `audit verify` 校验本地 JSONL 审计日志的 hash chain。
- `audit replay` 先校验本地审计链，再把原始 JSONL 行重放到 file/syslog/HTTPS sink。

从工程实现看，HostLift 被拆成四类代码：

| 类型 | 职责 | 例子 |
| --- | --- | --- |
| 契约层 | 定义可落盘、可审查、可兼容演进的数据结构 | inventory schema、plan schema、policy、audit event、rollback entry |
| 领域层 | 决定 Linux 迁移语义，例如扫描什么、生成什么 action、如何恢复 | `inventory/*`、`plan/modules/*`、`apply/action/*`、`rollback/*` |
| 边界层 | 统一处理外部副作用和不可信输入 | `security/*`、`remote/*`、`transport/*`、`credentials/*`、`audit/*` |
| 入口层 | 解析 CLI 参数、读写文件、输出摘要 | `src/main.zig`、`src/cli.zig`、`src/cli/*.zig` |

实现上刻意使用“文件型协议 + 边界 adapter”的方式：

- 文件型协议：inventory、plan、policy、audit log、rollback manifest 都是可保存的 JSON/JSONL。
- 边界 adapter：SSH、scp、rsync、审计 sink、凭据来源和防火墙后端都被限制在独立模块中。
- 领域模块：packages、services、cron、users、projects 等模块只表达领域动作，不直接处理原始 argv 或私钥内容。
- 执行门禁：真实执行必须经过 `--approve`、policy、registry 能力声明和安全校验。

从实现角度看，HostLift 的稳定接口不是 CLI 参数本身，而是这些可落盘数据结构：

| 接口 | 作用 | 主要代码 |
| --- | --- | --- |
| Inventory | 描述一台机器有什么 | `src/inventory/schema.zig`、`src/inventory/module_inventory.zig`、`src/inventory/schema_parts/*.zig` |
| MigrationPlan | 描述应该执行哪些迁移动作 | `src/plan/schema.zig`、`src/plan/builder.zig`、`src/plan/modules/*.zig` |
| ActionPolicy | 描述执行前允许或拒绝哪些动作、目标和本地 operator | `src/policy/*.zig` |
| ApprovalReceipt | 描述本地审批系统导出的执行凭证 | `src/policy/approval_receipt.zig`、`src/cli/approval_receipt.zig` |
| ModuleHandler | 描述模块支持哪些生命周期和 apply 远程依赖 | `src/modules/handler.zig`、`src/modules/scan_registry.zig`、`src/modules/plan_registry.zig`、`src/modules/apply_support.zig` |
| RemoteOptions | 描述远程执行超时、重试、identity file 和 credential provider | `src/remote/options.zig` |
| TransferPlan | 描述一次文件传输，包括 scp、rsync 和 chunk 计划契约 | `src/remote/transfer_plan.zig`、`src/transfer/*.zig`、`src/transport/*.zig` |
| RollbackManifest | 描述已执行动作如何恢复 | `src/rollback/*.zig` |
| AuditEvent | 描述真实执行事件和 hash chain | `src/audit/*.zig` |

CLI 是用户入口，schema 文件才是跨版本、跨工具和 AI 自动化最应该依赖的接口。

### 2.0 端到端实现链路

一次完整迁移在实现上可以拆成下面这条链路：

```text
旧机器 hostlift scan
  -> inventory scanner 读取 Linux 事实
  -> source-inventory.json

新机器 hostlift scan
  -> inventory scanner 读取 Linux 事实
  -> target-inventory.json

控制机 hostlift plan
  -> plan builder 比较 source/target
  -> plan/modules 生成 action
  -> hostlift-plan.json

控制机 hostlift validate / apply --dry-run
  -> validator 校验 action 形状和风险
  -> policy 检查 plan hash、host、operator、ticket、模块和 action
  -> dry-run 输出可审查动作

控制机 hostlift apply --approve
  -> security 校验 host/path/argv/identity
  -> host_authz 校验 operator/host
  -> modules/apply_support 检查 action 支持
  -> apply/preflight 检查远程依赖
  -> modules/handlers 分发到领域 action
  -> remote/transport 执行 SSH/scp/rsync
  -> handler verify 做执行后校验
  -> audit 写 hash-chain 事件
  -> rollback 写补偿记录
```

这条链路是核心架构约束。任何新增会修改远程主机的能力，都应该进入同一条链路；如果一个功能不能被 dry-run、policy、audit 或 rollback 描述，就不应该直接作为 approved action 执行。

### 2.0.1 为什么不直接让 AI SSH

HostLift 面向 AI 辅助迁移，但不把 AI 当成不受限的远程 shell 使用者。原因是 Linux 主机迁移通常同时涉及账号、权限、服务、cron、防火墙、项目数据和运行时状态，错误命令可能直接导致目标机不可用。

因此 HostLift 让 AI 参与下面这些低副作用环节：

- 读取 inventory，解释旧机器上有什么。
- 读取 plan，判断哪些 action 应分批执行。
- 读取 validate 和 dry-run 输出，指出风险和缺失依赖。
- 读取 audit 和 rollback manifest，辅助复盘。

真实执行仍由 HostLift 完成，并且必须显式 `--approve`。这样 AI 可以给建议，但不能绕过 host/path/argv 校验、policy、审批凭证、主机授权、审计和 rollback。

### 2.1 代码实现主线

一次用户命令进入 HostLift 后，大体会经过下面的代码主线：

```text
main.zig
  -> cli.zig
  -> cli/<command>.zig
  -> options/schema/filter/policy
  -> domain service
  -> remote/transport/audit/rollback adapter
```

具体来说：

- `src/main.zig` 只做进程入口、allocator 初始化和顶层错误返回。
- `src/cli.zig` 做一级命令分发。
- `src/cli/*.zig` 负责每个命令的参数解析、文件读写和输出格式。
- `src/inventory/*`、`src/plan/*`、`src/apply/*`、`src/rollback/*` 承载领域逻辑。
- `src/security/*`、`src/policy/*`、`src/credentials/*` 是执行前边界。
- `src/remote/*` 和 `src/transport/*` 是所有 SSH、scp、rsync 和远程 manifest 的唯一出口。
- `src/audit/*` 和 `src/rollback/*` 保存执行证据。

因此新增功能时要先判断它属于哪一层：如果是用户输入，放在 CLI/options；如果是领域能力，放在 inventory/plan/apply/rollback；如果是外部系统访问，放在 provider/adapter 边界。

以 `hostlift apply --approve` 为例，实际调用链不是 CLI 直接执行 SSH，而是：

```text
src/main.zig
  -> src/cli.zig
  -> src/cli/apply.zig
      -> 读取 plan/policy
      -> plan/filter.zig
      -> plan/validator.zig
      -> policy/action.zig
      -> credentials/source.zig
      -> apply/preflight.zig
      -> apply/executor.zig
          -> modules/apply_support.zig
          -> modules/handlers/<module>.zig
          -> apply/action/<module>.zig
          -> remote/runner.zig 或 transport/runner.zig
          -> audit/log.zig
          -> rollback/codec.zig
```

这个调用链是架构约束：CLI 可以读文件和输出结果，但不应该绕过 `apply/executor`、`remote/transport`、`audit` 和 `rollback` 去直接拼远程命令。

### 2.2 为什么使用文件型协议

HostLift 没有先做中心服务和数据库，而是先把关键状态落到文件，是出于三个考虑：

1. Linux 迁移通常发生在一次性项目或变更窗口内，文件比常驻服务更容易部署。
2. inventory、plan、audit 和 rollback 都需要被人工、AI、工单系统和审计系统独立读取。
3. 文件型协议天然支持 dry-run、离线审查、复盘和回滚。

这些文件同时也是未来 API/TUI/control plane 的数据契约。即使以后增加服务端，服务端也应该复用这些 schema，而不是另起一套内部模型。

### 2.3 命令到代码路径

HostLift 的命令入口和核心实现路径如下。开发时先从 CLI 文件看参数如何变成结构化 options，再进入对应领域模块。

| 用户命令 | CLI 入口 | 领域实现 | 外部副作用出口 |
| --- | --- | --- | --- |
| `scan` | `src/cli/scan.zig` | `src/inventory/scanner.zig`、`src/inventory/scan_runner.zig`、`src/inventory/*.zig` | 本机只读探针 |
| `manifest` | `src/cli/manifest.zig` | `src/manifest/local.zig`、`src/manifest/verify.zig` | 本机文件读取 |
| `plan` | `src/cli/plan.zig` | `src/plan/builder.zig`、`src/plan/modules/*.zig` | 无远程副作用 |
| `validate` | `src/cli/validate.zig` | `src/plan/validator.zig`、`src/policy/*.zig` | 无远程副作用 |
| `apply --dry-run` | `src/cli/apply.zig`、`src/cli/apply_dry_run.zig` | `src/plan/filter.zig`、`src/policy/action.zig` | 无远程副作用 |
| `apply --approve` | `src/cli/apply.zig` | `src/apply/executor.zig`、`src/modules/handlers/*.zig`、`src/apply/action/*.zig` | `src/remote/*`、`src/transport/*`、`src/audit/*`、`src/rollback/*` |
| `transfer` | `src/transfer/command.zig` | `src/transfer/options.zig`、`src/transfer/manifest_flow.zig` | `src/transport/scp.zig`、`src/transport/rsync.zig`、`src/transport/manifest.zig` |
| `remote exec` | `src/cli/remote.zig` | `src/remote/command_plan.zig`、`src/remote/risk.zig` | `src/remote/runner.zig` |
| `rollback` | `src/rollback/command.zig` | `src/rollback/dispatcher.zig`、`src/rollback/schema.zig` | `src/remote/*`、`src/audit/*` |
| `audit verify` | `src/cli/audit.zig` | `src/audit/verify.zig`、`src/audit/verify_event.zig` | 本机文件读取 |
| `audit replay` | `src/cli/audit.zig` | `src/audit/replay.zig`、`src/audit/verify.zig` | `src/audit/replay_sink.zig`、本机 `curl`、本机 `logger` |

这个映射也是职责约束：CLI 不应该直接拼远程 shell；领域模块不应该读取原始 argv；所有 SSH/scp/rsync/curl/logger 子进程都应该从 adapter 层出去。

### 2.4 关键抽象

当前代码里最重要的抽象有六类：

| 抽象 | 解决的问题 | 设计要求 |
| --- | --- | --- |
| `Inventory` | 把一台 Linux 主机的事实保存下来 | 只描述事实，不表达迁移意图 |
| `MigrationPlan.Action` | 把迁移意图变成可审查动作 | action id 稳定，payload 可校验 |
| `ModuleHandler` / registry | 声明模块支持哪些生命周期和远程依赖 | 未声明能力默认拒绝 |
| `RemoteOptions` / `CommandPlan` | 把远程命令变成结构化计划 | argv 数组表达，不散落 shell 字符串 |
| `TransferPlan` | 把文件传输变成结构化计划 | scp/rsync 可执行，chunk 已有 staging 执行 adapter 和索引契约 |
| `AuditEvent` / `RollbackManifest` | 保存执行证据和恢复信息 | approved 执行必须可追踪 |

新增能力时应先判断它属于哪一个抽象。如果一个功能同时修改多个抽象，通常应该拆成 schema、options、handler、adapter 和测试几个小改动，避免把业务判断、远程执行和审计写入混在同一个文件里。

### 2.5 代码设计思路

HostLift 的代码设计遵循“稳定契约在中间，副作用在边界”的思路。

核心契约是 inventory、plan、policy、approval receipt、audit event、rollback manifest、remote command plan 和 transfer plan。这些结构可以落盘，可以被人读，可以被 AI 分析，也可以被测试 fixture 复用。CLI、TUI、API 或未来控制面都应该复用这些契约，而不是各自发明内部格式。

副作用边界集中在少数目录：

- SSH 命令只从 `src/remote/*` 出去。
- 文件传输只从 `src/transport/*` 出去。
- 审计输出只从 `src/audit/*` 出去。
- 凭据来源只从 `src/credentials/*` 解析。
- 主机、路径、argv 和 identity file 校验只从 `src/security/*` 做。
- 防火墙 reload 和恢复窗口只在 `src/firewall/*` 里处理。

领域代码只负责表达“应该迁移什么”和“某个 action 怎么执行”，不直接散落 shell 字符串、私钥路径、审计编码或 rollback 文件格式。

从可维护性角度，HostLift 不追求把一个功能放在一个大文件里做完，而是把同一个功能拆成固定切面：

| 切面 | 典型文件 | 作用 |
| --- | --- | --- |
| CLI/options | `src/cli/*.zig`、`src/*/options.zig` | 把 argv 变成结构化输入 |
| Schema | `src/*/schema.zig` | 定义可落盘契约 |
| Domain | `src/inventory/*`、`src/plan/modules/*`、`src/apply/action/*` | 表达 Linux 迁移语义 |
| Registry | `src/modules/*.zig` | 声明模块生命周期和能力 |
| Boundary adapter | `src/remote/*`、`src/transport/*`、`src/audit/*` | 执行外部副作用 |
| Verification | `src/plan/validator.zig`、`src/manifest/*`、`src/audit/verify*.zig` | 执行前或执行后校验 |
| Recovery | `src/rollback/*` | 记录和执行补偿动作 |

这种拆分会让新增能力涉及多个小文件，但每个文件的职责清晰，便于 review、测试和后续企业能力替换。

## 3. 总体架构

当前源码按职责分层：

```text
CLI 层
  src/main.zig
  src/cli.zig
  src/cli/*.zig

Inventory 清单层
  src/inventory/*.zig
  src/inventory/schema.zig
  src/inventory/module_inventory.zig
  src/inventory/schema_parts/*.zig

Plan 规划层
  src/plan/schema.zig
  src/plan/builder.zig
  src/plan/modules/*.zig
  src/plan/filter.zig
  src/plan/validator.zig

模块契约层
  src/modules/handler.zig
  src/modules/scan_registry.zig
  src/modules/plan_registry.zig
  src/modules/apply_support.zig
  src/modules/registry.zig
  src/modules/handlers/*.zig

Apply 执行层
  src/apply/executor.zig
  src/apply/handler.zig
  src/apply/actions.zig
  src/apply/action/*.zig
  src/apply/backup.zig
  src/apply/permissions.zig

远程和传输边界
  src/remote/*.zig
  src/transport/*.zig
  src/transfer/command.zig
  src/transfer/options.zig
  src/transfer/manifest_flow.zig

安全、凭据和策略边界
  src/security/validation.zig
  src/credentials/source.zig
  src/policy/*.zig
  src/firewall/*.zig

Manifest、审计和回滚
  src/manifest/*.zig
  src/audit/*.zig
  src/rollback/*.zig

输出和工具
  src/util/*.zig
```

依赖方向应保持自上而下：

```text
CLI
  -> inventory / plan / validate / apply / rollback / remote / transfer
  -> modules registry
  -> security / credentials / remote / transport / audit / rollback
  -> util
```

底层模块不应该反向依赖 CLI。CLI 只负责把 argv 解析成结构化 options，业务模块只消费结构化输入。

### 3.1 运行时组件关系

一次 approved apply 的运行时关系如下：

```text
cli/apply
  -> 读取 plan/policy
  -> plan/filter + plan/validator
  -> policy/action
  -> modules/apply_support
  -> apply/executor
      -> modules/handlers/*
          -> apply/action/*
          -> remote/runner 或 transport/runner
      -> audit/log
      -> rollback/manifest
```

其中 `remote/runner` 和 `transport/runner` 是真正启动子进程的位置。其它领域模块只构造结构化请求或调用 adapter，不直接散落 `ssh`、`scp`、`rsync` 拼接逻辑。

### 3.2 兼容门面

部分文件仍保留 facade 作用，例如：

- `src/modules/registry.zig`
- `src/remote/planner.zig`
- `src/remote/exec.zig`
- `src/audit/sink.zig`
- `src/audit/log.zig`
- `src/inventory/schema.zig`

这些文件存在的目的，是让旧调用点和测试继续使用稳定导出，同时把新实现拆到更小的领域文件里。后续重构时应优先保持这些 facade 的公共导出稳定。

### 3.3 目录职责表

| 目录 | 职责 | 设计要求 |
| --- | --- | --- |
| `src/cli` | 命令参数解析、文件读写、用户输出 | 不承载业务决策，不直接拼 SSH |
| `src/inventory` | 采集 Linux 主机事实 | 尽量只读，失败写 warning |
| `src/plan` | 把 source/target 差异转成 action | action id 稳定，payload 可审查 |
| `src/modules` | 声明模块生命周期和 apply 能力 | 未声明能力默认拒绝 |
| `src/apply` | approved apply 编排和 action 执行 | 必须经过 policy、audit、rollback |
| `src/remote` | SSH 命令计划、风险、argv、runner | 远程命令唯一出口 |
| `src/transport` | scp/rsync、远程 manifest 和 chunk index 契约 | 文件传输唯一出口 |
| `src/transfer` | 独立文件传输命令 | 复用 transport，不做业务迁移判断 |
| `src/security` | host/path/argv/identity 校验 | 只做边界校验，不做业务授权 |
| `src/policy` | allow/deny/risk/host/operator/ticket/approval receipt 门禁 | 本地策略和本地审批凭证，不等同 RBAC |
| `src/credentials` | 凭据来源描述 | 不读取、不保存私钥内容 |
| `src/audit` | JSONL 审计和 hash chain | approved 执行必须写入 |
| `src/rollback` | rollback manifest 和恢复执行 | 只恢复已记录副作用 |
| `src/firewall` | 防火墙 backend/reload/recovery | 高风险动作单独隔离 |
| `src/manifest` | 本地文件树 manifest | 支持传输前后校验 |
| `src/util` | 摘要输出和通用工具 | 不依赖业务高层 |

这个表也是代码审查的边界清单。新增代码如果跨了多列职责，通常应该拆成 options、schema、adapter 或 handler。

### 3.4 受控执行路径

所有会修改目标主机的路径都应该满足同一条门禁链路：

```text
CLI 解析
  -> options 校验
  -> security 校验 host/path/argv/identity
  -> policy 检查
  -> registry/apply_support 检查模块能力
  -> remote/transport 构建 argv
  -> approved runner 执行
  -> audit 写事件
  -> rollback 写补偿记录
```

如果某个新功能需要修改远端状态，但不能写入 audit 或不能说明 rollback 策略，就不应该作为默认 approved action 合入。

### 3.5 分层取舍

当前架构优先保证“可审查”和“可控执行”，所以没有把所有逻辑压进一个远程 shell 脚本，也没有把所有能力放进一个巨大的 `apply.zig` 文件。

这样拆分带来的好处是：

- inventory 和 plan 可以离线保存，人工、AI、测试和工单系统都能复用。
- policy、security、registry、preflight、audit 和 rollback 可以在所有模块之间共享。
- SSH、scp、rsync、curl、logger 等外部命令只从 adapter 层出去，便于 fake remote 测试。
- 高风险领域可以独立隔离，例如 firewall、credentials、audit sink 和 rollback。

代价是一个能力通常要改多个文件：schema、plan、validator、registry、handler、action、rollback 和测试。这个代价是有意接受的，因为 Linux 主机迁移是高风险场景，隐式执行和模块间耦合比多几个小文件更危险。

### 3.6 文件长度和模块边界规则

判断一个文件是否应该继续拆分，可以用下面几条规则：

- 文件同时解析 CLI、做业务判断、拼远程命令时，应拆成 options、domain 和 adapter。
- 文件里出现多个后端分支，例如 apt/dnf/pacman 或 nftables/ufw/firewalld，应拆 provider/backend。
- 文件里既写 audit 又执行业务动作，应把 audit 事件适配拆出去。
- 文件里既循环 manifest 又分发 rollback action，应把 dispatcher 拆出去。
- 文件只是 facade 或兼容导出，可以保留较薄的入口，但不应该继续加入新领域类型。

当前 `firewall/*`、`credentials/*`、`audit/*`、`rollback/*`、`remote/*`、`transport/*` 已经按这个方向拆分。`sudoers` 已先按 scan-only 模块拆出 `inventory/sudoers.zig` 和 `schema_parts/sudoers.zig`，ACL 已先按 scan-only 模块拆出 `inventory/acl.zig` 和 `schema_parts/acl.zig`，`storage` 已先按 scan-only 模块拆出 `inventory/storage.zig` 和 `schema_parts/storage.zig`，SELinux/AppArmor 已先按 scan-only 模块拆出 `inventory/security_policy.zig` 和 `schema_parts/security_policy.zig`。这些高风险模块现在按领域拆成独立 plan-only review 文件：`sudoers_review.zig`、`acl_review.zig`、`storage_review.zig`、`security_policy_review.zig` 和 `container_review.zig` 负责生成 `manual_step` 人工审查项，`manual_common.zig` 负责公共构造逻辑，`manual_review.zig` 只保留薄门面和聚合测试；它们都不提供自动 apply/rollback。Docker/Podman 已先在 `inventory/docker.zig` 和 `schema_parts/runtime.zig` 下扩展 scan-only 事实，`docker.zig` 只做聚合入口，runtime 检测、运行中容器、volume/network/image 元数据和 Compose 文件候选路径分别拆到 `docker_runtime.zig`、`docker_containers.zig`、`docker_resources.zig` 和 `docker_compose.zig`；资源记录带 runtime 字段，plan 层按 Docker/Podman 分开比对同名 volume、network、image 和 container。这些事实会通过 `container_review.zig` 生成容器人工审查项，缺失 volume 且能解析 mountpoint 时可生成高风险数据复制动作，但不自动重建 network 或运行中容器状态。后续继续扩展容器 apply 时，也应沿用同样边界。

服务规划侧和执行侧都按 provider 继续拆分：`src/plan/modules/services.zig` 只保留聚合入口，systemd service/timer/socket、用户级 systemd、XDG autostart、SysV init 和 OpenRC 的规划规则分别拆到 `services_systemd.zig`、`services_user_systemd.zig`、`services_xdg.zig`、`services_sysv.zig` 和 `services_openrc.zig`。执行侧 `src/modules/handlers/services.zig` 只保留 services 模块的 apply/verify/rollback 分发和 systemd 轻量逻辑，用户级 systemd `runuser -- systemctl --user enable/is-enabled/disable` 已拆到 `src/modules/handlers/services_user_systemd.zig`，SysV provider 探测、`chkconfig`/`update-rc.d` 命令选择、runlevel verify 和 rollback 后置验证已拆到 `src/modules/handlers/services_sysv.zig`；OpenRC `rc-update add/del`、runlevel 链接 verify 和 rollback 后置验证已拆到 `src/modules/handlers/services_openrc.zig`。rollback dispatcher 不再复制用户级 systemd、SysV 和 OpenRC 验证逻辑，而是复用同一组 helper，避免 plan/apply verify 和 rollback verify 分叉。

## 4. 关键设计原则

### 4.1 先事实，后决策

`scan` 只采集事实，不决定迁移什么。软件包、service、cron、用户、SSH、配置、项目目录和防火墙都先进入 inventory。

`plan` 再根据 source/target inventory 生成 action。这样 inventory 可以被人工、AI、测试和其它工具复用。

### 4.2 计划和执行分离

`plan`、`validate` 和 `apply --dry-run` 不修改远程机器。真实执行必须进入 `apply --approve` 或 `rollback --approve`。

这条分离让迁移过程可以被拆成：

1. 低权限扫描。
2. 离线审查。
3. 审批。
4. 最小范围执行。
5. 审计和回滚。

### 4.3 远程边界集中

领域模块不直接拼 SSH shell 字符串。远程命令走 `src/remote/*`，文件传输走 `src/transport/*`，host/path/argv/identity file 校验走 `src/security/validation.zig`，credential provider 解析、env provider 解析和未支持 provider 的失败关闭走 `src/credentials/source.zig`。

这样可以把安全检查集中在少数边界里，避免每个模块自己实现一套远程调用。

`src/remote/preflight.zig` 负责执行前远程依赖预检。当前 remote exec 会检查 argv[0] 对应命令；transfer 会在 approved 执行前按计划推导目标机和源机器需要的命令，例如 checksum 校验需要 `sha256sum`；approved apply 会通过 `src/apply/preflight.zig` 调用模块 handler 的 `applyRequirements`，按 action 类型和 apply options 声明目标机依赖，例如包安装需要对应包管理器和验证命令，systemd 动作需要 `systemctl`，用户/组动作需要 `useradd`、`groupadd`、`id` 或 `getent`，文件备份和权限修复需要 `mkdir`、`cp`、`chmod`、`chown`，防火墙 reload/recovery 会按 backend 和恢复窗口声明 `grep`、`nft`、`iptables-restore`、`ufw`、`firewall-cmd`、`systemd-run` 等。所有检查都通过结构化 `command -v <cmd>` argv 远程执行。缺失依赖时失败关闭，避免进入主体执行后才失败。

### 4.4 能力声明而不是默认支持

`src/modules/scan_registry.zig`、`src/modules/plan_registry.zig` 和 `src/modules/apply_support.zig` 是能力声明表。模块能 scan，不代表能 apply；能 apply，也不代表能 rollback。`src/modules/registry.zig` 只保留旧调用入口的兼容导出。

未声明支持的生命周期和 action 应该 fail closed，不能静默跳过。

### 4.5 文件型中间产物

inventory、plan、policy、audit log 和 rollback manifest 都是文件。这是为了：

- 方便离线审查。
- 方便 AI 读取结构化上下文。
- 方便把 plan hash 和 policy hash 写进审计。
- 方便迁移失败后复盘。
- 方便用普通日志系统或文本工具处理 JSONL 审计。

### 4.6 可追加兼容

JSON schema 应优先通过可选字段扩展，避免修改已有字段语义。审计校验代码已经兼容历史字段集，例如旧事件没有 `credential_source` 或 `policy_hash` 的情况。

### 4.7 失败关闭

HostLift 处理远程执行时默认失败关闭：

- 未传 `--approve`：只输出计划或 dry-run。
- 未声明 apply 支持：拒绝执行。
- policy 拒绝：拒绝执行。
- host/path/argv 校验失败：拒绝执行。
- audit sink 必须是已实现 adapter：file 写 JSONL，syslog 通过本机 `logger`，HTTPS 通过本机 `curl` POST JSON。
- critical 远程命令未显式允许：拒绝执行。

这样做会牺牲一点便利性，但能避免“工具看起来执行成功，实际绕过了安全边界”的情况。

### 4.8 可测试 adapter

远程执行和文件传输都通过 runner/adapter 进入系统命令。这样 fake remote smoke 可以在不连接真实主机的情况下验证 apply、transfer、rollback 的主路径。后续要做 Docker/Podman 多发行版测试，也应该复用这些边界。

## 5. 核心数据流

从代码实现看，HostLift 的端到端链路可以拆成四个固定阶段：

```text
输入解析
  -> CLI 把 argv 转成 options
  -> security/policy 做边界校验

结构化建模
  -> inventory/plan/schema 承载数据
  -> plan/modules 生成 action
  -> validator 检查 action 形状和风险

受控执行
  -> modules registry 判断生命周期能力
  -> apply executor 分发到 handler
  -> remote/transport adapter 启动 ssh/scp/rsync

执行证据
  -> audit 写 JSONL hash chain
  -> rollback 写 JSONL 补偿记录
  -> manifest/hash 记录文件级证明
```

这个链路的关键点是：业务模块不能绕过 registry、security、remote/transport、audit 和 rollback。任何新增迁移动作都应该进入同一条链路，而不是在 CLI 里直接拼命令。

### 5.0 端到端示例

以“迁移一个 systemd 服务和它的项目目录”为例，代码路径如下：

```text
scan
  -> inventory/services.zig 读取 service 和 timer 启动事实
  -> inventory/projects.zig 识别项目目录
  -> inventory/schema_parts/*.zig 写入 inventory

plan
  -> plan/modules/services.zig 生成 enable/copy unit 动作和运行态人工审查项
  -> plan/modules/projects.zig 生成 copy_data_path 或项目动作
  -> plan/schema.zig 输出 hostlift-plan.json

validate/dry-run
  -> plan/validator.zig 校验 action
  -> policy/action.zig 检查模块、风险和 host
  -> cli/apply_dry_run.zig 输出预览

apply --approve
  -> modules/apply_support.zig 确认 action 支持
  -> modules/handlers/services.zig 或 projects.zig 分发
  -> apply/action/services.zig 或 projects.zig 执行
  -> remote/runner.zig 执行 systemctl
  -> transport/scp.zig 或 rsync.zig 复制目录
  -> audit/log.zig 写审计
  -> rollback/codec.zig 写 rollback manifest
```

这个例子体现了 HostLift 的核心原则：scan 负责事实，plan 负责意图，apply 负责受控执行，remote/transport 是外部副作用出口，audit/rollback 负责证据和恢复。

### 5.1 Scan

入口：

```text
hostlift scan --output source-inventory.json --summary --force
```

主要代码：

- `src/cli/scan.zig`：解析 scan 参数。
- `src/inventory/scanner.zig`：组装完整 inventory。
- `src/inventory/scan_filter.zig`：解析和校验 scan include/exclude 模块过滤。
- `src/inventory/scan_runner.zig`：按 scan registry 调用模块 scanner，并聚合 warning。
- `src/inventory/services.zig`：服务扫描聚合入口，识别 init system，并组合各类启动事实。
- `src/inventory/services_systemd.zig`：扫描 systemd service、systemd timer 和 systemd socket。
- `src/inventory/services_startup.zig`：非 systemd service 启动入口的薄聚合门面。
- `src/inventory/services_user_units.zig`：扫描用户级 systemd unit。
- `src/inventory/services_xdg.zig`：扫描 XDG autostart。
- `src/inventory/services_sysv.zig`：扫描 SysV init 脚本和 runlevel 链接。
- `src/inventory/services_openrc.zig`：扫描 OpenRC service 和 `/etc/runlevels` 链接。
- `src/inventory/dev_env.zig`：开发环境扫描聚合入口。
- `src/inventory/dev_env_tools.zig`：开发工具存在性和版本扫描。
- `src/inventory/dev_env_configs.zig`：系统和用户级开发配置路径扫描。
- `src/inventory/dev_env_proxy.zig`：代理环境变量扫描。
- `src/inventory/*.zig`：各领域探针。
- `src/inventory/schema.zig`：inventory 兼容导出门面和顶层 `Inventory`。
- `src/inventory/module_inventory.zig`：模块清单聚合类型、空模块 fixture 和模块内存释放。
- `src/inventory/schema_parts/*.zig`：host、package、service、user、config、runtime 等领域类型。
- `src/util/inventory_summary.zig`：inventory 摘要兼容入口。
- `src/util/inventory_summary_overview.zig`：主机、包、服务、用户、运行时和防火墙概览。
- `src/util/inventory_summary_details.zig`：摘要详情聚合。
- `src/util/inventory_summary_system.zig`、`inventory_summary_dev.zig`、`inventory_summary_runtime.zig`：system/dev/runtime 详情章节。

扫描模块失败时，不应该让整个 scan 直接崩掉。当前设计会收集 warning，并尽量保留其它模块结果。

scan 的实现重点是“事实采集”，不是“迁移建议”。例如监听端口、进程、Docker/Podman 可用性、Docker 容器、volume/network 元数据、Compose 文件候选路径和服务状态都会进入 inventory，但是否迁移、怎么迁移由 plan 和 policy 决定。

服务扫描分七类，代码上按 provider 拆成 `services_systemd.zig`、`services_user_units.zig`、`services_xdg.zig`、`services_sysv.zig` 和 `services_openrc.zig`，`services.zig` 只保留聚合逻辑：

- systemd service：通过 `systemctl list-unit-files --type=service` 获取 unit 名称和 unit-file 启用状态，通过 `systemctl list-units --type=service --all` 获取 active/reloading/activating/inactive/failed 等运行态，并检查 `/etc/systemd/system/<unit>` 是否为自定义 unit。
- systemd timer：通过 `systemctl list-timers --all` 获取 timer、被激活 unit 和 schedule 摘要，通过 `systemctl list-unit-files --type=timer` 补充 enabled/static/disabled 状态，并检查自定义 timer 路径。
- systemd socket：通过 `systemctl list-unit-files --type=socket` 获取 socket 名称和状态，通过 `systemctl list-sockets --all` 尽量补充被激活 unit，并检查自定义 socket 路径。
- 用户级 systemd unit：从可登录用户和 root 的 `~/.config/systemd/user` 目录中只读枚举 `.service`、`.timer`、`.socket` 文件，记录用户、文件名、路径、类型和 `default.target.wants/<unit>` enabled 状态。
- XDG autostart：只读枚举 `/etc/xdg/autostart` 和 root/非系统用户 `~/.config/autostart` 下的 `.desktop` 文件，记录作用域、用户、文件名和路径。
- SysV init：只读枚举 `/etc/init.d` 脚本名和路径，再扫描 `/etc/rc*.d/S*` 链接推断是否启用和 runlevel 摘要。
- OpenRC：检测 `/etc/runlevels` 后只读枚举 `/etc/init.d` service 名和路径，再扫描 `/etc/runlevels/*/<service>` 链接推断是否启用和 runlevel 摘要；runlevel 名会排序后写入 inventory，保证 plan 等价判断稳定。

用户级 systemd unit、系统级 socket/timer、XDG autostart、SysV init 和 OpenRC 都不读取正文。这样可以发现 systemd service 运行态、定时启动、socket activation、用户会话自启动项、桌面登录自启动项、传统 runlevel 启动脚本和 OpenRC runlevel service，但避免把 `ExecStart`、环境变量、命令参数、`.desktop` 或 init 脚本正文中的敏感内容写入 inventory。plan 阶段会对源端 active/reloading/activating 而目标端不是 active-like 的 systemd service 生成 `services/review-runtime/<unit>` high-risk `manual_step`，提醒人工决定是否在目标机启动或重启服务；它不会自动生成 `systemctl start/restart`。plan 阶段还会对自定义且目标缺失的 systemd timer/socket 生成 `install_systemd_unit` 动作，对 enabled timer/socket 生成 `enable_systemd_unit` 动作；这两类动作复用现有 systemd unit 安装、`systemctl enable`、`systemctl is-enabled` verify 和 enable rollback。目标缺失的用户级 systemd unit 会生成 `copy_home_config` 文件型 action，并把 `owner` 设为对应用户；enabled 用户级 systemd unit 会生成 `enable_user_systemd_unit`，subject 使用 `<user>:<unit>`，执行侧由 `src/modules/handlers/services_user_systemd.zig` 统一处理，通过 `runuser -u <user> -- systemctl --user enable <unit>` 启用，通过 `runuser -u <user> -- systemctl --user is-enabled <unit>` 验证，rollback 通过同一用户上下文执行 `disable`，rollback 后置验证确认 `is-enabled` 失败。目标缺失的 XDG autostart 也会生成文件型 action：系统级 `.desktop` 走 `write_file`，用户级 `.desktop` 走 `copy_home_config`。目标缺失的 SysV/OpenRC `/etc/init.d` 脚本会生成 `write_file` 文件型 action，services handler 委托文件传输 handler 复用备份、传输、checksum/存在性 verify 和文件型 rollback。SysV init 会按 runlevel diff 生成 `enable_sysv_init` 和 `disable_sysv_init`：subject 使用 `<service>:2,3,5`，preflight 用 provider group 表达 `chkconfig` 或 `update-rc.d` 至少存在一个，执行侧由 `src/modules/handlers/services_sysv.zig` 统一探测 provider，优先选择 `chkconfig`，否则选择 `update-rc.d`；`chkconfig` provider 把逗号 runlevel 规范化成 `chkconfig --level 235 <service> on/off`，并通过 `chkconfig --list <service>` 验证；`update-rc.d` provider 生成 `update-rc.d <service> enable/disable 2 3 5`，并通过 `/etc/rcN.d` 下的 `S??<service>` 链接验证；rollback 写入反向 enable/disable 动作，rollback 后置验证复用同一个 SysV helper。OpenRC service 会按 runlevel diff 生成 `enable_openrc_service` 和 `disable_openrc_service`，执行侧由 `src/modules/handlers/services_openrc.zig` 统一处理：前者逐个 runlevel 执行 `rc-update add` 并在 rollback 时 `del`，后者逐个 runlevel 执行 `rc-update del` 并在 rollback 时 `add`；verify 和 rollback 后置验证都检查 `/etc/runlevels/<runlevel>/<service>` 存在或缺失。用户级 systemd enable、SysV runlevel 收敛和 OpenRC runlevel 收敛都不会自动 `start/stop/restart`；用户级 systemd 不会自动调用 `loginctl enable-linger`。其它缺失或不等价的 systemd timer、systemd socket、XDG autostart 和需要发行版语义判断的启动差异会转成 services 模块的 high-risk `manual_step` 人工审查项；这些 action 可被 include/exclude 过滤，但不会进入自动 apply。后续如果要继续自动迁移这些入口，应新增内容校验、目标用户存在性检查、`systemctl start/status`、`systemctl --user start/status`、linger/autostart/runlevel/OpenRC provider 禁用语义处理和 rollback，而不是直接把 scan 结果当成可执行动作。

### 5.2 Plan

入口：

```text
hostlift plan --source source.json --target target.json --output plan.json --summary
```

主要代码：

- `src/cli/plan.zig`：解析 plan 参数和过滤选项。
- `src/plan/builder.zig`：整体计划构建。
- `src/plan/compatibility.zig`：源/目标兼容性检查。
- `src/plan/modules/*.zig`：按领域生成 action。
- `src/plan/filter.zig`：过滤器结构和 plan action 裁剪。
- `src/plan/filter_match.zig`：模块名解析、action pattern 校验和匹配规则。
- `src/plan/hash.zig`：plan 输入 hash。

Plan 阶段只生成结构化 action，不连接远程机器。

plan 的输出应该满足两个要求：

- 稳定：action id 可以用于 `--include-action` 和 `--exclude-action`。
- 可审查：payload 里保存执行所需的路径、服务名、包名等上下文，方便人工或 AI 判断风险。

### 5.3 Validate

入口：

```text
hostlift validate --plan plan.json --policy policy.json --summary
```

主要代码：

- `src/cli/validate.zig`：读取 plan 和 policy。
- `src/plan/validator.zig`：schema、action shape、风险和确认要求。
- `src/policy/action.zig`：策略评估。
- `src/policy/approval.zig`：审批票据存在性、精确值和前缀规则。
- `src/policy/approval_receipt.zig`：本地审批凭证 schema 和上下文绑定校验。
- `src/policy/plan_hash.zig`：plan SHA-256 allow/deny 规则。
- `src/policy/ruleset.zig`：policy schema、RuleSet 校验和子规则派生。
- `src/policy/source.zig`：策略文件读取和 hash。
- `src/policy/match.zig`：模块、action、risk、host 匹配逻辑。

Validate 阶段用于在执行前发现非法 action、高风险 action 和 policy 拒绝。当前 `src/plan/validator.zig` 的硬约束包括：schema version 必须匹配，兼容性检查必须通过，action id 和 description 不能为空，critical action 必须要求确认，`manual_step` 必须是 high/critical 风险并且必须要求确认。medium/high action 如果没有确认要求会产生 warning，用于提醒后续模块继续收紧风险建模。

validate 不应该产生副作用。它的职责是把“计划能不能被执行”提前暴露出来，而不是等到 SSH 到目标机后才失败。

### 5.4 Apply

入口：

```text
hostlift apply --plan plan.json --host root@NEW --source-host root@OLD --approve
```

主要代码：

- `src/cli/apply.zig`：approved apply 和 dry-run 顶层编排。
- `src/cli/apply_audit.zig`：apply action 审计上下文和事件写入。
- `src/cli/apply_options.zig`：解析 apply options。
- `src/cli/common_options.zig`：复用 apply/rollback 的 operator、审批、审计、host-authz 和远程执行元数据解析。
- `src/cli/apply_policy.zig`：apply/dry-run policy 评估和摘要输出。
- `src/cli/apply_dry_run.zig`：dry-run action 预览输出。
- `src/apply/executor.zig`：执行编排。
- `src/apply/preflight.zig`：按 action 类型声明 approved apply 的远程命令依赖。
- `src/apply/preflight_tests.zig`：覆盖 apply preflight 的包、服务、用户、文件备份和 SysV/OpenRC provider 依赖推导。
- `src/modules/scan_registry.zig`：扫描模块注册。
- `src/modules/plan_registry.zig`：迁移模块生命周期注册。
- `src/modules/apply_support.zig`：approved apply action 支持判断。
- `src/modules/registry.zig`：兼容导出门面。
- `src/modules/handlers/*.zig`：模块级执行适配。
- `src/apply/action/*.zig`：具体 action 执行逻辑。
- `src/apply/backup.zig`：覆盖前备份。
- `src/apply/rollback_entries.zig`：不需要文件备份的命令型 rollback entry 写入。
- `src/remote/*.zig`：远程命令执行。
- `src/transport/*.zig`：文件复制和远程 manifest。
- `src/audit/*.zig`：审计日志。
- `src/rollback/*.zig`：rollback manifest。

Apply 执行前会处理：

1. `--approve` 检查。
2. plan 读取和基础校验。
3. include/exclude 过滤。
4. policy 检查。
5. host/path/argv/identity file 校验。
6. registry 能力检查。
7. action 级远程依赖预检。
8. audit sink 初始化。
9. rollback manifest 初始化。

Apply 执行中每个 action 的推荐顺序是：

```text
检查 registry 支持
  -> 检查 policy
  -> 远程依赖预检
  -> dry-run 输出或 approved 执行
  -> 执行前准备备份
  -> remote/transport 执行
  -> module verify 校验执行结果
  -> 记录 rollback manifest
  -> 写 audit event
```

如果 action 不可回滚，也应在审计和摘要中暴露风险，不能假装有完整恢复能力。

`src/apply/executor.zig` 会在 handler apply 成功后调用对应模块的 `verify`。当前验证覆盖包括：包安装后的包管理器查询，系统级 systemd enable 后的 `systemctl is-enabled`，用户级 systemd enable 后的 `runuser -u <user> -- systemctl --user is-enabled <unit>`，用户创建后的 `getent passwd` 字段校验，文件型 action 的目标路径存在性，远程源到远程目标的单文件 SHA-256 比对，Docker Compose start 后的 `docker compose ps`。用户验证不只检查 `id <user>` 是否成功，还会比对 plan 中的 UID、GID、home 和 shell，避免迁移后账号存在但关键属性漂移。

### 5.5 Transfer

入口：

```text
hostlift transfer --host root@NEW --source /srv/app --target /srv/app --recursive --approve
```

主要代码：

- `src/transfer/command.zig`：CLI 命令实现。
- `src/transfer/options.zig`：transfer argv 解析、默认值和传输后端解析。
- `src/transfer/manifest_flow.zig`：source manifest 需求判断、manifest 选项约束、本地/远程源 manifest 构建、manifest 输出和远程校验编排。
- `src/transport/scp.zig`：scp adapter。
- `src/transport/rsync.zig`：rsync adapter。
- `src/transport/chunk.zig`：chunk 执行编排，按 manifest/index diff 上传缺失或变更文件到 staging，再用远端 rsync 合并落盘。
- `src/transport/chunk_paths.zig`：chunk staging 路径拼接和相对路径安全校验。
- `src/transport/chunk_upload.zig`：chunk scp 上传 argv 构造。
- `src/transport/runner.zig`：子进程执行封装。
- `src/transport/manifest.zig`：远程 manifest 构建。
- `src/transport/remote_probe.zig`：远程 `find/stat/sha256sum` 探针。
- `src/transport/chunk_index.zig`：chunk 传输索引契约，当前从 manifest 生成文件到 chunk 的第一版映射，并提供区分 missing、changed、extra 的 index diff 逻辑。

Transfer 是完整迁移之外的定点能力，适合按 `host + source path + target path` 直接传文件。

transfer 的执行顺序是：

```text
解析 options
  -> 校验 manifest 约束
  -> 构建 TransferPlan
  -> 按需构建本地或远程 source manifest
  -> 按需写出 source manifest
  -> 未批准时只输出 JSON plan
  -> approved 后按 transport 分发
  -> 按需构建远程 target manifest 并校验
```

这个顺序把“是否需要 manifest、是否允许远程源 manifest、是否允许远程校验”集中在 `transfer/manifest_flow.zig`，让 `transfer/command.zig` 只保留命令编排和后端分发。

当前 `scp`、`rsync` 和 `chunk` 都是可执行后端。`chunk` 已经进入 CLI 参数、`TransferPlan.transport`、`TransferPlan.chunk_size_bytes`、`transport/chunk_index.zig` 和 `transport/chunk.zig`。chunk approved 执行会创建目标机 staging 目录，构建本地源 manifest 和远程目标 manifest，使用 `chunk_index.diffIndexes` 区分目标缺失、内容变更和目标多余 chunk，然后只通过 `scp` 上传 missing+changed 对应的源文件，再用远端 `rsync -a` 合并到目标路径；它复用 timeout/retry、identity file、operation id、cancel file 和 operation state。当前 chunk 仍是整文件 chunk，不做目标多余文件删除，也还没有字节块级强断点续传。

远程到远程传输当前仍由控制机发起，使用 `source-host` 和 `host` 组合表达。后续如果支持 P2P 或 agent 模式，应新增 transport adapter，不应改变现有 transfer plan 语义。

### 5.6 Remote Exec

入口：

```text
hostlift remote exec --host root@NEW --approve -- systemctl status nginx
```

主要代码：

- `src/cli/remote.zig`：CLI 入口。
- `src/remote/planner.zig`：兼容门面，继续导出旧调用入口。
- `src/remote/command_plan.zig`：远程命令计划构建。
- `src/remote/transfer_plan.zig`：文件传输计划构建。
- `src/remote/risk.zig`：命令风险分级。
- `src/remote/session.zig`：operation id、本地 cancel file、operation state file 和子进程尝试上下文。
- `src/remote/operation_state.zig`：本地 JSONL 远程操作状态事件，记录 started/succeeded/failed/cancelled。
- `src/remote/package_manager.zig`：远端包管理器探测，供 rollback 执行和 rollback 后置验证复用。
- `src/remote/schema.zig`：远程命令计划结构。
- `src/remote/ssh_argv.zig`：SSH argv 前缀构建。
- `src/remote/runner.zig`：带 timeout/retry 的子进程执行。
- `src/remote/probe.zig`：远程路径和短命令状态探针。
- `src/remote/exec.zig`：兼容执行门面。
- `src/remote/options.zig`：timeout、retry、identity file。

Remote exec 使用 argv 数组表达命令，不鼓励把复杂 shell 拼接成一条字符串。

Remote exec 的第一版 session/cancel 模型是轻量级的本地控制边界：

- `operation_id`：写入 `CommandPlan`/`TransferPlan`，并进入重试日志和可选 operation state，方便工单、AI 控制器或后续 API/TUI 关联一次远程操作。
- `cancel_file`：控制机本地绝对路径。approved 执行前和每次 retry 前检查，文件存在则返回 `RemoteOperationCancelled`。
- `operation_state_file`：控制机本地绝对路径。每次远程命令或传输尝试会追加一条 `hostlift.remote.operation_state.v1` JSONL 事件，记录 operation id、kind、attempt、retries、status 和错误名。
- apply、rollback 和 transfer 也复用同一组 `ExecutionOptions` 字段；内部 SSH/scp/rsync/远程校验调用会继承 operation/cancel/state 元数据。
- `remote/runner.zig` 和 `transport/runner.zig` 都通过 `remote/session.zig` 的 `Control` 检查取消并生成 retry attempt 上下文，同时通过 `remote/operation_state.zig` 追加本地状态事件，避免远程命令和文件传输各自实现一套取消/状态语义。
- operation state 不记录 argv、host、identity file、credential provider ref 或 secret。该模型不杀掉已经启动的远端进程，也不是连接池。后续要做真正 session manager 时，应复用 `remote/session.zig` 的校验和状态边界。

风险分类由 `remote/risk.zig` 完成。普通状态查询可以直接计划或执行，高风险/critical 命令需要更明确的批准参数。这个机制不是完整沙箱，但能阻止最常见的误执行路径。

### 5.7 Rollback

入口：

```text
hostlift rollback --manifest rollback.jsonl --host root@NEW --approve
```

主要代码：

- `src/rollback/options.zig`：rollback 参数解析。
- `src/rollback/command.zig`：rollback 编排。
- `src/rollback/dispatcher.zig`：rollback action id 到模块 handler 的分发。
- `src/rollback/schema.zig`：rollback entry schema 和校验。
- `src/rollback/schema_tests.zig`：rollback entry 契约测试。
- `src/rollback/codec.zig`：rollback JSONL 写入。
- `src/rollback/manifest.zig`：兼容导出门面。
- `src/modules/handlers/rollback.zig`：模块级 rollback 分发。
- `src/audit/*.zig`：rollback 审计事件。

Rollback 当前覆盖文件型备份恢复，以及包安装、用户/组创建、系统级和用户级 systemd enable、Docker Compose up 的部分命令型恢复。`src/rollback/dispatcher.zig` 会在 rollback handler 返回 restored 后执行后置验证：文件型 entry 检查 original path 是否存在，包安装回滚会先通过 `src/remote/package_manager.zig` 探测远端包管理器，再复用 `src/apply/action/package_provider.zig` 生成 `dpkg-query -W`、`rpm -q` 或 `pacman -Q` 验证命令，用户/组创建回滚检查 `getent passwd/group` 失败，系统级 systemd enable 回滚检查 `systemctl is-enabled` 失败，用户级 systemd enable 回滚检查 `runuser -u <user> -- systemctl --user is-enabled <unit>` 失败。后置验证失败会让 rollback 命令失败，并写入 failed 审计事件。

rollback manifest 不应该被理解为整机恢复方案。它是 HostLift 已执行 action 的补偿记录，适合和云快照、磁盘快照、数据库备份一起使用。

### 5.8 Audit

入口：

```text
hostlift audit verify --log audit.jsonl --summary
hostlift audit replay --log audit.jsonl --audit-sink file:replayed.jsonl --summary
```

主要代码：

- `src/audit/event.zig`：审计事件 schema、phase、result 和 credential source 类型。
- `src/audit/chain.zig`：hash chain 状态和事件 hash 兼容计算。
- `src/audit/action_event.zig`：apply action 审计事件适配。
- `src/audit/rollback_event.zig`：rollback entry 审计事件适配。
- `src/audit/log.zig`：兼容写入门面。
- `src/audit/codec.zig`：规范 JSON 编码和 hash 输入。
- `src/audit/sink.zig`：兼容导出门面。
- `src/audit/sink_target.zig`：`file:`、`https://`、`syslog:` target 解析。
- `src/audit/sink_plan.zig`：把 target 转成可测试的 sink 执行计划，并集中处理未实现 sink 的失败关闭。
- `src/audit/combined_sink.zig`：统一 file/syslog/HTTP sink 的 open/write/flush/tailHash 接口。
- `src/audit/file_sink.zig`：本地 JSONL 文件写入。
- `src/audit/http_sink.zig`：通过本机 `curl` argv 向 HTTPS endpoint POST JSON。
- `src/audit/syslog_sink.zig`：通过本机 `logger` argv 写 syslog。
- `src/audit/mirror_sink.zig`：把 syslog/HTTPS 主 sink 和本地 file sink 组合成双写 sink。
- `src/audit/writer_sink.zig`：任意 writer 的链式审计写入。
- `src/audit/verify.zig`：JSONL 聚合校验。
- `src/audit/verify_event.zig`：单事件字段集和 hash 校验。
- `src/audit/replay.zig`：先校验 JSONL hash chain，再把原始审计行重放到指定 sink。
- `src/audit/replay_sink.zig`：file/syslog/HTTPS replay sink adapter，隔离本机文件写入、`curl` 和 `logger` 子进程调用。

当前可执行 sink 是本地文件、本机 syslog 和 HTTPS endpoint。file sink 写 JSONL 文件；syslog sink 复用同一条 hash chain 编码，然后通过结构化 argv 调用 `logger -p <facility>.info -t hostlift -- <json>`；HTTP sink 通过结构化 argv 调用 `curl --fail-with-body --silent --show-error --max-time 10 -X POST -H 'Content-Type: application/json' --data-binary <json> <endpoint>`。这些 adapter 都在 `combined_sink` 后面统一暴露给 apply/rollback。

approved apply/rollback 还支持 `--audit-mirror-log <path>`。它只能和 syslog/HTTPS sink 搭配，不能和 file sink 同用。实现上 `combined_sink` 会把主 sink 包成 `mirror_sink.MirroredSink`，主 sink 和本地 file sink 各自维护同一输入序列下的 hash chain；任一写入或 flush 失败都会向上返回错误。这样既保留主 sink 的失败关闭语义，又给外部审计系统异常后的本地 `audit verify` 和 `audit replay` 留下证据。

`audit replay` 不重新编码事件，也不重新计算 hash；它保留原始 JSONL 行，适合在本地文件审计已经完成后补发到另一个 sink。replay 会在打开输出 sink 前先完整校验输入日志，file sink 还会拒绝输出路径等于输入路径，避免截断原始审计。

HTTP sink 目前是直接逐事件发送，`audit replay` 也只是逐行补发，`--audit-mirror-log` 是本地证据镜像而不是后台重试队列。当前仍不提供可靠离线队列、签名、外部时间戳锚定、mTLS 或凭据绑定。后续真正 SIEM adapter 应继续替换 `combined_sink` 或新增专用 replay queue provider，而不是把集中 sink 判断散落在 apply/rollback/audit 命令里。

## 6. 数据模型

### 6.1 Inventory

Inventory 是“主机事实”，不表达迁移意图。

典型字段包括：

- host、distro、kernel、arch。
- package manager、explicit packages、held packages。
- services。
- users、groups。
- cron。
- ssh。
- configs。
- home configs。
- projects。
- appdata。
- processes、ports、docker。
- firewall。
- scan warnings。

Inventory schema 的设计原则：

- 字段尽量描述事实，不描述操作。
- 模块私有细节放在对应结构里，不让 plan/apply 反向猜测文本输出。
- 新字段优先可选，避免破坏旧 inventory。
- 扫描失败写 warning，尽量保留已采集事实。

### 6.2 MigrationPlan

MigrationPlan 是 plan、validate、apply、policy 和 audit 的共同语言。

Action 一般包含：

- `id`：稳定 action id，支持前缀过滤。
- `module`：模块名，例如 `packages`、`services`。
- `type`：动作类型。
- `risk`：风险等级。
- `requires_confirmation`：是否需要确认。
- `payload`：模块私有参数。

Action id 和 type 一旦被用户依赖，就应视为外部契约。新增能力优先添加新 action 或可选字段，不要随意改变旧 action 语义。

Plan schema 的设计原则：

- action id 稳定且可前缀过滤。
- module/type/risk/requires_confirmation 明确。
- payload 保持模块私有，但必须能被 validator 和 handler 校验。
- plan hash 用于审计关联，避免执行时无法证明使用的是哪份计划。

### 6.3 Policy

Policy 当前是本地 JSON 文件。它不是认证系统，而是执行前门禁。

支持的约束包括：

- default allow/deny。
- allow/deny modules。
- allow/deny action prefixes。
- allow/deny hosts。
- allow/deny plan hashes。
- allow/deny operators。
- max risk。
- require approval ticket。
- allow/deny approval ticket exact values and prefixes。
- approval scopes：把 ticket 或 ticket prefix 绑定到 host、operator、modules、action prefixes 和 max risk。

Policy 文件原始内容会计算 SHA-256，并写入 approved apply/rollback 审计事件。

Policy 目前在本地执行前评估。`allow_plan_hashes` / `deny_plan_hashes` 用来把策略绑定到已经审查过的 plan 文件 SHA-256，`allow_operators` / `deny_operators` 只匹配 `--operator` 或进程环境推断出的 operator 字符串；deny 优先于 allow。`approval_scopes` 是本地审批范围约束，approved apply 会逐 action 检查 ticket scope，approved rollback 因为没有 plan action 上下文，只能使用 host/operator/ticket 级 scope。`--approval-receipt` 可以额外读取本地审批凭证 JSON，校验 ticket、operator、host、purpose、过期时间；apply 还会校验 plan hash。receipt 如果带 `signature`，`--approval-receipt-key-env` 必须提供本地 HMAC-SHA256 密钥环境变量名，并用规范 payload 校验签名。它可以减少误操作面，但不认证真实用户身份，也不替代企业 RBAC 或在线审批系统。企业版本可以把 policy/receipt 来源升级为签名文件、HTTP policy 服务或工单系统返回的审批结果，但 apply 层看到的仍应是结构化 policy contract。

### 6.4 AuditEvent

AuditEvent 用 JSONL 追加写入。每条事件包含：

- 操作人。
- 审批票据。
- 目标 host。
- 模块和 action。
- started/succeeded/failed。
- plan hash。
- policy hash。
- credential source。
- rollback manifest。
- previous event hash。
- current event hash。

hash chain 可以发现中间行被删除、篡改或重排。

AuditEvent 的兼容策略是“读旧写新”：新版本写完整字段，校验器仍能识别缺少 `credential_source` 或 `policy_hash` 的旧事件。

### 6.5 RollbackManifest

Rollback manifest 也是 JSONL。它记录 approved apply 已经产生的可恢复副作用。

文件型变更通常包含：

- 目标路径。
- 备份路径。
- 文件类型。
- 权限信息。
- action 关联信息。

命令型 rollback 只覆盖当前明确支持的保守恢复动作。

RollbackManifest 的设计原则：

- 只记录已发生的副作用。
- 尽量把恢复命令和备份路径具体化。
- 不能恢复的副作用应显式标记或在 action 风险中体现。
- 回滚本身也必须 approved、policy 检查和审计。

当前实现把 rollback manifest 拆成多层：`schema.zig` 定义契约和校验规则，`schema_tests.zig` 承载契约测试，`codec.zig` 负责 JSONL 写入，`manifest.zig` 保留旧导出入口。后续新增非文件副作用 rollback 时，应先扩展 schema/validator，再接入模块 handler。

rollback 执行分发已经拆到 `dispatcher.zig`。`command.zig` 保留命令入口、policy、audit 和逐行 manifest 循环，dispatcher 只负责根据 action id 找模块并调用 rollback handler。

### 6.6 TransferPlan 和 CommandPlan

`TransferPlan` 和 `CommandPlan` 是独立远程能力的结构化表达。

`CommandPlan` 主要用于：

- `remote exec` 输出远程命令计划。
- approved apply 内部执行 SSH 命令。
- rollback 执行恢复命令。

`TransferPlan` 主要用于：

- `transfer` 命令输出传输计划。
- approved apply 内部迁移项目目录或应用数据。
- 递归传输前后 manifest 校验。

`TransferPlan` 还保存传输后端和可靠性选项：

- `transport`：当前支持 `scp`、`rsync` 和 `chunk`。三者都可以 approved 执行；chunk 当前是 staging+远端 rsync 的第一版 adapter。
- `partial`：只允许 rsync 使用，对应 rsync `--partial`。
- `resumable`：只允许 rsync 使用，对应 rsync `--append-verify`，并会自动让 `partial=true`。
- `bandwidth_limit_kbps`：可选传输限速，统一用 Kbit/s 表达。
- `chunk_size_bytes`：只在 `transport=chunk` 时写入，当前默认 8 MiB，用来稳定后续 chunk index 和缺块上传契约。

`scp + partial`、`scp + resumable`、当前尚未支持的 `source_host + rsync`、`source_host + chunk` 和非递归 `chunk` 都会在 `remote/transfer_plan.zig` 中失败关闭。这样 CLI、apply handler 和测试都复用同一套传输能力判断，不会在不同入口出现行为差异。

两个 plan 都支持 `operation_id`、`cancel_file` 和 `operation_state_file`。这些字段是为工单系统、AI 控制器、脚本化批次和后续 session manager 预留的轻量控制接口。当前语义是本地状态记录和本地取消标记，不是远程进程管理。

### 6.7 错误处理和返回语义

当前 CLI 使用 Zig error 返回失败原因，主入口把错误打印给调用方。设计要求是：

- 用户输入错误应尽早在 CLI 或 security 边界失败。
- plan/policy/schema 错误应在 validate 或 apply 前置阶段失败。
- 远程命令失败应携带子进程退出信息。
- 审计写入失败不能静默忽略；approved 执行需要可追踪。
- dry-run 不应该触发远程副作用。

后续如果增加 API 服务层，应把这些错误映射成稳定错误码，而不是把内部 Zig error 名直接暴露给外部客户端。

### 6.8 兼容性策略

HostLift 的数据契约按“追加优先”演进：

- 新字段优先做 optional。
- 老字段不改变含义。
- action id 和 action type 一旦被用户依赖，应视为外部契约。
- 审计校验器需要读旧写新。
- facade 文件保留旧导出，内部实现逐步拆分。

这样可以让旧 inventory、旧 plan、旧 audit log 在新版本中继续被读取和验证。

## 7. 模块生命周期设计

模块生命周期分为：

```text
scan -> plan -> apply -> verify -> rollback
```

不是每个模块都必须支持所有生命周期。当前 registry 的价值是把能力显式声明出来：

- scan-only 模块可以只提供观察能力，也可以先升级为 plan-only 的 `manual_step` 人工审查项。
- plan 模块可以先生成建议动作。
- apply 模块必须明确声明自己支持哪些 action。
- verify 模块负责执行后校验。
- rollback 模块负责恢复已执行副作用。

新增模块时建议按下面顺序落地：

1. 增加 inventory schema 和 scan 探针。
2. 增加 plan action 生成。
3. 在 validator 中校验 action shape。
4. 在 registry 中声明 apply 能力。
5. 通过 remote/transport 实现执行。
6. 增加 verify。
7. 增加 rollback manifest 和 rollback handler。
8. 增加 audit 字段或事件时保持历史兼容。

### 7.1 模块文件拆分建议

一个成熟模块建议拆成下面几类文件：

```text
inventory/<module>.zig        采集事实
plan/modules/<module>.zig     生成 action
apply/action/<module>.zig     执行具体 action
modules/handlers/<module>.zig 模块级分发
rollback/<module>.zig         可选，恢复逻辑
```

如果模块需要外部系统，例如防火墙、Docker、包管理器或 systemd，应再增加 backend/provider 文件，把发行版差异和命令差异隔离出去。

### 7.1.1 高风险模块隔离原则

用户、sudoers、ACL、防火墙、存储、systemd、Docker/Podman、SELinux/AppArmor 都属于高风险模块。它们不要和普通文件复制逻辑混在一起，应分别拆成独立文件或 provider。

推荐隔离方式：

| 能力 | 推荐位置 | 隔离原因 |
| --- | --- | --- |
| 用户和组 | `src/inventory/users.zig`、`src/plan/modules/users.zig`、`src/apply/action/users.zig` | 涉及 UID/GID、登录能力和权限边界 |
| sudoers | 已有 `src/inventory/sudoers.zig` 和 `src/inventory/schema_parts/sudoers.zig` 做只读事实扫描，`src/plan/modules/sudoers_review.zig` 会生成 `manual_step` 审查项；后续再补自动 apply | 语法错误会导致权限恢复困难，需要单独 validate、`visudo -c` 和 rollback |
| ACL | 已有 `src/inventory/acl.zig` 和 `src/inventory/schema_parts/acl.zig` 做只读事实扫描，`src/plan/modules/acl_review.zig` 会生成 `manual_step` 审查项；后续再补 apply/rollback | 扩展权限不能当成普通 mode 位复制，需要 setfacl 验证和 rollback |
| 防火墙 | `src/firewall/*`、`src/plan/modules/firewall.zig` | reload 可能切断 SSH，需要恢复窗口和端口检查 |
| systemd 服务、timer 和 socket | `src/inventory/services.zig`、`src/inventory/services_systemd.zig`、`src/plan/modules/services_systemd.zig`、`src/apply/action/services.zig`；service 运行态差异生成 high-risk `manual_step`，custom timer/socket 缺失时可安装 unit，enabled timer/socket 可生成 enable 动作，并复用 systemd unit verify/rollback；复杂 timer/socket 差异仍生成 `manual_step` 审查项 | enable/start/restart 和 socket activation 会改变运行时状态；复杂 timer/socket 语义还需要独立 verify/rollback |
| 用户级 systemd unit | 当前由 `src/inventory/services_user_units.zig` 做只读扫描，记录 `~/.config/systemd/user` 下的 service/timer/socket 元数据；`src/plan/modules/services_user_systemd.zig` 会为目标缺失的 unit 文件生成 `copy_home_config`，由 services handler 委托文件传输 handler 执行备份、复制、权限修复、verify 和 rollback；enabled unit 会生成 `enable_user_systemd_unit`，`src/modules/handlers/services_user_systemd.zig` 通过 `runuser` 执行 `systemctl --user enable/is-enabled/disable` 并写命令型 rollback entry，同时提供 rollback 后置验证 | 文件复制和 enable 状态可以受控自动化；用户会话 `start/status`、linger、环境变量和启动命令仍需要独立 provider、深度 verify 和 rollback |
| XDG autostart | 当前由 `src/inventory/services_xdg.zig` 做 scan-only，记录系统级和用户级 `.desktop` 文件元数据；`src/plan/modules/services_xdg.zig` 会为目标缺失项生成文件型 action，系统级走 `write_file`，用户级走 `copy_home_config`，并由 services handler 委托到文件传输 handler；复杂差异仍生成 `manual_step` | `.desktop` 可包含命令、环境变量和桌面会话条件，复杂自动迁移前需要内容解析、禁用语义和 rollback |
| SysV init | 当前由 `src/inventory/services_sysv.zig` 做只读扫描，记录 `/etc/init.d` 脚本和 `/etc/rc*.d/S*` runlevel 链接摘要；`src/plan/modules/services_sysv.zig` 会为目标缺失脚本生成 `write_file` 文件型 action，并用 `enable_sysv_init`/`disable_sysv_init` 收敛源/目标 runlevel 差异；`src/modules/handlers/services_sysv.zig` 通过 `chkconfig` 或 `update-rc.d` provider 完成 enable/disable、verify 和 rollback 后置验证 | 文件本体和 runlevel add/del 可以受控自动化；init 脚本可能包含任意 shell，start/stop/restart、更多发行版 fixture 和复杂内容语义仍需要补齐 |
| OpenRC | 当前由 `src/inventory/services_openrc.zig` 做只读扫描，记录 `/etc/init.d` service 和 `/etc/runlevels/*/<service>` runlevel 链接摘要；`src/plan/modules/services_openrc.zig` 会为目标缺失 service 脚本生成 `write_file` 文件型 action，并用 `enable_openrc_service`/`disable_openrc_service` 收敛源/目标 runlevel 差异；`src/modules/handlers/services_openrc.zig` 通过 `rc-update add/del` 和 `/etc/runlevels/<level>/<service>` 存在性检查完成 apply、verify、rollback 和 rollback 后置验证 | 文件本体和 runlevel add/del 可以受控自动化；OpenRC service 脚本可能包含任意 shell，start/stop/restart、provider 级 fixture 和跨发行版边界仍需要补齐 |
| Docker/Podman | 当前由 `src/inventory/docker.zig` 聚合，`docker_runtime.zig`、`docker_containers.zig`、`docker_resources.zig` 和 `docker_compose.zig` 分别做 scan-only 事实扩展，包含 runtime、运行中容器、volume、volume mountpoint、network、image 和 Compose 文件候选；Docker/Podman 资源记录带 runtime 字段，plan 层按运行时分开比对；`src/plan/modules/container_review.zig` 会生成容器 `manual_step` 审查项，目标缺失 volume 且源端能解析 mountpoint 时会额外生成高风险 `copy_data_path` 动作，复用通用 transfer handler；后续 apply 再拆 `src/container/*` 或 `src/apply/action/containers.zig` | volume 数据复制前必须停止写入者或做应用一致性备份；network、compose 状态和镜像来源都需要独立 verify |
| 存储和挂载 | 已有 `src/inventory/storage.zig` 和 `src/inventory/schema_parts/storage.zig` 做只读事实扫描，`src/plan/modules/storage_review.zig` 会生成 `manual_step` 审查项；后续再补 apply/rollback | fstab、权限、挂载点和数据一致性风险高 |
| 系统基线 | `src/inventory/system_baseline.zig` 和 `src/inventory/schema_parts/system_baseline.zig` 只读扫描 locale/timezone、PAM、NTP、sysctl、LDAP/SSSD、DNS/NSS、静态网络、hosts、LVM/ZFS/Btrfs 命令事实、at jobs、脚本安装应用和敏感材料存在性；locale、timezone、sysctl、limits、NTP、resolv.conf、nsswitch、NFS exports 和存储池命令输出会进入结构化 `config_facts`；`src/plan/modules/system_baseline_review.zig` 对高风险差异生成 `manual_step`，`/etc/hosts` 差异额外生成可选文件型迁移动作 | 这些配置强依赖发行版、网络、身份源和安全策略，除 `/etc/hosts` 外不能当普通文件自动覆盖 |
| SELinux/AppArmor | 已有 `src/inventory/security_policy.zig` 和 `src/inventory/schema_parts/security_policy.zig` 做只读事实扫描，`src/plan/modules/security_policy_review.zig` 会生成 `manual_step` 审查项；后续再补 apply/rollback | 策略语义复杂，不能当成普通配置文件覆盖 |

这些模块的共同要求：

1. scan 阶段只采集事实。
2. plan 阶段生成稳定 action id 和可审查 payload。
3. validate 阶段检查高风险字段和确认要求。
4. apply 阶段必须声明远程依赖和 rollback 能力。
5. approved 执行必须写 audit。
6. 不能完整 rollback 的动作必须在 plan、dry-run 或 audit 中暴露风险。

### 7.2 新增模块模板

新增一个可迁移模块时，建议按下面的最小模板推进：

```text
1. inventory/<module>.zig
   - 只采集事实
   - 失败时返回 warning 或空结果，避免拖垮整个 scan

2. inventory/schema_parts/<module>.zig 或模块私有 schema
   - 定义 inventory 字段
   - 新字段优先可选

3. plan/modules/<module>.zig
   - 把 source/target 差异变成 action
   - action id 必须稳定
   - action payload 必须足够审查

4. plan/validator.zig
   - 校验 action type、payload、风险和确认要求

5. modules/*registry 或 apply_support
   - 显式声明 scan/plan/apply/verify/rollback 能力
   - 未声明能力默认拒绝

6. modules/handlers/<module>.zig
   - 模块级分发，不解析原始 argv

7. apply/action/<module>.zig
   - 只做领域动作
   - 远程执行必须走 remote/*
   - 文件传输必须走 transport/*

8. rollback schema/handler
   - 能恢复的副作用写 rollback manifest
   - 不能恢复的副作用在风险和审计中暴露

9. tests/smoke
   - 单元测试覆盖 payload 和过滤规则
   - fake remote 覆盖执行 argv
```

这个模板的目的不是增加文件数量，而是保证“事实采集、计划生成、执行、验证、回滚”可以分别测试和替换。

### 7.2.0 新模块最小闭环

新增模块不要一开始就追求全生命周期。推荐先做一个最小闭环：

```text
scan-only
  -> inventory schema
  -> summary 输出
  -> 单元测试

plan-only
  -> action id/type/payload
  -> validator
  -> dry-run 可审查

approved apply
  -> registry 声明
  -> handler 分发
  -> remote/transport adapter
  -> audit event
  -> rollback entry 或明确不可回滚风险

verify/rollback
  -> 执行后校验
  -> rollback manifest 契约
  -> fake remote smoke
```

这样可以让一个模块先成为只读观察能力，再逐步升级为可计划、可执行、可恢复能力。scan-only 模块同样有价值，因为 AI 和人工需要先知道旧机器上到底有什么。

### 7.2.1 新模块落地示例

`sudoers` 模块当前已完成第一步只读扫描，后续推荐继续按下面顺序推进：

```text
inventory/sudoers.zig
  -> 已实现：读取 /etc/sudoers 和 /etc/sudoers.d 的元数据事实，输出结构化条目和 warning，不输出授权规则内容

inventory/schema_parts/sudoers.zig
  -> 已实现：定义 SudoersEntry、SudoersInventory 等类型

plan/modules/manual_common.zig
  -> 已实现：封装 manual_step action 的公共构造逻辑

plan/modules/sudoers_review.zig
  -> 已实现：比较 source/target sudoers 元数据，生成 sudoers manual_step 人工审查 action，不输出规则正文

plan/modules/manual_review.zig
  -> 已实现：保留高风险人工审查规则的薄门面和聚合测试；运行时 registry 直接引用各领域 review 模块

plan/modules/sudoers.zig
  -> 后续：生成 sudoers/copy-file 或 sudoers/install-snippet 自动迁移动作

plan/validator.zig
  -> 校验 action payload、路径、风险等级和确认要求

modules/plan_registry.zig / modules/apply_support.zig
  -> 显式声明 sudoers 支持 plan 或 apply

modules/handlers/sudoers.zig
  -> 分发 sudoers action，不直接拼 ssh

apply/action/sudoers.zig
  -> 上传临时文件，运行 visudo -c 校验，再原子替换

rollback/schema.zig / rollback dispatcher
  -> 写入原文件备份路径，rollback 时恢复备份并再次校验

tests / smoke
  -> 覆盖 action 生成、payload 校验、fake remote argv 和失败路径
```

这个示例体现两个边界：`sudoers` 的语义属于领域模块；`ssh`、临时文件上传、远程校验命令和审计写入仍属于通用 adapter。类似地，`docker`、`firewall`、`users`、`storage` 等模块也应该把领域判断和外部命令后端拆开。

### 7.2.2 什么时候拆 provider

如果一个模块内部存在多种系统实现，就应该拆 provider/backend，而不是在 action 里堆 `if`：

| 模块 | 适合拆出的 provider/backend | 原因 |
| --- | --- | --- |
| packages | apt、dnf、yum、zypper、pacman | 包管理器命令和输出格式不同 |
| firewall | nftables、iptables、ufw、firewalld | reload、校验和恢复方式不同 |
| services | systemd、OpenRC、SysV init | enable/start/status 语义不同 |
| containers | Docker、Podman、Compose | 命令、volume 和网络模型不同 |
| credentials | ssh-agent、identity file、Vault、短期证书 | 敏感信息来源和生命周期不同 |
| audit | file、syslog、HTTPS、SIEM | 可靠性、签名和传输协议不同 |

provider 的职责是封装“某种后端怎么做”，不是决定“要不要做”。要不要迁移、迁移哪些 action、是否允许执行，仍由 plan、filter、policy 和 registry 决定。

### 7.3 Package Manager Provider

包管理器是已经开始 provider 化的模块之一。当前支持 apt、dnf、yum、pacman 和 zypper 的扫描与部分 apply 命令；第一层 provider 已经把“命令差异”从业务编排中拆出。

当前结构：

```text
inventory/package_manager.zig
  -> candidates()
  -> versionCommand()
  -> repositorySources()
  -> explicitPackagesCommand()
  -> heldPackagesCommand()

apply/action/package_provider.zig
  -> commandPrefix(.install)
  -> commandPrefix(.verify)
  -> commandPrefix(.remove)

remote/package_manager.zig
  -> detect()
  -> rollback remove 和 rollback verify 共享远端包管理器探测
```

`inventory/packages.zig` 仍负责实际探测、读取仓库文件和运行扫描命令；`apply/action/packages.zig` 仍负责组装最终 argv 并保留兼容入口；`remote/package_manager.zig` 负责 approved rollback 阶段在目标机上探测实际可用包管理器。Provider 只负责“某个包管理器该用什么命令”，不负责决定要安装哪些包。是否迁移、迁移哪些包仍由 plan、filter 和 policy 决定。

后续需要继续补齐：

- 为每种包管理器增加更完整 fake command fixture 和失败注入。
- 增加多发行版容器测试，验证扫描命令输出解析和 apply argv。
- 增加包名映射/冲突解释，但不要在 v0.1 中默认跨发行版自动迁移。

## 8. 安全边界

HostLift 当前的安全策略是“本地强约束 + 远程最小执行边界”。

已经具备：

- `--approve` 才真实执行。
- host 校验。
- path 校验。
- argv token 校验。
- identity file 校验。
- policy allow/deny。
- 审批 ticket 本地规则。
- registry fail closed。
- audit hash chain。
- rollback manifest。
- 防火墙 reload 恢复窗口。

还不具备：

- 操作者身份认证。
- 企业 RBAC。
- 审批系统在线校验。
- 集中凭据托管。
- 短期 SSH 证书签发。
- SIEM 级审计队列、重放、签名、时间戳锚定和 mTLS/RBAC。
- 多租户隔离。

因此当前版本适合作为“受控迁移执行器”，不应该宣称为完整企业权限平台。

边界职责建议保持如下：

| 边界 | 负责内容 | 不负责内容 |
| --- | --- | --- |
| `security/*` | host、path、argv、identity file 形状校验 | 判断业务上是否应该迁移 |
| `policy/*` | allow/deny、risk、host、operator 字符串、审批票据要求、ticket 精确值和前缀规则 | 认证操作者身份或在线校验工单 |
| `credentials/*` | 描述凭据来源 | 保存或解密私钥 |
| `remote/*` | SSH argv、timeout、retry、风险分类 | 业务模块决策 |
| `transport/*` | scp/rsync/manifest | package/service/user 语义 |
| `audit/*` | 事件写入和 hash chain | 集中 SIEM 的最终存储保证 |
| `rollback/*` | 补偿动作记录和执行 | 整机快照 |

安全边界的实现顺序应该保持一致：

```text
parse argv
  -> validate host/path/argv/identity
  -> load host authorization and evaluate operator/host
  -> load policy and evaluate
  -> check registry support
  -> build remote/transport argv
  -> execute only when approved
  -> write audit and rollback evidence
```

如果某个功能无法落到这条链路上，应优先补 adapter 或 provider，而不是在业务模块里增加特殊通道。

### 8.1 用户、权限和主机授权

当前 HostLift 会校验 `--host` 是否符合格式、是否被 policy allowlist 允许，`--operator` 或环境推断 operator 是否命中本地 allow/deny 规则，action 是否被 policy 接受，`--approval-ticket` 是否满足本地 ticket 规则，以及可选 `--approval-receipt` 是否绑定当前 ticket/operator/host/purpose/plan hash/过期时间和可选 HMAC-SHA256 签名。

`src/policy/host_authz.zig` 提供了第一版本地主机授权 provider。approved apply/rollback 可以通过 `--host-authz <path>` 读取 `hostlift.host_authz.v1` JSON，把 operator 字符串绑定到精确 host、host prefix 或显式 `allow_all_hosts`。`src/cli/host_authz.zig` 负责读取文件、输出授权报告和失败关闭。这个检查发生在 audit sink 打开和远程调用之前，避免未授权请求留下半截执行证据或触发 SSH。

它仍然不会认证“当前操作者是谁”，也不会判断某个组织用户是否有权操作某台主机。当前的 host-authz 是本地文件型授权边界，适合先把职责从 action policy 中拆出来；真实企业版本仍应接入身份系统、资产系统和在线授权 provider。

企业级版本应新增独立的授权边界：

```text
OperatorIdentity
  -> ApprovalProvider
  -> HostAuthorizationProvider
  -> PolicyProvider
  -> approved execution
```

这些能力不应该塞进 `security/validation.zig`。`security` 负责输入形状安全，`policy` 负责本地 allow/deny 和 operator 字符串限制，`host_authz` 负责第一层本地 operator/host 授权，真正的用户身份、RBAC、主机分组和审批在线校验应该由 provider 接入。

### 8.2 密钥和敏感信息处理

当前实现只接受 identity file 路径并把它传给 SSH/scp/rsync，不读取私钥内容。审计中只记录 credential source 类型，不记录私钥路径和密钥材料。

后续接入 Vault、SSH agent、短期证书或云凭据时，应继续保持：

- 凭据材料不进入 inventory、plan、audit 和 rollback。
- 审计只记录凭据来源类型、provider 名称或凭据租约 id。
- provider 返回的临时凭据应该有过期时间和最小权限。
- 失败时不能把 secret 打印到错误日志。

## 9. 防火墙设计

防火墙是高风险模块，原因是配置错误可能导致 SSH 断连。

当前防护：

- 防火墙动作标记为高风险。
- 默认不 reload。
- reload 前检查指定 SSH 端口。
- 可配置 `--firewall-recovery-window`，通过 systemd-run 安排延迟恢复。
- 建议最后单独执行。

实现边界：

- `src/firewall/backend.zig` 负责 backend 推断、配置校验 argv、reload argv 和恢复脚本内容；backend argv 使用带内联存储的结构返回，避免把局部数组切片交给远程执行层。
- `src/firewall/recovery.zig` 负责上传恢复脚本、安排 systemd-run 延迟任务和成功后取消恢复任务。
- `src/firewall/reload.zig` 负责串联 SSH 端口预检、backend 配置校验、可选恢复窗口、reload 和 reload 后检查。

后续需要补齐：

- nftables/iptables/ufw/firewalld 后端差异测试。
- 非 systemd recovery fallback。
- 云安全组感知。
- SSH 连接保活证明。
- reload 后主动连通性验证。

## 10. 传输设计

传输层当前有三类后端契约：

- scp：简单复制，适合小文件和基础场景。
- rsync：支持目录同步、`--partial` 和 `--append-verify`，适合本机到目标机的大目录重试和续传辅助。
- chunk：HostLift 原生分块传输的第三个后端，当前有计划、索引契约和 staging+远端 rsync 第一版执行 adapter。

传输可靠性选项集中在 `TransferPlan` 上表达：

- `--partial` / `--transfer-partial` 让 `TransferPlan.partial=true`，rsync adapter 在 argv 中加入 `--partial`。
- `--resume` / `--transfer-resume` 让 `TransferPlan.resumable=true`，并自动启用 `partial`，rsync adapter 在 argv 中加入 `--append-verify`。
- 这两个选项都要求 `transport=rsync`；如果选择 `scp` 或 `chunk`，计划构建阶段直接返回错误。
- `--bwlimit` / `--transfer-bwlimit` 让 `TransferPlan.bandwidth_limit_kbps` 保存非零 Kbit/s 数值；scp adapter 使用 `-l <kbps>`，rsync adapter 向上取整转换成 `--bwlimit=<KB/s>`。
- `--transport chunk` 让 `TransferPlan.transport=chunk`，并写入默认 `chunk_size_bytes=8388608`。当前只允许本机源目录递归计划；`source_host + chunk` 和非递归 chunk 都会失败关闭。

这些组合规则集中在 `src/remote/transfer_rules.zig`，`src/remote/transfer_plan.zig` 只负责 host/path 校验、执行选项归一化和 `TransferPlan` 组装。后续新增 chunk 执行、P2P 或 agent 后端时，应优先扩展 rules 和 adapter，而不是把后端分支散落到 CLI 或 apply handler。

当前 rsync adapter 只支持本机到目标机。远程源到远程目标的传输仍走 scp 的 `-3` 模式；`source-host + rsync` 在计划构建阶段拒绝，直到实现源侧执行或专门的 P2P/agent transport。

远程 manifest 的实现拆成两层：

- `transport/remote_probe.zig` 负责远程 `find`、`stat` 和 `sha256sum`。
- `transport/manifest.zig` 负责把探针结果组织成 manifest。

transfer 命令自身也拆成三层：

- `transfer/options.zig` 负责 argv 解析、默认值和 transport 枚举解析。
- `transfer/manifest_flow.zig` 负责 transfer 过程中的 source/target manifest 编排。
- `transfer/command.zig` 负责把 transfer plan、manifest flow 和 scp/rsync adapter 串起来。
- `transport/chunk.zig` 负责 chunk approved 执行编排：目标机创建 staging 目录，构建源/目标 manifest，按 index diff 上传 missing+changed 文件，目标机 `rsync -a` 合并落盘。
- `transport/chunk_paths.zig` 负责 chunk 路径拼接和相对路径逃逸校验。
- `transport/chunk_upload.zig` 负责 chunk 的 scp argv 构造。
- `transport/chunk_index.zig` 负责第一版 chunk index schema：`hostlift.transport.chunk_index.v1`，包含文件引用、chunk 引用、偏移、大小和 SHA-256。

`transport/chunk_index.zig` 现在从 manifest 生成索引。为了先稳定 contract，它暂时把每个文件映射成一个 chunk，并复用 manifest 中的文件 SHA-256。`diffIndexes` 会按 path 和 offset 判断 chunk 身份，再按 size 和 SHA-256 区分内容是否一致，分别返回 missing、changed 和 extra；`missingChunks` 保留为上传队列便捷函数，返回需要上传的 missing+changed 源 chunk。后续真正分块时，应保持 index schema 可追加兼容，把整文件 chunk 替换为按 `chunk_size_bytes` 切分后的多 chunk 列表。

后续真正字节块级缺块上传应继续扩展 `transport/chunk.zig` 和相关 chunk 子模块，不应该塞进 scp 或 rsync 实现里。

建议的 chunk transport 形态：

```text
transport/chunk.zig
  -> buildManifest(source)
  -> buildIndex(source)
  -> uploadMissingChunks(target)
  -> verifyIndex(target)
```

它应该复用 manifest/hash 结构，并继续接受同一套 `RemoteOptions` 和 credential source。

### 10.1 远程到远程传输

当前远程到远程传输由控制机编排：

```text
source-host + source path
  -> 控制机启动 scp/rsync 或远程命令
  -> host + target path
```

这种方式部署简单，不需要常驻 agent，但大文件会受控制机网络路径影响。后续如果做 P2P、WebSocket 或 agent 模式，应新增 transport provider，并保留现有 `TransferPlan` 字段语义，避免破坏 CLI 和审计。

### 10.2 Manifest 校验

manifest 的职责是给文件树生成可比较的证据：

- 本地 manifest：`manifest --path` 和 `transfer --manifest-output`。
- 远程 manifest：approved transfer 后通过远程 `find/stat/sha256sum` 探针生成。
- 审计关联：manifest 可以和 plan、audit、工单一起保存。

manifest 不能解决正在写入的数据一致性问题。数据库、消息队列和业务运行时数据仍需要业务级备份恢复流程。

## 11. 凭据设计

当前凭据层只做“来源描述”和“identity file/provider 选择”：

- 默认 SSH 配置：`default_ssh`。
- 显式私钥：`identity_file`。
- SSH agent：`ssh_agent`，只记录来源类型，不生成 `-i` 参数。
- 环境变量：`env:<name>` 读取环境变量值作为 SSH identity file 路径，校验路径后传给 SSH/scp/rsync；审计只记录 `env`，不记录变量名或路径。
- Vault：`vault:<path>` 当前只解析 provider ref，校验阶段返回 `UnsupportedCredentialProvider`，保持失败关闭。

HostLift 不读取私钥内容，不托管私钥，也不把私钥路径写入审计日志。审计只记录来源类型。

后续企业级凭据能力应该拆成独立 provider：

- 短期 SSH certificate provider。
- Vault provider。
- 云厂商临时凭据 provider。
- 凭据轮换和过期时间记录。

现有契约在 `src/credentials/source.zig` 中集中实现：`fromOptions` 负责拒绝同时指定 `--identity-file` 和 `--credential-provider`，`parseProvider` 负责把 CLI 字符串变成来源元数据，`resolve` 负责把可执行 provider 解析为 SSH 可用参数，`validate` 负责来源形状校验和未支持 provider 的失败关闭。`src/remote/options.zig` 只暴露归一化后的 `ssh_identity_file` 和 `credential_source`，因此 `CommandPlan`、`TransferPlan` 和 audit log 都只保存非敏感来源类型，不保存 provider ref 或密钥材料。

## 12. AI 使用方式

HostLift 适合给 AI 提供结构化上下文和受控执行接口：

1. AI 读取 inventory、plan、validate 报告和 dry-run 输出。
2. AI 给出模块过滤、风险说明和迁移批次。
3. 人或审批系统确认。
4. HostLift 执行带 `--approve`、`--operator`、`--approval-ticket` 和 `--policy` 的命令。
5. 审计日志和 rollback manifest 回写到工单或外部系统。

AI 不应该绕过 HostLift 直接拼接远程 shell 批量执行。

## 13. 测试设计

当前主要测试入口：

```bash
scripts/check.sh
```

覆盖：

- `zig build test`。
- CLI help 构建。
- fake remote smoke。
- `git diff --check`。
- public function Chinese comment check。

测试重点：

- schema 编解码兼容。
- plan 生成和过滤。
- policy allow/deny。
- remote/transport 参数构造。
- apply preflight 远程依赖推导。
- audit hash chain。
- rollback options 和 manifest。
- fake remote 下的 apply/transfer/rollback smoke。

后续需要补齐：

- 多发行版容器集成测试。
- 防火墙后端测试。
- handler 级 fake fixture。
- 大目录 manifest 性能测试。
- 审计 sink adapter 测试。
- chunk transport 断点续传测试。

### 13.1 质量门禁

当前统一质量门禁是 `scripts/check.sh`。它把构建、测试、fake remote smoke、空白字符检查和 public 方法中文注释检查放在一起，适合作为本地提交前检查和 CI 入口。

新增代码时至少满足：

- `zig build test` 通过。
- `zig build run -- help` 能正常输出。
- fake remote smoke 不破坏。
- 新增 `pub fn` 前有简短中文注释。
- 文档中的命令参数和 `hostlift help` 保持一致。

### 13.2 集成测试演进

下一阶段建议按风险补集成测试，而不是一次性追求全覆盖：

1. fake command fixture：覆盖每个 handler 生成的 SSH/scp/rsync argv。
2. 单发行版容器测试：先覆盖 Ubuntu/Debian 常用路径。
3. 多发行版矩阵：再补 Fedora、Arch、openSUSE。
4. 故障注入：远程命令失败、传输中断、审计写入失败、rollback 失败。
5. 防火墙专项：只在隔离网络或容器环境验证，不直接依赖开发机防火墙。

## 14. 当前代码质量评估

当前代码已经从早期脚本式结构，推进到较清晰的分层架构：

- CLI 已经拆成 `src/cli/*.zig`。
- apply 参数解析已拆到 `src/cli/apply_options.zig`。
- apply/rollback 共享的 operator、审批凭证、审计 sink、host-authz 和远程执行元数据解析已抽到 `src/cli/common_options.zig`。
- apply policy 输出、dry-run 输出和 action 审计写入已拆到 `src/cli/apply_policy.zig`、`src/cli/apply_dry_run.zig` 和 `src/cli/apply_audit.zig`。
- policy 匹配已拆到 `src/policy/match.zig`。
- policy schema、RuleSet 校验和子规则派生已拆到 `src/policy/ruleset.zig`，`src/policy/action.zig` 保留动作级和执行入口策略评估。
- audit target 解析已拆到 `src/audit/sink_target.zig`。
- audit file sink 和 writer sink 已拆到 `src/audit/file_sink.zig` 和 `src/audit/writer_sink.zig`。
- audit 单事件校验已拆到 `src/audit/verify_event.zig`。
- rollback 参数解析已拆到 `src/rollback/options.zig`。
- transport 远程探针已拆到 `src/transport/remote_probe.zig`。
- remote 命令计划、传输计划、风险分类和默认值已拆到 `src/remote/command_plan.zig`、`transfer_plan.zig`、`risk.zig` 和 `defaults.zig`。
- remote SSH argv、runner、状态探针和执行门面已拆到 `src/remote/ssh_argv.zig`、`runner.zig`、`probe.zig` 和 `exec.zig`。
- firewall 后端识别已拆到 `src/firewall/backend.zig`。
- inventory schema 已拆出 `module_inventory.zig` 和 `schema_parts`，`schema.zig` 只保留兼容导出和顶层 Inventory。
- inventory scanner 已拆出 `scan_filter` 和 `scan_runner`，`scanner.zig` 只保留顶层 inventory 组装。
- firewall reload 已拆出 `recovery.zig`，恢复窗口上传、调度和取消不再混在 reload 编排里。
- rollback manifest 已拆出 `schema.zig`、`schema_tests.zig` 和 `codec.zig`，`manifest.zig` 只保留兼容导出。
- rollback dispatcher 已拆出 `dispatcher.zig`，action id 到模块 handler 的映射不再混在命令编排里。
- audit action/rollback 事件适配已拆到 `action_event.zig` 和 `rollback_event.zig`，`log.zig` 只保留兼容导出和通用事件入口。

仍然需要继续治理：

- `inventory/schema.zig` 已降为兼容 facade，后续新增领域类型不要回流到该文件。
- syslog 审计 sink 已有本机 `logger` adapter，HTTPS 审计 sink 已有本机 `curl` adapter；SIEM 级签名、队列、重放、mTLS 和外部时间戳锚定仍需要新增 provider。
- `inventory/scanner.zig` 已继续拆出 scan 编排和 warning 聚合；package manager 第一层 provider 已落地，rollback 执行和 rollback 后置验证已复用远端包管理器探测，后续重点转向 scanner fixture、多发行版测试和包管理器失败注入。
- module registry 已按 scan、plan lifecycle、apply support 和基础 apply 依赖声明拆分，后续重点是补 provider 级依赖、内容级 verify 和策略化禁用。
- `util/inventory_summary_overview.zig` 和 `util/inventory_summary_details.zig` 已把顶层概览和详情输出从摘要门面中拆出。

以企业级标准看，当前是“架构方向正确的工程核心”，还不是完整企业平台。缺口主要在 RBAC、集中审计、凭据托管、审批系统、集成测试矩阵、集中配置和更完整的 rollback/verify。

## 15. 企业级目标架构

如果继续做成企业级产品，建议保持当前单机 CLI 核心，同时增加外部控制面：

```text
CLI / TUI / API / AI Adapter
  -> shared core schema and registry
  -> policy engine
  -> credential provider
  -> approval provider
  -> audit sink provider
  -> remote executor and transport
  -> rollback and verification
```

需要补齐的能力：

- 中央策略源和签名 policy。
- 审批 ticket 在线校验和签名校验。
- 用户身份和 RBAC。
- 主机授权和主机分组。
- 凭据 provider 和短期凭据。
- HTTP/syslog/SIEM 审计 sink。
- 任务队列和执行状态持久化。
- 多发行版兼容矩阵。
- 模块级 verify 和 rollback 覆盖率。
- 分块传输、断点续传和校验索引。
- Web/TUI 操作台。

这些能力应作为 provider 或 adapter 接入，不应该破坏现有 CLI、schema、registry、policy、audit 和 transport 边界。

### 15.1 Provider 化方向

企业能力不要直接写死在 apply 里，建议用 provider 接口扩展：

| Provider | 目标 |
| --- | --- |
| CredentialProvider | 从 SSH agent、Vault、云厂商或短期证书系统获取凭据 |
| ApprovalProvider | 校验工单、审批人、变更窗口和双人审批 |
| AuditSinkProvider | 写入 HTTP、syslog、SIEM 或对象存储 |
| HostAuthorizationProvider | 判断当前操作者是否允许操作某组主机 |
| PolicyProvider | 拉取签名 policy 或环境级策略 |
| TransportProvider | 支持 rsync、scp、chunk、P2P 或 agent 传输 |

CLI 仍然可以保持单机可用；provider 是增强，不应该变成基本使用的强依赖。

## 16. 扩展规则

新增功能时遵守以下规则：

1. 原始用户输入只在 CLI 或边界层解析。
2. 领域模块消费结构化 options，不消费原始 argv。
3. 远程命令必须走 `remote/*`。
4. 文件传输必须走 `transport/*`。
5. host/path/argv 校验必须走 `security/*`。
6. 新 action 必须有 validator。
7. 新 apply 能力必须在 registry 显式声明。
8. approved 执行必须写 audit。
9. 可恢复副作用必须写 rollback manifest。
10. JSON schema 优先追加可选字段，不破坏旧字段。
11. 新 public `pub fn` 必须有简短中文注释。
12. 修改后运行 `scripts/check.sh`。

## 17. 推荐阅读路径

开发者建议按下面顺序读代码：

1. `src/main.zig` 和 `src/cli.zig`：了解命令分发。
2. `src/inventory/schema.zig`：了解 inventory 结构。
3. `src/plan/schema.zig` 和 `src/plan/builder.zig`：了解 plan 结构和生成。
4. `src/plan/validator.zig` 和 `src/policy/*.zig`：了解执行前门禁。
5. `src/modules/handler.zig`、`src/modules/scan_registry.zig`、`src/modules/plan_registry.zig` 和 `src/modules/apply_support.zig`：了解模块生命周期。
6. `src/apply/executor.zig`：了解 approved apply 编排。
7. `src/remote/*.zig` 和 `src/transport/*.zig`：了解 SSH/scp/rsync 边界。
8. `src/audit/*.zig`：了解审计事件和 hash chain。
9. `src/rollback/*.zig`：了解 rollback manifest 和恢复流程。

## 18. 当前结论

HostLift 当前已经具备 Linux 迁移工具的核心骨架：结构化扫描、计划、过滤、策略、受控执行、审计和回滚。代码架构已经从单文件脚本式实现，逐步拆成可维护的领域模块。

下一阶段重点不应是继续堆命令，而是补齐企业级边界：凭据 provider、审批 provider、集中审计 sink、模块级 verify/rollback、传输可靠性和多发行版集成测试。只要继续保持 schema、registry、security、remote、transport、audit、rollback 的边界稳定，HostLift 可以从 CLI 工具平滑演进到 TUI、API 或 AI 迁移执行平台。
