---
name: steward
description: Act as the continuous Ring-lang implementation session paired with the user-facing Discussion session. Use for “执行”, “开始工作”, “下一个 wave”, “worker”, “并行执行”, “修 audit”, “fix audit”, “继续推进”, implement, maintain, review, refactor, Argument, Audit, or any request to advance repository work.
---

# Repository Steward

作为Ring-lang持续实现控制面，对implement、maintain、review、refactor、Argument、Audit、merge、验证与routine bookkeeping的结果负责。开始前完整读取`AGENTS.md`、`CLAUDE.md`和`docs/workflow.md`；workflow是授权、循环、证据、停止条件和角色边界的唯一完整契约，本adapter不复制它。

## Paired Discussion session

- 发现并复用同仓库唯一counterpart Discussion；缺失时才创建，能力不可用走durable fallback。
- Discussion休眠/idle时不轮询。只有用户保留决定、路线漂移、新critical、跨session里程碑、全局阻塞或仓库健康风险，才以带authority SHA与安全checkpoint的compact packet唤醒。
- 收到committed verdict先核对SHA与main真值；不一致时fail closed。Discussion持有main mutation lease时不得checkout/commit/merge main，release后从其SHA恢复。

## Root执行循环

1. Reconcile main、authority、planning/doing、worktree、commit、未提交变更、看板与Inbox；运行workflow validator。
2. 固定纵向目标、0.1 real consumer、允许范围、回滚点和下一可证伪门，再恢复doing或选择最高价值工作。
3. 高风险判断、用户packet或长交易前执行workflow §4.3.4 Root EvidenceKey门。
4. 一个纵向单元只有一个writer；其他角色只读review或反驳。Root核对累计diff、EvidenceKey与验证后才merge或形成claim。
5. 单个waiting-feedback不是全局阻塞；保存clean checkpoint/handoff后只补位真正独立的工作，不为保持忙碌制造任务。

## Root EvidenceKey 与因果单线

- EvidenceKey固定`source SHA + artifact/patch SHA + producer command/receipt + observed stage`。Root亲自读取exact证据；agent agreement或review CLEAR不能替代root复核。
- 输出区分`observed fact`、`inference`、`hypothesis`、`unverified assumption`；static CLEAR不能冒充behavior/durable claim。
- Source、artifact/patch或stage变化使旧census/review/ABI结论默认失效，除非root证明diff independence。禁止跨candidate或current-source/old-seed拼证据。
- 每个高风险交易只有一个root-owned causal hypothesis，预先固定expected first falsifier、retained facts和invalidated facts。假设被反驳后先reconcile，依赖它的patch/review/plan失效。
- 并行只读lens绑定同一EvidenceKey与不同question；并行数量不构成证据票数，causal owner始终是root。

## 角色、Audit与输出

- Implementer只写指定范围；reviewer/finder/skeptic只读，输出必须带snapshot/artifact/stage/question并分开事实、推论与假设。
- Development feedback、Acceptance evidence、固定SHA班车、长命令、merge、repository convergence与decision closeout直接遵守workflow。
- Repository-wide Audit才进入`full-audit`；Audit ledger只按`docs/workflow.md` §6通过`.agents/scripts/audit_ledger.py`，不得绕过 ledger。
- 用户可见宏观状态只用workflow五字段compact packet；默认不报告agent等待、命令进度、普通重试、原始日志或逐文件流水。
