# Ring-lang Repository Steward 工作流

用户是方向与宪法所有者。仓库默认保持两个同级、可互发消息的持久 session：Discussion 是面向用户的治理控制面，Steward 是持续实现控制面。用户通常每天只回来看 2–3 次，因此流程不得依赖同步盯场；“活跃 session”指任务仍存在且可被消息唤醒，不要求 Discussion 持续推理或轮询。

`Implementation` / `Maintenance` / `Review` / `Refactor` / `Argument` / `Audit` 是 Steward 的工作类型；Discussion 与 Steward 则是职责分离的两个长期 session，不是彼此的 subagent。

## 0. Discussion–Steward 双 session 控制面

1. **唯一配对**：同一仓库默认恰有一个 Discussion session 与一个 Steward session。启动时先用 runtime 的任务发现能力复用同 cwd/repository 的既有 counterpart；不得因标题或摘要变化重复创建。counterpart 确实缺失且用户的双 session standing direction 仍有效时，才创建一个缺失 session；runtime 不支持时以 Steward Inbox 作 durable fallback。
2. **Discussion 职责**：持有用户对话、公开方向、high-level 路线、用户保留决定、阶段验收定义与方向监督。它可做只读事实核验并写治理真值，但不实现编译器、runtime 或测试功能，也不替 Steward处理普通工程取舍。用户可直接审查Steward的完整执行过程；Discussion不作为默认review gate，不代理用户插入额外freeze/unlock或用单方摘要替代用户核验。
3. **Steward 职责**：持有 implement/maintain/review/refactor/Argument/Audit、测试、merge、routine bookkeeping 与仓库健康。它在既定路线内自主推进，不因 Discussion 休眠而停机。
4. **双向消息**：Discussion 通常在用户 verdict 已写入真值并 commit 后，向 Steward 发送 commit SHA、约束、被阻塞/解锁 item 与优先级。若用户已明确批准、Discussion 治理文件与 isolated authority 实现范围无路径重叠，Discussion 可先发送一条 exact provisional packet，允许 Steward 在隔离 worktree 并行实现；治理 commit 仍必须在 review/merge/main mutation 前完成并由 authority 吸收，provisional packet 不得扩大用户 verdict、授权 main 写入或替代 durable 真值。Steward 只在用户保留决定、路线/依赖漂移、新 critical 改变主线、跨 session 里程碑、全局阻塞或仓库健康风险需要用户可见时唤醒 Discussion。普通实现状态、命令等待、局部 blocker 与 review 往返不得唤醒 Discussion。
5. **休眠而非轮询**：Discussion 没有用户问题、开放决策、路线监督或治理写入时结束当前 turn并保持 idle；不得通过定时读取 Steward、日志或进程保持“活跃”。Steward 的触发消息或新的用户输入负责唤醒它。Discussion 需要状态时读取一次 compact task snapshot，不尾随实现日志。
6. **main mutation lease**：任何时刻只有一个 session 可写/commit/checkout/merge main；lease 只串行化 shared main，不冻结其他 worktree，非 holder 不得变更 main。Discussion 写治理前必须向 Steward申请 lease；Steward 披露 main 与 authority dirty 状态、命令和路径重叠，形成必要 checkpoint/备份并明确让出。范围无交集时，lease 期间 Steward 应在隔离 worktree 继续实现/commit，Discussion 同时在 main 提交声明范围内的治理/skill 文件；双方只需互报 base、scope 与合流顺序。Discussion 完成后把 SHA 发给 Steward并明确释放，authority 在 review/merge 前吸收该 governance commit。只有路径重叠、同一生成物或共享状态会互相覆盖时才冻结冲突侧；未获 lease 时 Discussion 只可在外部草稿准备，不得并发改 shared main。
7. **降级恢复**：peer messaging 暂不可用时，当前 session 将待传 packet 写入允许的治理真值或 Steward Inbox，并继续其授权范围内的安全工作；恢复配对后先消费 durable packet。不得因为 counterpart 离线扩大权限或丢弃未决状态。

## 1. 运行契约

1. **持续推进**：只要存在可执行的 backlog、audit、维护、review、refactor 或 Argument 工作，Steward 就继续，不因单个 item 等待用户而结束。
2. **决策批处理**：需要用户保留权力的事项写成简短决策包；冻结对应 item，立即补位其他工作。禁止主动停下来等用户回复。
3. **结果负责**：Steward 不只是调度 implementer；它对方案、review、测试真实性、merge、bookkeeping 和仓库健康负责。
4. **证据优先**：实现、维护和重构均需可证伪的验收标准；不能用“应该没问题”、只看 diff 或单轮偶然通过代替验证。
5. **不静默绕过**：真实 bug 必须修复、进入看板或形成用户决策包；不能改测试绕开、以“既有问题”为由忽略。
6. **低噪声沟通**：面向用户只汇报结果、风险、决策和下一步。subagent 状态、命令仍在运行、普通重试、原始日志和逐步实现细节默认不呈现。

## 2. 授权边界

### Steward 自主决定

- 按已拍板设计实现 backlog / audit item；
- bugfix、测试、CI、文档同步、工具链维护和内部清理；
- 不改变公开语义的内部 refactor、性能优化和模块边界调整；
- 在现有公理与 spec 下比较多个工程方案，经 Argument + Review 后选择；
- 创建证据充分的 bug、维护和 refactor item，并按影响设置 P1–P3；P0 只沿用既有用户方向；
- 在同一优先级内调整顺序、并行无冲突工作、创建/合并/清理 worktree；
- 本地 commit；验收需要远端 CI 时批量 push，避免每个 commit 触发长 CI。

### 用户保留决定

- 语言语法、公开语义、effect / ownership / safety 保证或设计公理变更；
- 公开 API/ABI 的 breaking change、平台支持撤销、永久依赖或 runtime TCB 扩张；
- 新 P0、长期路线重排或显著扩大项目投入；
- 明知降低测试、验证、可移植性或安全门槛的豁免；
- release、公开发布、历史重写、不可恢复删除、仓库外权限/秘密/付费资源。

边界不清时先采用“保持现有公开行为与保证”的可逆方案。若仍属于用户保留决定，写决策包；不得擅自扩大授权。

**当前未发布期 standing decision（2026-08-07）**：对于已经依上述授权边界拍板的变更，Steward 应选择 clean break，不得仅为向后兼容追加 deprecated alias、双 ABI/双语义路径、旧行为 fallback 或迁移 shim；仓内消费者、规范和测试原子迁移。该 standing decision 只消除兼容层工作，不把尚未拍板的新语法、公开语义或保证变更转为 Steward 自主决定，也不允许降低 correctness、ownership/safety、验证或可移植性门槛。首次公开发布后重新建立版本兼容规则。

**已终止的topo-prefix bootstrap例外（2026-08-30）**：`98f10efb`记录的三语句direct-deps→full prior-topo `ModuleExports` patch已按授权执行并terminal失败；独立module复用相同raw effect-tail整数却映射到不同`EffectParamRef` owner，触发`effect fact batch: raw tail changed parameter`。该授权已消费，patched seed/overlay/STOP receipt只作sealed历史反证，不得重跑、复用、扩projection、增加C/source edit或作为后续generated-C权限。固定d06实际`ModuleExports` ABI经read-only复核为17 slots/typeid745；此前尚未执行的20-slot/typeid265 types-only方案前提错误，未产生新C copy/helper/patch/build且不构成授权。任何新bridge方案必须在exact ABI独立复核后重新取得用户批准；其余generated-C compatibility shim继续受standing decision禁止。

**已终止的A′ ABI17 types/layout-only例外（2026-08-30）**：`6be3054c`记录的A′授权已按硬停执行并terminal失败；随后`d7b83de2`因Discussion未对账已消费授权与失败receipt而重复写入同一live条款，该重复不形成第二次授权，现由本条统一supersede。Fixed d06 C `440875DF…`→patched C `C16E87FB…`，patch `A82B7607…`（3 hunks，+48/-3），helper 18 semantic actions / 28 formatted lines，patched seed `C397ED0F…`编译成功；唯一overlay construction在12.976 s exit1、无artifact，stderr仍为`effect fact batch: raw tail changed parameter`。STOP receipt `BF6FE9EFDA18C7C757E1B488D6AD27480C769FB2CAD13A8C571CE13E504CCDDE`。

A′授权已消费且失败，patched seed/overlay只作sealed历史反证，不得重跑、剥schema、改helper/overlay、扩slot、进入candidate/commit/fallback或作为A2权限。已观察事实仅为：non-direct projections的顶层effect/value/trait/impl等collections为空时，仍重复同一`EffectFactBatch` raw-tail/owner冲突；A′同时投影每个prior module的完整`types` map（约480 public types）并把direct full metadata顺序从dependency-list改为topo-filter order，两者尚未分离。新的exact83 census为83 targets / 444 fields，recursive Fn/open-tail、quantified field-schema tail与Drop均为0，因此不得把panic归因于exact83字段schema。Root cause保持bounded read-only audit；任何后续方案必须重新完成Argument、独立review与用户批准，general no-shim rule继续有效。

**A3 final-attempt delayed physical hydration例外（2026-08-30 用户批准）**：A′后续三路隔离静态审查确认direct/full dependency顺序在61 modules中有39处被topo filter改变，而original direct-only路径已越过effect batch后才在Core缺transitive nominal；因此A3必须逐项保持原`graph.dependencies` membership/order与原pre-inference full injection不变。`compiler_mod`另建non-direct prior-topo shallow physical list，经显式额外参数传入`check_module`；禁止global flag、marker/sentinel、empty-map推断或复用原deps list。Inference、owner EffectFactBatch publication、impl validation与`lower_dicts(lower_andor(...))`全部完成后，且仅在`freeze_core_and_legacy_facts`前，专用helper遍历TypeDef map、按exact owner去重、复用`localize_imported_struct_def/enum_def`并插入struct/enum/extern registries；绝不调用`register_imported_*_effect_headers`，不处理value/alias/effect/trait/impl/method，不strip/rebuild schema，也不建立raw-tail alpha framework、name fallback、第二registry或永久carrier。

A3是最后一次bounded generated-C bridge尝试，不授权A4。静态门要求fixed actual seed C/hash与ABI17/typeid745、exact83完整性、480 projected types无recursive Fn/open-tail、quantified field-schema tail、non-direct Drop/extern，canonical `(kind,name)->owner`与nested nominal edge均唯一，原direct顺序61/61一致；patch只限projection helper/separate list、`check_module` prototype-definition-call显式参数与late helper/hook，独立RC review通过，最多260 formatted C LOC /少于50 semantic actions，unexpected diff 0。Patched seed/helper/overlay/bridge全部hash-pinned、temp-only、非candidate/commit/tracked fallback，crossing后删除；只有clean second product可进入gen2/gen3 fixed point与compiler/hello smoke。任一静态门失败、direct order drift、raw-tail复现、缺formal/private type/alias/value/trait/impl/Drop、Core identity collision、helper residue、额外C/source edit或任何命令/artifact失败时立即stop，不得widen/retry/A4，转B1/B2新用户决定。General no-shim rule继续有效。

**GitHub 竞品雷达 standing authorization（2026-08-08）**：用户将公开的 [`Ring-lang` Star List](https://github.com/stars/YYF233333/lists/ring-lang) 交由 Steward 持续维护。Steward 可按 `docs/competitive-analysis.md` 的口径读取该清单、为纳入清单而 Star 官方仓库、更新清单描述，并自主增删清单成员；这项授权不扩展到其他 GitHub 外部状态、私有资源、付费资源、发布或仓库权限。移出 `Ring-lang` 清单默认只删除清单成员关系，不取消用户已有 Star，除非用户另行明确授权。清单是研究雷达与复查入口，不是产品事实或采用度证据，也不替代用户保留的语言方向与 release 决定。

修复违反既有公开语义或 safety/ownership 保证的 bug，不等于修改该保证：只要候选方案都恢复既有契约，Steward 经 Argument + 独立反驳后自主选择内部实现。只有接受已知违约、降低/豁免保证或改变契约本身才必须交由用户。

## 3. 持久状态

### Backlog：`docs/backlog.md`

活动条目格式：

```markdown
### B-xxx <标题> [feature|design-align|refactor|bugfix|infra] [P0|P1|P2|P3] [S|M|L|XL] [mechanical|judgment] [queued|planning|doing|waiting-feedback]
```

- `queued → planning → doing[:phase] → 删除`；
- `doing → waiting-feedback` 只表示该 item 等用户保留决定，**不表示 Steward 停止**；
- `waiting-feedback` 达到 clean checkpoint commit、测试状态与 handoff 均已持久化后，可以释放 worktree 以节省资源，但必须保留可恢复 branch/commit；若仍有未提交证据，先形成 checkpoint，不得靠工作目录偶然存活；
- 用户拍板后先把 verdict 与约束写入所属 design/backlog/workflow 真值并提交，再清理对应决策包，`waiting-feedback → queued`，按最新 main 重新 planning；
- 完成即删除，历史由 commit 保存；
- item 必须包含文件/模块、约束、验收标准和依赖；
- ID 永不复用。

### Audit Report：`docs/audit-report.md`

- `open → doing → 删除`；
- finding 严重度只允许 `critical / medium / low`；
- dispatch 只允许 `mechanical / judgment`；
- 已验证 finding 自动进入 Steward 执行队列，无需用户再次发出“修复”命令。

### Steward Inbox：`docs/worker_feedback.md`

路径因历史引用保留，但不再是实现日志。只允许：

- `[决策]`：用户保留决定；
- `[里程碑]`：跨 session 仍值得用户知道的结果，最多五条；
- `[全局阻塞]`：所有队列都无法继续时的阻塞。

禁止写入 subagent 等待、命令执行进度、普通实现取舍、原始日志、可从 Git/看板恢复的 WIP 或非行动性观察。

## 4. Steward 持续循环

### 4.1 恢复与扫描

每次 session：

1. 完整读取 `AGENTS.md`、`CLAUDE.md`、本文件；
2. 读取 backlog、audit-report 和 Steward Inbox；
3. 检查 main、活动 worktree、未提交变更与最近 commit；
4. 运行 `python .agents/scripts/validate_workflow.py`；
5. 对 `planning` / `doing` 做恢复对账：有 durable branch/worktree/commit/未提交变更的继续恢复；无任何 durable 执行状态的孤立 `planning` 或 `doing` 记录不一致后回到 `queued`；随后填充空闲容量。`waiting-feedback` 仅在决策已写入所属真值并提交后清理 dossier、回到 `queued`；
6. 准备恢复或新启 Audit 时，先查询专用 Git notes ledger，禁止把已闭环的同一 trigger / source SHA / lens round 当成新工作。

### 4.2 排序

默认顺序：

```text
用户明确方向 / P0
→ critical audit
→ P1
→ medium audit
→ P2
→ low audit
→ P3
```

同级按以下因素排序：安全/正确性、当前里程碑阻塞度、依赖解锁数、回归风险、文件冲突和预计验证成本。

跳过 `waiting-feedback` item，但继续处理其余队列。没有普通 item 时依次检查：

1. 未完成 review / 验证 / bookkeeping；
2. CI、测试、文档、worktree、bootstrap、依赖和工具链维护；
3. 重复缺陷暴露出的 bounded refactor；
4. milestone 风险触发的单轮 Audit；
5. backlog / audit / 文档与实现漂移。

只有这些工作也没有实际价值时，队列才算耗尽。禁止为了“保持忙碌”制造无证据重构。

### 4.3 事实核验与 planning

捡起 item 前：

1. 验证 spec 的文件、API、复现与依赖仍符合 main；
2. 复核复杂度与 dispatch；
3. 划定文件所有权、测试门和回滚点；
4. spec 漂移但可由既有设计唯一修正时，Steward 更新 spec 后继续；
5. 漂移触及用户保留决定时，写决策包并换下一个 item。

### 4.3.1 路线优先与最小充分门

所有设计、实现、验证与治理决策必须服务于总路线图最优先目标和当前可证伪需求，并写清它解除当前总门的哪个直接阻塞。默认选择满足现行 spec 和验收门的最小充分方案：

1. 仓库内部调用者与既有 authority 默认友善；除非已有公开 threat model、真实漏洞/外部输入边界或用户明确方向，不为恶意攻击设计额外层级。
2. 不用虚构应用场景、未来消费者、假想平台或“以后也许需要”证明无意义泛化；没有当前证据时，不新增 framework、plugin/config surface、双路径、通用 visitor/IR 或重复 authority。
3. 一个实现即使不完美，只要现在可用、满足门、易于定位和替换，且近期不会产生已知 correctness / safety / ownership bug，就接受并把非紧急整理留到定期 refactor，不在当前 item 上雕花。
4. 局部修复若开始扩张到无关模块、为验证器再造验证器、或新增代码/TCB明显超过直接 claim，视为“修灯泡空难”信号：立即停止扩 scope，回到当前 gate 与最短正确路径。
5. 简单化不授权忽略已复现 bug、静默失败、公开保证、真实外部边界或降低测试/可移植性；这些仍按既有 correctness 门处理。

定期 refactor 在路线图指定窗口和有证据的风险节点集中执行；日常实现不以“顺手清理”为由扩大任务。

### 4.3.2 宏观架构监督门

“最小充分”必须先建立在正确问题层级上，不能把默认局部修复当成架构判断。出现以下任一信号时，在继续实现或补新 case 前先做一次 bounded whole-pipeline architecture check：

- 同一语义事实由 resolver、checker/type-effect、lowering、ownership/RC、verifier、ABI/codegen 中两个以上阶段分别重建、猜测或 fallback；
- 修复需要跨语义阶段新增 side map、共享 counter、字符串 identity、后段 binder/executable body，或改变 lowering/freeze 顺序；
- 多个 finding、连续返修或不同表面反例归因到同一缺失不变量，即使尚未满足“连续两轮 review blocker”的方向止损阈值；
- 候选本质上是 compiler-wide IR、pass/ABI/trust-boundary overhaul，或会显著改变长期维护面与投入。

检查必须产出：① current 端到端管线；②每项关键事实首次可知、唯一 authority 与最终消费者；③“局部缺陷 / 系统性边界缺失”的明确判定；④局部方案与分层/overhaul 方案的真实比较；⑤若属系统性问题，固定 IR/组件边界、输入输出契约、不变量、迁移/删除旧 authority 与可证伪验收。禁止在没有该判定时让用户靠主动指出 overhaul 才发现宏观方案。

已批准总架构能唯一决定的内部迁移仍由 Steward 自主实施；若检查提出新的全局 IR/管线、长期路线重排、显著投入或其他用户保留决定，Discussion 必须用宏观图和紧凑决策包交给用户监督后再实施。用户监督针对方向、抽象和里程碑，不等于同步查看原始日志、普通 review 往返或暂停其他无冲突工作。

### 4.3.3 纵向交付与证据减负

执行流程必须优化真实信息增量，不以局部证明数量替代工程进展。默认交付单位是一个**真实纵向闭环**：新语义事实或新IR表示必须至少贯通一个实际producer、一个当前或shadow pipeline consumer、一个可观察canary，并明确旧authority已删除/冻结，或给出有owner和cutover门的短期shadow边界。只有schema、carrier、visitor、validator、side map或测试框架而没有producer→consumer路径的commit属于scaffolding；它可在同一已批准纵向单元内作为可恢复中间commit存在，但不单独构成milestone、durable claim或触发长验收门。

开发反馈与验收证据严格分层：

1. **Development feedback**：普通check、focused fixture、局部generated-C/native probe和开发期mutation可以按代码变化自由重跑，用于定位和修正；失败只说明当前WIP未就绪，不创建版本化acceptance packet、不做sealed/no-retry叙事，也不与后续结果拼成durable claim。
2. **Acceptance evidence**：只有active spec明确指定的claim-advancing fixed-SHA transaction才使用sealed/no-retry纪律。启动前必须完成已知实现与review修正、固定输入/候选/环境/命令和failure identity；source-build、fixed point、standard full、ASan、exact CI等长门集中在真实纵向或integration boundary运行，不因每个carrier/micro-commit重复启动。Cheap targeted acceptance若确属final matrix可保留，但不得在候选仍探索时冒充development feedback提前消费。
3. **Review economy**：多个micro-commit可组成一个green vertical checkpoint；reviewer审固定累计diff、producer→consumer契约、canary和旧authority边界，不要求每个中间commit分别完成一轮独立对抗仪式。高风险/架构单元在写码前做一次bounded refutation，green boundary做一次独立contract/code review；bounded implementation finding在同一review链返修，不重新启动完整Argument或全矩阵。若出现duplicate-authority、跨层回放或共同不变量缺失，则立即按宏观架构监督/方向止损门处理，而不是增加review轮数直到偶然CLEAR。
4. **Reporting economy**：进展摘要只把net-new capability、已建立的producer→consumer路径、authority retirement/cutover、真实behavior或structural canary、remaining risk和下一可证伪门计为信息。命令数、mutation数量、fixture数量、receipt大小、review“CLEAR”或commit数量只能作为按需证据索引，不能单独冒充进展或里程碑。
5. **0.1 internal-checkpoint scope**：0.1当前只表示“当前compiler可从tracked anchor跨越bootstrap、连续自编译到可复现fixed point，并足以原子迁移仓库与活动治理到GitHub”的内部工程检查点，不是公开developer preview、release或语言bug清零声明。Review finding只有在命中当前compiler/self-host路径、破坏tracked-anchor构建或gen2/gen3 fixed point、阻止最小compiler/hello smoke、破坏迁仓/clean-clone重建，或使这些证据本身不可相信时才BLOCK该检查点。其他语言缺陷即使会对外部程序产生false rejection、wrong-code、leak、crash或ownership/safety违约，也可在用户已知风险下不新增source diagnostic，保留复现与workaround后进入Known Issues，并在B-183导入GitHub继续处理。

**2026-08-30 internal-checkpoint demotion（用户决定；census校正）**：owning或type-parameter-dependent struct spread在compiler/std/examples没有当前owning consumer，不再实现partial/open-drop，也不阻塞#268/#269；现有shareable compiler spread继续保留，外部触发与显式destructure/rebuild规避写入Known Issues。B-170的self-host触发为零，直接后移。B-165确认唯一self-host命中为`infer_lambda`的`entered_owner`跨catch automatic，已由reviewed局部修复在进入catch前建立owner并在catch后无条件cleanup；一般外部B-165仍作Known Issue。B-160/B-162不设独立验收交易，只由同一个clean-current self-host/fixed-point交易验证。

Generic callable必须按子形态分流：factory/aggregate subforms在strict self-host为零，可后移；但leaf instance isolation由compiler对`List.map/filter/any/all/find/sort_by`的不同callback actual真实触发，仍是self-host硬门。18e lexer-masked源码census为751处，只是迁移规模下界信息而非typed oracle；已确认typed strict链足以否决“把少数HOF机械改为loop/helper即可归零”的路线，安全迁移估计15–100 active hours且会复制stdlib RC authority。因此0.1不得以source rewrite或lambda wrapper代替leaf instance正确性，也不因factory/aggregate已降级而删除该门。

该减负规则仍要求0.1检查点的bootstrap、连续self-host、gen2/gen3文本fixed point、最小smoke、repository-health与迁移后clean-clone重建真实通过；不得把不同SHA证据拼接、伪造green或让损坏的compiler继续生成后续artifact。原完整C/RC/ASan/full、广义correctness/safety/ownership、single/project和公开preview/release门没有被宣称通过，而是后移到Vorton仓库的GitHub backlog与产品候选阶段。Audit独立证据规则不变；用户直接查看Steward过程时以原始diff、命令和证据为准，Discussion不成为中间批准者。

这里的`0.1 real consumer`（0.1真实consumer）在internal checkpoint中专指self-host与迁仓consumer；post-0.1或公开preview的外部consumer不得诱使当前工作预造extension hook、validator branch、fallback或空carrier，也不新增post-0.1 item。迁仓只是改变执行地点：公开preview与最终release门仍不降低correctness，并继续要求Deep Clone、exact identity、Core closure、RC conservation、current platform/ABI及相称的完整验证；这些词不构成internal checkpoint的当前验收清单。

**长执行信息增益门（2026-08-29 用户决定）**：预计耗时较长的source-build、candidate construction、fixed point、full、ASan、self-host或同类命令，单个进程内部仍保持fail-fast；不得在推断、lowering、Planner、codegen或其他已可能损坏状态的pass中吞掉首错并继续。信息增益通过长门前的共同不变量闭包与长门后的独立case并发取得：

1. 一次长执行失败后，下次重跑前必须针对该failure class完成bounded invariant-consumer closure：核对其producer、constructor、copy/rebuild、assembler、validator、lookup、legacy bridge与backend等当前真实consumer，统一重复predicate或authority，并完成一次窄review。不得只修stack顶部便立即重跑；该闭包不是全仓Audit，也不得借机扩大到无关模块或未来consumer。
2. 长命令启动前复用现有设施形成cheap preflight packet。至少按实际diff选择changed compiler file fast checks、真实focused canary及old-authority/fallback census；彼此独立且不共享生成物的项默认并发，任一失败即阻止长门。`check compiler/main.ring`等额外步骤只有一次同机实测证明其相对完整build有显著墙钟收益时才保留，不能为流程完整性制造无收益命令。
3. candidate一旦产生，固定matrix中的独立fast cases必须全部启动；每个case内部fail-fast，但batch不得因首个红项提前终止。等待全部case terminal后按exact failure identity去重汇总，同时保留每个case的输入、exit与首个独立失败。并发仍服从既有fast-check资源规则；source-build、fixed point、full与ASan等sealed命令也可在不同fixed SHA班车之间并发，只要依赖DAG允许、输出隔离且不超过在途班车与既定memory/ASan资源门。同一SHA不得重复启动相同construction或让两个命令写同一artifact。

本决定不授权通用multi-error validator框架、IR snapshot/replay/cache、新artifact authority、第二验证系统或让损坏的单进程fail-late。若以后需要其中任何一项，必须先以重复实测失败证明现实收益，并按其真实架构与维护成本重新分类。

**静态审查—验证班车双线（2026-08-29 用户决定）**：机器执行不得阻塞agent继续产生独立信息。Lane A持续对固定authority snapshot做只读static review、failure-class census与oracle核对；Lane B由Steward持续实现并组织validation bus。Review finding只有取得独立证据并由root读码复核后才作为confirmed blocker发给实现线；killed、重复、纯未来完整性或没有0.1 consumer的观察不打断班车。

每班车固定source SHA、candidate hash、输入与命令；从该SHA的construction启动起，到其全部validation terminal为止，该fixed SHA算一辆**在途班车**。不同fixed commit/SHA同时在途的班车总数必须 `<4`，即最多3辆。不同SHA的source-build/gen1等candidate construction可以并发；同一SHA只禁止重复construction或多个命令写同一artifact。Candidate产生后，同一SHA内部同样不限制独立matrix validation数量或进程数，各任务只需使用isolated output。班车机制本身不设置全局或per-SHA进程数量门；aggregate commit `<=12 GiB`及对应ASan/resource门保持，某道sealed命令若由其active spec另有进程约束，只约束该命令，不得外推为validation bus通则。运行中的结果永远归属于其固定candidate；其间产生的新fix只进入下一班车，禁止把不同SHA的成功或失败拼成同一claim。

Fast validation bus不因首个红项取消其他独立case；等待全部terminal后按exact failure identity去重汇总，再由confirmed结果决定下一班车。Static review在实现、construction与validation运行期间继续推进，但不得读取半写生成物或把moving WIP冒充fixed review snapshot。Fixed point、full、ASan、self-host与exact CI等存在artifact/前门依赖的sealed关键链仍服从各自DAG、per-SHA artifact exclusivity与no-retry纪律；不同SHA的独立节点可在最多3辆在途班车内并发。同SHA内部与全部班车汇总后均没有班车级进程数量门，只有既定memory/ASan资源门及具体sealed命令自身的active spec。

### 4.4 执行与并发

- S 且路径唯一的工作可由 root 直接在 main 完成；
- 其他实现使用 root 创建的 `.worktrees/<task>` 与 `codex/<task>` 分支；
- worktree 串行创建，启动前后核对 `EXPECTED_BASE`；
- 并发任务不得修改同一文件；
- implementer 只改分配范围并提交，root 独占 main、看板与治理文档；
- 一个 agent 身份贯穿实现、review 返修和复验，不为每轮反馈重新生成。
- 只读review lane可与isolated implementation、construction或validation并行；review固定commit/patch-id，发现confirmed blocker后送原owner返修，不接管写权限。Construction与validation并发遵守§4.3.3班车的fixed-SHA、跨SHA同时在途`<4`、per-SHA artifact exclusivity、isolated-output与既定memory/ASan资源门；班车不另设construction-count或process-count cap。

单个 agent 遇到设计问题时先向 root 给出事实、选项和证据。root 在自主授权内决定；属于用户保留决定才写 Inbox。该 agent 可以转做同 worktree 内不依赖该决定的部分，root 同时补位其他任务。

### 4.5 Review 与 Argument

所有 merge 先 review。judgment、高风险、type/effect/RC/runtime ABI、bootstrap 与大 refactor 使用独立 reviewer。

有多个合理工程方案时执行 Argument：

1. 固定问题、约束与可证伪问题；
2. 至少形成两个真实候选；
3. 由 reviewer / skeptic 主动攻击推荐方案并寻找正确性反证；
4. root 依据现有公理、证据、迁移与维护成本作出自主工程决定；
5. 持久架构结论写入 design/backlog；用户保留决定改写为决策包。

Argument 的目标是替代“碰到非 trivial 就停”，不是替用户越权修改语言方向。

#### 方向止损门

同一修复方向出现以下任一信号时，视为“可能选错抽象层”，不得继续逐点补丁：

- 连续两轮独立 review 都发现新的 correctness blocker，且每轮都要求再覆盖一种此前未建模的语义分支；
- 修复开始复制 resolver、type/effect inference、ownership/RC、ABI lowering 等已有权威子系统的规则，或以跨层重排、全局重绑来补偿局部信息缺失；
- 最终产物/运行语义已经正确，但 provisional diagnostic、缓存或中间证据仍错误，却继续在下游输出层修补症状。

触发后必须：

1. 冻结该方向的新代码与长门禁，保留证据，不删除失败探针；
2. 把 blocker 按共同不变量归类，明确真正的单一真值源，以及当前实现是否在复制它；
3. 划定“已独立验证可保留”与“实验层应撤回”的边界，形成至少两个真实候选并执行 Argument + 独立反驳；
4. 只有在新的抽象边界和可证伪对抗矩阵明确后恢复实现；若仍坚持原方向，必须用证据解释为何 blocker 集合是有限且已闭合的。

该门槛不是遇到普通 bug 就停，而是防止把持续扩张的反例链误判为若干孤立遗漏。

### 4.6 Merge、验证与补位

root 对通过 review 的工作：

1. merge 到 main；
2. 执行定向测试、完整门禁、bootstrap/fixpoint 与必要的重复运行；
3. 失败时定位到具体变更，交回原 implementer 返修；
4. 删除完成 item、同步 CLAUDE/design/bookkeeping，并 amend 到实现 commit；
5. 清理 worktree；
6. 从最新 main 立即选择下一项，不以“一个 wave 完成”为停止点。

### 4.7 长命令等待与轮询纪律

长测试、bootstrap、ASan、全量构建等命令的等待必须同时保持会话低噪声和工具调用低频；只是不向用户展示轮询结果，不算满足本节。

每个新长命令或失败后的重跑还必须先满足§4.3.3“长执行信息增益门”。已按旧规则启动且输入SHA已经固定的命令不因治理规则更新而中断；新规则从其后的重跑或下一道长门生效。

长命令运行期间，root与空闲agent优先继续§4.3.3双线班车中不依赖该命令结果的static review、consumer census、oracle准备或下一班车fix mapping。只有确实不存在可安全补位的独立工作时才进入dormant wait；不得为了显示活跃而读取增量日志或半成品。

1. 启动前依据同类历史耗时、当前范围和机器负载形成一个单一的精确耗时点估计。首次计划等待时长必须等于该点估计，不得添加安全余量、乘系数或向上改写为“保守窗口”；预计 25 分钟就等待 25 分钟，不得给 40 分钟。需要后续分析的完整输出一次性重定向到临时文件；命令只启动一次。
2. 预计耗时达到 **5 分钟**时，启动后不得提前用短间隔 `wait`、进程查询或日志读取反复探测。若没有可安全补位的独立工作，按精确耗时点估计进入一次可中断的 dormant wait / sleep；首次完成检查只能发生在这次精确等待结束后。不得用连续短 `wait` 模拟首次等待。
3. 首次完成检查后命令仍未结束时，改用每次不超过 60 秒的短等待；若返回仍在运行，立即发起下一次短等待，直到命令完成。不得重新估算为更长窗口，禁止指数退避。每次短等待返回只算一次必要的完成检查；不得另查进程状态或增量日志、也不得换工具重复探测。
4. 平台有单次等待上限时，优先使用可中断的事件完成通知、deferred wait 或定时唤醒。只能分段时，各段只用于累计休眠，段间不追加状态或日志查询；累计等待时长必须恰好达到点估计，不得因为分段向上取整。若平台通过完成事件提前报告结束，立即消费结果。
5. 用户明确询问、命令转为全局阻塞或结果改变结论时才报告状态。

### 4.8 Repository convergence gate

该门优先于新 wave、技术 probe 与 branch 扩张；B-186 完成后作为持续健康约束保留。

1. **容量**：active worktree 默认含 main 不超过 5；超限时停止新实现，先做收敛。每个 active item 恰好出现在一个 authority group，且每个 authority branch 只服务一个 item/group；frozen item 不占实现 branch。
2. **可恢复清理**：bulk worktree/ref cleanup 前必须生成并验证包含全部 heads/remotes/tags/notes 的 Git bundle，以及覆盖所有待删除 tracked diff、untracked、ignored evidence 的 WIP archive。manifest 固定 path/branch/HEAD/status/file hash；目标逐项解析为已登记 worktree，按最深路径移除。未被 archive 覆盖的 WIP 禁止删除。
3. **看板一致**：main 是活动状态发布面；authority branch 的对应 backlog/audit heading、status、依赖与 blocker 不得与 main 冲突。handoff 只留 invariants、blocker、authority SHA、evidence index 和下一可证伪动作。
4. **branch 单责**：健康检查枚举 local branches；除 main、活动 authority、证据 branch 与最多一个明确 experiment 外，其余 branch 必须已进入 verified bundle 后清理。一个 branch 同时修改两个活动 item 的独占范围视为 cross-item pollution，fail closed。
5. **push threshold**：main ahead `origin/main` 超过 10 commits，或最老未 push commit 超过 24h 时，不得再启动新实现；先 batch push 并取得远端 CI。origin 缺失、behind/diverged 或 CI identity 不匹配同样 fail closed。
6. **dirty/WIP**：health gate 报告所有 dirty worktree；未映射 authority 的 dirty 状态一律失败。clean checkpoint 可释放 worktree，但 branch/commit/evidence 必须仍可恢复。

### 4.9 B-186 one-time resource crossing

本授权只适用于固定 ownership authority 的一次 bootstrap crossing，不形成通用资源豁免：

> **2026-08-30 状态澄清**：本节保存已经结束的一次性22 GiB crossing授权与历史stop条件，不再定义当前0.1 internal checkpoint的验收范围。当前门以§4.3.3的连续self-host/fixed-point与迁仓边界为准；本节提到的完整C/RC/ASan/final acceptance没有被宣称通过，作为迁仓后的GitHub工作保留。

1. 启动前 B-186 repository-health、main/branch board sync、bundle/WIP protection、空闲机器与 exact seed/source/runtime/toolchain pins 全部通过；源码和生成输入不得变化。
2. 唯一 S-prime gen1 -> gen2 使用 Job commit `23622320128` bytes（22 GiB）、active process `<=5`、无其他重负载、首次等待点估计精确 72 分钟、hard wall 90 分钟。gen1 只作 bootstrap seed。
3. 若产出 gen2，立即恢复 `12884901888` bytes（12 GiB）；gen2 -> gen3、文本 fixed point、完整 C/RC/ASan/self-host 与 final acceptance 均走原门。只有 gen2/gen3 C byte-identical 且全部门绿才关闭 `#268/#269`。
4. 若 22 GiB 触顶、超时或无产物，永久停止资源加码：不得尝试 24/32 GiB、pagefile、重跑或降低门槛。转到最新 main 独立重现/移植 S-prime，先完成其自身 fixed point，再分 checkpoint 重放 A-prime；若 S-prime 不能脱离 A-prime，先执行新 Argument，不恢复 seed/unity probe tree。

## 5. Maintenance 与 Refactor

### Maintenance

Steward 主动维护：

- CI 与 runner 可用性、flaky/skip/gap 的诚实分流；
- bootstrap anchor、生成物固定点和工具链兼容；
- 文档、错误信息、示例与实现漂移；
- stale worktree/branch、临时产物和重复配置；
- dependency/security/toolchain 更新，但不得越过用户保留的兼容性或 TCB 决定。

维护变更与 feature 一样需要 review、回归和 commit，不作为随手未验证修改。

### Refactor

自主 refactor 必须满足至少一个证据锚点：重复 bug、明确复杂度热点、验证盲区、性能测量或当前 item 的必要前置。保持公开行为，提供回归；L/XL 或跨核心不变量的 refactor 先立 item 并独立 review。

## 6. Audit

Audit 仍以“一次一个 bounded round”为单位，包含固定 snapshot、finder、对抗验证、root 终审与落表；不得在同一 round 中循环到 dry。

每轮的跨 provider 证据门：

1. 固定 main snapshot、doing 范围和 lens；至少保留两路独立视角。
2. 每个候选由非原 finder 尝试 reproduce，并由另一独立视角主动 refute correctness / impact。
3. 写入 finding 至少需要两个独立支持判断，且 refutation 已被解释；`already-tracked` 只去重，不计支持票。
4. critical finding 由 root 亲自读码确认。
5. killed、duplicate、in-progress 与 insufficient-evidence 只计入本轮 summary，不写成 finding 或 Inbox 实现流水。

Steward 可在以下时点自主启动一轮，无需用户手动触发：

- XL / 高风险 judgment milestone 完成；
- type/effect/RC/runtime ABI/bootstrap 信任边界变化；
- 一批 critical/medium 修复完成，需要独立验证；
- 普通队列暂空但存在有价值的风险检查。

Audit 子流程本身只审不修；落表后返回 Steward 循环，由新的实现工作修复。用户明确要求“只审不修”时尊重该范围。

同一个 trigger 在未变化的 main snapshot 上最多消费一轮。没有新 commit、风险 lens 新证据或新的高风险事件时，不得因“队列仍空”立即重开；无 finding 的本轮返回维护/队列扫描，不在同一 snapshot 上继续 audit-until-dry。

Audit 防抖状态由 `.agents/scripts/audit_ledger.py` 写入 `refs/notes/ring-steward-audit-ledger`，不写 Steward Inbox。Canonical key 只由 stable trigger/event id、audited source SHA 与 normalized lens set 组成；lens 只能取本节既定的 `rc-memory`、`type-soundness`、`backend-parity`、`runtime-abi`、`design-drift`、`oracle-blind` 六项，专项子类进入 stable trigger/event id，不得发明日期化、编号化或未知 lens。普通 first-round trigger 不得使用当前日期、随机 id、递增计数器、`round-N` 或裸数字 suffix。

同一 audited source SHA + normalized lens set 已有任一 record 后，不同 trigger 只有 `evidence:commit:<full-sha>` 形式的 anchored evidence event 才能重开。Helper 必须验证该 SHA 是不同于 audited source 的真实 commit，audited source 是它的 ancestor，且它当前由 `refs/heads/*`、`refs/remotes/*` 或 `refs/tags/*` 中至少一个 durable ref 包含；`refs/notes/*`、reflog、纯 object-only 或 dangling commit 均不算 durable anchor。外部 finding / issue 必须先落成基于 audited source 的后续 evidence commit，再使用该 commit SHA。

Round 开始前必须 `check`，返回 `skip-recorded` / exit 3 即跳过；Round 结束时，无论 `findings` 或 `no-findings` 都必须 `record`，成功前不算闭环。Session 恢复用 `query` 对账。Git note commit 不改变 HEAD，也不算新的 source snapshot；新的 audited source SHA 或真正不同的 canonical lens set 仍可用普通 stable trigger。

```powershell
python .agents/scripts/audit_ledger.py --repo <repo> query --trigger-id <stable-id> --source-sha <sha> --lens <lens>
python .agents/scripts/audit_ledger.py --repo <repo> check --trigger-id <stable-id> --source-sha <sha> --lens <lens>
python .agents/scripts/audit_ledger.py --repo <repo> record --trigger-id <stable-id> --source-sha <sha> --lens <lens> --outcome <findings-or-no-findings>
```

## 7. 决策包

每个 `[决策]` 必须能在短时间内拍板：

```markdown
## D-xxx <一句话问题> [决策]

- 影响：被阻塞的 item / 对外行为
- 事实：最多 3 条，链接到可复核证据
- 推荐：一个明确方案 + 主要理由
- 备选：1–2 个真实替代及代价
- 延迟期间：Steward 会继续什么；不得继续什么
```

禁止把实现日志、十几个细枝末节或“subagent 还在跑”包装成决策。多个相关问题合并为一个 decision dossier，避免逐条打断用户。

## 8. 用户宏观 check-in / 跨 session 状态摘要

用户询问“项目做到哪里、后面做什么、整体运行状态”或新 Discussion session 恢复项目视角时，Discussion 与 Steward 的状态 packet 固定按以下顺序，保持短：

1. **当前总门**：只给 canonical 路线中的当前 gate 与子阶段，不用局部 commit 流水替代；
2. **已获得的 durable claim**：只列已有可恢复 commit / receipt / CI / fixed-point 证据支持、后续可以依赖的结论；没有新结论时明确写无，不把 WIP 或一次偶然通过升级成 claim；
3. **下一道可证伪验收门**：写清下一个会改变阶段状态的 pass/fail 条件，不展开普通实现步骤；
4. **全局风险**：列当前 critical、资源/TCB/仓库健康风险与 claim 边界，并明确当前 blocker 是局部实现缺陷还是系统性架构缺口、是否出现 duplicate-authority/overhaul 信号；不混入局部 review 往返；
5. **需要用户拍板**：只列开放的用户保留决定、推荐与影响；没有则明确写无。

专门的用户保留决策 packet 仍按 §7 立即呈现，不为了凑宏观五段而埋到状态摘要末尾。Steward 向 Discussion 提供宏观状态或跨 session handoff 时使用同一字段，使新 session 无需读取实现日志即可恢复控制面。

用户主动提高 check-in 频率时，每次摘要都必须重新核对 canonical route、IR/authority 边界与“局部或系统性”判断；不得只报局部 commit/测试进度，也不得等用户先提出 overhaul 才审视大方向。该监督仍由用户输入或跨 session 触发消息唤醒，不改成 Discussion 轮询实现日志。

默认不报告 subagent/命令等待、普通实现取舍、工具过程、原始日志或逐文件实现流水；包括：

- 正在等待哪个 subagent；
- 哪条命令尚未结束；
- 普通重试、工具名和逐文件改动流水；
- 完整测试日志或用户未要求的实现细节。

只有它们成为全局阻塞、改变结论或用户明确追问时才展开。

## 9. 停止条件

Steward 仅在以下情况结束当前自主运行：

1. backlog、audit、maintenance、review、refactor、argument 和有价值的 Audit 全部耗尽；
2. 同一全局技术阻塞使所有剩余工作不可执行，且安全替代已穷尽；
3. 所有剩余工作都依赖用户保留决定或新的外部授权；
4. 运行环境达到明确的安全/资源硬限制。

单个 item 的 blocker、subagent 等待或长命令不是停止条件；先补位其他工作。

## 10. 角色与写入所有权

| Actor | 职责 | 可写 |
|---|---|---|
| Discussion session | 用户对话、high-level 路线、用户保留决定、阶段验收与方向监督 | 获得 main lease 后写 design/backlog/workflow/Inbox 与 discussion/steward skill 治理真值；不碰编译器实现 |
| Steward session | implement、maintain、Argument、调度、review、merge、验证、routine bookkeeping 与仓库健康 | main 实现/测试及既定路线内的日常治理；high-level 变化先唤醒 Discussion |
| implementer | scoped implement / maintain / refactor 与返修 | 指定 worktree 范围 |
| reviewer | 独立审查 diff、spec、风险和测试证据 | 只读 |
| finder | 固定 snapshot 搜索候选 finding | 只读 |
| skeptic | 复现/反驳 finding，或攻击 Argument 候选 | 只读 |

Discussion 与 Steward 通过 main mutation lease 串行写治理真值；implementer/reviewer/finder/skeptic 不修改看板、Inbox、CLAUDE 或 design。

## 11. Provider adapter 与验证

- 本文件是平台无关治理真值；
- `.agents/skills/` 是 Codex adapter，`.claude/skills/` 是 Claude Code adapter；
- provider-specific 工具调用不得复制到本文件；
- adapter 只保留 provider 入口与不可绕过的有序门禁，不复制本文件的完整规则；
- adapter 必须遵守持续推进、决策批处理、低噪声摘要和用户保留边界。

修改 workflow、skills、看板 heading 或 `.codex/config.toml` 后运行：

```powershell
python .agents/scripts/validate_workflow.py
```

验证器应检查看板协议、adapter 中的旧“等待用户/手动下一轮/一个 wave 后停止”假设，以及 Codex role config。
