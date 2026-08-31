# Backlog

> 活的工作看板。做完的条目删除，只在 git commit message 留记录。
> 条目格式：`### B-xxx <标题> [类型] [优先级] [复杂度] [dispatch] [状态]`
> dispatch 标记：`mechanical`（路径唯一，可直接执行）/ `judgment`（需要跨模块推理、Argument 或独立 review）
> 状态流转：`queued` → `planning` → `doing` → 删除
> 决策分支：`doing` → `waiting-feedback`（仅该 item 等用户保留决定）→ 拍板后 `queued`；Repository Steward 同时继续其他无阻塞工作
> 工作流规范见 `docs/workflow.md`

## 当前排序

当前主线目标是 **把latest compiler蓝本与完整历史直接迁入`vorton-lang/vorton`，并以稳定外部宿主语言建立v0.1 compiler**。固定实现蓝本为ownership authority `04b3ba53`的`compiler/std/ring_runtime.cpp/tests`；稳定design/lang-spec取与04b3逐blob一致的当前main版本，workflow/backlog/audit取本规划commit后的main。完整Git历史与两条ref共同迁移，不把跨branch composite伪装成单一Git tree。不再要求任何旧Ring compiler理解current source；现有Ring compiler、tracked C anchor与历史candidate只作语义/回归oracle。它不是developer preview、release、语言bug清零或ownership/safety产品保证；已知缺陷与未完成#268/#269原样进入新仓GitHub Issue。实际公开preview/release、许可证、正确性与最终支持平台仍由用户在后续候选产物和证据齐备后拍板。

**未发布期 clean-break 原则（2026-08-07 用户拍板；2026-08-30 checkpoint澄清）**：首次公开 preview/release 之前，一项公开语法、API、ABI 或语义变更一旦按授权边界拍板，就采用最简单的原子切换；兼容性本身不是增加 deprecated alias、双实现路径、旧 ABI fallback 或迁移 shim 的理由。仓内调用点、规范和测试在同一变更中整体迁移，并明确记录 break。该原则不替代新语义本身的用户保留决定。0.1 internal checkpoint允许把不命中self-host/迁仓路径的已知缺陷原样后移，而不是假称correctness/safety门已通过；首次公开preview前再按产品治理建立相称质量门，首次公开发布后的版本兼容政策另行建立。

**近期 break 审核门**：任何修改公开语法、签名、ABI 或可观察语义的 item，在实现前必须标成“已拍板 clean break”“等待 decision dossier”或“仅内部、非 breaking”之一。已拍板的 #268/#269 ownership 真值、B-167 调用点 evidence、0.1 no-index-assignment 与 B-193~B-196 surface/effect边界均采用一次性切换；旧 ownership、default evidence、宽泛`io`/host fallback、effectful Drop、index-assignment carrier与refinement placeholder必须在各自原子变更中删除，不形成双轨。B-168/B-169 的探针结论，以及 B-152、B-156、B-171、B-133 等潜在用户面变化在进入实现前仍显式核对 break 边界。每个已拍板 break 的验收都必须列出被删除的旧路径、同步迁移的仓内消费者/规范/测试，并用负例证明旧形式不会经 alias、fallback 或旧 ABI 继续生效。

Canonical dependency chain：`B-183 repository/GitHub migration + B-205 external-host compiler foundation -> B-176/B-180 -> #268/#269 ownership on the external host -> B-190 -> remaining correctness/ABI + imported Known Issues -> later self-host milestone`。

历史validator索引`#268/#269 -> B-176/B-180；B-176/B-180 -> B-190 -> remaining correctness/ABI -> B-183 -> B-174/B-177/B-175`已被上述2026-08-30迁仓优先路线supersede，只用于验证旧路线文本被显式识别，不再授权性能或correctness backlog先于B-183。

B-186 recovery gate 已由 `main@b29c8711` 与 GitHub Actions `32262726058`（check/test/bootstrap 全绿）完成；worktree/ref/WIP、authority、paired-session、push/CI 与 health 约束已转为 `docs/workflow.md` / `docs/repository-health.json` 的持续门，活动历史只留 Git。
`B-176` 保持 queued；B-180只保留runner anchor-object cache，compiler optimization冻结到B-183+B-205迁仓、host-selection spike与selected-host workspace闭环。

处理顺序固定为六道门：

1. **B-186 Repository convergence recovery（已完成）**：worktree/ref/WIP、单一 authority、main/branch 看板、repository-health 与 push/CI 已恢复；这些约束转为持续门。
2. **B-183+B-205 latest-blueprint迁仓与外部宿主compiler**：固定latest authority、完整Git历史/refs/notes、design/lang-spec/tests和全部WIP manifest，直接迁入目标仓库；在目标仓库用稳定宿主语言实现当前pipeline，不再把self-host或旧generated C兼容性作为0.1进入门。固定 archive 只能重建精确历史C而不能重建current Ring source，5d57同源gen2也已在84.171秒以`PreCore closure: open effect row crossed TypedHIR`失败；因此22 GiB crossing 路线已永久关闭，latest main也不得恢复S-prime、carrier backport、direct-edge/publicization/SCU/generated-C或同类代际加码。FlowIR/ONE ResourcePlanner/RcIR仍是目标compiler的唯一ownership终态，#268/#269在外部宿主上继续，不冒充已完成。

> **2026-08-31 Known Issues迁仓处置（用户决定，supersede self-host census gate）**：必须保留现有最小复现、已知后果和workaround，由B-183导入GitHub Issue；不得删除证据后声称支持。owning/type-parameter-dependent struct spread、B-170、B-160/B-162、一般B-165及此前所有demotion不再因旧compiler是否命中而决定优先级；B-205移植相应pipeline纵切时建立parity/负例，#268/#269在新host继续。

> **Generic callable correction**：factory/aggregate与leaf instance的历史census、fixtures和反证全部迁入#268/#269/B-205；不再作为旧self-host门。Selected-host ResourcePlanner纵切必须建模BodyInstance×leaf×CallableInstance，禁止以lambda wrapper、批量显式loop、per-type helper或复制stdlib RC authority冒充1:1翻译。

> **I′ final-emission H+T acceptance boundary（2026-08-20 用户批准）**：I′ 可增加一个永久但 internal-only 的 bounded acceptance TCB。Exact/NameOnly map 保存不可混用的 typed refs；所有 capture/dict/effect/closure critical leaf helper 必须从同一个 typed operand 原子生成实际 C line 与 ledger event，ledger 记录唯一 parent closure edge，并逐 edge 校验 store/extract、receiver load/call、domain、slot、index 与顺序。隐藏 flag 不进入公开 CLI/支持面；off/on 的 C、object 与诊断必须字节一致，相同输入 ledger hash 必须稳定，mutation 必须杀死缺失/交换的 tag、key、slot、index、edge 与 event。B-188 是首次 H+T one-shot 验收的硬前置；sealed artifact 一律不复用，fresh candidate 仍须原 runtime/RC/ASan/self-host/12 GiB fixed-point 完整门。任何 raw critical emitter 未接入、caller 可独立拼 C/event、closure edge 不唯一、ledger 不稳定、off-mode 漂移、需扩到 HIR/Perceus/runtime 或 12 GiB 失败都立即停止并重新 routing。T-alone 因不能证明 event 对应真实 raw slot而拒绝；提前 A′ 因重排路线并重新汇合资源风险而拒绝。

> **I′ fresh construction A-env verdict（2026-08-21）**：fresh `a2d59fd2` transaction 已按单次门永久停止；gen0生成部分C后，过度sanitize的友善环境使internal clang找不到正常`<math.h>`，不是I′/H+T或资源失败，partial产物不得复用。后续construction采用最小A-env：继承正常Windows/SDK discovery，删除B-188 secret-like names与显式compiler override，PATH前置exact LLVM/Python/Git，固定locale、`SOURCE_DATE_EPOCH`和fresh TEMP/TMP；只在ignored local evidence记录实际env/tool identity。25变量discovery whitelist因复制clang/SDK假设而拒绝，不新增sysroot/header manifest/wrapper。下一次必须由新的main治理commit合入ownership authority形成fresh full-repo snapshot，保持compiler tree不变；A-env C/C++ preflight、workflow/health和packet独立review通过后只运行一次，任意失败永久停止且不fallback。

> **I′ H+T COFF object-identity / v3 no-rerun verdict（2026-08-21 用户批准 A 并裁决既有证据）**：fresh `ffd6a416` gen1 construction 只建立construction claim。既有sealed candidate structural v3中四个RC case与off/on1/on2 child/audit均成功，off/on C字节一致、on1/on2 ledger与stderr字节一致，candidate hash不变；on1/on2 AMD64 COFF object等长，raw objects及hashes已保留，全部raw差异仅为标准COFF header `TimeDateStamp`字段offset 4（属于允许集合4..7），归一化offset 4..7后object字节一致。用户据已批准oracle直接裁决v3 structural PASS，证据root继续sealed/immutable，禁止创建或运行v4、禁止重跑structural。`tests/run_tests.py`只需把AMD64 COFF结构校验、仅归一化offset 4..7、raw diff offsets必须为该4字节子集的comparator与focused units固化并独立review；C、ledger、stderr继续literal byte identity，不丢弃object比较、不修改Ring clang invocation或引入确定性构建专项。该PASS只关闭H+T structural子门，不等于I′整体accepted；comparator review后下一门是剩余focused runtime matrix，gen2继续冻结，原RC/ASan/self-host/12 GiB fixed-point门均不降低。

> **I′ current-tree acceptance（2026-08-21）**：唯一 authority `dc91b3ae` 已把 compiler tree `21cb9782` 生成到 gen2/gen3 `main.c` literal fixed point（17,978,659 bytes，SHA-256 `2C8F1128…A23A2`），tracked anchor 与两代字节一致并经独立 review。一次 standard full runner 为 1588/1588（RC 保留既定 2 skip）；targeted ownership ASan 为 8/8、stderr 空。首个 ASan packet 因本机缺 x64 `stl_asan.lib` 在 link 前 sealed，materially different v2 复用仓库既有 Windows annotation 配方后通过，不把该失败追认为测试结果。I′ 只作为 exact-slot identity-only checkpoint accepted；当时的Trait-default executable-HDecl缺口后来由2026-08-30 convergence clean break结构性删除，不再是#268/#269 gate。该 claim 不因后续 S′ 路线反证而回滚。

> **S′ 独立性反证与历史 checkpoint 重排（2026-08-22）**：最新 main 的 source-built S′ gen1 对 direct/named owning payload 均生成“source 进入 owning sink 后仍在 block exit Drop”的同型 C，focused runtime/RC/structural 全红；旧 a11 S′ 绿色依赖祖先 A′ `HExpr::Take` 保存值并清 source slot，不能作为独立 S′ 证据。实验 admission 层已可恢复撤回，I′ 完整保留。当时下一且仅下一 checkpoint 曾为 A′ atomic transfer authority：一次贯通 checker→HIR→Perceus→verifier→codegen 的 executable-HDecl inventory、transitive may-Drop、callable modes、CFG/显式 `Take`/source-clear；transfer canary 通过后才恢复 exact-none W4/exit、tail negatives、shadow/loop/catch。不得把 fresh-only ANF 子集、Option ctor 特判或局部 verifier 补丁冒充该 authority；其实现分层现由下述 FlowIR 架构取代。

> **FlowIR Resource Planner architecture（2026-08-22 用户已理解并批准执行；2026-08-30 convergence收窄）**：TypedHIR→CoreHIR先闭合derive/protocol/andor/dict与typed call/member/handled evidence；source trait default body与`delegate`已从0.1 surface删除，不再形成elaboration或inventory obligation。CoreHIR是semantic elaboration closure。FlowIR只做pattern decision/projection、neutral ANF、scope/control result与freeze；`SymbolRef/SlotRef/PathRef`分域且不使用共享counter表达member/callable语义。共享ExecutableInventory覆盖Fn/explicit Impl/Trait contract/Effect/Test/Const/ModBlock/Lambda/handler、derived/constructor/dict/const getter、bodyless interface/extern与extern bridge；0.1同样不含函数default parameters、effect default body或sig。SystemEffectRef不进evidence/ExecutableInventory，只随exact host call进入AbiIR HostImport。ResourcePlanner以Logical OwnershipShape/Physical RcShape双轴、frozen callable graph与ephemeral CFG统一A′/S′，RcIR与ranked certificate完整显式；verifier证明least fixed point与路径守恒，codegen只消费verified RcIR。Single/project共用一条入口。

> **Builtin `Eq.ne` clean break（2026-08-30 用户批准 C）**：#268/#269 的 builtin public `Eq` inventory只保留exact `eq` member；`!=`唯一降低为`!exact Eq.eq`。删除`Eq.ne`、primitive Ne intrinsic、Option/derived Ne slot或body、default-specialization及其manifest/oracle，不实现sibling evidence rebase或无consumer样板。随后批准的0.1 convergence batch又独立删除全部source trait default body；builtin/derived exact ordinary impl body不受该source surface删除影响。

> **0.1 reserved type-binding gate（2026-08-30 用户批准 Nominal B）**：#268/#269 不实施exact-owner nominal Type纵切；type namespace一次保留18名 `Int Float Str Bool Unit Never Ptr Range Cell Option List ListIterator Map MapIterator Set SetIterator StringBuilder Result`。用户Struct/Enum/ExternType/TypeAlias direct declaration及import/re-export最终可见binding命中即稳定`E0207`，canonical builtin/std loader是唯一内部豁免；value/function/trait/effect/module namespace不受影响。验收穷尽single/project direct/import/re-export/alias collision、loader正例、非type namespace负控，并机械迁移仓内唯一Result type-shadow fixture。真正builtin继续不可覆盖；最终迁stdlib者随既有B-152/stdlib迁移逐项解锁为ordinary module type，同名用qualified path/import alias消歧。本限制是0.1 known limitation，不新增post item、Type owner carrier、side map或resolver fallback；`Range` exact syntax/annotation/for-in owner正例继续保留。

> **0.1 convergence clean-break batch（2026-08-30 用户批准）**：为先关闭#268/#269并进入B-176/B-180性能门，删除compiler/std/examples零生产consumer却要求跨层纵切的三项surface：①source trait method body，trait只保留signature且每个impl显式覆盖；②`delegate` declaration，全链退役并建议手写普通forwarding impl；③`Ptr`/non-RC extern递归进入generic aggregate storage，稳定source diagnostic。第三项使B-min hidden evidence、packed mask、payload-policy LFP/runtime branch与sealed WIP全部退役，不再作为mono fallback；direct raw value、ordinaryRing-managed generic container/HOF、builtin/derived impl body、associated type default、普通trait/impl/supertrait/dictionary保持。禁止compat alias、inert carrier、fallback或为三项新增post item。

> **Private physical nominal B + exact83 one-time bridge（2026-08-30 用户批准，supersede `680ee56c` Cut-A）**：public struct的private field可递归包含private nominal，source privacy对齐Rust；public fn/pub field/public enum payload等真正interface仍拒绝private type。Current carrier以exact `RegisteredNominalRef`运输physical metadata，禁止name-first后验owner；same/cross-provider、alias、generic、recursive与re-export/diamond继续由同一exact authority验证。当前post-cut overlay固定为83个private types、21 files、63 enum+20 struct、241 variants与8个pure header annotations，unexpected diff为0；旧exact84/64-enum/244-variant统计作废。

> **Terminal failed topo-prefix generated-C crossing**：`98f10efb`批准的三语句all-prior full `ModuleExports` patch已terminal失败并耗尽授权。它把不同module的alpha-local raw effect-tail整数并入同一`EffectFactBatch`，相同整数对应不同`EffectParamRef` owner，稳定报`raw tail changed parameter`；topological order或exact dedupe不能修复。该seed/overlay/receipt只作sealed反证，不得重跑、扩写或作为后续generated-C授权。Fixed d06的实际ABI为17 slots/typeid745；未执行的20-slot/typeid265 types-only方案来自错误artifact，未产生C/helper/build且已撤回。下一候选必须按实际ABI独立复核并重新取得用户决定。

> **Terminal failed A′ ABI17 types/layout-only crossing**：`6be3054c`授权的A′已按硬停执行并失败；`d7b83de2`只是Discussion对账错误产生的重复live文案，不形成新授权。Patch `A82B7607…`保持ABI17/typeid745、helper 18 actions/28 lines且review CLEAR，patched seed `C397ED0F…`成功，但唯一construction在12.976 s以同一`raw tail changed parameter`终止、无artifact；STOP receipt为`BF6FE9EFDA18C7C757E1B488D6AD27480C769FB2CAD13A8C571CE13E504CCDDE`。

> A′授权已消费，不得重跑、strip schema、改helper/overlay、扩slot或作为A2权限。当前只证明：顶层effect/value/trait/impl等slot为空仍重复同一batch raw-tail/owner panic；A′既投影约480个prior public TypeDefs，又改变direct full metadata的遍历顺序，尚未分离变量。Exact83自身83 targets /444 fields的recursive Fn/open-tail、quantified field-schema tail与Drop均为0，不能作为已证root cause。后续方案必须等完整projected-type/order静态审计形成新Argument并重新请用户决定；当前没有live bridge授权。

> **Terminal failed A3 final delayed-hydration crossing**：A3保持original direct/full `graph.dependencies` membership、顺序与pre-inference injection不变，以显式参数运输non-direct shallow physical list，并在effect facts/impl validation/dict lowering后、Core freeze前执行late TypeDef hydration。Fixed C `440875…`、ABI17/typeid745、exact83/480-types零tail/Drop、owner/edge单射与61/61 direct order静态门全部通过；patch `3E94B616…`为+89/-12、16 hunks，projection 18 actions、总估计38 actions，precheck `B6DDB5…`与独立review CLEAR。Patched seed `94EF698A…`编译成功。

> 唯一授权construction在13.009 s exit1、无artifact，重复`effect fact batch: raw tail changed parameter`；STOP receipt为`1436F76C2065C871DD7833829DB95BE39245BFA4499B489D6AA0AD44D3116F3A`。A3授权已消费且失败，临时C已删除，其余hash-pinned evidence仅供复核；禁止retry、diagnostic patch、A4或任何其他generated-C bridge。该路线关闭，B1/B2仍须新的用户裁决，不构成当前授权。

> **Static-stop global-renamer SCU**：`db109345`授权的root-scope global renamer经fixed `d6b15e82…` / tree `51f1763d…` census确认需解析6008个module-level declarations、38组重复拼写、440个named-use和至少147个shadow sites；仓内无Python binder/AST printer，估计12–20 active h，已触发`>=10h` stop且从未生成或运行。它不再是live route。

> **Terminal failed native inline-module SCU crossing**：fixed tuple为source `05acf602…`/tree `51f1763d…`/std `4a910034…`、generator `17A86339…`、flat `F61405E6…`、manifest `F346B25D…`、runner `9C490323…`、plan `2E89DCB1…`、d06 `D2078ED3…`。Root确认61 reachable files、60 wrappers、433 edges、440 `super::` insertions、500 unchanged spans、no UseDecl/unexpected edit；review CLEAR且`70ac7ac9`已吸收后才消费隔离结果。

> 唯一d06 single-file check在19.5354707 s exit1、零retry/无artifact，稳定报`typed effect header: quantified tail/schema census differs`；result SHA `29DE6A50E39827A94C95B3E7BACD059C68D9B22EA6FD6C01F44F779644BB89FF`、stderr SHA `39481455…`，无infra/resource failure。它绕开了ModuleExports但在d06 `validate_effect_header_schema`中发现definition quantified tails与stored schema binding census数量不等；具体owner未知。H1整体已被first falsifier反驳，路线授权消费并关闭：不diagnostic-patch/retry/换ordering、build/bridge/fixed-point，也不自动转pub/B1/B2/generated-C；temp evidence sealed、非candidate/fallback。

> **分阶段自举是唯一live route（2026-08-30 用户拍板）**：最终one-shot B1-7已固定为temp `9d3ae037…`/tree `00676c0e…`/patch `948596D6…`/manifest `4958DCF5…`，聚合五文件carrier、Unit修复、8 pure headers、全部适用606拆臂与83/83 publicization后，d06仍在16.071 s以`Core producer: struct registry owner is absent`终止（stderr `06215AEA…`），无infra/resource failure。该结果终止B1-0..7逐项backport；不得再按首错补owner或把不同代证据拼接。120条空direct-edge候选因会向旧injector送入完整`ModuleExports`、可能复现raw-tail owner冲突而由用户明确关闭，未运行、不得恢复。

> Canonical chain改为`d06 -> 524d1d00 checkpoint -> 最少的0fab/18e/606附近checkpoint -> clean-current -> gen2/gen3 literal fixed point -> compiler/hello smoke`。d06以后只有16个compiler-tree transition；按当前seed可接受的最远语义checkpoint跳跃，不逐commit replay。首个524d overlay必须由该tree重算exact84 private physical roots（census `4D2274FD…`）、补8 pure headers与适用606拆臂，且不得提前带入`PhysicalNominalFact` carrier；中间publicization/compatibility只存在temp crossing，最终clean-current保持规范privacy/identity。每个选中native checkpoint按candidate machine/review同启与PASS review gate执行。

> **2026-08-31 external-host纠偏（用户决定，supersede 5d57 cut）**：clean 5d57同源gen2已由全pin transaction在84.171秒terminal失败，唯一stderr为`PreCore closure: open effect row crossed TypedHIR`，无artifact；这证明“被旧代编译成功”不等于自身可自举。0.1不再选择任何历史Ring compiler cut，而以latest `04b3`为功能蓝本、B-183+B-205为唯一live route。dc91 fixed-point与current相同tracked C anchor只作旧功能oracle，不作为新compiler语义基线。只有外部宿主compiler稳定、公开语义/IR/runtime契约收口后再设self-host里程碑。

> **Struct move-spread Known Issue（2026-08-30 用户批准demotion，supersede partial/open-drop gate）**：#268/#269只依赖当前compiler中的8处全shareable spread；它们保持base单次求值、override LTR与现有physical RC语义。Owning或type-parameter-dependent字段需要exact Take时，0.1 compiler仍可接受源码但可能产生leak、double-drop、UAF或错误Drop顺序；不要求新增source diagnostic，也不实现`Live`/`Moved` partial/open-drop、`ReleaseMovedAggregate`、storage reuse或专用shell路径。compiler/std/examples当前owning consumer为零；外部程序应显式destructure并重建全部字段。现有反例与workaround随B-183导入GitHub，不阻塞internal self-host/migration checkpoint，也不得据此宣传owning spread正确。

> **0.1 named-enum update spread clean break（2026-08-30 用户批准）**：`Variant { ..base, ... }`稳定source diagnostic，并建议在已匹配exact variant的arm内显式重建全部字段；保留struct spread、named-field/generic/nullary variant construction、pattern/match与字段move。仓内0.1 production/std/examples consumer为0；7个测试source sites原子迁移为显式重建。实现必须删除`HExpr::NamedVariantConstruct.spread`及Core/Flow/Rc MoveUpdate的variant-only producer/consumer，old-authority census为0；不得新增runtime tag check、exact-variant refinement carrier、fallback、兼容语法或post item。验收覆盖single/generic enum显式重建正例、named-enum spread稳定负例、struct spread不回归及旧variant MoveUpdate mutation。

> **0.1 complete custom-handler gate（2026-08-30 用户批准 A）**：一个`handle...with`只要包含某exact `HandledEffectRef`的任一arm，就必须按对应`EffectDef`覆盖全部declared `EffectOperationRef`各一次；source order任意，TypedHIR按decl ordinal冻结dense `0..N-1`，完整后才消除whole effect atom/发布facts。Missing/duplicate/unknown/cross-owner稳定source diagnostic，Core复核owner/count/ordinal全集，现有dense C evidence ABI不变。Partial residual row、unhandled parent forwarding与sparse ABI不进入0.1。验收覆盖不同source顺序、nested/cross-module/generic closed instance、missing/duplicate/unknown/cross-owner及count/ordinal mutation；System effect仍不可handle。

> **Internal-checkpoint硬门（2026-08-30 supersede原完整验收）**：旧d5/17/df1/37a4/a7 S1候选与sealed packet只作反例/evidence，不作seed或逐点返修；a7 one-shot已user-directed终止且inconclusive。当前只修会阻止tracked anchor→current compiler→gen2/gen3文本fixed point、compiler/hello smoke或B-183 clean-clone重建的真实路径；其他既有矩阵失败、ownership/RC边角与未完成纵切保留证据后导入GitHub。关闭#268/#269 internal checkpoint要求一个fixed source的连续self-host交易、gen2/gen3 `main.c`字节一致、两个最终compiler可启动并通过最小smoke，以及无证据拼接；不要求standard full、完整RC/ASan、全部single/project/factory/catch/spread矩阵或exact CI先行全绿。后者没有被删除或宣称通过，而是迁仓后按GitHub Issue/PR恢复。

> **Compiler-wide staged IR adoption（2026-08-22 用户批准；2026-08-30 checkpoint澄清）**：总架构固定为 `AST -> ResolvedAST -> TypedHIR -> CoreHIR -> FlowIR -> RcIR -> AbiIR -> mechanical C11`，但不新增平行 P0 或一次性 rewrite。`FinalHIR`/`RcHIR`旧名不保留alias；FlowIR明确是first MIR/CFG-style operational IR，RcIR是其资源显式版本。当前#268/#269只保留self-host实际需要且后续可共用的exact identity、typed carrier、ExecutableInventory、neutral normalization、freeze/validator与RcIR路径；不命中self-host的未完成纵切迁入GitHub，不得用ownership-only side map抢先形成第二套前端。B-180仅在测量支持时消费稳定stage hash/cache，后续control/evidence/RIIR/optimization仍进入唯一所属层。每个cutover必须原子迁移消费者并删除旧name/type/backend fallback；长期架构与公开语义目标不变，但当前验收范围由上述internal-checkpoint硬门取代原七道门。

> **0.1 self-host execution boundary（2026-08-30 supersede）**：当前#268/#269只实现compiler自身、tracked bootstrap与B-183迁仓的真实consumer。任何仅服务外部边角程序、post-migration correctness或未来能力的variant、carrier、fallback、extension hook与validator branch均删除、不新增或保留为Known Issue证据；只有阻止current compiler连续self-host/fixed point、最小smoke或迁仓重建的finding才BLOCK。Deep Clone、exact identity、Core closure、RC conservation、single/project、full/ASan与公开preview门仍是后续真实工作，但不再是internal checkpoint已完成的claim。

> **Core effect closure（2026-08-26 用户批准）**：TypedHIR freeze必须把普通effect inference变量完全求解，并把合法多态tail generalize为稳定`EffectParamRef(owner, ordinal)`；raw UnionFind/type-var tail禁止进入Core。`CoreCallableEffectContract`保存canonical system/handled/fail/mut/unsafe atoms与可选formal effect参数，call site保存exact实例化；first-class/dynamic candidate逐项核对effect/evidence契约。Core/Flow不重跑effect inference，Planner不消费effect。本边界是现有0.1 effect-polymorphic HOF/B-167与B-194/B-195的真实consumer，不是未来扩展hook。

> **Recursive SCC inference gate（2026-08-28 用户批准 A+）**：当前#268/#269的effect-formal producer必须先把top-level、inline module、impl method与singleton self-recursion统一到一个HM递归组生命周期：组内monomorphic provisional schemes共享constraints且peer/self lookup不instantiate；整组完成后相对组外env一次性final-zonk/generalize、生成canonical effect schema与exact call/value provenance，并原子rebind/HIR finalize。不得只修top-level Phase2b、在现有impl effect pre-pass上叠第三authority、premint formal或新增post-SCC HIR patch。0.1明确不支持polymorphic recursion；普通generic recursion保持。验收必须覆盖四类递归入口、组失败零部分发布、组外独立实例化、B-122/#149回归、effect-HOF/diamond/import-order矩阵，并杀死first-use mint、owner-stack、importer remint和provenance缺失mutation；通过前effect build/matrix/长门冻结。

> **A1 single-inference closure（2026-08-28 用户批准）**：A+唯一实现是`infer_fn_draft → finalize_fn_draft`。每member body只infer一次；draft不得drain pending dictionary/evidence、zonk、canonicalize handled evidence、生成最终callable改写或保存整个InferCtx，只保存exact owner/registration、raw HIR/header、finalization必需的bounds/assoc provenance、owner-scoped pending facts与最小metadata delta。整组共享唯一UF，完成后每draft只finalize一次；所有scheme/schema/HIR/callable facts先全量验证，再atomic commit，失败恢复原scheme且零部分发布。Top-level/inline/impl/self只提供exact frame adapter，不能复制runner/solver。此前“constraint inference→安装scheme→再次infer body”的double-inference候选已按用户stop门封存，只作反证，不得恢复或换名重做。

> **Prelude A1 adapter gate（2026-08-29 用户批准）**：prelude Phase1先注册全部固定std files；Phase2按已证0.1 file DAG逐file，把该file全部ordinary Fn/Impl连同exact file/frame/site交给同一个`infer_decl::check_registered_body` call graph/Tarjan/A1 runner。每个真实SCC单独leaf-first、single-infer、atomic publish；same-file forward/self/mutual不得受声明顺序影响。Struct/Enum/Trait/Const/Extern阶段保持，non-publishing duplicate extern先现有single-decl finalize后从Program移除。禁止per-decl Fn checker、全prelude强行单SCC、新global/multi-frame scheduler、手工挪decl/STD_FILES绕过、provisional schema premint或fallback。`STD_FILES`只作固定inventory与跨file DAG；0.1无cross-file recursive prelude consumer，反向edge/cycle须preflight fail loud。验收覆盖`map_get_panic→map_probe_index`forward、same-file self/mutual、source reorder不变、cross-file leaf、reverse/cycle负例、exact HDecl/storage过滤及mutation杀死旧逐decl路径；通过前build/matrix/长门冻结。Post-0.1仅在真实consumer出现后重审完整跨file recursion，不新增当前carrier/item。

> **Unique instantiation receipt gate（2026-08-28 用户批准）**：每次scheme/member/callable instantiation必须生成一份包含全部source formal→fresh/final actual的typed mapping receipt；type/effect actual、DictRef/evidence与Core call/value provenance共同消费。`build_scheme_var_map`或任何按已zonktype shape重建mapping的dictionary/effect路径必须退役；D16与trait-bound/nested callable mutations必须能杀死receipt缺失、删项、换序及consumer私自重建。该receipt不创建新solver或post-0.1 carrier，只固定现有0.1实例化的单一真值。

> **R1 dynamic handled-evidence gate（2026-08-28 用户批准）**：为闭合#268/#269的factory/returned-lambda真实consumer，B-167的custom `HandledEffectRef` function-value纵切前移并入当前authority。Lambda创建pure；ordinary named/anonymous callable不capture定义处handler；每次调用从当前dynamic handler context借用exact evidence，无handler则effect外传。Internal handler arm/re-perform object可显式持outer context，但不得与user closure混用。必须原子删除旧lexical capture与任何hybrid/fallback；B-168 failure/control及B-169其余工作不前移，但后续须兼容本契约。

> **P2 uniform EffectCtx gate（2026-08-28 用户批准）**：所有Ring callable（含pure/system-only、named/method/constructor/ordinary closure及compiler/runtime builtin Ring closure）统一一个显式borrowed `EffectCtx*`；ABI为`closure env（仅indirect）→ordinary args→trait dictionaries→ctx`。普通用户top-level extern与不回调Ring callable的普通HostImport leaf保持原ABI，Ring wrapper机械丢弃ctx；任何exact compiler-owned runtime intrinsic leaf只要调用Ring callable就必须显式接收并转发ctx。当前穷尽callback set固定为`ring_list_sort_bridge`/`ring_list_sort`、`Option.map`、`Option.and_then`、`Option.unwrap_or_else`、`Cell.update`；sort/Option转发current ctx，pure Cell callback传immortal empty ctx；只按exact `CompilerExternRef`/`IntrinsicRef` tag裁决，missing/extra tag fail closed。所有调用同步且不得保存/retain ctx；无producer的legacy List HOF不保活，不新增thunk、adapter object、通用adapter inventory或用户FFI callback能力。Empty为immortal singleton；Handle创建owned RC child overlay并持parent；ordinary call零分配只borrow。Entry key必须是Core冻结的完整typed handled instance（exact ref+type args），inner exact match优先；closed fixed layout可静态offset，open formal转发typed view。TypedHIR/A1产layout/projection，Core唯一冻结验证，Flow只运输ctx/install，Planner只做Borrow/Own/cleanup，AbiIR/C机械emit。禁止P1变参/混合trailing evidence、P3 adapter inventory、specialization、TLS/global/root、name/nominal lookup、C临时token或第二effect solver；不得以ordinary-Core重写扩大#268/#269。验收除原P2矩阵外必须覆盖sort/Option三方法的pure/1/2-effect与None不调用、Cell.update empty ctx及reentrant RC、single/project一致性、wrong/missing/extra ctx或tag mutation和全部bridge的RC/ASan生命周期。

> **D1 fully-closed handled-instance gate（2026-08-28 用户批准）**：0.1保留generic custom effect declaration与所有closed concrete uses，但runtime handled token的type arguments必须递归fully closed；禁止依赖callable own/inherited/outer/lambda-chain type formal、nested callable effect formal/open row、open structural row或任何later-instantiable formal。`fail<T>`/`mut<T>`独立保留；generic alias展开后检查；top-level effect-row formal只forward同一ctx，Core BorrowView只作proof。TypedHIR/A1在atomic publish/export前统一检查final callable header、nested Fn type、body layout、lookup/install/handler、call/value actual与generic impl/method并给稳定诊断；Core复用type graph predicate和实际runtime token producer census二次fail closed。Bodyless generic effect operation contract不得自动进入token table，只有 executable body中的真实lookup/install/emit carrier可产token。禁止stack/heap remap view、closure descriptor、H3 handler ABI、type erasure、specialization或新solver。验收保留closed Reader/Writer/GenericProbe/OpenEcho正例，将`relay_nested<T>/NestedPort<T>`变专用负例，覆盖nested type/effect/open-row formal、alias、outer/lambda/impl owner、cross-module/re-export、bodyless false producer及相关mutations；通过前P2 build/matrix/长门冻结。

> **U1a no-partial-inline-module gate（2026-08-22 用户决定）**：0.1 中同一 direct parent scope 的 `mod name` 只能声明一次，第二个 ModBlock 在 resolver source census 立即报 `E0207`；不同 AstSite 不能因 canonical payload 相同合并，`E0707` 只保留给不同 origin 的 import ambiguity。Import/re-export/same-origin diamond 仍幂等复用 exact origin，不同 parent 同 leaf 与多个 impl block 不受影响。仓内 compiler/std/examples 零迁移；3 个 active resolver fixture 机械合为单 block 或改成 duplicate-mod 负例，staged b107 probes 同步重写/退役。验收必须由 source-built exact candidate 的真实 parser/resolver 覆盖 duplicate ModBlock、单 block 内 Fn/Const/Extern/Struct/ExternType/Enum/TypeAlias/Effect/Alias/Trait direct duplicates 及 delivery 非回归；Python source scan 只作非权威 scope guard。未来若有真实大规模 consumer，以显式新 feature 重新设计，不保留隐藏兼容路径。

> **0.1 surface simplification / CoreHIR closure（2026-08-23 用户决定；2026-08-30 supersede）**：compiler/std/examples对函数default parameters、sig placeholder、refinement placeholder、user effect default body、source trait default body与delegate surface均无必须保留的真实consumer。0.1 clean break删除函数default parameter、只注册/transport `SigDef`、parse-and-discard `where`、user default evidence、trait body/default specialization与delegate生成impl全链。每个保留surface必须提供唯一CoreHIR lowering或证明自身为canonical core，禁止把surface-only variant、待生成body/impl/evidence带入下游。Sig/refinement/default provider分别只按既有B-192/B-001/B-197完整未来门重入；trait default/delegate不因此新增post item。

> **0.1 trait / impl / private-interface visibility（2026-08-23 用户批准；2026-08-30 B澄清）**：trait是整体contract，impl block无visibility；`pub impl`、trait declaration/trait impl member的`pub`均hard-fail，只有inherent member逐项控制visibility。Public fn、pub field、public enum payload与bounds不得引用更private type/trait/effect；public struct的private field可隐藏private nominal，其layout只经exact compiler metadata运输。Private impl可留internal coherence registry，但外部trait impl surface要求target+trait均public，public inherent只发布pub methods。当前接受后丢弃的fake`pub`由B-199 clean break，不新增visibility identity bit。0.1无return-position`impl Trait`/opaque type，post-0.1由B-200按真实consumer重审。

> **0.1 impl-member extern clean break（2026-08-24 用户批准 A2）**：top-level `extern fn`/`extern type`是唯一用户FFI声明；inherent/trait impl中的`extern fn`全量hard-fail，不保留deprecated或backend fallback。现有Str20项与Int/Float `to_str`两项公共方法由B-201迁成唯一builtin assembly产生的exact `BuiltinMethodSite + IntrinsicRef + signature`，CoreHIR在闭合前接收contract，AbiIR按穷尽tag机械投影到既有runtime；删除`method_to_runtime_c(type,name)`字符串authority，不改变public method行为、top-level extern、runtime ABI或B-156 capability边界。B-201直接并入当前#268/#269 physical Core/formal3b cutover，不建立平行FFI/identity路线。

> **0.1 effect/capability batch（2026-08-23 用户批准）**：B-195以`SystemEffectRef(console/fs/process)`取代special `io`，system不进evidence、不可handle、无root handler，只经AbiIR HostImport/link provider；custom `HandledEffectRef`才显式handle。Host capability与`fail<E>`正交，std host extern漏标与`io.read`双authority原子收口。B-196令0.1用户Drop最终effect row为空且不建DropEffectSet；post-0.1 effectful destruction只在真实consumer下由B-198重审。B-072匿名sum既有语义继续批准但实现顺延post-0.1。

> **0.1 file capability / allocation-effect boundary（2026-08-23 用户批准）**：文件是隐式模块，B-156新增唯一第一项`requires {effects}` header并复用inline-module capability checker；无header不隐式授权unsafe，extern声明要求有效requires集合含unsafe，拒绝逐声明`unsafe extern fn`第二语法。0.1不建立`AllocEffect`、OOM profile或占位carrier；现有unsafe `alloc<T>()` raw-memory intrinsic不变，分配可见性只在post-0.1出现真实no-heap/real-time/embedded consumer后重新Argument，不为它预建backlog item。

> **0.1 no-index-assignment clean break（2026-08-26 用户批准）**：`x[i]` 只作读取；`x[i] = value`及compound index assignment稳定hard-fail并建议具名mutator，绝不按receiver类型隐式改写setter。List使用`set(mut self, index, value)`，Map使用既有`insert(mut self, key, value)`；0.1删除assignment-only Core/Flow/Planner/bridge `IndexPlace` carrier，不保留fallback或未来hook。完整`IndexMut`/嵌套index place由B-202仅在首次0.1后、存在真实consumer时重新设计，当前实现/review/验收视其为不存在。

3. **B-183+B-205迁仓 / external host**：立即进入planning与用户批准的外部cutover，在目标仓建立host-selection spike，并在硬门裁决后建立selected-host compiler workspace；活动backlog、review与用户决策迁到GitHub Issue/PR，稳定spec/verdict继续入库，不建立两套手工真值。
4. **B-176/B-180 反馈速度**：对selected-host compiler建立clean/incremental check、unit/parity和profile基线；runner与compiler分checkpoint，原量化目标需按新host重测，compiler只允许一个profile-guided wave。随后在该反馈回路上继续#268/#269。
5. **B-190 + Remaining correctness / ABI**：性能反馈改善后做一次有界减法复核，再由GitHub backlog处理B-193/B-194/B-195/B-196、B-162/B-164、现存issues及B-168/B-169/B-167/B-152/B-002；Known Issues按影响与真实consumer重新排序，不因0.1检查点关闭而冒充完成。
6. **Public preview candidate**：B-191 → B-174 → B-177 → B-175；随后B-204优先恢复proper callable-occurrence ResolvedAST，再由B-181、B-178/B-016、B-111等证据与工具面推进。B-072/B-197/B-198/B-202只在迁仓后按真实consumer与既有优先级重启。

B-176/B-180不得绕过B-183+B-205的迁仓、selected-host workspace与translation spike；其已证明的runner anchor-object cache可保留，但必须对选定宿主compiler重新测量。#268/#269在反馈基线建立后继续，不再等待或制造Ring self-host fixed point。

### B-205 Latest-blueprint外部宿主compiler [refactor] [P0] [XL] [judgment] [planning] [with: B-183] [before: B-176+B-180+#268+#269]

> **2026-08-31 用户决定，最高优先级**：语言surface、类型/效果系统、Core/Flow ownership IR与runtime尚未稳定时，不再要求旧Ring compiler理解current source。B-205与Vorton迁移作为同一个最高优先级program直接在目标仓库启动：实现蓝本固定为`04b3ba53`的`compiler/std/ring_runtime.cpp/tests`，治理真值取本规划commit后的main，完整Git历史与两ref均迁移；dc91 tracked C fixed point、5d57 source-built artifact及其他历史candidate只作限定oracle，不作为实现基线或self-host门。#268/#269保持未完成并迁入新仓，在外部宿主compiler上继续。

**宿主语言 / 翻译原则**：直接选择Rust，不做预先的多语言竞赛。Ring的`struct/enum/match/fn/impl`、`Option/Result`、泛型与容器算法按文件和函数尽量一对一翻译；参考TypeScript compiler的原则是使用成熟宿主生态、保持源码module与compiler stage直接映射、先机械保真再重构。只有实际翻译遇到明确且无法局部解决的Rust结构性阻塞时才回用户讨论，不提前设计TypeScript/C++ fallback。

**Phase 0 — 固定蓝本与最小纵切**：B-183迁仓manifest固定合并后唯一main的SHA/tree与每个compiler/std/runtime/test/spec文件hash。获得后续实施授权后，第一步只翻译一个`source → token → AST → diagnostic`纵切，用现有fixture证明路径可工作；不先翻译三套大切片，不写通用Ring→Rust transpiler，不混合调用旧compiler，也不同时维护双parser/checker。

**Phase 1 — compiler纵切**：按`Lexer/Parser → AST/diagnostics → resolver/modules → type/effect checker → TypedHIR/CoreHIR → FlowIR/ResourcePlanner/RcIR/certificate → C11 backend`移植；初期继续复用现有`ring_runtime.cpp`与C ABI。建立internal `host_support`层只映射确定容器、字符串/intern、Span、arena和稳定迭代顺序，不模拟Ring ownership/effect runtime，也不把host语言的内存模型当Ring语义。每个Ring源文件与selected-host module保留可追踪映射；先达到行为parity，再以独立commit做host-native重构。

**验收**：clean clone只依赖选型硬门产出的固定host toolchain/lockfile即可构建；三个spike与全量移植manifest无silent omissions；现有parser/type/effect/HIR/Core/ownership fixtures逐批转为host compiler parity测试；C输出继续链接现有runtime并通过compiler/hello与代表性single/project程序。#268/#269必须在单一FlowIR/ResourcePlanner/RcIR authority中闭合后才能标完成。self-host不属于B-205完成条件；只有外部compiler、规范和runtime稳定后另立用户决策里程碑。

---

## 类型系统


### B-001 Refinement Types [feature] [P2] [XL] [judgment] [queued] [after: B-193]
design.md 1.2。类型附带谓词，编译期静态验证 + 运行时检查兜底。

```ring
type Positive = Int where it > 0
type Email = Str where it.matches(r"^[^@]+@[^@]+\.[^@]+$")
fn divide(a: Float, b: Float where b != 0.0) -> Float { a / b }
```

- **当前状态 / 进入门**：refinement checker尚未实现。B-193先按2026-08-23用户决定删除struct-field `where`的parse-and-discard/W0002占位路径；完成后所有refinement clause在0.1均hard-fail，`where`仍保留未来关键字。本项不得先恢复parser/AST carrier：只有具名可判定片段、允许的runtime fallback、诊断与验证证据全部闭合时才原子开放语法和语义
- **前置依赖**：Phase B 模块系统稳定后启动
- **复杂度**：极大（SSA 约束传播 + 可选 Z3 集成）
- **优先级**：Phase C 首要
- **交互规则（B-043 决策）**：refinement 是值级谓词，不允许引用可变绑定；跨 effect/await 边界恒成立；handler resume 值须满足 refinement 约束；`mut` 参数带 refinement 时每次赋值重新验证（SSA 流分析，复杂度归入本 item）。详见 design.md 1.5
- **可判定片段条款（2026-06-12 D-5 拍板，公理⑤做实）**：SMT 查询限于**具名可判定片段**（QF_LIA + enum/bool 等式类，Liquid-style；具体片段定义 = lang-design §10 TODO「Refinement types 的可判定片段定义」，实现前必须完成）；超出片段 = 编译错误，要求显式 runtime check 兜底。**禁止 timeout 语义**——SMT timeout 即「耗时不可预期」，违反公理⑤
- **含 const generic 参数谓词**（2026-05-25，原 B-003 吸收）：refinement predicates 作用于 const generic 参数（如 `where N > 0`）归入本 item 的 SSA 约束传播。详见 design.md 1.3
- **验证架构约束（2026-07-28 竞品复查，Verus / `moon prove` 映射）**：
  1. checker 约束先降到独立、可打印、可缓存的 verification IR，再交给具名可判定片段的 decision procedure；proof/ghost 信息不得渗入 runtime ABI 或改变未启用 refinement 的 codegen
  2. 语言规范必须逐种数值类型声明谓词采用机器整数还是数学整数语义，以及 overflow/wrap/trap 的关系；**禁止以无界整数证明替代可能溢出的机器整数执行**
  3. 每次证明结果携带可审计 trust/assumption ledger：verification IR 指纹、算法/solver 及版本与配置、语言内 assumption/axiom/external specification、使用的整数/内存模型、资源预算
  4. solver 缺失、`unknown`、超预算或遇到不支持构造时不得静默视为已证明；只有规范明确允许的 predicate 才能生成显式 runtime check 兜底，其余 fail closed
  5. 相同输入、工具链与预算必须得到相同结果；缓存只按完整 proof fingerprint 命中，禁止把历史成功掩盖成当前成功
- **新增验收锚点（2026-07-28）**：正例/反例之外，至少覆盖 overflow 模型差异、assumption 可见性、solver 缺失/unknown、资源预算耗尽、proof cache 失效、runtime fallback 可观察性；每例同时断言 verification IR 与 ledger 稳定

### B-002 Drop / RAII Phase 2 [feature] [P1] [L] [judgment] [queued] [after: B-152+B-168+B-196]

Phase 1 的 scope-end Drop、move checker 和 drop glue 已完成；稳定语义见 design §7.6。当前只跟踪 C-native unwind 与 `Weak<T>`。

**约束**：消费 B-168 failure/control ABI；不得恢复 LLVM/C++/平台私有 unwind 或以 `volatile` 掩盖 C 语义。abort、normal/early return、nested catch/re-raise 与 evidence 失活共享 cleanup 模型；只 Drop 已初始化 owned 值。Weak 保持 scope-end/as-if 契约。failure edge 必须在 HIR/post-RC/生成 C 的稳定层可审计。

**验收**：单/多帧 abort、部分初始化、所有退出路径、Weak upgrade/最后强引用均恰好消费一次；B-165 转绿；完整 C e2e/golden、RC/ASan、自编译与 dist-c 固定点通过。

### B-110 非 Drop 类型别名追踪（资源管理 checker）[feature] [P1] [L] [judgment] [queued] [deferred: B-002]

> 2026-06-11 立项，2026-06-24 重新设计+拆分（Discussion）。**真值源 = design.md §7.4（2026-06-24 版）**。Drop auto-move 已移入 B-002（简单 consumed-flag checker）。本项专注非 Drop 类型的别名追踪 + mutation 推断。B-002 和 B-110 都完成后再做整体优化。

**设计决策（2026-06-24 Discussion）**：
- **mutation 判定完备性**：上线即全覆盖——赋值 = mutation；用户函数从函数体自底向上推断（mut 传播到签名）；extern fn 必须显式标注 `mut`（§7.3）。不接受渐进白名单
- **别名作用域**：默认到大括号结束。编译器可隐式缩小别名生存期至最后使用点（NLL 风格），精度取决于 NLL 设计探针结果
- **循环别名**：参考 Rust 规则，循环体内 mutation 使循环外别名在整个循环体内失效

**前置**：B-002（Drop/RAII，提供 Drop 类型信息用于 share vs move 分叉判定）+ NLL 设计探针

**涉及修改**：
1. **checker：mutation 推断（自底向上）**——分析函数体：binding/字段赋值 = mutation；调用 mutating 方法 = mutation（递归：callee 的参数已推断 mut → caller 该调用是 mutation）。0.1 index assignment已删除，List/Map mutation只通过显式`mut self` mutator进入本分析。推断结果标记参数为 `mut T`。extern fn 从声明读取 `mut` 标注
2. **checker：别名追踪 pass（§7.4）**——`let y = x`（非 Drop 复合类型）建立别名关系；对 x 的 mutation 使 y 失效；失效后使用 y = 编译错误（E07xx，`--error-format=llm` 含 `.clone()` 修复建议）。别名生存期到大括号结束，编译器可隐式缩小到最后使用点（NLL）
3. **调用点检查**——callee 参数推断为 `mut T` 时，caller 实参不能有其他活跃别名
4. **测试**：别名失效 E2E + mutation 推断 + `.clone()` 独立性 + 编译器自身零错误
5. **赋值边界**：binding/字段赋值必须覆盖mutation与alias失效；`grid[0][1] = v`等index assignment在0.1稳定hard-fail并由B-202 deferred，不进入本项的IR/codegen范围

**编译器自身迁移**：新模型下非 Drop 类型不 move，编译器现有的 `let y = x` 共享模式天然合规——无需大规模迁移。可能需要修复的只有 mutation-after-alias 站点（预期少量）。首步跑 checker 统计错误数。

**验收标准**：
- 别名失效：`let ys = xs; xs.push(1); print(ys)` → 编译错误
- mutation 推断：用户函数体 mutate 参数 → 签名推断 `mut T`；extern fn 声明 `mut` → 调用点检查别名
- 调用点别名安全：`let ys = xs; sort_in_place(xs)` → 编译错误（xs 有活跃别名 ys）
- `.clone()` 路径：`let ys = xs.clone(); xs.push(1); print(ys)` → ✅
- 编译器自身（31+ 文件）在新 checker 下零错误 + double bootstrap 一致
- 完整 C/native、checker 与自举回归通过

### B-072 Union Type（匿名 enum 语法糖）[feature] [P3] [M] [judgment] [queued] [after: B-175] [deferred: post-0.1-release]
`A | B | C` 作为匿名 enum 的语法糖。纯编译期展开，不引入子类型，HM 推断不受影响。详见 design.md 1.1b。

> **2026-08-23 用户复核**：2026-05-25匿名sum与2026-06-15 match消歧两次裁决继续有效；该能力有结构等价、自动注入和错误组合价值，不属于纯缩写语法糖。它不是0.1 urgent特性，实施明确顺延到首次0.1发布后，不为preview增加surface/IR工作。

**核心用例**：
1. 错误组合：`fail<IoError | ParseError>` — 消除手写包装 enum 的 boilerplate
2. Row poly 签名显示：`fn greet(person: User | Company)` — 单态化后的具体类型展示
3. 多类型参数：`fn process(x: Str | I64)` — 轻量级 sum type

**语义规则**：
- 展开为匿名 enum（tagged，同 enum codegen）
- 归一化：按类型名字典序、去重、扁平化
- 结构等价：两处 `Str | I64` = 同一类型
- 调用点隐式包装：传 `Str` 到 `Str | I64` 时编译器自动插入构造

**match 语法（2026-06-15 拍板）**：Union = 匿名 enum，variant 名 = 类型的非限定名，match 语法与普通 enum 完全一致（`Str(s) => ...`）。消歧规则：同名类型冲突时（如 `fs.Error | parse.Error`）要求用户写具名 enum，不支持匿名 union 含同名 variant

**涉及修改**：
1. `parser.ring`：类型语法支持 `A | B`
2. `types.ring`：`UnionType` 或复用 `EnumType` + 匿名 enum 生成
3. `infer.ring`：调用点隐式包装推断
4. `codegen.ring`：同 enum（tag + payload）

**验收标准**：
- `Str | I64` 可声明为参数/返回/变量类型
- `fail<IoError | ParseError>` 可编译，catch 可按类型 match
- 调用点自动包装
- 归一化 + 去重 + 扁平化正确
- 不影响 HM 推断
- 全部 E2E 测试通过
- 自举编译器正常编译自身

### B-033 GADTs（Generalized Algebraic Data Types）[feature] [P3] [L] [judgment] [queued]
无当前下游依赖；在 C 主路径和更高优先级类型系统工作稳定后再排期。
enum 变体可指定不同的返回类型约束，match 分支内编译器自动获得类型等式约束（完整方案：scoped unification）。

```ring
enum Expr<T> {
    Lit(Int): Expr<Int>,
    Add(Expr<Int>, Expr<Int>): Expr<Int>,
    IsZero(Expr<Int>): Expr<Bool>,
}

fn eval<T>(e: Expr<T>) -> T {
    match e {
        Lit(n) => n,                      // 分支内 T = Int，n: Int 满足 -> T
        Add(a, b) => eval(a) + eval(b),   // 分支内 T = Int
        IsZero(x) => eval(x) == 0,        // 分支内 T = Bool
    }
}

// 类型安全的异构列表
enum HList<T> {
    Nil: HList<Unit>,
    Cons(T, HList<U>): HList<(T, U)>,
}
```

**当前状态**：未实现

**前置依赖**：无硬依赖（但 union-find 需要扩展 snapshot/rollback）

**涉及修改**：
1. `ast.ring`：enum 变体声明扩展——`EnumVariant` 新增可选字段 `result_type: TypeExpr?`（`: Expr<Int>` 部分）
2. `parser.ring`：`parse_enum_variant()` 在字段列表后检查 `:` token → 解析返回类型约束。无 `:` 时为普通 enum（向后兼容）
3. `types.ring`：`EnumType` 的 variants 信息需要携带每个变体的类型约束（`variant_constraints: Map<Str, List<(Int, Type)>>`——类型参数 → 具体类型的绑定）
4. `infer_register.ring`：注册 enum 时，对有返回类型约束的变体，解析约束并验证——约束必须是 enum 自身的实例化（`Lit(Int): Expr<Int>` 中 `Expr<Int>` 是 `Expr<T>` 的实例化，绑定 T=Int）
5. `union_find.ring`：新增 `snapshot() -> Snapshot` 和 `rollback(Snapshot)` 方法——记录当前状态，分支结束后恢复
6. `infer.ring`：match 表达式推断时，若 scrutinee 类型是 GADT enum：
   - 每个分支进入前 `snapshot()`
   - 从变体的类型约束提取等式（如 T=Int），调用 `unify()` 注入
   - 推断分支体
   - 分支结束后 `rollback()` 撤回约束
   - 各分支返回类型在原始（未约束）环境中统一
7. `codegen`：GADT 是纯编译期约束；lowering 复用共享 enum HIR，不新增后端专用语义

**交互规则（design.md 1.5）**：
- GADTs × Or-Pattern：or-pattern 合并的 GADT 变体必须携带兼容的类型等式，不兼容则编译错误
- GADTs × Effects：正交，无需特殊规则（scoped type equality 是编译期，evidence 是运行时）

**验收标准**：
- `enum Expr<T> { Lit(Int): Expr<Int> }` 语法可解析
- match 分支内类型等式自动生效——`eval` 函数可类型检查通过
- 无返回类型约束的 enum 变体行为不变（向后兼容）
- 类型约束与 enum 类型不匹配 → 编译错误（如 `Foo(Int): Bar<Int>`）
- 分支约束不泄漏到分支外
- 穷尽性检查对 GADT enum 正常工作
- or-pattern 合并不兼容 GADT 约束的变体 → 编译错误
- 全部 E2E 测试通过
- 自举编译器正常编译自身

### B-006 `dyn Trait`（动态分发）[feature] [P3] [L] [judgment] [queued]
运行时多态，默认静态分发（泛型单态化），`dyn` 是主动选择动态分发的标志。

```ring
fn process_all(items: List<dyn Describable>) { ... }
```

- **当前状态**：未实现
- **前置依赖**：无硬依赖
- **优先级**：Phase C 或 D

### B-038 高阶类型抽象选型：GAT vs 受限 rank-1 HKT [design-align] [P3] [M] [judgment] [queued] [after: B-169]

> **2026-07-29 Discussion 修订**：此前草案把 GAT 当成已选方案，并以“effect system 覆盖 Monad 主要用例”解释低优先级。现纠正为：GAT 只是 HKT-lite 候选，仓库从未完成 GAT vs HKT 的正式 Argument；effect 可覆盖直接风格的常见 Monad sequencing，但不能在理论上替代所有显式计算载体与高阶类型抽象。B-038 先做选型探针，不在选型前保留任何一方为默认实现方案。

**目标**：比较两种可判定、可推断的最小高阶类型能力，选择符合“类型即模型 / 推断为王 / 编译器必须终止”的公开语义：

1. **GAT / associated type family**：沿用现有 trait + associated type，允许 `type F<A>` / `Self::F<A>`；核实是否需要人为 witness/tag type，以及 projection 归一化、owner 歧义和 dictionary 传播成本。
2. **受限 rank-1 HKT**：只允许一阶 constructor 参数（首要 kind 为 `Type -> Type`，不引入 higher-rank type quantification 或 kind polymorphism）；核实 `F<A>`、`Result<E, _>`、必要的受限 partial application/type alias，以及 kind inference 与 trait resolution 的终止边界。

完整 System Fω、任意 type-level lambda、kind polymorphism 和高阶 unification 不在候选范围；若探针证明最小用例必须依赖其中任一能力，须显式报为超范围，而不是静默扩大语言。

**共同 probe corpus**：

1. lending / streaming iterator：输出类型随调用参数变化；
2. `Functor.map` 与 `Applicative/Monad.traverse`；
3. Parser 与 Validation（累积错误 vs 短路错误）；
4. `Result<E, _>` 的部分应用；
5. `Compose<F, G>` 或等价的两个 constructor 组合；
6. B-169 选定的 effect-polymorphic trait 方法与显式计算载体交叉案例。

**评估门**：

- lv0 常见用例零额外标注；失败诊断能在单轮指出缺失 kind、歧义 owner、无法归一化 projection 或不满足的 trait；
- 类型推断、kind 检查、instance resolution 与 normalization 有具名可判定片段和 fuel/深度边界，不依赖 timeout 语义；
- 对模块导出、关联类型等式、单态化、mangling、dictionary/effect evidence、HIR 与 C ABI 的影响可枚举；
- 对每个候选给出至少一个主动反例，不能只比较正向语法长度；
- 不以“effect 已取代 Monad”否决 HKT，也不以“抽象更统一”豁免 Ring 的推断与诊断公理。

**产出 / 验收标准**：

- 同一 probe corpus 的两候选类型、必要标注、预期诊断和编译器改动矩阵；
- 明确推荐、否决理由、仍未知项及后续实现复杂度；若结论改变公开类型语法或语义，形成用户决策 dossier；
- 选型拍板后把 B-038 重写为可执行 implementation spec（或删除并新建实现项），不得把当前探针文本直接当实现规范；
- 调研本身不改变 main 的公开行为，`python .agents/scripts/validate_workflow.py` 通过。

### B-170 bounded generic + 空容器字面量的 bound 求解时序（E0503 误报）[bugfix] [P2] [M] [judgment] [queued]

> **0.1 internal-checkpoint处置（2026-08-30 用户决定）**：compiler/std/examples的exact self-host trigger为零时，本项不再运行独立focused验收或阻塞#268/#269；保留现有复现与`set_new()`、concrete helper或非空input workaround，随B-183导入GitHub Known Issues。若唯一self-host交易实际命中，才按当前failure class恢复修复。

2026-07-31 B-107 wave 收尾归因立项。**主复现（通用形态，2026-07-31 于 B-107 tip 双重验证仍触发）**：`fn count_tags<T: Marker>(items: List<T>)` + `count_tags([])` → E0503 'Marker'。根因：`resolve_dicts_from_scheme`（infer_ctx.ring:1306-1356，行号=立项时）对未解 TypeVar 的 trait bound fail-closed，而该求解发生在 let 注解双向传播之前——**带了显式注解也无法单轮修复**（`let s: Set<Int> = set_from([])` 同报），违反公理①「错误单轮可修」。main 既有 checker 通用限制，非 Set 特有；b973859 给 `set_from` 加 `T: Hash+Eq` bound 后被 `set_ops.ring` 撞出（该用例经 runner `CHECK_BLOCKED_POSITIVE_GAPS` skip 挂本条，注意验证时编译器必须是含 bound 版 std 的分支/merge 后编译器——main 旧 std 无 bound 不触发，勿误判「已修复」）。

- **修复方向**（实施时 Argument 二选一）：bound obligation 延迟到 zonk/注解传播后再解；或 let 显式注解先行双向传播再触发 dict 求解。不得对空容器做特殊 case 硬编码。
- **验收**：`set_ops.ring` pending 解除转绿；`let x: List<T具体> = []` + bounded HOF 正反用例；不回归既有 E0503 真歧义报错（无注解、无任何类型来源时仍应报）。
- **依赖**：B-107 merge 后（`set_from` 签名与 pending 标记在其分支上）。

### B-149 Display trait + 字符串插值类型约束 [feature] [P2] [M] [judgment] [queued]

插值目前只安全支持 Str/Int/Float/Bool；其他类型在 Display evidence 可用前由 checker 拒绝。

- `trait Display { fn display(self) -> Str }`；基本类型内置 impl。
- `"${x}"` 要求 Display；缺失时建议 derive 或手写 impl。
- Debug 面向开发者，Display 面向用户；均返回 fresh-owned Str。
- checker/derive/共享 HIR/C codegen/std registry 统一消费 Display，queued 阶段不保存后端文件清单。

**验收**：基本类型不变；struct/enum 有无 Display 正反例；direct/HOF/跨模块 evidence；完整 C/RC/self-host 门通过。

## Effect 系统

### B-007 `async` Effect + 结构化并发 [feature] [P2] [XL] [judgment] [queued] [after: B-116]

- `async` 是 effect；handler 决定执行策略。
- spawn 只能在 structured scope；正常退出等待，异常/提前退出取消，不提供 detach。
- 取消只在 await 点以 `Cancelled` fail 注入；同步区段不被打断，可 catch 补偿。
- effect/trait/Drop/evidence 复用 B-168/B-169 ABI。

B-116 先以 native probe 选 lowering；归档 JS generator/Promise 不属于 spec。planning 时按 C-only main 定文件。

**验收**：sync/production handler、nested scope、spawn/await、取消补偿正反例；scope 外 spawn 报错；退出不遗留任务/owned 资源；完整 native/RC/ASan/self-host 门通过。

### B-156 extern fn 声明处 `requires {unsafe}` 签字检查 [feature] [P1] [M] [judgment] [queued] [after: B-195]

> **2026-08-23 用户决定，已拍板 clean break**：文件本身是隐式模块。0.1新增一个可选文件头`requires {effects}`，必须是第一项非注释语法、每文件至多一次，并与`mod name requires {effects}`共享同一解析、typed capability与checker authority。拒绝逐声明`unsafe extern fn`第二套语法。立项时current main census为78个extern fn/10个文件；实施时重新机械census，不把旧327/19计数当迁移真值。

**公开语义**：

1. `Program ::= FileRequires? UseDecl* Decl*`，`FileRequires ::= 'requires' EffectSet`；header晚于`use`/声明或重复出现均稳定报错。
2. 有header时，它是文件模块的effect ceiling，`requires {}`表示纯模块；无header时system/handled/fail/mut不增加额外ceiling，但unsafe许可从不隐式获得。
3. unsafe原语仍必须由`unsafe {}`逐块discharge；header只提供模块许可，不能替代责任签字。
4. 每个`extern fn`声明要求其有效文件/inline-module requires集合显式包含`unsafe`。声明是ABI签字，调用点保持safe；extern type不因本项变成unsafe操作。

**范围 / 唯一authority**：`compiler/parser.ring`/AST与模块resolver/checker建立文件header并把它运输为与inline mod相同的typed capability fact；B-195后的SystemEffectRef/HandledEffectRef/fail/mut/unsafe全部复用同一集合检查。仓内compiler/std/examples/tests按实际推断effect迁移header；不能给所有文件机械只写`{unsafe}`而误拒其真实console/fs/process/fail/mut。`ring audit unsafe`枚举文件/inline capability许可、unsafe discharge block与extern声明，禁止另建extern叶名白名单或backend fallback。

**验收标准**：

- header第一项/重复/late/empty/qualified/custom effect的parser与human/LLM诊断矩阵；无header普通effect正控、`requires {}`与受限集合负控、single/project/inline nesting一致；
- 无显式unsafe许可的unsafe block或extern fn声明稳定失败；有许可的raw-memory与全部仓内extern声明通过，普通extern调用点不染unsafe；
- mutation杀死header skip、unsafe隐式授权、extern特判、file/inline双checker与system→handler evidence；inspection/audit只消费typed capability authority；
- 完整C e2e/golden/RC/structural/parity/self-compile、targeted audit output、double bootstrap与tracked`dist-c`literal fixed point通过，workflow validator与exact CI全绿。

### B-168 C-native abort/unwind 实现模型探针 [design-align] [P0] [M] [judgment] [queued] [after: B-180+B-195+B-196]

> 2026-07-29 Discussion 用户拍板 P0/M、保持两候选中立实测。LLVM 已退役，B-002 Phase 2 原定的 `invoke`/`landingpad` 路径失效；现行 `setjmp`/`longjmp` 又已由 B-165 证明存在跨 catch 局部写入不可见问题。B-169/B-167 随后还会决定 effect/type evidence 的共享边界并改变 effectful function value evidence ABI，因此必须先确定共同的 C-native failure/control ABI，避免各项工作重复改写控制流、closure prototype 与 RC 证据面。

**目标**：以最小但真实的垂直切片比较两种可移植 C11 实现模型，不在立项时预选赢家：

1. **编译器生成 cleanup stack + `setjmp`/`longjmp`**：raise 沿显式 cleanup record 逐帧执行 Drop，再跳转到 catch；核实 frame 生命周期、部分初始化、局部写入可见性与 callback/FFI 边界。
2. **显式 failure-status/continuation lowering**：仅对可能 fail 的函数增加显式失败返回/continuation 路径，逐调用点传播并在边上执行 Drop；纯函数 ABI 不承担额外参数。核实跨模块/间接调用/effect row 单态化如何稳定标注 fail-capable prototype。

平台私有 unwind、SEH-only、C++ exception 或重新依赖 LLVM 均不进入候选集：它们扩大 TCB、破坏 C11 可移植性，也与现行 C-only 后端契约相反。

**必须回答的问题**：

1. 正常返回、early return、单帧/多帧 raise、部分初始化、nested catch/handle、handler evidence 失活、re-raise 下，每个 owned 值能否恰好消费一次。
2. B-165 是被模型结构性消除，还是仍需精确 boxed-vars；禁止以 `volatile` 或全量装箱回避 C 标准语义。
3. B-167 的动态 evidence 如何穿过 direct call、closure、跨模块、泛型 HOF、递归/互递归，而不制造第二套不兼容 function-pointer ABI。
4. cleanup/failure edge 能否在 HIR、post-RC 或生成 C 的稳定层次由 `verify_rc` 机器审计。
5. `main`、未捕获 fail/panic、extern C、Ring→C callback→Ring 重入各自的 ABI 与退出语义。
6. 同一生成 C 是否在 Windows Clang、Linux Clang/GCC 的 C11 模式成立；平台差异必须被隔离在最小 runtime 边界。

**探针范围 / 文件所有权**：

- 共享层：`compiler/hir.ring`、`compiler/perceus.ring`、`compiler/verify_rc.ring`
- C lowering：`compiler/codegen_c.ring`、`compiler/codegen_c_expr.ring`、`compiler/codegen_c_runtime.ring`
- runtime：`ring_runtime.cpp` 或后续 RIIR 承接该边界的 C runtime 文件
- 证据：`tests/cases/` 的最小程序、Python runner 与生成 C/汇编/对象尺寸记录
- 两候选原型必须位于隔离 worktree/实验分支；**不得把任一候选的行为改动并入 main**

**验收标准**：

- 两候选运行同一组最小程序，覆盖上述六类问题；生成 C 与 failure/cleanup trace 一并归档。候选若不可行，必须给出最小复现、编译器诊断/崩溃或 C 标准约束等可复核证据。
- 固定源码 commit、编译器版本、target 与 flags，测量正常/失败微基准、生成 C/对象尺寸，以及一次编译器 self-compile 的 build time、run time 与 peak memory；性能只作决策输入，不替代正确性。
- 形成 TCB、跨平台性、B-165 处置、B-167 ABI、Perceus/`verify_rc` 可审计性和迁移复杂度矩阵，明确推荐、否决理由与仍未知项。
- dossier 完成后转 `waiting-feedback` 由用户拍板；root 随决策重写 B-002 Phase 2，并把 B-165 标为结构性关闭/验证项或精确实现项；随后启动 B-169，以已固定的 failure/control ABI 为输入，再由 B-169 结论细化 B-167 的共享 ABI。探针条目随后按工作流删除。
- main 分支行为零变化；`python .agents/scripts/validate_workflow.py` 通过。

### B-169 Effect system × trait/type system 融洽性探针 [design-align] [P1] [M] [judgment] [queued] [after: B-168] [before: B-167+B-038]

> **2026-07-29 Discussion 用户决定**：单独立项、择期执行，覆盖内部实现与用户面；目标不是把 trait 与 effect 强行合成一个概念，而是让两套体系在组合处没有语义、推断、诊断或 ABI 接缝。排在 B-168 之后，是为了先固定 failure/control edge；排在 B-167 之前，是为了避免 effectful function value ABI 在未审视 trait dictionary 交互前再次固化。B-167 已拍板的“调用点动态 evidence”目标语义不在本项重开。

**必须保持的语义边界**：

- trait/type-class evidence 回答“某个类型采用哪个实现”，默认要求静态可见、coherent、可终止的 instance resolution；
- effect handler evidence 回答“当前词法/动态 handler scope 如何解释操作”，允许局部覆盖、effect 消除及受控的 abort/tail-resumptive 控制行为；
- `console/fs/process`等SystemEffectRef只作静态HostImport capability，永不进入本项的evidence统一候选；任何候选把它们变为implicit/root handler即被B-195直接否决；
- 可以共享编译器 substrate，但不得因实现统一而把普通 trait 调用误报为 effect、让 `Eq` 等 instance 被 handler 任意改写，或让 handler 退化成全局 instance；
- effect row 与 trait bound 都是公开能力真值，任何优化或 lowering 不得静默丢失、合并或臆造 evidence。

**内部实现调研**：

1. 固定并比较三种真实候选：①共享 typed evidence substrate、保留两套表面语义；②两套 lowering 独立但以单一 typed interop contract 连接；③以 capability/implicit parameter 统一部分用户面。不得预选赢家，需主动攻击共享过度与分离过度两端。
2. 核查 `TypeScheme`/trait bounds、effect rows、associated types、default trait methods/custom effect ops 在 inference、generalization、SCC rebind、HIR lowering 与 module export 中的约束求解顺序；明确 principal-type、coherence、determinism 与 termination 条件。
3. 比较 dictionary 与 effect evidence 的 identity、参数排序、direct/indirect call prototype、closure capture、跨模块导出、泛型单态化、递归/互递归转发和默认 evidence 注入；判断哪些元数据必须成为 `hir.ring` 的共享契约，哪些必须保持分域。
4. 明确 evidence 的 borrow/owned 生命周期及 Perceus/`verify_rc` 可审计边界；结合 B-168 的 normal/failure edge，证明 nested handler、early return、re-raise 与 callback 重入不漏传、不双 drop、不悬垂。
5. 以 B-167 的外部 callback 调用点动态截获为硬案例，验证 trait-bounded callback 同时携带 dictionary + open effect tail 时不会形成两套不兼容 function-pointer ABI。

**用户面调研**：

1. effectful trait method、effect-polymorphic trait method、带 trait bound 的 effect-polymorphic HOF、handler 内调用 trait method、default trait method 调 custom effect；
2. associated type 出现在 effect payload/operation return、effect alias 与 trait bound 同时量化、跨模块公开签名与 formatter/LLM 诊断；
3. handler override 与 trait instance selection 的概念边界：相同拼写、默认实现、局部覆盖、缺 evidence 和歧义时是否“一种事一种写法”；
4. 显式计算载体（Parser/Validation/Future 等）与 ambient effect 的互操作；把结论输入 B-038，但不预设 GAT 或 HKT；
5. 对每种候选记录用户必须理解的概念数、常见签名标注量、错误定位轮数与迁移成本，不只比较实现代码量。

**固定 probe matrix**：

- `T: Show` + `fn(T) -> U with ?e` 的 callback 同时转发 dictionary 与 open effect tail；
- `T: Iterable` 的 `T::Iter: Iterator` 嵌套 associated evidence，覆盖 `iter` / `next` dictionary、Item 一致性与跨模块转发；
- default trait method执行custom handled effect，handler arm调用trait method；
- associated type 作为 effect op 的参数/返回值，含 owner-qualified 跨模块路径；
- 外部创建 closure 进入 nested handler，覆盖 direct/indirect、泛型 HOF、递归/互递归与 re-export；
- handler arm/catch arm 内的 trait dispatch、early return/re-raise 及 RC evidence 生命周期；
- Parser/Validation/traverse 各一个用户面案例，用于区分 ambient effect 与显式 computation carrier。

**涉及文件 / 模块**：`docs/design.md`、`docs/lang-spec/{type-system,traits,effects}.md`；事实核验读取 `compiler/types.ring`、`infer*.ring`、`hir.ring`、`dict_lower.ring`、`codegen_c*.ring`、`perceus.ring`、`verify_rc.ring` 与相关 `tests/cases/`。实验只允许在隔离 probe 分支产生，不把任一候选实现并入 main。

**产出 / 验收标准**：

- 内部 evidence pipeline 图、用户概念/签名矩阵、三候选的正确性/推断/诊断/ABI/RC/迁移比较，以及每个推荐点至少一个反例；
- 固定 probe matrix 有当前实现证据与候选预期；无法由现状运行的案例必须给出最小不可表达点，不能以纸面“应当可行”代替；
- `docs/design.md` 写入明确推荐、保留语义边界、否决理由与未知项，并据此重写 B-167/B-038 的前置契约；
- 若推荐涉及新的公开语法、instance coherence、handler 选择规则或 breaking ABI，形成用户决策 dossier，不在调研项内擅自实施；
- 本项只调研，不改变 main 公开行为；`python .agents/scripts/validate_workflow.py` 通过。

### B-167 effectful function value 调用点动态 evidence ABI [refactor] [P0] [L] [judgment] [queued] [after: B-168+B-169]

> 2026-07-28 Discussion 用户拍板“先 C 后 A”。audit #258 先以创建处词法 evidence 收口 checker soundness：handler 只消除显式 custom label，未知 open tail 原样向外传播。LLVM 已退役、`dist-c/` 已成为唯一 bootstrap 锚。**2026-07-29 前置更新**：B-168 必须先拍板 C-native failure/control ABI；B-169 随后固定 trait dictionary / effect evidence 的共享边界与用户面不变量。本项必须同时复用两者的 function-pointer、failure edge、typed evidence 与 RC 契约，不得另造平行 ABI。

> **2026-08-23 system/handled 边界**：本项只处理`HandledEffectRef`的调用点evidence。`console/fs/process`等`SystemEffectRef`永不进入closure/evidence ABI，也不能被handler动态换绑；mock-fs等案例中的可替换抽象必须是用户custom effect，生产adapter再调用system API。

> **2026-08-28 用户批准 R1 前移**：本项的custom handled-effect function-value完整纵切已作为#268/#269的直接Core/ABI前置立即实施，不再等待B-168/B-169，也不保留创建处lexical capture过渡路径。前移范围仅限ordinary callable hidden evidence、direct/method/indirect调用点传参、closure prototype/slot、borrow生命周期与对应Core/Flow/Rc/ABI验证；failure/control和trait/effect其余研究仍受heading依赖约束。本条完成后，B-167只保留尚未被R1覆盖且由B-168/B-169结论决定的残余工作，不能重复建设第二套ABI。

**目标语义**：effectful function value 在调用点接收当前 effect evidence。外部创建的 callback 传入 `with_mock_clock` / `with_mock_fs` / `capture_logs` 等高阶 handler 后，其 effect 由调用点内层 handler 截获，而不是继续使用 callback 创建处的旧 evidence。静态 effect row 仍是 capability 真值；调用点只传递签名要求的 evidence，未知 open tail 必须逐项转发，不能被机械消除。

**涉及修改**：
1. TypedHIR / function type lowering：先完成effect generalization，以稳定`EffectParamRef`固化effectful function value与调用点的effect/evidence参数布局，覆盖closed row、formal open row、泛型effect row、递归与互递归closure；raw inference tail不得进入Core，共享布局helper，禁止codegen按字符串猜参数顺序。
2. C 后端：按P2统一所有Ring callable的`EffectCtx*` prototype、closure构造、direct/method/indirect调用、跨模块声明与runtime builtin；pure/system-only传empty ctx，foreign leaf不接收。
3. FlowIR / ResourcePlanner / RcIR：明确 evidence 参数为 borrow 还是 owned，验证env capture、转发、嵌套handler和early return的Clone/Take/Drop平衡；Planner不求解effect，不得通过泄漏evidence规避生命周期问题。
4. 迁移与诊断：把 C → A 作为 breaking change 记录；若旧代码依赖创建处 handler，诊断应指向 callback 创建/调用边界并给出显式 capability 或重构建议。
5. 测试：新增外部 callback 动态截获、handler 内创建 callback、嵌套 handler、多 effect、open-tail 转发、跨模块 callback、泛型 HOF、递归 closure 及 RC/负面回归。

**验收标准**：
- 外部创建的 `Clock` callback 传入内层 fake-clock handler 后使用内层 evidence；同类 mock-fs、capture-logs 形态有正式回归。
- 显式 effect 被当前 handler 消除，未知 open tail 和未处理的其他 effect 精确向外传播；不出现 capability 漏报或错误消除。
- 直接调用、间接 closure 调用、跨模块与泛型 HOF 使用同一共享 ABI 契约；C 生成物的 function-pointer 声明与调用实参一致。
- RC verifier、定向 ASan、完整 C E2E/golden、自编译与 `dist-c` 文本固定点通过；CI bootstrap 在 clean clone 上通过。
- main 不重新引入 LLVM-C、`dist-llvm` 或双后端兼容层；迁移说明明确记录 C → A 的行为变化。

### B-194 删除用户 effect default operation body / 自动 evidence [design-align] [P1] [L] [judgment] [queued] [before: B-195+B-168]

> **2026-08-23 用户决定，已拍板 clean break**：0.1 custom effect operation只有签名，必须由显式`handle...with`解释。删除op body、部分默认、自动default evidence与默认依赖图。Source trait default body已由2026-08-30 convergence batch独立删除；B-197只重审effect default provider，不恢复trait body。

**范围**：parser/AST删除EffectOp body surface；checker/env/HIR删除`has_default`、default body检查/拓扑/循环与自动evidence发布；CoreHIR/ExecutableInventory/visitor不再把effect default当body root；legacy Perceus/verifier/codegen删除default body transport、global evidence init、main注入与fallback。退役相关诊断、fixtures、structural/mutation authority，不保留inert字段或兼容分支。

**约束**：custom effect、tail-resumptive显式handler、effect alias、trait/effect identity与B-167目标继续保留。无body op在未处理时必须fail loud；不能把默认实现改名为隐藏stdlib/runtime fallback。当前compiler/std/examples无真实default-op consumer，tests按新边界原子迁移。

**验收**：operation body稳定parse error并给显式handler建议；无default/evidence-init symbols、fields、visitor arms或main hook残留；显式custom handler正反例、nested/HOF/cross-module/evidence RC不回归；mutation杀死任何自动注入或未处理放行。完整C/full/RC/ASan/self-host/fixed-point与exact CI通过。

### B-195 SystemEffectRef / HandledEffectRef 与 host capability 原子切换 [design-align] [P1] [L] [judgment] [queued] [after: B-194] [before: B-168+B-169+B-167+B-152+B-156+B-174]

> **2026-08-23 用户决定，已拍板 clean break**：删除宽泛special`io`与root-handler设想。0.1 effect atom分为`SystemEffectRef(console/fs/process)`和`HandledEffectRef(custom)`；system不进evidence、不可handle、无main注入，只经AbiIR HostImport/link provider执行。Failure/mut/unsafe维持独立规则。

**唯一authority / pipeline**：

1. prelude/std host extern/intrinsic声明产生exact capability identity、callee/ABI symbol、参数返回与现行failure contract；当前无网络/时钟/随机API，不预造相应effect；
2. ResolvedAST/TypedHIR保存typed effect class与SymbolRef，alias展开、re-export、HOF/open row不改变class；
3. CoreHIR/FlowIR/RcIR中system call是普通exact call且零evidence，handled operation才进入call/evidence graph；
4. AbiIR唯一生成HostImport；native C链接runtime symbol，未来WASM/embedded只替换provider，不在compiler/main建立root handler；
5. `ring inspect`/module requires/未来package policy消费transitive system capability与exact HostOp清单，不冒充OS sandbox。

**0.1 surface / 迁移**：初始`console`覆盖stdout/stderr，`fs`覆盖文件读写/exists/delete及依赖filesystem/cwd的resolve，`process`覆盖argv/cwd/exec/exit；纯path string操作保持纯。原`io.read/write`与无effect`std/fs`/`std/process`双路径收成一个公开operation authority，special`Effect::IoEffect`、`io`alias与按叶名runtime mapping全部删除。Capability与`fail<E>`正交；本项不凭空发明error payload，B-168按已枚举HostFailureInventory固定可恢复failure ABI。

**验收**：system→evidence、system被handle、handled→HostImport、root/main注入、name fallback五类mutation全杀；全部host extern不再假纯，纯path负控不染effect；single/project/re-export/HOF/alias/module-requires/inspection一致；native HostImport exact，C emitter无host leaf switch。完整C/full/RC/ASan/self-host/fixed-point与Windows/Linux exact CI通过。

### B-196 0.1 effect-free Drop 边界 [design-align] [P1] [M] [judgment] [queued] [before: B-168+B-002]

> **2026-08-23 用户决定，已拍板 clean break**：0.1用户`Drop::drop`最终推断effect row必须为空；system/handled/fail/逃逸`mut<T>`均禁止。编译器生成的字段递归释放、RC deallocation与已验证intrinsic cleanup不属于用户body。0.1不建`DropEffectSet`或latent carrier；post-0.1由B-198重审。

**范围**：Drop trait/impl检查从宽泛`with {io}`改为closed `{}`；任何推断effect给单轮可修诊断。迁移effectful Drop专项fixtures，保留pure Drop的auto-move、Clone冲突、顺序、提前drop与generated glue；B-168/B-002仍证明pure Drop在normal/return/break/catch/unwind全部路径恰好一次。

**约束 / 验收**：不得通过不标extern、unsafe/root/system call或backend special-case隐藏effect；不新增empty DropEffect metadata。Pure generic/recursive/field Drop与StringBuilder继续工作；system/custom/fail/mut负例全拒绝；完整RC/ASan/full/self-host/fixed-point与exact CI通过。

### B-197 Post-0.1 default effect provider 重新设计 [design-align] [P3] [M] [judgment] [queued] [after: B-175] [deferred: post-0.1-release]

用户确认default provider有真实便利性，但0.1不为零consumer保留旧实现。首次0.1发布后正式重审，使用Logger/Storage/配置provider等具体场景比较operation内body、显式具名provider与普通wrapper/adapter；衡量用户概念、partial override、依赖可见性、CoreHIR closure、evidence生命周期和diagnostic。任何推荐均形成新的用户decision dossier；禁止直接恢复B-194删除的global init、checker hydration、默认依赖图或兼容surface。

### B-198 Post-0.1 effectful destruction / latent contract 设计 [design-align] [P3] [L] [judgment] [queued] [after: B-175] [deferred: post-0.1-release+real-host-resource]

只有真实File/Socket/Transaction等RAII consumer出现后启动。比较effectful Drop、显式`close()`+pure safety-net Drop及组合；若采用latent destruction contract，必须给出generic/recursive field effects的有限fixed point、ownership-mode依赖、TypedHIR freeze前effect可见性、all-exit ResourcePlanner witness、failure禁止/能力边界与AbiIR规则。不得在0.1预建`DropEffectSet`、空字段或让system HostImport从隐式Drop绕过effect row。

## RIIR

### B-152 RIIR 标准库收尾 [feature] [P1] [L] [judgment] [queued] [after: B-195]

List/Map/Set/StringBuilder 与 Str runtime 布局 Step 1 已完成；只剩 Str Step 2 与 P5。

**Str Step 2**：`Type::StrType` 收口为普通 StructType；`std/str.ring` 提供 Ring Str/Drop，方法迁 Ring，C 只留字面量/FFI 最小 bridge。保持 UTF-8 byte-string、显式长度、NUL 兼容、binary-safe 与 extern marshalling；不得按叶名猜 ABI；double bootstrap 证明固定点。

**P5**：删除无 anchor 消费者的 shim/STL；runtime 改纯 C + clang，只留 RC/typeid/drop、AbiIR HostImport provider、fail/control、Ptr/raw-memory 与初始化。System effect分类不在runtime重建。

**验收**：Str/插值/FFI/容器全绿；runtime 无 STL/placement-new/已迁移符号；完整 C e2e/golden/RC/ASan/self-host、double bootstrap 与 dist-c 固定点通过。

## 迭代与集合

### B-095 List.enumerate 方法 [feature] [P3] [S] [mechanical] [queued]

纯 Ring `List.enumerate() -> List<(Int, T)>`。在 std/list 实现；必要时最小更新 builtin registry；不得恢复 runtime/codegen 映射。

**验收**：空/嵌套列表、所有权和 for destructure 正确；完整 C E2E/self-host 通过。

### B-171 裸名同名 enum variant 歧义收紧 [design-align] [P2] [M] [judgment] [queued] [with: B-172]

裸名命中同帧同名 variant → 编译错误并列出全部候选、要求 qualified 消歧；声明同名与 qualified `E::V` 合法。随 B-172 实施。

- **实施**：新 E07xx 错误码；resolver value lane 的 enum-leaf last-wins shadow（`same_frame_seed_enum_leaf_shadow` 归约路径）改为 ambiguous 标记 + 裸名使用点报错，qualified 与单 payload 路径不受影响
- **回归翻转**：`tests/cases/enum_leaf_shadow_last_wins.ring`（头注释已预告翻转）与 `project_namespace_same_frame_enum_leaf_shadow` 改为负例
- **验收**：错误列全部候选 + qualified 建议（单轮可修）；qualified 寻址正反用例不回归；编译器自身源码（HExpr::Call/FieldAction::Call 共存、全 qualified 使用）继续零错误

### B-172 C′ exact dependency pipeline 主体（discovery/authoritative 两 context）[design-align] [P1] [L] [judgment] [queued]

Unit 3 已抽出 `ResolvedNamespacePlan`；本 spec 自含。

**硬约束**：①修 TuplePattern provisional local 假边；②alias/qualified call 元数据由 resolved DefId 追 ultimate origin并清陈旧 impl seed；③relative import 只由 canonical resolver 产 structured plan，所有阶段共同消费；④discovery incomplete 不可信，authoritative 无用户错误时 internal hard-fail；⑤一次 discovery + 一次 authoritative + `O(NP+F+E)`，禁 sweep。

discovery 每 top/inline Fn best-effort 一次，只携带 AST/index、canonical import、owner/origin、Ident census 与 exact edges；所有 ctx state 丢弃。fresh authoritative 独立注册/derive/seed，按图每 Fn 一次，Test 延后；module frame 完整恢复全部 namespace/ctor/mut metadata。范围不扩到 ConstGetter、default body、Impl、外部 module 或 impl/mutual SCC。

G1 inline relative import、G2 single-file plan 按 staged NOTES 激活；Param.default_value 进入 census/edge。验收覆盖 alias/re-export/default/HOF/shadow/pattern、check-count=1、layout/capability、W0001=0。audit #259 原场景已在 `4f6f186` 确认由 Unit 3 delta journal 修复并补齐正负回归，finding 已关闭。

### B-173 结构容器 Hash / Eq evidence 扩展：Option / tuple / List [feature] [P2] [M] [judgment] [queued]

2026-07-31 B-107 merge review concern：`Option<T>`、tuple-as-key、`List<T>` 字段无 Hash evidence（`resolve_hash_field_action` 覆盖集不含；`resolve_dict_ref_for_type` 对 TupleType 走 builtin 名失败），fail-closed 正确（E0503 拒绝）但含这些字段的类型进不了 Map/Set。结构化 tuple equality wave 已关闭 audit #221 的直接 `==` wrong-code；但 tuple 作为泛型 `T: Eq` 实参仍因缺少 `TupleType` DictRef 而被 E0503 拒绝，属于同一 capability gap。

- **修复方向**：为三类内建结构提供结构化 Hash evidence，并为 tuple 提供可传入泛型 `T: Eq` 的结构化 Eq DictRef；复用直接 tuple equality 的结构分解路径
- **验收**：三类字段的 struct/enum 进 Map/Set 正反用例；tuple 的泛型 Eq 正负例、manual element Eq 与嵌套结构；Float 嵌套仍拒绝；C-native、structural、RC 与 self-host 门一致

### B-133 UTF-8 字节串模型落地 [feature] [P1] [L] [judgment] [queued]

真值为 design §1.7.1：默认 Str API 使用 UTF-8 byte 单位；code point/grapheme 用显式 API。统一 len/index/slice/iteration、literal、StringBuilder、FFI/std 边界与 fail-loud 诊断，保持 binary-safe/NUL ABI/RC；planning 时按 C-only main 定文件。

**验收**：ASCII、BMP、非 BMP、组合字符、embedded NUL、非法 boundary、跨模块/FFI；规范/std/生成 C 一致；完整 C/RC/ASan/self-host 门通过。

## 性能优化（愿景：语义驱动的编译优化）

> **核心论点**：Ring 的类型系统（effect + refinement + linear）不仅用于安全性，还为编译器提供其他语言没有的优化信息。性能是 Ring 的核心卖点之一——目标不是"接近 C++/Rust"而是在特定场景**超越**。
>
> 优化分 AOT 与远期运行时 PGO/JIT 两层；当前先稳定 C 主路径、Perceus RC 与可复现性能基线。

### B-079 Perceus Reuse Analysis / FBIP (L3) [feature] [P3] [XL] [judgment] [queued]
就地复用分析（functional but in-place）：`rc == 1` 时 match 解构 + 同尺寸重构 → 就地改写，drop-reuse 配对消除分配。Perceus 的性能核爆点（函数式写法零拷贝：list map、tree rebalance/insert）。含 reuse specialization（为有/无 reuse token 特化函数）+ COW（`rc > 1` 时 clone-on-write，内部优化非用户可见语义）。
- **前置依赖**：现行 Perceus RC、ownership 与 Drop/Weak 合法性边界稳定
- **参考**：Koka Perceus reuse pass
- **合法性边界（2026-06-12 D-1 拍板）**：last-use drop / 重用仅限「无用户 Drop impl 且非 `Weak<T>` 目标」的类型（as-if 条款，公理⑥ / design.md §7.11）；Weak 目标与带 Drop 类型钉死 scope-end，不得重用
- **验收**：典型 FBIP 模式（list map/filter、tree insert）生成就地改写而非新分配；基准显示分配数下降；完整 C/native、RC/verifier 与自举回归通过；Weak/Drop 用例在 reuse 启用前后输出一致（D-1 锚点）

### B-176 `check` / 验证反馈基线与 regression budget [infra] [P0] [M] [judgment] [queued] [after: B-183+B-205] [before: B-180+#268+#269]

此前Ring compiler的directional measurements与replay index只作历史证据，不构成B-176完成证据。
B-205锁定selected host并完成三个translation spike后，必须从其clean clone、固定toolchain/lockfile、host compiler source、runtime与parity manifest重新采集。

**范围**：selected-host compiler的tiny/大单文件/module check、失败诊断与已移植`verify-rc`等效入口；
host compiler clean/incremental build、单个focused case、unit/parity/e2e/golden/RC/structural与C emission门。
记录 wall/CPU、peak RSS、进程数、case 数、cold/warm cache 和完整工具链指纹；短 lane >=5 次，
预计 >=5min 的长 lane >=3 次，保留全部样本/invalid，不挑最好值。

**验收**：在selected-host clean clone形成可重放baseline、top-3 wall-time构成与B-180预算，明确区分
compiler内部、每进程初始化/重复parse-check、runner/C-toolchain调度。默认测量关闭时近零开销；
一个 bounded wave 收口，不扩为通用 telemetry。

### B-180 开发反馈回路吞吐专项 [refactor] [P0] [XL] [judgment] [queued] [after: B-176+B-183+B-205] [before: #268+#269+B-190]

**进入门（2026-08-31 external-host supersession）**：B-183迁仓、B-205宿主硬门与三个translation spike、B-176 selected-host baseline必须先完成；随后B-180位于#268/#269 external-host实现之前。此前Ring developer-unblock/self-host checkpoint只保留为历史证据，不授权恢复旧compiler lane。

**冻结边界**：只保留已证明fail-closed的runner anchor-object cache；其他Ring compiler candidates全部rejected/frozen。selected-host translation spike完成后由B-176建立新baseline，runner与compiler分checkpoint，compiler只允许一个profile-guided wave。不得恢复历史probe tree、拼接rejected candidates或用缓存掩盖nondeterminism/panic/false-green。

**实现范围 / 顺序**：

1. 先按B-176真实端到端等待选择第一刀；若host compiler construction、runner/C-toolchain调度占主导，再改selected-host build/test入口：compiler artifact使用source/runtime/flags/toolchain/lockfile全指纹控制的内容寻址缓存，但每轮仍在隔离目录执行，禁止信任裸root artifact；增加有界jobs、per-case独立out-dir、确定性汇总与fail-fast可选显示，原始失败永不自动重试或吞掉；
2. compiler lane只允许一次由selected-host profile直接支持的bounded wave；预先固定假设、文件边界、正确性门、端到端淘汰门与停止条件，不得用多轮speculative knives拼凑收益；
3. 若进程启动/重复初始化主导，比较 bounded worker-process/batch-check 与普通进程池；任何复用方案必须以随机 case 顺序、重复运行和进程隔离对照证明无 global state 泄漏。daemon、常驻服务和新公共协议不作为首轮默认；
4. 只有profile证明unchanged module的重复parse/check仍主导，才重写并激活B-105，把HIR/module cache纳入其per-module增量范围；cache key必须覆盖host compiler/stdlib/source/import/effect-signature/toolchain指纹并fail closed。

> **2026-08-14 第一项 retained candidate。** Windows runner 只缓存 controlled recipe 下 tracked `main.c` 的 ThinLTO anchor object；key 绑定 source snapshot、实际 header/macro closure、三段 recipe、target、sanitized environment 与 clang/clang++/lld 内容身份。每轮仍 fresh runtime compile/link 与隔离 run dir；dependency closure 前后各扫一次。artifact/receipt 采用 immutable CAS，同 key divergence 先转为有界 durable poison tombstone，畸形 receipt、大小谎报、hardlink/flush/closure 漂移均 fail loud。focused `bool_ops` e2e 在同一 12 GiB/5-process 门下 fresh miss 与 warm hit 均 1 pass/0 fail，warm whole loop 约 3.2 s；原始 trace 见 replay index。该结果只关闭 runner construction 第一刀，不代表 B-180 或 release acceptance 完成。

> **2026-08-14 第二项 profile-guided checkpoint，尚未合入。** Samply 将 `compiler/types.ring` 的主要等待定位到 callable-summary fixed point；一个有界 generated-C probe 表明，只有在 const owner transaction 与 exact alias rebind 均完成、blocked/pending/default-seed authority 全空，且 source annotation、literal 与 rebound scheme 三方同为相同的 `Int/Float/Str/Bool` primitive 时，省略该 const 后的重复 callable retry 能显著缩短整条命令。Ring source 候选 `8931ad0dafb0c55b00f12b6e0b769831f0b80a11` 已通过独立 source/mutation review，并把新增 helper 从 4 个收敛到 2 个；alias、nonliteral、inferred/callable/nominal const 与任何 pending/failed path 均保留旧 retry。但 exact A7 source check 在 300 s 超时，12 GiB/5-process、1500 s 的 bounded A7→A8 generation 也超时且未产出 C；随后 measurement-only C probe 作为 stage0 的独立 900 s attempt 同样无产物。后者显著降低 CPU/内存轨迹，但不是可信 bootstrap。原始失败见 replay index；不得据 generated-C probe 合入源码，也不得为漂亮结果自动重跑。下一步需要 materially different 的 bootstrap construction 或更深的 fixed-point 优化，不重复相同生成命令。

> **2026-08-14 分段 profile 裁决。** 用户明确允许把慢命令只运行到一个有界前缀：先修复该前缀中已经由 profile 定位的瓶颈，再让后续瓶颈自然暴露；不要求一个候选先完成整条 `compiler/main.ring check` 才能继续，也不要求一次 profile 找出所有问题。每一刀仍须有原始样本、精确候选身份、资源上限、fail-loud 失败与独立正确性 authority；“后段仍超时”不否定已经从同一前段移除的真实热点。

> **2026-08-14 exhaustiveness checkpoint，尚未合入。** 两个相互独立的 source 候选均已获独立 CLEAR：`2af820bc932acecda20d098fdc28fbef0fcb8a7e` 只在 discarded fn/impl precheck 中延后 E0601 exhaustiveness 诊断，并在 retained pass 原样重算；`b627b8becec292d52465287fce004c0275be481b` 在 Maranget pattern matrix 的 zero-column base 后加入等价的 irrefutable-row base，保留 malformed-row panic 路径与所有诊断/type/effect/ownership authority。measurement-only locator 表明原 `compiler/hir.ring:1886` 这一 28-arm match 从超过 100,000 次递归 matrix call 降至 28 次，随后编译继续推进到更多查询；这只证明前段热点消除，尚不是 bootstrap/合入验收。

> **2026-08-14 下一热点，暂停点。** 对上述 matrix locator 的 60 s capped Xperf 前缀显示：旧 `check_matrix` 已退出顶部；约 90% sampled stacks 位于 `precheck_callable_summaries_to_fixed_point`，其中约 67% 沿 `lower_protocol_for_in → unify → unification_pair_reaches_callable → type_may_hide_callable → type_reaches_callable_through_nominals`。下一刀因此是 discarded callable precheck 中反复进行的 nominal-to-callable reachability traversal/分配，不是继续修改 pattern matrix。用户要求定位后暂停；恢复前不得实现或启动新 profile。原始 ETL 与 Job receipt 见 replay index。

> **2026-08-18 callable reachability 第一轮裁决，已淘汰。** Argument 排除了跨 selector、precheck round 或 speculative→retained 边界的持久缓存：当前 nominal registry 与 mutable substitution 没有足以防止 overlay/rollback ABA 的 generation authority。隔离源码候选 `d5ffad63e72ade9b94b19d29a4d870448acb6081` 以 complete nominal walk 替代 pair-sensitive 重放；两个 ownership E0301 锚点与短 `types.ring` 检查通过，但同一 120 s `compiler/main.ring` 前缀只完成 196 个 locator query，低于旧 target 的 501，peak job commit / sampled tree RSS 也从约 8.39/8.08 GiB 增至 11.41/10.99 GiB。只删除 pair recursion 的 mutation 虽仍到 501，却把递归泛型反例从 callable ownership contract mismatch 推迟成 rebind error，不能保留。该候选不合入、不做 bootstrap，也不重复旧 ETW；raw receipts 与精确 executable/source hash 见 replay index。下一刀只能在保持现有 selector decision set、pair recursion 和原始失败的前提下消除 traversal/apply-subst 重复，并继续用同口径有界前缀决定去留。

> **2026-08-18 hidden-only traversal 裁决，已淘汰。** 隔离候选 `15895ab7797d797d4aa658072150499f135081b8` 保留原 pair recursion、Struct/Enum actual 与 active-set 决策，只把一次 nominal walk 内 descendant 的重复 surface scan 收敛为 materialized member 边界的一次 `surface || hidden`。独立 review、source/mutation authority、旧 target source check、两个 ownership E0301 锚点与约 2.29 s 的 `types.ring` 均通过；但同一 120 s 主前缀仍精确停在 501 queries，peak job commit / sampled tree RSS 为 10.68/10.29 GiB，高于旧 8.39/8.08 GiB。该候选同样不合入、不做 bootstrap。证据表明单次 walker 内 surface replay 不是足以推动 whole loop 的成本；下一审计限定为 detector-local nominal binder substitution，优先判断能否在不跨调用缓存、不改变 pair/actual authority的前提下避免临时 Map 与 `apply_subst_map` 整树物化，否则放弃此方向。

> **2026-08-18 nominal binder substitution 裁决，已淘汰。** 四个 detector-local `apply_subst_map` 站点的 measurement-only 分布探针在第 501 个 query 累计观测到：Struct hidden 34,764,600 次，其中 23,162,798 次可直接使用 raw member；Enum hidden 15,215,813 次全部可安全直接使用 root-binder actual；两个 Struct↔Record pair 站点均为 0。按该 authority 实现且独立 review CLEAR 的 Struct+Enum 候选 `6bd4bd95abfc2a9204362306f6d31a961bbbb393` 与更窄的 Enum-only 候选 `e018b12f44f2728de70df6fb75f1cff73a07b7f1` 均保留原 pair recursion、visited/failure 路径，并通过两个 E0301 锚点与 `compiler/types.ring` 短门。真实同拓扑 120 s 前缀中，两者仍都精确停在 501 queries；前者 sampled tree RSS / peak job commit 为 5,638,926,336 / 5,837,950,976 bytes，后者为 5,550,366,720 / 5,746,233,344 bytes，虽明显消除了资源放大，却没有推动可见 whole-loop 进度，因此均不合入、不 bootstrap、不重跑。下一步先在 query 501 正常返回后到下一 `check_exhaustive` 入口之间加入低频 phase-boundary locator；只有该 locator 仍把超时锁在 callable nominal detector，才允许做单 selector 安全 scope 内的 exact-root 重放探针，SCC summary 暂不启动。

> **2026-08-18 post-query-501 coarse locator。** 纯插入、独立 review CLEAR 的 generated-C locator 在 query 501 之前只维护 allocation-free parent latches，之后以 4096-event budget 记录 caller/fixed-point/round/SCC/function/impl 边界。真实 120 s receipt 到达并正常返回 query 501 的 catch callsite，随后进入新的 fixed point；共 224 个 phase events、无 budget exhaustion，前 223 个全部成对闭合，唯一未闭合边界是 `perceus$$_ownership_metadata_with_role_maps` 的 function precheck。该函数源码只有 `compiler/perceus.ring:424` 一个 `for ... in callable_by_def_id.keys()`。下一且仅下一 locator 因此限定为这个 active function 下的 `lower_protocol_for_in` caller 与三个直接 `unify_at_noted` step；不得在第一轮结论外扩到全局 unify/walker，也不得据 coarse function boundary 直接实现 memo/SCC。

> **2026-08-18 targeted for-in locator，callable 下钻终止。** 第二层 generated-C locator 只按完整 43-byte function identity 命中上述 function，并只包围其唯一 generic for-in caller 与 `lower_protocol_for_in` 内三个直接 `unify_at_noted` step；pre-query latches、sticky-invalid 和全部 begin/end/fail counter 均不受 trace gate 控制，原 call/RC/catch/control 序列经独立 review 保持不变。唯一 120 s receipt 到达 query 501，未出现 budget exhaustion、nesting invalid 或普通 Fail；target for-in、三个 outer-unify step、target function 与其 SCC 全部正常闭合，随后又正常闭合九个 function precheck，最终仅在同轮后续 `perceus$$_rc_stmt` 入口耗尽边界。coarse run 的 unmatched function 因而只是当次进度边界，不是 callable nominal traversal 或该 for-in 的热点证明。按 Argument 停止门，不再追逐新的末行、不开第三层 locator、不做 exact-root memo 或 nominal SCC summary；下一单元改为只读审计 callable-summary fixed point 为何整轮重放 function/impl SCC，以及能否以依赖/dirty authority 缩小真实 replay 工作集。

> **2026-08-18 fixed-point replay 计数裁决。** 独立 review CLEAR 的 measurement-only C 镜像保持原 fingerprint equality、SCC/function/impl 调用、RC 与失败流不变，只在 query 1/28/100/250/501 输出 allocation-free 累计计数；SCC/function/impl 均有 normal-return 守恒，query 501 的 `invalid` 与全部 active/inflight latch 为零。真实 120 s 前缀中，14 个 initial invocation 共运行 27 轮，其中 13 轮发生 fingerprint change；相反，观测到的 101 个 post-const invocation 全部在 round 0 立即稳定、没有一轮 change，却累计重放 1,944 个 function SCC、2,043 个 function node 与 7 个 impl site，且所有 function/impl Bool 均为 true。该 target 沿用旧 probe topology，故有意排除了 `compiler/types.ring` 前 42 次 post-const retry；101 次结论不得外推为所有 const shape。seed clear/store 与 pending insert 均为 0；8,489 个 pending remove 只是原 `Set.remove` 调用次数，不能解释为集合真实 transition。该证据反驳立即建设依赖 worklist/SCC local convergence，并把下一刀限定为 behavior-preserving post-const exact-preflight shadow：先让原 FP 始终执行，证明 candidate token 覆盖 last-stable→owner-before→after→FP-return 的 const、forward/reverse alias、default/impl、pending/seed真实 transition、rollback、diagnostic/Fail/fresh-state authority；现有 callable fingerprint 或 owner before/after token 单独都不足以启用 skip。只有 shadow 中每个 would-skip 都对应稳定且零可观察 delta，才允许 source candidate；任何候选仍须以同口径 whole-loop 前进和相称 correctness/bootstrap 门决定去留。

> **2026-08-18 post-const preflight shadow 裁决，invocation skip 路线终止。** 独立 review CLEAR 的全量-FP generated-C shadow 完整撤掉旧 50-const primitive guard，保留已审 matrix/defer locator topology，并让原 post-const fixed point 无条件执行。唯一 120 s receipt 到 query 501 时 `invalid=0`、event budget 未耗尽、143 个 ENTRY/END 全部闭合；143 次均为 `txn=true`、入口 global fingerprint 与上次 stable 相同、round 0 stable。六项 O(1) 状态筛选却只留下 13 次 clean：它们全部是 `compiler/builtin_methods.ring` 的 13 个顶层 `*_METHODS` 常量，而该 leaf module 没有 function/impl scheduler work，最多只可省 13 次 34,467-byte fingerprint（448,071 bytes output）。其余 130 次全部推进 fresh type/DefId，71 次还推进 callable ownership term/parent/solution 状态；按 session 的 delta 向量严格稳定为 59×`[9,2,0,0,0,0]`、7×`[138,58,19,19,7,0]`、50×`[1913,635,335,335,122,0]`、14×`[1536,741,407,407,21,0]`。这直接反驳 signature/transaction/round0 即可跳过；零长度 delta 也不能证明 UF/Map 内容、alias/default、ABA 或 path compression 不变。停止 transition/deep-owner shadow、dirty worklist 与 invocation cache，不实现收益极小的 empty-scheduler 特例；下一 Argument 只审计这 130 轮 fresh-ID/ownership rebuild 的真实 retention/rollback authority，并以 whole-loop 证据决定是否有可回收的 speculative churn。

> **2026-08-18 fresh rebuild / snapshot 路线终止。** 对上述 130 轮的只读 authority 审计确认：四个无 default 参数的观测模块中，42,648 个 fresh DefId 随 discarded HIR 清理而不可达，但回卷 monotonic counter 既不回收对象也不省推理；成功 fn/impl precheck 则会发布可能含 fresh TypeVar/ownership term 的 scheme 或 EffectRow，并有意保留 ownership UF，故不能按 stable fingerprint、编号区间或 Map 长度整体 rollback/compact。default HIR capture 还是把 fresh DefId 保留到权威状态的直接通用反例。复用 2026-08-14 已固定的 Xperf ETL 做离线 stack 汇总（没有新采集）又把重复 snapshot 的收益上限限定在小量级：15,036 个总 samples 中 `infer_decl::map_clone` 209（约 1.39% inclusive）、`callable_summary_fingerprint` 186（约 1.24%）、`snapshot_const_owner_transaction` 94（约 0.63%）、`snapshot_default_authority_surface` 61（约 0.41%）；与 callable fixed-point 的 13,554 samples（约 90.14%）不在同一量级。停止 fresh-ID/UF 回收、summary/HIR 复用、mutation journal/COW 与重复 snapshot 去重，不再为该支线造新 probe。下一可执行单元回到已有真实前缀收益的隔离 irrefutable-matrix base `b627b8becec292d52465287fce004c0275be481b`：先重新锁定 source/mutation authority、独立反驳与最短 correctness 门，候选通过且仍保持原失败后才讨论集成；不得把 501-query measurement 直接当 bootstrap/合入验收。

> **2026-08-18 narrow irrefutable-matrix 裁决，性能淘汰。** 从当前干净基线隔离得到的 `e757487802489deea42b4f05d2b4f9d17b66fd5c` 只把 Wildcard/Binding 视为直接 irrefutable，Or 与其余 Pattern 全部保留旧路；完整 raw helper body、全候选 identifier inventory 与 11 项定向 mutation 已获两份独立 CLEAR。content-bound targeted source/mutation gate 明确通过，两个 E0601 负例与三个非 primitive 正例也保持。固定 mirror/executable 的唯一 120 s 前缀把 `compiler/hir.ring:1886` 保持在 28 calls / 28 hits，501 个 query 全部正常闭合且没有 locator abort，因而局部 hotspot movement 成立；但它没有推进到 query 502 或下一可见 phase，sampled tree RSS / peak commit 反而为 10,715,787,264 / 11,132,325,888 bytes，显著高于旧同拓扑的 8,680,701,952 / 9,006,792,704 bytes。0.67 s timeout 差异不足以把内存差归因为源码回归，却同样不能提供 retain 所需的正向 whole-loop/resource 证据。该候选不合入、不 bootstrap、不重复 locator，也不得与 primitive/defer 拼接救结果；只保留 source-correct 与 28-call 原始证据。B-180 最后一项仍有独立 profile 假设的候选限定为从当前基线移植 `2af820bc932acecda20d098fdc28fbef0fcb8a7e` 的 defer-only 验收：retained pass 必须原样发布 E0601，discarded/speculative pass 只延后诊断计算，不改变 Or/matrix 语义。若 defer-only focused 行为失败、同口径前缀仍停在 501 且无绝对资源收益、或只能依赖已淘汰的混合 C，则终止 B-180 技术探索并记录无新增 retained compiler candidate。

> **2026-08-18 defer-only 最终裁决，编译器候选技术探索终止。** 从当前基线隔离并经多轮独立 source authority 反驳收口的候选 `d8fe4ded621b832caadcfee920b721b54e68e3a6` 只在 discarded function / impl-effect precheck 中省略 speculative `check_exhaustive`，保留 retained E0601、类型解析、HIR/subst/effects 与 catch Fail cleanup。content-bound source/mutation 门和 A0/B0 retained-diagnostic/catch/recovery focused 门均一次通过。最终性能 authority 只使用无 locator 的纯 A0/B0：A0、B0 对同一 `compiler/main.ring` 都在 120 s 超时，没有 whole-loop 完成或独立 terminal 前进；A0 peak commit / sampled tree RSS 为 2,097,664,000 / 2,043,904,000 bytes，B0 反而为 6,926,209,024 / 6,690,410,496 bytes（约 3.30× / 3.27×）。因此候选不合入、不 bootstrap、不做 ETW、不重跑，也不与任何已淘汰候选组合。全部镜像、构建、focused 与最终原始 receipt 保存在 `bench/check/results/b180-exhaustive-precheck-defer-20260818/`。B-180 已无剩余独立支持的 compiler candidate；保留结果只有已合入的 runner anchor-object cache。技术探索关闭，完成认定继续受 #268/#269 critical 长尾与整体验收门阻塞，禁止为填补空档再开 speculative knife。

> **2026-08-19 ownership-cleanup crossing 最终裁决。** 新的 direct fixture 把 Map/Option allocation 信号提升为通用 correctness 根因：`var Option = none` 后装入 owned payload 时缺 W4/exit cleanup。bounded safe-tail 候选与独立 verifier 已通过 source-built gen1 的 runtime 1/1、RC/mutation 8/8、structural 1/1 和 parity 1/1；但该 gen1 自身仍由旧 Perceus lowering 生成，完整 gen2 在 2371.12 s 触及固定 12 GiB/typeid 8。唯一额外 construction 只把临时 mirror 的 3016-line verifier替换为同 API、调用即 panic 的 30-line fail-closed stub，仍在 2347.24 s 触及同一资源墙。两条收据都无产物，证据见 `bench/check/results/ownership-option-cleanup-20260819/s-prime-acceptance/`。不得继续删模块、提高 cap、patch generated C/runtime/typeid、重跑旧 profile或按 `unify.ring` 热点写 workaround；candidate 保留 correctness evidence，但 B-180/self-host acceptance 仍 blocked，tracked bootstrap 不更新。任何后续 crossing 必须先有新的直接 peak authority 与独立 Argument，不能把同类 size-cut 猜测当成下一刀。

**整体验收**：B-205 translation spike完成后由B-176在同机同manifest上为selected-host compiler重建基线，再固定量化目标；旧Ring self-host wall、2x目标和probe只作历史输入，不直接约束新host。至少覆盖clean/incremental check、tiny/大单文件/module project、parity suite与C emission，先证明瓶颈分布再允许一个profile-guided wave；p95与peak RSS budget必须基于新基线。runner/compiler checkpoint可分别验收，但B-180不要求Ring self-host/double-bootstrap；串行oracle与并行runner的pass/fail/skip、诊断和已移植C输出必须一致，覆盖数不减少，任何原始失败必须fail loud。

### B-190 Repository overengineering audit and simplification [refactor] [P1] [XL] [judgment] [queued] [after: B-180+B-187+B-183] [before: B-174]

性能专项完成后，对固定最新 main 做一次 bounded 全仓盘点，识别历史执行中混入但不再服务当前路线的复杂度；目标是减轻维护面，不是追求抽象完美或重写编译器。范围覆盖 compiler/runtime/std/tests、构建与 one-shot harness、provider adapter、活动治理入口及重复 authority；B-187 已处理的纯文档漂移只作为输入，不重复清扫。

**盘点与执行**：每项只允许 `保留（当前必要）/ 删除 / 简化合并 / 延后到具体未来需求 / 用户决定`。重点核对重复真值、失效后端/probe、无消费者的 extensibility/config/plugin 层、为友善内部工具构造的恶意攻击防线、重复 parser/visitor/oracle、过度 mutation/harness、可由现有 authority直接推出的中间抽象和完成历史残留。先形成有证据的 inventory并独立反驳，再按文件冲突切成 bounded refactor waves；优先净删除、合并 authority和缩短调用链，不以 LOC 指标驱动。

**约束 / 验收**：不改变公开语义、ownership/safety保证、ABI或release门，不把“清理”变成新架构项目；当前可用、近期无已知bug而仅不够漂亮的代码允许继续保留。每个变更必须说明删除了哪个维护负担及为何不影响当前/已登记近程消费者；selected-host clean build、unit/parity、相称C/RC/ASan、workflow/health通过，独立reviewer主动寻找误删和新重复层。self-host/fixed point只在后续独立里程碑重新批准后才成为验收门。一次盘点后收口，禁止audit-until-dry或为了填满波次制造工作。

### B-183 Vorton 仓库身份与 GitHub 工作流原子迁移 [infra] [P0] [XL] [judgment] [queued] [with: B-205] [before: B-176+B-180+#268+#269+B-174+B-177+B-175]

> **2026-09-01 用户方向（单人项目治理减法）**：立即把latest蓝本、完整历史/WIP与治理迁入`vorton-lang`，并在目标仓库与B-205一起建立外部宿主compiler；#268/#269、B-176/B-180与Known Issues在新仓继续。迁仓前只规划最小可执行流程；transfer/rename等外部动作仍须用户随后明确批准。

**范围 / 文件与外部面**：authority正常merge回main、GitHub transfer+rename、最小Issue/PR模板、现有CI适配、活动backlog/audit导入、`docs/workflow.md`与provider adapter、repo-wide public identity/CLI/source extension/editor package/cache path、README/规范/测试。

**已固定边界**：

1. 核心仓库目标为 `vorton-lang/vorton`；使用 GitHub transfer + rename，保留完整 commit/tag/ref provenance，不新建空仓导入、不 squash 或重写历史，也不得复用旧 `YYF233333/Ring-lang` slug 破坏重定向。
2. `compiler/dist-c/main.c`继续随完整历史迁移、不拆仓、不转Git LFS，以`linguist-generated`排除语言统计并默认折叠diff；它是dc91旧功能oracle，不再是latest compiler的bootstrap authority。B-205选型硬门产出的selected-host compiler及lockfile成为clean-clone可构建入口，其他生成C仍不入库或只作test/release artifact。
3. 公共身份按未发布期 clean break 原子改为 Vorton，不建立 Ring alias/双 CLI/双 ABI；`.v` 因与 V、Verilog、Rocq Prover 冲突而排除，最终源码扩展名及 CLI/package/editor namespace 在本项 planning 固定。
4. GitHub Issue成为活动scope/status/acceptance的持久真值，session继续承担讨论；用户在session拍板后由Discussion向Issue同步一条摘要，用户无需重复。单人项目直接使用现有用户`git`/`gh`身份，不建设GitHub App、broker、webhook、machine user、权限矩阵或security基础设施。

**planning 必须先产出的执行规范**：

- 隔离rehearsal后用normal merge commit把authority合回main；不squash/rebase/rewrite。生成全部refs/notes/tags的bundle与一份迁移manifest。
- 活动B/A/D各生成一个Issue：保留标题、现状、验收、依赖与原ID；closed历史不导入。导入后新工作只使用Issue编号，旧编号仅供搜索；核对Issue总数与依赖后冻结`docs/backlog.md`/`docs/audit-report.md`。
- Session只负责讨论；Issue保存scope/status/acceptance，唯一实现链为`Issue #N → 一个active PR → PR head branch`。PR正文写`Closes #N`，merge自动关Issue；本地worktree只是可选checkout。session决定在开始实现或merge前同步一次，冲突时直接问用户。
- 用户批准后执行transfer+rename，更新remote、公共标识、最小Issue/PR模板和CI；随后另行批准才开始B-205 spike。

**验收**：authority已正常merge进唯一main；bundle/manifest可解析全部durable refs/notes/tags；迁移后`vorton-lang/vorton`保留完整ancestry，main与远端SHA一致；活动Issue数量、原ID和依赖核对一致，Markdown看板冻结且无第二手工真值；clean clone可运行现有基础CI。B-205 workspace/spike、release、公开preview和全部语言质量门不属于本项执行授权。

### B-184 Ownership checker workaround retirement / 语义人体工学收口 [refactor] [P1] [L] [judgment] [queued] [after: B-183]

> **2026-08-09 用户方向**：当前 strict ownership 自举为通过 compiler fixed point 引入了大量 sink-local fresh whole binding、named Borrow firebreak、每轮 loop view 与 whole-value rebuild。它们中一部分是在现有语言边界下表达唯一 owning sink 的必要代码，一部分则暴露 callable/capture mode、loop back-edge 或 closure ordinary-capture 的分析精度不足。本项在 Vorton 仓库迁移完成后独立收口；不与 B-180 性能专项混做，也不阻塞当前 correctness checkpoint。

**目标 / 范围**：

1. 以 strict ownership 迁移补丁、hash-bound diagnostics 与 self-host fixed-point evidence 建立 workaround inventory；逐项分为「语义必要的唯一 ownership 分流」「checker false positive」「仅为旧 bootstrap 所需且现已冗余」三类，禁止按 fresh-local 文本形状 blanket 删除。
2. 对 false positive 在单一 ownership 真值中修复：优先收敛 callable/capture mode fixed point、临时 CFG 的 branch/loop 状态、ordinary closure 捕获与 sink fanout；checker、Perceus、`verify_rc` 必须消费同一 plan，不新增 callee-name、arity、AST-shape fallback 或第二套 authority。
3. 分析修复后机械删除不再需要的 firebreak/helper/fresh locals，恢复最小、可读的 compiler source；仍代表多个真实 owning sink 的分流必须保留或重构为单一 owner，不能用隐式复制、`clone`、RC 泄漏或放宽 `E0801` 消除。
4. 当前 fail-loud 的 partial move、may-own consume-capture / `FnOnce` 契约以及 B-168 前跨 `catch` ownership transfer 不在本项暗中扩语义；前两者若进入实现须另交用户 decision dossier 并立项，后者继续由 B-168 及其消费者收口。

**验收**：inventory 对当前 workaround 100% 有分类与 source/evidence lineage；每个被修 false positive 都有能在旧 checker 失败、新 checker 通过的正例，以及保持真实 double-move/use-after-move 失败的对抗负例；workaround 删除前后 HIR ownership plan、DefId authority、traversal/evaluation order与诊断类别可复核。old-anchor/current strict、C emission、Perceus/`verify_rc`、完整 C/RC/structural/parity/self-host double bootstrap 全绿，`E0801` 覆盖不得减少，禁止 clone/fallback/豁免增量。最终报告分别列出已删除、仍语义必要、转交独立能力项的代码形态，不能以“编译通过”代替 soundness 证明。

### B-181 生成程序 runtime / 内存 / 产物 release budget [infra] [P1] [M] [judgment] [queued] [after: B-180]

B-176/B-180 先解决编译器开发反馈；本项再建立用户程序性能真值，避免两类优化竞争同一 P0。覆盖代表性 CLI、容器、effect、trait、RC workload 的 wall/CPU、peak RSS、allocation/dup/drop 数和 binary size；记录 compiler commit、`dist-c` 指纹、C compiler/version、完整 flags、机器与 cold/warm 状态。

**决策输出**：建立 Windows/Linux 可重放 baseline 与 release regression budget；用 profiler/alloc trace 把热点映射到 Ring pass、生成 C 或 runtime。#262、B-079 等生成程序优化只有在本项证明收益面后启动；性能结果不得推翻 correctness 修复，只能触发后续优化。

**验收**：同一 manifest 至少 5 次并保留原始样本、中位数与离散度；结果 schema/图表由原始数据生成；CI 只跑稳定低成本 subset，完整 benchmark 手动触发；至少形成一个“立即修”、一个“保持观测”和一个“证据不足不做”的结论。



### B-119 公理⑤做实：推断 fuel 上限 + trait instance 终止性审计 [design-align] [P3] [M] [judgment] [queued]

> 2026-06-12 立项（D-5 拍板，公理⑤「做实条款」①③）。公理⑤承诺「耗时可预期」与「当前系统全部可判定」，两处缺工程兜底/证据。

**涉及修改**：
1. **trait instance 终止性审计（probe 部分，先行）**：核查 checker 的 trait resolution（`trait_impls` 查找/递归 bound 解析）对 `impl Foo for T where Bar<T>: Foo` 类自引用 impl 是否会无界递归——有 Paterson 式结构递减条件或深度上限则记录证据入 lang-design；没有则构造最小复现（负面测试）。
2. **fuel/深度上限（实现部分，依审计结论定范围）**：推断与 trait resolution 加深度/迭代上限，超限 = 编译错误（E 码 + 提示加标注兜底），不允许卡死或不可预期耗时。上限值取「真实代码永不触发」量级（参考 Rust recursion_limit=128）。
3. 负面测试：爆炸/递归构造案例报错而非挂起（带 timeout 的测试 harness）。

**验收标准**：
- 审计结论写入 lang-design §10 的可判定性条目：终止性有证据，或修复后有上限
- 病态构造（自引用 impl / 深嵌套 let-多态）编译器在上限处报错退出，不挂起
- `python tests/run_tests.py` 全绿，无现有代码触发上限

### 语义驱动优化（AOT + JIT 共享）

以下优化利用 Ring 类型系统提供的**独有语义信息**，是 C++/Rust 编译器做不到或需要手动标注才能做到的：

| 优化 | 依赖的语义信息 | AOT | JIT | C++/Rust 对等物 |
|------|--------------|-----|-----|---------------|
| **Bounds check 消除** | Refinement types（编译器已证明 `i < len`） | ✓ | — | 无（需 unsafe） |
| **RC 省略** | Linear types（证明唯一持有） | ✓ | ✓ | Rust `&mut`（手动标注） |
| **就地修改保证** | Linear types + Perceus reuse analysis | ✓ | — | Rust `&mut`（手动标注） |
| **纯函数优化** | Effect purity（`with {}`） | ✓ CSE/DCE/重排 | ✓ 自动并行 | `constexpr`（有限） |
| **Evidence 特化** | Effect 单态调用点 | ✓ | ✓ | N/A |
| **Dictionary 反虚化** | Trait dispatch 热路径 | ✓ | ✓ speculative | Rust 单态化（编译期全量） |
| **融合（Deforestation）** | 纯函数管道 + Effect purity | ✓ | — | 手动循环合并 |
| **逃逸分析 → 栈分配** | 数据流分析 | ✓ | ✓ 更精确 | 手动控制 |
| **热路径单态化** | 泛型 + row-poly 函数 | 部分 | ✓ profile 驱动 | C++ 模板（编译期全量） |
| **闭包合并** | 管道中多个小闭包 | ✓ | — | 手动合并 |

### B-041 JIT 编译选型与热路径重编译 [feature] [P3] [XL] [judgment] [queued]
在稳定 AOT native 基础上，用 runtime profile 重编译热路径。实现前先对 ORC、轻量 IR/解释器 tier 与外部 JIT runtime 做 Argument，不预先绑定已退役后端。

- **前置依赖**：C-only 基础 AOT pass 与性能基线稳定，并有实测热点证明 JIT 值得扩大 runtime/平台边界
- **验收**：选型含跨平台、TCB、deopt、effect/refinement/linear 元数据和回滚成本；原型证明真实 workload 收益且不改变公开语义

### 类型系统驱动的控制力（远期愿景）

> 设计原则：控制力通过类型系统表达，不通过 `unsafe` 逃逸口。程序员声明意图，编译器保证正确性。
> 等 C 主路径与性能基线稳定后再逐项实现。

**Region Effect（内存分配策略）**

`region<R>` 作为 effect，handler 决定分配策略（arena / pool / bump）。块内分配零 RC 开销，块结束一次性释放。Linear types 保证引用不逃逸 region 生命周期。

```ring
handle {
    let tmp = entities.map(|e| alloc(e.pos))
    process(tmp)
} with region { arena(64 * 1024) }
```

应用场景：游戏帧循环、HTTP 请求处理、批处理管道。

**Value Types（unboxed 内联存储）**

`@value struct Point { x: Float, y: Float }` — 保证无 RC、按值传递、内联存储。编译器验证 value type 不含引用类型字段（或所有字段也是 value type）。

应用场景：数学向量/矩阵、颜色、坐标、小型不可变数据。

**Refinement 驱动的检查消除**

`fn get_unchecked(list: List<T>, i: Int where i >= 0 && i < list.len()) -> T` — refinement 证明已涵盖安全条件，编译器跳过运行时 bounds check。不需要 `unsafe`，类型系统保证安全。

应用场景：HPC 紧循环、图像像素遍历、矩阵运算。

**声明式优化 Hint**

| Hint | 作用 |
|------|------|
| `@align(N)` / `@packed` | 内存布局控制（cache line 对齐、紧凑存储） |
| `@specialize(T = Int)` | 强制泛型函数单态化 |
| `@vectorize` | 结合 effect purity 安全自动向量化 |
| `@inline` / `@noinline` | 内联控制 |

**不做的控制力**（2026-06-11 订正：unsafe 两行旧立场撤销，见 design.md §7.12 unsafe 区域图景）

| 机制 | 状态/原因 |
|------|-----------|
| 原始指针 / 手动 malloc | **安全区不做；unsafe 区提供**（§7.12 三栏总账；原语集已拍定 §7.12「B-106 正文拍定」，实现 = B-125）|
| `unsafe` 块 | **改做**——`unsafe` effect + 两级 discharge（`mod requires {unsafe}` + `unsafe {}`，关键字与 Rust 一致），§7.12 |
| 手动 SIMD intrinsics | 不可移植，由编译器 + hint 处理 |
| 无 RC 模式 | 和 Perceus 架构冲突 |

## 工具链

### B-174 v0.1 preview CLI 与本地项目闭环 [feature] [P0] [L] [judgment] [queued] [after: B-183]

当前 CLI 只有 `check`/`build`，`build` 只产出 C 与 object，版本写死且 runtime/std 定位依赖仓库布局。首个 preview 必须让解压后的用户在一个命令闭环内检查、构建、运行并诊断工具链。

**范围 / 文件**：`compiler/cli.ring`、`compiler/compiler_mod.ring`、C codegen/link driver、`compiler/scripts/`、Python command-contract tests 与用户文档。

- `ring --version` / `ring version` 输出语义版本、compiler commit/anchor 指纹与 target；机器格式字段稳定；
- `ring check <entry>`、`ring build <entry> --emit=c|obj|exe`、`ring run <entry> -- <args>`、`ring doctor`；单文件和现有多文件 project 走同一 driver；
- compiler/std/runtime/toolchain discovery 不依赖当前工作目录或源码 checkout；clang 缺失、链接失败、runtime 不匹配均非零退出并给出单轮可修诊断；
- human/LLM 输出、stdout/stderr、退出码与产物路径形成 command contract；不把 test-only RC mutation flag 暴露为普通用户面；
- 本项不顺带设计 registry/package solver、formatter 或 LSP，分别由 B-179/B-178/B-016 承担。

**验收**：从任意目录对 hello、带参数 CLI、两层 module project 执行 check/build/run；路径含空格与非 ASCII；失败覆盖无 clang、坏源码、坏 link、缺 runtime；生成 exe 与直接 object+runtime 手工链接行为一致；完整 C/RC/self-compile/fixed-point 门通过。

### B-175 可复现发布包与 Windows/Linux CI 矩阵 [infra] [P0] [L] [judgment] [queued] [after: B-174]

本项产出 **release candidate artifact**，不授权公开 release。首轮支持门为 Windows x64 + Linux x64；macOS 先做可重放 smoke/evidence，未通过同等门前不宣传支持。产品 compiler 仍使用 clang；Linux 额外用 gcc 编译生成 C 作为去相关信道。

**范围 / 文件**：`.github/workflows/`、`compiler/scripts/`、release manifest/NOTICE、安装与卸载脚本、README/quickstart、artifact smoke tests。

- D-002 已固定 `MIT OR Apache-2.0` 双许可与 `Yufeng Ying` holder；bundle 包含 compiler、版本匹配的 std/runtime 资产、两份官方 license、SPDX expression、NOTICE/provenance、quickstart 与 checksum，不依赖源码仓库结构；
- clean checkout 从 tracked `dist-c/main.c` 构建，clean unpack 能运行 `ring doctor`、hello、多文件 project 与 self-compile fixed point；
- Windows/Linux 各跑 e2e/golden/RC/structural/parity/self-compile；Linux 同时验证 clang 与 gcc 的 C11 编译，平台差异限制在 runtime/driver 边界；
- artifact 名、版本、target triple、toolchain requirements、SHA-256 与 provenance manifest 确定；同输入重建差异必须可解释；
- 对 compiler/runtime/std/generated template 做 provenance inventory，贡献说明固定“提交即按同一双许可提供”；纯用户源码生成物不附加 Ring 许可，实际复制/链接的 runtime/std/template 仍由 manifest 明示相应 license/NOTICE。最终支持声明、tag 与 GitHub Release 仍属用户保留决定；完成许可 packaging 也不代用户发布。

**发布阻断**：全部 critical finding 清零；当前排序列出的 silent wrong-code/heap/RC blockers 关闭；B-193~B-196与B-167/B-152/B-002/B-156/B-133 gate 完成；C-only 全量门和至少一轮 clean-clone CI 全绿；文档不得宣称 async/refinement/default provider/effectful Drop/LSP 等未发货能力。

### B-177 版本化 agent inspection contract + bundled primer [feature] [P1] [L] [judgment] [queued] [after: B-174] [before: B-111]

外部 agent-first 语言已把 query/check/test/run、稳定程序 identity 与版本匹配的语言 skills 作为 compiler 产品面。Ring 保持普通源码 + Git 为真值，不改成 graph-native 数据库；但必须让 agent 无需读完整实现即可取得可缓存、可校验的语义事实。

**用户面 / 文件**：在 CLI 增加 `ring inspect --format=json`（planning 时可在不制造第二套概念的前提下核定最终命名），并随 release bundle 提供版本匹配的 Ring primer 与 std public signatures。输出至少包含 schema/compiler/source hash、module/import edge、public symbol stable identity、推断 type/effect/trait bound、展开后的SystemEffectRef/HandledEffectRef分类、exact HostOp清单、module capability/unsafe discharge与诊断关联span；system effect不得伪装成handler evidence。

**约束**：canonical ordering、schema version 与内容 hash 稳定；陈旧缓存/源码 hash 不匹配 fail closed；只暴露 checker/HIR 的权威事实，不在 CLI 重做解析/推断；v1 只读，不引入 compiler-managed patch/write 或第二份程序数据库。Primer token 单独计量，必须由当前 compiler/spec 自动校验，不允许版本漂移。

**验收**：单/多模块、re-export、泛型 trait/effect、unsafe 与错误程序的 JSON contract golden；相同输入字节稳定，语义变化改变 hash；primer + signatures 在固定 token budget 内覆盖 B-111 任务所需核心；B-111 harness 实际消费 bundle 中的版本化产物而非手工副本。

### B-178 `ring fmt` 与行为签名物化 [feature] [P1] [L] [judgment] [queued] [after: B-174]

philosophy ②/③ 已把 formatter 物化标注列为 effect/type 对 agent 的主可见载体，但当前 `compiler/formatter.ring` 只格式化诊断。实现 source formatter，先兑现稳定格式与 lv0/lv2 核心，不把全部远期 preset 一次塞入 MVP。

**范围**：AST/source edit 表示、checker/HIR annotation view、`ring fmt [--check] [--preset=none|api|review]`、项目遍历与 formatter golden。`none` 做纯语法规范化；`api/review` 物化 public/internal function 的返回类型、effect row 与已定 ownership/mut 标注。pub 契约不一致必须保留人工确认边界。

**机械性质 / 验收**：幂等、round-trip、不同 preset 编译语义与运行结果一致、canonical ordering、注释/字符串保持；`--check` 不写文件且以退出码报告漂移；全仓 dry-run 可枚举变化，compiler/std 迁移单独 review；B-016 只消费同一 parser/checker/format edit substrate，不复制 formatter。

### B-016 LSP 移植 [feature] [P1] [L] [judgment] [queued] [after: B-178]
原 TS 实现未移植到 Ring 自举编译器。需要重新实现。

- **当前状态**：VSCode 插件仅提供语法高亮
- **前置依赖**：B-178 的 parser/checker/format edit substrate；LSP 不复制第二套 source edit 或 formatter
- **复杂度**：大
- **优先级**：v0.1 developer preview 后的首个可用性门；先交付 diagnostics/hover/definition/completion/formatting，再扩展 rename/code action


### B-018 Debugger [feature] [P3] [L] [judgment] [queued]
source-map 支持 + 断点调试。

- **前置依赖**：LSP
- **复杂度**：大
- **优先级**：Phase D/E

### B-111 LLM eval harness：核心赌注测量仪 [feature] [P1] [L] [judgment] [queued] [after: B-175+B-177]

> 2026-06-12 D-7 拍板：P2→P1——层 0 判据（公理④）的测量仪，地位等价公理⑥的 B-089 锚点；只改优先级，不动排程（B-104 里程碑照旧先行）。
> 2026-06-11 立项（Discussion）。design.md §11.3 五指标至今零测量——「LLM 写 Ring 优于 TS」是项目存在理由，须从信念变数据，且结果反向校准语言面特性优先级（哪类 papercut 真烧 token）。拍板：**对照组 TS only**；**题目从既有 benchmark（HumanEval/MBPP 风格）改编**（防自选偏差，题目分布不由我们控制）。
> 2026-07-28 竞品复查：TypeScript 7 已正式发布并有生产反馈，本项不再对 beta/旧 `tsc` 做历史对比；对照固定为正式 TypeScript 7 native compiler。目标是证伪或证实「行为签名降低 agent 总成本」，不是证明 Ring 在所有任务都更强。

**形态（MVP）**：
1. **任务集**：15–25 题（字符串/数据变换/小算法/小 CLI），每题 = 自然语言 spec + 隐藏测试套件 ×（Ring + TS）。改编只替换语言表面（std API 名），不改任务实质。
2. **Ring primer**（关键产物，独立价值 = 未来所有 LLM 的标准 onboarding 文档）：~1–2K token 语法速查 + std 签名表。harness 喂 primer——「零训练数据 + 签名即够」是命题本身。
3. **驱动循环**：headless 驱动被测模型——生成 → 编译（Ring 用 `--error-format=llm`；TS 用正式 TypeScript 7 native CLI，`strict=true`）→ 错误喂回 → 重试（上限 N 轮）→ 跑隐藏测试。两语言协议完全相同；每题 ×3 取均值压噪音。
4. **指标**：首次编译通过率 / 到绿轮数 / 隐藏测试运行时错误率 / 总 token（design.md §11.3 前四项）。
5. 被测模型 Sonnet 级（平均 agentic 代表 + 便宜可多跑；顶级模型硬实力会掩盖语言差异）。放 `eval/`，手动触发，不进 CI（烧 token）。
6. **行为契约子集**：任务集中预注册一组 signature-only/API-use 题；只提供模块签名，不提供实现，覆盖纯函数误用、`console/fs/process` system capability、custom handled effect、`fail<E>`、`mut` 与资源生命周期。TS 题提供语义等价的 `.d.ts`/文档，不额外泄漏答案。该子集直接测量「签名信息密度」，不得事后挑题。
7. **可复现协议**：锁定并记录模型名/版本、system prompt、temperature、上下文和输出预算、Ring/TS compiler commit/version、TS config、机器环境、每轮完整 prompt/diagnostic/patch、token 与 wall-clock。onboarding primer token 单独报告，不得藏入免费上下文。
8. **分析纪律**：预先固定主指标、重试上限与失败分类；报告均值同时给出原始样本和离散程度。结果允许为 Ring 无优势或更差，禁止只发布胜例；版本/协议不一致的 run 标 invalid，不与正式结果合并。

**验收标准**：
- ≥15 题 × 2 语言 × 3 重复跑通，产出指标对比报告
- Ring primer 成文且被 harness 实际使用
- 失败案例归类（语法迁移 / 类型 / effect / std API），形成修缮清单回流 backlog
- 至少 5 题属于预注册的行为契约子集；两语言输入信息量差异逐题可审计
- 发布可重放 manifest 与逐轮原始记录；报告明确列出 null/负向结果、无效 run 和已知混杂因素

### B-182 证据携带补丁验收系统（低成本 agent 安全委派）[infra] [P1] [XL] [judgment] [queued] [after: B-111]

B-111 回答语言层的核心赌注；本项随后验证仓库层的有界主张：在预先声明的任务与风险包络内，提议模型的能力只影响产出率、重试次数和成本，不能降低补丁的接受标准。它不把当前“CI 绿色”直接解释成正确性证明，而是要求每个被接受的补丁携带与风险等级相称、可独立重放的证据。

**范围 / 文件**：以 B-111 的原始 traces、失败分类和成本基线为输入，在 `eval/` 建立仓库任务 replay/calibration corpus，在 `.agents/scripts/` 建立 acceptance contract、oracle 与校准工具，并把稳定的确定性门接入 `tests/run_tests.py` / `.github/workflows/`；风险分层、升级权限和证据保留规则写入 `docs/workflow.md`。编译器可判定的不变量仍由各自 compiler backlog 收敛，本项不复制类型/effect/ownership/RC 权威逻辑。

**约束**：候选补丁声明 base SHA、允许路径、行为/非变化 claim、风险等级与所需证据；不受信任的提议者不能在同一候选中改写验收策略、隐藏 oracle 或其他 acceptance TCB。确定性检查、差分/property/fuzz/mutation 与隐藏行为 oracle 优先；模型只处理剩余的 spec/意图判断，输出 `blocker / clear / unknown`，其中 unknown、冲突、高风险或 TCB 变更一律 fail closed 并升级到强模型/用户保留边界。强模型主要用于建立永久 oracle、校准和抽样审计，而不是无限重复验收同一类低风险补丁。具体任务分层、模型组合、抽样率和统计阈值待 B-111 完成后 planning，不提前冻结。

**验收标准**：
- 每个 accepted patch 都有版本化 acceptance contract、完整 gate 结果和可从固定 snapshot 重放的证据包；缺证据、结果冲突或验证器版本不匹配不得静默通过；
- 预注册的历史缺陷补丁与 seeded mutation calibration corpus 均被阻断或明确升级，不得作为低风险绿色补丁漏出；修改 gate/oracle/TCB 的候选自动进入高风险路径；
- 在一批预注册外围任务上，以同一接受标准比较低成本与强模型，报告 accepted yield、重试/token/成本、隐藏 oracle 逃逸及统计上界；允许 null/负向结论，未达到预注册阈值不得扩大委派范围；
- 对 compiler/type/effect/ownership/RC/runtime ABI/bootstrap/verifier/CI gate 等 acceptance TCB 保留独立强审，不因外围试验成功而自动降级。

## 设计验证（Stabilize 前置）

> 非实现任务，而是设计探针。在对应 XL 特性实现前完成，防止特性交互导致事后 breaking change。

### B-116 async native 实现模型（B-007 前置 design-probe）[design-align] [P3] [M] [judgment] [queued]

async 需要挂起，现行 handler 只有 tail-resumptive + abort。中性评估 stackless/CPS、stackful fiber、线程池阻塞垫脚石；归档 JS generator 不作为答案。以原型核实跨 await ownership/drop、HOF、C ABI/FFI、跨平台、scope/cancel，给出推荐/否决与反证，写回 design §8 并重写 B-007。本项不改 main 行为。

## 语法增强

### B-193 删除未生效的 refinement `where` 占位语法 [design-align] [P1] [S] [mechanical] [queued] [before: B-174+B-001]

> **2026-08-23 用户决定，已拍板 clean break**：refinement尚未实现，0.1不接受“能解析、只报警告、但不验证”的field`where`。当前唯一进入parser的struct-field placeholder删除；未来B-001只有parser与真实refinement语义原子闭合时才重新加入。

**范围**：`compiler/parser.ring`停止消费`where...`到逗号/右花括号并在clause起点给单轮可修hard error；删除只服务该路径的W0002及消费者；`where_clause_warning`改正式负例，覆盖普通/generic/多字段恢复。`where`继续为未来保留关键字，不变成普通标识符。

**约束 / 验收**：不新增TypeExpr/AST/HIR/FlowIR carrier，不提前实现predicate、SMT、runtime check或const-generic refinement；不得保留warning/skip/documentation-only fallback。所有field/parameter refinement clause稳定hard-fail且不吞后续声明；无`where`代码不变。Targeted parser/diagnostic、完整C/full/self-host/fixed-point与workflow validator通过。

### B-191 删除 `T?` Option 纯缩写语法糖 [design-align] [P2] [M] [judgment] [queued] [after: B-180] [before: B-174]

> **2026-08-22 用户决定，已拍板 clean break**：Ring 不保留仅减少字符、无独立建模/认知/验证/组合价值的纯缩写语法糖；少写几个字符或 token 对 LLM 不构成充分收益。`T?` 与 `Option<T>` 语义完全相同，却增加第二种类型拼写及 nullable / error-propagation 跨语言歧义，因此删除。该项不打断 #268/#269 或 B-176/B-180；性能专项完成后执行，并在 preview CLI/product surface 前关闭。

**范围 / 文件**：

- `compiler/parser.ring`、`compiler/ast.ring`、`compiler/infer_ctx.ring`：删除类型位置的 `?` 后缀与只服务该糖的 `TypeExpr::OptionType` 路径；`Option<T>` 继续解析到现有 builtin Option enum。`TkQuestion` 若仍被 open effect tail `?e` 等现行语法使用则保留，不做无关 token 清理。
- `compiler/types.ring` 及 formatter/diagnostic/inspection consumers：canonical type display 改为 `Option<T>`，不得再把显式源码或推断结果打印成 `T?`。
- 原子迁移 `compiler/*.ring`、`std/*.ring`、examples、tests 与 `docs/lang-spec/{syntax,type-system,stdlib}.md`；同步当前 design/philosophy/CLAUDE 的实现状态。历史 Git 文本与专用负例不作“残留”误报。

**约束**：不改变 `Option<T>`、`some`/`none`、match、RC/ownership、ABI 或 runtime 表示；不增加 deprecated alias、warning-only 过渡、formatter fallback 或双 parser 路径。迁移 commit 中旧形式必须立即 hard-fail，并给出单轮可修的 `Option<...>` 建议。不得把本项与 Option runtime/cleanup、nullable/null、新 Option API 或其他语法清理混做。

**验收**：

- `Int?`、`List<T>?`、`(K, V)?` 及 qualified 形态均稳定 parse error，诊断建议对应 `Option<...>`；`Option<Int>`、`Option<(K, V)>`、`Option<Option<T>>`、`Option<fn(Int) -> Str>` 与跨模块形态全绿。
- formatter、human/LLM diagnostics、module signatures、inspection/golden 不再发射 `T?`；仓内活动源码/规范除专用负例与本 item 说明外无旧拼写。
- 仓内消费者、公开规范、examples 与测试同一 clean-break commit 迁移；无 alias/fallback，`Option<T>` 行为与生成 C/runtime 输出不变。
- 完整 C e2e/golden/RC/structural/parity/self-compile、targeted parser/diagnostic negative matrix、double bootstrap 与 tracked `dist-c` literal fixed point通过；独立 reviewer 主动检查 `?e` 等非目标问号语法未被误删。

### B-192 完整 module signature conformance [feature] [P3] [L] [judgment] [queued] [after: B-175]

> **2026-08-23 用户决定**：0.1 删除只 parse/register/export `SigDef`、却不约束任何 module 的 `sig` placeholder；首次0.1发布后择期重新实现。该未来项目不得从register-only中间态恢复，只有真实module conformance、消费者与验收同时闭合才可进入main。

**目标 / 范围**：先以真实大型代码库需求重新Argument surface，至少比较 contextual `sig` + `module/mod X : Signature`、独立interface文件与inspection-generated contract；0.1中`sig`是合法标识符，未来语法不得无迁移地夺回该标识符。实现必须让module公开value/type/effect/trait/associated type与可见性、泛型/effect row、re-export及same-origin identity接受一个可检查的signature contract；不顺带引入first-class modules、functor、动态module value或跨文件partial module。

**验收**：缺失/类型不符/effect扩大/visibility与associated contract不符均给单轮可修诊断；合法single/project/re-export/diamond与separate implementation通过；signature成为TypedHIR/module interface与incremental hash的单一authority，CoreHIR后无name-based conformance重算；formatter/inspection/LLM contract输出一致。完整C/full/self-host/fixed-point与跨平台CI通过，且必须有至少一个仓内或preview真实consumer，不能再次以纯parser/namespace transport测试冒充feature完成。

### B-199 删除 impl / trait member 假 `pub` 并收口 private interface [design-align] [P1] [M] [judgment] [queued] [after: B-190] [before: B-174]

> **2026-08-23 用户决定，已拍板 clean break**：0.1对齐Rust。Trait visibility一次决定完整associated contract；impl block本身无visibility。当前parser在所有Decl前接受`pub`、并在trait/impl路径部分丢弃，形成`pub impl`与trait-member`pub`假语义。Public接口含private declaration则外部必不可用，Ring不沿用warn-only，全部在preview前hard-fail。

**范围 / 文件**：`compiler/parser.ring`/checker按decl/impl kind区分visibility：任何`pub impl`、trait declaration与trait impl中的fn/associated type出现`pub`即单轮可修错误并建议删除；inherent impl继续逐member保留`pub`/private。Public fn/const/type/trait/effect、pub fields/public enum payload/methods及generic bounds递归检查Type/Effect/Trait可见性；public struct的private field只影响physical metadata，不构成source interface leak。`compiler/exports.ring`把source-public surface与exact private-layout metadata分开；private impl保留内部，public inherent只导出pub member，trait impl只有target+trait均可见才导出。Impl-member extern由B-201整体删除，不在本项保留visibility分支。`docs/lang-spec/{syntax,traits,modules,type-system}.md`、examples/fixtures同步。

**约束**：Provider/trait dictionary/TypedHIR/CoreHIR/ExecutableInventory不新增per-trait-member visibility字段，visibility不得从origin/name/span猜测。`impl PublicTrait for PrivateType`本身合法且参与internal coherence；禁止的是外部发布与private type泄漏。0.1无accidental opaque return；supertrait、associated binding、coherence与qualified-method post-0.1边界不变，source trait body与delegate则服从convergence clean break而不存在。未来sealed/opaque trait必须显式立项。

**验收**：`pub impl`及trait declaration/trait impl的`pub fn`/`pub type`全部稳定hard-fail并给删除建议；inherent public/private method与跨模块visibility保持。Public参数/返回/pub field/public enum payload/nested generic/bound/effect正反例覆盖private leak；public struct private field承载private nominal必须保持source不可见而physical compile/runtime正常。Private-target public-trait与public-target private-trait impl只在module内部可用，不进入dependency method index；same-origin re-export不扩大visibility。Mutation杀死parser skip、source visibility猜测、metadata→source binding、name-first physical lookup、private inherent误导出和单边public impl导出。完整C e2e/golden/structural/parity/self-compile、targeted human/LLM diagnostics、double bootstrap与tracked`dist-c`literal fixed point通过，workflow validator/exact CI全绿。

### B-200 Return-position opaque type / `impl Trait` 设计 [design-align] [P3] [M] [judgment] [queued] [after: B-175] [deferred: post-0.1-release+real-consumer]

> **2026-08-23 用户决定**：0.1不支持return-position`impl Trait`/opaque type；类型推断不能替代API abstraction，但当前没有必要为未来能力增加parser/AST/IR/ABI carrier。首次0.1发布后，以真实factory/iterator/closure API consumer重新设计。

**研究范围**：比较`-> impl Trait`、具名opaque type与显式public wrapper/generic返回；固定“callee选择单一concrete type、caller只能使用公开bounds”的抽象边界。核对associated types、generic capture、effect row、ownership/Drop/RC shape、跨模块ABI、inspection/hash、多个return branch与错误诊断；与`dyn Trait`动态分发严格分开，不因语法相似合并实现。

**进入/产出门**：至少一个仓内或preview真实consumer证明公开concrete type不可接受且wrapper/generic不足；先形成surface/TypedHIR→CoreHIR lowering/ABI与反例矩阵及用户decision dossier。获批前`impl`在type position稳定parse error，public interface引用private concrete type继续由B-199 hard-fail；不得预建OpaqueType、hidden associated type、dictionary slot或backend special case。

### B-201 删除 impl-member extern 假FFI表面并迁移精确内建方法 [design-align] [P1] [M] [judgment] [queued] [before: B-156+B-174]

> **2026-08-24 用户决定，A2 clean break**：0.1不支持impl-member `extern fn`。现行表面没有link name、calling convention、physical representation或collision规则，普通用户声明会失败；仓内唯一正向依赖是Str的20项与Int/Float `to_str`两项std特例，它们依靠C backend的target/method字符串表才工作。删除假能力，同时保持这些公共method的签名、effect、visibility、runtime symbol与行为不变。

**范围 / 文件**：

- `compiler/parser.ring`、AST/checker/resolver/infer/HIR：从inherent/trait impl member grammar与各pass删除ExternFn分支；在impl内遇到`extern fn`于`extern`处给单轮可修hard error，建议“top-level extern + ordinary inherent wrapper”。Top-level `extern fn`/`extern type`路径原样保留。
- builtin/prelude/project唯一assembly：为22项既有公共method安装fixed exact `BuiltinMethodSite + IntrinsicRef + signature`；single/project/prelude共享同一producer，public method lookup只消费typed ref，不按target/name/span/注册顺序重建。
- TypedHIR→CoreHIR/ExecutableInventory：builtin method在Core闭合前成为exact intrinsic contract；MethodCallRef只携callee/evidence/signature identity，不携Borrow/Own/Take/RC策略。AbiIR按穷尽IntrinsicRef tag投影到既有runtime symbol；删除C backend `method_to_runtime_c(type,name)`及相关字符串fallback。
- `std/str.ring`等删除22项impl extern声明并同步fixtures、grammar、human/LLM diagnostics；runtime与无关top-level extern声明不改。

**约束**：不新增用户link-name/callconv/ForeignAbiRef表面，不把未来真实method FFI提前塞进0.1；不保留deprecated alias、old-or-new fallback、name table或impl ExternFn inert carrier。B-156仍只负责top-level extern的`requires {unsafe}`签字；本项不扩大unsafe/HostImport、runtime TCB、公开ABI、qualified method、trait visibility、derive或ResourcePlanner范围；delegate已由convergence clean break独立删除。它是当前#268/#269 physical Core/formal3b的直接前置，复用同一authority，不建立平行P0。

**验收**：

- inherent/trait impl中的public/private/generic/effectful `extern fn`均在exact token稳定hard-fail，human/LLM JSON诊断与恢复不吞后续member；top-level extern与普通wrapper正例保持。
- 22项builtin method逐项核对public签名、effect、method resolution、generated-C call target与native行为；single/project/prelude/re-export输入一致。缺tag、重复tag、错signature、错runtime target及任何name/span fallback mutation全部fail loud。
- 活动compiler/std/examples除专用负例外无impl-member extern，backend无`method_to_runtime_c`或等价`(type-name, method-name)`映射；Core closure validator拒绝backend-only executable/intrinsic。
- 与current aggregate固定SHA一起通过独立review、fresh source-built targeted matrix、deep-Clone scoped delta外的行为/parity门、12GiB fixed point、standard full、targeted ASan、self-host与exact CI；不得用既有sealed packet拼接acceptance。

### B-202 Post-0.1 `IndexMut` / index assignment 重新设计 [feature] [P3] [M] [judgment] [queued] [after: B-175] [deferred: post-0.1-release+real-consumer]

> **2026-08-26 用户决定**：0.1 clean break禁用`x[i] = value`及compound index assignment，只保留index读取与具名mutator；当前IR不为本项保留`IndexPlace`、setter fallback或validator hook。首次0.1后只有真实List/Map/用户类型consumer证明具名方法不足时才重启。

**研究范围**：比较完整`IndexMut` trait、少数内建容器专属语法与继续使用显式mutator；固定List越界、Map缺key时replace-vs-insert、Str不可变、用户类型coherence、`grid[0][1]`嵌套place、求值顺序、`mut self`/alias失效、exact projection与Drop-old/Take-new资源契约。禁止用receiver leaf/name表把赋值偷偷改写成`set`/`insert`。

**进入 / 验收门**：至少一个首次0.1后的真实consumer及用户decision dossier；获批后必须给出唯一ResolvedAST→TypedHIR→CoreHIR place authority、Flow/RcIR exact projected overwrite、single/project与正反例矩阵。获批前parser/checker稳定给可修hard error，仓库只依赖`List.set(mut self, ...)`、`Map.insert(mut self, ...)`等显式API。

### B-203 Post-0.1 polymorphic recursion 应用场景复核 [design-align] [P3] [M] [judgment] [queued] [after: B-175] [deferred: post-0.1-release+real-consumer]

> **2026-08-28 用户决定**：0.1递归组内部按HM monomorphic recursion检查，不支持同一SCC成员以彼此不可统一的类型实例递归调用；普通generic recursion不受影响。当前compiler/std/examples/tests无polymorphic-recursion承诺或真实consumer，0.1 IR/checker不预留annotation、rank、carrier、fallback或兼容路径。

**进入门**：首次0.1发布后，至少一个真实程序必须证明其递归环确实需要同一函数/方法在两个不可统一的实例上调用，且普通泛型递归、显式sum/erasure、拆分非递归wrapper或数据结构重写均不足。只有用户确认该场景值得扩大类型系统后才进入planning。

**届时研究范围**：比较显式完整签名下的受限polymorphic recursion与继续拒绝；核对可判定性、principal type、termination、trait/effect参数、dictionary/evidence ABI、跨模块scheme与诊断。不得以当前A+递归组实现“不够通用”为由提前启动，也不得回填0.1空carrier。

### B-204 Proper callable-occurrence ResolvedAST 与恢复同检查单元具名函数值推断 [design-align] [P1] [L] [judgment] [queued] [after: B-175] [deferred: post-0.1-release]

> **2026-08-29 用户决定，高优先级post-0.1恢复项**：0.1为按时闭合#268/#269采用H0：同一尚未闭合A1 scheduling unit内，named callable作为first-class value时provider registration header必须递归closed，通常由显式完整`with { ... }`保证。Direct call、import/re-export frozen provider、lambda、fn参数、factory/dynamic/HOF formal不受影响。完整能力在0.1后优先补回；当前实现不得为本项预留ResolvedAST carrier、SCC name resolver、fallback或双路径。

**目标 / 唯一authority**：sole resolver遍历当前0.1所需的callable occurrences，产生`CallableOccurrenceSite { consumer exact executable, structural child path }`与`DefinitionDependency { consumer exact executable, provider exact executable, site }`并冻结进ResolvedNamespacePlan。Tarjan只消费exact dependency；inference在这些site只消费resolver已选provider及唯一instantiation receipt，不再按relative name、scope prefix或`env.lookup`重新选择。Import/re-export与same-origin diamond原样复用provider；static self/member使用既有exact member facts；receiver-type-dependent dynamic method继续由TypedHIR选择，不为“完整ResolvedAST”扩张当前范围。

**删除边界**：以正常commit撤销/退休`e0986b7c`及baseline SCC中的bare-name、shadow-set、relative-string、direct-call AST name edge；删除inference对已resolved callable site的provider reselection，仅保留exact一致性验证。不得保留dependency-only mini-resolver、registration body scan、source-order规则、whole-file monomorphic group、post-HIR patch或第二lookup authority。

**验收**：覆盖direct call与first-class value、forward/reverse declaration order、参数/let/var/pattern/lambda/handler shadow、inline module、prelude、project import/re-export/diamond、extern/constructor/method namespace分离及source diagnostics；mutation必须杀死错误provider、丢site、换consumer、name fallback和infer重选。固定SHA通过独立resolver/type-effect review、single/project真实matrix、source-build fixed point、standard full、targeted ASan/self-host与exact CI。完成后删除H0显式closed-header限制及对应迁移性诊断。

## 基础设施

### B-187 Repository 文档漂移复核与过期内容清理 [infra] [P2] [M] [judgment] [queued] [after: #268+#269]

> **2026-08-20 用户方向**：当前 ownership 主线完成后，安排一轮 bounded 文档维护，清理再次累积的过期、重复和相互矛盾内容；不打断 I′ → S′ → A′，也不把文档清理包装成新的语言设计。

**范围 / 真值对账**：`AGENTS.md`、root/子目录 README、`docs/*.md`、`docs/lang-spec/`、活动 backlog/audit/Inbox/handoff，以及 `.agents/.claude` provider adapter。以最新 main 的 C11 compiler/runtime/std、可执行测试、tracked bootstrap 和现行 workflow 为事实源，逐项核对：退役 LLVM/JS/旧 anchor 仍被写成现状、完成 item/历史过程残留在活动 spec、失效路径/命令/行号/依赖、设计/规范/实现互相矛盾、重复产品主张、过长 handoff 与断链引用。

**约束**：

1. 先形成有界 inventory，每项只允许 `仍正确保留 / 直接修订 / 删除并由 Git 保留历史 / 新建具体 backlog finding / 用户决策` 五种结论；不得凭措辞陈旧机械删掉仍承载公开语义或 safety/ownership 约束的文本。
2. 文档事实可由当前设计唯一推出时直接同步；涉及公开语义、保证、release gate、平台支持或路线重排时停止该项并形成 decision dossier，不在 cleanup 中偷渡。
3. 活动 spec 只保留当前目标、约束、验收和必要 blocker；逐轮实验、已拒绝候选、长日志与完成历史回归 Git/evidence index。provider adapter 不复制 `docs/workflow.md` 全文。
4. 本项默认只改文档/adapter/文档验证器；发现实现 bug 只立可复现 item，不顺带改 compiler/runtime/std/tests。

**验收**：inventory 100% 有结论与证据锚；所有保留的本地路径/命令/Markdown link 可解析，C-only 构建/测试说明与当前入口一致；活动看板、audit、Inbox、handoff、CLAUDE/design/lang-spec 无已知状态/依赖冲突；retired backend 不再作为现行 oracle/依赖，完成流水不占活动真值；`python .agents/scripts/validate_workflow.py` 与适用的文档/link/example checks 通过；独立 reviewer 以 `current / historical / future` 三类边界主动寻找误删与漏删。

### B-179 project manifest 与可复现 dependency lock [feature] [P2] [XL] [judgment] [queued] [after: B-175]

首个 preview 允许以 entry `.ring` 文件作为 project root，不等待 registry；随后补 `ring.toml` + lockfile，把编译器/std 兼容、local/path/git dependency、feature/capability 与构建输入变为可复现真值。Registry、账号、签名服务与付费托管不在本项。

**约束**：依赖以内容 hash 锁定，解析确定、离线可重放；manifest/lock 进入 project/source fingerprint；禁止 build script 隐式联网或执行未声明代码；同包多版本、cycle、checksum mismatch 与 compiler/std 不兼容 fail closed。包管理用户面遵守 lang-design 的“先可复现/内容寻址/锁定，再 registry”。

System capability由B-195的transitive TypedHIR/inspection summary提供；manifest可声明依赖允许的`console/fs/process`集合并fail closed，但0.1不得把该静态政策宣传为OS sandbox。HandledEffectRef、fail、mut与unsafe保持各自规则，不进入HostImport许可列表。

**验收**：local/path/git 正反例、transitive lock、离线 clean build、缓存失效、冲突/环/篡改诊断；Windows/Linux 相同 lock 得到相同依赖图与生成 C；现有无 manifest 单/多文件项目保持兼容。

## 测试基础设施

### B-153 verify_rc mutation testing harness [infra] [P3] [M] [judgment] [queued]

> 2026-06-27 立项（Discussion，#205 审计发现触发）。verify_rc 负面测试 22 类中仍有 9 类（均为 fatal 类别）缺专用测试。这 9 类无法用正常 Ring 源码触发——仅在 RC pass 本身出 bug 时产生。需要 mutation testing harness 自动注入缺陷并验证检测。

**设计**：
- 对 perceus.ring 产出的 post-RC HIR 进行定向 mutation（如删除 drop 插入、跳过 dup、交换 drop/dup 位置）
- 每次注入一个 mutation，运行 verify_rc，断言报出对应类别的错误
- 覆盖剩余 9 类 fatal 判据

**涉及修改**：
1. `tests/mutation_rc.py`：mutation harness——读取编译器对测试用例的 RC 标注输出，注入 mutation，跑 verify_rc
2. 需要编译器暴露 post-RC HIR 的可序列化形式（或 harness 直接 patch verify_rc 的输入数据结构）
3. 每类 fatal 判据至少一个 mutation 用例

**验收标准**：
- 22/22 verify_rc 负面测试类别有覆盖
- 每个 mutation 被 verify_rc 正确检测
- harness 可重复运行，无误报
- #205 审计条目可删除

## 已知 Bug / 技术债

### B-165 跨 catch（setjmp/longjmp）边界的 `let mut` 写入丢失 [bugfix] [P1] [M] [judgment] [queued] [after: B-168]

> **0.1 internal-checkpoint处置（2026-08-30 final census）**：current compiler唯一命中位于`infer_lambda`：`entered_owner`在catch/setjmp保护区内写、longjmp后读取。`d364853e`已把owner enter前移并在catch后无条件cleanup，独立review CLEAR；该局部修复随唯一self-host交易验证，不再扩成一般boxed-vars工程。其余compiler 61个catch与std/examples无该exact形态；一般外部B-165仍作为Known Issue迁仓，compiler不新增诊断，workaround为heap `Cell`或让catch显式返回新状态。潜在invalid read/UAF/double-drop/OOB风险必须写入导入issue，不能被描述成安全支持。

> 2026-07-12 立项（B-163 step 6 worker 实测发现，用户拍板方案 b：立案修复，不文档化）。**2026-07-29 前置更新**：暂停单独实现，先由 B-168 确定 C-native failure/control ABI；若显式 failure-status 模型结构性保留普通 C 控制流，本项改为验证后关闭，若 cleanup stack + `setjmp`/`longjmp` 胜出，再执行下面的精确 boxed-vars 方案。

**现象**：`let mut progress = 0; let r = { progress = 1; raise_x() } catch { _ => progress + 100 }` ——当前 C `-O2` 下 catch arm 与后续代码读到 `progress = 0`（写入丢失）。**gen_try_catch 的 B-089 G-b 注释宣称的「body 内 let mut 赋值对外可见」不成立**：跨 setjmp 修改的非 volatile 局部变量在 C 中是 indeterminate。golden 零覆盖（有则早红）。

**条件修复方向（原拍板，等待 B-168 复核）**：若最终模型仍使用 `setjmp`/`longjmp`，复用 B-091 boxed_vars 装箱机制，不用 `volatile`——在共享层（checker/HIR）识别「catch body 内被写、body 外可见」的 mut 变量，并入 `program.boxed_vars` 集合，复用现有堆 cell 读写路径。若 B-168 选显式 failure-status lowering，则不得为已不存在的 longjmp 边界保留装箱成本，只保留同一回归证明写入可见。

**验收标准**：
- 上述场景 C/native 输出 `101 1`（写入可见）
- 新增 golden 用例锁定（catch body 写外层 mut：捕获路径 + 正常路径 + 嵌套 catch）
- 全部 E2E + golden + rc 通过；动 RC 相关（box dup/drop）→ golden ×3

### B-162 Perceus FieldAccess scalar reassign 不消费旧 boxed scalar [bugfix] [P1] [M] [judgment] [queued]

> **0.1 internal-checkpoint处置（2026-08-30 用户决定）**：现有DropOldPlace实现不再单独消费focused/full/ASan验收交易；由唯一clean-current self-host/fixed-point交易覆盖compiler真实字段写。该交易不失败则随其他Known Issues迁仓继续验证；若命中并阻止self-host才返修。

FieldAccess overwrite 不消费旧 boxed scalar，造成线性泄漏。优先在共享 FlowIR/ResourcePlanner/RcIR 定义 overwrite；AbiIR/C emitter 只 materialize 已验证的 load/drop/store，不能复制 ownership authority，且 target 只求值一次。本项不与 unboxing 混做。

**验收**：FieldAccess/嵌套 lvalue 对旧值恰好消费一次，Ident 不回归；verifier 可见，循环不线性增长；完整 C e2e/RC/ASan/self-host/fixed point 通过。

### B-185 raw buffer grow/move 与用户 raw alloc 的边界语义收口 [bugfix] [P2] [M] [judgment] [queued]

B-164 已把 `ring_slot_alloc`、`ring_buf_alloc`、`ring_buf_alloc_zeroed` 的空句柄、请求范围与分配失败收口，但同族入口仍有独立缺口：`ring_buf_grow` 直接把新容量转为 `size_t` 且不检查返回值；`ring_slot_move` 的正数 `count * sizeof(void*)` 未验证可表示；用户面的 `ring_raw_alloc` 对 zero/negative 仍继承平台差异。三者不得因“相邻”就共享未经设计的 fallback，尤其 `ring_raw_alloc` 属于显式 raw-pointer API，先核对现行 unsafe/Ptr 语义与公开 break 边界。

**范围**：`ring_runtime.cpp`、相关 `std/*.ring` extern 契约与 native-only/ASan 回归。保留 B-164 的 zero empty-handle 与 owner 无条件 dealloc 真值；增长/搬移只接受已验证的非负长度和可表示字节数，失败在产生无效 `Ptr` 前响应该入口的稳定诊断。`ring_raw_alloc(0)` 是返回空句柄、最小物理块还是显式拒绝，必须先由既有 Ptr 设计唯一推导；若会改变公开 unsafe API，转 decision dossier，不猜。

**验收**：zero/边界/正常增长与搬移的可证伪矩阵；请求范围与分配失败不延迟成后续 null/越界；Windows native + ASan gating、Linux C runtime 编译门、完整 e2e/structural/self-host fixed point 通过。

### B-160 rebind_fn_type / update_fn_effects 不查 impl_methods [bugfix] [P2] [M] [judgment] [queued]

> **0.1 internal-checkpoint处置（2026-08-30 用户决定）**：A1 exact store已有实现，不再安排独立1–3小时验证；唯一clean-current self-host/fixed-point交易负责验证compiler Parser impl与std impl真实路径。成功即迁仓后继续一般矩阵，失败且命中self-host才返修。

> 2026-06-30 立项（B-159 修复过程中发现的残留问题）。

`rebind_fn_type`（infer_decl.ring:1815）和 `update_fn_effects`（infer_ctx.ring:551）都用 `ctx.env.lookup(name)` 查 scope stack，但 impl 方法在 `trait_reg.impl_methods` 映射中，查不到。导致 impl 方法 body check 后的 inferred effects/return type 不回写 scheme。

B-159 靠注册时共享 closure 参数 effect tail 绕过了 HOF 场景，但非 HOF 的 impl 方法（如声明了 effects 但 body 实际 effect 更窄的方法）可能有 effect 信息不准确的问题。

此外，prelude 方法的 check 路径不走 `check_one_decl_with_rebind` 而是直接 `check_decl`，修了会导致编译器自身大量 W0001——需要协调处理 prelude 注册的 effect 推断。

**涉及修改**：
1. `infer_decl.ring`：`rebind_fn_type` 增加 `impl_methods` 查找路径
2. `infer_ctx.ring`：`update_fn_effects` 同上
3. `infer_decl.ring`：prelude check 路径走 rebind（需处理 W0001 级联）

**验收标准**：
- impl 方法的 scheme 在 body check 后正确反映 inferred effects 和 return type
- prelude 方法（List::map 等）的 scheme 正确
- 编译器自举一致 + 全量测试通过

### B-073 Row poly 降级为语法糖 + 单态化 [refactor] [P3] [M] [judgment] [queued]
Row poly 从类型系统一等概念降级为语法糖（design.md 1.4，2026-05-25 决策）。编译期通过单态化消除 `RecordType`，pub fn 禁止 row poly 参数。

**涉及修改**：
1. `unify.ring`：移除 row unification（~260 行），替换为"检查 struct 是否有所需字段"
2. `types.ring`：`RecordType` 降级为 desugar 中间表示，不出现在最终类型
3. `infer.ring`：row poly 函数标记为需单态化，收集调用点具体类型
4. `codegen.ring`：为每个具体类型生成特化版本（同泛型单态化）
5. `checker.ring`：pub fn 使用 row poly 参数 → 编译错误

**验收标准**：
- 现有 row poly 测试（row_basic/multi_field/generic/reject）全部通过
- pub fn 使用 row poly → 编译错误
- `RecordType` 不出现在 HIR 最终类型中
- 如存在匹配 trait → trait 归化（可选，增量实现）
- 全部 E2E 测试通过
- 自举编译器正常编译自身





### B-070 固定长度数组 `[T; N]` [feature] [P2] [M] [judgment] [queued]

编译期长度值类型；N 属 const generic，布局连续，不隐式退化 List。与 refinement、repr/FFI、placement 在 planning 统一核定。解析/统一/布局/bounds-check 在共享层，不保存旧后端清单。

**验收**：声明/字面量/索引/迭代/长度等式、越界、嵌套/FFI；不同 N 不混用，动态长度用 List；完整 C/self-host 回归。

## 增量编译（远期）

### B-105 增量 check / 原生编译（HIR cache + per-module object）[feature] [P3] [XL] [judgment] [queued] [after: B-180] [deferred: measured-build-cost]

当前 project check 每次重做 module graph/parse/check，C build 还把所有模块发射为一个 translation unit。只有 B-180 证明 unchanged-module 重复工作在已完成内层热点/runner 优化后仍是主导成本才启动；planning 先决定 type-checked HIR/export cache、跨模块单态化实例、struct/trait/enum ABI、依赖失效与 cache key 的唯一所有者。

**验收**：改一文件只重新 parse/check 受影响 module，并只重编该文件及受影响实例；clean/warm 的诊断、HIR/export、生成 C 与执行语义一致；多 object 链接与单 translation unit golden 一致；cache 可解释、可失效、compiler/std/toolchain mismatch fail closed；完整 C/native 与自举回归通过。


## 架构与备忘边界

后端、RIIR 与信任策略见 design §10.4/§7；本看板只保留未完成 item。取消方案、完成路径和非正式 TODO 留 design/Git；新工作必须取得 B-ID、依赖和验收。
