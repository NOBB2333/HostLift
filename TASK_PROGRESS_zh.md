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
- [x] scan registry 不再用 `.security` 承载 dev env、不再用 `.kernel` 承载 processes；新增 `.dev_env` 和 `.processes`，旧名称保留为命令行兼容别名。
- [x] 进程扫描从 `ps ... comm` 改为 `ps ... args`，记录完整命令行摘要。
- [x] `readWholeFile` 默认读取上限从 1MB 提升到 8MB，并明确超限返回错误、不静默截断。
- [x] 抽出 Docker label 归一化 helper，去掉 `docker_containers.zig` 和 `docker_resources.zig` 重复实现。
- [x] 抽出 init 脚本忽略规则 helper，SysV/OpenRC 共用。
- [x] 扩展 configs 扫描候选路径，补 SSH、containerd/podman/containers、journald/logind、rsyslog、logrotate、cron.d、profile.d、limits、sysctl、DNS/NSS 等常见系统配置入口。
- [x] 抽出用户 home 扫描规则 helper，home 配置、用户级 systemd、XDG autostart、dev env 和 system baseline 共用。
- [x] Docker/Podman 容器资源扫描按 runtime provider 聚合，container/volume/network/image 记录带 runtime 字段，plan 层按运行时区分同名资源。

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
- [x] 新增 system baseline scan-only 模块：locale/timezone、NTP、sysctl、limits、PAM、SSSD/LDAP、NSS、DNS、logrotate、tmpfiles.d、内核模块加载配置。
- [x] storage/system baseline 扩展只读事实：LVM、ZFS、Btrfs、crypttab、NFS/autofs、exports；默认只生成人工审查项。
- [x] users plan 阶段增加 UID/GID/name 冲突解释，避免只在远程 useradd 失败后才发现。
- [ ] scan_runner 对用户/认证/存储等关键模块失败应升级成更强 warning 或 manual_step，避免空清单被误解为无需迁移。
- [ ] operation state JSONL 增加文件锁或单 writer 约束，避免多实例并发写损坏。
- [x] Docker 镜像列表和脚本安装应用做 scan-only/reinstall 建议，不默认复制缓存、二进制和隐含依赖。
- [x] Docker volume mountpoint 生成可选高风险数据复制 action，复用现有文件同步能力。
- [x] 修复 mountinfo 八进制转义解析，避免含空格挂载路径解析错误。
- [x] system_baseline 从路径存在性推进到关键配置值 scan-only 和 plan review。
- [x] `/etc/hosts` 差异生成可选文件型迁移动作。
- [x] sshd_config 关键认证/连通性指令进入 scan-only 审查。
- [x] appdata 接入文件型 rollback handler。
- [x] appdata 和 Docker volume rollback dispatcher 路由已补齐。
- [x] scan registry 的 dev_env/processes 命名已清理，保留 security/kernel 兼容别名。
- [x] 进程扫描记录完整命令行摘要。

## 长期能力缺口

这些不是当前切片已经完成的事项，不能因为一次文档或局部代码通过测试就标记完成。

- [ ] 真实用户身份认证和 RBAC。
- [ ] 在线审批校验、审批签名和可信审批 provider。
- [ ] Vault、短期 SSH 凭据、凭据租约和密钥轮换。
- [ ] 可靠审计队列、SIEM 级集中存储、外部签名和时间戳锚定。
- [ ] 字节块级 chunk 传输、强断点续传和目标多余文件安全清理。
- [ ] 更深的 action 级 verify 和完整非文件副作用 rollback。
- [ ] sudoers、ACL、SELinux/AppArmor、storage 的自动 apply/rollback。
- [ ] Docker/Podman network、运行中容器状态的自动迁移和恢复。
- [x] Podman image/volume/network/container scan-only provider 已接入；自动 apply/verify/rollback 仍未接入。
- [ ] 扫描器测试覆盖补齐，尤其 cron、configs、home_configs、appdata、projects、firewall、processes 和 dev_env 系列。
- [ ] systemd/SysV/OpenRC 的受控 start/stop/restart 语义和更多发行版 fixture。
- [ ] 多发行版容器或虚拟机集成测试矩阵。
- [ ] Web/TUI/API 控制面和任务队列。
- [ ] P2P/agent/远程源 rsync provider，减少 `scp -3` 控制机中转瓶颈。
- [ ] curl 脚本安装应用 provider：识别安装痕迹、版本、来源 URL、校验和和 reinstall 步骤，默认只生成人工审查项。

## 验证记录

- 2026-06-12：`scripts/check.sh` 通过，输出包含 `all checks passed`。
- 2026-06-12：`./scripts/build-linux.sh` 通过，输出包含 `dist/x86_64-linux-musl/bin/hostlift` 和 `dist/aarch64-linux-musl/bin/hostlift` 构建成功。
- 2026-06-12：Linux 换机遗漏评估和 Maven/Cargo/Gradle/Go 配置扫描补充后，`scripts/check.sh` 与 `./scripts/build-linux.sh` 均通过。
- 2026-06-12：Linux 系统基线 scan-only、Docker 镜像扫描和 UID/GID 冲突检测补充后，`scripts/check.sh` 与 `./scripts/build-linux.sh` 均通过。
- 2026-06-12：Docker volume mountpoint 可选复制动作和 mountinfo 八进制转义修复后，`scripts/check.sh` 与 `./scripts/build-linux.sh` 均通过。
- 2026-06-12：system_baseline 关键配置值解析、sshd_config 审查、`/etc/hosts` 可选迁移动作、appdata rollback 和用户扫描失败显式化后，`scripts/check.sh` 与 `./scripts/build-linux.sh` 均通过。
- 2026-06-12：rollback dispatcher 路由、scan registry 命名、process args、readWholeFile 上限、公共 helper、Podman scan-only provider 和测试临时文件隔离修复后，`scripts/check.sh` 与 `./scripts/build-linux.sh` 均通过。
