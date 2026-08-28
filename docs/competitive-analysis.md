# Ring-lang 竞品与行业定位

> 最后更新：2026-08-28
>
> 外部事实截止：2026-08-28（版本、活跃度与 stars 均为时点数据）
>
> 用途：产品定位、路线图取舍、B-001 Refinement Types 与 B-111 LLM eval harness 的证据输入

## 口径与证据纪律

本文比较直接与相邻语言、主流替代工具链、形式化验证/AI proof 生态，以及 Ring 当前已实现能力。所有时效结论受顶部事实截止日期约束：

- 时效事实只采用项目官网、官方 GitHub、官方 release notes、论文或会议页面；
- 明确区分「已发货 / 实验性 / 宣称 / 计划」，不把 roadmap 当产品能力；
- 无法确认的事实标为未知，不以搜索空集证明不存在；
- 不把默认语言安全、可选 refinement 和完整功能正确性混成同一级保证；
- stars 只表示关注度，不表示采用率、成熟度或技术正确性。

---

## 1. 结论先行

### 1.1 Ring 仍有差异化，但不能再表述为「无直接竞品」

截至 2026-08-28 的一手来源复查，尚未发现一个项目**同时交付**以下组合：

- 面向应用开发、接近脚本语言的低标注表面；
- HM 类型推断与 application-facing effect inference；
- 显式 failure / mutation contract 与 application-facing custom handled effect；
- Perceus 风格确定性 RC、native、自举；
- 把 agent 可修复诊断、签名信息密度和可重放验证闭环作为产品目标。

这不是排他性证明，而且 Ring 自身也尚未把这套组合全部交付：当前 main 仍是 legacy HIR / Perceus 管线，完整 ownership、0.1 effect 分域与 preview agent 产品面都还在活动路线中。

但每个单项都有强先例，部分组合也已出现：

- **Koka / Effekt / Flix**：effect inference、effect polymorphism、handler 与优化；
- **Unison**：abilities（代数效果）+ 内容寻址代码库 + 语义化编辑/agent 工具；
- **MoonBit**：ML 风格应用语言 + 完整工具链 + native + 实验性形式化验证；
- **Zero**：graph-native 程序数据库 + agent checked edits；
- **BAML**：typed agent/workflow language + standalone VM + 跨宿主 bridge + agent skill/semantic tools/eval 回流；
- **Mojo 1.0**：source-stable 核心、linear / lifetime 路线、AI compute 与完整开源编译器工具链；
- **Roc / Flux**：分别提供 ARC + platform capability 的应用语言近邻，以及 Rust-integrated refinement 的 G2 机制近邻；
- **Verus**：Rust 上的规范、proof/exec 分层、权限模型、SMT 验证与 AI proof 生态；
- **TypeScript 7 / Python / Rust**：凭生态、训练语料和工具链形成极强的「已经够好」替代。

因此，Ring 的可辩护定位不是“发明了无人拥有的单项机制”，而是：

> **把可推断的行为契约、确定性资源语义和 agent 闭环放在同一条 application-native 默认路径上，并用可复现实验说明它比主流工具链减少了多少上下文、重试和运行时失败。**

这仍是一个有窗口的组合，但窗口必须靠实现和数据守住，不能靠空集论证。

### 1.2 当前威胁排序

| 层级 | 对象 | 主要威胁 | 结论 |
|---|---|---|---|
| **极高** | TypeScript 7 | 主流替代、native 工具链速度、编辑器与训练数据 | 已从 beta 风险变成正式发货事实 |
| **高** | MoonBit | 最接近的应用语言产品、团队与工具链、`moon prove` | 工程威胁上调，effect 机制仍不同 |
| **高** | Python + Astral/Codex | agent 生态与低摩擦「够用」路径 | 语言保证弱，但采用阻力最低 |
| **高** | Zero | graph-native 程序库、checked edits 与完整 agent CLI/skills | 机制路线不同，但产品面竞争直接 |
| **高** | BAML | 直接占据“programming language for agents”、agent-first toolchain、跨语言渐进采用与公开反馈回流 | 新语言通道仍为 canary，但产品与叙事竞争已经正面成立 |
| **高** | Mojo | 1.0 source stability、完整开源 compiler/toolchain、linear/lifetime 与官方 agent skills | 已从资源/叙事威胁上升为可审计、可长期采用的语言对手；ABI/stdlib/部分并发与 lifetime 能力仍未完全稳定 |
| **中高** | Rust + Verus | 安全基线、证明能力、训练数据、系统生态 | Ring 的安全/验证措辞必须分层且可证 |
| **中** | Flix / Koka / Effekt / Unison | effect 与语义工具机制先例 | 市场替代低，技术与叙事纠偏价值高 |
| **中** | Rue | 一人 + agent 的编译器工程速度与纪律 | 非直接产品竞品，是执行力基准 |
| **中低 / 机制高** | Roc / Flux | ARC、platform capability、bounded refinement 工程先例 | 当前产品成熟度有限，但分别直接约束资源/effect 与 B-001 设计 |
| **低** | Mog | 小规范、嵌入式 capability 模型 | 活跃度低，保留为规格压缩启发 |

2026-08-28 保鲜复查没有改变上述排序。正式版本的净变化只有 Astral `ty` 0.0.75 与 Effekt 0.78.0；BAML 0.17.1、Mojo 1.1 与 Verus 的更新仍分别属于 nightly/dev/rolling，不能升级为新的稳定能力。TypeScript 7、MoonBit、Zero、Mojo stable、Koka、Flix 与 Unison 的最新正式版本均未变化。该结果只更新时点事实，不产生新的 Ring feature、backlog 或 0.1 前置。

### 1.3 五个最重要的路线图含义

1. **B-111 是立论门，不是营销附件。** TS7 已正式发布，Ring 必须用同协议、同模型、同预算的实验回答“effect 签名是否真的减少 token/轮数/运行时错误”。
2. **B-001 应做 bounded refinement，不应复制 Verus 或 Flux。** 普通 Ring 代码继续依靠默认类型/effect/资源检查；refinement 先限定可判定片段、机器整数语义和运行时兜底，再谈通用 SMT。
3. **形式化验证必须显式管理信任。** Verus、`moon prove`、CryptoProver 与 Vero 都说明“证明成功”不等于“无假设”：solver、整数模型、trusted library / external spec、编译器和 runtime 都属于保证边界。
4. **C-only 只是发布地基，不是产品发布。** Zero 与 BAML 已把 install/run、版本匹配 skill 和 semantic inspection 做成同一 compiler 产品面；Mojo 1.0 又把 source stability 与完整开源 compiler/toolchain 提升为采用基线。Ring 的 candidate 不应只是二进制压缩包：迁移与 release blockers 收口后，产品面保持 B-174 → B-177 → B-175，让只读、版本化的 semantic inspection/skill/primer 随 candidate 一起被验证；保持源码 + Git 为真值，不追随 graph-native 存储重写。
5. **“Agent PL”已经成为真实品类，不再只是 Ring 的内部定位词。** BAML 已把 `agent install`、`describe`/`grep`、standalone run、跨语言 bridge、内建 eval 与 agent 反馈回流放在同一产品面。Ring 不应跟随其 LLM-workflow VM/GC 路线，而应让 B-174/B-177/B-111 证明 inference-first native、显式 effect 与确定性资源契约在普通应用任务上的独立价值；B-111 保持 TypeScript 7 单一语言对照，另做有界的 Ring 工具面消融来区分“语言契约”与“skill/inspection”的贡献。

---

## 2. 比较框架：不要把不同保证混在一起

### 2.1 保证阶梯

| 层级 | 保证 | 代表 | Ring 对应状态 |
|---|---|---|---|
| G0 | 语法、格式化、结构化诊断与可修复编辑 | Zero checked patch、LSP/MCP 工具 | `--error-format=llm` 等内部基础已有；formatter、版本化 inspection、bundled skill/primer 与可量化闭环尚未发货 |
| G1 | 默认类型/效果/所有权或资源安全 | Rust、Flix/Koka effects、MoonBit 类型系统 | HM/trait、legacy effect、Perceus RC 与 verifier 已实现；I′ identity-only checkpoint 已接受，但 #268/#269 仍阻止整体 ownership/resource-safety claim |
| G2 | 有界值级性质，编译期证明 + 明示运行时兜底 | Liquid-style refinement、Flux | B-001 规划中，尚未发货 |
| G3 | 用户规范下的功能正确性证明 | Verus、实验性 `moon prove` | 非 Ring 当前默认目标；只借鉴可组合的 verification lane |

G1 和 G3 解决的问题不同。Verus 的证明能力更强，但要求规范、lemma、trigger/invariant 与显式权限；Ring 的目标是让普通应用代码在 G1 路径保持低标注，再为局部高价值性质增加 G2。

### 2.2 威胁维度

- **产品替代**：用户今天能否直接选择它完成同类工作；
- **机制重叠**：是否已经实现 Ring 的核心技术；
- **agent 叙事**：是否占据“为 AI 编程而生”的心智；
- **证据强度**：是否有公开基准、论文、生产案例或 soundness 边界；
- **执行速度**：团队能否在 Ring 窗口内追平组合。

stars 和发布频率只辅助判断后两项，不直接证明产品质量。

---

## 3. 全景矩阵

| 项目 | 时点状态 | 已发货核心 | Agent 路线 | 保证层 | 对 Ring 的关系 |
|---|---|---|---|---|---|
| **Ring** | C11-only 自举；I′ exact identity checkpoint 已 fixed-point 接受，#268/#269 仍 critical/doing | current main 为 HM + trait、legacy `io/fail/mut`、limited handler、Perceus/verifier 与 C11 native；A1递归组、R1动态evidence、P2统一`EffectCtx`与分层IR属于已批准且在isolated authority实现中的目标，尚无aggregate behavior acceptance | 结构化诊断已有；inspection/primer 与 B-111 待交付 | G1 机制已有、整体 ownership/resource guarantee blocked | 被比较对象 |
| **TypeScript 7** | 7.0 正式通道；截至 2026-08-28 最新正式 release 为 7.0.2 | Go native 编译器、LSP、`strict` 默认、并行检查 | 海量训练数据 + 编辑器/agent 生态 | G1 的结构类型子集 | 最大主流替代 |
| **Python + Astral** | Ruff/uv/ty 持续发展；`ty` 0.0.75；OpenAI 收购协议未确认交割 | 极低摩擦生态与高速 lint/env/type/LSP 工具链 | Codex/agent 原生使用场景 | G0–G1（依工具） | 最大低阻力替代 |
| **Rust** | 1.98；Polonius Alpha 与 next trait solver 在 nightly 默认启用、仍未稳定 | ownership/borrow、trait、unsafe 隔离、native | 高训练覆盖 + LSP/agent 工具 | 强 G1 | 安全基线与底层替代 |
| **MoonBit** | v0.10.9；1.0 目标 Q3 2026 | ML 风类型、Wasm/JS/C/native、LSP、包管理、Pilot、`errdefer`/async cleanup | 专用 coding agent 与工具链 | G1；`moon prove` 仍为实验性 G3 | 最接近产品竞品 |
| **Zero** | v0.3.4、experimental；semantic graph 是程序数据库、`.0` 是 projection | checked graph/patch、query/inspect/check/test/run、显式 capability | agent 直接操作图并消费版本匹配 skills | G0–G1 | 最直接 agent 产品面竞品 |
| **BAML** | 新 BAML Language stable仍为0.17.0；0.17.1仅nightly，legacy BAML v0 0.226.1；新通道仍在迁移期 | TypeScript 风类型、typed errors、bytecode VM/GC、green-thread workflow、standalone run、跨宿主 bridge、内建 tests/evals | `agent install`、`describe`/`grep`、project-local toolchain pin、LSP 与 Agent Tries BAML | G0–G1（类型/错误；非确定性 ownership） | 直接 agent-language 产品/叙事竞品；运行与资源路线不同 |
| **Mojo** | 1.0；compiler/tooling 已完整开源 | Pythonic syntax、linear/lifetime types、compile-time reflection、AI compute；多数核心语言进入 source stability | 官方 agent skills | G1 | 高资源与产品威胁；ABI、stdlib 稳定面及部分能力仍有限 |
| **Koka** | v3.2.3；活跃研究语言 | effect inference/handlers、evidence passing、Perceus、C backend | 非主要目标 | G1 | Ring 最接近理论与实现来源 |
| **Flix** | v0.75.3；活跃 | effect polymorphism、subeffecting/exclusion、handlers、purity-driven optimization | 官方已直接研究 LLM 对新语言的影响 | G1 | 直接机制近邻 |
| **Effekt** | v0.78.0 | algebraic effects、contextual effect polymorphism、capabilities/resources、持续优化 | 非主要目标 | G1 | 活跃的 effect 实验场 |
| **Unison** | 1.4.0；已过 1.0 | abilities、content-addressed codebase、语义重构、分布式能力 | MCP/agent 工具持续增加 | G1 | “效果 + 语义程序库”最强先例 |
| **Verus** | 2026-08 稳定/rolling release 持续 | Rust 子集、spec/proof/exec、ghost erasure、SMT、权限模型 | CryptoProver、Vero 等 repo/cross-file proof 研究继续推进 | G3 | 形式化验证首要参照，非应用语言直接替代 |
| **Roc** | 仍明确未 ready for 0.1 | 低标注函数式应用语言、platform-controlled I/O、ARC + opportunistic reuse | 提供 experimental AI-friendly docs | G1 目标 | 应用/ARC/platform capability 机制近邻，产品成熟度有限 |
| **Flux** | 活跃研究工具；稳定发布/生产采用未知 | Rust refinement checker，以逻辑谓词验证值级性质 | 非主要目标 | G2 | B-001 的直接工程参照，非应用语言竞品 |
| **Rue** | 2026-08-21 field report：820/823 traced rules、2,375 spec tests；仍 early-stage | affine ownership、native、自研 IR、spec/test/fuzz/sanitizer | 主要由 Claude 协助构建 | G1 目标，仍实验性 | 一人+agent 工程基准 |
| **Mog** | 官方最新提交仍为 2026-03-09 | 3,200-token spec、host capabilities、native | 为 agent 使用而压缩规范 | G0–G1 | 小型规格/嵌入式启发 |

---

## 4. 主流「够用就行」替代

### 4.1 TypeScript 7：威胁已从计划变为现实

TypeScript 7.0 已在 2026-07-08 正式发布，不应再称为 tsgo beta。官方数据包括：

- Go native port 对典型完整构建带来约 8–12× 提升；
- 新 LSP 相对 TypeScript 6 显著降低失败命令和 crash；
- Slack 报告 CI 从 7.5 分钟降到 1.25 分钟，Canva 报告首次错误从 58 秒降到 4.8 秒；
- 7.0 默认启用 `strict`，支持稳定类型排序与并行检查；
- 7.0 暂无旧式 programmatic API，Vue/MDX/Astro/Svelte 及部分 Angular 嵌入式流程仍可能需要 TypeScript 6；官方提供 `@typescript/typescript6` 并行安装路径。

截至 2026-08-28，最新正式 release 仍为 7.0.2；原报告设定的“7.1 恢复 programmatic API并完成主流 framework 迁移”提前复查门尚未触发。

这意味着 Ring 不能再用“编译器更快”作为充分差异。TS7 的优势是：

- 训练数据、npm、编辑器与 agent 工具几乎无迁移成本；
- 反馈时延已经低到足以支撑快速 agent loop；
- 类型系统虽不追踪完整副作用，但能满足大量 Web/CLI/服务端任务。

Ring 的可证伪反论必须交给 B-111：在同模型、同任务、同预算下，行为签名是否减少总 token、修复轮数和隐藏测试失败，而不是比较宣传语。

### 4.2 Python + Astral/Codex：采用阻力最低

Python 的核心优势不是静态保证，而是：

- 模型训练覆盖广、库生态大、生成成功先验高；
- Ruff、uv、`ty` 等工具持续压低 lint、环境与类型反馈成本；`ty` 0.0.75 已提供多平台 type-check、LSP 与结构化诊断产品面；该版继续补PEP 723脚本环境、pytest fixture导航、autofix、泛型推断与unsound narrowing修复，但仍是0.0.x通道；
- OpenAI 2026-03-19 宣布与 Astral 签署收购协议，并明确工具与 Codex 的协同方向。

截至本报告日期，OpenAI 和 Astral 官方页面仍使用“拟收购/已签协议/将加入”措辞，本文不把交易写成已完成。

Ring 面对 Python 时应强调“失真必须响”的默认保证和可枚举行为契约，而不是只强调语法简短；Python 在简短与生态上几乎不可正面击败。

### 4.3 Rust：安全基线，也是 Verus 的生态地基

Rust 1.98 已把 ownership、unsafe 隔离、native 性能和成熟工具链继续维持为用户基线。2026-08 的 Polonius Alpha 与 next-generation trait solver 已在 nightly 默认启用，但仍处稳定化前测试期；它们不能写成当前 stable 能力，却说明 Rust 正持续削弱 borrow/trait 的人体工学劣势。Verus 则进一步证明：在 Rust 语义与生态上叠加规范和 SMT，可以覆盖高保证系统。

对 Ring 的约束：

- “Rust 的安全性 + Python 的体验”只能作为目标简写，正式材料必须列出已经保证、正在收口和明确不保证的边界；
- Ring 的零 lifetime 标注与 RC 路线是易用性差异，不自动等于更强安全；
- agent 对 Rust 的训练覆盖和工具支持会持续削弱“新语言更适合 agent”的先验，B-111 必须覆盖 onboarding 成本。

---

## 5. 最接近的产品与叙事竞品

### 5.1 MoonBit：最接近的应用语言产品

MoonBit 当前比 Ring 成熟得多：多后端、包管理、LSP、文档与专用 agent 已形成产品面。v0.10.9 的关键状态：

- native backend 已扩展到 x86-64 Linux 与 Windows nightly；Apple Silicon debug 默认 native，release 仍可走 C `-O2`；
- native LSP 默认启用，async 与 Wasm async 持续迭代；
- `errdefer` 与 async cleanup 继续加强显式错误/资源清理路径；
- 通过显式 `extend Type with Trait` 收紧隐式方法附着，体现其对可重构性的重视；
- 1.0 目标为 2026 Q3，但官方保留依据测试结果调整的空间。

#### `moon prove` 的真实能力与边界

`moon prove` 不是一句 roadmap：

- `.mbt` 中写可执行代码与 contract，`.mbtp` 中写 predicate、model 和 lemma；
- 支持 `proof_require`、`proof_ensure`、`proof_assert`、循环 invariant、termination decrease、pure/axiomatized 标记；
- proof-enabled package 降到 Why3，再调用 Z3、cvc5 或 Alt-Ergo；当前工具链已不再要求用户单独安装 Why3，只需安装受支持 solver；
- 官方仍明确标为 experimental；
- 当前整数验证模型是无界数学整数，**不模拟运行时机器整数溢出**；
- 局部 mutation 与 escaping `FixedArray` 等仍有限制，验证代码更偏函数式；
- `proof_axiomatized` 等入口进入信任边界。

这使 MoonBit 同时成为产品与 verification-adjacent 竞品。Ring 不能再声称 refinement 在理论整合上天然胜出；B-001 必须通过更清晰的机器整数语义、可判定性和默认低负担证明其取舍。

#### 与 Ring 的关键差异

| 维度 | MoonBit | Ring |
|---|---|---|
| 普通函数 effect | 局部函数倾向显式 effect 声明；错误/async 有专门机制 | current main 为 legacy `io/fail/mut`；0.1 已批准 system/handled 分域，但尚未实施 |
| Handler | 非 application-facing 核心卖点 | current main 有 limited tail-resumptive + abort；0.1 custom effect 只保留显式 handler |
| 资源 | 多后端与 runtime 路线并行 | Perceus RC 已有；分层 FlowIR/ResourcePlanner 是已批准终态，完整 ownership 尚未接受 |
| 验证 | 独立 experimental `moon prove` lane | bounded refinement 规划中，尚未发货 |
| Agent | MoonBit Pilot + 完整工具链 | 编译器诊断/签名路线，B-111 尚待实证 |

结论：**工程与采用威胁高，effect 机制不是同一路线，验证叙事已正面相遇。**

### 5.2 BAML：已经正面占据“programming language for agents”

2026-08-28 复核确认，BAML 已不再只把自己描述成 prompt/structured-output DSL。官方默认分支、仓库 description 与新官网统一使用 **“the programming language for agents”**；新 BAML Language 的最新稳定版仍为0.17.0，8月26日可见的0.17.1仍是nightly，legacy BAML v0 已到0.226.1。两条产品面仍处于迁移期：旧文档首页继续把 BAML 定义为 structured-output DSL，而新官网与新工具链已经展示更广的 standalone agent/workflow language。

#### 已交付或可由官方产物核验的产品面

- TypeScript 风表面包含 union、generic、lambda 与 pattern matching；类型在 runtime 保留，公开设计排除 `any` 和 unchecked cast，并以 typed error/`throws` 进入函数类型；
- Rust 实现的 compiler、bytecode VM、GC 与 async engine 支撑 standalone `baml run`、green-thread/colorless workflow、取消和并发；这不是 Ring 的 C11 AOT + Perceus deterministic RC 路线；
- wrapper/toolchain 可安装、以 `baml toolchain pin` 固定 project-local 版本并跨 macOS/Linux/Windows 运行；Python、TypeScript、Go、Rust、Java、C#、C++、Kotlin、Swift 等宿主通过生成 bridge 渐进采用；
- `baml agent install` 提供版本匹配的 agent skill，`baml describe` / `baml grep` 面向 agent 暴露语言与项目事实；IDE/LSP、内建 tests/evals、标准库和本地 tracing 已形成连续产品面；
- 0.17.0 的 type-checker rewrite、LSP code action 与诊断增量继续增强“同一 toolchain 提供语言事实和修复入口”的产品耦合；
- “Agent Tries BAML” 公开了 run、agent、finding、skill arena 与 pinned build 的反馈结构，明确把 agent 真实写程序、发现问题、修复并在新 build 复验作为语言迭代输入。

官网还宣称 compiler 快于 Go、semantic search 优于 ripgrep、pack 产物小于 Bun，以及 tracing 相对 OpenTelemetry 的数量级优势。本轮没有把这些营销数字核验为可独立重放的 benchmark，也没有确认 Agent Tries BAML 已提供稳定的跨语言对照协议与完整 raw manifest；因此它们当前只算**官方宣称/方法信号**，不能进入 Ring 的性能或 agent-efficiency 事实账本。

#### 对 agent 真正有效的组合，以及尚未证明的边界

BAML 最值得 Ring 响应的不是 TypeScript 风语法或“agent-first”标签，而是三层产品耦合：编译器同版本发布的 skill 和 semantic tools 降低 agent 的语义搜索成本；`run`/trace/eval 把“生成—执行—观察—修复”收进一个可重放回路；bridge 让新语言可以从既有应用中局部采用。单独复制一份 prompt 或一个 JSON 命令不会形成同等产品能力；版本锁定、权威语义来源、失配拒绝与 raw trace 才是可守护部分。

同时，这一组合没有自动证明三件事：严格类型能减少 schema/API 形状错误，但不能保证 prompt 事实性、业务不变量或非确定 LLM 输出正确；VM/GC/async engine 与多宿主 bridge 把易用性换成了更广的 runtime TCB 和兼容矩阵；当前 canary/旧 v0 文档分裂、包生态与官方 benchmark 仍不足以支撑“已成熟或已领先”的结论。

#### 与 Ring 的关键差异

| 维度 | BAML | Ring |
|---|---|---|
| 首要 workload | LLM function、agent/workflow、eval 与宿主应用嵌入 | 普通 native CLI/应用；agent 是重要作者/消费者而非唯一运行对象 |
| 执行与资源 | bytecode VM + tracing GC + async engine；多宿主 bridge | C11 AOT + Perceus RC；确定性资源与显式 failure/effect 是语言公理 |
| 类型/行为契约 | 严格 runtime-preserved types、typed errors，强调无 `any`/unchecked casts | HM/trait + inferred behavior contract；0.1 effect 分域与完整 ownership 仍在收口 |
| Agent 产品面 | skill、`describe`/`grep`、eval、公开 agent feedback loop 已可见 | 结构化诊断已有；B-174/B-177/B-111 仍待形成可安装、可测量闭环 |
| 采用路径 | standalone + 多语言渐进 bridge，降低替换成本 | 目标是独立 native application language；首个 preview 不以 FFI bridge 生态为前置 |

结论：**威胁为高，但主要是产品、采用与叙事威胁，不是 effect/ownership/native 机制同构。** BAML 已使“专为 agent 的编程语言”成为有安装入口、runtime、工具链和反馈系统的公开品类；Ring 不能再把 LLM-first/agent-readable 本身当差异。可辩护边界应收窄到 inference-first native application language、显式 effect 与确定性资源语义，并由 B-111 量化。

路线响应不新增独立 backlog、不提升任务优先级，也不改动 #268/#269 → B-176/B-180 与 B-187 → B-190 → B-183 → preview 产品面的既定依赖；迁移后的 preview 顺序仍为 B-174 → B-177 → B-175。B-177 保持 P1，把 version-matched skill 和 `describe`/`grep` 类可发现性纳入发布包，且只导出 compiler 的权威语义事实；B-111 保持用户已拍板的 TypeScript 7 单一语言对照，在行为契约子集另做有界的 Ring 工具面消融。不为追赶宿主 bridge、GC VM 或 workflow stdlib 扩大首个 preview 范围。

### 5.3 Zero：graph-native 已从叙事推进为完整 agent loop

截至 2026-08-28，Zero 最新正式 release 仍为 v0.3.4，项目仍明确标为 experimental；其 semantic graph 继续作为 program database，`.0` 文本是 human-readable projection，而不是普通 authoring 真值，checked graph 是 compiler input。其公开 loop 包括：

- `zero query` / `zero inspect` 获取 stable graph facts，`zero patch` 以 graph hash 拒绝陈旧或非法编辑；
- `zero check` / `zero test` / `zero run` 覆盖日常闭环，并提供一行安装与 `--version`；
- compiler 随版本提供 language/stdlib/agent/graph skills，减少外部 primer 漂移；
- `World`/capability 与 graph model 仍不同于 Ring 的 inferred effect + 普通文件/Git 路线；项目继续明确标为 experimental，不应把产品面完整误写成 production safety。

这使 Zero 的威胁从“agent-first 叙事”上升为“agent compiler 产品面”。Ring 不应复制 graph-native source-of-truth：这会牺牲现有 Git/文本生态并引入第二套存储模型。合理响应是 B-174 先交付可安装的 check/build/run/doctor，B-177 从 compiler 权威语义阶段导出只读、版本化的 identity/signature/effect/import/unsafe contract，配套 source hash stale guard、skill 与 bundled primer，再由 B-175 把它们一起纳入 candidate 重放。是否需要 checked patch 必须由 B-111/真实 agent loop 证据另行立项，不能因竞品存在就预设。

### 5.4 Mojo：1.0 与完整开源把威胁提升到产品层

Mojo 1.0 于 2026-08-11 发布，官方开始承诺大多数核心语言特性的 source stability；8 月 18 日 compiler、tooling 与构建语言所需的源码以 Apache-2.0-with-LLVM-exceptions 完整开源。已发货能力包括：

- Pythonic 表面、typed errors、linear/lifetime types、compile-time reflection；
- unified pointer + per-operation unsafe、unique resource container 与显式 deinitialization；
- CPU/GPU/AI kernel 与模型服务的深度整合；
- 官方 agent skills 与“更早编译期反馈降低 agent 成本”的叙事。

这个变化消除了旧报告“compiler 开放范围有限”的关键保留，使 Mojo 成为可审计、可 fork、可长期采用的 general-purpose language 对手。边界仍需写清：1.0 的 ABI 不稳定，stdlib 初始稳定集合较小，interior origins 等 lifetime 能力仍标 experimental，async 等能力也未全部进入稳定承诺；它也没有把通用 algebraic effects/handlers 作为应用语言核心。

因此 Mojo 对 Ring 的威胁由中上调为**高**：资源与产品执行力已经正面竞争，effect inference 与确定性 RC 默认路径仍不同。Ring 不应追随 AI-kernel 平台范围，而应让 #268/#269、B-181 与 preview 产品面分别证明安全、资源与采用主张。

### 5.5 Roc：ARC、platform capability 与低标注应用语言近邻

Roc 官方仍明确表示尚未 ready for 0.1，当前 compiler 与语言表面也在迁移中；它不能作为成熟产品替代。但其组合与 Ring 有持续机制相关性：

- 低标注函数式应用语言表面；
- platform 控制 I/O 与 host capability，应用代码通过 platform 提供的能力运行；
- ARC 与 opportunistic reuse，直接提供确定性资源/复用的相邻工程经验；
- experimental AI-friendly 文档，开始显式优化 agent onboarding。

Roc 的产品威胁为中低，机制参考价值为中高。其 platform 模型不等于 Ring 已批准的 `SystemEffectRef` / AbiIR `HostImport`，但足以进入核心矩阵，持续校验 capability 与 runtime 边界是否被过度设计。

---

## 6. Effect 与语义程序表示赛道

### 6.1 Koka：最接近的理论与实现来源

截至 2026-08-28，Koka 最新 release 仍为 v3.2.3，官方 dev 主线保持活跃。它已经证明：

- polymorphic type/effect inference 与 algebraic handlers 可工程实现；
- evidence passing 可把 handlers 降为高效直接代码；
- Perceus 可把精确 RC 与 reuse analysis 结合；
- C backend 能承载这些语义。

Koka 是研究语言，生态、async library、包管理与 production support 不是其强项。它对 Ring 的意义是“核心算法并非空白创新”，也是 correctness 风险提醒：近期仍出现 Perceus 相关 UAF 修复，静态资源 pass 必须有 verifier 和回归门。

Ring 的差异在 application-facing 语法、有限 handler 语义、`mut` 可见性、自举、agent 诊断与产品目标，而不在“拥有 effects/Perceus”本身。

### 6.2 Flix：直接机制近邻

Flix v0.75.3，项目保持活跃。其 effect system 已覆盖：

- effect polymorphism、subeffecting、effect exclusion；
- primitive/algebraic/heap effects 与 handlers；
- purity reflection 和 associated effects；
- 用 purity 信息驱动自动并行化、dead-code elimination 与 inlining。

Flix 官方还直接讨论并实验 LLM 对新语言和 effect 代码的影响。这意味着“effect 签名帮助 LLM”并非 Ring 独占的话语空间，Ring 必须更快产出可复现实验和 application-native 体验。

Flix 偏函数式/JVM 与研究型生态，市场替代威胁有限；机制与 AI 论证威胁为中高。

### 6.3 Effekt：活跃的 capability/effect 实验场

Effekt 已于2026-08-24更新到v0.78.0；本次正式版主要加速array/bytearray，并通过CSE改善aliased value sharing，没有改变其公开effect模型或Ring威胁层级。近期版本密集，并继续加入monomorphization等优化。核心包括：

- algebraic effects/handlers；
- contextual effect polymorphism；
- capability 与 resource 表达；
- JS 等后端及持续推进的 C FFI。

Effekt 是研究语言，但其活跃度说明 handler/capability 设计仍在快速迭代。Ring 应持续把 handler 子集的取舍写清：当前只做 tail-resumptive + abort，full AE 不在计划中；“完整代数效果”已不再是准确措辞。

### 6.4 Unison：effects + semantic codebase 的最强先例

Unison 已发布 1.0，当前 1.4.0；官方 1.0 数据显示已有数千项目作者和十万级发布定义/下载。1.4 继续更新 UCM/MCP 与交互运行入口。它把：

- algebraic effects（abilities）与 handlers；
- 内容寻址的 codebase；
- 基于 identity 的 rename/refactor；
- 分布式计算模型；
- MCP/agent 工具

放在同一产品中。

Unison 的函数式、分布式与 codebase-as-database 产品模型和 Ring 不同，但它反驳了“effect + 语义程序库 + agent 工具无人组合”的说法。Ring 的区别应落在普通文件/Git 兼容、应用语言手感、effect inference、native 与确定性资源语义。

---

## 7. Verus：形式化验证与 AI proof 的首要参照

### 7.1 它是什么，不是什么

Verus 是在 Rust 子集上增加规范与证明的验证工具链，不是面向一般应用开发的新语言。它处于活跃开发期，README 仍明确提示缺失/损坏特性和不完整文档；同时维持每周滚动发布，并已用于多个真实系统研究。

它对 Ring 的竞争主要发生在“安全/正确性到底能保证到哪一层”的叙事，而不是语法、包生态或普通应用开发。

### 7.2 管线与架构

Verus 的核心管线为：

```text
Rust source
  → rustc HIR
  → VIR-AST
  → VIR-SST
  → AIR
  → SMT-LIB
  → Z3（cvc5 实验性）
  → 验证通过
  → 擦除 spec/proof/ghost
  → 正常 rustc MIR/LLVM 编译 exec 代码
```

代码按 `spec`、`proof`、`exec` 分层。验证 IR 与执行 codegen 解耦、ghost 擦除、proof 不进入产物，这些是 B-001 可以直接借鉴的架构原则。

### 7.3 保证、成本与 TCB

Verus 可以验证内存安全和功能正确性，但保证相对于用户规范与信任边界成立：

- `assume`、`external_body`、`external_fn_specification`、`external` 等会引入假设；
- TCB 包含顶层规范、Verus verifier、SMT solver 与 Rust 编译器；
- SMT 推理一般不可判定，工程上依赖 trigger、invariant、分解和 resource limit；
- Verus 不把“只经 Rust typecheck”视为足够：其 raw pointer/权限代码必须实际完成验证。

SOSP 论文的 5 个系统案例合计约 6.1K 行实现代码和 31K 行证明代码，说明它能处理真实低层系统，也说明完整证明仍有显著规格/lemma 成本。论文报告的速度优势是相对其他验证系统，不等于普通编程零成本。

### 7.4 权限模型对 Ring 的启发

Verus `vstd::raw_ptr` 用 `PointsTo`、`PointsToRaw`、`Dealloc` 等 ghost permissions 描述地址、provenance、metadata、初始化状态与释放权。这比“裸指针在 unsafe 块里所以没问题”强得多。

对 Ring 的可用映射：

- 当前 `unsafe` effect + `Ptr<T>` 保留显式 discharge 和 `ring audit unsafe` 审计面；
- RIIR 稳定后，可研究**可选**的 pointer permission verifier，把常见 raw pointer 义务静态化；
- 即使未来实现，也应是局部 verification lane，不把所有普通 Ring 代码变成 Verus 风格 proof engineering。

### 7.5 VerusBelt：soundness 证据也有边界

PLDI 2026 VerusBelt 给出了 Verus 重要子集的首个语义 soundness 证明，覆盖 proof-oriented types、lifetime/borrow/concurrency 等关键机制。其边界同样重要：

- 证明针对形式化模型中的重要子集，不是对整个 Verus 实现二进制的验证；
- 部分常用库按 axiomatized 方式建模；
- 编译器、solver 与规范仍属于整体信任链。

对 Ring 的教训是：文档应同时公布“证明了什么”和“没有证明什么”，不要把 verifier 通过压缩成无条件“安全”。

### 7.6 Flux：Rust-integrated refinement 的直接工程参照

Flux 为 Rust 类型增加逻辑谓词，并在编译期验证值级性质，是 B-001 最直接的 G2 工程参照之一。它说明 refinement 不必把整门应用语言改造成 proof language，也说明 ownership 与 refinement 的组合已有实现先例。

Flux 的稳定 release、生产采用与长期兼容承诺在本轮一手资料中仍为未知，因此不把它列为成熟产品竞品。对 Ring 的约束是：B-001 必须明确机器整数、可判定片段、fallback 与信任边界，不能只凭“低标注”声称优于 Rust-integrated refinement。

---

## 8. AI 证明生态：证明编写正在被自动化，信任边界没有消失

Verus 周围已形成连续的 AI proof synthesis/repair 研究线：

| 项目 | 时间/发表 | 方向 |
|---|---|---|
| RAG-Verus | 2025-02 | 用检索增强生成 Verus proof |
| AlphaVerus | ICML 2025 | 生成并迭代形式化证明 |
| AutoVerus | OOPSLA 2025 | 自动补全/修复 Verus annotations |
| VeriStruct | 2025-10 | 利用结构化验证信息 |
| VeruSAGE | 2025-12 | agentic proof 工程 |
| KVerus | 2026-05 | Verus 证明生成/知识利用 |
| ExVerus | ICML 2026 | 扩展 proof synthesis |
| Propose/Solve/Verify | ICML 2026 | 生成—求解—验证闭环 |
| CryptoProver | 2026-08 preprint | 在固定 API contract 与 trusted library 下，为 production cryptographic code 生成跨文件 Verus spec/proof |
| Vero | 2026-08 preprint | 43 个 repository-level Lean benchmark；最强配置完整解出 27/43，显式保留未解 hard cases |

共同信号：

- LLM/agent 正在降低 lemma、invariant 和 proof repair 的人工成本；
- verifier 是强反馈 oracle，可把生成错误变成机器可判定的迭代信号；
- 但 agent 不能替代正确 specification、TCB 审计、solver 可重复性和整数/内存模型；
- “能自动证明”会提高用户对新语言保证的期待，也会降低证明语法负担这一传统反对理由。

CryptoProver 与 Vero 是强研究信号，不是生产级采用证据：前者依赖固定 contract/trusted library，且其时间数据不能直接解释为人工证明成本已经消失；后者的 27/43 结果反而表明 repo-scale proof 仍有大量未闭合案例。它们支持 B-001/B-182 的 evidence-carrying、anti-cheat 与 negative-result 纪律，不支持把完整 AI proof 提升为 0.1 前置。

Ring 的合理响应是双层：

1. 默认层继续以可判定的类型/effect/资源检查承担大部分代码；
2. 对钱、长度、索引、协议状态等高价值局部性质提供 bounded refinement，并让 agent 消费结构化 proof failure。

不要把完整 Verus 式功能正确性证明塞进 B-001；也不要假设 AI 会自动解决不良规范或 SMT 不稳定性。

---

## 9. Agent 构建与小语言基准

### 9.1 Rue：持续活跃的 agent 编译器工程基准

Rue 是 Steve Klabnik 主导、Claude 深度协作的实验性系统语言。2026-08-21 官方 field report 的状态包括：

- 820/823 个规范规则可追踪；
- 2,375 个 spec test cases；
- x86-64 与 arm64/macOS 支持；
- affine ownership/borrowing/destructors、自研多层 IR、直接 native codegen；
- fuzz、sanitizer、benchmark 与规范追踪基础设施。

这些数字是项目自报、build-generated 的工程进度指标，不等于独立质量或采用证明；项目仍明确标为 early-stage、不可用于 production。

Rue 不追求与 Ring 相同的 HM/effect 应用语言路线，但它表明“一人 + agent”可以在数月内建立非常系统的编译器质量工程。Ring 的人效优势不能继续引用 2026-03 的静态快照，应该比较：

- spec-to-test 可追踪率；
- sanitizer/fuzz 覆盖；
- bootstrap/后端 parity；
- 活跃缺陷关闭速度；
- 可复现发布，而非总代码行或短期 commit 数。

### 9.2 Mog：规格压缩仍有启发，动量低

Mog 是小型、可嵌入、面向 agent 的静态语言：

- 完整规范约 3,200 tokens；
- safe Rust compiler/runtime 规模小；
- host capability、安全嵌入与 native codegen；
- 官方仓库最新提交仍为 2026-03-09，当前产品威胁低。

其启发仍有效：Ring primer 应把**稳定核心语言 + 高频 std 签名**控制在可预测上下文预算内，并由 B-111 实测 onboarding token 成本。

### 9.3 外围 agent DSL

Pel、Quasar、Dana、Darklang 的 agent 化方向主要是 workflow/orchestration、自然语言动作或“AI 唯一作者”，和 Ring 的 native application language 不同。它们可作为叙事雷达，不应与能编译、运行、自举的语言放在同一成熟度表中。

---

## 10. Ring 的真实位置

### 10.1 已有能力

- 自举编译器，Ring 源码贯穿主编译管线；
- 当前 compiler 管线仍为 Lexer / Parser / AST / Checker → `HProgram` HIR → Perceus RC → verifier → C11 codegen；
- HM 推断、trait、row-polymorphic effect 基础，以及 legacy `io` / `fail` / `mut` 与 limited tail-resumptive / abort handler；
- Perceus L0/L1 RC 与 post-RC `LEAK/UAF/BALANCE` verifier；
- C11 是唯一 native codegen/bootstrap，覆盖单文件/project/self-host；tracked `dist-c` 达到文本固定点，最后 LLVM lane 只保存在历史 tag；
- I′ exact-slot identity-only checkpoint 已在固定 current compiler tree 上达到 gen2/gen3 literal fixed point，并通过 standard full runner 与 targeted ASan；该 claim 只接受 identity/provenance 基础；
- `unsafe` effect、`Ptr<T>` 与显式 discharge/audit 面；
- 结构化/LLM 诊断基础。

### 10.2 尚未兑现，不能写成现状

- async effect 设计已有，但 native 实现未发货；
- full algebraic effects/multi-shot continuation 明确不做；
- #268/#269 仍为 `[critical] [doing]`；I′ 不能外推为完整 callable ownership mode、atomic transfer、cleanup 或全局 RC/resource-safety acceptance；
- `AST → ResolvedAST → TypedHIR → CoreHIR → FlowIR → RcIR → AbiIR → C11` 是已批准迁移终态；fixed main 尚无这些独立 compiler stages，仍由 legacy HIR/Perceus/codegen 承担语义；
- 0.1 已批准 `SystemEffectRef(console/fs/process)` / `HandledEffectRef(custom)` 分域、删除 user effect default body，并把用户 Drop 限制为 effect-free；但 current main 仍保留 legacy `io` 与旧 default/evidence/Drop 路径；
- 0.1 已批准A1递归组single-inference、R1调用点dynamic handled evidence与P2统一`EffectCtx` ABI；isolated authority已有typed producer/HIR/C/runtime纵切代码，但尚未通过fresh candidate、统一single/project矩阵或最终长门，不能写成current main已发货能力；
- 0.1 已决定删除 partial/reopened inline module、function default parameters、inert `sig`、refinement `where` placeholder；`T?` 也由 B-191 在 preview 前 clean break。除已明确形成的局部证据外，这些决定不能统称为 fixed main 已发货能力；
- refinement types 未实现：参数位 `where` 仍不能表达，struct-field `where` 在 current main 仍是 parse-and-discard + warning，等待 B-193 删除；
- RIIR 标准库迁移尚未完成；
- Drop 的 C-native abort unwind、Weak 与若干已知 critical RC/runtime 缺陷尚未收口；
- CLI 仍只有 `check/build`，缺可安装 bundle、exe link/run/doctor、跨平台 release matrix 与版本化 agent inspection contract；
- LSP 暂不可用；
- B-111 尚无一轮公开、可复现的 Ring vs TS7 数据；
- “Rust 级安全”“LLM 更容易写对”“语义驱动性能领先”仍需分项证据，不是现成事实。

### 10.3 竞争定位三支柱与证据状态

1. **推断默认行为契约（internal evidence）**：普通代码尽量不写类型/effect/ownership 注解，但编译器产生稳定、可读、可机器消费的签名；0.1 effect class 与完整 ownership carrier 尚未 cut over。
2. **确定性资源与失真可见（设计公理成立，implementation blocked）**：RC/Drop/unsafe discharge/审计面把不可自动保证的部分显式列出；#268/#269 未关闭前不得写成完整安全保证。
3. **可验证的 agent 闭环（hypothesis）**：诊断、语义 query、受检 patch、隐藏测试与 bounded proof 共同缩短生成—验证循环；B-174/B-177/B-111 尚未把它交付并量化。

“语义驱动性能”仍是长期收益，但在 B-181 生成程序基线、RIIR 与 ownership 边界未完成前，不应与已发货支柱并列宣传为已证明优势。B-176/B-180 解决的是 compiler/check 反馈吞吐，不能把开发工具 wall-time 改善混报为用户程序性能。

### 10.4 可对外使用的一句话

> **Ring 是一门 inference-first native 应用语言：源码保持低标注，编译器推断类型、effect 与资源行为，并把无法证明的边界显式暴露出来。**

状态边界：当前 C11 自举与基础类型/effect/RC 机制已有内部证据；完整 ownership 闭环、0.1 system/handled effect 分域和可安装 agent 产品面仍未发货。

若需要更技术化的版本：

> **Ring 的目标路径把 HM 类型/effect inference、确定性资源计划和结构化 agent feedback 组合成默认应用开发体验；bounded refinement 是可选增强，而不是普通代码的证明税。**

---

## 11. 相关工作项

- **#268/#269**：仍是当前 correctness 总门。I′ identity-only fixed point 保留为 durable claim；A1/R1/P2与exact callback set仍在isolated authority的development green boundary，完整 FlowIR freeze、single ResourcePlanner、RcIR/certificate 与最终 full/ASan/self-host/CI acceptance 尚未完成。
- **B-174/B-177/B-175**：按 CLI 闭环 → 版本化 agent contract → Windows/Linux candidate artifacts 交付可安装、可运行、可诊断的 preview；BAML 的 wrapper/toolchain pin/run/bridge 说明版本匹配与渐进采用已成为竞争基线，但首个 Ring preview 不以多宿主 bridge 为前置。
- **B-176/B-180/B-187/B-190/B-183**：ownership 后建立可复现 baseline与 2× 开发反馈目标，并完成 bounded 文档复核，再做 overengineering audit，随后才执行 Vorton/GitHub workflow cutover；竞品变化不改变该顺序。
- **B-181**：单独建立生成程序 runtime、内存/分配与产物尺寸的 release baseline/budget。
- **B-193/B-194/B-195/B-196/B-191**：在 preview 前完成 0.1 surface/effect clean break；不得把已批准目标写成 current main 能力。
- **B-177**：导出版本化只读 semantic inspection contract、provider-neutral skill 与 bundled primer，不改变源码/Git 真值模型；对照 BAML `agent install`、`describe`/`grep` 与 Zero query/inspect 的可发现性，但只消费 compiler 权威事实，并作为 B-175 candidate 门。
- **B-168**：在 B-176/B-180 工具链吞吐专项后确定 C-native failure/control ABI 及其 Drop、TCB 与可移植性边界。
- **B-111**：用固定模型、预算和公开 artifact 复现 Ring vs TypeScript 7 的 agent 开发对照；借鉴 BAML 的 run/finding/skill-variant/build-pin 回流形态，在 Ring 行为契约子集另做工具面消融，不把其未独立核验的结果当先验，也不在首轮擅自增加第三语言。
- **B-001/B-182**：参考 Flux、Verus、MoonBit、CryptoProver 与 Vero，保持 refinement bounded、deterministic，并把 solver、整数模型、trusted assumptions、negative evidence 与 acceptance TCB 明示。
- **B-110**：持续核对 Rust Polonius/NLL 进展；nightly 变化不授权它越过当前 ownership 总门。

---

## 12. 复查节奏与触发条件

### 12.1 GitHub 竞品雷达

公开的 [`Ring-lang` Star List](https://github.com/stars/YYF233333/lists/ring-lang) 是本报告的持续观察入口，由 Repository Steward 依 `docs/workflow.md` 的 standing authorization 维护。每轮竞品复查先读取该清单，再按本报告的一手来源纪律核验事实；复查可在同一工作中自主 Star 官方仓库、更新描述及增删清单成员，无需逐项请求用户确认。

纳入清单至少满足一项：① 可直接替代 Ring 的产品或工具链；② 与当前类型/effect/ownership/resource/verification 设计有实质机制重叠；③ 对 agent 开发闭环、诊断、语义 inspection、发布工具链或执行速度构成可复核基准；④ 正在为活动 backlog 提供一手实现或实验参考。优先收录官方、canonical、仍可核验的仓库；同一项目默认只收一个主仓，只有独立的 agent/eval/runtime 子仓确实承载不同证据面时才例外。泛编译器资料、仅因 stars 高而相关性弱的项目、重复镜像和不可确认来源不进入核心雷达。

清单可以是本文全景矩阵的超集：被纳入只表示“值得观察”，不表示直接竞品、成熟、正确或已采用。移出清单通常只表示重复、长期失活或已不再影响当前决策；默认保留用户原有 Star。GitHub stars、更新时间与提交频率只能用于发现复查对象，任何进入本文的能力、版本、威胁或行动结论仍须回到官网、官方仓库、release notes、论文或会议页面核验。

### 12.2 复查节奏

常规保鲜期：**6 周**。下次定期复查建议不晚于 2026-10-09。

出现以下任一事件时提前复查：

- MoonBit 1.0/RC 发布，或 `moon prove` 去掉 experimental；
- Zero 发稳定 release、公开采用数据，或 graph-native 工作流发生重大改变；
- BAML 新 language channel 离开 canary/达到 1.0，旧 v0 文档与新语言产品面完成收口，或 Agent Tries BAML 发布可独立重放的协议、raw traces 与跨语言结论；
- Mojo 扩大 stable std/ABI 范围、其 async/interior-origin 等关键能力稳定，或公开可复现的 general-application / agent benchmark与采用数据；
- TypeScript 7.1 恢复 programmatic API，主流 framework 完成迁移；
- `ty` 离开 0.0.x 并成为 Python 主流默认 type/LSP 路径，或 Roc 达到 0.1 / Flux 形成稳定 release 与公开采用；
- Verus/AI proof 出现公开生产级采用或显著降低 proof/implementation ratio；
- Flix/Effekt/Unison 发布直接面向 coding agent 的 effect benchmark；
- Ring B-111 首轮数据或 B-001 design probe 产出，足以反向修改本文结论。

每轮复查必须同时更新日期、版本、保证层、行动映射；不再在顶部追加互相矛盾的“增量节”。

---

## 13. 主要一手来源

### 主流替代

- TypeScript：[Announcing TypeScript 7.0](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/)、[7.0.2 release](https://github.com/microsoft/typescript-go/releases/tag/typescript%2Fv7.0.2)
- OpenAI：[OpenAI to acquire Astral](https://openai.com/index/openai-to-acquire-astral/)
- Astral：[About Astral](https://astral.sh/about)、[`ty` documentation](https://docs.astral.sh/ty/)、[`ty` 0.0.75](https://github.com/astral-sh/ty/releases/tag/0.0.75)
- Rust：[Rust 1.98.0](https://blog.rust-lang.org/2026/08/20/Rust-1.98.0/)、[Polonius Alpha on nightly](https://blog.rust-lang.org/2026/08/04/enabling-polonius-alpha-on-nightly/)、[next trait solver on nightly](https://blog.rust-lang.org/2026/08/21/enabling-next-solver-on-nightly/)

### 直接与相邻语言

- MoonBit：[v0.10.9 release](https://www.moonbitlang.com/updates/2026/08/19/index)、[Formal Verification](https://docs.moonbitlang.com/en/latest/language/verification.html)
- Zero：[vercel-labs/zerolang](https://github.com/vercel-labs/zerolang)、[releases](https://github.com/vercel-labs/zerolang/releases)
- BAML：[BoundaryML/baml](https://github.com/BoundaryML/baml)、[BAML Language 0.17.0](https://github.com/BoundaryML/baml/releases/tag/baml-language-0.17.0)、[0.17.1 nightly](https://github.com/BoundaryML/baml/releases/tag/baml-language-0.17.1-nightly.20260826.a)、[0.17 changelog](https://github.com/BoundaryML/baml/blob/baml-language-0.17.0/baml_language/CHANGELOG.md)、[new language overview](https://boundaryml.com/)、[quickstart](https://boundaryml.com/quickstart)、[legacy changelog](https://docs.boundaryml.com/changelog/changelog)、[Agent Tries BAML](https://boundaryml.com/atb)
- Mojo：[release channels](https://mojolang.org/releases/)、[Mojo 1.0](https://mojolang.org/releases/v1.0.0/)、[compiler/toolchain open source](https://www.modular.com/blog/mojo-open-source)、[stability contract](https://mojolang.org/docs/api-docs/stability/)
- Roc：[repository](https://github.com/roc-lang/roc)、[platform model](https://www.roc-lang.org/docs/main/langref/platforms/)、[alpha4 ARC string model](https://www.roc-lang.org/builtins/alpha4/Str/)、[tutorial/AI docs](https://www.roc-lang.org/tutorial)
- Rue：[rue-lang.dev](https://rue-lang.dev/)、[rue-language/rue](https://github.com/rue-language/rue)
- Mog：[moglang.org](https://moglang.org/)、[voltropy/mog](https://github.com/voltropy/mog)

### Effect / semantic code

- Koka：[documentation](https://koka-lang.github.io/koka/doc/index.html)、[koka-lang/koka](https://github.com/koka-lang/koka)
- Flux：[repository](https://github.com/flux-rs/flux)、[Flux Book](https://flux-rs.github.io/flux/)
- Flix：[The Flix Effect System](https://doc.flix.dev/effect-system.html)、[releases](https://github.com/flix/flix/releases)、[Will LLMs Help or Hurt New Programming Languages?](https://blog.flix.dev/blog/will-llms-help-or-hurt-new-programming-languages/)
- Effekt：[documentation](https://effekt-lang.org/docs)、[v0.78.0](https://github.com/effekt-lang/effekt/releases/tag/v0.78.0)
- Unison：[website](https://www.unison-lang.org/)、[abilities](https://www.unison-lang.org/docs/fundamentals/abilities/)、[releases](https://github.com/unisonweb/unison/releases)

### Verus 与 AI proof

- Verus：[repository](https://github.com/verus-lang/verus)、[rolling releases](https://github.com/verus-lang/verus/releases)、[code architecture](https://github.com/verus-lang/verus/blob/main/source/CODE.md)
- Verus guide：[Trusted Computing Base](https://verus-lang.github.io/verus/guide/tcb.html)、[SMT failures](https://verus-lang.github.io/verus/guide/smt_failures.html)、[memory safety](https://verus-lang.github.io/verus/guide/memory-safety.html)
- Verus std：[raw pointer permissions](https://verus-lang.github.io/verus/verusdoc/vstd/raw_ptr/index.html)
- 论文：[Verus: Verifying Rust Programs using Linear Ghost Types (SOSP)](https://www.andrew.cmu.edu/user/bparno/papers/verus-sys.pdf)、[VerusBelt (PLDI 2026)](https://iris-project.org/pdfs/2026-pldi-verusbelt.pdf)
- 研究索引：[Verus publications and projects](https://verus-lang.github.io/verus/publications-and-projects/)
- AI proof：[CryptoProver](https://arxiv.org/abs/2608.00965)、[Vero paper](https://arxiv.org/abs/2608.13522)、[Vero repository](https://github.com/sunblaze-ucb/vero)
