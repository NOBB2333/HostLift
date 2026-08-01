# HostLift Linux 迁移覆盖范围审计

本文档从"Linux 主机迁移"角度，系统性评估 HostLift 当前已实现、部分实现和完全缺失的能力。适用于换机规划、版本路线评审和缺口优先级排序。

## 评估时间

- 初次覆盖审计：2026-06-28
- AI 驱动整机迁移复审：2026-07-26
- Action 级兼容门禁复审：2026-07-30
- 递归内容 Manifest Verify 复审：2026-07-30
- PostgreSQL 有状态 Provider 复审：2026-07-30
- 可信 Verified Reinstall Provider 复审：2026-07-31

## 评估基准

- 项目版本：v0.1 工程核心阶段
- 扫描模块：packages、configs、ssh、sudoers、acl、security_policy、cron、services、users、home_configs、projects、appdata、resources、firewall、storage、network、docker、processes、dev_env、system_baseline
- 传输后端：scp、rsync、chunk
- 安全边界：policy、host-authz、approval receipt、audit、rollback

---

## 零、AI 驱动整机迁移复审结论

### 0.1 结论

HostLift 当前最准确的定位是：**以同发行版、同版本为高置信度主路径，并能跨主机差异规划可移植 action 的受控重建和文件迁移执行器**。它的扫描面、模块边界和安全骨架已经明显超过一组临时 shell 脚本，但还不能承担“让 AI 一次命令把整台在线服务器完整搬到另一台服务器”的闭环目标。

不要用单一百分比描述全部场景。按当前代码能力分场景判断更准确：

| 迁移场景 | 当前可行性 | 能做到什么 | 主要阻塞 |
| --- | --- | --- | --- |
| 同发行版同版本、包管理为主、无状态服务 | 较高，可实际试用 | 包、用户、配置、项目文件、部分服务 enable、cron、home、SSH 和防火墙可分批迁移；数据/项目目录默认内容级 verify | manual action 需独立分批，文件系统扩展元数据、服务启动和业务健康仍需处理 |
| 同发行版同版本、Docker/Compose + 数据库 | 中等，PostgreSQL 严格场景可执行 | 可发现 Compose、容器、volume、端口和数据路径；PostgreSQL 10+ 同 major、停写、fresh target 场景可显式执行逻辑迁移，其它数据库输出人工合同 | 缺 Compose 自动拓扑恢复、数据库服务编排、低停机 cutover、内容级 verify 和自动数据库回滚 |
| `curl | sh`、手工二进制、语言运行时工具 | 中等，显式固定 recipe 可执行 | 可发现部分未托管 executable/install root；AI/操作者可提供 HTTPS + 精确 size + SHA-256 + 目标平台 + 结构化 argv recipe，生成 download/execute/verify DAG | scanner hint 不能自动信任；官方来源/签名、ABI/依赖和脚本未声明副作用的完整回滚仍缺 |
| 同发行版跨版本 | 中低，可生成有效 plan | 同包管理器包、项目、普通 appdata、home、用户和 SSH key 可继续规划；系统配置/init/cron/firewall 转兼容性人工任务 | 缺版本语义映射和真实发行版矩阵 |
| 跨发行版/包管理器 | 中低，仅可移植切片可自动 | 项目、普通 appdata、home、用户/组、authorized_keys 和全部 manual task 保留；包管理器不同时包动作转人工 | 没有包名、路径、service、network 和配置语义映射 provider |
| 跨架构 | 低，仅可移植切片可自动 | 项目、普通数据、home 和由目标包管理器安装的包可规划 | install root/未托管资源复制被转人工；仍缺 ELF ABI、CPU feature、目标依赖和镜像多架构验证 |
| 在线业务低停机切换 | 低 | 可提前复制静态文件并输出人工检查项 | 没有 quiesce、final delta、readiness、DNS/LB switch 和 rollback 状态机 |

如果把“受控迁移工程核心”作为目标，当前已经进入可用的 v0.1；如果把“AI 驱动的一键整机换服务器”作为目标，关键闭环仍未完成，不能对外承诺完整迁移。

### 0.2 当前架构做得好的部分

1. inventory/plan/apply/remote/transport/security/audit/rollback 的边界清楚，适合继续演进为 AI 控制面，而不需要推翻重写。
2. 高风险模块默认 scan-only/manual_step，避免为了功能表看起来完整而自动破坏认证、网络、存储和数据库。
3. 包、文件、用户、unit enable、传输、审计和部分 rollback 已有真实 handler、测试与 fake remote smoke，不只是 README 声明。
4. resources 已能通过包归属和引用证据发现一部分脚本/手工安装资源，curl 脚本应用不再是完全盲区。

### 0.3 关键问题与本轮修复状态

| 严重度 | 问题 | 当前证据 | 影响 |
| --- | --- | --- | --- |
| P0（已修复 2026-07-26） | 混合计划可能部分执行后才遇到 manual/unsupported action | apply 现已在 host/policy/SSH 前校验全部所选 action 的模块、类型和 handler；混入人工项会原子拒绝 | 不再因后置 `manual_step` 造成前序远程修改；远程依赖的全批次 preflight 仍待补 |
| P0（已修复 2026-07-26） | rollback manifest 在分批执行和中途失败时不够可靠 | 默认路径增加随机 run 后缀，显式路径拒绝覆盖，每条 entry 立即 flush | 已消除同 plan manifest 覆盖和 writer 缓冲丢失；完整 run ledger/续跑仍待补 |
| P0（已修复 2026-07-26） | system env 可能把 secret 原值写入 inventory | 敏感 key token 和含 userinfo URL 的 value 现在固定写为 `[REDACTED]` | system env 的 token、password 和代理凭据不再进入 JSON/summary；统一 `secret_ref` 仍待补 |
| P0（已修复 2026-07-26） | 后序 action 的 preflight 失败可能发生在前序 mutation 之后 | approved apply 现对全部未完成所选 action 先做 generic 与 module preflight，覆盖依赖、传输源、目标冲突和容量/inode | fake remote 已证明后序缺 `systemctl` 时前序包安装、backup、transfer、audit 和 rollback 均为零 |
| P0（已修复 2026-07-26） | 没有 run/action checkpoint，失败后无法证明哪些 action 可跳过 | `hostlift.apply.run_state.v1` 绑定 plan/host/选择集合/rollback，使用 hash chain、独占锁和逐事件 flush；`--resume-run` 只跳过成功 action并复用首次备份 | 已覆盖 action 失败续跑、host/plan/filter mismatch、链篡改和 rollback manifest 不重复追加 |
| P0（粗粒度门禁已修复 2026-07-30） | 兼容性模型既过严又过松 | 完整主机 compatible 现包含已知架构；plan v2 按 action 保留 portable 候选并把危险候选改写为 `compatibility_review`；validator/apply 共用门禁 | 已消除全局零 action 和跨架构 resources 错误放行；ELF/ABI/SONAME/CPU feature/目标依赖及 distro provider 仍未完成 |
| P0（证据合同、ledger、只读 probe 已补 2026-07-28） | manual step 和 action 缺机器合同 | plan v2、三类 rich inputs、systemd/container probe provider、单证据强绑定、plan 级 completeness、hash-chain ledger 和 `manual_probe_report.v1` 已接入 | AI 不再只靠 description 或自报 probe passed；probe/report 仍未签名，ledger 仍是 hash_chain_only，也尚未被 run-state/workload 消费 |
| P0（基础报告已修复 2026-07-26） | 缺少 workload/application 完整性单元 | `hostlift.workload_report.v1` 已聚合 systemd 服务、项目/Compose、appdata、容器和未托管资源，输出组件/action/blocker/confidence/host status；`scan.full_scan` 防止把过滤扫描或旧 inventory 的空模块误判为无资源 | 已能按当前 inventory/plan 粒度回答完成、待执行、阻塞或未知；run-state/manual evidence、跨模块完整拓扑和业务级 verify 仍待补 |
| P0（首个受限 provider 已补 2026-07-30） | 没有通用有状态 cutover 状态机 | PostgreSQL 已有双 opt-in 五步 DAG、停写/fresh target 门禁、dump/restore、catalog verify 和人工 recovery evidence；其它数据库仍为结构化人工合同 | 已能执行严格受限的 PostgreSQL 离线逻辑迁移，但仍不能保证低停机切换、内容级一致性或失败自动回切 |
| P1（已修复 2026-07-30） | 目录 apply 默认只验证路径存在 | `copy_data_path`/`copy_project_path` 现在全批次 preflight 源 manifest，传输后比较源/目标路径、类型、大小、文件 SHA-256 和 symlink target；任一侧截断、special file 或 mismatch 失败关闭 | fake remote 覆盖远程源、匹配/mismatch、special/truncated、run-state 不误报成功和 verify 前 rollback baseline；ACL/xattr/capability/hardlink/sparse/SELinux 仍未保真 |
| P1（受限 provider 已补 2026-07-31） | curl/手工安装应用只能发现，无法进入受控执行 | `hostlift.reinstall_recipes.v1` 精确绑定 manual action、HTTPS、size、SHA-256、目标平台、install/verify argv 和 managed paths；validator/handler 双重门禁，失败中间态 rollback 证据立即落盘 | 可迁移 AI 明确确认的固定 artifact；HostLift 不判断来源官方，shell installer 的未声明副作用仍不能完整回滚 |
| P1 | 文件系统元数据语义不完整 | rsync 为 `-a`，没有 ACL/xattr/capability/hardlink/sparse/SELinux 策略 | 权限敏感程序可能复制成功但运行失败 |
| P1 | 测试矩阵不足 | CI 只有 Ubuntu runner + fake remote | 不能证明多发行版、init 系统和真实 SSH 故障下可迁 |

### 0.4 面向 AI 的目标流程

```mermaid
flowchart LR
    A[源/目标只读扫描] --> B[带完整性与脱敏证据的 Inventory]
    B --> C[Workload / Application 拓扑]
    C --> D[Plan v2 Action DAG]
    D --> E[全计划 preflight 与策略批准]
    E --> F[可执行 Provider]
    E --> G[结构化 Manual Task]
    F --> H[Run Ledger 与 Rollback 证据]
    G --> H
    H --> I[机器可执行 Verify Probes]
    I --> J{全部 workload 收敛?}
    J -->|否| K[阻塞原因 / 补救 / 回滚]
    J -->|是| L[Cutover / 观察 / 完成]
```

这张图中，现有代码已经具备 A、部分 B、C 的第一版离线工作负载报告、v2 D 基础、全批次 E、F 的基础、通用结构化 G、文件型可恢复 H，以及 systemd/container/TCP/HTTP 固定只读 I 的第一版；C 的跨模块完整拓扑、更多 provider 专属 G、run/manual/probe evidence 合并、跨 provider 的完整 H、签名可信 I、J 和 L 仍是当前重要缺口。

### 0.5 建议实现顺序

1. 已完成第一阶段执行闭环：selected action support/manual 前置校验、全批次 generic/module preflight、唯一 rollback manifest、run ledger/action checkpoint/安全续跑和 system env secret redaction。
2. 已完成 AI 合同输入、单 evidence 校验、plan 级完整度、hash-chain ledger 和只读 remote probe 第一阶段：systemd/container 自动合同，TCP/HTTP 固定执行器，report 文件 hash/host 联合校验；下一步补外部验签/可信时间戳、secret 专属字段和 run-state/workload 受控消费。
3. 已完成 workload v1 离线报告：聚合五类应用主体并失败关闭判定状态；下一步补 package/config/user/secret/port 跨模块归属、run-state/manual evidence 和远程 verify 证据合并。
4. PostgreSQL 已完成第一个同 major、停写、fresh target 的逻辑迁移切片；下一步补内容级 verify/可验证恢复，再按 MySQL、Redis、Compose 逐个增加 provider 和 cutover，不一次覆盖所有数据库。
5. 已完成显式固定 recipe 的可信 reinstall 第一阶段；下一步补发布签名/透明日志验证、语言生态 provider、跨发行版映射、目录元数据保真和真实 Linux 集成矩阵。

完整可勾选清单和验收标准见项目根目录 `TASK_PROGRESS_zh.md` 的“AI 驱动整机迁移待办”。

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
| 项目目录递归传输 | ✅ | 指定路径；默认源/目标内容 manifest verify |
| 应用数据目录 | ✅ | 默认内容 manifest verify，verify 前写新建路径 rollback baseline |
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
| apply 递归内容校验 | ✅ | 本地/远程源、远程目标、symlink target；截断/special/mismatch 失败关闭，可显式 opt-out |
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

当前已经收窄了常见 bin 目录直下的单文件边界：`/usr/local/bin/tool`、`/opt/bin/tool`、`~/go/bin/tool`、`~/.cargo/bin/tool`、`~/.local/bin/tool` 默认作为单文件 executable 审查，不再归并成整个父级 bin 目录。对未托管 executable 会记录 `file` 文件类型和 `readelf`/`objdump` 静态动态依赖摘要，并生成通用 `resources/reinstall/<path>` 人工步骤，提示确认来源 URL、版本、校验和、配置目录和运行依赖。`system_baseline.script_apps` 已能基于通用用户路径提取 source URL、版本、checksum 和 config hint。

现在已经有受限的可信重装执行器，但不会直接信任上述扫描事实。AI/操作者必须另行提供 `hostlift.reinstall_recipes.v1`：HTTPS URL、精确字节数、SHA-256、目标发行版/版本/架构、结构化 install/verify argv 和全部 managed paths 均必填。planner 只替换精确匹配的 `script_reinstall`/`resource_reinstall` 人工 action；下载落到 source inventory hash 绑定的 `0700`/`0600` artifact，禁止管道执行，最终重新核对 artifact、路径和 stdout hash。

| 安装来源 | 典型路径 | 当前覆盖 | 仍缺能力 |
|---|---|---|---|
| curl \| sh 脚本安装 | /usr/local/bin, /opt, ~/.local/bin | 资源地图可发现一部分；显式固定 recipe 可先 HTTPS 落盘、校验 size/hash，再以 `sh`/`bash` 执行 | 自动官方来源/签名判定、完整副作用声明和脚本级 rollback |
| 编译安装/单文件二进制 | /usr/local/bin, /usr/local/sbin, /opt | 包归属缺失时可进入 install root/review；固定二进制 recipe 可用受限 `install` 写一个声明目标 | 来源/版本自动推导、动态库和 ABI 验证 |
| go install / cargo install | ~/go/bin, ~/.cargo/bin | 主动扫描用户级 bin；ELF 静态动态依赖摘要用于发现 CGO 风险 | module/source/version 重建建议 |
| snap / flatpak | /snap, /var/lib/flatpak | `/snap/bin` 可作为 PATH 候选发现 | runtime/sandbox provider、安装源重建 |
| AppImage | 任意路径 | 被引用时可作为未托管 executable 发现 | 桌面集成、签名、更新源 |
| pip install --user | ~/.local/bin | 被引用时可发现入口脚本 | Python 版本、site-packages、venv 关系 |
| npm global | /usr/local/bin, /usr/local/lib/node_modules | 可发现部分入口命令 | Node 版本、全局包清单、lock/source 信息 |

**建议补齐**：
1. 在显式 recipe 之上增加发布签名、透明日志或可信 registry provider；不能用 scanner URL 自动跳过信任审查。
2. 对 Go/Cargo/pipx/npm global 等用户级工具，补 module/source/version 重建建议。
3. 为动态二进制增加 ELF interpreter、glibc/musl、SONAME、CPU feature 和目标依赖验证；脚本继续要求准确声明副作用或保留人工任务。

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
| PostgreSQL 数据目录 | 默认仍是 sensitive review；双 opt-in 可执行 PostgreSQL 10+ 同 major、停写、fresh target 的 `pg_dumpall` 逻辑迁移和 catalog verify | 低停机 cutover、跨 major、非 peer auth、内容级一致性和自动回滚仍需人工方案 |
| Redis 数据 | `/var/lib/redis` 进入 sensitive review，提示 dump/snapshot/停写 | RDB/AOF 备份恢复 |
| MongoDB 数据 | `/var/lib/mongodb` 进入 sensitive review，提示 dump/snapshot/停写 | mongodump 或快照恢复 |
| Elasticsearch 索引 | `/var/lib/elasticsearch` 进入 sensitive review，提示 dump/snapshot/停写 | snapshot API |
| RabbitMQ 队列/绑定 | `/var/lib/rabbitmq` 进入 sensitive review，提示 dump/snapshot/停写 | rabbitmqctl export 或业务级恢复 |
| Kafka topics | `/var/lib/kafka` 进入 sensitive review，提示 dump/snapshot/停写 | topic/consumer group 迁移方案 |

这些数据不应该由迁移工具直接热复制。除严格 opt-in 的 PostgreSQL provider 外，HostLift 仍把 resources 里的有状态路径保持为 review，并让 `appdata` 的 database/docker data 生成 dump-restore 人工任务；后续按服务逐个补专用 provider，不能复用 PostgreSQL 的固定命令假装通用。

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
| 脚本安装应用 | resources 可发现一部分；显式 HTTPS/size/SHA-256/平台绑定 recipe 可受控执行，仍缺自动官方来源/签名和未声明副作用 rollback | ⭐⭐⭐⭐ |
| 非包管理器二进制 | 已有资源地图、ELF 摘要和固定 binary recipe；受限 `install` 目标必须是声明路径，仍缺 ABI/依赖和发布签名验证 | ⭐⭐⭐⭐ |
| 网络配置 | 已有 NetworkManager/netplan/systemd-networkd 路径、地址/路由和命令摘要 scan-only；缺自动合并和 apply | ⭐⭐⭐ |
| 认证链深度 | PAM/SSSD/LDAP 只扫描不迁移 | ⭐⭐ |
| 数据库/有状态服务 | PostgreSQL 已有首个严格受限的逻辑 dump/restore/verify provider；其它数据库和 Docker 数据仍是结构化人工合同 | ⭐⭐⭐ |
| 机器身份 | machine-id 不迁移；SSH host key 已有指纹/存在性审查和选择提示 | ⭐⭐⭐ |
| 引导/内核 | 内核模块配置已有只读事实；boot loader 仍未覆盖 | ⭐⭐ |

---

## 五、建议优先级

> 本节保留 2026-06-28 以“补扫描覆盖”为主的历史排序。多数条目已经完成第一阶段；2026-07-26 起的当前优先级以“0.5 建议实现顺序”和 `TASK_PROGRESS_zh.md` 的“AI 驱动整机迁移待办”为准，先修执行/证据/脱敏闭环，再扩扫描范围。

### P0 — 最值得立即补齐

1. **脚本安装和用户级工具的来源识别**
   - 已能从部分 executable/install root 提取来源 URL、版本、校验和和配置目录 hint
   - 已有独立显式 recipe provider，但 scanner hint 不会自动进入执行；当前缺口是可信发布签名/registry 和 Go/Cargo/pipx/npm global 专用 provider
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

6. **有状态 provider 与运行态门禁**
   - PostgreSQL 已有双 opt-in 的离线逻辑迁移 provider；默认仍保持人工任务，且不热复制 PGDATA
   - MySQL/Redis/MongoDB/Elasticsearch/RabbitMQ/Kafka 和 Docker/Podman volume 仍只生成 dump/restore/consistency 人工合同
   - 后续按 provider 增加运行态隔离、内容级 verify、服务启停/cutover 和可验证恢复，不默认执行未知数据库命令

7. **SSH host key 处理**
   - 已记录 host key 类型、公钥指纹、私钥/公钥存在性
   - plan 输出 `ssh/review-host-key/<type>`，让用户选择“保留目标新 key”或“复制源 key”

8. **/etc/environment 和系统级 profile**
   - 已扫描 `/etc/environment`、`/etc/profile` 和 `/etc/profile.d` 的关键环境变量事实
   - 敏感 key token 和含 userinfo 的 URL value 已固定写入 `[REDACTED]`；PATH、locale 和普通 runtime 值仍保留
   - 仍默认 review，不自动覆盖全局 PATH、代理和运行时变量；统一 `secret_ref` 合同留待后续

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

1. **manual task 的执行/证据闭环仍未完成** — 三类 rich-input provider、显式固定 reinstall recipe、systemd/container probe provider、manual evidence 单份/plan 级校验、hash-chain ledger 和固定只读 remote probe 已有第一版；任意未知脚本、其它数据库 executor、secret inputs、发布签名、外部时间戳锚定及 run-state/workload 受控消费仍缺
2. **统一 secret 合同仍未完成** — system env 的敏感 key/URL 已脱敏，但其它 inventory 模块还没有统一分类、`secret_ref` 和跨 schema 的泄漏回归测试
3. **有状态恢复闭环仍不完整** — PostgreSQL 已补同 major、停写、fresh target 的 opt-in dump/restore/catalog verify，但 baseline 仅是人工 recovery evidence；仍缺内容级一致性、自动恢复、低停机 cutover，且其它数据库没有执行 provider
4. **run 级闭环仍局限于 supported action** — 全批次 preflight、hash-chain run state、逐 action checkpoint、安全续跑和 rollback 复用已补；workload v1 只能用重新扫描后的 inventory/plan 离线判定，尚未合并 run/manual evidence，PostgreSQL 之外的数据库/cutover provider 和跨控制机协调仍未覆盖
