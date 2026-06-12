// 打印 CLI 帮助文本。
pub fn print(writer: anytype) !void {
    try writer.writeAll(
        \\HostLift - Linux 主机迁移与同步规划工具
        \\
        \\用法:
        \\  hostlift scan [--summary] [--output <path>] [--force] [--include-module <list>] [--exclude-module <list>]
        \\  hostlift manifest --path <path> [--output <path>] [--force] [--max-entries <n>]
        \\  hostlift manifest --verify <manifest.json> --path <path> [--max-entries <n>]
        \\  hostlift plan --source <json> --target <json> [--summary] [--output <path>] [--force] [filters]
        \\  hostlift validate --plan <json> [--policy <json>] [--summary]
        \\  hostlift apply --plan <json> --dry-run [filters]
        \\  hostlift apply --plan <json> [--source-host <user@ip>] --host <user@ip> --approve [--operator <id>] [--approval-ticket <id>] [--approval-receipt <path>] [--approval-receipt-key-env <name>] [--audit-log <path>|--audit-sink <target>] [--audit-mirror-log <path>] [--policy <json>] [--host-authz <path>] [filters] [--identity-file <path>|--credential-provider <provider>] [--remote-timeout <seconds>] [--remote-retries <n>] [--operation-id <id>] [--cancel-file <path>] [--operation-state <path>] [--transfer-transport scp|rsync|chunk] [--transfer-partial] [--transfer-resume] [--transfer-bwlimit <kbps>]
        \\  hostlift audit verify --log <jsonl> [--summary]
        \\  hostlift audit replay --log <jsonl> --audit-sink <target> [--summary]
        \\  hostlift rollback --manifest <jsonl> --dry-run [--host <user@ip>]
        \\  hostlift rollback --manifest <jsonl> --host <user@ip> --approve [--operator <id>] [--approval-ticket <id>] [--approval-receipt <path>] [--approval-receipt-key-env <name>] [--audit-log <path>|--audit-sink <target>] [--audit-mirror-log <path>] [--policy <json>] [--host-authz <path>] [--identity-file <path>|--credential-provider <provider>] [--remote-timeout <seconds>] [--remote-retries <n>] [--operation-id <id>] [--cancel-file <path>] [--operation-state <path>]
        \\  hostlift remote exec --host <user@ip> [--approve] [--identity-file <path>|--credential-provider <provider>] [--timeout <seconds>] [--retries <n>] [--operation-id <id>] [--cancel-file <path>] [--operation-state <path>] -- <command> [args...]
        \\  hostlift transfer [--source-host <user@ip>] --host <user@ip> --source <path> --target <path> [--recursive] [--preserve] [--manifest-output <path>] [--verify-remote-manifest] [--approve] [--identity-file <path>|--credential-provider <provider>] [--timeout <seconds>] [--retries <n>] [--operation-id <id>] [--cancel-file <path>] [--operation-state <path>] [--transport scp|rsync|chunk] [--partial] [--resume] [--bwlimit <kbps>]
        \\  hostlift version
        \\  hostlift help
        \\
        \\命令:
        \\  scan      扫描本机清单事实
        \\  manifest  生成带校验和的本地路径逐文件清单
        \\  plan      比较源/目标清单并生成迁移计划
        \\  validate  在 apply 前校验迁移计划
        \\  apply     预览或执行已批准的迁移动作
        \\  audit     校验本地审计 JSONL hash chain
        \\  rollback  预览或按 rollback manifest 恢复备份
        \\  remote    生成或执行已批准的 SSH 远程命令计划
        \\  transfer  生成或执行已批准的文件传输计划
        \\  version   打印 HostLift 版本
        \\  help      显示帮助
        \\
        \\Scan 选项:
        \\  --summary        打印紧凑的人类可读摘要
        \\  --output <path>  写入文件
        \\  --force          覆盖已存在的输出文件
        \\  --include-module <list>  只扫描逗号分隔模块
        \\  --exclude-module <list>  跳过逗号分隔模块
        \\
        \\Manifest 选项:
        \\  --path <path>         要扫描的本地文件或目录
        \\  --output <path>       将 manifest JSON 写入文件
        \\  --verify <path>       用已有 manifest JSON 校验指定路径
        \\  --force               覆盖已存在的输出文件
        \\  --max-entries <n>     达到条目数后停止扫描，默认 100000
        \\
        \\Plan 选项:
        \\  --source <path>  源主机 inventory JSON
        \\  --target <path>  目标主机 inventory JSON
        \\  --summary        打印紧凑的人类可读摘要
        \\  --output <path>  写入文件
        \\  --force          覆盖已存在的输出文件
        \\  --include-module <list>  只保留逗号分隔模块中的动作
        \\  --exclude-module <list>  移除逗号分隔模块中的动作
        \\  --include-action <prefix>  只保留匹配 action id 前缀的动作
        \\  --exclude-action <prefix>  移除匹配 action id 前缀的动作
        \\
        \\Validate 选项:
        \\  --plan <path>  迁移计划 JSON
        \\  --policy <path>  action 策略 JSON；用于 allow/deny plan hash、模块、action 前缀、host/operator、审批票据/scope 和最大风险
        \\  --summary      打印紧凑的人类可读摘要
        \\
        \\Apply 选项:
        \\  --plan <path>  迁移计划 JSON
        \\  --dry-run      只预览动作，不修改目标主机
        \\  --source-host <user@ip>  copy_data_path 等动作使用的 SSH 源主机
        \\  --host <user@ip>  已批准 apply 使用的 SSH 目标主机
        \\  --approve      通过 SSH 执行已支持的动作
        \\  --operator <id>  写入审计日志的操作人标识；未提供时从 HOSTLIFT_OPERATOR、USER、LOGNAME 推断；policy 可限制
        \\  --approval-ticket <id>  写入审计日志的审批票据；策略可要求必须提供
        \\  --approval-receipt <path>  本地审批凭证 JSON；会绑定 ticket/operator/host/plan hash/purpose/过期时间
        \\  --approval-receipt-key-env <name>  可选 HMAC-SHA256 签名密钥环境变量名；receipt 有 signature 时必填
        \\  --audit-log <path>      写入指定审计 JSONL 文件；默认 /tmp/hostlift-audit-<created_at>.jsonl
        \\  --audit-sink <target>   审计 sink 目标；支持 file:<path>、syslog:<facility> 和 https://...；HTTPS 通过 curl POST JSON
        \\  --audit-mirror-log <path>  使用 syslog/HTTPS sink 时同步写入本地 JSONL 镜像，便于 audit verify/replay 补发；不能和 file sink 同用
        \\  --policy <path>  action 策略 JSON；策略不通过时拒绝 apply，可限制 plan hash/host/operator/ticket/scope
        \\  --host-authz <path>  本地主机授权 JSON；按 operator 限制可操作 host，不能替代真实身份认证/RBAC
        \\  --identity-file <path>      SSH 私钥路径；会传给 apply 内部 SSH/scp/rsync/校验/rollback 相关调用
        \\  --credential-provider <provider>  凭据来源；支持 ssh-agent 和 env:<name>，vault:<path> 失败关闭；不能和 --identity-file 同时使用
        \\  --firewall-reload  校验并 reload 已复制的防火墙配置
        \\  --ssh-port <port>  防火墙 reload 后必须继续允许的 SSH 端口
        \\  --firewall-recovery-window <seconds>  reload 前安排 systemd-run 延迟恢复窗口，范围 10-3600
        \\  --remote-timeout <seconds>  单次 SSH/scp 子进程总超时，默认 60
        \\  --remote-retries <n>        失败后重试次数，默认 0，最大 5
        \\  --operation-id <id>          操作标识，会透传给内部远程命令/传输计划
        \\  --cancel-file <path>         本地取消标记文件；内部远程命令/传输尝试前存在则停止
        \\  --operation-state <path>     本地 JSONL 状态文件；记录内部远程命令/传输的 started/succeeded/failed/cancelled
        \\  --transfer-transport <name> 文件传输后端：scp、rsync 或 chunk，默认 scp；chunk 当前按文件粒度增量上传到 staging 后用远端 rsync 合并
        \\  --transfer-partial          rsync 传输保留未完成文件，便于后续重试
        \\  --transfer-resume           rsync 传输使用 --append-verify 续传；会自动启用 --transfer-partial，不能和 scp 一起使用
        \\  --transfer-bwlimit <kbps>   内部 scp/rsync 传输限速，单位 Kbit/s；0 会被拒绝
        \\  --include-module <list>  只执行逗号分隔模块中的动作
        \\  --exclude-module <list>  跳过逗号分隔模块中的动作
        \\  --include-action <prefix>  只执行匹配 action id 前缀的动作
        \\  --exclude-action <prefix>  跳过匹配 action id 前缀的动作
        \\
        \\Audit 选项:
        \\  verify --log <path>  校验本地 JSONL 审计日志 hash chain
        \\  replay --log <path> --audit-sink <target>  校验通过后，把原始审计 JSONL 行重放到 file/syslog/HTTPS sink
        \\  --summary            打印紧凑的人类可读摘要
        \\
        \\Rollback 选项:
        \\  --manifest <path>  approved apply 生成的 rollback manifest JSONL
        \\  --dry-run          只预览恢复操作，不修改目标主机
        \\  --host <user@ip>   预期 SSH 目标主机；--approve 时必填
        \\  --approve          通过 SSH 恢复备份
        \\  --operator <id>    写入审计日志的操作人标识；未提供时从 HOSTLIFT_OPERATOR、USER、LOGNAME 推断；policy 可限制
        \\  --approval-ticket <id>  写入审计日志的审批票据
        \\  --approval-receipt <path>  本地审批凭证 JSON；rollback 会绑定 ticket/operator/host/purpose/过期时间
        \\  --approval-receipt-key-env <name>  可选 HMAC-SHA256 签名密钥环境变量名；receipt 有 signature 时必填
        \\  --audit-log <path>      写入指定审计 JSONL 文件；默认 /tmp/hostlift-audit-<timestamp>.jsonl
        \\  --audit-sink <target>   审计 sink 目标；支持 file:<path>、syslog:<facility> 和 https://...；HTTPS 通过 curl POST JSON
        \\  --audit-mirror-log <path>  使用 syslog/HTTPS sink 时同步写入本地 JSONL 镜像，便于 audit verify/replay 补发；不能和 file sink 同用
        \\  --policy <path>         action 策略 JSON；rollback 会强制其中的 host/operator allowlist 和审批票据/scope 要求
        \\  --host-authz <path>     本地主机授权 JSON；按 operator 限制可操作 host，不能替代真实身份认证/RBAC
        \\  --identity-file <path>      SSH 私钥路径；会传给 rollback 内部 SSH 调用
        \\  --credential-provider <provider>  凭据来源；支持 ssh-agent 和 env:<name>，vault:<path> 失败关闭；不能和 --identity-file 同时使用
        \\  --remote-timeout <seconds>  单次 SSH 子进程总超时，默认 60
        \\  --remote-retries <n>        失败后重试次数，默认 0，最大 5
        \\  --operation-id <id>          操作标识，会透传给内部远程命令计划
        \\  --cancel-file <path>         本地取消标记文件；内部远程命令尝试前存在则停止
        \\  --operation-state <path>     本地 JSONL 状态文件；记录内部远程命令的 started/succeeded/failed/cancelled
        \\
        \\Remote 选项:
        \\  --host <user@ip>      SSH 目标主机
        \\  --approve            执行命令，而不是只打印 JSON 计划
        \\  --allow-critical     允许已批准的 critical 风险命令
        \\  --identity-file <path>  SSH 私钥路径；会作为 ssh -i 参数使用
        \\  --credential-provider <provider>  凭据来源；支持 ssh-agent 和 env:<name>，vault:<path> 失败关闭；不能和 --identity-file 同时使用
        \\  --timeout <seconds>  单次 SSH 子进程总超时，默认 60
        \\  --retries <n>        失败后重试次数，默认 0，最大 5
        \\  --operation-id <id>   操作标识，会写入 remote command plan 方便外部系统关联
        \\  --cancel-file <path>  本地取消标记文件；approved 执行前和每次重试前存在则停止
        \\  --operation-state <path>  本地 JSONL 状态文件；记录远程命令 started/succeeded/failed/cancelled
        \\  --                  远程命令 argv 前的分隔符
        \\
        \\Transfer 选项:
        \\  --host <user@ip>   SSH 目标主机
        \\  --source-host <user@ip>  远程到远程传输使用的 SSH 源主机
        \\  --source <path>    源路径
        \\  --target <path>    远程目标路径
        \\  --recursive        使用 scp -r 复制目录
        \\  --preserve         使用 scp -p 保留文件元数据
        \\  --manifest-output <path>  传输前写入本地源路径 manifest
        \\  --manifest-max-entries <n>  限制传输源 manifest 条目数
        \\  --verify-remote-manifest  approved 递归传输后比较本地源和远程目标 manifest
        \\  --identity-file <path>  SSH 私钥路径；会传给 scp/rsync 和远程 manifest 校验
        \\  --credential-provider <provider>  凭据来源；支持 ssh-agent 和 env:<name>，vault:<path> 失败关闭；不能和 --identity-file 同时使用
        \\  --timeout <seconds>  单次 scp 子进程总超时，默认 60
        \\  --retries <n>        失败后重试次数，默认 0，最大 5
        \\  --operation-id <id>   操作标识，会写入 transfer plan 方便外部系统关联
        \\  --cancel-file <path>  本地取消标记文件；approved 传输前和每次重试前存在则停止
        \\  --operation-state <path>  本地 JSONL 状态文件；记录传输 started/succeeded/failed/cancelled
        \\  --transport <name>   传输后端：scp、rsync 或 chunk，默认 scp；chunk 当前按文件粒度增量上传到 staging 后用远端 rsync 合并
        \\  --partial            rsync 传输保留未完成文件，便于后续重试
        \\  --resume             rsync 传输使用 --append-verify 续传；会自动启用 --partial，不能和 scp 一起使用
        \\  --bwlimit <kbps>     传输限速，单位 Kbit/s；scp 使用 -l，rsync 转成 --bwlimit
        \\  --force            覆盖已存在的 --manifest-output
        \\  --approve          执行传输，而不是只打印 JSON 计划
        \\
    );
}
