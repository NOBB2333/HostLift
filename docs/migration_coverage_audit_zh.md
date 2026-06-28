# HostLift Linux 迁移覆盖范围审计

本文档从"Linux 主机迁移"角度，系统性评估 HostLift 当前已实现、部分实现和完全缺失的能力。适用于换机规划、版本路线评审和缺口优先级排序。

## 评估时间

2026-06-28

## 评估基准

- 项目版本：v0.1 工程核心阶段
- 扫描模块：packages、configs、ssh、sudoers、acl、security_policy、cron、services、users、home_configs、projects、appdata、resources、firewall、storage、network、docker、processes、dev_env、system_baseline
- 传输后端：scp、rsync、chunk
- 安全边界：policy、host-authz、approval receipt、audit、rollback

---

## 一、已实现自动 apply 的能力

### 1.1 包管理器

| 能力 | 状态 | 说明 |
|---|---|---|
| apt/dnf/yum 包安装 | ✅ | 主流 Debian/RHEL 系 |
| pacman 包安装 | ✅ | Arch 系 |
| apk 包安装 | ✅ | Alpine |
| zypper 包安装 | ✅ | openSUSE/SLES |
| hold 状态迁移 | ✅ | 防止目标机自动升级 |

覆盖了 Linux 主流包管理器，是当前最完整的模块之一。

### 1.2 配置文件

| 能力 | 状态 | 说明 |
|---|---|---|
| /etc 常见配置文件 | ✅ | sshd、journald、logrotate、rsyslog、DNS/NSS、cron.d、profile.d、limits、sysctl、containerd 等 |
| /etc/hosts 差异 | ✅ | 生成可选文件型动作，支持人工 merge |
| 文件型传输 | ✅ | 复用通用 transfer handler |
| verify/rollback | ✅ | 每个 write_file 都有备份和恢复 |

### 1.3 SSH

| 能力 | 状态 | 说明 |
|---|---|---|
| SSH 配置和 authorized_keys | ✅ | 文件型传输 |
| sshd_config 关键指令扫描 | ✅ | Port、ListenAddress、PermitRootLogin、PasswordAuthentication、PubkeyAuthentication、AllowUsers/Groups |
| sshd_config 差异审查 | ✅ | 进入 manual_step，不自动修改 |

### 1.4 定时任务

| 能力 | 状态 | 说明 |
|---|---|---|
| crontab | ✅ | 用户级和系统级 |
| /etc/cron.d | ✅ | 系统级 cron 片段 |
| /etc/cron.daily 等 | ✅ | cron 目录结构 |
| systemd timer | ✅ | 安装/启用自定义 timer，非自定义差异生成 manual_step |
| systemd timer schedule 摘要 | ✅ | 记录 OnCalendar/OnBootSec 等 |

### 1.5 服务和启动

| 能力 | 状态 | 说明 |
|---|---|---|
| systemd service 安装/启用 | ✅ | 自定义 unit 安装和 enabled 状态 |
| systemd service 运行态扫描 | ✅ | 记录 active/reloading/inactive/failed 等 |
| systemd service 运行态差异处理 | ✅ | 源端 active 而目标端非 active 的生成 `services/review-start/<unit>` 和 `services/check-status/<unit>` 高风险人工步骤；默认不自动启动服务 |
| systemd drop-in/env 文件审查 | ✅ | 扫描 `/etc/systemd/system/*.d/*.conf`、`/etc/default/*`、`/etc/sysconfig/*` 和 `EnvironmentFile=` 引用，默认人工 merge/review |
| systemd timer 安装/启用 | ✅ | 自定义 timer 缺失时可生成安装动作 |
| systemd socket 安装/启用 | ✅ | 自定义 socket 缺失时可生成安装动作 |
| 用户级 systemd unit | ✅ | 目标缺失时复制 unit 文件 + enable |
| XDG autostart | ✅ | 目标缺失时复制 .desktop 文件 |
| SysV init 脚本 | ✅ | 目标缺失时复制 /etc/init.d 脚本 |
| SysV init runlevel | ✅ | chkconfig 或 update-rc.d 收敛 enable/disable |
| OpenRC service | ✅ | 目标缺失时复制 + rc-update add/del 收敛 runlevel |

### 1.6 用户和组

| 能力 | 状态 | 说明 |
|---|---|---|
| 用户创建 | ✅ | useradd |
| 组创建 | ✅ | groupadd |
| UID/GID/name 冲突检测 | ✅ | 冲突时生成 manual_step |
| 用户密码 hash | ❌ | 明确不迁移，安全考虑 |

### 1.7 Home 配置

| 能力 | 状态 | 说明 |
|---|---|---|
| .bashrc/.zshrc/.profile | ✅ | 通用 home 文件 |
| .gitconfig | ✅ | Git 全局配置 |
| Maven settings.xml | ✅ | ~/.m2/settings.xml |
| Cargo config | ✅ | ~/.cargo/config.toml |
| Gradle properties | ✅ | ~/.gradle/gradle.properties |
| Go env | ✅ | ~/.config/go/env |

### 1.8 项目和应用数据

| 能力 | 状态 | 说明 |
|---|---|---|
| 项目目录递归传输 | ✅ | 指定路径 |
| 应用数据目录 | ✅ | 带 rollback |
| Docker volume mountpoint 数据 | ✅ | 高风险可选动作，需先停写 |
| chunk 增量传输 | ✅ | 文件粒度缺失/变更上传 |

### 1.9 防火墙

| 能力 | 状态 | 说明 |
|---|---|---|
| iptables 配置 | ✅ | 文件型传输 |
| nftables 配置 | ✅ | 文件型传输 |
| firewalld 配置 | ✅ | 文件型传输 |
| reload 延迟恢复窗口 | ✅ | 防火墙 reload 后 SSH 断连自动恢复 |

### 1.10 传输和远程执行

| 能力 | 状态 | 说明 |
|---|---|---|
| scp 传输 | ✅ | 含 -3 远程源中转 |
| rsync 传输 | ✅ | 含 --partial、--resume、--bwlimit；支持 `source-host + rsync` 源机推目标机和源机到目标机 BatchMode SSH 预检 |
| chunk 增量传输 | ✅ | 文件粒度 diff 上传 |
| 远程命令执行 | ✅ | 结构化 argv，带 approve 约束 |
| 远程依赖预检 | ✅ | 执行前检查目标机是否有对应命令 |

### 1.11 安全和审计

| 能力 | 状态 | 说明 |
|---|---|---|
| policy 门禁 | ✅ | 模块/host/operator/风险级别约束 |
| host-authz | ✅ | operator 可操作主机授权 |
| approval receipt | ✅ | HMAC 签名审批凭证 |
| 审计日志 | ✅ | JSONL/syslog/HTTPS sink |
| 审计验证 | ✅ | audit verify 命令 |
| 审计重放 | ✅ | audit replay 命令 |
| rollback manifest | ✅ | 文件型、`copy_data_path`/`copy_project_path` 新建路径删除型 entry + 部分命令型；删除型 entry 会明确提示删除整个 HostLift 新建路径 |

---

## 二、只能扫描、不能自动 apply 的能力（manual_step）

| 模块 | 扫描内容 | 不自动迁移的原因 |
|---|---|---|
| sudoers | /etc/sudoers + /etc/sudoers.d 片段元数据 | 授权规则涉及安全边界，误写可能锁死机器 |
| ACL | POSIX ACL 扩展属性存在性 | 权限语义复杂，跨机器不一定等价 |
| SELinux/AppArmor | 状态、配置路径、profile/policy 计数 | 安全内核策略直接复制可能破坏目标 |
| storage | LVM/ZFS/Btrfs/crypttab/NFS/autofs | 存储池/卷是底层硬件绑定的，不能直接复制 |
| Docker/Podman 运行中容器 | 容器状态、network、image | 容器有运行时依赖，image 需要 pull |
| system_baseline 认证链 | PAM/SSSD/LDAP/Kerberos | 涉及认证链，直接覆盖可能锁死 SSH |
| system_baseline DNS/NSS | resolv.conf/nsswitch | DNS 解析链改错导致所有网络请求失败 |
| system_baseline sysctl | 内核参数 | 涉及内核行为，误写可能影响稳定性 |
| system_baseline NTP | 时间同步配置 | 错误的 NTP 可能导致时间跳跃 |
| system_baseline 证书 | CA 证书、TLS 证书存在性 | 涉及信任链 |
| system_baseline GPG | 密钥环存在性 | 安全密钥材料 |
| sshd_config | Port/ListenAddress/PermitRootLogin 等 | 改错会丢失 SSH 访问 |

---

## 三、仍未完整的能力

### 3.1 非包管理器二进制和脚本安装应用

飞书/Mojo 这类 curl|sh 安装的应用，以及手动安装到 `/usr/local/bin`、`/opt`、`~/go/bin`、`~/.cargo/bin`、`~/.local/bin` 的二进制，已经不再是完全盲区。`resources` v1 会基于通用资源根、PATH 目录、用户级 bin、运行中进程、systemd/user unit、XDG autostart、cron、profile/tool config 中引用到的绝对可执行路径，并结合 `dpkg -S`、`rpm -qf`、`pacman -Qo`、`apk info --who-owns` 判断包归属，生成资源地图和 copy/review/exclude 建议。

当前已经收窄了常见 bin 目录直下的单文件边界：`/usr/local/bin/tool`、`/opt/bin/tool`、`~/go/bin/tool`、`~/.cargo/bin/tool`、`~/.local/bin/tool` 默认作为单文件 executable 审查，不再归并成整个父级 bin 目录。对未托管 executable 会记录 `file` 文件类型和 `readelf`/`objdump` 静态动态依赖摘要，并生成通用 `resources/reinstall/<path>` 人工步骤，提示确认来源 URL、版本、校验和、配置目录和运行依赖。`system_baseline.script_apps` 已能基于通用用户路径提取 source URL、版本、checksum 和 config hint；仍缺的是可信自动化：官方来源判定、下载校验、落盘审计和自动 reinstall provider 还没有完成。

| 安装来源 | 典型路径 | 当前覆盖 | 仍缺能力 |
|---|---|---|---|
| curl \| sh 脚本安装 | /usr/local/bin, /opt, ~/.local/bin | 资源地图可通过 bin 路径和引用关系发现一部分，并生成通用 reinstall 人工步骤；脚本安装候选可提取 source URL、版本、checksum 和 config hint | 可信来源判定、下载校验和自动 reinstall provider |
| 编译安装 | /usr/local/bin, /usr/local/sbin, /opt | 包归属缺失时可进入 install root 或 review，单文件边界已收窄 | 来源、版本、配置目录关联 |
| go install / cargo install | ~/go/bin, ~/.cargo/bin | 主动扫描用户级 bin；ELF 静态动态依赖摘要用于发现 CGO 风险 | module/source/version 重建建议 |
| snap / flatpak | /snap, /var/lib/flatpak | `/snap/bin` 可作为 PATH 候选发现 | runtime/sandbox provider、安装源重建 |
| AppImage | 任意路径 | 被引用时可作为未托管 executable 发现 | 桌面集成、签名、更新源 |
| pip install --user | ~/.local/bin | 被引用时可发现入口脚本 | Python 版本、site-packages、venv 关系 |
| npm global | /usr/local/bin, /usr/local/lib/node_modules | 可发现部分入口命令 | Node 版本、全局包清单、lock/source 信息 |

**建议补齐**：
1. 对 curl|sh 安装的应用，识别版本文件、配置目录、来源 URL 和校验和，提升通用 reinstall 人工步骤的准确性。
2. 对 Go/Cargo/pipx/npm global 等用户级工具，补 module/source/version 重建建议。
3. 可选接入轻量安全扫描或 hash 风险报告，但不把这条做成默认重型门禁。

### 3.2 内核和引导

| 缺失项 | 说明 |
|---|---|
| GRUB/引导加载器配置 | /boot/grub/grub.cfg、/etc/default/grub |
| 内核版本选择 | 默认内核、已安装内核列表 |
| initramfs | mkinitcpio/dracut 配置 |
| /boot 目录 | 内核镜像、initramfs、grub 等 |

这些在同发行版换机时可能有用，在跨发行版换机时价值有限。

### 3.3 内核模块深度

| 已有 | 缺失 |
|---|---|
| /etc/modules-load.d 配置 | /etc/modprobe.d 自定义配置 |
| lsmod 摘要 | 模块参数（modprobe.d/options） |
| | 内核版本差异导致的模块不兼容 |

### 3.4 网络完整配置

| 已有 | 缺失 |
|---|---|
| 静态 IP/地址/路由（scan-only） | NetworkManager connection profiles 自动迁移 |
| /etc/hosts | netplan 配置自动迁移 |
| DNS resolver | systemd-networkd 自动迁移 |
| NetworkManager/netplan/systemd-networkd 路径存在性 | bonding/bridging/VLAN 自动迁移 |
| ip route/ip -6 route/nmcli/networkctl 摘要 | 非默认 IP routes 自动应用 |
| | Wi-Fi 配置（服务器少见但有时有） |
| | IPv6 完整配置 |
| | 防火墙规则已覆盖，但 nftables set/counter/map 可能丢失 |

### 3.5 PAM 和认证链深度

| 已有 | 缺失 |
|---|---|
| PAM 状态（scan-only） | /etc/pam.d/ 下具体规则文件 |
| LDAP/SSSD/Kerberos 存在性 | 实际绑定配置（ldap.conf、sssd.conf） |
| | TOTP/2FA 配置（pam_google_authenticator） |
| | /etc/security/access.conf、/etc/security/time.conf |
| /etc/environment/profile.d 系统级环境变量 | 自动应用和冲突合并 |

### 3.6 系统级密钥和信任链

| 已有 | 缺失 |
|---|---|
| 证书目录存在性（scan-only） | CA 证书 bundle 完整复制（/etc/ssl/certs） |
| GPG 密钥环存在性 | GPG 密钥环实际导出 |
| SSH host key 指纹/存在性 | SSH host key 自动复制（/etc/ssh/ssh_host_*） |
| | TLS 证书 + 私钥（Let's Encrypt /etc/letsencrypt） |

### 3.7 服务配置深度

| 已有 | 缺失 |
|---|---|
| systemd service 文件 | drop-in 自动合并 |
| systemd drop-in/env 文件摘要 | environment 文件自动写入 |
| OpenRC | service 依赖图（depend 块） |
| | socket activation 完整依赖 |

environment 文件尤其重要 — 很多服务的配置不在 unit 文件里，而在 `/etc/default/` 或 `/etc/sysconfig/` 里。

### 3.8 数据库和有状态服务

| 服务类型 | 当前提醒 | 仍需人工处理 |
|---|---|
| MySQL/MariaDB 数据目录 | `/var/lib/mysql` 进入 sensitive review，提示 dump/snapshot/停写 | mysqldump 或物理备份恢复 |
| PostgreSQL 数据目录 | `/var/lib/postgresql` 进入 sensitive review，提示 dump/snapshot/停写 | pg_dump/pg_basebackup 或快照恢复 |
| Redis 数据 | `/var/lib/redis` 进入 sensitive review，提示 dump/snapshot/停写 | RDB/AOF 备份恢复 |
| MongoDB 数据 | `/var/lib/mongodb` 进入 sensitive review，提示 dump/snapshot/停写 | mongodump 或快照恢复 |
| Elasticsearch 索引 | `/var/lib/elasticsearch` 进入 sensitive review，提示 dump/snapshot/停写 | snapshot API |
| RabbitMQ 队列/绑定 | `/var/lib/rabbitmq` 进入 sensitive review，提示 dump/snapshot/停写 | rabbitmqctl export 或业务级恢复 |
| Kafka topics | `/var/lib/kafka` 进入 sensitive review，提示 dump/snapshot/停写 | topic/consumer group 迁移方案 |

这些确实不应该由迁移工具直接热复制。HostLift 当前会把 resources 里的有状态路径保持为 review，并且 `appdata` 的 database/docker data 只生成 dump-restore 人工步骤；后续再补更精确的服务运行态识别和专用 dump/restore hook。

### 3.9 机器身份

| 缺失项 | 说明 |
|---|---|
| /etc/machine-id | systemd 日志、D-Bus、journald 依赖 |
| /etc/hostname | 已在 system_baseline 扫描但不迁移 |
| /etc/timezone、/etc/localtime | 已识别不迁移 |
| SSH host key | 已生成选择提示：保留目标新 key 或复制源 key |

### 3.10 定时任务的隐藏形态

| 已有 | 缺失 |
|---|---|
| cron | at jobs（/var/spool/at）— 已识别并生成 review，不自动 replay |
| systemd timer | anacron（/etc/anacrontab）— 已识别并生成 review |
| | systemd 的残留 timer（OnCalendar 配置错误的） |

### 3.11 临时/运行时状态

| 缺失项 | 说明 |
|---|---|
| /tmp 清理规则 | systemd-tmpfiles 已识别但不迁移 |
| 进程运行状态 | 已扫描但不迁移 |
| 系统日志 | journald 已识别但不迁移历史日志 |
| swap 配置 | /etc/fstab 中的 swap 条目、zram |

### 3.12 桌面环境（桌面 Linux 迁移）

| 缺失项 | 说明 |
|---|---|
| GNOME/KDE 设置 | dconf/gsettings 键值 |
| 字体 | /usr/share/fonts、~/.local/share/fonts |
| 壁纸/主题 | 大量 dconf 键 |
| 浏览器 profile | Firefox/Chrome 用户数据 |
| 输入法配置 | fcitx/ibus 配置 |
| 打印机配置 | /etc/cups |

### 3.13 其他

| 缺失项 | 说明 |
|---|---|
| 定时任务的 anacron | /etc/anacrontab |
| 系统级环境变量 | /etc/environment |
| 系统级 profile | /etc/profile、/etc/profile.d/（已有扫描但不迁移） |
| tmpfiles.d 规则 | 已扫描但不迁移 |
| sysctl.d 规则文件 | 已扫描但不迁移 |
| kernel.sysctl 运行时值 | 已扫描但不迁移 |

---

## 四、覆盖情况总览

### 4.1 按迁移阶段

| 阶段 | 覆盖情况 | 评分 |
|---|---|---|
| 事实扫描 | 覆盖广泛，几乎所有重要系统事实都有扫描 | ⭐⭐⭐⭐⭐ |
| 差异比较 | plan 阶段能识别差异并生成 action 或 manual_step | ⭐⭐⭐⭐ |
| 自动迁移 | 包/配置/服务/用户/文件传输完整 | ⭐⭐⭐⭐ |
| 安全边界 | approve/policy/host-authz/audit/rollback 链完整 | ⭐⭐⭐⭐⭐ |
| 回滚恢复 | 文件型完整，命令型部分，非文件型缺失 | ⭐⭐⭐ |

### 4.2 按内容类别

| 类别 | 覆盖情况 | 评分 |
|---|---|---|
| 包管理器 | 多发行版覆盖，hold 支持 | ⭐⭐⭐⭐⭐ |
| 配置文件 | /etc 候选路径多，有 verify/rollback | ⭐⭐⭐⭐ |
| 服务和启动 | systemd/SysV/OpenRC/timer/socket 都有，最完整 | ⭐⭐⭐⭐⭐ |
| 用户和组 | 有冲突检测 | ⭐⭐⭐⭐ |
| 文件传输 | scp/rsync/chunk 三后端 | ⭐⭐⭐⭐ |
| 安全边界 | approve/policy/host-authz/audit 链完整 | ⭐⭐⭐⭐⭐ |
| 脚本安装应用 | resources 已能发现一部分并生成通用 reinstall 人工步骤，system_baseline.script_apps 可提取 source URL、版本、checksum 和 config hint；缺可信自动 reinstall provider | ⭐⭐⭐⭐ |
| 非包管理器二进制 | 已有资源地图、单文件边界、用户级 bin 主动扫描、ELF 静态动态依赖摘要、轻量安全报告和 reinstall 人工步骤；缺可信来源判定和自动重装 | ⭐⭐⭐⭐ |
| 网络配置 | 已有 NetworkManager/netplan/systemd-networkd 路径、地址/路由和命令摘要 scan-only；缺自动合并和 apply | ⭐⭐⭐ |
| 认证链深度 | PAM/SSSD/LDAP 只扫描不迁移 | ⭐⭐ |
| 数据库/有状态服务 | 常见数据目录已有 sensitive review 和备份提醒；appdata 数据库/Docker 数据目录已改为 dump-restore 人工步骤，缺专用 dump/restore hook | ⭐⭐⭐ |
| 机器身份 | machine-id 不迁移；SSH host key 已有指纹/存在性审查和选择提示 | ⭐⭐⭐ |
| 引导/内核 | 内核模块配置已有只读事实；boot loader 仍未覆盖 | ⭐⭐ |

---

## 五、建议优先级

### P0 — 最值得立即补齐

1. **脚本安装和用户级工具的来源识别**
   - 基于已发现的 executable/install root 继续识别来源 URL、版本文件、校验和和配置目录
   - 对 curl|sh、Go/Cargo/pipx/npm global 等工具完善 reinstall `manual_step` 内容
   - ELF 静态动态依赖摘要只作为审查事实，不默认阻断迁移

2. **服务 environment 文件**
   - 已扫描 `/etc/default/*`、`/etc/sysconfig/*`、`EnvironmentFile=` 和 systemd drop-in 配置（`/etc/systemd/system/*.service.d/`）
   - plan 阶段默认生成 review/merge 提示，不盲目覆盖
   - 后续只补更细 diff/merge 自动建议

3. **NetworkManager/netplan 完整网络配置**
   - 已扫描 NetworkManager/netplan/systemd-networkd 路径存在性和 `ip`/`nmcli`/`networkctl` 摘要
   - 默认 manual_step，避免自动改 IP、路由、桥接、VLAN 导致断网
   - 后续补配置文件内容级 diff/merge 建议

4. **远程源到目标的 chunk/agent 传输**
   - `source-host + rsync` 第一阶段已支持源机推目标机，后续补 chunk 远程源或 agent 模式
   - 优先做无常驻 agent 的 SSH 编排模式；agent/P2P 后端作为可选增强
   - 保留带宽限制、断点续传、manifest 校验和失败关闭，不增加重型安全流程

5. **目标容量预检**
   - 已在 storage scan 中记录目标挂载容量、inode、内存和 swap 摘要
   - 已在 plan 阶段按 resources 默认 copy 资源估算挂载点容量风险，并对目标内存/swap 小于源端给出人工提醒
   - 已补 plan summary 迁移批次建议、resources 单独计数和 apply 前实时容量/inode 复核；后续继续补更细批次依赖图
   - 不做重型安全门禁，重点避免迁一半失败

### P1 — 中期补齐

6. **运行中服务识别和提醒**
   - 对 MySQL/PostgreSQL/Redis/MongoDB/Elasticsearch/RabbitMQ/Kafka 和 Docker/Podman volume，当前已生成 dump/restore/consistency 人工操作清单，不自动热复制
   - 后续如继续增强，应优先做 opt-in 的运行态识别和专用 dump/restore hook，而不是默认执行数据库命令

7. **SSH host key 处理**
   - 已记录 host key 类型、公钥指纹、私钥/公钥存在性
   - plan 输出 `ssh/review-host-key/<type>`，让用户选择“保留目标新 key”或“复制源 key”

8. **/etc/environment 和系统级 profile**
   - 已扫描 `/etc/environment`、`/etc/profile` 和 `/etc/profile.d` 的关键环境变量事实
   - 默认 review，不自动覆盖全局 PATH、代理和运行时变量

9. **语言运行时和用户级包管理器**
   - nvm/pyenv/conda/pipx/uv/npm global/pnpm/yarn/go/rust 等依赖复杂
   - 已识别常见运行时目录并生成 review；后续补版本/导出清单和更准确重装建议，不默认复制 cache

10. **anacron**
   - 已识别 `/etc/anacrontab` 和 at spool，并生成 review，不自动 replay

### P2 — 长期规划

11. **交互式选择界面**
   - 已提供按个人迁移批次分组的 `hostlift plan --selection` 文本选择清单，以及只输出本地清单的 `hostlift plan --health-report`
   - 后续如需继续优化，优先做 TUI/向导，不做企业 Web 审批台

12. **内核和引导配置**
   - 同发行版换机时有用
13. **机器身份（machine-id）**
   - systemd 日志和 D-Bus 依赖
14. **桌面环境配置**
   - 仅在桌面 Linux 迁移场景下需要

---

## 六、当前设计决策的合理性

### 设计得好的部分

1. **scan 和 apply 分离** — 扫描不产生副作用，是正确的安全边界
2. **manual_step 机制** — 对高风险/不确定的操作，不自动 apply 而是生成人工审查项，非常合理
3. **文件型 rollback** — 每个 write_file 都有备份和恢复，是最可靠的回滚方式
4. **firewall reload 延迟恢复窗口** — 防止防火墙 reload 后 SSH 断连，考虑周到
5. **UID/GID 冲突检测** — 在 plan 阶段就发现用户冲突，比 apply 时失败好得多
6. **sshd_config 关键指令审查** — 避免改错 Port/ListenAddress 导致锁死
7. **Docker volume 可选复制** — 高风险动作有明确标记，用户可选择性执行

### 设计上可以改进的部分

1. **脚本安装应用只生成"请重新安装"** — 可以进一步识别来源 URL、版本、校验和，让重装更精确
2. **system_baseline 扫描结果已经丰富** — 摘要还可以更清晰地分组展示"哪些需要人工操作"
3. **数据库服务缺自动恢复流程** — 已有常见数据目录识别和 dump/restore/consistency 人工操作清单；仍缺 opt-in 自动 dump/restore hook、恢复校验和版本兼容检查
