# HostLift Agent 协作规则

本文件是 HostLift 项目的项目级 agent 规则。它适合放在仓库里长期生效；不要把这些规则做成跨项目 Skill，除非将来要抽象成通用工程方法论。

## 适用场景

当 agent 在本项目中执行开发、重构、评估、文档、测试或质量修正任务时，必须遵守本文件。尤其适用于下面这些任务：

- 长时间 goal 或多轮续跑。
- 代码质量、架构拆分、企业级差距评估。
- README、技术设计、架构文档、PRD、质量文档更新。
- 需要维护方法注释、测试门禁、模块边界和执行进度的工作。

## 执行模式

HostLift 的协作模式采用“目标 + 可见计划 + 持久清单 + 验证证据”。

执行顺序：

```text
理解目标
  -> 读取当前工作区和相关文档
  -> 更新短期执行计划
  -> 更新 TASK_PROGRESS_zh.md 持久清单
  -> 分批修改代码或文档
  -> 每完成一个可验证项就勾选清单
  -> 运行质量门禁
  -> 用证据判断是否可以关闭 goal
```

`Updated Plan` 只用于当前会话内的短期可视化，不是项目事实来源。跨轮、跨 agent、跨压缩上下文时，以 `TASK_PROGRESS_zh.md` 和当前工作区为准。

## 持久进度清单

多步骤任务必须维护 [TASK_PROGRESS_zh.md](TASK_PROGRESS_zh.md)。

规则：

- 新发现的功能缺口、架构问题、质量问题、文档缺口，必须写进清单。
- 完成一个可验证项后，立即把对应条目从 `[ ]` 改成 `[x]`。
- 不要把“计划要做”写成“已经完成”。
- 不要因为一次切片通过测试，就把完整企业级目标标记完成。
- 如果某项是长期产品能力，例如 RBAC、Vault、集中审计、字节块级 chunk、多发行版矩阵，应保留在“长期缺口”里，而不是混进本轮已完成。

推荐清单结构：

```markdown
## 当前执行切片

- [ ] 要做的具体事项
- [x] 已完成并有证据的事项

## 新发现问题

- [ ] 问题描述、影响、建议处理位置

## 长期能力缺口

- [ ] 企业级能力或产品级能力缺口

## 验证记录

- 日期、命令、结果
```

## 质量门禁

修改代码或项目规则后，默认运行：

```bash
scripts/check.sh
```

该脚本必须覆盖：

- `zig build test`
- `zig build run -- help`
- `scripts/smoke-fake-remote.sh`
- `git diff --check`
- public function 中文注释检查

如果只改文档，也至少运行：

```bash
git diff --check
```

但如果文档变更影响使用说明、命令示例或质量规则，仍应优先运行 `scripts/check.sh`。

## 注释要求

新增或修改 `pub fn` 时，函数前必须有简短中文注释。

注释要求：

- 说明这个函数做什么。
- 说明不明显的边界、失败关闭、外部副作用或安全约束。
- 不写空洞注释，例如“执行函数”“返回结果”。
- 不用注释替代清晰命名。

当前门禁由 `scripts/check.sh` 的 public function comment check 执行。新增公开函数后必须确保该检查通过。

## 架构边界

HostLift 的核心边界不能绕过：

- CLI 只负责参数解析、文件读写和输出。
- `inventory/*` 只采集事实，不产生迁移副作用。
- `plan/*` 只生成 action，不连接远程主机。
- `modules/*` 声明 scan/plan/apply/verify/rollback 能力。
- `apply/*` 只在显式 `--approve` 后编排执行。
- SSH 命令只能从 `remote/*` 出去。
- 文件传输只能从 `transport/*` 出去。
- host/path/argv/identity 校验只能走 `security/*`。
- 凭据来源只能走 `credentials/*`，不得把 secret 写入 inventory、plan、audit 或 rollback。
- 审计只能走 `audit/*`。
- rollback manifest 和恢复执行只能走 `rollback/*`。

新增能力时优先按下面顺序落地：

```text
schema
  -> scanner
  -> plan action
  -> validator
  -> registry
  -> handler
  -> remote/transport adapter
  -> verify
  -> rollback
  -> tests / smoke
```

高风险模块可以先做 `scan-only` 或 `manual_step`，不要为了看起来完整而直接自动 apply。

## 完成度判断

关闭 goal 前必须做完成度审计：

1. 列出用户显式要求。
2. 为每个要求找到当前工作区证据。
3. 检查文档、代码、测试、脚本和清单是否一致。
4. 运行对应质量门禁。
5. 把完成项和未完成项写入 `TASK_PROGRESS_zh.md`。

不能用下面理由关闭 goal：

- “已经做了一部分”。
- “测试绿了，但目标范围没有覆盖”。
- “长期企业级能力还没有做，但暂时不想继续”。
- “文档说未来会做”，但用户要求的是当前实现。

如果用户目标是“完成当前切片”，可以在切片证据完整时关闭。  
如果用户目标是“做成完整企业级平台”，则 RBAC、在线审批、Vault/短期凭据、可靠审计队列、深度 verify/rollback、字节块级 chunk、多发行版集成矩阵等缺口不能被忽略。

## 文档要求

项目文档默认使用中文。

关键文档职责：

- `README.md`：怎么安装、怎么使用、常用命令、当前能力边界。
- `TECH_DESIGN_zh.md`：技术实现、代码设计思路、架构分层、模块扩展方式。
- `ARCHITECTURE_zh.md`：源码目录、模块关系、工作流和设计决策。
- `CODE_QUALITY_zh.md`：代码质量、文件长度、企业级差距、重构建议。
- `PRD_zh.md`：产品需求、市场需求、版本路线。
- `TASK_PROGRESS_zh.md`：本项目持续进度、发现的问题、完成证据和长期缺口。

修改命令示例后，必须用 `zig build run -- help` 或相关源码核对参数名。

## 工作区纪律

- 不要回滚用户或其它 agent 的无关改动。
- 不要执行破坏性 git 命令。
- 大改动前先读相关文件和测试。
- 编辑文件使用补丁方式。
- 发现已有改动和当前任务冲突时，优先兼容；无法兼容再说明阻塞原因。

