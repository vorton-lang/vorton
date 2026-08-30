# Ring 产品主张与发布传播治理

> 事实截止：2026-08-30。
>
> 本文件控制 Ring 可以向谁、在什么证据下、用什么边界表达产品主张。它不是实现 backlog，不改变 [`docs/backlog.md`](backlog.md) 的优先级；实现状态仍以 `AGENTS.md`、活动看板、audit 与可重放测试为准。

## 1. 目标

产品治理的任务不是把愿景写得更响，而是维持一条可审计链：

```text
公开主张 → 适用范围 → 固定 snapshot → 独立证据 / 已知反证 → 下一道解锁门
```

每条对外主张必须满足以下规则：

1. **绑定范围**：语言版本、平台、任务类型和不保证的内容必须明确；不得把局部证据外推为全场景保证。
2. **绑定 snapshot**：一次通过只证明被测 commit/anchor；main 变化后仍需在候选 snapshot 重放。
3. **反证优先**：新反例立即降级主张，即使已有大量绿色测试；“尚未观察到失败”不能改写为“已证明无失败”。
4. **愿景与现状分离**：backlog、design 和论文先例不算已发货证据。
5. **负向结果保留**：B-111、B-181、B-182 等测量允许 null/负向结论；不得只传播胜例。
6. **传播不越权**：release、tag、公开 campaign、机构接触与外部权限仍由用户拍板。

### 1.1 0.1 internal checkpoint 与产品发布分离（2026-08-30 用户决定）

当前“0.1”不是developer preview、release candidate或公开产品版本，而是一个内部工程检查点：tracked C anchor能够构建current compiler，current compiler连续自编译到可复现fixed point，并足以把仓库、durable refs/notes与活动治理原子迁移到`vorton-lang/vorton`。它的首要目标是解除旧仓库与文本活动看板对后续开发的约束，不是语言bug清零。

因此，不命中current compiler/self-host/迁仓路径的已知语言缺陷可以继续被compiler接受而没有专门诊断，只需保留可复现触发、实际后果与workaround，并在B-183中导入GitHub Known Issues。该处理允许false rejection、wrong-code、leak、crash或ownership/safety违约存在于未覆盖的外部程序；相应能力不得进入`shipped`，不得据此宣称“所有通过编译的程序安全/正确”，也不得把internal checkpoint称为公开preview。任何阻止tracked-anchor构建、连续self-host、gen2/gen3 fixed point、compiler/hello最小smoke、仓库迁移或clean-clone重建的缺陷仍是检查点blocker。

公开developer preview继续服从本文件后续candidate、known limitations、artifact与用户release决定；0.1内部检查点不会提升任何产品claim状态。GitHub Issue/PR承载迁仓后的活动工作、review与用户决策，稳定语言spec和已批准verdict仍版本化入库，不能把Issue变成第二份永久设计真值。

## 2. 主张状态

| 状态 | 含义 | 可用于什么 |
|---|---|---|
| `hypothesis` | 有设计理由或路线图，尚无目标协议下的数据 | 内部选路；不得写成产品优势 |
| `internal-evidence` | 固定 snapshot 上有可复核的仓库内证据，但尚未形成独立可消费 artifact | 技术进展说明；必须带 snapshot 与限制 |
| `candidate-evidence` | release candidate 上按预注册协议重放，manifest/raw result 齐全 | 封闭 preview 与 release dossier |
| `public-evidence` | 外部可取得 artifact、协议和原始结果并能独立重放 | 对外事实主张；仍不得扩大适用域 |
| `rejected` | 已有直接反例，或实验没有支持该命题 | 只能作为限制/教训传播，禁止换措辞复活 |
| `retired` | 产品方向或证据已被新版替代 | 保留历史链接，不进入当前宣传 |

状态提升必须靠新的证据事件；文案修改、更多 stars、更多 commit 或模型赞同都不能提升状态。发现 escaped defect、协议污染或 snapshot 不一致时，主张先降级，再调查。

## 3. 活动主张账本

| ID | 有界主张 | 当前状态 | 证据与反证 | 当前允许措辞 | 下一道门 |
|---|---|---|---|---|---|
| C-001 | C11-only 编译器能够自举，tracked C anchor 可达到固定点 | `internal-evidence`（snapshot） | `50a96a` clean clone 全量 1551 pass ×3、anchor hash 固定、远端 CI green；只覆盖该 snapshot | “Ring 编译器已经用 Ring 自举；C11 是当前唯一 codegen/bootstrap 路径。”提及强可复现性时附 snapshot | B-175 在 candidate artifact 上重放 clean build、fixed point 与 Windows/Linux matrix |
| C-002 | Ring 当前实现 HM/trait、`io/fail/mut` effect 与确定性 RC/verifier 路径 | `internal-evidence`（有 blocker） | 代码、规范与测试存在；#260/#268/#269 证明当前仍有安全源码崩溃/ownership 逃逸 | 可以列出“已实现机制”；不得说“所有通过编译的程序都内存安全”或“Rust 级安全” | critical 清零；candidate 上做对应 C/RC/ABI/ASan 与独立审查 |
| C-003 | 新用户可从发布包完成 install/doctor/check/run/build native exe | `hypothesis` | 当前 README 仍要求源码构建与手工链接；无 release artifact | 只能说“B-174/B-177/B-175 正在建设 preview 产品面” | B-174/B-177/B-175 验收 + 用户 release 决定 |
| C-004 | 在同任务、同模型、同预算下，Ring 的行为契约降低相对 TypeScript 7 的 agent 总成本 | `hypothesis` | 尚无正式对照 run | 不得使用“LLM 更容易写对”“比 TS 更省 token”等比较级；可说这是 B-111 的可证伪研究问题 | B-111 预注册实验、raw traces 与可重放报告 |
| C-005 | 在声明的低风险包络内，低成本模型只影响产出率，不降低 accepted patch 的正确性标准 | `hypothesis` | 当前强模型 review 有价值但昂贵；尚无 repository replay/calibration 证据 | 不得说“廉价模型通过 CI 就安全”或据此开放核心 TCB | B-182 历史缺陷/seeded mutation calibration、隐藏 oracle 与统计上界 |
| C-006 | 当前 CI 绿色等价于“补丁一定正确” | `rejected` | 同一 `50a96a` snapshot 曾全量 ×3 与远端 CI green，#268/#269 后续仍给出 critical 反例 | 只能说“CI 是必要证据，不是无条件正确性证明” | 不恢复该无界主张；B-182 只能建立风险包络内的接受保证 |
| C-007 | Ring 生成程序具有领先或可发布的 runtime/内存/产物尺寸 | `hypothesis` | 尚无 Windows/Linux release baseline | 不得宣传性能领先；B-176/B-180 的 compiler feedback wall time 不得混报为用户程序性能 | B-181 reproducible baseline 与 release budget |

以下能力在实现并形成对应证据前一律视为未发货：refinement types、native async、完整 Drop unwind/Weak、formatter、LSP、package registry、JIT 和 debugger。文档可以解释设计方向，但首页、release note 和演示不得使用现在时暗示可用。

## 4. 产品面与传播门

公开源码、产品 release、对比宣传和机构级保证是四件不同的事，不能由同一个“仓库已公开”事实自动解锁。

| 产品面 | 进入条件 | 可以做 | 不可以做 |
|---|---|---|---|
| 工程源码快照（当前） | 仓库公开 | 展示语言机制、自举进展、设计与已知限制 | 称为可安装产品；承诺支持 SLA；使用未证实比较级 |
| 内部 release candidate | critical/release blockers 按看板关闭；B-174/B-177/B-175 candidate 门完成 | 重放安装、agent contract 激活、跨平台与 provenance；准备用户决策包 | 对外发布、tag、广泛招募 |
| 封闭 developer preview | 用户批准 cohort 与数据边界；许可证/支持范围已定；candidate 可重放 | 邀请少量目标用户按 [`preview-feedback-protocol.md`](preview-feedback-protocol.md) 独立试用 | 把参与者数量当采用率；临场教学后仍记作“无人介入成功” |
| 公开 developer preview | 用户作出 release 决定；artifact、checksum、已知限制、反馈入口齐全 | 宣传已发货事实与复现步骤；明确 experimental/preview 边界 | 在 B-111 前宣传相对 TS7 的 agent 优势；在 B-181 前宣传性能领先 |
| 证据型 campaign / 机构材料 | 对应 claim 达到 `public-evidence`；原始协议与负向结果可取 | 围绕该 claim 的限定结论传播 | 把 B-111 外推到仓库安全委派；把 B-182 外推到 compiler/TCB 核心 |

B-111 不是公开 developer preview 的绝对前置：Ring 可以作为诚实标注限制的实验性语言发布；但任何“agent 更高效”的 campaign 必须等待 B-111。类似地，B-182 只解锁其预注册风险包络内的委派主张。

## 5. 首个产品叙事

在 B-111 之前，首个可兑现叙事固定为：

> Ring 是一门 inference-first native 应用语言：源码保持低标注，编译器推断类型、effect 与资源行为，并把无法证明的边界显式暴露出来。

首个验证场景是“小型 native CLI 的完整生成—检查—修正—运行—构建闭环”，不是“通吃所有应用开发”。它同时覆盖当前最接近交付的 CLI 产品面、agent feedback 和普通文件/Git 工作流。

GitHub description 的候选英文文案：

> An inference-first native language with explicit effects, deterministic resources, and agent-readable compiler feedback.

该文案只是草案；修改公开 metadata 属外部产品面动作，须与 preview/release 决定一起执行。当前 `A programming language for LLM agent` 把 LLM-first 写成出发点，与 [`docs/philosophy.md`](philosophy.md) 的现行定位不一致。

## 6. 公开入口契约

公开 preview 的 README 首屏和 release artifact 必须共同回答：

1. **它现在能做什么**：只列 shipped 能力；给一个从 unpack 到 native exe 的最短路径。
2. **它明确不能做什么**：列出 platform、语言特性、正确性与性能边界。
3. **如何核对版本**：compiler version、commit/anchor、target、checksum、inspection schema/agent skill identity 与 provenance manifest。
4. **如何反馈**：结构化 bug、agent-loop 与 feature request 入口；不承诺尚无资源承担的响应 SLA。
5. **证据在哪里**：测试/benchmark/实验指向 raw manifest，而不是只给汇总图。

每份 release note 分为 `shipped`、`fixed`、`known limitations`、`evidence` 四栏。Roadmap 不混进 shipped。安全与 agent 效率主张必须链接本账本的具体 claim ID。

## 7. 许可与生成物边界（2026-08-07 D-002）

Ring 采用 `MIT OR Apache-2.0` 双许可，copyright holder 为 `Yufeng Ying`；现有 Git history 中 `Yufeng Ying` 与 `Yyf2333` 两个 author identity 均纳入同一权利人的授权。`OR` 表示使用者可以任选 MIT 或 Apache-2.0，而非必须同时遵守两份许可证。

默认许可范围覆盖 Ring 自有的 compiler、runtime、std、文档和生成模板；第三方来源保持其原许可并进入 NOTICE/provenance manifest。外部 contribution 在未显式声明 `Not a Contribution` 时按同一双许可提交；若未来需要 CLA 或改变贡献条款，必须另行由用户决定。

项目不对只表达用户源码的生成 C/object/executable 主张额外版权许可。若生成物实际复制、静态包含或链接 Ring runtime、std、模板或其他受许可材料，其相应 MIT/Apache-2.0 与第三方 notice 义务仍然存在，并由 release manifest 明示；不能用“编译器输出不附加许可”抹去真实捆绑内容。

本决定只固定许可政策，不等于许可证已经落地或授权公开 release。B-175 负责 provenance inventory、两份官方许可证原文、SPDX expression、NOTICE、贡献说明和 artifact 许可 smoke；最终支持声明、tag 与 GitHub Release 仍由用户另行拍板。

## 8. 维护责任与触发器

Repository Steward 维护本账本；用户保留 release、公开 campaign 和保证边界决定。以下事件触发同步，而不是按日制造文档 churn：

- critical escaped defect 或新 counterexample；
- B-183/B-174/B-177/B-175/B-181/B-111/B-182 的状态改变；
- release candidate snapshot/anchor 改变；
- 外部竞品事件满足 [`competitive-analysis.md`](competitive-analysis.md) §12 的提前复查门；
- 对外文案引入新的比较级、安全保证或平台支持范围。

完成项的逐轮过程留 Git；本文件只保留当前 claim、范围、证据状态和下一道门。

## 9. 公共名称与组织边界（2026-08-09 D-003）

语言的公共名称确定为 **Vorton**，GitHub organization 使用 [`vorton-lang`](https://github.com/vorton-lang)。对外完整名称使用 **Vorton Programming Language**；短名称仍为 **Vorton**。

本决定只固定名称和组织身份，不提前执行仓库迁移或公开 release。在迁移计划另行拍板并原子执行前，现有仓库名、源码扩展名、CLI、包名、内部路径和历史文档可以继续使用 Ring；这些遗留标识不构成双品牌或兼容承诺，也不得通过零散 alias 提前形成两套公共身份。

用户已授权先维护 `vorton-lang` 的最小公开组织页面：可以设置组织显示名、使用 §5 已批准边界内的单句 description，并建立不含 logo、插图、badge、下载链接或未发货能力的 profile README。网站、视觉资产、仓库 transfer/rename、历史保留策略、生成物拆仓、CLI/扩展名/package namespace 和 release 仍属于后续迁移计划；本次组织页面上线不等于 release。

## 10. 仓库与 GitHub 工作流迁移方向（2026-08-09 D-004）

用户于2026-08-30重新固定顺序：#268/#269最小self-host/fixed-point检查点完成后立即执行B-183 planning与另行批准的cutover，把核心仓库迁至`vorton-lang/vorton`，并把用户—Repository Steward的活动协作入口迁到GitHub Issue/PR；B-176/B-180性能专项与Known Issues修复在新仓库继续。该顺序避免在旧Ring公共标识和文本活动看板上继续投入开发基础设施，也不把内部检查点误作preview。

迁移保留完整 Git history、tag、自定义 durable ref 与 audit notes，采用 GitHub transfer + rename，不重建或重写历史；旧 `YYF233333/Ring-lang` slug 不得复用。`compiler/dist-c/main.c` 继续留在核心仓库充当唯一 tracked bootstrap anchor，不拆仓或使用 Git LFS，并在 `.gitattributes` 标记为 `linguist-generated`。公共身份按未发布期 clean break 一次迁到 Vorton；`.v` 扩展名已因现有语言/工具链冲突排除，最终源码扩展名及 CLI/package/editor namespace 留到 B-183 planning 固定。

GitHub 迁移遵守“活动协作与稳定结论分层、无双重手工真值”：Issue/PR 承载活动工作、review 与用户决策，稳定设计/治理 verdict 仍进入仓库；现有 backlog/audit 只有在导入 schema、幂等映射、dry-run、校验和 cutover 方案完成后才能批量迁移。Steward 初期使用限定到 Vorton 仓库的最小权限人类账号凭据；需要长期无人值守身份时优先采用组织拥有的 GitHub App，machine user 仅作 fallback，任何 bot/App 均不得成为 organization owner。

D-004 只授权把 B-183 排入路线并固定上述不变量，不授权现在执行 transfer、创建账号/token/App、修改组织权限/ruleset、批量创建 Issue 或发布 release。B-183 进入 planning 后必须先形成精确执行规范、权限清单、回访/离线契约和原子 cutover dossier，再由用户批准其中的仓库外动作。
