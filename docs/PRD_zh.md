# HostLift - 产品需求文档

## 1. 产品定义

### 1.1 名称

**HostLift**

HostLift 是一个专注的 Linux 服务器迁移工具。它将一台主机的可恢复状态提取出来，应用到另一台运行相同 Linux 发行版和版本的主机上。

### 1.2 一句话描述

一个用 Zig 编写的单二进制 Linux 服务器迁移工具，设计用于将应用程序、包、配置、用户、服务、定时任务和选定数据从即将到期的服务器迁移到运行相同 Linux 发行版版本的新服务器。

### 1.3 主要场景

第一个支持的场景是：

```
- 源服务器即将到期或退役
- 目标服务器是新配置的
- 两台服务器运行相同的 Linux 发行版系列和版本
  例如: Ubuntu 24.04 -> Ubuntu 24.04
        Debian 12 -> Debian 12
        Rocky Linux 9 -> Rocky Linux 9
- CPU 架构可以相同或不同，但不会盲目复制架构相关的工件
- 用户希望迁移实际的服务器状态，而不是克隆磁盘镜像
```

### 1.4 目标用户

```
- 从一个提供商迁移到另一个提供商的 VPS 和云服务器用户
- 处理中小型服务器迁移的 Linux 管理员
- 维护个人或团队服务器的开发人员
- 需要为非 Kubernetes 主机提供可审计、交互式迁移助手的 DevOps 工程师
```

### 1.5 产品定位

HostLift 不是磁盘克隆工具，也不是实时同步系统。它是一个引导式迁移工具：

```
- 扫描源主机和目标主机
- 构建可审计的迁移计划
- 对有风险、主机绑定或架构绑定的项目发出警告
- 在目标主机上应用已批准的更改
- 验证结果并在技术上可行时记录回滚数据
```

### 1.6 核心价值

```
相同版本迁移优先: 通过要求目标主机运行相同的发行版和版本来减少包和配置的歧义
变更前先规划:     用户在目标进行任何更改之前可以看到将添加、更改、跳过或标记为手动处理的内容
风险感知迁移:     每个项目都有风险和兼容性分类
选择性迁移:       用户选择模块和单个项目，而不是复制整个系统
P2P 传输:        直接从源到目标传输，无第三方存储依赖
单二进制文件:     编译的 Zig 二进制文件，易于复制到两台机器
```

## 2. 范围

### 2.1 v1 范围内支持

HostLift 支持在匹配的两台 Linux 主机之间进行一次性迁移：

```
匹配条件:
  - 发行版 ID (例如: ubuntu, debian, rocky, fedora)
  - 发行版主/次版本 (例如: 24.04, 12, 9)
  - 包管理器系列 (例如: apt, dnf, yum, pacman, zypper)
```

架构差异仅允许用于安全的项目类别：

```
- 文本配置
- 可以从目标仓库重新安装的包意图
- 不引用源专用二进制路径的服务定义
- 通过兼容性检查的脚本
```

### 2.2 v1 明确排除的范围

```
- 跨发行版自动迁移 (例如: Ubuntu -> Rocky Linux)
- 跨版本自动迁移 (例如: Ubuntu 20.04 -> Ubuntu 24.04)
- 完整磁盘克隆
- 实时同步或持续备份
- 自动数据库数据迁移
- 云提供商身份、元数据或网络的自动迁移
- 内核、引导加载程序、RAID、LVM 和低级存储布局的自动迁移
- 容器运行时实时迁移
- Windows 和 macOS 支持
```

### 2.3 未来范围

未来版本可能添加：

```
- 带有兼容性配置文件的跨版本迁移
- 跨发行版包映射
- 内置数据库转储和恢复钩子
- 特定提供商的云迁移助手
- 带有中继服务的远程代理模式
```

## 3. 迁移模型

### 3.1 状态类别

每个发现的项目必须分类到以下类别之一：

| 类别 | 含义 | 默认行为 |
|---|---|---|
| `safe` | 通常可以直接应用的文本或声明式状态 | 默认选中 |
| `review` | 可能正确，但需要用户确认 | 显示但默认不选中 |
| `rebuild` | 应在目标上重新创建，而非直接复制 | 生成重建指令 |
| `manual` | 过于主机特定或有风险，不适合自动处理 | 仅报告 |
| `unsupported` | HostLift 不处理 | 仅报告 |

### 3.2 兼容性标签

每个迁移项目可能包含：

```
same_distro_required     需要相同发行版
same_version_required    需要相同版本
arch_independent         架构无关
arch_dependent           架构相关
host_identity_bound      绑定主机身份
cloud_provider_bound     绑定云提供商
hardware_bound           绑定硬件
secret                   包含秘密
requires_service_stop    需要停止服务
rollback_supported       支持回滚
rollback_partial         部分支持回滚
rollback_unsupported     不支持回滚
```

### 3.3 迁移阶段

HostLift 在明确的阶段中运行：

```
1. 扫描源:   收集源清单
2. 扫描目标: 收集目标清单
3. 预检:     验证操作系统、包管理器、架构、磁盘空间、权限和必需命令
4. 计划:     生成包含操作和警告的迁移计划
5. 审查:     用户批准模块和项目级别的有风险操作
6. 准备:     在可能的情况下创建回滚快照
7. 应用:     在目标上执行已批准的操作
8. 验证:     运行模块特定的验证检查
9. 报告:     写入摘要、日志、未解决项目和回滚元数据
```

在用户批准计划之前不会进行任何变更。

## 4. 功能需求

### 4.1 模块概览

| 模块 | 默认状态 | v1 处理方式 |
|---|---:|---|
| 包 (Packages) | 开启 | 使用相同包管理器重新安装包意图 |
| 服务 (Services) | 开启 | 迁移自定义 systemd 单元和启用状态；扫描 drop-in、service env 文件和运行态，必要时生成 start/status 审查动作 |
| 定时任务 (Cron) | 开启 | 迁移用户和系统定时任务条目；anacron 和 at jobs 默认只审查不 replay |
| 用户 (Users) | 开启 | 添加非系统用户/组并进行冲突检查 |
| SSH | 开启 | 迁移 `authorized_keys`；私钥默认关闭 |
| 配置 (Configs) | 开启 | 迁移选定的 `/etc` 配置路径 |
| 主目录配置 (Home Configs) | 开启 | 迁移 root 和非系统用户的精选 dotfile/XDG 配置路径 |
| 应用数据 (App Data) | 关闭 | 复制选定的数据路径并有大小限制 |
| 整机资源 (Resources) | 审查模式 | 生成资源地图，展示路径大小、磁盘占用、文件数、包归属、文件类型、静态动态依赖摘要、证据、敏感等级和默认动作；通用识别未被包管理器托管的脚本/手工安装 executable/install root，主动扫描用户级 bin，并生成 reinstall 和容量风险人工步骤 |
| Web 根目录 (Web Roots) | 关闭 | 复制选定的 `/var/www` 路径 |
| Docker | 审查模式 | 迁移守护进程配置、Compose 文件、镜像列表和可选 volume 数据；network/container 缺失生成重建和健康检查提示，不自动恢复运行态 |
| 系统基线 (System Baseline) | 审查模式 | 扫描 locale/timezone、PAM、NTP、sysctl、LDAP/SSSD、DNS/NSS、网络地址/路由、TLS/证书、系统环境变量、语言运行时、hosts、脚本安装应用和敏感材料存在性，默认只生成人工审查项 |
| 防火墙 (Firewall) | 审查模式 | 在后端匹配时导出/导入配置文件 |
| 网络 (Network) | 审查模式 | 采集 netplan、NetworkManager、systemd-networkd、地址、路由和监听端口摘要，默认 manual_step，避免自动改 IP 路由 |
| 安全 (Security) | 审查模式 | 证书可以迁移；PAM/SELinux/AppArmor 需要审查 |
| 内核 (Kernel) | 关闭 | 报告 sysctl/模块差异；仅应用选定的安全 sysctl |
| 存储 (Storage) | 关闭 | 报告 fstab、mount、NFS/CIFS、autofs、LVM/ZFS/Btrfs 操作清单；v1 中不进行自动设备映射 |

### 4.2 包

HostLift 必须：

- 检测包管理器：`apt`、`dnf`、`yum`、`pacman` 或 `zypper`。
- 捕获显式安装的包意图，而非每个传递依赖。
- 捕获第三方仓库和仓库密钥。
- 在支持的情况下捕获保持/锁定状态。
- 使用相同的包管理器在目标上重新安装包。
- 将不可用的目标包标记为未解决。
- 避免直接复制包管理器数据库。

对于相同版本的迁移，包名称仅在检查目标仓库可用性后才假定为兼容。

### 4.3 服务

HostLift 必须：

- 检测初始化系统。v1 支持 systemd 作为主要路径。
- 迁移 `/etc/systemd/system/` 下的自定义单元。
- 扫描并审查 systemd drop-in、`/etc/default/*`、`/etc/sysconfig/*` 和 `EnvironmentFile=` 引用。
- 捕获启用/禁用状态。
- 捕获 active/reloading/activating/inactive/failed 等运行态。
- 在可用时运行 `systemd-analyze verify`。
- 应用单元后运行 `systemctl daemon-reload`。
- 仅在验证后启用服务。
- 源端运行中而目标端未运行时生成 `services/review-start/<unit>` 和 `services/check-status/<unit>` 高风险人工步骤，不生成默认可执行启动 action。

### 4.4 定时任务和定时器

HostLift 必须：

- 为选定用户迁移用户 crontab。
- 迁移 `/etc/crontab` 和 `/etc/cron.d/` 条目并进行冲突审查。
- 将 systemd 定时器作为服务模块的一部分迁移。
- 识别 `/etc/anacrontab`、periodic 目录和 at spool 来源。
- 报告 `at` 作业，但不自动应用过期或模糊的作业。

### 4.5 用户和组

HostLift 必须：

- 添加选定的非系统用户。
- 添加选定的组。
- 仅在目标无冲突时保留 UID/GID。
- 检测用户名、UID、组名和 GID 冲突。
- 永不覆盖目标的 `/etc/passwd`、`/etc/shadow`、`/etc/group` 或 `/etc/gshadow`。
- 默认不迁移密码哈希。
- 使用 `visudo -c` 验证 sudo 片段。

### 4.6 SSH

HostLift 必须：

- 为选定用户迁移 `authorized_keys`。
- 保留 `.ssh` 目录和文件的权限。
- 仅在审查后迁移 SSH 客户端配置。
- 默认不迁移 SSH 私钥。
- 默认不迁移 SSH 主机密钥。
- 在替换或合并之前使用 `sshd -t` 验证 `sshd_config`。

### 4.7 配置

HostLift 必须：

- 支持常见服务的精选配置文件，如 nginx、Apache、PostgreSQL 配置、MySQL 配置、Redis、Docker 和 shell 配置文件。
- 支持用户定义的包含和排除路径。
- 在可能的情况下保留文件模式、所有者、组、符号链接目标和修改时间。
- 检测二进制文件并将其分类为审查或重建，除非明确允许。
- 在配置的地方运行服务特定的语法检查。

### 4.7.1 主目录配置

HostLift 必须：

- 扫描 root 和非系统用户的常见 shell、Git、SSH 客户端、编辑器、用户级 systemd 和工具配置路径。
- 扫描 Maven、Cargo、Gradle、Go、npm 和 pip 的轻量配置文件，例如 `~/.m2/settings.xml`、`~/.cargo/config.toml`、`~/.gradle/gradle.properties`、`~/.config/go/env`、`~/.npmrc` 和 pip 配置。
- 默认不迁移 Maven repository、Cargo registry/cache、Gradle caches、Go module cache、pip cache、npm cache 等可重建的大型缓存目录。
- 将每个主目录配置路径作为独立迁移项，允许按模块或 action 前缀选择。
- 默认不迁移 SSH 私钥、GPG 私钥、浏览器 profile、token 数据库和其他高敏状态目录。
- 复制后恢复目标路径 owner；对 `.ssh/config` 保持 `.ssh` 目录 `700`、文件 `600`。

### 4.8 应用数据

HostLift 必须：

- 仅复制用户选定的路径，如 `/srv`、`/opt/<app>`、`/var/www` 或选定的主目录。
- 强制执行单个项目和总大小限制。
- 保留所有权和权限。
- 支持大文件的可恢复传输。
- 当路径似乎包含有状态数据目录时发出警告，如 `/var/lib/mysql`、`/var/lib/postgresql`、`/var/lib/redis`、`/var/lib/mongodb`、`/var/lib/elasticsearch`、`/var/lib/rabbitmq`、`/var/lib/kafka` 或 Docker 卷。

数据库目录在 v1 中不会自动迁移。用户应使用本机转储/恢复或自定义钩子。

### 4.9 Docker

HostLift 必须：

- 检测 Docker 和 Compose 的可用性。
- 在验证后迁移 `/etc/docker/daemon.json`。
- 在配置的路径中查找 Compose 文件。
- 导出镜像引用。
- 可选地在目标上拉取匹配的镜像。
- 报告卷和绑定挂载。

HostLift 不得：

- 实时迁移容器。
- 盲目复制 `/var/lib/docker`。
- 假设镜像架构兼容性。

### 4.10 网络和云提供商状态

HostLift 必须：

- 报告网络管理器类型和活动配置。
- 迁移 `/etc/hosts` 并进行审查。
- 迁移代理环境配置并进行审查。
- 迁移 VPN 配置并进行审查。

HostLift 默认不得应用：

- 静态 IP 地址。
- 默认路由。
- 接口名称。
- 云初始化网络配置。
- 提供商元数据配置。
- 主机名，除非用户选择替换模式。

### 4.11 防火墙

HostLift 必须：

- 检测后端：`ufw`、`firewalld`、`nftables` 或 `iptables`。
- 仅在源和目标后端匹配时自动应用规则。
- 优先使用本机持久化配置文件而非命令输出。
- 为可能锁定 SSH 的规则提供干运行和审查。
- 如果当前 SSH 端口在迁移后不被允许，则发出警告。

### 4.12 安全

HostLift 必须：

- 在用户确认后从选定路径迁移证书，包括 `/etc/letsencrypt`。
- 保留秘密文件权限。
- 将 GPG 密钥、SSH 私钥、API 令牌和密码哈希视为秘密。
- 默认将 PAM、SELinux、AppArmor、auditd、SSSD/LDAP、Kerberos、sudoers、ACL 和双因素认证配置置于审查/手动模式。
- 报告 `/etc/security/limits.conf`、`limits.d`、PAM、SSSD/LDAP 和 NSS 解析链差异，但在没有专用校验和 rollback 前不自动应用。

### 4.13 存储和内核

HostLift 必须：

- 报告 `/etc/fstab`、`findmnt`、`lsblk`、LVM、ZFS、Btrfs、RAID、crypttab、NFS/CIFS/autofs 和内核模块状态。
- 在 v1 中不自动映射磁盘或 UUID。
- 报告 locale、timezone、NTP、sysctl、tmpfiles.d、logrotate 和内核模块加载配置差异；默认先进入审查模式。
- 允许应用选定的安全 `sysctl` 设置，但必须有明确 allowlist、dry-run、verify 和 rollback 策略。
- 在 v1 中避免 GRUB 和引导加载程序更改。

## 5. CLI 需求

### 5.1 当前个人迁移主流程

当前已实现的 CLI 主线是 `scan -> plan -> validate -> apply`，源主机和目标主机分别生成 inventory，控制机再比较两份清单并分批执行。不存在 `hostlift export`、`hostlift import`、`--modules` 或 `--bundle` 这类当前命令。

```bash
# 在源主机扫描
hostlift scan --output source-inventory.json

# 在目标主机扫描
hostlift scan --output target-inventory.json

# 在控制机比较清单并生成计划
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --output hostlift-plan.json \
  --summary \
  --force

# 输出按个人迁移批次分组的选择清单
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --selection

# 输出迁移后健康检查清单
hostlift plan \
  --source source-inventory.json \
  --target target-inventory.json \
  --health-report

# 验证现有计划而不应用
hostlift validate --plan hostlift-plan.json --summary
hostlift apply --plan hostlift-plan.json --dry-run

# 按模块分批执行
hostlift apply \
  --plan hostlift-plan.json \
  --source-host root@OLD \
  --host root@NEW \
  --include-module packages,users \
  --audit-log ./batch1-audit.jsonl \
  --approve
```

### 5.2 定点传输和远程源传输

完整 plan 之外，当前也支持直接传输已知路径。个人服务器迁移优先使用 `rsync`、`--resume` 和 `source-host + rsync`，而不是常驻 agent。

```bash
# 控制机到目标机
hostlift transfer \
  --host root@NEW \
  --source /srv/app \
  --target /srv/app \
  --recursive \
  --transport rsync \
  --resume \
  --approve

# 源机推目标机；源机必须能 BatchMode SSH 到目标机
hostlift transfer \
  --source-host root@OLD \
  --host root@NEW \
  --source /srv/app \
  --target /srv/app \
  --recursive \
  --transport rsync \
  --approve
```

### 5.3 后续 CLI 设想

离线 bundle、交互式 TUI 和 `export/import` 风格向导仍可作为后续需求，但必须基于当前 inventory、plan、audit 和 rollback 契约实现；在未落地前，文档和示例不得把它们写成可用命令。

## 6. 配置文件需求（后续）

当前 CLI 主要通过命令行参数、inventory JSON、plan JSON、policy JSON、host-authz JSON 和 approval receipt JSON 配置执行；尚未读取全局 `config.toml`。以下是后续配置文件草案，不是当前可用功能。

默认配置路径：

```text
/etc/hostlift/config.toml
```

用户覆盖路径：

```text
~/.config/hostlift/config.toml
```

示例：

```toml
[compatibility]
require_same_distro = true
require_same_version = true
allow_cross_arch = true

[transfer]
compression = "zstd"
parallel = 4
chunk_size = "1MB"
max_total_size = "50GB"

[conflict]
default_strategy = "ask"
backup_before_replace = true

[packages]
enabled = true
install_recommends = false
include_third_party_repos = true

[services]
enabled = true
auto_enable = true
auto_start = false

[users]
enabled = true
include_shadow = false
preserve_uid_gid = "when_no_conflict"

[ssh]
enabled = true
include_authorized_keys = true
include_private_keys = false
include_host_keys = false

[configs]
enabled = true
include = ["/etc/nginx", "/etc/redis", "/etc/systemd/system"]
exclude = ["*.bak", "*.tmp", "*.swp"]

[appdata]
enabled = false
include = ["/srv", "/var/www"]
exclude = ["/var/lib/mysql", "/var/lib/postgresql", "/var/lib/docker"]
max_item_size = "10GB"

[network]
enabled = false
apply_ip_addresses = false
apply_hostname = false

[rollback]
enabled = true
path = "/var/lib/hostlift/rollback"
max_snapshots = 5
```

## 7. 选择界面需求

HostLift 当前已提供 `hostlift plan --selection` 文本 action 清单，用于个人迁移时按 action 前缀勾选和分批执行。完整 TUI 仍是后续增强，目标是把文本清单升级为更直观的终端向导：

```
- 连接屏幕
- 源和目标兼容性摘要
- 模块选择屏幕
- 按风险分组的计划审查屏幕
- 进度屏幕
- 验证和报告屏幕
```

选择界面和计划审查屏幕必须清晰显示：

```
- 要创建的项目
- 要替换的项目
- 要合并的项目
- 要跳过的项目
- 需要重建的项目
- 需要手动处理的项目
- 没有回滚支持的操作
```

### 7.1 主界面

```
┌──────────────────────────────────────────────────────────────┐
│  HostLift v1.0.0                                             │
│                                                              │
│  Mode: [Export from this machine]  [Import to this machine]  │
│                                                              │
│  连接状态: 等待连接中...                                       │
│  配对码: 847293                                               │
│  监听端口: 28451                                              │
└──────────────────────────────────────────────────────────────┘
```

### 7.2 模块选择界面

```
┌──────────────────────────────────────────────────────────────┐
│  选择要同步的模块                                     全选 反选 │
│                                                              │
│  [X] 1. 软件包 (packages)        [12 项]  ~2.3 GB            │
│  [X] 2. 系统服务 (services)      [3 项]   ~48 KB             │
│  [ ] 3. 定时任务 (cron)          [5 项]   ~2 KB              │
│  [X] 4. SSH 密钥 (ssh)           [4 项]   ~8 KB              │
│  [X] 5. 配置文件 (configs)       [6 项]   ~32 KB             │
│  [ ] 6. 应用数据 (appdata)       [3 项]   ~15 GB             │
│  [X] 7. Docker (docker)          [4 项]   ~512 KB            │
│  [ ] 8. 防火墙 (firewall)        [2 项]   ~12 KB             │
│  [ ] 9. 网络 (network)           [4 项]   ~8 KB              │
│                                                              │
│  预计传输大小: ~3.2 GB    预计时间: ~5 分钟                    │
│                                                              │
│  [Tab] 展开详情    [Space] 选择    [Enter] 确认开始迁移        │
└──────────────────────────────────────────────────────────────┘
```

### 7.3 对比视图（类似 Git diff）

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  迁移对比视图                                              [Tab] 切换视图   │
│                                                                              │
│  模块: packages                                          [↑↓] 导航          │
│ ┌─────────────────────────────┬─────────────────────────────┬──────────────┐│
│ │  源主机 (Source)            │  目标主机 (Target)          │  处理方式    ││
│ ├─────────────────────────────┼─────────────────────────────┼──────────────┤│
│ │  nginx 1.24.0               │  nginx 1.24.0               │  ✓ 跳过      ││
│ │  redis 7.2.0                │  (不存在)                   │  + 新增      ││
│ │  nodejs 20.9.0              │  nodejs 18.17.0             │  ! 替换      ││
│ │  python3 3.11.2             │  python3 3.11.2             │  ✓ 跳过      ││
│ │  docker-ce 24.0.7           │  (不存在)                   │  + 新增      ││
│ │  custom-app 2.1.0           │  custom-app 2.0.0           │  ! 替换      ││
│ ├─────────────────────────────┼─────────────────────────────┼──────────────┤│
│ │  源: 6 项                   │  目标: 2 项                 │  变更: 4 项  ││
│ └─────────────────────────────┴─────────────────────────────┴──────────────┘│
│                                                                              │
│  模块: services                                                              │
│ ┌─────────────────────────────┬─────────────────────────────┬──────────────┐│
│ │  源主机 (Source)            │  目标主机 (Target)          │  处理方式    ││
│ ├─────────────────────────────┼─────────────────────────────┼──────────────┤│
│ │  nginx.service (enabled)    │  nginx.service (disabled)   │  ~ 合并      ││
│ │  redis.service (enabled)    │  (不存在)                   │  + 新增      ││
│ │  custom.service (enabled)   │  custom.service (enabled)   │  ✓ 跳过      ││
│ ├─────────────────────────────┼─────────────────────────────┼──────────────┤│
│ │  源: 3 项                   │  目标: 2 项                 │  变更: 2 项  ││
│ └─────────────────────────────┴─────────────────────────────┴──────────────┘│
│                                                                              │
│  处理方式说明:                                                               │
│  [Space] 切换  [S]kip 跳过  [R]eplace 替换  [M]erge 合并  [A]ppend 追加     │
│                                                                              │
│  [Enter] 确认迁移    [Esc] 返回                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 7.4 单项详情对比

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  文件详情对比: /etc/nginx/nginx.conf                            [Esc] 返回   │
│                                                                              │
│ ┌─────────────────────────────────┬─────────────────────────────────────────┐│
│ │  源主机 (Source)                │  目标主机 (Target)                      ││
│ ├─────────────────────────────────┼─────────────────────────────────────────┤│
│ │  # nginx.conf                   │  # nginx.conf                           ││
│ │  user nginx;                    │  user nginx;                            ││
│ │  worker_processes auto;         │  worker_processes 2;                    ││
│ │                                 │                                         ││
│ │  events {                       │  events {                               ││
│ │      worker_connections 1024;   │      worker_connections 512;            ││
│ │  }                              │  }                                      ││
│ │                                 │                                         ││
│ │  http {                         │  http {                                 ││
│ │      include mime.types;        │      include mime.types;                ││
│ │      # 新增配置                 │                                         ││
│ │      gzip on;                   │                                         ││
│ │      gzip_types text/plain;     │                                         ││
│ │  }                              │  }                                      ││
│ ├─────────────────────────────────┼─────────────────────────────────────────┤│
│ │  大小: 1.2 KB                   │  大小: 0.8 KB                           ││
│ │  修改时间: 2026-05-25 10:30     │  修改时间: 2026-05-20 14:20             ││
│ │  SHA256: a1b2c3...              │  SHA256: d4e5f6...                      ││
│ └─────────────────────────────────┴─────────────────────────────────────────┘│
│                                                                              │
│  差异: 3 处不同 (worker_processes, worker_connections, gzip 配置)            │
│                                                                              │
│  处理方式: [S]kip 跳过  [R]eplace 替换  [M]erge 合并  [A]ppend 追加         │
│                                                                              │
│  [Enter] 确认    [↑↓] 切换文件    [Tab] 切换视图                            │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 7.5 冲突处理策略选择

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  冲突处理策略                                                    [Esc] 返回 │
│                                                                              │
│  发现 5 个冲突项目，请选择处理方式:                                           │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │  冲突项目                    │  推荐策略    │  选择策略    │  说明      ││
│  ├─────────────────────────────────────────────────────────────────────────┤│
│  │  /etc/nginx/nginx.conf       │  Merge       │  [▼ 合并]    │  配置合并  ││
│  │  /etc/passwd                 │  Append      │  [▼ 追加]    │  用户追加  ││
│  │  /etc/ssh/sshd_config        │  Manual      │  [▼ 手动]    │  需要审查  ││
│  │  ~/.ssh/authorized_keys      │  Append      │  [▼ 追加]    │  密钥追加  ││
│  │  /etc/crontab                │  Merge       │  [▼ 合并]    │  任务合并  ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  策略说明:                                                                   │
│  Skip:    保持目标不变                                                       │
│  Replace: 备份目标后替换                                                     │
│  Merge:   按模块特定逻辑合并 (如 passwd 按用户名合并)                         │
│  Append:  只添加新内容，不触动已有内容                                        │
│  Manual:  不自动处理，迁移后手动处理                                          │
│  Ask:     每个项目单独询问                                                    │
│                                                                              │
│  [↑↓] 导航    [Enter] 展开选项    [A] 全部应用推荐策略                       │
│                                                                              │
│  [Enter] 确认迁移    [Esc] 返回                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 7.6 迁移进行中界面

```
┌──────────────────────────────────────────────────────────────┐
│  迁移进行中...                                      已用 2:34 │
│                                                              │
│  总进度  [████████████░░░░░░░░░░░░░░░░] 38%   1.2 GB / 3.2 GB│
│                                                              │
│  ● 软件包     [██████████████████░░░░░░] 72%   传输中         │
│  ✓ 系统服务   [████████████████████████] 100%  完成           │
│  ○ SSH 密钥   [░░░░░░░░░░░░░░░░░░░░░░░░] 0%    等待中         │
│  ○ 配置文件   [░░░░░░░░░░░░░░░░░░░░░░░░] 0%    等待中         │
│                                                              │
│  当前文件: /opt/app/config.yml (2.4 KB)                      │
│  传输速度: 45 MB/s                                            │
│                                                              │
│  日志: [14:23:01] packages: 安装 nginx -> 完成                │
│        [14:23:02] services: 启用 nginx.service -> 完成        │
│        [14:23:03] packages: 开始传输 /opt/nodejs/...          │
│                                                              │
│  [P] 暂停    [Q] 取消                                        │
└──────────────────────────────────────────────────────────────┘
```

### 7.7 完成界面

```
┌──────────────────────────────────────────────────────────────┐
│  迁移完成！                                          用时 4:12│
│                                                              │
│  模块状态:                                                   │
│  ✓ 软件包      12/12 项成功                                   │
│  ✓ 系统服务    3/3 项成功   已执行 daemon-reload               │
│  ✓ SSH 密钥    4/4 项成功                                     │
│  ✓ 配置文件    6/6 项成功                                     │
│  ✓ Docker      4/4 项成功                                     │
│                                                              │
│  ⚠ 需要手动处理:                                              │
│    - /etc/sudoers 需要手动合并                                 │
│    - /etc/ssh/sshd_config 需要审查配置                        │
│    - 网络配置未自动应用（安全考虑）                              │
│                                                              │
│  迁移日志已保存到: /var/log/hostlift/2026-05-26.log            │
│  回滚信息已保存到: /var/lib/hostlift/rollback/                 │
│                                                              │
│  [Enter] 退出    [R] 回滚    [V] 查看详细日志                  │
└──────────────────────────────────────────────────────────────┘
```

## 8. 安全需求

### 8.1 权限模型

```
- 源需要 root 权限才能完整扫描，但在没有 root 权限时应优雅降级
- 目标需要 root 权限才能应用系统级更改
- HostLift 必须永不静默提升权限
- 如果在没有所需权限的情况下启动，它必须显示确切缺失的功能或路径
```

### 8.2 传输安全

```
- 支持直接 TCP 传输
- 所有在线传输必须加密
- 配对凭据必须过期
- 认证必须将批准的目标绑定到源会话
- 包含秘密的离线包必须在静态时加密
```

### 8.3 连接建立流程

```
目标主机                                    源主机
  |                                         |
  |  TCP SYN  ──────────────────────────>   |
  |  TCP SYN+ACK  <──────────────────────   |
  |  TCP ACK  ──────────────────────────>   |
  |                                         |
  |  TLS ClientHello  ──────────────────>   |
  |  TLS ServerHello + Cert  <───────────   |
  |  TLS Finished  ────────────────────>   |
  |  TLS Finished  <───────────────────    |
  |                                         |
  |  [TLS 加密通道建立]                      |
  |                                         |
  |  Hello{version=1}  ────────────────>   |
  |  Hello{version=1}  <────────────────   |
  |                                         |
  |  AuthChallenge{salt}  <────────────    |
  |  AuthResponse{bcrypt(code+salt)}  ─>   |
  |  AuthOk{session_token}  <──────────    |
  |                                         |
  |  [认证完成，开始迁移]                     |
```

### 8.4 传输流程

```
发送端:
  Item -> 压缩(zstd) -> 分块(1MB) -> TLS加密 -> TCP发送
                                                    |
接收端:                                             v
  应用 <- 解压(zstd) <- 合并块 <- TLS解密 <- TCP接收
```

断点续传：
- 接收端维护已收到块的 bitmap
- 重连后发送 bitmap 给发送端
- 发送端跳过已确认的块

### 8.5 秘密处理

```
普通文件:  TLS 加密 -> 传输 -> 写入
敏感文件:  TLS 加密 -> AES-256-GCM 二次加密 -> 传输 -> 解密 -> 写入
配对码:    bcrypt 哈希比对，不在网络上传输明文
```

秘密处理规则：

```
- 除非明确选择，否则排除秘密
- 秘密项目在计划中标记
- 日志必须编辑秘密内容
- 秘密恢复后必须验证文件权限
```

### 8.6 锁定保护

在应用 SSH、防火墙、用户、sudo 或网络更改之前，HostLift 必须：

```
- 如果可能，检测当前的 SSH 连接端口
- 如果迁移计划可能阻止 SSH 访问，则发出警告
- 验证 sudo 和 SSH 配置语法
- 如果可能，为高风险更改提供延迟回滚命令
```

## 9. 冲突策略

### 9.1 支持的策略

| 策略 | 含义 | 适用场景 |
|------|------|----------|
| `skip` | 保持目标项目不变 | 目标已有相同或更新版本 |
| `replace` | 备份目标项目并替换它 | 需要完全覆盖 |
| `merge` | 应用模块特定的合并逻辑 | 配置文件、用户列表等 |
| `append` | 添加条目而不触动现有条目 | authorized_keys、crontab 等 |
| `manual` | 不自动应用 | 高风险项目，需要人工审查 |
| `ask` | 提示用户 | 默认策略 |

### 9.2 合并策略详情

不同模块的合并逻辑：

```
模块              合并逻辑
─────────────────────────────────────────────────────────────
packages          检查目标仓库可用性，安装缺失的包
services          按单元名合并，更新 enabled 状态
cron              按命令去重后合并
users             按用户名合并，不删除目标已有用户
passwd            按用户名合并，保留目标已有用户
group             按组名合并
ssh/authorized    追加新密钥，保留已有密钥
configs           按文件路径，可选择替换或合并
fstab             按挂载点合并，UUID 需要重映射
hosts             按 IP 合并，保留目标已有条目
iptables          不合并，提示用户手动处理
```

### 9.3 默认策略

```
冲突类型          默认策略
─────────────────────────────────────────────────────────────
普通文件冲突      ask (询问用户)
高风险系统更改    manual (手动处理)
用户/组冲突       append (追加)
密钥冲突          append (追加)
配置文件冲突      ask (询问用户)
```

## 10. 回滚需求

回滚必须基于操作，而不仅仅是基于文件。

每个已应用的操作记录：

```
1. 操作类型
2. 目标路径或目标系统对象
3. 之前状态引用
4. 适用时的备份路径
5. 验证状态
6. 回滚支持级别
```

回滚级别：

```
full:    可以自动恢复之前的状态
partial: 可以恢复文件但可能无法撤消副作用
none:    无法安全地自动回滚
```

示例：

```
替换配置文件:  完全回滚
创建用户:      部分回滚，因为迁移后可能创建文件
安装包:        部分或无，取决于包管理器状态
应用防火墙规则: 部分且需要锁定保护
```

## 11. 日志和报告

HostLift 必须写入：

```
- 机器清单
- 迁移计划
- 应用日志
- 验证报告
- 手动跟进列表
- 回滚元数据
```

默认路径：

```
/var/log/hostlift/          # 日志目录
/var/lib/hostlift/          # 数据目录
```

报告必须以人类可读的文本和 JSON 格式提供。

## 12. 成功标准

v1 迁移成功的条件：

```
✓ 源和目标兼容性检查通过
✓ 用户批准的包已安装或明确标记为未解决
✓ 用户批准的配置文件已应用并验证
✓ 用户批准的服务已按请求安装和启用
✓ 定时任务和定时器条目存在
✓ 选定的用户和 SSH 访问可用
✓ 选定的应用数据具有匹配的大小和校验和
✓ 高风险模块在确认后应用或列为手动工作
✓ 最终报告清晰说明成功、失败、跳过和需要手动工作的内容
```

## 13. 版本计划

### v0.1.0 - 本地清单和规划

```
功能:
  - scan 命令
  - 清单架构
  - 兼容性检查器
  - 计划生成
  - JSON 输出

模块:
  - packages (软件包)
  - services (系统服务)
  - cron (定时任务)
  - users (用户)
  - SSH
  - configs (配置文件)
```

### v0.2.0 - 本地应用和干运行

```
功能:
  - validate 命令
  - apply --dry-run
  - 文件备份和操作日志
  - 同主机测试工具

模块:
  - packages (软件包)
  - services (系统服务)
  - cron (定时任务)
  - users (用户)
  - SSH
  - configs (配置文件)
```

### v0.3.0 - 在线迁移

```
功能:
  - export 模式
  - import 模式
  - 加密的源到目标传输
  - source-host + rsync 远程源传输
  - rsync 可恢复传输和文本 action 选择清单
  - 交互式 TUI 作为后续增强
```

### v0.4.0 - 数据和风险模块

```
功能:
  - 应用数据复制
  - Docker Compose 发现
  - 防火墙审查和应用
  - 网络/存储/证书/系统环境变量 scan-only 审查和操作清单
```

### v1.0.0 - 稳定的相同版本迁移

```
功能:
  - 完整的报告和回滚元数据
  - 跨支持发行版的集成测试
  - 常见发行版的打包
  - 提供商到提供商 VPS 迁移的文档
```
