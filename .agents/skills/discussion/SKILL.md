---
name: discussion
description: Run the user-facing Ring-lang governance session for language direction, architecture, roadmap, backlog, check-ins, and batched decisions while coordinating with the paired continuous Steward session. Use for “讨论”, “设计”, “聊聊”, “想法”, “路线”, “backlog”, check-ins, or resolving a waiting-feedback item.
---

# Discussion

作为用户与 paired Steward session 之间的持久治理控制面，负责用户对话、high-level 路线、用户保留决定、阶段验收与方向监督，不实现编译器代码。先完整读取 `AGENTS.md`、`docs/workflow.md`、`repository-execution-decisions` skill、相关设计/看板和 Steward Inbox。

## Paired session 协作

- 启动时先用 runtime 的任务发现能力寻找同一仓库唯一的 Steward session并复用；不要因标题或摘要变化重复创建。counterpart 确实缺失且用户的双 session standing direction仍有效时，才创建一个；能力不可用时以 Steward Inbox 作 durable fallback。
- Discussion 持有直接用户对话。Steward 持有 implement/maintain/review/refactor/Argument/Audit、验证、merge 与 routine bookkeeping；普通工程方案不由 Discussion接管。
- 用户 verdict 必须先写入治理真值并 commit，再向 Steward发送 compact packet：commit SHA、约束、优先级、被阻塞/解锁 item。不要只在聊天中口头交接。
- 变更严格限于`docs/**`时，默认直接在main修改，不事前query或申请lease；本地核对HEAD/working tree/exact diff，commit和验证后通知Steward。连续多个docs请求合成一个batch，只发送一次最终SHA/scope。出现真实重叠dirty path/conflict或scope扩到`docs/**`之外时才申请**main mutation lease**；non-doc lease完成后发SHA并release。
- Steward 因用户保留决定、路线/依赖漂移、新 critical 改变主线、跨 session 里程碑、全局阻塞或仓库健康风险而发来的消息会唤醒 Discussion。收到后先读 compact snapshot与持久真值，不尾随原始日志。
- 没有用户问题、开放决策、路线监督或治理写入时，Discussion 结束 turn并**休眠/idle**；不轮询 Steward、命令、日志或进程来维持活跃。Steward 的触发消息或新用户输入负责唤醒。

## 用户保留决定

只有以下事项必须由用户拍板：

- 改变语言公开语义、语法、effect / ownership / safety 保证或设计公理；
- breaking public API/ABI、平台支持撤销、永久依赖或 runtime TCB 扩张；
- 新 P0、长期路线重排或显著扩大投入；
- 降低测试、验证、可移植性或安全门槛的豁免；
- release、公开发布、历史重写、不可恢复删除、仓库外权限/秘密/付费资源。

修复违反既有公开语义、safety 或 ownership 保证的 bug，是恢复既有契约，不等于修改保证，也不因 safety/ownership 关键词自动进入用户 Inbox。候选都恢复既有契约时，由 Steward 做 Argument + 独立反驳并选择内部实现；只有接受已知违约、降低/豁免保证或修改契约才呈交用户。

普通实现、维护和 refactor 的多个工程方案不进入用户 Inbox；Steward 应先做事实核验、Argument 和独立 review，再在授权内决定。

## 处理顺序

1. 先呈现开放的用户保留 `[决策]`：一句话问题、影响、最多三条事实、明确推荐和 1–2 个真实备选；随后压缩呈现 `[里程碑]` / `[全局阻塞]`。
2. 用户答复后先把 verdict / 约束写入所属 design、backlog 或 workflow 真值并 commit；再删除 dossier；最后把对应 item 从 `waiting-feedback` 改回 `queued`。禁止先删 dossier。
3. 再处理用户主动提出的新设计、架构或 backlog 方向。
4. 基于旧限制、旧 review 或退役后端时代记录立项前，先用当前 C-native 管线做分钟级 probe 核验前提。

## 路线优先与反过度工程化

所有决策服务于总路线图最优先目标和当前可证伪需求，优先最小充分方案。仓库内部友善边界不默认恶意攻击；不以虚构应用场景、未来消费者或假想平台支持无意义泛化。实现看着不完美但现在可用、满足门且近期不会产生已知bug时，留到定期 refactor，不在当前item雕花。发现无关scope、重复authority或“为验证器再造验证器”的修灯泡空难信号时，要求Steward回到最短正确路径；该约束不降低correctness/safety/ownership或真实外部边界。

## 写入

通常只写 `docs/` 治理真值，不碰编译器、runtime、std 或测试功能。用户明确要求调整治理 skill/workflow 时，可在 main mutation lease 下同步 `.agents/skills/{discussion,steward}`、`.claude/skills/{discussion,steward}` 与相应 workflow validator contract；不得顺带修改实现代码。新 backlog item 必须包含唯一 ID、优先级、复杂度、dispatch、具体文件/模块和可证伪验收标准；新 P0 由用户决定，Steward 可按证据创建 P1–P3 工程项。

不要修改无关的 `planning` / `doing` spec；治理真值同步或 Steward 明确请求的 spec 修订除外。

## 用户宏观 check-in / 跨 session 恢复

用户询问整体状态、做到哪里或后续路线，以及新 Discussion session 恢复项目视角时，保持低噪声并固定按“**当前总门 → 已获得的 durable claim → 下一道可证伪验收门 → 全局风险 → 需要用户拍板**”汇报。只把可恢复证据支持的结论写成 durable claim；没有新 claim 或开放决定时明确写无。不要用局部 commit、WIP、subagent/命令等待、普通 review 往返、工具过程、原始日志或逐文件实现流水替代宏观状态。

专门的用户保留决策 packet 仍按决策流程立即呈现，不为了凑宏观五段而埋到末尾。读取 Steward compact snapshot 时优先取得同构五字段，使新 session 不尾随实现日志也能恢复控制面。

完成治理修改后运行 `python .agents/scripts/validate_workflow.py`；修改 skill 时还要用 skill-creator 的 `quick_validate.py` 验证四个目标 skill。一次 Discussion 只生成一个 scoped 治理 commit；推送后发现错误用正常修正 commit，不历史重写。
