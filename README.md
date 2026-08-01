# HostLift

HostLift 是一个用 Zig 编写的 Linux 主机迁移与同步工具，面向“两台 Linux 电脑或服务器之间迁移配置、服务、定时任务、用户配置、项目目录和应用数据”的场景。它不是整盘克隆工具，也不是实时双向同步系统；它的核心是把迁移过程拆成可保存、可审查、可批准、可审计、可回滚的步骤。

典型流程：

```text
旧机器 scan
  -> 新机器 scan
  -> 控制机 plan
  -> validate
  -> apply --dry-run
  -> apply --approve
  -> audit verify
  -> 按需 rollback
```

HostLift 支持 AI 辅助分析 inventory、plan、dry-run 和 audit，但真实执行仍必须经过 `--approve`、policy、host 授权、安全校验、审计和 rollback 边界。

## 文档导航

| 文档 | 内容 |
| --- | --- |
| 本 README | 安装、使用流程、常用命令和当前能力边界 |
| [TECH_DESIGN_zh.md](docs/TECH_DESIGN_zh.md) | 技术实现、代码设计思路、架构分层和模块扩展方式 |
| [ARCHITECTURE_zh.md](docs/ARCHITECTURE_zh.md) | 当前源码目录和模块关系 |
| [CODE_QUALITY_zh.md](docs/CODE_QUALITY_zh.md) | 代码质量、文件长度、企业级差距和重构建议 |
| [PRD_zh.md](docs/PRD_zh.md) | 产品需求、市场需求和版本路线 |
| [migration_coverage_audit_zh.md](docs/migration_coverage_audit_zh.md) | 当前迁移覆盖、AI 驱动整机迁移场景矩阵和缺口 |

## 当前状态

当前项目处于 v0.1 工程核心阶段，已经适合做：

- Linux 主机事实扫描。
- 源/目标 inventory 比较并生成迁移计划。
- 迁移计划校验、dry-run 审查和按模块/action 过滤执行。
- 部分包、服务、配置、SSH、cron、用户、项目目录、home 配置、应用数据和防火墙迁移。
- `resources` 整机资源地图：扫描通用应用根、用户 home、XDG 登录态、缓存、PATH/用户级 bin/进程/service/cron/profile 引用到的可执行文件，记录逻辑大小、磁盘占用、文件数、包管理器归属、文件类型、静态动态依赖摘要、证据、敏感等级和默认迁移建议；未被包管理器托管的可执行文件会按通用证据识别，不按具体应用名硬编码；plan 阶段会结合目标挂载容量、inode、内存和 swap 事实输出轻量容量风险提醒。
- systemd service、systemd timer、systemd socket、用户级 systemd unit、XDG autostart、SysV init 和 OpenRC 的启动事实扫描；systemd service 会同时记录 unit-file 状态、运行态、drop-in、service env 文件和 `systemctl show` 依赖摘要，源端运行中而目标端未运行的 service 会在 plan 阶段生成高风险 `services/review-start/<unit>` 和 `services/check-status/<unit>` 人工步骤，依赖摘要差异会生成 `services/review-deps/<unit>`，HostLift 默认不自动启动服务；复杂 drop-in/env/timer/socket/autostart 差异仍生成 `manual_step`；缺失的用户级 systemd unit、XDG autostart、SysV init 脚本和 OpenRC service 脚本可生成文件型迁移动作，enabled 用户级 systemd unit 可生成受控 `systemctl --user enable` 动作，SysV init 可通过 `chkconfig` 或 `update-rc.d` 生成 runlevel enable/disable 动作，OpenRC service 可生成受控 `rc-update add/del` 动作。
- 指定 IP/路径的点对点文件传输。
- 受控远程命令执行。
- 本地 policy、审批票据、审批凭证、host 授权、审计日志和 rollback manifest。

已经实现的传输后端包括 `scp`、`rsync` 和第一版 `chunk` adapter。`chunk` 当前使用目标机 staging 目录加远端 `rsync` 落盘，并已把 chunk index diff 接入 approved 传输路径：本机源目录和目标目录会先构建 manifest/index，HostLift 只上传目标缺失或内容变更的文件，再用远端 `rsync -a` 合并。当前仍是“整文件 chunk”，还不是字节块级断点续传。

当前仍不应该宣称为完整企业平台。RBAC、集中凭据托管、在线审批、SIEM 级审计队列、多发行版矩阵、完整非文件 rollback 和真正字节块级 chunk 缺块续传仍是后续工作；个人服务器迁移主线优先使用 `rsync --resume` 做大文件续传。

## 实现架构速览

HostLift 的实现不是把迁移逻辑写成一批临时 shell，而是把每个阶段都做成结构化契约：

```text
CLI 参数
  -> Inventory JSON
  -> MigrationPlan JSON
  -> validate / policy / dry-run
  -> approved apply / transfer / remote exec
  -> Audit JSONL + Rollback JSONL
```

代码按职责拆分：

- `src/cli/*.zig` 负责命令入口、参数解析、文件读写和输出。
- `src/inventory/*` 负责只读扫描 Linux 主机事实。
- `src/plan/*` 负责把源/目标差异转成可审查 action。
- `src/modules/*` 负责模块生命周期注册、能力声明和 handler 分发。
- `src/apply/*` 负责 approved apply 编排、备份、权限修复、verify 和 rollback entry。
- `src/remote/*` 是 SSH 命令唯一出口。
- `src/transport/*` 是 scp、rsync、chunk 和远程 manifest 的唯一出口。
- `src/policy/*`、`src/security/*`、`src/credentials/*` 负责执行前门禁和凭据来源边界。
- `src/audit/*` 和 `src/rollback/*` 负责证据链和恢复路径。

更完整的代码设计、模块边界和扩展方式见 [TECH_DESIGN_zh.md](TECH_DESIGN_zh.md)。当前源码目录说明见 [ARCHITECTURE_zh.md](ARCHITECTURE_zh.md)，代码质量和企业级差距评估见 [CODE_QUALITY_zh.md](CODE_QUALITY_zh.md)。

## 安装和构建

开发环境需要 Zig 0.16.0。项目带有 `mise.toml`：

```bash
mise install
mise exec -- zig version
```

本机检查：

```bash
zig build test
zig build run -- help
```

构建 Linux 二进制：

```bash
./scripts/build-linux.sh
```

构建结果：

```text
dist/x86_64-linux-musl/bin/hostlift
dist/aarch64-linux-musl/bin/hostlift
```

复制到旧机器和新机器：

```bash
scp dist/x86_64-linux-musl/bin/hostlift root@OLD_SERVER_IP:/usr/local/bin/hostlift
scp dist/x86_64-linux-musl/bin/hostlift root@NEW_SERVER_IP:/usr/local/bin/hostlift

ssh root@OLD_SERVER_IP 'chmod +x /usr/local/bin/hostlift && hostlift version'
ssh root@NEW_SERVER_IP 'chmod +x /usr/local/bin/hostlift && hostlift version'
```

## 运行前提

- 控制机可以 SSH 登录旧机器和新机器。
- 旧机器和新机器都能运行 HostLift 二进制。
- 迁移 `/etc`、systemd、cron、用户、项目目录、防火墙时，目标执行账号通常需要 root 或 sudo 权限。
- 使用 `rsync` 后端时，本机和目标机需要安装 `rsync`。
- 使用 `--source-host ... --transport rsync` 做远程源到目标传输时，源机和目标机都需要安装 `rsync`，并且源机需要能通过免交互 SSH 访问目标机；`--identity-file` 只用于控制机连接源机，源机连接目标机仍依赖源机上的 SSH 配置或 agent，preflight 会从源机发起 BatchMode 探测。
- 使用远程 manifest 校验时，远端需要 `find`、`stat`、`sha256sum` 和 `readlink`。
- 使用 `chunk` 后端时，目标机需要 `mkdir`、`rsync`、`find`、`stat` 和 `sha256sum`。
- 使用 SysV init runlevel 自动收敛时，目标机需要 `chkconfig` 或 `update-rc.d`；两者都没有时会在 preflight 阶段失败关闭。
- 使用 OpenRC runlevel 自动收敛时，目标机需要 `rc-update`。
- 使用 PostgreSQL provider 时，源/目标必须是 PostgreSQL 10+ 同主版本，SSH 会话必须为 root，`sudo -n -u postgres psql`/`pg_dumpall` 必须能通过本机 peer 认证；目标只能有 fresh cluster 的 `postgres` 数据库/角色和 `pg_*` 内建角色。
- 使用可信重装 provider 时，目标 SSH 会话必须为 root，并具备 `curl`、`install`、`sha256sum`、`stat`、recipe 指定的 `sh`/`bash` 或 `install` 以及只读 verify 命令。recipe 只允许无凭据、无 query/fragment 的 HTTPS URL，并必须声明精确 artifact 字节数和 SHA-256。
- 正式迁移前仍应准备云盘快照、系统快照或其它整机备份。

HostLift 的 rollback manifest 是动作级补偿记录，不能替代整机快照、数据库备份或业务恢复方案。MySQL/MariaDB、Redis、MongoDB、Elasticsearch、RabbitMQ、Kafka 和 Docker/Podman volume 默认只生成 `appdata/dump-restore/*` 人工合同。PostgreSQL 有一个严格受限、显式 opt-in 的逻辑迁移 provider，但它不会热复制 PGDATA，也不能自动回滚已恢复的数据库集群。

## 怎么使用 HostLift

HostLift 推荐按“先看清楚，再生成计划，再分批执行”的方式使用。不要一上来就把旧机器所有内容直接覆盖到新机器；先把两台机器都扫描成 inventory，再让 HostLift 生成 plan，最后按模块或 action 前缀选择性迁移。

HostLift 有三种常见使用模式：

| 模式 | 适合场景 | 核心命令 |
| --- | --- | --- |
| 规划式迁移 | 把旧 Linux 主机上的包、配置、服务、cron、用户配置、项目目录等迁到新主机 | `scan` -> `plan` -> `validate` -> `apply --dry-run` -> `apply --approve` |
| 定点传输 | 已经知道要传哪个路径，只需要把文件或目录送到指定 IP 和指定路径 | `transfer --host ... --source ... --target ... --approve` |
| 受控远程操作 | 需要在目标机上执行一次检查、重启、安装或其它小范围命令 | `remote exec --host ... --approve -- <cmd>` |

推荐先使用规划式迁移作为主流程；定点传输和远程命令适合补充处理单个项目、单个目录或单次运维动作。AI 可以读取 inventory、plan、dry-run 和 audit 输出帮你判断迁移批次，但真实修改目标机仍必须通过 HostLift 的 `--approve`、policy、host 授权、审计和 rollback 边界。

最常用的使用方式有五类：

| 场景 | 推荐命令 | 说明 |
| --- | --- | --- |
| 整体迁移评估 | `scan` + `plan` + `validate` + `apply --dry-run` | 先看旧机器和新机器差异，不修改目标机 |
| 分批迁移 | `apply --include-module ... --approve` | 只迁选中的模块，例如包、配置、服务或项目目录 |
| 定点传文件 | `transfer --source ... --target ... --approve` | 已知道源路径和目标路径时，直接传文件或目录 |
| 远程执行命令 | `remote exec --host ... --approve -- <cmd>` | 在目标机执行受控命令，适合状态检查或小范围操作 |
| 失败后恢复 | `rollback --manifest ... --approve` | 对 HostLift 已记录的副作用做动作级补偿恢复 |

完整迁移建议遵守下面顺序：

```text
1. 在旧机器执行 scan，得到 source-inventory.json
2. 在新机器执行 scan，得到 target-inventory.json
3. 在控制机执行 plan，得到 hostlift-plan.json
4. 执行 validate 和 apply --dry-run，确认风险、依赖和 manual_step
5. 按模块分批 apply --approve，每批都写 run state、audit log 和 rollback manifest
6. 中断后用同一 plan、host、过滤条件和 run state 安全续跑；每批执行后 audit verify，必要时 rollback
```

PostgreSQL 10+ 整集群逻辑迁移必须在业务维护窗口内单独生成计划。下面两个 plan 开关必须同时出现；第二个开关是操作者或 AI 对“dump 开始前已经停写，并在迁移完成前保持停写”的明确确认：

```bash
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --postgresql-auto \
  --postgresql-writers-stopped \
  --output postgresql-plan.json

hostlift apply \
  --plan postgresql-plan.json \
  --source-host root@OLD_SERVER_IP \
  --host root@NEW_SERVER_IP \
  --run-state ./postgresql-run.jsonl \
  --audit-log ./postgresql-audit.jsonl \
  --rollback-manifest ./postgresql-rollback.jsonl \
  --approve
```

provider 固定执行 `preflight -> pg_dumpall -> target baseline -> scp/rsync -> psql restore -> database/role catalog verify`。全批次 preflight 会拒绝缺少 source-host、非 root SSH、peer 认证失败、PostgreSQL 9.x、major 不同、源端存在任何其它 client backend、目标有业务数据库/角色、artifact 路径冲突或容量不足。dump 和 baseline 固定写到 `/var/lib/hostlift/artifacts/postgresql/<source-inventory-sha256>/`，validator 和 handler 都校验该 hash 绑定，文件权限为 `0600`；文件可能包含 role password hash，必须按 secret artifact 管理。

restore 前 rollback JSONL 会记录 target baseline 路径和 SHA-256。该 baseline 只是人工重建/恢复证据，`hostlift rollback --approve` 会明确返回 `ManualRollbackRequired`，不会谎报数据库已经恢复。restore 失败后不要直接续跑该 action；先按 baseline/基础设施快照把目标恢复为 fresh cluster，再创建新的迁移 run。

`curl | sh` 或手工安装的应用默认仍是结构化 `manual_step`，HostLift 不会直接执行 scanner 提取到的 URL。AI 或操作者确认官方 artifact 后，可以另外提供显式 `hostlift.reinstall_recipes.v1` 文件，把精确匹配的 `script_reinstall`/`resource_reinstall` action 替换为 download、execute、verify 三步 DAG：

```json
{
  "schema_version": "hostlift.reinstall_recipes.v1",
  "recipes": [{
    "id": "tool-v1",
    "manual_action_id": "resources/reinstall//usr/local/bin/tool",
    "kind": "verified_binary",
    "source_url": "https://downloads.example.com/tool/v1.0.0/tool-linux-amd64",
    "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "artifact_size_bytes": 12345678,
    "target_distro_id": "ubuntu",
    "target_distro_version": "24.04",
    "target_arch": "x86_64",
    "install_argv": ["install", "-m", "0755", "{artifact}", "/usr/local/bin/tool"],
    "verify_argv": ["test", "-x", "/usr/local/bin/tool"],
    "verify_stdout_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "managed_paths": ["/usr/local/bin/tool"]
  }]
}
```

先生成普通 plan，从 JSON 中取得精确 `manual_action_id` 和目标发行版/架构；确认来源、版本、下载大小和摘要后再生成带 recipe 的计划：

```bash
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --reinstall-recipes verified-reinstall-recipes.json \
  --output hostlift-plan.json

hostlift apply \
  --plan hostlift-plan.json \
  --host root@NEW_SERVER_IP \
  --include-action resources/reinstall-download/tool-v1 \
  --include-action resources/reinstall-execute/tool-v1 \
  --include-action resources/reinstall-verify/tool-v1 \
  --run-state ./reinstall-run.jsonl \
  --rollback-manifest ./reinstall-rollback.jsonl \
  --audit-log ./reinstall-audit.jsonl \
  --approve
```

`verified_script` 只允许 `sh {artifact} ...` 或 `bash {artifact} ...`，不会产生 `curl | sh` 管道；`verified_binary` 只允许 `install [-m MODE] {artifact} <managed_path>`。下载固定落到 `/var/lib/hostlift/artifacts/reinstall/<source-inventory-sha256>/<recipe-id>/verified-artifact`，目录/文件权限为 `0700`/`0600`；curl 首参数固定为 `--disable` 以忽略目标机 `.curlrc`，同时限制最大字节数，完成后再比较精确大小和 SHA-256。apply 会重新核对目标 `/etc/os-release`、架构、root 身份、命令依赖、`/var/lib` 可用容量和路径不存在；最终 verify 再校验 artifact、全部 `managed_paths` 以及固定只读 argv 的原始 stdout SHA-256。`test -x` 成功时 stdout 为空，因此示例使用空字节 SHA-256；其它命令必须按原始输出（包括换行）计算。recipe/plan/audit/run-state/rollback 不应包含 token、密码或私有下载 URL。

该 provider 只对 recipe 声明且执行前不存在（包括不存在悬空 symlink）的路径提供删除型 rollback，managed path 不能与 HostLift artifact 根重叠。recipe schema 没有 secret 执行通道，明显的 password/token/key/credential 参数会直接拒绝；需要凭据的 installer 必须继续走人工或未来的专属凭据 provider。任意 shell 安装脚本仍可能修改未声明路径、包数据库、用户或服务；这些副作用 HostLift 无法发现或完整回滚。recipe 是 AI/操作者对固定 artifact 和安装行为的显式信任声明，不等于 HostLift 自动判定来源官方，也不把任意 `curl | sh` 应用变成可无条件完整迁移的对象。

完整迁移时建议把每一次执行都绑定到操作者、工单号和审计日志：

```bash
hostlift apply \
  --plan hostlift-plan.json \
  --source-host "$OLD" \
  --host "$NEW" \
  --operator "$OPERATOR" \
  --approval-ticket "$TICKET" \
  --run-state ./hostlift-run.jsonl \
  --audit-log ./hostlift-audit.jsonl \
  --include-module packages,configs,ssh \
  --approve
```

如果要先让 AI 或脚本只分析迁移计划，不产生副作用，使用：

```bash
hostlift validate --plan hostlift-plan.json --summary
hostlift apply --plan hostlift-plan.json --include-module packages,configs,ssh --dry-run
```

如果只想迁一个项目目录，不需要跑完整 scan/plan，可以直接使用：

```bash
hostlift transfer \
  --host root@192.0.2.20 \
  --source /srv/my-app \
  --target /srv/my-app \
  --recursive \
  --transport rsync \
  --approve
```

如果只想让目标机执行一条命令，可以直接使用：

```bash
hostlift remote exec \
  --host root@192.0.2.20 \
  --approve \
  -- systemctl status nginx
```

AI 或自动化系统适合读取 `inventory.json`、`hostlift-plan.json`、`validate` 和 `dry-run` 输出，帮助判断迁移批次和风险；真实修改仍应由 HostLift 在 `--approve`、policy、host 授权、审计和 rollback 约束下执行。

## 三分钟上手

```bash
OLD=root@192.0.2.10
NEW=root@192.0.2.20
OPERATOR=ops/alice
TICKET=OPS-123
```

在旧机器扫描：

```bash
ssh "$OLD" 'hostlift scan --output /root/source-inventory.json --summary --force'
scp "$OLD":/root/source-inventory.json .
```

在新机器扫描：

```bash
ssh "$NEW" 'hostlift scan --output /root/target-inventory.json --summary --force'
scp "$NEW":/root/target-inventory.json .
```

在控制机生成迁移计划：

```bash
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --output hostlift-plan.json \
  --summary \
  --force
```

生成可勾选的 action 选择清单，便于按 action 前缀分批执行：

```bash
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --selection
```

生成迁移后健康检查报告，执行完对应批次后逐项核对：

```bash
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --health-report
```

生成供 AI 读取的工作负载迁移完成度报告：

```bash
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --workloads \
  --output hostlift-workloads.json \
  --force
```

`hostlift.workload_report.v1` 聚合 systemd 服务、项目/Compose、应用数据路径、Docker/Podman 容器和未托管资源，输出组件、关联 action、blocker、confidence、`host_status` 和未归属 action。状态不是迁移百分比：`complete` 只表示当前 scanner 粒度下目标事实已匹配且没有未决 action；`pending` 表示仍有可执行 action；`blocked` 表示存在 manual/critical action 或兼容性阻塞；`unknown` 表示扫描 warning/truncated、组件不匹配或事实不足。为避免过滤后误报完整，`--workloads` 不允许搭配 action/module filter；源/目标 inventory 也必须来自未带 include/exclude 的完整 scan。旧 inventory 没有 `scan.full_scan` 证据时同样输出 `unknown`，需要用当前版本重新扫描。

迁移执行后应重新扫描目标机，再用源 inventory 和新的目标 inventory 生成报告。v1 尚不读取 run-state 或 manual evidence，因此它不能单独证明数据库内容一致、密钥可用、业务请求成功或在线切换完成。

先校验和预览，不修改目标机器：

```bash
hostlift validate --plan hostlift-plan.json --summary
hostlift apply --plan hostlift-plan.json --dry-run
```

确认后执行：

```bash
hostlift apply \
  --plan hostlift-plan.json \
  --source-host "$OLD" \
  --host "$NEW" \
  --operator "$OPERATOR" \
  --approval-ticket "$TICKET" \
  --run-state ./hostlift-run.jsonl \
  --audit-log ./hostlift-audit.jsonl \
  --rollback-manifest ./hostlift-rollback.jsonl \
  --approve
```

`copy_data_path` 和 `copy_project_path` 默认在全批次 preflight 构建完整源 manifest，并在传输后构建目标 manifest，逐项比较相对路径、类型、大小、普通文件 SHA-256 和符号链接目标。源或目标超过默认 100000 条、探针输出不完整，或发现 FIFO、socket、block/character device 时都会失败关闭。可用 `--transfer-manifest-max-entries <n>` 调整上限；只有明确接受“仅检查目标存在”的降级语义时才使用 `--no-transfer-manifest-verify`。

内容 mismatch 会把 action/run-state 记录为 `failed`，不会写 `succeeded`；新建数据/项目路径的删除型 rollback baseline 会在内容 verify 前写入并 flush，因此 verify 失败后仍有回滚证据。该校验不提供数据库热数据一致性，也不保留 ACL、xattr、Linux capability、hardlink、sparse 或 SELinux context 语义。

`--rollback-manifest` 指定的文件必须不存在，HostLift 不会覆盖旧的恢复证据；省略时会在 `/tmp` 生成带随机 run 后缀的唯一文件名。每条 rollback entry 写入后立即 flush，执行中途失败时此前已经生成的记录仍可用于恢复。

approved apply 会同时创建 migration run state。`--run-state` 可指定一个必须不存在的 JSONL 路径；省略时会生成唯一 `/tmp/hostlift-run-*.jsonl`。状态文件使用 hash chain 和独占文件锁，绑定 plan hash、目标 host、所选 action 集合和 rollback manifest，并记录 `started`、`rollback_prepared`、`succeeded`、`failed`、`skipped`。批次失败后，用原 plan、原 host、完全相同的 include/exclude 参数恢复：

```bash
hostlift apply \
  --plan hostlift-plan.json \
  --source-host "$OLD" \
  --host "$NEW" \
  --resume-run ./hostlift-run.jsonl \
  --rollback-manifest ./hostlift-rollback.jsonl \
  --audit-log ./hostlift-resume-audit.jsonl \
  --approve
```

恢复会重新做所有未完成 action 的批量只读 preflight，只跳过状态链中已有 `succeeded`/安全 `skipped` 证据的 action，并复用首次 `rollback_prepared` 对应的备份，避免覆盖原始恢复证据。plan、host、选择集合、manifest 路径或 hash chain 任一不一致都会失败关闭。每次恢复建议使用新的 `--audit-log` 路径；run state 不替代 audit，也不保证数据库热数据一致性。

执行后校验审计链：

```bash
hostlift audit verify --log ./hostlift-audit.jsonl --summary
```

## 常用命令速查

| 目标 | 命令 |
| --- | --- |
| 查看帮助 | `hostlift help` |
| 扫描本机并输出摘要 | `hostlift scan --output inventory.json --summary --force` |
| 生成迁移计划 | `hostlift plan --source source.json --target target.json --output hostlift-plan.json --summary --force` |
| 生成选择清单 | `hostlift plan --source source.json --target target.json --selection` |
| 生成健康检查报告 | `hostlift plan --source source.json --target target.json --health-report` |
| 生成 AI 工作负载完成度报告 | `hostlift plan --source source.json --target target.json --workloads --output hostlift-workloads.json` |
| 校验计划 | `hostlift validate --plan hostlift-plan.json --summary` |
| 预览执行 | `hostlift apply --plan hostlift-plan.json --dry-run` |
| 批量执行指定模块 | `hostlift apply --plan hostlift-plan.json --host "$NEW" --include-module packages,configs,ssh --approve` |
| 恢复中断批次 | `hostlift apply --plan hostlift-plan.json --host "$NEW" --resume-run ./hostlift-run.jsonl --approve` |
| 直接传目录 | `hostlift transfer --host "$NEW" --source /srv/app --target /srv/app --recursive --transport rsync --approve` |
| 直接执行远程命令 | `hostlift remote exec --host "$NEW" --approve -- systemctl status nginx` |
| 校验审计链 | `hostlift audit verify --log ./hostlift-audit.jsonl --summary` |
| 预览回滚 | `hostlift rollback --manifest hostlift-rollback.jsonl --dry-run --host "$NEW"` |

要重点查看“这台机器有哪些启动项、定时任务、用户会话服务和后台项目”，优先跑：

```bash
hostlift scan --include-module services,cron,users,projects,processes,network,docker --output runtime.json --summary --force
```

摘要会列出 systemd service、drop-in、service env 文件、systemd 依赖摘要、systemd timer、systemd socket、用户级 systemd unit、XDG autostart、SysV init、OpenRC、cron/anacron/at 线索、项目目录、进程摘要、监听端口和容器事实。systemd service 会记录 unit-file 状态、active/reloading/activating/inactive/failed 等运行态、自定义路径和 Requires/Wants/After/EnvironmentFiles/ExecStart 摘要；源端 active-like 而目标端不是 active-like 的 service 会生成 `services/review-start/<unit>` 和 `services/check-status/<unit>` 高风险人工步骤，HostLift 默认不自动启动服务，建议在确认依赖、配置和数据后人工启动或用外部流程处理。drop-in、service env 文件和依赖摘要差异只生成审查项，避免盲目覆盖目标环境。systemd timer/socket、用户级 systemd unit、XDG autostart、SysV init 和 OpenRC 的文件迁移、enable/disable、verify/rollback 仍按原有受控路径执行；用户级 linger/start/session、复杂 timer/socket/autostart 差异仍保留为 `manual_step`。

## 推荐迁移批次

真实迁移不要一次执行全部模块。建议分批，每批都先 `--dry-run`，再 `--approve`。

| 批次 | 模块 | 目的 |
| --- | --- | --- |
| 1 | `packages,users` | 先补基础包、用户和组，减少后续 action 失败面 |
| 2 | `configs,ssh,home_configs,system_baseline` | 再审查系统配置、SSH、用户目录配置和系统基线 |
| 3 | `projects,appdata,resources` | 单独迁项目目录、应用数据和整机资源地图中的高风险复制项 |
| 4 | `services,cron,firewall,docker,network` | 最后处理启动项、定时任务、防火墙、容器和网络审查项 |
| 5 | 高风险 `manual_step` | 数据库 dump/restore、证书/密钥、存储、权限策略等逐项人工确认 |

预览某一批：

```bash
hostlift apply \
  --plan hostlift-plan.json \
  --include-module packages,configs,ssh,cron \
  --dry-run
```

执行某一批：

```bash
hostlift apply \
  --plan hostlift-plan.json \
  --source-host "$OLD" \
  --host "$NEW" \
  --operator "$OPERATOR" \
  --approval-ticket "$TICKET" \
  --audit-log ./hostlift-audit.jsonl \
  --include-module packages,configs,ssh,cron \
  --approve
```

如果这一批仍包含 `manual_step`，approved apply 会在任何 SSH 修改前返回 `UnsupportedApplyAction`。新生成的 `hostlift.plan.v2` 会为每个 manual action 提供 `hostlift.manual_task.v2`，包含 kind、provider、inputs、secret_refs、preconditions、expected_outputs、verify_probes、rollback_policy 和 evidence_schema；AI 可以按字段分发任务，不必用 description 判断任务类型。`script_reinstall` 已提供 install path/kind、source URL、version、checksum、config path 和 discovery hint，`resource_reinstall` 已提供 artifact path、SHA256、文件类型、静态动态依赖和 owner/mode/mtime，`appdata_restore` 已提供 engine、dump/restore command hint 和一致性要求。

人工任务完成后，AI 可以生成一份 `hostlift.manual_evidence.v1` JSON，并做本地只读校验：

```bash
hostlift evidence validate \
  --plan hostlift-plan.json \
  --evidence resources-reinstall-evidence.json \
  --summary
```

证据必须绑定原始 plan 文件的 SHA-256、action id、task kind 和 provider，并逐项覆盖 manual task 的 preconditions、expected outputs 和 verify probes。schema 只允许状态、观察时间及可选 SHA-256，不提供 stdout、命令文本或 secret 原值字段；未知字段会被拒绝。这个基础命令只做本地合同校验，不验签、不写 run-state，也不会让 approved apply 跳过 `manual_step`。AI 自报 `succeeded` 不能替代目标机复扫、业务健康验证或人工审查；自动批次仍需按 action id 排除人工步骤。

对于带受支持 probe 的 manual action，可以让 HostLift 在目标机执行固定只读检查并生成独占报告文件：

```bash
hostlift evidence probe \
  --plan hostlift-plan.json \
  --action services/check-status/nginx.service \
  --host "$NEW" \
  --output nginx-probe.json \
  --credential-provider ssh-agent \
  --summary
```

`hostlift.manual_probe_report.v1` 强绑定 plan SHA-256、action、task kind、provider、host、时间和逐项结果。当前执行器支持 `systemd`、`container`、`tcp` 和 `http`：systemd 使用 `systemctl is-active --quiet`；Docker/Podman 解析 `inspect` JSON 的 `State.Running`；TCP 使用固定 `nc -z -w 5`；HTTP 使用固定超时的 `curl --fail`。`command`、`log`、`manual_evidence` 以及非法 target 只会得到 `unsupported`/`error`，不会执行自由命令。自动 plan 首批只为 systemd 状态和 Docker/Podman 容器状态生成这些 probe。报告不保存 stdout、stderr 或命令正文；容器观察最多保存规范化布尔值的 SHA-256。`--output` 必填且拒绝覆盖，路径冲突会在 SSH 前失败。

AI 把 probe report 原始文件 SHA-256 和同一 `observed_at` 写入匹配的 evidence probe 后，再做联合校验：

```bash
hostlift evidence validate-probed \
  --plan hostlift-plan.json \
  --evidence nginx-evidence.json \
  --probe-report nginx-probe.json \
  --host "$NEW" \
  --summary
```

`validate-probed` 先运行原 evidence validator，再校验 report 原始 SHA-256、预期 host、plan/action/provider/task、executor、target、status 和观察时间。只有 evidence 自报 `passed`、缺 report、hash 不一致或 report 来自其它 host 都会失败。`trust_level: hostlift_remote_read_only` 表示报告合同来自 HostLift 的固定只读执行路径，不是密码学身份：报告仍是本地未签名文件，有写权限的人可以伪造整份 report/evidence。它不写 apply run-state/workload、不解除 `manual_step`，也不替代外部签名、可信时间戳、数据库一致性校验或请求级业务验证。

需要检查整份 plan 的人工任务是否都有且只有一份有效证据时，可重复传入 evidence；零份 evidence 也允许，用于列出全部缺失项：

```bash
hostlift evidence completeness \
  --plan hostlift-plan.json \
  --evidence resources-reinstall-evidence.json \
  --evidence database-restore-evidence.json
```

输出 `hostlift.manual_evidence.completeness.v1`，按 manual action 区分 `valid`、`missing`、`duplicate` 和 `invalid`，并列出指向非 manual/不存在 action 的 unexpected evidence。报告固定为 `trust_level: contract_only`：`contract_complete: true` 只说明本地证据文件覆盖完整且合同有效，不是验签、远程 probe 或业务成功证明。

校验通过后，可以把 evidence 文件的真实 SHA-256 登记到 plan-bound hash-chain ledger：

```bash
hostlift evidence record \
  --plan hostlift-plan.json \
  --evidence resources-reinstall-evidence.json \
  --ledger hostlift-manual-evidence.jsonl

hostlift evidence verify-ledger \
  --plan hostlift-plan.json \
  --ledger hostlift-manual-evidence.jsonl \
  --summary
```

`record` 会在打开 ledger 前重新严格解析 evidence、计算摘要并运行单文件 validator；随后持有独占文件锁，验证全部历史 hash chain、plan/task 绑定和 action 唯一性，才追加并立即 flush。`verify-ledger` 使用共享锁读取，避免与并发追加形成半条 JSONL。跨 plan 追加、同 action 重复登记或被篡改的历史链都会拒绝。ledger 不保存 evidence 正文或 secret；`valid` 表示链完整，`ledger_contract_complete` 表示 plan 的 manual action 都有登记。信任等级固定为 `hash_chain_only`，因为没有外部签名或时间戳锚定，整份文件仍可能被有写权限者重建；需要修正已登记 action 时应使用新的 ledger 文件，而不是覆盖或追加第二份同 action 记录。

v2 action 同时带 `phase` 和可选 `depends_on`。当前已为 Compose copy -> up -> verify、自定义 systemd unit install -> enable、用户 group -> user、用户级 systemd/SysV/OpenRC install -> enable 建立依赖边。`validate` 会拒绝缺失依赖、重复 ID、前向/循环依赖和阶段逆序；`plan`/`apply` 的 include/exclude 过滤如果拆断依赖闭包，也会在远程调用前失败。过滤器不会悄悄自动扩大选择范围，AI 必须显式提交完整依赖集合。

防火墙 reload 默认不开启。确实需要 reload 时，建议最后单独执行并保留已有 SSH 会话：

```bash
hostlift apply \
  --plan hostlift-plan.json \
  --host "$NEW" \
  --operator "$OPERATOR" \
  --approval-ticket "$TICKET" \
  --include-module firewall \
  --firewall-reload \
  --ssh-port 22 \
  --firewall-recovery-window 120 \
  --audit-log ./hostlift-audit.jsonl \
  --approve
```

## 选择性迁移

扫描阶段可以限制模块：

```bash
hostlift scan \
  --include-module services,cron,projects \
  --output source-runtime.json \
  --summary \
  --force
```

也可以跳过不需要的模块：

```bash
hostlift scan \
  --exclude-module appdata,projects,docker \
  --output source-light.json \
  --summary \
  --force
```

plan/apply 阶段按模块过滤：

```bash
hostlift apply \
  --plan hostlift-plan.json \
  --host "$NEW" \
  --include-module packages,configs,ssh \
  --approve
```

按 action id 前缀过滤：

```bash
hostlift apply \
  --plan hostlift-plan.json \
  --host "$NEW" \
  --include-action services/enable/nginx \
  --approve
```

常用模块名：

```text
packages
services
cron
users
ssh
sudoers
acl
configs
dev_env
home_configs
appdata
projects
processes
network
docker
firewall
resources
storage
system_baseline
security_policy
```

`resources` 用于整机迁移前的资源地图和选择性迁移。它会显示路径大小、磁盘占用、文件数、包管理器归属、文件类型、`readelf`/`objdump` 静态动态依赖摘要和发现证据；XDG 登录态等默认生成高风险复制动作，未被包管理器托管的 executable/install root 会进入复制或人工审查建议，缓存和运行时临时目录默认排除。`/usr/local/bin/tool`、`/opt/bin/tool`、`~/go/bin/tool`、`~/.cargo/bin/tool`、`~/.local/bin/tool` 这类常见 bin 目录直下的单文件 executable 默认生成 `resources/reinstall/<path>` 人工步骤，不会归并成整个父级 bin 目录；`/opt/myapp/bin/server`、`/usr/local/myapp/bin/tool` 这类明确应用根仍可归并为 install root，并同时保留 reinstall 审查提示。目标容量预检会按默认 copy 资源估算挂载点空间和 inode 风险，并对目标内存或 swap 明显小于源端的情况生成 `resources/capacity/<name>` 人工步骤；apply 执行递归复制前还会用实时 `du`、`find` 和目标 `df` 复核字节数与 inode。

`docker`、`sudoers`、`acl`、`security_policy`、`storage` 当前会从只读扫描事实生成 `manual_step` 人工审查项，但不会自动 apply。`validate` 会要求所有 `manual_step` 至少是 high 风险并且必须带确认标记。

## 定点文件传输

只想把一个文件或目录从控制机或旧机器传到新机器时，可以不用完整 scan/plan 流程。

本机到目标机器：

```bash
hostlift transfer \
  --host "$NEW" \
  --source /srv/app \
  --target /srv/app \
  --recursive \
  --transport rsync \
  --partial \
  --resume \
  --bwlimit 8192 \
  --approve
```

旧机器到新机器：

```bash
hostlift transfer \
  --source-host "$OLD" \
  --host "$NEW" \
  --source /srv/app \
  --target /srv/app \
  --recursive \
  --transport rsync \
  --partial \
  --bwlimit 8192 \
  --approve
```

远程源传输有两种模式：默认 `scp` 会由控制机使用 `scp -3` 中转；显式 `--transport rsync` 时，HostLift 会 SSH 到源机并在源机上执行 `rsync` 推送到目标机，减少控制机中转流量。这个模式不需要常驻 agent，但要求源机能 SSH 到目标机；preflight 会检查源机具备 `rsync` 和 `ssh`，并从源机执行 `ssh -o BatchMode=yes` 轻量探测目标机连通性。transfer plan 会输出 `remote_source_note` 提醒 `--identity-file` 只用于控制机连源机。`--source-host` 仍不支持和 `--transport chunk` 组合。

使用 chunk 后端传本机目录：

```bash
hostlift transfer \
  --host "$NEW" \
  --source /srv/app \
  --target /srv/app \
  --recursive \
  --transport chunk \
  --approve
```

当前 `chunk` 只支持本机源目录到目标目录的递归传输，不支持远程源、非递归、`--partial` 或 `--resume`。它会先比较源/目标 manifest 生成整文件 chunk index，只把目标缺失或内容变更的文件上传到目标机 staging 目录，再用远端 `rsync -a` 合并到目标路径。目标多余文件当前不会在 chunk 增量路径中删除；需要强一致清理时仍应走明确的审查和后续清理能力。

传输前写出 manifest：

```bash
hostlift transfer \
  --host "$NEW" \
  --source /srv/app \
  --target /srv/app \
  --recursive \
  --manifest-output app-manifest.json \
  --force
```

递归传输后校验远程 manifest：

```bash
hostlift transfer \
  --host "$NEW" \
  --source /srv/app \
  --target /srv/app \
  --recursive \
  --verify-remote-manifest \
  --approve
```

## 远程命令

`remote exec` 用结构化 argv 表达远程命令。没有 `--approve` 时只输出命令计划；带 `--approve` 才执行。

只生成计划：

```bash
hostlift remote exec \
  --host "$NEW" \
  -- systemctl status nginx
```

真实执行：

```bash
hostlift remote exec \
  --host "$NEW" \
  --identity-file ~/.ssh/hostlift_ed25519 \
  --timeout 30 \
  --retries 2 \
  --operation-id OPS-123/restart-nginx \
  --approve \
  -- systemctl restart nginx
```

使用 SSH agent：

```bash
hostlift remote exec \
  --host "$NEW" \
  --credential-provider ssh-agent \
  --approve \
  -- systemctl restart nginx
```

`--credential-provider` 和 `--identity-file` 不能同时使用。当前可执行 provider 是 `ssh-agent` 和 `env:<name>`；`env:<name>` 的环境变量值必须是 SSH identity file 路径。`vault:<path>` 是后续企业凭据托管接口预留，当前失败关闭。

高风险命令默认会被拒绝。确实需要执行 critical 命令时，必须显式加：

```bash
hostlift remote exec \
  --host "$NEW" \
  --approve \
  --allow-critical \
  -- systemctl reboot
```

## 本地 Manifest

生成本地文件树清单：

```bash
hostlift manifest \
  --path /srv/app \
  --output app-manifest.json \
  --max-entries 100000 \
  --force
```

用已有 manifest 校验目录：

```bash
hostlift manifest \
  --verify app-manifest.json \
  --path /srv/app
```

manifest 适合比对项目目录、静态资源和配置目录。数据库文件、消息队列和正在写入的数据目录仍需要业务级备份恢复流程。

## 策略、审批和主机授权

`--policy` 是本地执行前门禁，可以限制 plan hash、host、operator、模块、action 前缀、最大风险和审批票据。

示例：

```json
{
  "schema_version": "hostlift.policy.v1",
  "default": "allow",
  "allow_modules": ["packages", "configs", "ssh", "services"],
  "deny_modules": ["firewall"],
  "allow_hosts": ["root@192.0.2.20"],
  "allow_operators": ["ops/alice"],
  "max_risk": "high",
  "require_approval_ticket": true,
  "allow_approval_ticket_prefixes": ["OPS-"],
  "approval_scopes": [
    {
      "ticket_prefix": "OPS-",
      "hosts": ["root@192.0.2.20"],
      "operators": ["ops/alice"],
      "modules": ["packages", "services"],
      "action_prefixes": ["packages/install/", "services/enable/"],
      "max_risk": "medium"
    }
  ]
}
```

校验：

```bash
hostlift validate \
  --plan hostlift-plan.json \
  --policy hostlift-policy.json \
  --summary
```

带策略执行：

```bash
hostlift apply \
  --plan hostlift-plan.json \
  --host "$NEW" \
  --operator "$OPERATOR" \
  --approval-ticket "$TICKET" \
  --policy hostlift-policy.json \
  --approve
```

如果你已经有本地审批凭证 JSON，可以使用：

```bash
hostlift apply \
  --plan hostlift-plan.json \
  --host "$NEW" \
  --operator "$OPERATOR" \
  --approval-ticket "$TICKET" \
  --approval-receipt hostlift-approval.json \
  --approval-receipt-key-env HOSTLIFT_APPROVAL_HMAC_KEY \
  --approve
```

如果要把 operator 可以操作哪些主机单独拆出来，可以使用 `--host-authz`：

```json
{
  "schema_version": "hostlift.host_authz.v1",
  "rules": [
    {
      "operator": "ops/alice",
      "hosts": ["root@192.0.2.20"],
      "host_prefixes": ["admin@10.10."],
      "allow_all_hosts": false
    }
  ]
}
```

`policy`、`approval receipt` 和 `host-authz` 都是本地执行前约束，不认证真实用户身份，不能替代企业 RBAC、堡垒机、在线审批或资产授权系统。

## 审计和回滚

approved apply 和 approved rollback 会写审计事件。建议每批执行后立刻校验：

```bash
hostlift audit verify --log ./hostlift-audit.jsonl --summary
```

支持的审计输出：

```bash
--audit-log ./hostlift-audit.jsonl
--audit-sink file:./hostlift-audit.jsonl
--audit-sink syslog:local0
--audit-sink https://audit.example.test/v1/events
```

使用 syslog 或 HTTPS sink 时，建议同时写本地镜像：

```bash
hostlift apply \
  --plan hostlift-plan.json \
  --host "$NEW" \
  --operator "$OPERATOR" \
  --approval-ticket "$TICKET" \
  --audit-sink https://audit.example.test/v1/events \
  --audit-mirror-log ./hostlift-audit-mirror.jsonl \
  --approve
```

审计补发：

```bash
hostlift audit replay \
  --log ./hostlift-audit-mirror.jsonl \
  --audit-sink file:./hostlift-audit-replayed.jsonl \
  --summary
```

预览回滚：

```bash
hostlift rollback \
  --manifest hostlift-rollback.jsonl \
  --dry-run \
  --host "$NEW"
```

真实回滚：

```bash
hostlift rollback \
  --manifest hostlift-rollback.jsonl \
  --host "$NEW" \
  --operator "$OPERATOR" \
  --approval-ticket OPS-124 \
  --audit-log ./hostlift-audit.jsonl \
  --approve
```

当前 rollback 主要覆盖文件型备份恢复，以及部分命令型动作，例如包安装、用户/组创建、系统级和用户级 systemd enable、Docker Compose up。它不能替代整机快照。

PostgreSQL provider 的 rollback entry 是 `postgresql_manual_recovery`：它只保存目标 baseline artifact 路径和 SHA-256。approved rollback 会显示恢复证据并以 `ManualRollbackRequired` 失败关闭，因为把旧逻辑 dump 重新导入一个已经部分恢复的新集群，不能可靠删除新对象或重建事务级原状态。

## 扫描覆盖范围

当前 `scan` 会尽量采集：

- 主机、发行版、架构、内核和平台信息。
- 包管理器、显式安装包和 hold 包。
- systemd service 的 unit-file 状态、运行态和自定义 unit 路径，systemd timer 的 enabled 状态、被激活 unit、schedule 摘要和自定义 timer 路径，以及 systemd socket 的状态、被激活 unit 和自定义 socket 路径。
- 用户级 systemd unit，包括 `~/.config/systemd/user` 下的 `.service`、`.timer`、`.socket` 文件名、路径、类型和 enabled 状态。
- XDG autostart，包括 `/etc/xdg/autostart` 和用户 `~/.config/autostart` 下的 `.desktop` 文件名、路径、作用域和用户。
- SysV init，包括 `/etc/init.d` 脚本名、路径、是否启用和 `/etc/rc*.d/S*` runlevel 摘要。
- OpenRC，包括 `/etc/init.d` service 名、路径、是否启用和 `/etc/runlevels/*/<service>` runlevel 摘要。
- cron。
- 用户和组。
- SSH 配置和 authorized_keys。
- sudoers 主文件和 `/etc/sudoers.d` 片段元数据，不输出授权规则内容。
- 常见路径是否存在扩展 POSIX ACL，不输出 ACL 条目正文。
- SELinux 和 AppArmor 状态、配置路径存在性和 profile/policy 计数，不输出策略正文。
- 常见系统配置。
- 系统基线 scan-only 事实，包括 locale/timezone、NTP、sysctl、limits、PAM、LDAP/SSSD/Kerberos、DNS/NSS、静态网络配置、logrotate、profile.d、tmpfiles.d、NFS/autofs/exports、内核模块配置、证书/SSH/GPG 敏感材料存在性；其中 locale、timezone、sysctl、limits、NTP server/pool、resolv.conf、nsswitch、NFS exports 和 LVM/ZFS/Btrfs 命令输出会记录结构化摘要。
- `/etc/hosts` 条目、`timedatectl`/`locale`/`lsmod`/`vgs`/`lvs`/`zpool`/`zfs`/`btrfs`/`atq` 的只读事实统计，用于发现 LVM/ZFS/Btrfs、内核模块和 at jobs 等迁移风险。
- sshd_config 中影响认证和连通性的关键指令，例如 Port、ListenAddress、PermitRootLogin、PasswordAuthentication、PubkeyAuthentication、AllowUsers/Groups。
- 用户级 bin、语言运行时目录和用户级包管理器目录中的脚本/手工安装候选；会尽量提取 source URL、版本、checksum 和 config hint，默认只生成重新安装或人工审查建议，不复制缓存、二进制和凭据。
- home 目录配置。
- 项目目录和应用数据路径。
- 进程、监听端口、Docker/Podman 可用性、运行中容器、container image/volume/network 元数据、volume mountpoint 和常见 Compose 文件候选路径。
- 防火墙配置。
- `/etc/fstab` 和当前挂载点事实，不执行 mount/umount。

单个扫描模块失败时，HostLift 会保留其它模块结果，并在 `scan.warnings` 和摘要中报告。

## 安全默认值

- 真实修改必须加 `--approve`。
- approved apply 需要明确 `--host`。
- 文件复制动作涉及旧机器时，需要 `--source-host`。
- SSH host、path、argv token 和 identity file 会经过 `security` 边界校验。
- 凭据层只记录来源类型，不读取私钥内容，也不会把私钥路径写进审计日志。
- policy 拒绝、host-authz 拒绝、未声明 apply 支持、远程依赖缺失都会失败关闭。
- `manual_step` 只能作为 high/critical 风险的人工审查项存在，并且必须要求确认；plan v2 还要求完整的 `manual_task.v2` 机器合同。executor 不支持执行它。approved apply 会在任何远程副作用前校验全部所选 action，只要过滤结果中包含 `manual_step` 或其它 unsupported action 就整体失败关闭；用户需要用 module/action filter 把人工步骤分到独立批次。
- approved apply 会对全部未完成 action 做批量远程/模块 preflight，并验证过滤后的 DAG 依赖闭包。
- supported apply action 执行后会进入模块 verify。
- approved remote exec 会在执行前检查远端是否能找到 argv[0] 对应命令。
- approved transfer 会在执行前对需要的远程命令做预检。

这些默认值的目标是避免把 AI 建议、脚本误操作或错误 plan 直接变成远程破坏性执行。

## 当前边界

已经实现：

- 本地 scan、manifest、plan、validate、dry-run、approved apply。
- approved apply 在任何 backup/transfer/远程 mutation 前，对全部未完成所选 action 执行 support、依赖、源路径、目标冲突和递归容量/inode preflight；后序 action 失败不会让前序 action 提前修改目标机。
- migration run state 和安全续跑：唯一 run ID、hash-chain JSONL、独占锁、plan/host/选择集合/rollback 绑定、逐 action checkpoint、已成功 action 跳过和首次 rollback 预备复用。
- `hostlift.plan.v2` action phase/depends_on DAG、过滤闭包校验和运行时依赖成功门禁；旧 `hostlift.plan.v1` 仍可读取，但没有 v2 的完整结构保证。
- PostgreSQL 10+ 首个有状态 provider：双 opt-in 生成固定五步 DAG，执行 root/peer auth、同 major、停写观察、fresh target、容量和 artifact 独占 preflight；dump/baseline 为 `0600`，传输校验 SHA-256，restore 后比较 database/role catalog，rollback 只记录 hash-bound 人工恢复证据。
- 可信重装 provider：`plan --reinstall-recipes` 只转换精确匹配的 reinstall 人工项；recipe 绑定 HTTPS URL、精确大小、SHA-256、目标发行版/版本/架构、结构化 install/verify argv 和受管路径。approved apply 使用 source inventory hash 绑定的 `0700`/`0600` artifact，执行三步 DAG、全批次 preflight、最终复核和失败中间态 rollback 证据；不会执行 scanner URL hint 或 `curl | sh` 管道。
- `hostlift.manual_task.v2` 通用 AI 合同：manual action 结构化声明 kind/provider/inputs/secret refs/前置条件/期望输出/verify probe/rollback policy/evidence schema；三类 reinstall/appdata rich inputs 和 systemd/container probe provider 已接入，secret 合同仍在扩展。
- `script_reinstall`、`resource_reinstall` 和 `appdata_restore` 已把 scanner 中已有的来源/版本/checksum/配置、artifact 校验/ELF、dump/restore/consistency 事实保留为结构化 manual task inputs；validator 拒绝歧义 value/secret_ref、重复 input 名和空 secret ref。
- `hostlift evidence validate` 只读校验 `hostlift.manual_evidence.v1`：证据与原始 plan SHA-256、manual action、task kind/provider 强绑定，并要求前置条件、输出和探针合同精确覆盖；它不执行、授权或自动消费 manual action。
- `hostlift evidence completeness` 输出 plan 级 `hostlift.manual_evidence.completeness.v1`，失败关闭报告 missing/duplicate/invalid/unexpected evidence；信任级别固定为 `contract_only`，不会改变 run-state、workload 或 apply。
- `hostlift evidence record/verify-ledger` 提供 plan-bound `hostlift.manual_evidence.ledger.v1`：独占锁、追加前全链校验、同 action 唯一、逐记录 flush 和已登记/缺失 action 报告；`hash_chain_only` 不能替代签名身份、远程 probe 或业务 verify。
- `hostlift evidence probe/validate-probed` 提供 `hostlift.manual_probe_report.v1` 固定只读 SSH 探针和 report 文件 hash/host/合同联合校验；支持 systemd、Docker/Podman、TCP、HTTP，拒绝自由 command/log/manual evidence 执行，且不保存远程原始输出。
- plan v2 使用 action 级兼容门禁。全局 `compatibility.compatible` 只表示发行版、版本、已知包管理器和已知 CPU 架构全部相同，不再表示整份 plan 是否可执行。普通项目目录、非数据库应用数据、`home_configs`、用户/组和 authorized_keys 可在主机不完全兼容时继续规划；包安装要求包管理器相同；系统配置、cron、systemd/SysV/OpenRC 和防火墙动作要求发行版及版本相同；`resources` install root/未托管资源复制和容器 volume 复制要求架构相同。不满足要求的 builder 候选 action 会改写成 provider=`compatibility_review` 的结构化 `manual_step`，不会静默丢失，也不能由 approved apply 自动执行。
- validator 会拒绝 `compatible` 与四项事实不一致的 plan，并逐 action 拒绝手写的不安全 v2 plan；approved apply 在任何 SSH、backup、transfer、audit、run-state 或 rollback 文件创建前再次复用相同门禁。旧 plan v1 继续采用严格整机兼容规则。当前 action 级规则只解决粗粒度发行版/版本/包管理器/架构边界，尚未验证 ELF interpreter、glibc/musl、SONAME、目标动态库或容器镜像多架构可用性，因此跨架构仍不能自动复制未托管二进制。
- 按模块和 action 前缀选择性迁移。
- `hostlift plan --selection` 可输出按个人迁移批次分组的可勾选 action 清单，降低个人迁移时手写 include/exclude 的成本。
- `hostlift plan --health-report` 可从计划中的 service、network、container、Compose 和 firewall 检查项生成迁移后健康检查报告；它只输出清单，不执行远程探测，也不阻断 apply。
- `hostlift plan --workloads` 输出 `hostlift.workload_report.v1` JSON，聚合五类应用主体、组件、action、blocker、confidence、整机状态和未归属 action；扫描不完整或目标组件事实不足时失败关闭为 `unknown`，不输出伪精确百分比。
- SSH 私钥选择、SSH agent、env 凭据 provider、timeout、retry。
- scp/rsync 文件传输，rsync `--partial`、`--resume` 和带宽限制。
- 第一版 chunk staging 增量传输 adapter，以及文件粒度 chunk index diff 上传逻辑。
- 远程 manifest 探针和传输前依赖预检；`transfer --verify-remote-manifest` 可显式校验定点传输，approved apply 的 `copy_data_path`/`copy_project_path` 默认做未截断的源/目标内容 manifest 比较，覆盖普通文件、目录和符号链接目标，并在 special file 上失败关闭。
- 本地 policy、审批凭证和 host-authz 门禁。
- 本地 JSONL 审计、syslog/HTTPS sink、mirror log 和 replay。
- 文件型 rollback manifest、copy_data_path/copy_project_path 新建路径删除型 rollback entry，以及部分命令型 rollback；默认 manifest 路径带随机 run 后缀，也可用 `--rollback-manifest` 显式指定且拒绝覆盖已有文件，每条 entry 会立即 flush；删除型 rollback 会记录复制成功后的 `stat:v1:<bytes>:<file_count>:<mtime>` 基线，dry-run 会显示基线，执行前 bytes、file count 或 mtime 不匹配会失败关闭。
- 防火墙 reload 的 SSH 端口检查和 systemd-run 延迟恢复窗口。
- sudoers、ACL、SELinux/AppArmor、storage 的 scan-only 事实扫描和 plan 阶段 `manual_step` 人工审查项。
- `system_baseline` scan-only 事实扫描和 plan 阶段 `manual_step` 人工审查项；系统环境变量按敏感 key 和带 userinfo 的 URL value 写入固定 `[REDACTED]` 标记，普通 PATH/locale/runtime 值仍保留用于审查；PAM、DNS/NSS、SSSD/LDAP、sysctl、网络地址/路由、TLS/证书、GPG、SSH 私钥、脚本安装应用、系统环境变量、语言运行时目录和 at jobs 默认不自动迁移。`/etc/hosts` 条目差异会额外生成高风险 `configs/write//etc/hosts` 文件型动作，用户可选择复制或人工 merge。
- SSH host key 公钥指纹和私钥存在性摘要；差异会生成 `ssh/review-host-key/<type>`，让用户选择保留目标新 key 或复制源 key。
- `resources` 整机资源地图和计划动作：通用发现 app/data 根、home 状态、XDG 登录态、cache、package-managed executable、未被包管理器托管的 executable/install root；会主动扫描 `~/go/bin`、`~/.cargo/bin`、`~/.local/bin`、`~/.deno/bin`、`~/.bun/bin`、`~/.npm-global/bin`；登录态和 install root 可生成高风险 `resources/copy/<path>`，未托管 executable/install root 默认生成 `resources/reinstall/<path>` 人工步骤，只有显式固定 recipe 才转换为可信重装 DAG；目标容量风险会生成 `resources/capacity/<name>` 人工步骤，目标多余资源会生成 `resources/cleanup-review/<path>`，缓存和 `/tmp`、`/run` 等临时路径默认排除。
- systemd timer/socket 事实扫描；自定义且目标缺失的 timer/socket 可生成安装/启用动作，其它 timer/socket 差异会在 plan 阶段生成 `manual_step` 人工审查项，可用于审查“哪些定时启动项或 socket activation 会触发哪些 service/unit”。
- systemd service 运行态扫描；源端 active/reloading/activating 而目标端非 active-like 的 service 会生成 `services/review-start/<unit>` 和 `services/check-status/<unit>` 高风险人工步骤，HostLift 默认不生成可执行启动 action。
- 用户级 systemd unit 事实扫描；目标缺失的 unit 文件可生成 `copy_home_config` 文件型迁移动作，enabled 状态可生成 `enable_user_systemd_unit` 并复用 verify/rollback，会话启动、`linger` 和运行时环境语义仍保留人工审查。
- XDG autostart 事实扫描；目标缺失的 `.desktop` 文件可生成文件型迁移动作，复杂差异仍生成 `manual_step` 人工审查项，可用于审查桌面或用户会话登录后的自启动入口。
- SysV init 事实扫描；目标缺失的 `/etc/init.d` 脚本可生成 `write_file` 文件型迁移动作，runlevel 差异可通过 `chkconfig` 或 `update-rc.d` 生成 `enable_sysv_init`/`disable_sysv_init`，并复用 verify/rollback，不自动 `start/stop/restart`。
- OpenRC 事实扫描；目标缺失的 `/etc/init.d` service 脚本可生成 `write_file` 文件型迁移动作，runlevel 差异可生成 `enable_openrc_service`/`disable_openrc_service` 并复用 verify/rollback，不自动 `start`。
- Docker/Podman 容器运行时 scan-only 增量事实和 plan 阶段 `manual_step` 人工审查项，包括 runtime 可用性、container image/volume/network 元数据、volume mountpoint、运行中容器 mount 摘要和 Compose 文件候选路径；目标缺失的 network/container 会生成重建和健康检查提示，目标缺失的 volume 在能解析 mountpoint 时会额外生成 `docker/copy-volume/<name>` 或 `docker/copy-volume/podman/<name>` 高风险 `copy_data_path` 动作；如果运行中容器 mount source 精确引用该 volume name 或 mountpoint，会先生成 `docker/stop-writers/<volume>` 人工步骤。

尚未完成：

- action DAG 当前覆盖已知的 Compose、systemd、用户、SysV/OpenRC 生命周期边；更多跨模块/workload provider 依赖仍需补齐。过滤器会拒绝破坏依赖闭包，但不会自动补选依赖。
- run state 当前是单机文件型 ledger，能安全恢复同一 plan/host/选择集合的 supported action；尚未提供跨控制机协调、远程状态后端或数据库/cutover 事务恢复。
- inventory 的统一 secret redaction/secret reference；`system_baseline` 的敏感系统环境值已脱敏，但其它 inventory 字段还没有统一的敏感值分类和 `secret_ref` 合同。
- workload v1 还不是完整应用拓扑：当前只稳定聚合 systemd 服务、项目/Compose、应用数据路径、容器和未托管资源；包、用户、通用配置、secret、监听端口与服务之间的跨模块归属仍会作为未归属 action 或组件事实保留。
- workload v1 尚未消费 apply run-state、manual evidence、`manual_probe_report.v1` 或 rollback/cutover 状态；执行后必须重新 scan 目标机，不能把 `complete` 当成数据库内容一致、业务请求成功或低停机切换完成的证明。
- 密码 hash 迁移。
- sudoers、ACL、SELinux/AppArmor、storage 的自动 apply/rollback；当前只有人工审查计划项。
- systemd/SysV/OpenRC 的完整 `start/stop/restart` 生命周期和更多发行版 fixture；当前 systemd service 运行态差异只生成 `services/review-start/*` 和 `services/check-status/*` 人工步骤，SysV/OpenRC 仍只自动收敛 runlevel。
- Docker/Podman network 和运行中容器状态的自动迁移；当前只生成 network/container 重建和健康检查人工步骤，volume 数据可通过高风险 `copy_data_path` 动作复制 mountpoint，但需要先停止写入者或完成数据库/应用一致性备份。
- 任意发现脚本的自动重装：显式 HTTPS + size + SHA-256 recipe 已能执行受限重装，但 `resources`/`system_baseline.script_apps` 提取的 URL、版本或 checksum 仍只是 hint，HostLift 不能自动判断官方来源、验证发布签名、推导完整 managed paths 或回滚脚本的未声明副作用。
- 完整非文件副作用 rollback。
- 字节块级 chunk 强断点续传和远程到远程 chunk/agent 传输；当前 chunk 已支持文件粒度缺失/变更上传，rsync `--resume` 已适合作为个人迁移的大文件续传路径，远程源 rsync 已支持源机推目标机。
- 其它有状态服务 provider、低停机 cutover、事务级恢复、自动数据库 rollback、日志语义和请求内容级健康检查；PostgreSQL 仅支持显式停写、同 major、fresh target 的首个逻辑迁移切片，MySQL/Redis/MongoDB/Elasticsearch/RabbitMQ/Kafka 和 Docker 数据仍是 `appdata_restore` 人工任务。只读 probe 已支持严格 HTTP URL 的状态码检查，但自动 plan 尚未从监听端口/服务配置推导 HTTP/TCP target，也不检查响应正文。
- 多发行版集成测试矩阵。
- 完整 TUI/交互式多选界面；当前已有批次化 `plan --selection` 文本向导。

在线审批、RBAC、集中审计、Vault/短期凭据等仍可作为未来企业增强，但不属于当前个人服务器迁移主线。

## 给 AI 或自动化系统使用

推荐把 HostLift 当成“受控迁移执行器”：

1. AI 读取 `source-inventory.json`、`target-inventory.json`、`hostlift-plan.json`、`hostlift-workloads.json`、`validate` 输出和 `dry-run` 输出。
2. AI 给出迁移批次、模块过滤、风险说明和回滚建议。
3. 人工在本地确认 `--operator`、`--approval-ticket`、`--policy` 和 `--include-module`。
4. HostLift 执行真实 `apply --approve`、`transfer --approve`、`remote exec --approve` 或 `rollback --approve`。
5. `hostlift-audit.jsonl` 和 rollback manifest 保存到本地迁移目录，供后续核对或回滚使用。

不建议让 AI 绕过 HostLift 直接拼接 SSH shell 批量执行。

## 开发命令

统一检查：

```bash
scripts/check.sh
```

该脚本会运行：

```text
zig build test
zig build run -- help
scripts/smoke-fake-remote.sh
git diff --check
public function comment check
```

完整参数以帮助为准：

```bash
hostlift help
```
