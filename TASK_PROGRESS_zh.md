# HostLift 持久进度清单

本文件用于记录跨会话、跨 agent、跨上下文压缩后仍然可见的项目进度。短期 `Updated Plan` 只能反映当前会话，不能替代本文件。

## 当前执行切片：可信 Verified Reinstall Provider

- [x] 定义独立 `hostlift.reinstall_recipes.v1` JSON 合同；recipe 必须绑定现有 reinstall manual action、HTTPS URL、64 位 SHA-256、结构化 install/verify argv、预期 verify 输出摘要和全部新建路径。
- [x] `plan --reinstall-recipes <json>` 只把精确匹配的 `script_reinstall`/`resource_reinstall` 人工项替换为 download -> execute -> verify DAG；未知 URL、缺校验、重复 recipe、非法 argv/path 或非 reinstall action 必须失败关闭。
- [x] 下载必须先落到 source inventory hash 绑定的 `0700`/`0600` artifact，再校验 SHA-256；禁止 `curl | sh` 管道和从 scanner hint 直接执行。
- [x] approved apply 在任何 mutation 前检查 root SSH、命令依赖、artifact/目标路径冲突；install 只执行 recipe 中经过 validator 的 argv，并把 `{artifact}` 替换为受控路径。
- [x] verify 对全部声明路径做存在性检查，并对固定 verify argv 的 stdout 做 SHA-256 比较；下载/安装创建路径写入删除型 rollback baseline，失败中间态也尽量保留恢复证据。
- [x] 收紧 provider 安全边界：recipe 必须声明精确 artifact 字节数并限制/复核下载大小与目标容量；curl 必须忽略 `.curlrc`；`verified_binary` 的 `install` 目标必须精确绑定一个声明的 managed path；明显 secret 参数和 HostLift artifact 路径必须拒绝；手写 plan 中跨 recipe 的 action/path/manual-action 冲突必须由 validator 拒绝。
- [x] 修复失败恢复证据持久性：rollback 准备和失败中间态的新建路径条目必须在 mutation/verify 或错误返回前 flush；最终 verify 必须重新检查 artifact 与全部声明路径，覆盖 resume 间隙。
- [x] 补单元和 fake remote 的成功、校验失败、非法 recipe、后序依赖失败零 mutation、rollback 场景；更新中文 README/技术设计/架构/覆盖审计并运行 `scripts/check.sh`。

## 当前执行切片：首个 PostgreSQL 有状态迁移 Provider

- [x] 增加显式 opt-in 的 PostgreSQL 10+ 整集群逻辑迁移动作；默认仍生成 `appdata_restore` 人工任务，不能静默自动执行数据库命令。
- [x] 以专属 action 和固定 argv 实现 source preflight/dump、artifact 传输、target baseline、restore 和 catalog verify；禁止执行 inventory 中的自由文本 command hint。
- [x] 在任何 mutation 前失败关闭校验 `--source-host`、源/目标 `sudo -n -u postgres`、同 PostgreSQL major、源端零其它 client backend、目标无业务数据库/角色、artifact 独占路径与容量。
- [x] dump/target baseline 使用 `0600` 受控 artifact，并校验 SHA-256；凭据不得进入 inventory、plan、audit 或 rollback，首版仅支持 postgres OS 用户 peer 认证。
- [x] rollback manifest 记录 target baseline 和“需要人工恢复/重建空目标集群”的真实 recovery evidence；不得把逻辑 restore 伪装成可自动完整回滚。
- [x] 补单元测试和 fake remote 成功/失败/零副作用场景，更新中文 README、技术设计、架构和覆盖审计，并运行 `scripts/check.sh`。

## 当前执行切片：递归迁移动作内容级 Manifest Verify

- [x] `copy_data_path`/`copy_project_path` 默认构建源/目标内容 manifest，比较相对路径、类型、大小和文件 SHA-256；不再只以目标路径存在作为成功证据。
- [x] 全批次 preflight 在任何 mutation 前校验源 manifest 可构建、条目未超限、无不支持的 special file，并检查本地/远程源和目标 manifest 依赖。
- [x] 优化远程 manifest 为安全 argv 批量 stat/hash，覆盖本地源、`--source-host`、普通文件、目录和 symlink；截断或结果不完整必须失败关闭。
- [x] 增加显式 max-entry 与 opt-out CLI 合同、dry-run/帮助提示、单元和 fake remote 回归；mismatch 时 action/run 不得标记 succeeded，rollback baseline 在 verify 前写入并保留。
- [x] 更新中文 README、技术/架构/覆盖审计和验证记录，运行 `scripts/check.sh`。

## 当前执行切片：P0 Action 级迁移兼容性门禁

- [x] 定义唯一的 action 兼容性策略，区分可移植、同架构、同发行版/版本和同包管理器要求；完整主机兼容必须包含架构一致。
- [x] builder 在主机不完全兼容时仍生成候选动作，保留普通项目/数据和结构化人工任务，将不安全自动动作转换为兼容性人工审查项。
- [x] plan validator 对 v2 逐 action 校验兼容性，旧 v1 保持严格全局拒绝；approved apply 在任何 SSH、传输、备份或 mutation 前复用同一门禁。
- [x] 单元测试和 fake remote 覆盖跨发行版、跨版本、跨包管理器、跨架构以及手写 plan 绕过，确认失败路径零远程副作用。
- [x] 更新中文 README、技术/架构/覆盖审计和验证记录，运行 `scripts/check.sh`。

## 当前执行切片：可信只读 Remote Manual Probe

- [x] 扩展 manual task provider spec，允许 planner 深拷贝结构化 verify probe；systemd status/start review 和 Docker/Podman container check 首批接入。
- [x] 定义 `hostlift.manual_probe_report.v1`，绑定 plan SHA-256、manual action、provider/task kind、目标 host、观察时间和逐 probe 状态。
- [x] 实现 systemd、container、TCP、HTTP 只读远程 probe；command/log/manual_evidence 及非法 target 失败关闭为 unsupported/error。
- [x] 增加 `hostlift evidence probe` 和 `hostlift evidence validate-probed`，用 probe report 文件 SHA-256 绑定 manual evidence，不接受 AI 单独自报 passed。
- [x] 保持 probe 不写 apply run-state、不解除 manual_step 拒绝；补 fake remote/单元测试、中文文档并运行 `scripts/check.sh`。

## 当前执行切片：Manual Evidence Hash-Chain Ledger

- [x] 定义 plan-bound `hostlift.manual_evidence.ledger.v1` JSONL，记录已校验证据文件 SHA-256 和 manual task 身份，不保存证据正文或 secret。
- [x] 实现 exclusive file lock、原子追加前全链验证、逐记录 flush、跨 plan 追加拒绝和同 action 重复登记拒绝。
- [x] 增加 `hostlift evidence record` 与 `hostlift evidence verify-ledger`，验证报告列出已登记和缺失 manual action。
- [x] 明确 ledger 只能检测链内篡改，未做外部签名/时间戳锚定，不得作为 apply/run-state/workload 的可信成功凭证。
- [x] 补充篡改、重复、跨 plan、CLI 和文档测试，运行 `scripts/check.sh` 并记录验证证据。

## 当前执行切片：Plan 级 Manual Evidence 完整度报告

- [x] 定义 `hostlift.manual_evidence.completeness.v1`，按 plan 中全部 manual action 汇总 evidence 合同覆盖。
- [x] 实现 `hostlift evidence completeness --plan <json> [--evidence <json>]...`，支持零份或多份 evidence 输入。
- [x] 失败关闭区分 missing、duplicate、invalid 和 unexpected evidence，并保留逐文件错误分类供 AI 修正。
- [x] 报告固定声明 `trust_level=contract_only`，不得写入 run-state、解除 apply 拒绝或把 workload 标成 complete。
- [x] 补充聚合/CLI 测试、帮助和中文文档，运行 `scripts/check.sh` 并记录验证证据。

## 当前执行切片：Manual Evidence 机器合同与只读验证

- [x] 定义 `hostlift.manual_evidence.v1` 封闭 schema，绑定 plan SHA-256、manual action、provider、task kind、operator 和时间。
- [x] 实现 `hostlift evidence validate --plan <json> --evidence <json>`，拒绝跨 plan/action/provider 重用证据。
- [x] 严格校验 manual task 的前置条件、期望输出和 verify probe 逐项覆盖；证据不得保存 secret 原值或任意命令输出。
- [x] 保持 approved apply 对 `manual_step` 的原子拒绝；本切片不得用 AI 自报 succeeded 绕过 verify 或自动执行未知脚本/数据库命令。
- [x] 补充单元测试、CLI help 和中文能力边界文档，运行 `scripts/check.sh` 并记录验证证据。

## 新发现问题：Manual Evidence 信任闭环

- [x] 已补 plan-bound hash-chain ledger、独占锁和篡改/重复检测；外部签名、可信时间戳或不可变存储锚点仍未完成，不能证明提交者身份或阻止整链重建。
- [ ] 已补独立 `evidence probe/validate-probed`、systemd/container provider 和 unsigned report hash/host 绑定；尚未消费到 apply run-state/workload，也没有外部签名，不能因 `status=succeeded` 或本地 report 直接标记 action/workload 完成。
- [x] 已补按 plan 汇总全部 manual action 的 contract-only completeness 报告和 fixed read-only remote probe；外部验签、可信时间锚点和 workload/run-state 消费仍未完成。

## 当前执行切片：Provider 专属 Manual Task 输入合同

- [x] 扩展共享 manual task 构造 API，在保留通用 subject 合同的同时支持 provider 和结构化额外 inputs。
- [x] 将 `system_baseline.script_apps` 的安装路径、类型、来源 URL、版本、checksum、配置目录和重装提示映射到 reinstall task。
- [x] 将 resources 未托管重装事实和 appdata engine/dump/restore/consistency 事实映射到 provider 专属 task inputs。
- [x] validator 和测试覆盖 input 合法性、provider、字段保留及 JSON 输出，更新中文能力边界。
- [x] 运行 `scripts/check.sh` 并记录验证证据；未知下载脚本仍不得自动执行。

## 当前执行切片：工作负载聚合与迁移完成度报告

- [x] 定义 `hostlift.workload_report.v1` 机器合同，按工作负载而不是零散 action 表达迁移状态、组件、阻塞项和证据。
- [x] 聚合 systemd 服务、项目/Compose、应用数据路径、Docker/Podman 容器和未托管资源，并关联源/目标事实与 plan action。
- [x] 实现 `complete`、`pending`、`blocked`、`unknown` 失败关闭判定，扫描截断或关键 warning 时不得误报完整。
- [x] 为 `hostlift plan --workloads` 增加 JSON 输出、CLI help、单元测试和中文能力边界说明。
- [x] inventory 增加向后兼容的 `scan.full_scan` 范围证据；过滤扫描和缺少该字段的旧 inventory 在完成度报告中一律判为 `unknown`。
- [x] 运行 `scripts/check.sh`，记录本切片验证证据和仍未完成的整机迁移缺口。

## 新发现问题：工作负载证据闭环

- [ ] workload v1 尚未读取 apply run-state、manual evidence、audit verify 或远程健康探针；当前必须在执行后重新扫描目标机再生成报告。
- [ ] package/config/user/secret/port 与应用主体的跨模块归属还不完整；无法可靠归属的 action 已保留在 `unassigned_action_ids` 并继续影响 `host_status`，后续不能用名称模糊匹配静默归属。
- [ ] `complete` 只证明当前 scanner 粒度下目标事实匹配；数据库内容一致性、请求级健康、密钥可用和 cutover/回切仍需要 provider/evidence 状态机。

## 当前执行切片：Plan v2 DAG 与 AI 人工任务合同

- [x] 新生成计划升级为 `hostlift.plan.v2`，action 带 phase/depends_on，manual action 带 `hostlift.manual_task.v2` 结构化合同。
- [x] validator 检查依赖存在、唯一 ID、顺序、阶段逆序和环；plan/apply 过滤后拒绝缺失依赖闭包。
- [x] apply 按 run state 验证 dependency 已成功，恢复时保持 DAG 语义；补齐 schema、生成、过滤和 fake remote 回归。
- [x] 更新 README/技术/架构/覆盖审计并运行 `scripts/check.sh`。

## 当前执行切片：完整迁移执行闭环第一阶段

- [x] 将模块专属只读 preflight 纳入 handler 合同，approved apply 在任何 backup/mutation 前检查全部所选 action。
- [x] 文件型 action 前置检查传输依赖、源路径存在性、递归容量/inode 和新建数据目标冲突；service/project 的文件动作复用同一入口。
- [x] fake remote 覆盖“后序 action 缺依赖时前序 action 零 mutation”，并保留单 action executor 的防御性 preflight。
- [x] 设计并实现 migration run/action checkpoint 基础，绑定 plan hash、host、filter、rollback manifest 和 action 状态。
- [x] 更新 README、架构文档和 AI 驱动整机迁移待办，运行 `scripts/check.sh`。

## 当前执行切片：三个 P0 执行安全问题修复

- [x] approved apply 在任何远程副作用前校验全部所选 action 的模块、类型和 handler 支持，混合计划包含 `manual_step` 时原子拒绝。
- [x] rollback manifest 支持 `--rollback-manifest <path>`，默认使用唯一 run 路径，拒绝覆盖已有文件，并在 mutation 前后按 entry 立即 flush。
- [x] `system_baseline` 对敏感环境变量 key 和含 userinfo 的 URL value 写入固定脱敏标记，inventory JSON 和 summary 不保留原值。
- [x] 补齐过滤、参数解析、文件覆盖和脱敏误报边界测试，并运行 `scripts/check.sh`。

## 当前执行切片：AI 驱动整机迁移完成度复审

- [x] 按“同发行版重建、脚本安装应用、有状态服务、跨发行版、跨架构、在线切换”六类场景复审当前迁移能力，不再用单一百分比掩盖场景差异。
- [x] 抽查 inventory、plan schema、compatibility、manual_step、approved apply、verify、rollback manifest、传输元数据和 CI 主路径，核对文档声明与代码边界。
- [x] 确认当前定位应是“同发行版同版本主机的受控重建与文件迁移执行器”，还不是 AI 可闭环的一键整机迁移产品。
- [x] 在 `docs/migration_coverage_audit_zh.md` 增加 AI-first 复审、场景矩阵、关键风险和目标架构流程图。
- [x] 形成 P0/P1/P2 AI 驱动整机迁移待办，并为每项写明可验证的验收标准。

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
- [x] 递归 `copy_data_path`/`copy_project_path` 已改为默认内容级 manifest 校验；可显式 opt-out，扩展元数据保真仍保留为后续能力。

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
- [x] approved apply 已在第一次远程修改前校验全部所选 action 的模块、类型和 apply handler；`manual_step` 或其它 unsupported action 混入批次时会原子拒绝，过滤排除人工项后才继续。
- [x] rollback manifest 默认路径已增加加密随机 run 后缀，`--rollback-manifest` 可显式指定且 existing file 失败关闭；JSONL entry 写入后立即 flush，不再等整个 apply 成功才刷盘。
- [x] `system_baseline` 已按大小写不敏感的敏感 key token 和 URL userinfo 规则脱敏 `/etc/environment`、`/etc/profile`、`/etc/profile.d`，固定写入 `[REDACTED]`，测试覆盖 token/password、带凭据代理 URL 和普通值误报边界。
- [x] compatibility 完整主机判定已包含已知架构；plan v2 已按 action 保留跨主机可移植动作，并将 distro/version/package-manager/arch 不满足的自动动作改写为 `compatibility_review`，validator/apply/workload 共用失败关闭规则。
- [ ] 当前二进制兼容门禁仍只有 `same_arch` 粗分类，尚未把 resources 已扫描的 ELF interpreter、glibc/musl、SONAME、CPU feature 和目标依赖事实接入 copy/reinstall/rebuild/incompatible 决策。
- [x] plan v2 action 已有 phase/depends_on，manual task 已有通用 precondition/output/probe/rollback/evidence 合同；script/resource reinstall 和 appdata restore 专属 inputs 已接入，container/secret inputs 和 evidence 提交仍列在 AI 待办中。
- [x] approved apply 已用 hash-chain migration run state 持久化 run/action 状态，并按 plan/host/filter/rollback 绑定安全续跑；stateful provider/cutover 恢复仍列在 AI 待办中。
- [x] apply 对递归 `copy_data_path`/`copy_project_path` 已默认比较完整源/目标内容 manifest；截断、special file、缺失/额外/变化条目失败关闭，mismatch 不写 succeeded。
- [ ] 传输元数据语义不足以宣称整机文件系统保真：rsync 当前只有 `-a`，没有显式 ACL、xattr/Linux capability、hardlink、sparse file 和 SELinux context 策略；scp 只能保留基础时间和 mode。
- [x] workload v1 已聚合 systemd 服务、项目/Compose、appdata、容器和未托管资源，并输出 complete/pending/blocked/unknown；package/config/user/secret/port 跨模块完整归属和 run/manual/health evidence 合并仍列在新发现问题中。
- [ ] 当前没有停写、最终增量同步、服务启动、健康门禁、DNS/负载均衡切换、失败回切组成的 cutover 状态机，不能承担在线业务的一键换机。
- [ ] CI 只在单个 Ubuntu runner 上运行单元测试和 fake remote smoke，没有 Debian/Ubuntu/RHEL/Fedora/Arch/Alpine/SUSE、x86_64/aarch64 和 systemd/OpenRC/SysV 的真实迁移矩阵。
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

## AI 驱动整机迁移待办

目标不是让 AI 绕过 HostLift 拼 shell，而是让 AI 能读取稳定契约、补齐受控 provider、提交证据，并由 HostLift 判定一台主机或一个 workload 是否迁移完成。

| 优先级 | 能力 | 当前状态 | 验收标准 |
| --- | --- | --- | --- |
| P0 | 全计划执行前置校验 | 已补：support/manual、generic command 和 module preflight 在全部未完成所选 action 上先执行；传输源、目标冲突、容量/inode 也在 mutation 前检查 | 已有 fake remote “后序缺依赖时前序零 mutation”回归；后续由 DAG 补阶段和依赖闭包 |
| P0 | 持久 migration run 与 rollback 证据 | 已补：唯一 run ID、可指定/默认唯一 hash-chain run state、文件锁、plan/host/选择集合/rollback 绑定、逐 action checkpoint、安全续跑和首次 rollback 预备复用 | 已覆盖失败续跑、成功 action 跳过、manifest 不重复、host/plan/filter mismatch 和 hash 篡改；后续扩展到 stateful provider/cutover |
| P0 | inventory/plan 机密脱敏 | system env 敏感 key/URL 已固定脱敏；其它 inventory 字段仍缺统一分类和 `secret_ref` | 按 key/value 规则识别 secret，只写存在性、类型、指纹或 `secret_ref`；测试覆盖 `TOKEN`、`PASSWORD`、带凭据代理 URL 和误报边界，inventory/plan/audit 不出现明文 |
| P0 | `manual_step.v2` 结构化合同 | 已补通用合同；script/resource reinstall 和 appdata restore 已结构化携带 URL/version/checksum/config、artifact/ELF、dump/restore/consistency inputs | 下一步补 container/secret 专属 inputs、可信 executor 和 evidence 提交/校验 |
| P0 | action DAG 与阶段门禁 | 已补 plan v2 phase/depends_on、已知生命周期依赖、缺失/顺序/环/阶段 validator、过滤闭包拒绝和 run-state dependency 门禁 | 继续随 workload/provider 补跨模块边；过滤器保持显式选择，不自动扩大范围 |
| P0 | workload/application 聚合模型 | 已补 `hostlift.workload_report.v1`：聚合五类应用主体、组件、action、blocker、confidence、host status 和未归属 action | 下一步补 package/config/user/secret/port 跨模块归属及 run/manual/health evidence；当前状态使用 complete/pending/blocked/unknown 并对扫描不完整失败关闭 |
| P0 | 兼容性改为 action/workload 级 | 已补第一阶段：全局完整兼容含架构，v2 action 分为 portable/same_arch/same_distro_version/same_package_manager/full_host；builder 改写 compatibility review，validator/apply/workload 共用门禁 | 后续补包名/路径/服务语义 distro provider，以及 ELF interpreter、glibc/musl、SONAME、CPU feature 和目标依赖判定 |
| P0 | 有状态服务迁移 provider | PostgreSQL 首切片已补双 opt-in 五步 DAG、版本/停写/fresh target 门禁、SHA-256、catalog verify 和人工恢复证据；MySQL/MariaDB、Redis、Compose volume 仍只生成人工合同 | 继续逐 provider 补内容级 verify、服务/cutover 编排和可验证恢复；未知数据库命令不得从 inventory hint 执行 |
| P0 | cutover 状态机 | 没有最终增量、流量切换和失败回切 | 支持 pre-copy -> quiesce -> final-delta -> start -> readiness -> switch -> observe -> finalize/rollback；每个不可逆点显式批准，失败时输出可执行恢复路径 |
| P1 | 可信脚本/未托管应用 reinstall provider | 已补显式 HTTPS/size/SHA-256/目标平台/argv/managed-path recipe 和受控三步 DAG；scanner hint 仍不可信 | 后续增加官方发布签名/registry、ELF ABI/依赖验证和脚本声明副作用审计；继续禁止未落盘未校验的 `curl | sh` |
| P1 | 语言生态 provider | nvm/pyenv/pipx/npm/cargo/go 等主要是路径识别 | 导出并恢复机器可读清单，锁定 runtime/tool 版本；区分 cache、可重建依赖、全局工具和项目环境，并验证目标命令版本 |
| P1 | 可执行健康验证 | 已补 systemd/container 自动 probe 合同、TCP/HTTP 固定只读执行器和 `manual_probe_report.v1`；command/log/manual evidence 仍 unsupported，未接入阶段门禁 | 后续从 inventory/provider 推导 TCP/HTTP target，补签名身份、hard fail/warning 策略及 run-state/workload 显式消费 |
| P1 | 递归内容与元数据保真 | 已补默认源/目标内容 manifest、symlink target、special file 拒绝、截断失败关闭、100000 条默认上限和显式 opt-out；ACL/xattr/capability/hardlink/sparse/SELinux context 仍缺 | 继续补扩展元数据策略和真实 Linux 矩阵；任何无法证明的语义保持失败关闭或人工任务 |
| P1 | 冲突与幂等收敛 | 目标已存在路径多为失败或人工 merge | action 声明 create/replace/merge/append/skip 策略和目标前置 hash；重复执行同一 run 不产生额外副作用，目标漂移时失败关闭并给出结构化冲突 |
| P1 | 扫描完整性与来源证据 | warning 是字符串，部分探针失败会返回空或截断 | 每模块输出 complete/partial/skipped/failed、probe 版本、权限、截断原因和覆盖计数；plan 不把 unknown 当 absent，完成度报告显示未知项 |
| P1 | 容器 workload 恢复 | Compose 项目可 copy/up，image/network/volume 仍多为 review | 结构化恢复 compose spec、image digest、network、secret refs、volume backup；启动后验证容器 health、端口和依赖，不用 `docker export` 冒充完整迁移 |
| P1 | 真实 Linux 集成矩阵 | 单元测试 + Ubuntu fake remote | 用容器/VM 覆盖主流发行版和 init/package manager 组合，加入 SSH 断线、磁盘满、源变化、目标漂移、恢复失败、跨架构二进制等故障注入 |
| P2 | 快照与云资源 provider | rollback 不能替代磁盘/数据库快照 | 可选接入云盘/LVM/ZFS/Btrfs snapshot、DNS/LB/EIP/security group provider，并保持显式批准和独立回滚证据 |
| P2 | 字节块级传输与远程源 chunk | 当前整文件 chunk，rsync 是主要续传路径 | 大文件按块 hash、缺块续传、端到端校验；远程源不依赖源机持有目标 SSH 长期身份，失败后按 run checkpoint 恢复 |
| P2 | AI 稳定接口与 schema 演进 | JSON 可读但 inventory 输入不校验 schema version，多个报告仍是文本 | 所有输入严格校验 schema/version，提供 machine JSON 输出、能力协商和兼容升级测试；人类 description 只做展示，不承载唯一执行语义 |

## 个人服务器迁移业务能力待办

这些是当前个人服务器迁移更值得优先做的业务能力。在线审批、RBAC、Vault、SIEM 级集中审计等企业能力不作为当前个人使用主线。

| 优先级 | 功能点 | 当前欠缺 | 建议约束 |
| --- | --- | --- | --- |
| P0 | resources 单文件边界 | 已补：`/usr/local/bin/tool`、`/opt/bin/tool`、用户级 bin 直下 executable 默认单文件 review，不再复制整个父级 bin | 保持分类回归；只有明确 install root 才建议 copy |
| P0 | 用户级 bin 扫描 | 已补：主动扫描 `~/go/bin`、`~/.cargo/bin`、`~/.local/bin`、`~/.deno/bin`、`~/.bun/bin`、`~/.npm-global/bin` | 通用路径规则，不按应用名硬编码 |
| P0 | ELF 静态动态依赖审查 | 已补：未托管 executable 输出 `file` 类型和 `readelf`/`objdump` 静态动态依赖摘要 | 只生成报告和 manual_step，不默认阻断迁移，不默认运行可疑 executable |
| P0 | 脚本安装应用重装提示 | 已补：未托管 executable/install root 会生成通用 `resources/reinstall/<path>`；`system_baseline.script_apps` 基于通用用户 bin/runtime/package-manager 路径识别脚本安装候选，并提取 source URL、版本、checksum、config hint | 来源不可信时只提示人工确认，不自动执行下载重装；不按具体应用名硬编码 |
| P0 | P2P/远程源传输 | 已补：`source-host + rsync` 支持源机推目标机，减少控制机中转；preflight 检查源机 `rsync`/`ssh` 并从源机 BatchMode SSH 探测目标机，plan 说明 identity 语义；仍缺远程源 chunk/agent | 继续保持 SSH 编排，不先做常驻 agent |
| P0 | 有状态服务备份提醒 | 已补：常见数据库目录进入 sensitive review，`appdata` 带 engine/dump/restore/consistency 人工合同；PostgreSQL 另有显式双 opt-in 的受限逻辑迁移 provider | 不直接复制热数据；其它自动 provider 必须显式 opt-in 并使用封闭命令合同 |
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
| 校验 | `copy_data_path`/`copy_project_path` 默认做容量/inode 和源目标内容 manifest；可调条目上限，显式 opt-out 才降级为存在性校验 |
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
- [x] 可信脚本安装 reinstall provider 第一阶段：显式 recipe 绑定现有人工项、HTTPS、精确字节数、SHA-256、目标平台、结构化 argv 和受管路径；scanner hint 仍不自动执行，官方签名/registry 和脚本未声明副作用审计保留为长期增强。
- [x] resources 通用资源地图已接入，可基于包管理器归属和引用关系发现未托管 executable/install root，并可由显式可信 recipe 转换精确 reinstall 人工项。
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
| E-P0 | 深度 verify | 已补递归数据/项目内容级 manifest，服务和其它 action 仍多为基础 verify 或人工健康检查 | 需要每个 action 的前置/后置 contract、服务健康门禁、失败自动分级和证据归档 |
| E-P0 | 完整 rollback/恢复 | 文件型和部分命令型 rollback 已有；复杂副作用多为人工审查 | 需要所有 action 的 rollback contract、快照集成、非文件副作用恢复、恢复演练和失败降级策略 |
| E-P0 | 多发行版认证矩阵 | 有单元测试和 fake remote smoke | 需要 Debian/Ubuntu/RHEL/Fedora/Arch/Alpine/SUSE 等真实矩阵、systemd/SysV/OpenRC fixture、包管理器故障注入 |
| E-P0 | 数据与业务一致性 | PostgreSQL 有首个受限 provider；其它数据库/Docker 数据默认生成人工 dump/restore 合同 | 需要更多应用级 provider、停写/cutover 编排、内容级恢复校验、版本兼容和自动回切策略 |
| E-P0 | 内容安全与供应链 | resources 有轻量 SHA256/权限/mtime/静态依赖报告，显式 reinstall recipe 固定 HTTPS/size/SHA-256/目标平台 | 需要 ClamAV/YARA/hash allowlist、发布签名/透明日志、SBOM、来源可信度和 installer 副作用审计 |
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

- 2026-07-31：可信 Verified Reinstall Provider 切片通过 `scripts/check.sh`，最终输出包含 `fake remote smoke passed` 和 `all checks passed`。覆盖严格 `hostlift.reinstall_recipes.v1`、`plan --reinstall-recipes` 真实 inventory/recipe CLI、manual action 精确绑定、source inventory hash artifact、HTTPS/size/SHA-256/目标平台/结构化 argv/managed path 合同、binary install 目标约束、secret 参数/artifact 根/跨 recipe 重叠拒绝、root/命令/distro/arch/容量/普通路径/悬空 symlink 全批次 preflight、`.curlrc` 禁用、`0700`/`0600` 下载、最终 artifact/path/stdout hash 复核，以及缺依赖/容量不足零 mutation、checksum mismatch/安装中途失败恢复证据 flush 和 approved rollback。scanner URL hint 仍不自动执行；任意 shell installer 的未声明副作用、官方发布签名、ABI/依赖和真实多发行版验证仍是边界。
- 2026-07-30：首个 PostgreSQL 有状态迁移 Provider 切片通过 `zig build test`、`zig build run -- help`、`scripts/smoke-fake-remote.sh` 和 `scripts/check.sh`，最终输出包含 `fake remote smoke passed` 与 `all checks passed`。覆盖双 opt-in、默认人工任务、固定五步 DAG、source inventory hash artifact 绑定、root/peer auth、PostgreSQL 10+ 同 major、源端零其它 client backend、fresh target、容量/路径冲突、`0600` dump/baseline、传输 SHA-256、database/role catalog verify、restore `ERROR:` allowlist、非空目标全批次 preflight 零 install/dump/transfer/artifact，以及 rollback baseline hash evidence 和 approved rollback `ManualRollbackRequired`。该切片不是热迁移，不支持跨 major、非 peer auth、非空目标、内容级一致性、自动数据库回滚或低停机 cutover。
- 2026-07-30：递归迁移动作内容级 Manifest Verify 切片通过 `scripts/check.sh`，输出包含 `fake remote smoke passed` 和 `all checks passed`；覆盖本地源和 `--source-host`、普通文件/目录/symlink target、远端 32 路径批量 stat/hash、路径哈希索引线性比较、source/target 截断失败关闭、special file 全批次 preflight 拒绝、默认 100000 条与显式 opt-out、匹配/mismatch，以及 mismatch 后 run-state 只有 failed、无 succeeded 且删除型 rollback baseline 已在 verify 前落盘。内容校验仍不证明 ACL、xattr、capability、hardlink、sparse、SELinux context 或热数据一致性。
- 2026-07-30：P0 Action 级迁移兼容性门禁切片通过 `scripts/check.sh`，输出包含 `fake remote smoke passed` 和 `all checks passed`；覆盖完整主机兼容纳入已知架构、unknown 失败关闭、plan v2 portable/same_arch/same_distro_version/same_package_manager/full_host 分类、跨版本包与 portable 项目/appdata 保留、跨发行版系统配置和跨架构 resources 改写 `compatibility_review`、workload 不再全局误阻断，以及手写不安全 v2 plan 在 audit/run-state/rollback/SSH 前零副作用拒绝。旧 plan v1 保持严格整机兼容；ELF/ABI/SONAME/目标依赖仍列为后续缺口。
- 2026-07-28：可信只读 Remote Manual Probe 切片通过 `scripts/check.sh`，输出包含 `fake remote smoke passed` 和 `all checks passed`；覆盖 probe override 深拷贝、systemd/container provider 映射、systemd/container/TCP/HTTP 固定只读 executor、非法/自由 probe 失败关闭、原始远程输出不落盘、report 独占输出、plan/action/provider/task/host/time 绑定、report 原始 SHA-256 联合 evidence 校验，以及错误 host/伪造 hash 拒绝。report 固定为 unsigned `hostlift_remote_read_only`，未写 apply run-state/workload，未解除 `manual_step`。
- 2026-07-28：Manual Evidence Hash-Chain Ledger 切片通过 `scripts/check.sh`，输出包含 `fake remote smoke passed` 和 `all checks passed`；覆盖原始 evidence bytes 严格重验/真实 SHA-256、无效 evidence 零文件写入、新建/续写、record exclusive lock、verify shared lock、全链重算、逐记录 flush、内容篡改、同 action 重复、跨 plan、provider/task mismatch 拒绝，以及 record/verify-ledger CLI。ledger 固定为 `hash_chain_only`，未接入 apply run-state/workload。
- 2026-07-28：Plan 级 Manual Evidence 完整度报告切片通过 `scripts/check.sh`，输出包含 `fake remote smoke passed` 和 `all checks passed`；覆盖零/单/多 evidence CLI、plan 全量 manual action 汇总、valid/missing/duplicate/invalid/unexpected 分类、逐文件 binding/contract/result 错误和 `trust_level=contract_only`。未写入 run-state/workload，也未改变 apply 对 `manual_step` 的拒绝。
- 2026-07-27：Manual Evidence 机器合同与只读验证切片通过 `scripts/check.sh`，输出包含 `fake remote smoke passed` 和 `all checks passed`；覆盖真实 plan/evidence JSON CLI、原始 plan SHA-256 与 action/task/provider 绑定、前置条件/输出/probe 精确覆盖、重复或额外项、失败状态、矛盾 hash、未来观察时间和非 manual action 拒绝。approved apply 仍原子拒绝 `manual_step`，未新增未知脚本或数据库命令执行路径。
- 2026-07-26：Provider 专属 Manual Task 输入合同切片通过 `scripts/check.sh`，输出包含 `fake remote smoke passed` 和 `all checks passed`；覆盖共享 inputs 深拷贝、value/secret_ref 二选一、重复 input/空 secret ref 拒绝、`script_reinstall` URL/version/checksum/config、`resource_reinstall` SHA256/ELF/owner/mode/mtime、`appdata_restore` engine/dump/restore/consistency 及 JSON 序列化。未新增未知下载脚本或数据库命令自动执行路径。
- 2026-07-26：工作负载聚合与完成度报告切片通过 `scripts/check.sh`，输出包含 `fake remote smoke passed` 和 `all checks passed`；单元测试覆盖五类 workload、complete/pending/blocked/unknown、跨发行版阻塞、同名项目/容器组件不等价、目标事实缺失和 partial/legacy scan 失败关闭。CLI 实测确认过滤扫描写入 `scan.full_scan=false`，`plan --workloads` 输出 `host_status=unknown`/`scan_incomplete`，并拒绝与 action/module filter 组合。
- 2026-07-26：Plan v2 DAG 与 AI 人工任务合同切片通过 `scripts/check.sh`，输出包含 `fake remote smoke passed` 和 `all checks passed`；覆盖 v1 读取兼容、v2 phase/depends_on、Compose/systemd/user/SysV/OpenRC 依赖生成、manual_task.v2 通用字段、validator 分类错误、缺失/前向/循环/阶段依赖拒绝、过滤闭包零远程调用和 resume 运行时依赖门禁。
- 2026-07-26：完整迁移执行闭环第一阶段通过 `scripts/check.sh`，输出包含 `fake remote smoke passed` 和 `all checks passed`；覆盖全批次 module preflight、后序缺依赖时前序零 mutation、hash-chain migration run、plan/host/filter/rollback 绑定、失败续跑、成功 action 跳过、首次 rollback 预备复用、manifest 不重复追加及状态链篡改拒绝。
- 2026-07-26：三个 P0 执行安全问题修复后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`；回归覆盖混合 `manual_step` 批次零远程调用、显式 rollback manifest 拒绝覆盖且零远程调用、随机默认路径、逐 entry flush、敏感 system env key/URL 脱敏及普通值误报边界。
- 2026-07-26：AI 驱动整机迁移完成度复审后，`scripts/check.sh` 通过，输出包含 `fake remote smoke passed` 和 `all checks passed`；本次新增场景矩阵、执行闭环风险、P0/P1/P2 待办及逐项验收标准，未把尚未实现的能力标记完成。
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
