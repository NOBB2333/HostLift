# HostLift 持久进度清单

本文件用于记录跨会话、跨 agent、跨上下文压缩后仍然可见的项目进度。短期 `Updated Plan` 只能反映当前会话，不能替代本文件。

## 当前执行切片：Agent 协作规则和进度可视化

- [x] 判断当前协作模式应落到项目级 `AGENTS.md`，而不是跨项目 Skill。
- [x] 新增 `AGENTS.md`，定义 goal、计划、持久清单、质量门禁、注释、架构边界和完成度审计规则。
- [x] 新增 `TASK_PROGRESS_zh.md`，作为后续功能、质量、架构和长期缺口的持久清单。
- [x] 运行 `scripts/check.sh` 验证新增规则文件和清单不会破坏项目门禁。

## 当前执行切片：Linux musl 构建修复

- [x] 复现 `./scripts/build-linux.sh` 在 `x86_64-linux-musl` 下因为 `std.c.getenv` 未显式链接 libc 失败。
- [x] 在 `build.zig` 的可执行模块和测试模块中显式设置 `.link_libc = true`。
- [x] 重新运行 `./scripts/build-linux.sh`，确认 `x86_64-linux-musl` 和 `aarch64-linux-musl` 都构建成功。

## 当前执行切片：Linux 换机遗漏评估

- [x] 核对 locale/timezone、LVM/ZFS/Btrfs、NFS/CIFS/autofs、内核模块、limits、PAM、NTP、sysctl、SSSD/LDAP、logrotate、profile.d、tmpfiles.d、Docker 镜像、hosts/DNS/NSS 等覆盖情况。
- [x] 确认 systemd timers 已有专门扫描和部分迁移动作，不只是普通 service；at jobs 当前未覆盖。
- [x] 确认 SELinux/AppArmor 已是 scan-only/manual_step，不应直接自动迁移；密码 hash、SSH 私钥、GPG 密钥、API tokens 仍应默认不迁移。
- [x] 补齐 Maven/Cargo/Gradle/Go 轻量 home 配置扫描：`~/.m2/settings.xml`、`~/.cargo/config.toml`、`~/.cargo/config`、`~/.gradle/gradle.properties`、`~/.config/go/env`。
- [x] 保持 Maven repository、Cargo registry/cache、Gradle caches、Go module cache、pip cache、npm cache 不进入默认迁移。
- [x] 在 `PRD_zh.md` 和 `CODE_QUALITY_zh.md` 记录这些遗漏的处理策略和后续设计方向。

## 当前执行切片：Linux 系统基线 scan-only 覆盖

- [x] 新增 `system_baseline` inventory schema 和 scanner，覆盖 locale/timezone、NTP、sysctl、limits、PAM、LDAP/SSSD/Kerberos、DNS/NSS、静态网络配置、logrotate、profile.d、tmpfiles.d、NFS/autofs/exports、内核模块配置、证书/SSH/GPG 敏感材料存在性。
- [x] 新增 `/etc/hosts` 结构化条目解析，避免只知道文件存在、不知道映射内容。
- [x] 新增 `timedatectl`、`locale`、`lsmod`、`vgs/lvs`、`zpool/zfs`、`btrfs`、`atq` 命令事实统计，用于发现 LVM/ZFS/Btrfs/at jobs 等迁移风险。
- [x] 新增脚本安装应用候选识别：Rustup、NVM、Mojo、Linuxbrew、飞书/Lark CLI，默认生成重装/人工审查建议，不复制缓存和二进制。
- [x] `system_baseline` 接入 scan registry、plan registry、inventory summary 和 registry 测试。
- [x] `system_baseline` plan 阶段对高风险差异生成 `manual_step`，默认不自动写 PAM、DNS、NSS、sysctl、SSSD、网络、证书或密钥。
- [x] Docker inventory 新增镜像扫描，plan 阶段对目标缺失镜像生成人工审查动作。
- [x] users plan 阶段新增 UID/GID/name 冲突检测，冲突时生成 `manual_step`，不再盲目生成会失败的 create user/group。
- [x] 为 `/etc/hosts` 解析、system baseline review、UID 冲突、Docker 镜像解析补充单元测试。

## 当前执行切片：Docker 数据卷和存储解析修复

- [x] 评估现有文件同步能力：`copy_data_path` 已走通用 transfer handler，支持递归复制数据路径，但此前 Docker volume 只生成人工审查项。
- [x] Docker volume 扫描增加 `docker volume inspect --format {{.Mountpoint}}`，inventory 和摘要能显示卷实际 mountpoint。
- [x] 目标缺失 Docker volume 且源端能解析 mountpoint 时，plan 额外生成 `docker/copy-volume/<name>` 高风险 `copy_data_path` 动作，用户可按 action 前缀选择执行。
- [x] Docker volume 数据复制仍要求先停写或做应用一致性备份，不自动重建运行容器，也不自动迁移 Docker network。
- [x] 修复 `storage.zig` 中 mountinfo 八进制转义空实现，含空格路径现在可正确解析。
- [x] 为 Docker volume copy action 和 mountinfo 转义解析补充测试。

## 当前执行切片：关键扫描值、SSH 配置和回滚补强

- [x] `system_baseline` 新增结构化配置事实：locale、timezone、sysctl、limits、NTP server/pool、resolv.conf、nsswitch、NFS exports、LVM/ZFS/Btrfs 命令输出摘要。
- [x] `system_baseline` 摘要和 plan review 会展示/审查结构化值差异，但仍不自动写 PAM、sysctl、DNS/NSS、SSSD、NTP 或存储池配置。
- [x] `/etc/hosts` 结构化条目不同步时，plan 额外生成 `configs/write//etc/hosts` 高风险文件型动作，供用户选择复制或人工 merge。
- [x] SSH 扫描新增 `sshd_config` 关键指令摘要：Port、ListenAddress、PermitRootLogin、PasswordAuthentication、PubkeyAuthentication、AllowUsers/Groups 等；差异进入 `manual_step`。
- [x] `users.parsePasswd` 和 `parseGroup` 读取失败不再静默返回空，改为上抛给 scan_runner 形成 warning，避免误判“无需迁移用户”。
- [x] appdata 模块接入通用文件型 rollback handler。

## 当前执行切片：架构清理和剩余问题修复

- [x] 修复 rollback dispatcher 路由：`appdata/copy/` 映射到 appdata，`docker/copy-volume/` 映射到 docker。
- [x] Docker volume copy 的 docker 模块接入通用文件型 rollback handler。
- [x] scan registry 不再用 `.security` 承载 dev env、不再用 `.kernel` 承载 processes；新增 `.dev_env` 和 `.processes`，不再保留旧模块别名。
- [x] 进程扫描从 `ps ... comm` 改为 `ps ... args`，记录完整命令行摘要。
- [x] `readWholeFile` 默认读取上限从 1MB 提升到 8MB，并明确超限返回错误、不静默截断。
- [x] 抽出 Docker label 归一化 helper，去掉 `docker_containers.zig` 和 `docker_resources.zig` 重复实现。
- [x] 抽出 init 脚本忽略规则 helper，SysV/OpenRC 共用。
- [x] 扩展 configs 扫描候选路径，补 SSH、containerd/podman/containers、journald/logind、rsyslog、logrotate、cron.d、profile.d、limits、sysctl、DNS/NSS 等常见系统配置入口。
- [x] 抽出用户 home 扫描规则 helper，home 配置、用户级 systemd、XDG autostart、dev env 和 system baseline 共用。
- [x] Docker/Podman 容器资源扫描按 runtime provider 聚合，container/volume/network/image 记录带 runtime 字段，plan 层按运行时区分同名资源。

## 当前执行切片：整机资源发现和脚本安装通用检测

- [x] 新增 resources inventory schema，记录可迁移资源路径、大小、磁盘占用、文件数、包归属、证据、敏感等级和默认动作。
- [x] 新增 resources scanner，基于 PATH、service、cron、profile 和 process 引用发现未被包管理器托管的可执行文件，不按具体应用名硬编码。
- [x] resources plan 阶段对源端缺失资源生成可选择的迁移动作或人工审查项。
- [x] inventory summary 输出资源大小、占用、风险和证据，便于整机迁移前人工选择。
- [x] 补充 resources 单元测试和中文文档，运行 `scripts/check.sh` 验证。

## 当前执行切片：resources v1 完成度评估

- [x] 核对 resources scan、plan registry、rollback dispatcher、summary 和通用 transfer handler 接入状态。
- [x] 确认 resources v1 当前定位是保守的资源地图和高风险选择性复制，不是恶意软件扫描器、整盘克隆器或完整企业迁移平台。
- [x] 确认 `resources/copy/*` 可走 `copy_data_path` 传输和路径存在性 verify；后续已补新建目标路径的 `delete_created_path` rollback manifest。
- [x] 确认 `scripts/check.sh` 在当前工作区通过，输出包含 `all checks passed`。

## 当前执行切片：个人服务器迁移业务能力待办审计

- [x] 按个人服务器迁移场景重新审计缺口，不把在线审批、RBAC、集中审计等企业能力作为本轮业务优先级。
- [x] 更新 `docs/migration_coverage_audit_zh.md` 中“非包管理器二进制完全不扫描”的老旧描述。
- [x] 更新 README 中 resources 单文件 executable 和 install root 分类边界的描述，避免文档承诺超过当前实现。
- [x] 形成 P0/P1/P2 个人使用业务能力待办清单。

## 当前执行切片：个人服务器迁移待办表更新

- [x] 按产品经理视角评估用户提供的 P0/P1/P2 方案是否更适合当前个人服务器迁移目标。
- [x] 将 `TASK_PROGRESS_zh.md` 的个人迁移待办改成“优先级 / 功能点 / 当前欠缺 / 建议约束”表格。
- [x] 补充 P2P/远程源传输加固建议，明确不引入重型企业安全体系。
- [x] 更新老旧文档口径，把企业审批/RBAC/Vault 等从当前优先级降为非个人使用优先。
- [x] 运行文档变更检查并记录验证结果。

## 当前执行切片：P0 resources 精度修正

- [x] 修正 `/usr/local/bin/tool` 这类单文件 executable 的分类边界，避免默认复制整个 `/usr/local/bin`。
- [x] 主动扫描用户级 bin：`~/go/bin`、`~/.cargo/bin`、`~/.local/bin`、`~/.deno/bin`、`~/.bun/bin`、`~/.npm-global/bin`。
- [x] 为未托管 executable 增加 ELF 静态动态依赖审查事实，输出文件类型和动态依赖摘要。
- [x] 更新 resources 单元测试和相关文档。
- [x] 运行 `scripts/check.sh` 并记录验证结果。

## 当前执行切片：P0 脚本安装应用重装提示

- [x] 梳理现有 `system_baseline.script_apps` 和 `resources` 对未托管 executable/install root 的 plan 输出。
- [x] 为未托管 executable/install root 生成通用 reinstall `manual_step`，提示来源 URL、版本、校验和和配置目录仍需人工确认。
- [x] 更新测试、README/覆盖审计文档和个人迁移待办表。
- [x] 运行 `scripts/check.sh` 并记录验证结果。

## 当前执行切片：P0 P2P/远程源传输

- [x] 审计现有 `transfer`、`remote`、`transport` 对 `source-host`、`rsync`、`chunk` 和 `scp -3` 的支持边界。
- [x] 实现第一阶段 `source-host + rsync` 编排，优先复用 SSH/remote/transport 边界，不引入常驻 agent。
- [x] 增加 preflight/测试，确保源端和目标端缺 rsync 时失败关闭并给出明确错误。
- [x] 更新 README/技术设计/待办表。
- [x] 运行 `scripts/check.sh` 并记录验证结果。

## 当前执行切片：P0 有状态服务备份提醒

- [x] 补齐常见数据库/队列/搜索服务数据目录资源事实，默认 sensitive review。
- [x] plan 阶段对有状态数据路径输出 dump/snapshot/停写窗口提醒，不自动热复制。
- [x] appdata 数据路径增加 engine/dump/restore/consistency hint，覆盖 MySQL/MariaDB、PostgreSQL、Redis、MongoDB、Elasticsearch、RabbitMQ、Kafka 和 Docker/Podman volume 操作清单。
- [x] 更新测试、README/覆盖审计文档和个人迁移待办表。
- [x] 运行 `scripts/check.sh` 并记录验证结果。

## 当前执行切片：P0 目标容量预检

- [x] 审计现有 storage/resources 是否已有磁盘容量、inode、内存或 swap 事实。
- [x] plan 阶段根据 resources 待迁移大小和目标容量事实输出容量风险 `manual_step`。
- [x] 更新测试、README/覆盖审计文档和个人迁移待办表。
- [x] 运行 `scripts/check.sh` 并记录验证结果。

## 当前执行切片：P1/P2 个人服务器迁移能力补齐

- [x] 补齐 systemd drop-in、service env 文件和服务启动/status 检查规划。
- [x] 补齐网络配置、TLS/证书、SSH host key、系统环境变量和 anacron/at jobs 的可见审查事实。
- [x] 补齐语言运行时目录识别和重装建议，不默认复制 cache。
- [x] 补齐 merge-aware 配置审查、目标多余文件清理审查和迁移后健康检查报告动作。
- [x] 补齐 `copy_data_path` 新建路径的删除型 rollback entry。
- [x] 补齐 Docker/Podman network/container 恢复计划、存储挂载操作清单和交互式选择清单输出。
- [x] 补齐 chunk/rsync 续传口径和文档，避免把文件级增量误说成字节块级。
- [x] 更新 README、技术设计、覆盖审计和待办表。
- [x] 运行 `scripts/check.sh` 并记录验证结果。

## 当前执行切片：另一模型改动完成度评估

- [x] 审查另一模型声称完成后的工作区 diff，确认改动覆盖 resources 精度、用户级 bin、ELF 静态动态依赖摘要、source-host+rsync、容量预检、service drop-in/env、anacron/at、network/container review、delete_created_path rollback 等。
- [x] 运行 `scripts/check.sh`，确认当前工作区统一门禁通过，输出包含 `all checks passed`。
- [x] 确认 P0/P1 中多项业务能力已真实落地为代码和测试，不只是文档更新。
- [x] 修正文档/help 中老旧或易误解口径：`scan` 模块数包含 resources、`source-host + rsync` 的 identity 语义、service start 高风险可选执行和删除型 rollback 风险。
- [x] 审查发现默认对未托管 executable 运行 `ldd` 有安全边界问题；已改为 `readelf`/`objdump` 静态解析动态依赖摘要，不默认执行目标 executable 的 loader 路径。
- [x] 审查发现 `services/start/*` 已从 manual_step 变成可执行 `start_systemd_unit`；已删除该 action 类型和 handler 支持，默认只生成 `services/review-start/*` 与 `services/check-status/*` 人工步骤。
- [x] 审查发现 `source-host + rsync` 只把 `--identity-file` 用于控制机连接源机，源机推目标机仍使用源机本地默认 SSH 身份；已在 transfer plan 增加 `remote_source_note`，preflight 要求源机具备 `rsync`/`ssh` 并能 BatchMode SSH 到目标机。
- [x] 审查发现 `delete_created_path` rollback 会 `rm -rf` HostLift 新建路径；已在 rollback dry-run 和执行输出中突出提示会删除整个 HostLift 新建路径，apply 后新增数据也会删除。

## 当前执行切片：P0 风险收口

- [x] 将 resources 未托管 executable 的默认依赖审查从 `ldd` 改为 `readelf`/`objdump` 静态解析，schema 字段改为 `dynamic_link_summary`。
- [x] 删除 `start_systemd_unit` action 类型和 handler/rollback 支持，systemd 运行态差异默认只生成 `services/review-start/*` 和 `services/check-status/*` 人工步骤。
- [x] 为 `source-host + rsync` 增加 `remote_source_note`，并在 preflight 中检查源机具备 `rsync`/`ssh`，且源机能 BatchMode SSH 到目标机。
- [x] 为 `delete_created_path` rollback dry-run 和执行输出增加整路径删除提示，明确 apply 后新增数据也会被删除。
- [x] 更新 README、USAGE、PRD、TECH_DESIGN、ARCHITECTURE、CODE_QUALITY、覆盖审计和本清单的对应口径。
- [x] 运行 `scripts/check.sh`，输出包含 `fake remote smoke passed` 和 `all checks passed`。

## 当前执行切片：95% 完整迁移能力复审

- [x] 复查 P0 风险收口代码：未托管 executable 默认改为静态依赖解析；systemd 服务启动默认人工 review；delete_created_path 回滚输出强提示；transfer plan 有 remote source note。
- [x] 运行 `scripts/check.sh`，确认当前工作区统一门禁通过，输出包含 `all checks passed`。
- [x] 复审发现 `hostlift transfer --approve` 会执行 source-host rsync 的源/目标依赖 preflight，但 `hostlift apply` 内部文件型 action 直接调用 transfer executePlan，未复用 transfer source/target preflight；已在文件型 apply handler 中补齐 transfer source/target preflight。
- [x] 复审判断：对个人常见 Linux 服务器，当前可以覆盖大多数包、配置、用户、cron、项目目录、home 状态、resources、容器线索和传输场景；但数据库一致性、网络/存储自动应用、密钥材料、运行态恢复和内容安全扫描仍需要人工确认，不能无条件宣称“一键 95% 完整迁移”。

## 当前执行切片：个人迁移剩余 P0/P1 收口

- [x] `hostlift apply` 内部文件型 action 复用 transfer source/target preflight，`source-host + rsync` 会在 apply 阶段检查目标 `rsync`、源机 `rsync/ssh` 和源机到目标机 BatchMode SSH 连通性。
- [x] `copy_data_path`/`copy_project_path` 执行前实时计算源路径 `du` 大小，并用目标 `df` 复核可用空间和 inode；本轮又补了源端 file_count/`find` 条目数估算，不足时失败关闭。
- [x] `appdata` 的 `database_data`/`docker_data` 不再生成热复制 `copy_data_path`，改为 `appdata/dump-restore/<path>` 人工步骤。
- [x] `delete_created_path` rollback 改为复制成功后写入带 `stat:v1:<bytes>:<file_count>:<mtime>` 基线的 entry；rollback 前基线不匹配会失败关闭。
- [x] 关键 scan warning 升级为 plan 中的 critical `scan-warning/<source|target>/<module>` 人工步骤，覆盖 users、ssh、sudoers、acl、storage、system_baseline、resources、security_policy。
- [x] plan summary 增加个人迁移推荐批次：基础包/用户、配置/SSH/home、数据/项目/resources、服务/cron/firewall/container、人工高风险审查；本轮又在顶部模块统计单独展示 Resources 数量。
- [x] resources 轻量安全报告、脚本安装来源/版本/checksum/config hint、HTTP/TCP/日志健康检查提示已进入 scan/plan/report。
- [x] 经评估不纳入本次默认实现：可插拔 ClamAV/YARA/hash allowlist、完整 TUI、块级 chunk、多发行版矩阵仍保留后续。

## 当前执行切片：个人迁移业务能力二次补齐

- [x] resources schema/scanner 增加 `sha256`、`owner_group`、`mode`、`mtime_unix` 和 `security_summary`，目录做有限深度 suid/sgid、world-writable、隐藏路径摘要。
- [x] resources plan 增加 `resources/security-review/<path>` 和大目录 `resources/verify-manifest/<path>` 人工步骤，target-only cleanup 描述包含大小、文件数、owner/mode。
- [x] 脚本安装候选从应用名枚举改为通用分类：`user_binary`、`runtime_manager`、`package_manager`、`config_state`、`install_root`；扫描用户级 bin 和运行时目录，并提取 source URL、version、checksum、config hint。
- [x] Docker/Podman 容器扫描增加运行中容器 mount 摘要；volume 被运行中容器结构化 mount source 精确引用时，plan 先生成 `docker/stop-writers/<volume>` 人工步骤，再允许显式选择 volume copy。
- [x] systemd service 扫描通过 `systemctl show` 记录 Requires/Wants/After/EnvironmentFiles/ExecStart 摘要；plan 对依赖摘要差异生成 `services/review-deps/<unit>`。
- [x] TLS/证书、SSH host key、防火墙、服务状态、网络监听和 home config 描述已补充更明确的人工决策、连通性检查和 owner/group/mode 校验语义。
- [x] operation state JSONL 写入增加文件锁，降低多实例并发追加损坏风险。
- [x] appdata `dump-restore` 人工步骤补齐具体数据库/队列/搜索服务的 dump、restore 和一致性操作清单；仍不自动执行备份恢复命令。
- [x] 经评估不纳入本次默认实现：可插拔杀毒/规则扫描 provider、自动执行数据库 dump/restore hook、完整 TUI、远程源 chunk、字节块级 chunk、多发行版矩阵。

## 当前执行切片：个人迁移体验与可靠性 P1/P2 收口

- [x] plan summary 顶部模块统计单独展示 Resources 数量。
- [x] apply 容量预检用源端 file_count 和实时 `find` 估算 inode 需求，避免大量小文件迁移到一半才失败。
- [x] `delete_created_path` rollback 基线从单纯 `du` 增强为 bytes/file_count/mtime 摘要，回滚前不匹配则失败关闭。
- [x] `source-host + rsync` 增加源机到目标机 BatchMode SSH 连通预检，不只检查源机本地是否有 `ssh`。
- [x] Docker volume stop-writers 从简单字符串包含匹配改为结构化 mount token 匹配，降低误报/漏报。
- [x] 更深目录级 verify 保持 opt-in/人工步骤，不作为默认重型校验门禁。

## 当前执行切片：个人迁移最终收口复审

- [x] 复核 apply 文件传输 preflight、apply 前容量复核、delete_created_path rollback 基线、有状态数据 dump/restore 清单、resources 轻量安全报告、systemd 依赖摘要、Docker stop-writers、operation state 文件锁和网络/SSH/TLS/健康检查提示，确认均有源码或文档证据。
- [x] 修正 `CODE_QUALITY_zh.md`、`TECH_DESIGN_zh.md` 和 `docs/migration_coverage_audit_zh.md` 中老旧口径：关键 scan warning、operation state 文件锁、脚本安装 hint 和“个人默认迁移还必须硬做”的表述。
- [x] 复审判断：当前可称为“个人服务器选择性迁移主线基本补齐”；简单应用/项目服务器可以覆盖接近 95% 的迁移工作量，但不应承诺复杂有状态、存储、认证、网络或安全扫描场景的一键 95% 自动完成。

## 当前执行切片：个人迁移轻量体验增强

- [x] 按用户最新口径确认：当前不继续推进企业审批、RBAC、Vault、SSO、SIEM 或企业任务队列，个人迁移主线优先。
- [x] 删除误加入的“企业治理 P0 基础 contract”执行切片，避免后续模型误做企业治理。
- [x] 将 `plan --selection` 从平铺 action 清单增强为按个人迁移批次分组的选择清单。
- [x] 新增 `plan --health-report`，从已有 plan action 汇总迁移后健康检查报告，不执行远程探测或阻断 apply。
- [x] 更新 README/USAGE/help/TASK_PROGRESS_zh.md，明确这是个人轻量体验能力，不是企业控制台。
- [x] 运行 `scripts/check.sh` 并记录验证结果。

## 当前执行切片：文档一致性审计

- [x] 核对 README/USAGE/PRD/ARCHITECTURE/CODE_QUALITY/TECH_DESIGN/CHANGELOG/覆盖审计是否仍包含旧 CLI、旧回滚基线或过度企业化口径。
- [x] 将旧 `export/import`、`--modules`、`--bundle` 示例改成当前 `scan`/`plan`/`apply`/`transfer` 工作流，或明确标为后续设想。
- [x] 将删除型 rollback 文档从 `du` 基线更新为 bytes/file_count/mtime 基线。
- [x] 将个人迁移批次、`plan --selection`、`plan --health-report` 和 dump/restore 人工清单口径统一到当前实现。
- [x] 运行文档/项目质量门禁并记录结果。

## 已完成并有证据的项目质量项

- [x] README 已使用中文说明安装、使用流程、常用命令、定点传输、远程命令、审计和回滚。
- [x] `TECH_DESIGN_zh.md` 已说明技术实现、代码设计思路、架构分层、模块边界和扩展方式。
- [x] `ARCHITECTURE_zh.md` 已记录源码目录、模块关系、工作流和设计决策。
- [x] `CODE_QUALITY_zh.md` 已记录代码质量、文件长度、企业级差距和重构建议，并按当前工作区更新过最大文件评估。
- [x] `PRD_zh.md` 已记录产品需求、市场需求和版本路线。
- [x] `scripts/check.sh` 已作为统一质量门禁，覆盖构建、测试、帮助输出、fake remote smoke、空白检查和 public function 中文注释检查。
- [x] 最近一次验证命令 `scripts/check.sh` 通过。

## 执行过程中必须持续维护的清单

- [ ] 每次新增多步骤任务时，在本文件新增“当前执行切片”或追加到已有切片。
- [ ] 每完成一个可验证事项，立即勾选对应条目。
- [ ] 每发现一个新缺口，写入“新发现问题”或“长期能力缺口”。
- [ ] 每次关闭 goal 前，把验证命令和结果写入“验证记录”。

## 新发现问题

- [ ] 后续每次分析出的代码质量、架构、文档、测试或产品缺口，都必须在这里留下条目，避免只存在于对话里。
- [ ] 本机 macOS 完整 `scan --summary` 在 resources 扫描部分遇到 `unexpected errno: 102` 时会输出 Zig 调试栈但命令返回 0；Linux 个人迁移主线非阻塞，后续应让 `resources` 路径大小探测对未知 errno 安静跳过并记录 scan warning。
- [x] 新增 system baseline scan-only 模块：locale/timezone、NTP、sysctl、limits、PAM、SSSD/LDAP、NSS、DNS、logrotate、tmpfiles.d、内核模块加载配置。
- [x] storage/system baseline 扩展只读事实：LVM、ZFS、Btrfs、crypttab、NFS/autofs、exports；默认只生成人工审查项。
- [x] users plan 阶段增加 UID/GID/name 冲突解释，避免只在远程 useradd 失败后才发现。
- [x] scan_runner 对用户/认证/存储等关键模块失败应升级成更强 warning 或 manual_step，避免空清单被误解为无需迁移；plan 阶段已将关键 scan warning 升级为 critical manual_step。
- [x] operation state JSONL 增加文件锁，避免多实例并发写损坏。
- [x] Docker 镜像列表和脚本安装应用做 scan-only/reinstall 建议，不默认复制缓存、二进制和隐含依赖。
- [x] Docker volume mountpoint 生成可选高风险数据复制 action，复用现有文件同步能力。
- [x] 修复 mountinfo 八进制转义解析，避免含空格挂载路径解析错误。
- [x] system_baseline 从路径存在性推进到关键配置值 scan-only 和 plan review。
- [x] `/etc/hosts` 差异生成可选文件型迁移动作。
- [x] sshd_config 关键认证/连通性指令进入 scan-only 审查。
- [x] appdata 接入文件型 rollback handler。
- [x] appdata 和 Docker volume rollback dispatcher 路由已补齐。
- [x] scan registry 的 dev_env/processes 命名已清理，不再保留 security/kernel 旧模块别名。
- [x] 进程扫描记录完整命令行摘要。
- [x] resources 对 `/usr/local/bin/tool` 这类未托管 PATH 可执行文件会归并为 `/usr/local/bin` install root 并默认 copy，和“单文件 executable 默认 review”的产品语义不完全一致，存在夹带同目录历史二进制或垃圾文件的风险；已改为常见 bin 目录直下 executable 默认单文件 review。
- [x] resources 的 `copy_data_path` 对目标原本不存在、apply 后新建的路径已写入 `delete_created_path` rollback entry；目标已存在路径仍失败关闭，避免覆盖未知内容。
- [x] resources 已注册 apply/verify/rollback handler，registry 测试已覆盖 resources 的 apply/verify/rollback 支持声明。
- [x] `docs/migration_coverage_audit_zh.md` 仍按 2026-06-13 口径描述“非包管理器二进制完全不扫描”，与 resources v1 当前实现不一致，需要更新或标注为历史审计。
- [x] resources 已补 ELF `file`/静态动态依赖审查、SHA256、owner/mode/mtime、suid/sgid、world-writable、隐藏路径等轻量风险报告；仍不默认做 YARA/ClamAV/签名校验这类重型内容安全门禁。
- [x] resources 默认调用 `ldd` 审查未托管 executable 的动态库摘要存在不必要执行风险；已改为 `readelf`/`objdump` 静态解析，失败时只输出 parser 不可用/无动态依赖提示。
- [x] `services/start/*` 可执行 action 当前会随普通 `apply --approve` 执行；已删除 `start_systemd_unit` action 和 handler 支持，默认只生成人工 review/status 步骤。
- [x] `source-host + rsync` 需要源机能 SSH 到目标机；已在 help/文档说明 identity 语义，transfer plan 输出 `remote_source_note`，preflight 检查源机具备 `rsync`/`ssh` 并能 BatchMode SSH 到目标机。
- [x] `delete_created_path` rollback 语义需要提示“删除整个 HostLift 新建路径”；dry-run 和执行输出已提示 apply 后新增数据也会被删除，且现在会用复制成功后的 bytes/file_count/mtime 基线做变更检测。
- [x] `apply --source-host --transfer-transport rsync` 的文件型迁移动作还没有复用 `transfer` 子命令的 source/target preflight；已在文件型 apply handler 中补齐。
- [x] plan summary 顶部模块统计已单独展示 Resources 数量，resources 不再只隐藏在推荐批次中的 Data/projects/resources。
- [x] apply 前容量复核已用 action file_count 和实时 `find` 估算 inode 数量需求，目标 inode 不足会提前失败。
- [x] `delete_created_path` rollback 的防误删基线已从 `du` apparent size 增强为 bytes/file_count/mtime；仍是轻量防误删，不替代完整 manifest/hash。
- [x] Docker/Podman volume `stop-writers` 判断已改为结构化 mount source token 精确匹配 volume name 或 mountpoint，降低误报和漏报。

## 个人服务器迁移业务能力待办

这些是当前个人服务器迁移更值得优先做的业务能力。在线审批、RBAC、Vault、SIEM 级集中审计等企业能力不作为当前个人使用主线。

| 优先级 | 功能点 | 当前欠缺 | 建议约束 |
| --- | --- | --- | --- |
| P0 | resources 单文件边界 | 已补：`/usr/local/bin/tool`、`/opt/bin/tool`、用户级 bin 直下 executable 默认单文件 review，不再复制整个父级 bin | 保持分类回归；只有明确 install root 才建议 copy |
| P0 | 用户级 bin 扫描 | 已补：主动扫描 `~/go/bin`、`~/.cargo/bin`、`~/.local/bin`、`~/.deno/bin`、`~/.bun/bin`、`~/.npm-global/bin` | 通用路径规则，不按应用名硬编码 |
| P0 | ELF 静态动态依赖审查 | 已补：未托管 executable 输出 `file` 类型和 `readelf`/`objdump` 静态动态依赖摘要 | 只生成报告和 manual_step，不默认阻断迁移，不默认运行可疑 executable |
| P0 | 脚本安装应用重装提示 | 已补：未托管 executable/install root 会生成通用 `resources/reinstall/<path>`；`system_baseline.script_apps` 基于通用用户 bin/runtime/package-manager 路径识别脚本安装候选，并提取 source URL、版本、checksum、config hint | 来源不可信时只提示人工确认，不自动执行下载重装；不按具体应用名硬编码 |
| P0 | P2P/远程源传输 | 已补：`source-host + rsync` 支持源机推目标机，减少控制机中转；preflight 检查源机 `rsync`/`ssh` 并从源机 BatchMode SSH 探测目标机，plan 说明 identity 语义；仍缺远程源 chunk/agent | 继续保持 SSH 编排，不先做常驻 agent |
| P0 | 有状态服务备份提醒 | 已补：MySQL/PostgreSQL/Redis/MongoDB/Elasticsearch/RabbitMQ/Kafka 常见数据目录进入 sensitive review；`appdata` database/docker data 改为 `dump-restore` 人工步骤，并带 engine/dump/restore/consistency 操作清单，不再自动热复制 | 不直接复制热数据；自动执行 hook 未来必须显式 opt-in |
| P0 | 目标容量预检 | 已补：storage scan 记录挂载容量、inode、内存和 swap；plan 根据默认 copy resources 输出 `resources/capacity/<name>` 字节/inode 风险；apply 递归复制前实时 `du`/`find`/`df` 复核容量和 inode | 不做重型安全门禁，空间不足直接失败 |
| P1 | service drop-in | 已补：扫描 `/etc/systemd/system/*.d/*.conf` 和 drop-in 摘要，差异进入 review/merge | scan/plan 先行，apply 保守，复杂内容进入 manual_step |
| P1 | service env 文件 | 已补：扫描 `/etc/default/*`、`/etc/sysconfig/*` 和 `EnvironmentFile=` 引用 | 作为服务依赖配置展示，避免只迁 unit 不迁环境 |
| P1 | 网络配置 | 已补：NetworkManager、netplan、systemd-networkd 路径和 `ip`/`nmcli`/`networkctl` 摘要进入 scan-only review | 默认 manual_step，避免迁移时断网 |
| P1 | TLS/证书 | 已补：TLS/证书路径进入系统基线事实和人工审查，并区分 Let's Encrypt、CA bundle、业务证书引用和私钥决策提示 | 默认人工确认；私钥可选择迁移，但必须高风险标记 |
| P1 | SSH host key | 已补：记录 key 类型、公钥指纹、私钥/公钥存在性，并生成 `ssh/review-host-key/<type>` | 给“保留新 key / 复制旧 key / 只记录指纹”选择和风险提示 |
| P1 | 系统环境变量 | 已补：`/etc/environment`、`/etc/profile`、`/etc/profile.d` 和全局代理/PATH 摘要进入 review | scan + review，谨慎 apply |
| P1 | anacron/at jobs | 已补：`/etc/anacrontab`、periodic dirs、`atq`、`/var/spool/at` 来源进入 review | 先做审查提示，不自动 replay 一次性任务 |
| P1 | merge-aware 配置 | 已补：hosts、nginx、systemd、ssh、resolver、network 等高风险路径生成 merge review | 提供 diff/merge 建议；默认不盲目覆盖复杂目标文件 |
| P1 | 新建目录 rollback | 已补：`copy_data_path`/`copy_project_path` 对新建目标路径写 `delete_created_path` rollback entry，带复制成功后的 bytes/file_count/mtime 基线；rollback 前不匹配则失败关闭 | 已存在路径仍失败关闭，不覆盖未知内容；基线是轻量防误删，不替代快照 |
| P1 | 语言运行时 | 已补：识别 nvm/pyenv/conda/pipx/uv/npm global/pnpm/yarn/go/rust 等运行时目录并生成 review；脚本候选会提取版本/source/checksum/config hint | 识别环境和重装建议优先，不默认复制 cache |
| P2 | systemd review-start/status | 已补：源端 active-like 而目标端未运行时生成 `services/review-start/<unit>` 和 `services/check-status/<unit>` 高风险人工步骤 | 默认不自动启动服务，提供状态检查报告 |
| P2 | Docker/Podman network | 已补：network/container 缺失生成重建和健康检查提示；volume mountpoint 可生成高风险复制动作；运行中容器 mount 摘要会触发 `docker/stop-writers/<volume>` 人工步骤 | 先重建 compose/network plan，volume 仍要求停写或备份 |
| P2 | 存储挂载向导 | 已补：fstab、NFS/CIFS/autofs、LVM/ZFS/Btrfs 生成操作清单式 review | 生成操作清单和目标能力检查，不自动改底层存储 |
| P2 | chunk 强续传 | 现在是文件粒度 chunk，不是字节块级断点续传 | 后续做大文件断点；保持现有 rsync 简单路径 |
| P2 | 目标多余文件清理 | 已补：目标多余资源生成 `resources/cleanup-review/<path>`，描述包含磁盘占用、文件数、owner/mode，不自动删除 | 必须显式审查后清理，不能默认删除 |
| P2 | 迁移后健康检查 | 已补：监听端口、service 状态、container/network、HTTP/TCP 探测建议、journal/log tail 和失败摘要提示进入健康检查步骤 | 做 report，不做重型安全门禁 |
| P2 | 交互式选择 | 已补：`hostlift plan --selection` 输出按个人迁移批次分组的可勾选 action 清单；`plan --health-report` 输出迁移后检查报告；完整 TUI 仍是后续增强 | 文本向导优先于 Web 企业控制台 |

## P2P/远程源传输加固建议

个人使用优先业务能力和可靠性，不要上来做复杂安全体系。

| 项目 | 建议 |
| --- | --- |
| 第一阶段 | 已支持 `source-host + rsync`：控制机 SSH 到源机，由源机执行 rsync 推到目标；不引入常驻 agent |
| 必要校验 | host/path/argv 继续走现有 `security/*` 和 `remote/*` 边界 |
| 性能 | 继续支持 `--partial`、`--resume`、`--bwlimit` |
| 可靠性 | preflight 检查目标有 rsync、源机有 rsync/ssh，并从源机 BatchMode SSH 探测目标；实际源机到目标机的 SSH 认证仍依赖源机本地配置 |
| 校验 | 大目录默认做存在性、容量和文件数校验；checksum 做可选增强 |
| 不建议先做 | 常驻 agent、复杂认证系统、重型加密协议重造、企业审批平台 |

## 非当前个人迁移优先的长期增强

这些不是当前个人服务器迁移主线待办，只保留为未来可能扩展或历史缺口记录。后续模型不要优先实现这些内容，除非用户明确切换到企业平台目标。

- [ ] 真实用户身份认证和 RBAC。
- [ ] 在线审批校验、审批签名和可信审批 provider。
- [ ] Vault、短期 SSH 凭据、凭据租约和密钥轮换。
- [ ] 可靠审计队列、SIEM 级集中存储、外部签名和时间戳锚定。
- [ ] 字节块级 chunk 传输、强断点续传和显式批准后的目标多余文件清理执行。
- [ ] 更深的 action 级 verify 和完整非文件副作用 rollback。
- [ ] sudoers、ACL、SELinux/AppArmor、storage 的自动 apply/rollback。
- [ ] Docker/Podman network、运行中容器状态的自动迁移和恢复。
- [x] Podman image/volume/network/container scan-only provider 已接入；自动 apply/verify/rollback 仍未接入。
- [ ] 扫描器测试覆盖补齐，尤其 cron、configs、home_configs、appdata、projects、firewall、processes 和 dev_env 系列。
- [ ] systemd/SysV/OpenRC 的受控 start/stop/restart 语义和更多发行版 fixture。
- [ ] 多发行版容器或虚拟机集成测试矩阵。
- [ ] Web/API 控制面和任务队列；完整 TUI 只作为后续体验增强，不进入企业审批主线。
- [ ] P2P/agent/远程源 chunk provider；`source-host + rsync` 第一阶段已支持源机推目标机，仍缺常驻 agent 或 chunk 远程源能力。
- [ ] 可信脚本安装 reinstall provider：当前已识别安装痕迹、版本、来源 URL、校验和和 config hint；仍不自动执行未知下载脚本，未来如要自动重装必须先做来源信任和校验策略。
- [x] resources 通用资源地图已接入，可基于包管理器归属和引用关系发现未托管 executable/install root；可信 reinstall provider 仍未完成。
- [ ] 内容级安全评估 provider：当前已有轻量 SHA256/权限/mtime/隐藏路径/静态动态依赖报告；可插拔 ClamAV/YARA/hash allowlist、签名/来源校验仍是后续可选能力，不作为默认门禁。

## 企业级完整评估缺口

以下缺口只在目标切换为“企业迁移平台”时进入主线；个人服务器迁移不应默认实现这些重能力。

| 优先级 | 能力域 | 当前状态 | 企业级缺口 |
| --- | --- | --- | --- |
| E-P0 | 身份认证与授权 | 只有本地 operator 字段、policy 和 host-authz 约束 | 需要 SSO/OIDC/SAML、用户/组/角色、RBAC/ABAC、主机组授权、最小权限和操作委派 |
| E-P0 | 在线审批与变更治理 | 有本地 approval ticket/receipt 和 HMAC 凭证 | 需要在线审批 provider、双人审批、变更窗口、审批撤销、审批人与执行人分离、工单系统回写 |
| E-P0 | 企业凭据托管 | 支持 identity file、ssh-agent、env；vault provider 预留失败关闭 | 需要 Vault/云 KMS/短期 SSH 证书、凭据租约、自动轮换、审批绑定、凭据使用审计 |
| E-P0 | 中央审计与防篡改 | 有本地 JSONL、hash chain、syslog/HTTPS sink、replay | 需要可靠队列、断点补发、mTLS、外部时间戳、对象存储/WORM、SIEM 字段映射、审计保留策略 |
| E-P0 | 任务队列与控制面 | 当前是单机 CLI 执行 | 需要 API/TUI/Web 控制面、任务状态机、分布式锁、重试/取消/暂停/恢复、并发限制、批次编排 |
| E-P0 | 深度 verify | 已有基础 verify 和人工健康检查提示 | 需要每个 action 的前置/后置 contract、内容级校验、服务健康门禁、失败自动分级和证据归档 |
| E-P0 | 完整 rollback/恢复 | 文件型和部分命令型 rollback 已有；复杂副作用多为人工审查 | 需要所有 action 的 rollback contract、快照集成、非文件副作用恢复、恢复演练和失败降级策略 |
| E-P0 | 多发行版认证矩阵 | 有单元测试和 fake remote smoke | 需要 Debian/Ubuntu/RHEL/Fedora/Arch/Alpine/SUSE 等真实矩阵、systemd/SysV/OpenRC fixture、包管理器故障注入 |
| E-P0 | 数据与业务一致性 | 数据库/Docker 数据默认生成人工 dump/restore 清单 | 需要应用级 dump/restore provider、停写编排、备份校验、恢复校验、版本兼容和回滚策略 |
| E-P0 | 内容安全与供应链 | resources 有轻量 SHA256/权限/mtime/静态依赖报告 | 需要 ClamAV/YARA/hash allowlist、签名校验、SBOM、来源可信度、脚本安装自动重装的信任策略 |
| E-P1 | Agent/P2P 传输 | 已有 scp、rsync、source-host rsync 和文件粒度 chunk | 需要远程源 chunk/agent、字节块级断点续传、端到端 checksum、对象存储 staging、限速/拥塞控制 |
| E-P1 | 资产与拓扑管理 | inventory 是文件输入输出 | 需要资产库、主机标签、依赖拓扑、环境/业务线分组、迁移波次和容量预测 |
| E-P1 | 策略中心 | 本地 policy 文件可约束风险、模块、host、operator | 需要签名策略、中央策略分发、策略版本、例外流程、策略模拟和策略审计 |
| E-P1 | 机密与敏感数据治理 | inventory/plan 避免写 secret，但仍是本地文件流 | 需要敏感字段分类、红action 策略、inventory/plan 加密、访问审计和保留/销毁策略 |
| E-P1 | 容器和存储 provider | Docker/Podman、storage 多数是 scan/review | 需要容器 network/volume/image/apply/verify/rollback provider，LVM/ZFS/Btrfs/NFS/CIFS/cloud disk provider |
| E-P1 | 网络与云环境 provider | 网络、防火墙以本机事实和人工审查为主 | 需要云安全组、负载均衡、DNS、弹性 IP、路由表和证书自动化 provider |
| E-P1 | 可观测性 | 有 audit 和 operation state JSONL | 需要 metrics、tracing、任务 SLA、失败聚合、告警、仪表盘和容量/耗时预测 |
| E-P1 | 插件/SDK | 模块 registry 已有内部边界 | 需要稳定 provider SDK、版本兼容、插件签名、沙箱、能力声明和第三方测试套件 |
| E-P2 | 发布与合规 | 有 check.sh 和基础文档 | 需要发布流水线、签名制品、SBOM、CVE 扫描、升级/降级兼容、配置迁移和支持策略 |
| E-P2 | UX/运营 | `plan --selection` 是批次化文本清单，`plan --health-report` 是本地健康检查报告 | 需要企业控制台、权限视图、批次看板、审计报表、Runbook 导出和操作培训材料 |

## 验证记录

- 2026-06-12：`scripts/check.sh` 通过，输出包含 `all checks passed`。
- 2026-06-12：`./scripts/build-linux.sh` 通过，输出包含 `dist/x86_64-linux-musl/bin/hostlift` 和 `dist/aarch64-linux-musl/bin/hostlift` 构建成功。
- 2026-06-12：Linux 换机遗漏评估和 Maven/Cargo/Gradle/Go 配置扫描补充后，`scripts/check.sh` 与 `./scripts/build-linux.sh` 均通过。
- 2026-06-12：Linux 系统基线 scan-only、Docker 镜像扫描和 UID/GID 冲突检测补充后，`scripts/check.sh` 与 `./scripts/build-linux.sh` 均通过。
- 2026-06-28：P0 resources 精度修正后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`。
- 2026-06-28：P0 脚本安装应用重装提示接入后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`。
- 2026-06-28：P0 P2P/远程源传输第一阶段 `source-host + rsync` 接入后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`。
- 2026-06-28：P0 有状态服务备份提醒接入后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`。
- 2026-06-28：P0 目标容量预检接入后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`。
- 2026-06-28：P1/P2 个人服务器迁移能力补齐和文档口径清理后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`。
- 2026-06-12：Docker volume mountpoint 可选复制动作和 mountinfo 八进制转义修复后，`scripts/check.sh` 与 `./scripts/build-linux.sh` 均通过。
- 2026-06-12：system_baseline 关键配置值解析、sshd_config 审查、`/etc/hosts` 可选迁移动作、appdata rollback 和用户扫描失败显式化后，`scripts/check.sh` 与 `./scripts/build-linux.sh` 均通过。
- 2026-06-12：rollback dispatcher 路由、scan registry 命名、process args、readWholeFile 上限、公共 helper、Podman scan-only provider 和测试临时文件隔离修复后，`scripts/check.sh` 与 `./scripts/build-linux.sh` 均通过。
- 2026-06-28：整机 resources 资源地图和脚本/手工安装通用检测接入后，`scripts/check.sh` 通过，输出包含 `all checks passed`。
- 2026-06-28：resources v1 完成度评估后，`scripts/check.sh` 通过，输出包含 `all checks passed`。
- 2026-06-28：个人服务器迁移业务能力待办审计和文档更新后，`git diff --check` 通过。
- 2026-06-28：个人服务器迁移 P0/P1/P2 待办表、P2P 加固建议和企业能力降级说明更新后，`git diff --check` 通过。
- 2026-06-28：另一模型改动完成度评估后，`scripts/check.sh` 通过，输出包含 `all checks passed`；评估仍发现 `ldd` 默认执行、service start 默认可执行、source-host rsync 身份语义和 delete rollback 数据删除提示四项需后续处理。
- 2026-06-28：修正文档/help 中 resources 模块数、source-host rsync identity 语义、service start 高风险可选执行和 delete rollback 风险提示后，`scripts/check.sh` 通过，输出包含 `all checks passed`。
- 2026-06-28：95% 完整迁移能力复审后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`；仍发现 apply 内部文件型传输未复用 source-host rsync preflight。
- 2026-06-28：P0 风险收口后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`。
- 2026-06-28：个人迁移剩余 P0/P1 收口后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`。
- 2026-06-28：个人迁移业务能力二次补齐后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`；覆盖 resources 轻量安全报告、脚本安装 hint、Docker volume stop-writers、systemd 依赖摘要、健康检查提示和 operation state 文件锁。
- 2026-06-28：最终收口审计后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`；本次确认本轮应做项已完成，不纳入当前个人默认实现的能力已移入长期增强或明确保留后续。
- 2026-06-28：个人迁移体验与可靠性 P1/P2 收口后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`；覆盖 plan summary Resources 计数、容量/inode 复核、bytes/file_count/mtime rollback 基线、source-host rsync BatchMode 连通预检和 Docker volume mount 结构化匹配。
- 2026-06-28：个人迁移最终收口复审和老旧文档口径修正后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`。
- 2026-06-28：rollback baseline parser 收紧后再次运行 `scripts/check.sh`，输出包含 `fake remote smoke passed` 和 `all checks passed`。
- 2026-06-28：个人迁移轻量体验增强后，`zig build test` 通过；`zig build run -- plan --selection` 和 `zig build run -- plan --health-report` 使用轻量 inventory 验证通过；`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`。
- 2026-06-28：文档一致性审计后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`；覆盖 README/USAGE/PRD/ARCHITECTURE/CODE_QUALITY/TECH_DESIGN/CHANGELOG/覆盖审计的旧命令、rollback 基线和个人迁移口径修正。
