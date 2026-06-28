# HostLift 使用指南

本文档面向实际执行 Linux 主机迁移的运维人员。安装和技术架构见 [README.md](../README.md)。

## 环境要求

| 角色 | 要求 |
|---|---|
| 控制机 | 能 SSH 到旧机器和新机器；安装 HostLift 二进制 |
| 旧机器 | 能运行 HostLift 二进制（musl 静态链接，无需额外依赖） |
| 新机器 | 同上；迁移系统配置通常需要 root 权限 |
| 传输 | `rsync` 后端需本机和目标机安装 rsync；`source-host + rsync` 还要求旧机器能免交互 SSH 到新机器；`chunk` 后端还需 `find`、`stat`、`sha256sum` |

## 典型迁移流程

```text
旧机器 scan → 新机器 scan → 控制机 plan → validate → dry-run → 分批 apply → audit verify
```

### 第一步：扫描

在旧机器和新机器上分别执行：

```bash
hostlift scan --output /root/inventory.json --summary --force
```

将两个 inventory 文件拷贝到控制机。

### 第二步：生成计划

```bash
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --output hostlift-plan.json \
  --summary --force
```

需要先挑选动作时，可以生成按个人迁移批次分组的文本清单：

```bash
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --selection
```

需要迁移后逐项核对服务、端口、容器和防火墙时，可以生成健康检查报告：

```bash
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --health-report
```

`--selection` 和 `--health-report` 都只输出本地报告，不连接远程主机，也不是企业审批或重型健康门禁。

### 第三步：审查

```bash
hostlift validate --plan hostlift-plan.json --summary
hostlift apply --plan hostlift-plan.json --dry-run
```

`dry-run` 会列出所有待执行 action 及其风险等级，不修改目标机器。

### 第四步：分批执行

建议按批次迁移，每批都独立审计：

```bash
# 第一批：基础包和用户
hostlift apply --plan hostlift-plan.json \
  --host root@NEW --operator ops/alice --approval-ticket OPS-001 \
  --include-module packages,users \
  --audit-log ./batch1-audit.jsonl --approve

# 第二批：配置和 home 状态
hostlift apply --plan hostlift-plan.json \
  --host root@NEW --operator ops/alice --approval-ticket OPS-002 \
  --include-module configs,ssh,home_configs,system_baseline \
  --audit-log ./batch2-audit.jsonl --approve

# 第三批：项目、应用数据和资源地图
hostlift apply --plan hostlift-plan.json \
  --host root@NEW --operator ops/alice --approval-ticket OPS-003 \
  --include-module projects,appdata,resources \
  --audit-log ./batch3-audit.jsonl --approve

# 第四批：服务、定时任务、容器、网络和防火墙
hostlift apply --plan hostlift-plan.json \
  --host root@NEW --operator ops/alice --approval-ticket OPS-004 \
  --include-module services,cron,docker,network,firewall \
  --firewall-reload --ssh-port 22 --firewall-recovery-window 120 \
  --audit-log ./batch4-audit.jsonl --approve
```

### 第五步：验证

```bash
hostlift audit verify --log ./batch1-audit.jsonl --summary
hostlift audit verify --log ./batch2-audit.jsonl --summary
```

## 三种使用模式

| 模式 | 命令 | 适用场景 |
|---|---|---|
| 规划式迁移 | `scan` → `plan` → `apply` | 完整服务器迁移 |
| 定点传输 | `transfer --source ... --target ...` | 已知源/目标路径，传单个目录 |
| 远程命令 | `remote exec -- ...` | 在目标机执行单条命令 |

### 定点传输示例

```bash
# rsync 带断点续传和带宽限制
hostlift transfer --host root@NEW \
  --source /srv/app --target /srv/app \
  --recursive --transport rsync --partial --resume --bwlimit 8192 \
  --approve

# 远程源直接推目标机，避免控制机中转大流量
hostlift transfer --source-host root@OLD --host root@NEW \
  --source /srv/app --target /srv/app \
  --recursive --transport rsync --partial --resume --approve

# chunk 增量传输（只传变更文件）
hostlift transfer --host root@NEW \
  --source /srv/app --target /srv/app \
  --recursive --transport chunk --approve
```

`source-host + rsync` 会先由控制机 SSH 到旧机器，再让旧机器执行 rsync 推送到新机器。`--identity-file` 只用于控制机连接旧机器；旧机器连接新机器需要旧机器本地 SSH 配置、agent 或默认密钥可用。preflight 会检查旧机器具备 `rsync` 和 `ssh`，并从旧机器执行 `ssh -o BatchMode=yes` 轻量探测新机器连通性；transfer plan 会带 `remote_source_note` 提醒这个身份语义。

### 远程命令示例

```bash
# 只预览不执行
hostlift remote exec --host root@NEW -- systemctl status nginx

# 真实执行
hostlift remote exec --host root@NEW \
  --timeout 30 --retries 2 --approve -- systemctl restart nginx
```

## 回滚

每批 apply 会自动生成 rollback manifest。需要回滚时：

```bash
# 预览
hostlift rollback --manifest hostlift-rollback.jsonl --dry-run --host root@NEW

# 执行
hostlift rollback --manifest hostlift-rollback.jsonl \
  --host root@NEW --operator ops/alice --approval-ticket OPS-100 \
  --audit-log ./rollback-audit.jsonl --approve
```

当前 rollback 覆盖：文件备份恢复、包卸载、用户/组删除、systemd/unit disable/stop、Docker Compose down，以及 HostLift 新建数据路径的删除型回滚。删除型回滚会删除整个新建目标路径；如果 apply 之后业务或用户又往该路径写了新数据，这些新数据也会被删除。rollback 不能替代整机快照。

## 策略和审批

### 本地策略文件

限制可执行的模块、主机、操作者和风险等级：

```json
{
  "schema_version": "hostlift.policy.v1",
  "default": "allow",
  "allow_modules": ["packages", "configs", "ssh", "services"],
  "deny_modules": ["firewall"],
  "allow_hosts": ["root@192.0.2.20"],
  "allow_operators": ["ops/alice"],
  "max_risk": "high",
  "require_approval_ticket": true
}
```

使用：`--policy hostlift-policy.json`

### 主机授权文件

限制操作者可以操作哪些主机：

```json
{
  "schema_version": "hostlift.host_authz.v1",
  "rules": [
    { "operator": "ops/alice", "hosts": ["root@192.0.2.20"] }
  ]
}
```

使用：`--host-authz hostlift-host-authz.json`

### 审批凭证

读取本地 HMAC-SHA256 审批凭证：

```bash
--approval-receipt hostlift-approval.json \
--approval-receipt-key-env HOSTLIFT_APPROVAL_HMAC_KEY
```

## 审计

```bash
# 校验审计链完整性
hostlift audit verify --log ./hostlift-audit.jsonl --summary

# 补发到另一个 sink
hostlift audit replay --log ./hostlift-audit.jsonl \
  --audit-sink https://audit.example.test/v1/events --summary

# 双写：本地 + 远程
--audit-sink https://audit.example.test/v1/events \
--audit-mirror-log ./hostlift-audit-mirror.jsonl
```

## 凭据管理

| 方式 | 用法 | 说明 |
|---|---|---|
| 默认 SSH | 不指定 | 使用系统 ssh-agent 或默认密钥 |
| 指定密钥 | `--identity-file ~/.ssh/key` | 指定 SSH 私钥路径 |
| SSH agent | `--credential-provider ssh-agent` | 使用 ssh-agent |
| 环境变量 | `--credential-provider env:MY_KEY` | 环境变量值为密钥路径 |

`--identity-file` 和 `--credential-provider` 不能同时使用。

## 扫描覆盖

`scan` 采集 20 个模块的事实：

| 类别 | 模块 | 说明 |
|---|---|---|
| 基础 | packages, users, ssh, configs, cron | 包、用户、SSH、配置、定时任务 |
| 服务 | services | systemd/OpenRC/SysV/XDG/user systemd |
| 项目 | projects, appdata, home_configs, resources | 项目目录、应用数据、用户配置、整机资源地图 |
| 容器 | docker | Docker/Podman 容器/卷/网络/镜像/Compose |
| 安全 | sudoers, acl, security_policy, firewall | sudo、ACL、SELinux/AppArmor、防火墙 |
| 基线 | system_baseline, storage, network, processes, dev_env | locale/sysctl/limits/NTP/DNS/NFS/LVM/ZFS/Btrfs、挂载、端口、进程、开发工具 |

system_baseline 会解析实际配置值（不仅是路径存在性），包括 locale、timezone、sysctl 参数、limits 条目、NTP server/pool、resolv.conf nameserver、nsswitch 查找链、NFS exports、LVM/ZFS/Btrfs 命令输出。resources 会生成整机资源地图，覆盖通用应用根、XDG 登录态、用户级 bin、未托管 executable/install root、大小/占用/文件数、包归属、文件类型和动态链接摘要。

## 操作控制

| 选项 | 说明 |
|---|---|
| `--cancel-file /tmp/cancel` | 创建此文件可取消正在执行的远程操作 |
| `--operation-id OPS-123/step1` | 关联本地迁移批次、脚本或外部记录的操作 ID |
| `--operation-state ./state.jsonl` | 记录操作状态事件（JSONL） |
| `--remote-timeout 60` | SSH 命令超时秒数 |
| `--remote-retries 3` | SSH 命令重试次数（最大 5） |
| `--allow-critical` | 显式允许执行 critical 风险命令 |

## 安全默认值

- 不加 `--approve` 不执行任何修改
- SSH host/path/token 全部经白名单校验
- 凭据不读入进程内存，不写入审计日志
- 未知能力默认拒绝（fail-closed）
- `manual_step` 只作为 high/critical 审查项，不自动执行
- 防火墙 reload 前检查 SSH 端口防止锁死
- Policy deny 始终优先于 allow

## 故障处理

| 场景 | 处理方式 |
|---|---|
| apply 中途失败 | 检查 audit log，用 rollback manifest 回滚已执行动作 |
| 防火墙锁死 | systemd-run 恢复窗口会自动回退（`--firewall-recovery-window`） |
| SSH 连接超时 | 调大 `--remote-timeout`，检查网络和 SSH 配置 |
| 包安装失败 | 检查目标机包管理器状态，可能需要手动修复依赖 |
| 用户 UID 冲突 | plan 阶段会生成 `manual_step`，需人工决定处理方式 |
| 大目录传输慢 | 使用 `--transport rsync --bwlimit` 限速，或 `--transport chunk` 增量传输 |
