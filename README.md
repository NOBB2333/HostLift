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
| [TECH_DESIGN_zh.md](TECH_DESIGN_zh.md) | 技术实现、代码设计思路、架构分层和模块扩展方式 |
| [ARCHITECTURE_zh.md](ARCHITECTURE_zh.md) | 当前源码目录和模块关系 |
| [CODE_QUALITY_zh.md](CODE_QUALITY_zh.md) | 代码质量、文件长度、企业级差距和重构建议 |
| [PRD_zh.md](PRD_zh.md) | 产品需求、市场需求和版本路线 |

## 当前状态

当前项目处于 v0.1 工程核心阶段，已经适合做：

- Linux 主机事实扫描。
- 源/目标 inventory 比较并生成迁移计划。
- 迁移计划校验、dry-run 审查和按模块/action 过滤执行。
- 部分包、服务、配置、SSH、cron、用户、项目目录、home 配置、应用数据和防火墙迁移。
- systemd service、systemd timer、systemd socket、用户级 systemd unit、XDG autostart、SysV init 和 OpenRC 的启动事实扫描；systemd service 会同时记录 unit-file 状态和运行态，源端运行中而目标端未运行的 service 会在 plan 阶段生成 high-risk `manual_step`，不自动 start；自定义 systemd timer/socket 缺失时可生成安装/启用动作，缺失的用户级 systemd unit、XDG autostart、SysV init 脚本和 OpenRC service 脚本可生成文件型迁移动作，enabled 用户级 systemd unit 可生成受控 `systemctl --user enable` 动作，SysV init 可通过 `chkconfig` 或 `update-rc.d` 生成 runlevel enable/disable 动作，OpenRC service 可生成受控 `rc-update add/del` 动作来补齐源端 runlevel 并清理目标多余 runlevel，其它不等价 timer/socket 和 autostart 差异会在 plan 阶段生成 `manual_step` 人工审查项。
- 指定 IP/路径的点对点文件传输。
- 受控远程命令执行。
- 本地 policy、审批票据、审批凭证、host 授权、审计日志和 rollback manifest。

已经实现的传输后端包括 `scp`、`rsync` 和第一版 `chunk` adapter。`chunk` 当前使用目标机 staging 目录加远端 `rsync` 落盘，并已把 chunk index diff 接入 approved 传输路径：本机源目录和目标目录会先构建 manifest/index，HostLift 只上传目标缺失或内容变更的文件，再用远端 `rsync -a` 合并。当前仍是“整文件 chunk”，还不是字节块级断点续传。

当前仍不应该宣称为完整企业平台。RBAC、集中凭据托管、在线审批、SIEM 级审计队列、多发行版矩阵、完整非文件 rollback 和真正 chunk 缺块续传仍是后续工作。

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
- 使用远程 manifest 校验时，远端需要 `find`、`stat` 和 `sha256sum`。
- 使用 `chunk` 后端时，目标机需要 `mkdir`、`rsync`、`find`、`stat` 和 `sha256sum`。
- 使用 SysV init runlevel 自动收敛时，目标机需要 `chkconfig` 或 `update-rc.d`；两者都没有时会在 preflight 阶段失败关闭。
- 使用 OpenRC runlevel 自动收敛时，目标机需要 `rc-update`。
- 正式迁移前仍应准备云盘快照、系统快照或其它整机备份。

HostLift 的 rollback manifest 是动作级补偿记录，不能替代整机快照、数据库备份或业务恢复方案。

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
5. 按模块分批 apply --approve，每批都写 audit log 和 rollback manifest
6. 每批执行后 audit verify，必要时 rollback
```

完整迁移时建议把每一次执行都绑定到操作者、工单号和审计日志：

```bash
hostlift apply \
  --plan hostlift-plan.json \
  --source-host "$OLD" \
  --host "$NEW" \
  --operator "$OPERATOR" \
  --approval-ticket "$TICKET" \
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
  --audit-log ./hostlift-audit.jsonl \
  --approve
```

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
| 校验计划 | `hostlift validate --plan hostlift-plan.json --summary` |
| 预览执行 | `hostlift apply --plan hostlift-plan.json --dry-run` |
| 批量执行指定模块 | `hostlift apply --plan hostlift-plan.json --host "$NEW" --include-module packages,configs,ssh --approve` |
| 直接传目录 | `hostlift transfer --host "$NEW" --source /srv/app --target /srv/app --recursive --transport rsync --approve` |
| 直接执行远程命令 | `hostlift remote exec --host "$NEW" --approve -- systemctl status nginx` |
| 校验审计链 | `hostlift audit verify --log ./hostlift-audit.jsonl --summary` |
| 预览回滚 | `hostlift rollback --manifest hostlift-rollback.jsonl --dry-run --host "$NEW"` |

要重点查看“这台机器有哪些启动项、定时任务、用户会话服务和后台项目”，优先跑：

```bash
hostlift scan --include-module services,cron,users,projects,processes,network,docker --output runtime.json --summary --force
```

摘要会列出 systemd service、systemd timer、systemd socket、用户级 systemd unit、XDG autostart、SysV init、OpenRC、cron 来源、项目目录、进程摘要、监听端口和容器事实。systemd service 会记录 unit-file 状态、active/reloading/activating/inactive/failed 等运行态和自定义路径；源端 active-like 而目标端不是 active-like 的 service 会生成 `services/review-runtime/<unit>` high-risk `manual_step`，供人工决定是否启动目标服务。systemd timer 会记录被激活 unit、schedule、enabled 状态和自定义路径；systemd socket 会记录状态、被激活 unit 和自定义路径。用户级 systemd unit 当前只扫描 `~/.config/systemd/user` 下的 `.service`、`.timer`、`.socket` 文件名、路径、类型和 enabled 状态，不读取 unit 文件正文。XDG autostart 只扫描 `/etc/xdg/autostart` 和用户 `~/.config/autostart` 下的 `.desktop` 文件名、路径、作用域和用户，不读取 `.desktop` 正文。SysV init 只扫描 `/etc/init.d` 脚本名、路径、是否启用和 `/etc/rc*.d/S*` runlevel 摘要，不读取脚本正文。OpenRC 只扫描 `/etc/init.d` service 名、路径、是否启用和 `/etc/runlevels/*/<service>` runlevel 摘要，不读取脚本正文。自定义且目标缺失的 systemd timer/socket 会在 plan 中生成 `install_systemd_unit`，enabled timer/socket 会生成 `enable_systemd_unit`；目标缺失的用户级 systemd unit 和 XDG autostart 会生成文件型 action，用户级路径走 `copy_home_config` 并修复权限，系统级 XDG autostart 走 `write_file`；目标缺失的 SysV/OpenRC `/etc/init.d` 脚本会生成 `write_file` 文件型 action，复用文件备份、传输、verify 和 rollback；SysV init 会根据源/目标 runlevel 差异生成 `enable_sysv_init` 和 `disable_sysv_init`，subject 形如 `<service>:2,3,5`，执行时优先使用 `chkconfig --level 235 <service> on/off`，否则使用 `update-rc.d <service> enable/disable 2 3 5`，verify 分别解析 `chkconfig --list <service>` 或 `/etc/rcN.d` 目录中的 `S??<service>` 链接，rollback 做反向 enable/disable；OpenRC service 会根据源/目标 runlevel 差异生成 `enable_openrc_service` 和 `disable_openrc_service`，分别执行 `rc-update add/del <service> <runlevel>`，verify 检查 `/etc/runlevels/<runlevel>/<service>` 是否存在或缺失，rollback 做反向 add/del；enabled 用户级 systemd unit 会生成 `enable_user_systemd_unit`，执行时通过 `runuser -u <user> -- systemctl --user enable <unit>` 启用，并通过 `systemctl --user is-enabled` verify、rollback 时 disable；需要人工判断的 service 运行态、timer/socket/autostart 启用差异和用户级 linger/start/session 语义，会在 plan 中变成 high-risk `manual_step`，供人工选择和审查。

## 推荐迁移批次

真实迁移不要一次执行全部模块。建议分批，每批都先 `--dry-run`，再 `--approve`。

| 批次 | 模块 | 目的 |
| --- | --- | --- |
| 1 | `packages,configs,ssh,cron` | 先补基础环境和访问能力 |
| 2 | `users,services,projects,home_configs` | 再迁用户、服务、项目和用户目录配置 |
| 3 | `appdata` | 单独处理较大的业务数据目录 |
| 4 | `firewall` | 最后处理防火墙，并保留恢复通道 |

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
configs
ssh
sudoers
acl
security_policy
cron
services
projects
home_configs
appdata
firewall
users
storage
network
docker
```

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
  --bwlimit 8192 \
  --approve
```

当前远程源传输由控制机编排，使用 `scp -3`。`--source-host` 暂不支持和 `--transport rsync` 或 `--transport chunk` 组合。

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

如果审批系统能导出本地审批凭证，可以使用：

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
- Rustup、NVM、Mojo、Linuxbrew、飞书/Lark CLI 等脚本安装应用候选；默认只生成重新安装或人工审查建议，不复制缓存、二进制和凭据。
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
- `manual_step` 只能作为 high/critical 风险的人工审查项存在，并且必须要求确认；它不会进入自动 apply。
- approved apply 会做 action 级远程依赖预检。
- supported apply action 执行后会进入模块 verify。
- approved remote exec 会在执行前检查远端是否能找到 argv[0] 对应命令。
- approved transfer 会在执行前对需要的远程命令做预检。

这些默认值的目标是避免把 AI 建议、脚本误操作或错误 plan 直接变成远程破坏性执行。

## 当前边界

已经实现：

- 本地 scan、manifest、plan、validate、dry-run、approved apply。
- 按模块和 action 前缀选择性迁移。
- SSH 私钥选择、SSH agent、env 凭据 provider、timeout、retry。
- scp/rsync 文件传输，rsync `--partial`、`--resume` 和带宽限制。
- 第一版 chunk staging 增量传输 adapter，以及文件粒度 chunk index diff 上传逻辑。
- 远程 manifest 探针、传输前远程依赖预检和递归传输后校验。
- 本地 policy、审批凭证和 host-authz 门禁。
- 本地 JSONL 审计、syslog/HTTPS sink、mirror log 和 replay。
- 文件型 rollback manifest 和部分命令型 rollback。
- 防火墙 reload 的 SSH 端口检查和 systemd-run 延迟恢复窗口。
- sudoers、ACL、SELinux/AppArmor、storage 的 scan-only 事实扫描和 plan 阶段 `manual_step` 人工审查项。
- `system_baseline` scan-only 事实扫描和 plan 阶段 `manual_step` 人工审查项；PAM、DNS/NSS、SSSD/LDAP、sysctl、静态 IP、证书、GPG、SSH 私钥、脚本安装应用和 at jobs 默认不自动迁移。`/etc/hosts` 条目差异会额外生成高风险 `configs/write//etc/hosts` 文件型动作，用户可选择复制或人工 merge。
- systemd timer/socket 事实扫描；自定义且目标缺失的 timer/socket 可生成安装/启用动作，其它 timer/socket 差异会在 plan 阶段生成 `manual_step` 人工审查项，可用于审查“哪些定时启动项或 socket activation 会触发哪些 service/unit”。
- systemd service 运行态扫描；源端 active/reloading/activating 而目标端非 active-like 的 service 会生成 `services/review-runtime/<unit>` high-risk `manual_step`，不会自动 `start/restart`。
- 用户级 systemd unit 事实扫描；目标缺失的 unit 文件可生成 `copy_home_config` 文件型迁移动作，enabled 状态可生成 `enable_user_systemd_unit` 并复用 verify/rollback，会话启动、`linger` 和运行时环境语义仍保留人工审查。
- XDG autostart 事实扫描；目标缺失的 `.desktop` 文件可生成文件型迁移动作，复杂差异仍生成 `manual_step` 人工审查项，可用于审查桌面或用户会话登录后的自启动入口。
- SysV init 事实扫描；目标缺失的 `/etc/init.d` 脚本可生成 `write_file` 文件型迁移动作，runlevel 差异可通过 `chkconfig` 或 `update-rc.d` 生成 `enable_sysv_init`/`disable_sysv_init`，并复用 verify/rollback，不自动 `start/stop/restart`。
- OpenRC 事实扫描；目标缺失的 `/etc/init.d` service 脚本可生成 `write_file` 文件型迁移动作，runlevel 差异可生成 `enable_openrc_service`/`disable_openrc_service` 并复用 verify/rollback，不自动 `start`。
- Docker/Podman 容器运行时 scan-only 增量事实和 plan 阶段 `manual_step` 人工审查项，包括 runtime 可用性、container image/volume/network 元数据、volume mountpoint、运行中容器和 Compose 文件候选路径；目标缺失的 volume 在能解析 mountpoint 时会额外生成 `docker/copy-volume/<name>` 或 `docker/copy-volume/podman/<name>` 高风险 `copy_data_path` 动作，可按 action 前缀选择执行。

尚未完成：

- 密码 hash 迁移。
- sudoers、ACL、SELinux/AppArmor、storage 的自动 apply/rollback；当前只有人工审查计划项。
- systemd/SysV/OpenRC 的自动 `start/stop/restart` 和更多发行版 fixture；当前 systemd service 只扫描运行态并对运行态差异生成人工审查项，不自动启动目标服务。SysV 支持 `chkconfig` 和 `update-rc.d` 两类 provider 收敛 runlevel 并复用 verify/rollback，OpenRC 只支持目标缺失时复制 `/etc/init.d` 脚本、用 `rc-update add/del` 收敛 runlevel 并复用 verify/rollback。用户级 systemd unit 当前支持目标缺失时复制 unit 文件、enabled 时执行 `systemctl --user enable` 并复用 verify/rollback，但不会自动 `start`、不会自动配置 `linger`，复杂会话语义仍是人工审查项；XDG autostart 当前只支持目标缺失时复制 `.desktop` 文件并复用文件型 verify/rollback，复杂差异仍是人工审查项；systemd timer/socket 当前只支持自定义 unit 缺失时安装/启用，并复用 systemd unit verify/rollback，其它 timer/socket 差异仍是人工审查项。
- Docker/Podman network 和运行中容器状态的自动迁移；volume 数据当前可通过高风险 `copy_data_path` 动作复制 mountpoint，但需要先停止写入者或完成数据库/应用一致性备份。
- 脚本安装应用的可信来源 URL、版本、校验和和自动 reinstall provider；当前只识别常见痕迹并生成 `manual_step`。
- merge-aware 配置更新。
- 完整非文件副作用 rollback。
- 字节块级 chunk 强断点续传、目标多余文件安全清理和远程到远程 chunk/P2P 传输；当前 chunk 已支持文件粒度缺失/变更上传。
- 集中审计、RBAC、在线审批、凭据托管和短期凭据。
- 多发行版集成测试矩阵。
- TUI、Web/API 控制面和实时同步。

## 给 AI 或自动化系统使用

推荐把 HostLift 当成“受控迁移执行器”：

1. AI 读取 `source-inventory.json`、`target-inventory.json`、`hostlift-plan.json`、`validate` 输出和 `dry-run` 输出。
2. AI 给出迁移批次、模块过滤、风险说明和回滚建议。
3. 人工或审批系统确认 `--operator`、`--approval-ticket`、`--policy` 和 `--include-module`。
4. HostLift 执行真实 `apply --approve`、`transfer --approve`、`remote exec --approve` 或 `rollback --approve`。
5. `hostlift-audit.jsonl` 和 rollback manifest 回写到工单系统。

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
