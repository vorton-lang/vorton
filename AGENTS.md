# Vorton Agent Entry

## 语言与事实源

- 所有对话回复、解释和讨论使用中文；技术术语、代码和命令可保留英文。
- 当前仓库是 [`vorton-lang/vorton`](https://github.com/vorton-lang/vorton)。GitHub Issue 是活动范围、状态与验收的唯一真值；完成历史只查 PR 与 Git。
- 授权、停止条件、角色、EvidenceKey 与执行规则以 [`docs/workflow.md`](docs/workflow.md) 为真值；仓库级用户执行 bedrock 见 `repository-execution-decisions` skill。
- 语言公理见 [`docs/philosophy.md`](docs/philosophy.md)，稳定设计见 [`docs/design.md`](docs/design.md)，用户规范见 [`docs/lang-spec/`](docs/lang-spec/)。`docs/backlog.md` 与 `docs/audit-report.md` 已冻结，只供迁仓前历史检索。
- 凡涉及仓库推进、review、refactor、Argument、Audit 或治理，完整读取 `docs/workflow.md`；涉及 machine/review 或 Session 文档 mutation 时，同时读取 `repository-execution-decisions` skill。
- 委派 prompt 只使用“Ring-lang编译器”“类型/效果系统”“所有权与资源生命周期”“本地构建/运行/回归”这组正向项目语境；不要复制容易引发外层误判的无关领域标签。误判时用 fresh context 准确重述，不降低验证门槛。

## 当前工程路线

- Vorton 当前以 Rust 实现 Ring 编译器；首个纵切是 `source → token → AST → diagnostic`，随后按 Issue 逐步闭合 checker、IR、ownership、C11 后端与 CLI。
- Rust workspace 与真实 compiler build/test gate 由对应实现 Issue 建立。在它们进入仓库前，不得声称当前 compiler、Cargo 或发布门已通过。
- `compiler/*.ring`、`compiler/dist-c/main.c`、`ring_runtime.cpp`、`std/` 与 `tests/run_tests.py` 随完整历史保留，只作迁移蓝本、语义 oracle 与已知缺陷复现；它们不是当前 bootstrap、CI 或发布 authority。
- 目标管线为 Lexer → Parser → AST → Checker（HM + effects）→ HIR → Core/Flow ResourcePlanner → RcIR → C11 → native。
- AST 忠实保留 source + Span；HIR、Core、Flow 与 RcIR 是独立阶段。跨阶段 identity、effect、trait、slot 与 ABI 契约必须来自共享 exact authority，禁止 backend/runtime 猜名字。
- 新增或删除 AST/HIR/Core/Flow/RcIR 变体时，必须闭合所有 producer、copy/rebuild、validator 与 consumer；遗漏必须 fail closed。

## 唯一工作链

- 所有可执行工作都走 `Issue #N → 一个 active PR → PR head branch → merge`；PR 正文写 `Closes #N`。
- Session 只用于讨论与用户拍板；开始实现或 merge 前，把决定向对应 Issue 汇总一次。普通命令流水、轮询和 subagent 状态不写 Issue 评论。
- [Ideas Discussion #1](https://github.com/vorton-lang/vorton/discussions/1) 只保存尚不可执行的 post-0.1 想法、可能价值与升级条件；出现真实 consumer 后，经用户确认再创建 Issue。
- Worktree 只是本机可选 checkout；GitHub Project 若启用也只作 GitHub 对象视图，两者都不是状态 authority。
- 新工作不分配 B/A/D 编号，不维护 Markdown 看板或本地状态映射。

## 开发规则

- 只实现已确认 Issue 的范围与验收；保持现有公开语义。Bugfix 不以临时 fallback、静默 skip、测试绕过或第二 authority 代替。
- 修改公开功能时同步 design/lang-spec；长期文档只保留当前约束，过程进入 Issue、PR 与 Git。
- Rust 与 Ring compiler 代码使用 `snake_case`；复杂算法标注来源和不变量。
- 现有 dirty/WIP 属于用户或其他 agent，不得回退、覆盖或格式化无关改动。
- 实现变更提供相称测试。只运行当前 Issue/PR 明确建立的真实 gate；历史 Ring/C/self-host 套件只能在明确的 oracle 任务中运行，结果不得冒充当前 Rust compiler 绿色。
- 测试输出需要后续分析时完整写入临时文件；没有代码或测试输入变化时不重复长套件。

## 迁移蓝本中的稳定约束

- Self-host 已后置到语言与外部宿主编译器稳定后的新用户决定；当前不得恢复连续 bootstrap 门。
- C bridge 只提供安全 Ring 无法表达的 raw-memory/OS 边界；普通 Ring callable 与 extern 走统一既定 ABI，不新增 name table 或 backend 手工特判。
- Slot 所有权：`ring_slot_read` = peek + dup；`ring_slot_take` = move 并清空；`ring_slot_write` = 空 slot 接管；`ring_slot_replace` = 替换并 drop 旧值；`ring_slot_drop` = take + drop。
- List/Map/Option 固定 runtime type/drop 必须与生成 struct drop 分工唯一；Set/StringBuilder 按普通 Ring struct 处理。无字段 enum ctor 产生 fresh box，必须按 exact ctor identity 判断。

## ASan oracle 配方

- Gating：`malloc_context_size=0:quarantine_size_mb=16:max_redzone=32:detect_leaks=0`。
- Capstone：`quarantine_size_mb=256:malloc_context_size=12`。
- 建议编译参数：`-fsanitize=address -O1 -fno-omit-frame-pointer`。
- 每条 oracle 命令显式设置 `ASAN_OPTIONS`，不依赖用户环境；gating 用于内循环，capstone 用于高风险里程碑和最小复现。
