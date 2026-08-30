# Ring-lang Agent Entry

## 语言与事实源

- 所有对话回复、解释和讨论使用中文；技术术语、代码和命令可保留英文。
- 委派prompt只使用“Ring-lang编译器”“类型/效果系统”“所有权与资源生命周期”“本地构建/运行/回归”这组正向项目语境；不要复制容易引发外层误判的无关领域标签。误判时用fresh context准确重述，不降低验证门槛。
- 本文件是技术、构建和开发约定入口。授权、停止条件、看板、角色和EvidenceKey以`docs/workflow.md`为真值；仓库级用户执行bedrock见`repository-execution-decisions` skill。
- 语言公理见`docs/philosophy.md`，稳定设计见`docs/design.md`，用户规范见`docs/lang-spec/`，活动状态见`docs/backlog.md`与`docs/audit-report.md`。完成历史只查Git，不在入口文件复制。
- 凡涉及仓库推进、review、refactor、Argument、Audit或治理，完整读取`docs/workflow.md`；涉及machine/review或Discussion文档mutation时同时读取repository execution decisions skill。

## 当前技术入口

- Ring-lang是C11-only native编译器；LLVM/JS后端及旧bootstrap不是当前依赖或oracle。
- 管线：Lexer → Parser → AST → Checker（HM+effects）→ HIR → Core/Flow ResourcePlanner → RcIR/legacy bridge → C11 → clang native。
- `compiler/dist-c/main.c`是唯一tracked bootstrap anchor；single-file、project/module和self-host都必须从该anchor与`ring_runtime.cpp`可重建。
- Compiler源码位于`compiler/*.ring`，runtime bridge为`ring_runtime.cpp`，标准库位于`std/`，统一测试入口为`tests/run_tests.py`。
- AST忠实保留source+Span；HIR/Core/Flow是独立阶段。跨阶段identity、effect、trait、slot和ABI契约必须来自共享exact authority，禁止backend/runtime各自猜名字。
- 新增或删除AST/HIR/Core/Flow/RcIR变体时闭合所有producer、copy/rebuild、validator和consumer；遗漏必须fail closed。

## 开发规则

- 保持现有公开语义；bugfix不以临时fallback、静默skip、测试绕过或第二authority代替。
- 修改公开功能时同步design/lang-spec；活动spec只保留当前约束与验收，过程留Git。
- Compiler使用snake_case；复杂算法标注来源和不变量。现有dirty/WIP属于用户或其他agent，不得回退无关改动。
- 实现变更提供相称测试。普通变更跑定向suite；RC、ABI、bootstrap、fixed point和间歇性内存路径按活动spec执行额外门。
- 测试输出需要后续分析时完整写入临时文件；没有代码/测试输入变化时不重复长套件。

## 常用命令

```powershell
# 从tracked C anchor构建本地compiler
.\compiler\scripts\build_native.ps1

# 使用compiler
.\ring.exe check examples/effects.ring
.\ring.exe check --error-format=llm examples/effects.ring
.\ring.exe build examples/hello.ring --target=c

# 测试
python tests/run_tests.py --suite e2e
python tests/run_tests.py --suite golden
python tests/run_tests.py --suite rc
python tests/run_tests.py --suite self-compile
python tests/run_tests.py --suite structural
python tests/run_tests.py --suite parity
python tests/run_tests.py

# 重建tracked C；提交前验证self-compile/fixed point
.\ring.exe build compiler/main.ring --target=c --out-dir=compiler/dist-c --no-c-lines
```

## Bootstrap与C ABI

- 编译器源码变化后使用当前compiler重编`compiler/main.ring`；结构级变化可能需要连续bootstrap。只有活动spec要求的gen2/gen3文本fixed point和相应smoke成立，才宣称self-host完成。
- C bridge只提供安全Ring无法表达的raw-memory/OS边界；普通Ring callable和extern走统一既定ABI，不新增name table或手工backend特判。
- Slot所有权：`ring_slot_read`=peek+dup；`ring_slot_take`=move并清空；`ring_slot_write`=空slot接管；`ring_slot_replace`=替换并drop旧值；`ring_slot_drop`=take+drop。
- List/Map/Option固定runtime type/drop必须与生成struct drop分工唯一；Set/StringBuilder按普通Ring struct处理。无字段enum ctor产生fresh box，必须按exact ctor identity判断。

## ASan

- Gating：`malloc_context_size=0:quarantine_size_mb=16:max_redzone=32:detect_leaks=0`
- Capstone：`quarantine_size_mb=256:malloc_context_size=12`
- 建议：`-fsanitize=address -O1 -fno-omit-frame-pointer`
- 每条命令显式设置`ASAN_OPTIONS`，不依赖用户环境；gating用于内循环，capstone用于高风险里程碑和最小复现。
