# Changelog

本文件是版本变更索引。每个版本的完整变更记录在 [docs/changelog/](changelog/) 目录下。

## [0.1.0] - 2026-06-12

首个公开版本。Linux 主机迁移工具，支持 scan → plan → validate → apply → audit → rollback 全流程。

**扫描**：19 个模块，覆盖包、服务（systemd/OpenRC/SysV/XDG）、用户、SSH（含 sshd\_config 解析）、配置（29 路径）、cron、home 配置、项目、应用数据、Docker/Podman、防火墙、sudoers、ACL、SELinux/AppArmor、存储（含八进制转义）、网络、进程、开发环境、系统基线（locale/sysctl/limits/NTP/DNS/NSS/NFS/LVM/ZFS/Btrfs 实际值解析）。

**计划**：24 种动作类型，4 级风险，UID/GID 冲突检测，兼容性检查，按模块/action 过滤。

**执行**：5 大包管理器，systemd/OpenRC/SysV enable/disable，用户级 systemd，Docker Compose，文件备份 + 权限修复 + verify。

**传输**：scp/rsync/chunk 三种后端，rsync 断点续传，chunk 增量传输。

**远程执行**：SSH argv 数组，重试 + 超时 + 取消文件。

**策略**：7 维度评估，HMAC-SHA256 审批凭证，per-operator 主机授权。

**审计**：SHA-256 哈希链，file/syslog/HTTPS sink，镜像双写，replay。

**回滚**：11 个模块覆盖，含包卸载、用户/组删除、systemd disable、OpenRC/SysV runlevel 反向、Docker Compose down。

**防火墙**：4 种后端，SSH 端口防锁死，systemd-run 恢复窗口。

**安全**：输入白名单，凭据不入内存，vault fail-closed。

**构建**：Zig 0.16.0，零依赖，musl 静态链接，x86\_64 + aarch64，GitHub Actions CI + Release。

> 完整变更记录：[docs/changelog/v0.1.0.md](changelog/v0.1.0.md)
