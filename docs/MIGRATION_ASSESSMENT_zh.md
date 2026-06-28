# HostLift 迁移评估报告：NucBox-G3 -> 京东云

**评估日期**: 2026-06-13
**评估工具**: HostLift v0.1.0
**评估类型**: 仅评估，不执行迁移

---

## 1. 源机器概况 (NucBox-G3)

| 项目 | 详情 |
|------|------|
| 主机名 | NucBox-G3 |
| IP | 192.168.31.183 (局域网) |
| 操作系统 | Ubuntu 24.04.4 LTS |
| 内核 | 6.17.0-35-generic |
| 架构 | x86_64 |
| CPU | 4 核 |
| 内存 | 15GB (已用 6.2GB) |
| 磁盘 | 468GB NVMe (已用 88GB, 20%) |
| 包管理器 | apt |
| 显式安装包 | 154 个 |
| systemd 服务 | 328 个 (74 enabled, 78 running, 26 custom) |
| Docker 容器 | 30 个运行中 |
| Docker 镜像 | 35 个 |
| Docker 卷 | 44 个 |
| 用户 | 54 个 (1 个非系统用户: wong) |
| 防火墙 | UFW |
| 开发工具 | Python 3.12, Node 18, Git 2.43, Docker 29.4.3 |

### 1.1 运行中的核心服务

#### Docker 容器服务 (30个)

| 服务 | 镜像 | 端口映射 | 用途 |
|------|------|----------|------|
| **Dify 全栈** | | | |
| docker-web-1 | langgenius/dify-web:1.10.1 | 3000 | Dify Web 前端 |
| docker-api-1 | langgenius/dify-api:1.10.1 | 5001 | Dify API |
| docker-worker-1 | langgenius/dify-api:1.10.1 | - | Dify Worker |
| docker-worker_beat-1 | langgenius/dify-api:1.10.1 | - | Dify 定时任务 |
| docker-plugin_daemon-1 | dify-plugin-daemon:0.4.1-local | 5003 | Dify 插件守护 |
| docker-ssrf_proxy-1 | ubuntu/squid:latest | 3128 | SSRF 代理 |
| docker-weaviate-1 | semitechnologies/weaviate:1.27.0 | - | 向量数据库 |
| docker-sandbox-1 | langgenius/dify-sandbox:0.2.12 | - | 沙箱 |
| docker-redis-1 | redis:6-alpine | 6379 | 缓存 |
| docker-db_postgres-1 | postgres:15-alpine | 5432 | 主数据库 |
| docker-nginx-1 | nginx:latest | 8070, 8443 | 反向代理 |
| **1Panel 应用** | | | |
| 1panel-mysql | mysql:8.4.4 | 3306 | MySQL 数据库 |
| 1panel-postgresql | postgres:17.4-alpine | 5432 | PostgreSQL 数据库 |
| 1panel-redis | redis:7.4.2 | 6379 | Redis 缓存 |
| 1panel-gitea | commitgo/gitea-ee:24.7.0 | 222, 3222 | Git 服务 |
| 1panel-n8n | n8nio/n8n:2.0.2 | 5678 | 工作流自动化 |
| 1panel-openclaw | 1panel/openclaw:2026.3.8 | 28789, 28790 | AI 客户端 |
| 1panel-CoPaw | agentscope/copaw:v0.0.5 | 18788 | AI 协作 |
| 1panel-new-api | calciumion/new-api:v0.11.2 | 30000 | API 网关 |
| 1panel-jupyter | jupyter/scipy-notebook:latest | 8888 | Jupyter Notebook |
| 1panel-alist | xhofe/alist:v3.45.0 | 5244, 5426 | 文件列表 |
| 1panel-file | filebrowser/filebrowser:v2.32.0 | 40071 | 文件管理 |
| 1panel-homepage | ghcr.io/gethomepage/homepage:v1.7.0 | 8083 | 仪表盘 |
| 1panel-gotify | gotify/server:2.7.3 | 40266 | 消息推送 |
| 1panel-itools | corentinth/it-tools:2024.10.22 | 40116 | IT 工具集 |
| 1panel-frps | snowdreamtech/frps:0.65.0 | - | 内网穿透服务端 |
| 1panel-qbittorrent | linuxserver/qbittorrent:5.1.4 | 8181, 48181 | BT 下载 |
| 1panel-openvpn | openvpn/openvpn-as:latest | 443, 943, 1194 | VPN |
| **独立容器** | | | |
| openclaw | openclaw-docker-openclaw | 18789 | AI 客户端 |
| mihomo-docker | metacubex/mihomo:latest | 17890, 19090 | 代理/翻墙 |

#### 系统服务 (关键)

| 服务 | 用途 |
|------|------|
| 1panel-agent/core | 1Panel 面板 |
| nginx | Web 服务器/反向代理 |
| docker/containerd | 容器运行时 |
| fail2ban | 入侵防护 |
| NFS (nfs-kernel-server, mountd, etc) | 网络文件共享 |
| Samba (smbd, nmbd) | Windows 文件共享 |
| OpenVPN | VPN 服务 |
| Clash Verge | 代理客户端 |
| NPC (npc.service, npc-jingdong.service) | 内网穿透客户端 |
| SSH | 远程访问 |

### 1.2 数据量

| 路径 | 大小 | 说明 |
|------|------|------|
| /home/wong/Desktop/Code/ | ~27GB | 代码和项目目录 |
| /opt/1panel/apps/ | ~1.2GB | 1Panel 应用配置 |
| /var/lib/docker/volumes/ | 较大 (权限受限) | Docker 数据卷 |
| Docker 容器数据 | 包含数据库数据 | MySQL, PostgreSQL, Redis 等 |

---

## 2. 目标机器概况 (京东云)

| 项目 | 详情 |
|------|------|
| 主机名 | lavm-ovgv2xa7gp |
| IP | 117.72.147.216 (公网) |
| 操作系统 | Ubuntu 24.04.2 LTS |
| 内核 | 6.8.0-53-generic |
| 架构 | x86_64 |
| CPU | 2 核 |
| 内存 | 1.9GB (已用 782MB) |
| 磁盘 | 39GB (已用 27GB, 73%) |
| 包管理器 | apt |
| 显式安装包 | 76 个 |
| systemd 服务 | 254 个 (48 enabled, 56 running, 12 custom) |
| Docker 容器 | 2 个运行中 |
| Docker 镜像 | 3 个 |
| 用户 | 36 个 (2 个非系统用户: ubuntu, wong) |
| 防火墙 | UFW |

### 2.1 运行中的服务

| 服务 | 镜像 | 端口映射 | 用途 |
|------|------|----------|------|
| aiclient2api | aiclient2api-aiclient2api | 8085-8086, 19876-19880, 10087 | AI 客户端 API |
| kiro-rs | ghcr.io/hank9999/kiro-rs:latest | 10090 | Kiro RS 服务 |

### 2.2 已安装的关键软件

- 1Panel 面板 (1panel.service)
- Nginx
- Docker / containerd
- NTP (chrony)
- AppArmor

---

## 3. 迁移可行性分析

### 3.1 可迁移项目 (HostLift 支持)

| 模块 | 迁移方式 | 风险等级 | 说明 |
|------|----------|----------|------|
| **系统包** | apt install | 低 | 可自动迁移，但需注意发行版差异 |
| **SSH 配置** | 文件复制 | 低 | sshd_config、authorized_keys |
| **Cron 定时任务** | 文件复制 | 低 | /etc/crontab, /etc/cron.d/* |
| **系统配置** | 文件复制 | 低 | /etc/hosts, /etc/fstab, /etc/nsswitch.conf 等 |
| **Nginx 配置** | 文件复制 | 低 | /etc/nginx/nginx.conf 及 sites |
| **Docker 配置** | 文件复制 | 中 | /etc/docker/daemon.json |
| **用户/组** | useradd/groupadd | 中 | 需注意 UID/GID 冲突 |
| **Home 目录配置** | 文件复制 | 低 | .bashrc, .profile, .config/* |
| **systemd 服务** | 文件复制 + enable | 中 | 自定义 unit 文件 |
| **防火墙规则** | ufw 导入 | 高 | 需保留 SSH 通道 |

### 3.2 需手动处理的项目

| 项目 | 原因 | 建议 |
|------|------|------|
| **Docker 容器和数据** | HostLift 只扫描事实，不自动迁移容器状态 | 使用 docker export/import 或 docker-compose 重建 |
| **数据库数据** | 需要一致性备份恢复 | 使用 mysqldump / pg_dump 导出，在目标机导入 |
| **NFS/Samba 共享** | 局域网特有配置 | 公网服务器不需要，或重新配置 |
| **Clash Verge/代理** | 局域网代理工具 | 公网环境可能不需要，或重新配置 |
| **内网穿透 (frps/npc)** | 局域网特有 | 公网服务器不需要内网穿透 |
| **OpenVPN** | 需要重新生成证书 | 需要重新配置或迁移证书 |
| **代码项目目录** | 27GB 数据量大 | 建议用 rsync 分批传输 |
| **密码 hash** | HostLift 不支持 | 需要手动重新设置密码 |
| **sudoers** | HostLift 只扫描不 apply | 需要手动复制 |
| **SELinux/AppArmor** | 只扫描不 apply | 需要手动迁移 profile |

### 3.3 不可迁移/不建议迁移的项目

| 项目 | 原因 |
|------|------|
| **XDG autostart** | 桌面环境特有，云服务器不需要 |
| **snap 包** | NucBox-G3 有 snap，京东云可能没有 snap |
| **内核模块** | 硬件不同，内核模块不通用 |
| **GPU 驱动** | 云服务器无 GPU |
| **桌面环境组件** | GNOME 相关服务不需要 |

---

## 4. 关键差距分析

### 4.1 硬件差距

| 资源 | NucBox-G3 | 京东云 | 差距 | 影响 |
|------|-----------|--------|------|------|
| CPU | 4 核 | 2 核 | -50% | 并发能力下降 |
| 内存 | 15GB | 1.9GB | -87% | **严重不足** |
| 磁盘 | 468GB | 39GB | -92% | **严重不足** |
| 磁盘使用率 | 20% | 73% | - | 目标机空间紧张 |

### 4.2 内存风险

NucBox-G3 当前使用 6.2GB 内存，运行 30 个 Docker 容器。
京东云只有 1.9GB 内存，即使只运行核心服务也会非常紧张。

**建议**: 京东云需要升级到至少 8GB 内存才能运行主要服务。

### 4.3 磁盘风险

NucBox-G3 数据量约 27GB (代码) + Docker 数据卷。
京东云只剩 11GB 可用空间。

**建议**: 京东云需要扩容磁盘到至少 100GB。

---

## 5. 迁移方案设计

### 5.1 方案一：最小化迁移 (推荐)

**目标**: 只迁移核心服务，不迁移所有内容。

**迁移内容**:
1. 系统包和配置
2. SSH 配置
3. Nginx 配置
4. Docker 配置
5. 用户和组
6. Home 目录配置
7. Cron 定时任务
8. 部分 Docker 容器 (选择性)

**不迁移**:
- NFS/Samba
- Clash/代理
- 内网穿透
- 桌面环境组件
- 大型代码目录

**执行步骤**:

```bash
# 1. 在 NucBox-G3 扫描
hostlift scan --output source-inventory.json --summary --force

# 2. 在京东云扫描
hostlift scan --output target-inventory.json --summary --force

# 3. 生成迁移计划
hostlift plan --source source-inventory.json --target target-inventory.json --output plan.json --summary --force

# 4. 验证计划
hostlift validate --plan plan.json --summary

# 5. 预览执行
hostlift apply --plan plan.json --dry-run

# 6. 分批执行
# 批次1: 基础环境
hostlift apply --plan plan.json --source-host wong@192.168.31.183 --host root@117.72.147.216 --include-module packages,configs,ssh,cron --approve

# 批次2: 用户和服务
hostlift apply --plan plan.json --source-host wong@192.168.31.183 --host root@117.72.147.216 --include-module users,services,home_configs --approve

# 批次3: 选择性 Docker 容器
# 使用 docker export/import 手动迁移
```

### 5.2 方案二：完整迁移

**目标**: 迁移所有服务到京东云。

**前提条件**:
- 京东云升级到 8GB+ 内存
- 京东云扩容到 100GB+ 磁盘

**迁移内容**: 所有模块

**风险**: 高，需要仔细规划和测试。

### 5.3 方案三：混合迁移

**目标**: 核心服务迁移到京东云，部分服务保留在 NucBox-G3。

**架构**:
- 京东云: 公网服务 (Nginx, API, Web)
- NucBox-G3: 内网服务 (数据库, 开发工具, 大文件存储)

**优点**: 利用两台机器的优势，降低单点风险。

---

## 6. 迁移批次建议

### 批次 1: 基础环境 (低风险)

```bash
hostlift apply --plan plan.json \
  --source-host wong@192.168.31.183 \
  --host root@117.72.147.216 \
  --include-module packages,configs,ssh,cron \
  --operator "ops/wong" \
  --approval-ticket "MIGRATION-001" \
  --audit-log ./hostlift-audit.jsonl \
  --approve
```

**内容**:
- 系统包 (apt)
- /etc 配置文件
- SSH 配置
- Cron 定时任务

### 批次 2: 用户和服务 (中风险)

```bash
hostlift apply --plan plan.json \
  --source-host wong@192.168.31.183 \
  --host root@117.72.147.216 \
  --include-module users,services,home_configs \
  --operator "ops/wong" \
  --approval-ticket "MIGRATION-002" \
  --audit-log ./hostlift-audit.jsonl \
  --approve
```

**内容**:
- 用户和组
- systemd 服务配置
- Home 目录配置

### 批次 3: 应用数据 (高风险)

```bash
# 使用 rsync 传输代码目录
rsync -avz --progress wong@192.168.31.183:/home/wong/Desktop/Code/ /home/wong/Desktop/Code/

# 使用 docker export/import 迁移容器
docker export <container> | docker import - <image_name>
```

### 批次 4: 防火墙 (最后执行)

```bash
hostlift apply --plan plan.json \
  --host root@117.72.147.216 \
  --include-module firewall \
  --firewall-reload \
  --ssh-port 22 \
  --firewall-recovery-window 120 \
  --operator "ops/wong" \
  --approval-ticket "MIGRATION-004" \
  --audit-log ./hostlift-audit.jsonl \
  --approve
```

---

## 7. 数据库迁移专项

### 7.1 MySQL

```bash
# 在 NucBox-G3 导出
docker exec 1panel-mysql mysqldump -u root -p --all-databases > mysql-backup.sql

# 在京东云导入
docker exec -i 1panel-mysql mysql -u root -p < mysql-backup.sql
```

### 7.2 PostgreSQL

```bash
# 在 NucBox-G3 导出
docker exec 1panel-postgresql pg_dumpall -U postgres > postgres-backup.sql

# 在京东云导入
docker exec -i 1panel-postgresql psql -U postgres < postgres-backup.sql
```

### 7.3 Redis

```bash
# 在 NucBox-G3 导出
docker exec 1panel-redis redis-cli BGSAVE
docker cp 1panel-redis:/data/dump.rdb ./redis-dump.rdb

# 在京东云导入
docker cp redis-dump.rdb 1panel-redis:/data/dump.rdb
docker restart 1panel-redis
```

---

## 8. Docker 容器迁移

### 8.1 使用 docker-compose 重建 (推荐)

对于 1Panel 管理的容器，可以：

1. 在 NucBox-G3 导出 docker-compose.yml 和环境变量
2. 在京东云重新 `docker-compose up -d`

### 8.2 使用 docker export/import

```bash
# 导出容器
docker export <container_name> > container_backup.tar

# 在目标机导入
docker import container_backup.tar new_image_name:tag
```

**注意**: 这种方式会丢失 volume 数据和网络配置。

### 8.3 建议迁移的容器

| 容器 | 优先级 | 原因 |
|------|--------|------|
| 1panel-new-api | 高 | API 网关 |
| 1panel-gitea | 高 | 代码仓库 |
| 1panel-n8n | 中 | 工作流 |
| 1panel-jupyter | 中 | 开发环境 |
| 1panel-alist | 中 | 文件管理 |
| Dify 全栈 | 低 | 资源需求大 |

---

## 9. 风险和注意事项

### 9.1 高风险项

1. **内存不足**: 京东云 1.9GB 内存无法运行所有服务
2. **磁盘不足**: 京东云只剩 11GB 空间
3. **端口冲突**: 两台机器可能有相同端口的服务
4. **数据库一致性**: 迁移过程中数据库可能有写入

### 9.2 缓解措施

1. **升级京东云配置**: 至少 8GB 内存 + 100GB 磁盘
2. **分批迁移**: 不要一次迁移所有服务
3. **停服迁移**: 数据库迁移前停止写入
4. **备份**: 迁移前在两台机器都做备份
5. **测试**: 先在测试环境验证

### 9.3 回滚方案

```bash
# 预览回滚
hostlift rollback --manifest hostlift-rollback.jsonl --dry-run --host root@117.72.147.216

# 执行回滚
hostlift rollback --manifest hostlift-rollback.jsonl --host root@117.72.147.216 --operator "ops/wong" --approval-ticket "ROLLBACK-001" --audit-log ./hostlift-audit.jsonl --approve
```

---

## 10. 总结

### 10.1 迁移建议

| 项目 | 建议 |
|------|------|
| **是否迁移** | 可以迁移，但需要先升级京东云配置 |
| **推荐方案** | 方案一 (最小化迁移) 或 方案三 (混合迁移) |
| **京东云升级** | 内存 8GB+，磁盘 100GB+ |
| **迁移时间** | 预计 2-4 小时 (不含数据传输) |
| **停机时间** | 数据库迁移需要停服 10-30 分钟 |

### 10.2 HostLift 评估

HostLift 可以处理：
- 系统包和配置迁移
- SSH 配置迁移
- Cron 定时任务迁移
- 用户和组迁移
- systemd 服务配置迁移
- Home 目录配置迁移
- 防火墙规则迁移

HostLift 需要手动处理：
- Docker 容器和数据
- 数据库数据
- 大型代码目录
- 密码 hash
- sudoers 规则

### 10.3 下一步

1. 升级京东云配置 (内存 8GB+, 磁盘 100GB+)
2. 决定迁移方案 (最小化/完整/混合)
3. 准备备份
4. 执行迁移评估 (dry-run)
5. 分批执行迁移
6. 验证迁移结果

---

**文档版本**: v1.0
**生成工具**: HostLift v0.1.0
**评估人**: MiMo Code Agent
