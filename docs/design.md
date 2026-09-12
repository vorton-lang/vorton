# Vorton 编译器设计

本文件定义 Vorton compiler 的稳定目标架构与跨层不变量。语言的可观察语法和语义只以 [`lang-spec/`](lang-spec/README.md) 为准；设计公理只以 [`philosophy.md`](philosophy.md) 为准。这里不记录实现进度、任务顺序、过程方案或完成声明。

## 设计约束

1. **事实只产生一次。** 名称、类型、effect、callee、impl、资源与 ABI 各自由信息首次完备的最高层决定，并以 typed carrier 单向传递。
2. **下游不猜测。** 下游不得按字符串、叶名称、声明顺序、span 或 backend fallback 重建上游事实。
3. **上游不回跑。** 一个阶段冻结后，后续阶段不得重新执行 resolver、类型/effect 推断、trait selection 或语义 lowering。
4. **有限且确定。** 编译决策作用于冻结的有限集合；相同输入、配置和工具链指纹产生相同 IR、诊断与生成文本。
5. **非法状态尽早拒绝。** 无法获得 exact identity、closed contract 或完整证据时，在拥有源码位置的最高层报错，不能向下运输 unknown 占位。
6. **优化不可观测。** 优化不得改变求值顺序、effect、failure、ownership transfer、Drop 时点或 ABI contract。

## 确定性求值顺序

同一 evaluation region 内，同级子表达式按源码从左到右求值。Callable 或 receiver 先于 arguments；binary operands、arguments、list/tuple/construction fields 与字符串插值依次求值；index 先求 receiver 再求 index，range 先求 start 再求 end。

`&&` 与 `||` 保持左侧优先和短路。条件只求选中分支；match 先求 scrutinee，再从上到下检查 arm，模式成功后才求 guard。任一子表达式 failure、panic 或 diverge 后，后续子表达式不执行。

会影响上述次序的表达式必须在 FlowIR 前显式化。C11 serialization 必须先按 Vorton 顺序物化 temporary，不能依赖 C 未规定的 operand 或 argument order。

## 编译管线

```text
Source
→ Token
→ AST
→ ResolvedAST
→ TypedHIR
→ CoreHIR
→ FlowIR
→ RcIR
→ AbiIR
→ C11
→ native
```

| 层 | 冻结契约 |
|---|---|
| `Token` | Lexer 按唯一词法规范产生 token、原始字面量拼写与 span；空白和注释不改变语法角色。 |
| `AST` | Parser 忠实保存 canonical surface、数值字面量拼写、结构与 span；不承载名称、数值解释、类型、effect 或后端结论。 |
| `ResolvedAST` | 每个 source library/module、lexical/nominal 声明、binding、constructor、import/re-export 与根引用获得含库归属的 exact identity；已闭合 owner 集合中由当前语法直接选择的 member 同样 exact。显式 effect binder/ref 与 `TraitPath::method<...>` 取得 exact trait/method identity，并保留 actual type、callable shape、parameter qualifier/mode、where predicate 与 effect tree；省略 `with` 的 shape 保留其结构 occurrence。只有依赖 receiver/base type、适用 impl 或 associated selection 的 obligation 才保留 occurrence、已知 base/owner、库来源与源码选择信息，最终 target 留给 Checker。 |
| `TypedHIR` | HM metavariable 已求解；类型、effect row、已解释数值字面量、完整 callable scheme、callee、impl、associated type、call-site instantiation 与公开模块接口冻结。合法 type/effect 多态变量转为带 owner 与 ordinal 的 formal；有限 row 合并义务显式附着于 scheme/instantiation，其它 raw 变量被拒绝。 |
| `CoreHIR` | 所有语言级隐式行为已 elaborated 为 explicit typed construct、callable body、edge 或 intrinsic contract，包括 checked integer panic 与比较 dispatch。此层是最后的 Vorton semantic representation，不含资源操作。 |
| `FlowIR` | Structured control 降为 ownership-neutral CFG/ANF；pattern projection、scope/control result、normal/failure edge 与全部 cleanup-visible slot 建立；project-wide binder、call、alias 与 capture graph 冻结。 |
| `RcIR` | 唯一 ResourcePlanner 在既有图上显式加入 `Clone`、`Take`、`Drop` 与 `Cleanup`，并输出可独立检查的 certificate；binder 集合与 FlowIR 相同。 |
| `AbiIR` | 已验证语义被投影为 type/tag/field layout、symbol、prototype、closure/dictionary/evidence layout、drop glue、HostImport、extern 与 failure ABI。 |
| `C11` | 对 AbiIR 做确定性、机械的标准 C11 serialization；不再选择方法、推断 effect、解释 pattern 或创建 semantic identity。 |

每个 source `OriginRef` 保留 `LibraryId`、库内 source key 与 UTF-8 byte span，让诊断回到唯一输入位置，而不迫使低层保留整份表面语法。

## Identity 与项目闭包

具名声明和引用使用包含 source `LibraryId`、origin module、namespace、declaration 与 owner 的 exact reference。Re-export 原样转发同一 identity；same-library/same-origin diamond 是幂等 delivery，不创建新声明。不同库或不同 origin 的相同叶名称永不合并。每个 source library root 也是 exact module entity；primitive type 与 effect 等 intrinsic 的 Language identity 继续使用独立 origin，没有 source `LibraryId`。Option、Ordering 与 core traits 使用宿主指定 core 库的真实 source identity。

Compiler library 的 Resolver 入口消费宿主指定 entry、唯一 core `LibraryId` 与显式纯内存依赖 DAG；每个库包含 root source、抽象 file-module key 到 UTF-8 source 的映射，以及指向真实库 ID 的直接依赖别名。它不读取文件系统、cwd、OS path、package registry 或网络。先验证整个输入图和每个可达非 core 库到该 core 的显式直接边，随后只解析 entry 可达库；每个可达库 root 必定进入闭包，各库 file/inline/synthetic tree 仍只由本库已解析 source 的实际 import/re-export 扩展。Consumer 不能打开依赖库未达 file body，也不能通过碰巧相同的 key、ID 数字或别名形成边。

Language intrinsic declaration 使用独立 `Language` origin，不通过隐藏 source、虚构 module 或自动 source prelude 注入。官方 core 的协议 declaration、member、generic、Self 与 reference 全部来自指定 core root source；受保护短名直接引用这些 source entity，不按别名、ID 数值或遍历序重建。其他 source declaration、generic 与 local binding 的 identity 同样从冻结的 library、module、owner、declaration site 与语法角色构造。依赖别名只在所属库 root 建立 private Type binding，指向目标库的真实 root；跨库 import、explicit re-export 与 facade 继续消费同一套 binding 和 exact identity。

`ResolvedProject` 仍是一个 owned、opaque 的名称层结果，统一保留 entry、指定 core、可达的直接依赖图、各库原声明归属与引用，以及已经核对的有限 core 角色引用。它不增加可编辑接口摘要、序列化契约或查询框架，也不表示 Checked、TypedHIR 或完整有效接口已经成立。

`prepare_project` 直接消费 owned `ResolvedProject`，以 exact declaration identity 检查 supertrait 目标类别、trait inheritance graph 与 effect alias declaration graph，并返回 owned、opaque 的 `PreparedProject`。成功结果完整保留原项目，只额外承载这些声明不变量已经成立的状态；graph adjacency 与 traversal state 只是准备期间的临时视图。它不形成 effective signature、展开后的 alias、完整 Checker 结果、接口 S 或 TypedHIR，也不重新执行 Parser 或 Resolver。

`check_project` 从同一 `ProjectSources` 依次执行既有 Resolver 与 declaration preparation，建立当前受支持的 source header、formal 和非泛型 alias 规范类型，再绑定选定 contract。它从 exact direct-call graph 建立 callable SCC；每组 body 各生成一次 constraints 与 typed draft，组内调用复用 monomorphic provisional 类型，组外调用实例化已经发布的 scheme。Source 与 contract 约束共同闭合后，整组才 final-zonk、generalize 并原子发布。契约 path 只消费 `ResolvedProject` 内部冻结的 module/namespace binding、真实直接依赖边和 exact entity；该 carrier 不公开名称查询 API，也不重新运行 Parser、Resolver、body inference 或 import fixed-point。失败不返回部分结果。

当前 `CheckedProject` 是 owned、opaque 的窄 Checker carrier。它承载纯值 HM 子集实际形成的 closed callable scheme、每次已发布调用的唯一 type mapping、组内 provisional call 关系、normalized type、interpreted literal、exact direct callee、Borrow/Move parameter convention、whole-binding use 状态闭合、empty effect 事实与每个函数唯一的 typed body；成功结果没有 raw metavariable。Resolver 已验证的 exact core role declaration 只保留其既有依赖 profile，额外 core declaration 仍走普通 Checker 边界。这个结果不是完整接口 S 或最终 TypedHIR，不能向下游暗示尚未检查的 Trait/impl、非空 effect、pattern、partial move、完整 resource 或 callable 事实。

名称选择先在每个适用 namespace 内应用词法 shadowing，再按 path 的 root、每个中间 container 与 terminal category 过滤并合并候选。不能用不合法的跨 namespace candidate 抢占合法结果，也不能为得到结果而回退到同 namespace 已被遮蔽的 declaration。Enum constructor、custom-effect operation 与已知 named construction/pattern field 的 owner 集合已经闭合，缺失或类别错误必须在 Resolver 拒绝；普通 field/method receiver 与 type-relative impl/associated selection 仍是 Checker obligation。Effect 与 effect alias 不是 Type/Value 的 type-relative `::` base。

局部 binder 使用 owner-scoped identity；sequential shadowing 创建新 identity，or-pattern 各分支的同名 binder 则共享一个 arm-scoped logical identity。Normalization 创建的 block、temporary、projection 与 result slot 使用由冻结树位置导出的稳定 path identity。Identity 只由对应阶段建立，不能由共享计数器、遍历顺序或生成符号反推。

项目诊断按 library-graph input、全部 reachable-source frontend、module graph、当前 generation support、declaration/index、import/export 与 body-name 的阶段顺序选择。Source 阶段内统一按 `LibraryId`、logical module path、primary UTF-8 span 与稳定错误类别选首错；只在源码有序遍历已经证明后继位置不可能产生更小候选时短路，不能让 spelling、物理 source key、map 插入顺序、table/subpass 或偶然 traversal 抢先。没有 source span 的依赖图诊断直接携带实际 owner／alias／target 或 cycle chain。

所有可执行 body 汇入同一 project-wide `ExecutableInventory`，包括具名函数、method、closure、handler、compiler-defined glue 与 exact intrinsic body。Enum constructor 是 typed construction operation，不冒充 callable。FlowIR freeze 前 inventory 与 call graph 必须闭合；之后新增 executable、binder、edge 或 reachability 都是 internal error。

## 类型、Trait 与 Effect 闭合

HM 类型推断、effect row unification、trait bound 与 associated type selection 在 TypedHIR 前完成。一次 scheme instantiation 只产生一份 mapping receipt；type actual、effect formal-to-actual、显式 method scheme application 与 dictionary/evidence 共同消费该 receipt，不能分别从结果类型重建映射。

Resolver 只建立 source 显式 effect binder/ref、exact trait/method scheme 引用，保存 actual type、callable shape、parameter qualifier/mode、where predicate 与 effect tree，并保留省略 `with` 的 shape 结构位置。它不创建 per-impl effect mapping，不从 impl 集合汇总 row，不决定隐式 scheme arity、推断尾的求解/泛化，不实例化 actual，也不执行 impl selection、row union/subset 或 conformance。Checker 按 method owner 与稳定结构 ordinal 建立 trait signature 的隐式 effect formals；对应 impl signature 位置映射到同一 contract formal，不能制造第二份不相关 scheme。

自递归和互递归 callable 以调用图的 strongly connected component 为绑定组。组内使用共享 monomorphic provisional variables，所有 body 约束闭合后才原子 final-zonk、generalize 和 publish。组内不支持 polymorphic recursion；组外使用已发布 scheme 正常实例化。

Effect atom 在 TypedHIR 前分为：

```text
SystemEffectRef   console / fs / process
HandledEffectRef  用户 effect 声明
FailEffect        fail<E>
MutEffect         mut
UnsafeEffect      unsafe
```

System effect 只随 exact host call contract 向下传递，不进入 handler evidence，也不能被 `handle`。Handled effect 进入 call/evidence graph并由显式 handler 消除。Failure、mutation 与 unsafe 使用语言规范规定的专用规则。Effect alias 在 CoreHIR 前展开；合法开放尾必须成为正式 `EffectParamRef`，不能作为未解推断变量下沉。

有 body callable 的推断 row 为 `A`，显式 source 上界为 `B` 时，Checker 验证 `A ⊆ B` 并发布 `B`；省略时发布 `A`。Trait method 无显式 `B` 时，完整公开 scheme 按选定 impl 关联，而不是对 impl 集合取 union；trait 有 `B` 时普通调用与 scheme 引用都使用 `B`。Call site 为 effect actual 选择唯一合法的最小正规解，handler 只消除已知 exact head，未知 formal 原样保守传播。

Generic row 合并只携带现有 atom identity、fail payload unification 与 handled-effect type argument 产生的有限义务；单一 `mut` marker 去重，具体 state origin 由独立内部事实追踪。实例化后静态检查，不下沉 runtime，也不扩张为通用 constraint language。普通 callable recursion 仍按 SCC 原子闭合；显式公开上界的直接/间接自引用，以及必须猜测自身结果才能决定 type/evidence/effect selection 的循环在 TypedHIR 前拒绝。

First-class callable 的 body effect 冻结在实际 callable 类型中。普通 closure 不捕获创建点的动态 handler 环境；每次调用使用调用点的当前 typed context。该规则对 direct、method 与 indirect call 一致，后端不能建立 closed/open 或 pure/effectful 的平行函数语义。

Trait call 在 TypedHIR 固定为 exact inherent method、builtin intrinsic、concrete trait impl 或 formal dictionary selection。CoreHIR 之后没有 method lookup、impl search 或按名称 dispatch。

### 数值与比较闭合

Checker 是数值字面量解释的唯一 authority。它从 AST 保留的十进制拼写产生固定的 `Int` 或 binary64 值，处理直接一元负号作用于边界字面量的唯一特例，并拒绝其他超范围字面量；这项局部解释不能扩张为通用 const evaluator。TypedHIR 同时冻结每个数值运算的同型 operand、每个比较点的 exact core source trait/member identity，以及结构派生所需的 field evidence。

CoreHIR 在一处显式化 checked `Int` 运算及其 panic、普通 `Float` 运算、`PartialEq::eq`、`PartialOrd::partial_cmp` 到四个排序运算符的映射，以及 `Ord::cmp` 的独立显式调用。Compiler-defined struct/enum 比较 body 同样在 CoreHIR freeze 前按字段与 variant 声明顺序进入 executable inventory。后续层只能运输这些选择，不能按 C 运算符、宿主 trait 或名称重新决定 overflow、rounding、comparison 或 derivation。

`Float` lowering 必须保持语言规范固定的 binary64 普通结果：不得把分离的运算隐式融合为 FMA，不得让额外中间精度或 flush-to-zero 改变结果，也不得将 NaN/Infinity、部分比较或截断 `%` 改写为后端更方便的另一套语义。动态舍入模式、IEEE exception flags、额外 remainder API 与数学函数库没有当前 carrier 或 fallback。

## CoreHIR 语义闭包

CoreHIR 是所有语言 feature 的统一 elaboration 终点。每个 surface construct 必须拥有唯一 TypedHIR-to-CoreHIR lowering，或证明自身已经是 canonical core construct。

在 CoreHIR freeze 前必须显式化：

- short-circuit、pattern decision 与 `for-in` protocol；
- chosen callee、trait dictionary 与 associated type evidence；
- custom handler operation、ordered evidence 与 closure capture；
- exact constructor、intrinsic、extern 与 HostImport contract；
- compiler-defined structural implementation与 drop glue；
- callable effect contract及其 formal instantiation。

CoreHIR validator 拒绝 surface-only variant、未选择 callee/impl/evidence、待生成 executable/body 与其它 implicit obligation。FlowIR 只规范化 evaluation、control 与 pattern；ResourcePlanner 只规划资源；AbiIR 只决定 representation 与 ABI。

## 资源语义

参数默认 borrow；mutation 与 ownership transfer 从 callable body 推断，并可由 source mode assertion 核对。赋值遵守以下语义：

| 来源 | 结果 |
|---|---|
| Fresh value | 新 binding 取得该值 |
| Shareable non-`Drop` lvalue | 增加引用计数，源和目标都保持可用 |
| `Drop` lvalue | Ownership move，源立即失效 |
| Scalar value | Copy，源保持可用 |

显式 `Clone` 产生递归独立副本，不等同于 share。包含资源的值保持唯一 ownership；`Drop` 在 scope-end 执行。编译器只可在类型无用户 `Drop` 且释放时点不可被 `Weak` 观察时提前释放。

拥有用户 `Drop` 的类型不能同时实现 `Clone`。Generic `Drop` impl 若需要在销毁时取得 runtime trait evidence，则在没有显式 object-layout evidence contract 时被拒绝；不需要 runtime evidence 的 unbounded generic `Drop` 仍合法。

同一 scope 按 binding 逆序 Drop；aggregate 字段按声明顺序释放，集合元素按其规范顺序释放。Normal return、failure、`break`、`continue` 与 handler exit 都必须执行相同 ownership cleanup。Panic 直接终止程序，不要求建立 unwind cleanup edge，也不保证尚存值的 `Drop`；panic 前已经完成的 mutation、IO 与资源移交保持发生。环由显式 weak reference 打破，不引入 cycle collector。

### Mutation 与 alias

Shareable assignment 建立 alias。对任一 alias 的 mutation 使其它仍存活 alias 失效；失效后的读取或写入是编译错误。Liveness 可以把 alias lifetime 缩短到最后使用点，但不能允许 mutation 与其它可观察 alias 并存。

局部 `let mut` 只允许 binding rebind。通过 `&mut T` 参数、外部 mutable capture 或 mutable receiver 修改 caller state 会产生单一 `mut` marker，并参与 effect 与 module capability 检查；具体 state origin/type 继续由内部事实保留。Call-site mode 和 capture list 是 assertion，不改变推断。

普通 closure 的 read-only capture 共享已证明 non-owning 的值，mutable capture 共享同一 boxed binding。Ordinary function type 没有 consume-once call mode，因此可能唯一拥有资源的外部 binding 不能通过普通 borrow/mut/move capture 逃逸；这类资源必须保留在可证明的词法 ownership scope。Handler evidence 同样不能隐藏可能唯一拥有的 outer capture。

### Struct update

`Type { ..base, field: value }` 是 move spread：`base` 只求值一次；override expressions 按源码顺序完整求值，并可在提交前读取或借用 `base`。全部成功后，未覆盖字段转入 fresh result，被覆盖旧字段 Drop，override temporary 转入结果，最后 `base` 失效。任何 override failure 都不得留下部分 move。

Named enum variant 不支持 update spread；variant 更新必须在已知 variant 的分支中显式重建字段。

## FlowIR 与唯一 ResourcePlanner

FlowIR 在规划前冻结有限的 type、callable、edge、slot 与 CFG 集合。Normalization 创建全部 cleanup-visible storage 并初始化为空，但不产生资源指令。每个 value edge 被分类为 `Borrow`、`MutBorrow`、`Own` 或 `Discard`。

ResourcePlanner 使用两个独立但关联的有限 shape：

- `LogicalOwnershipShape` 决定值是否可能唯一拥有资源，以及何时必须 `Take` 并使 source 失效；
- `PhysicalRcShape` 决定 aggregate shell 与 payload 是否参与 RC，以及何时物化 `Clone` 或 `Drop`。

Raw/foreign payload 只排除自身的 RC 操作，不能抑制 managed aggregate shell 或 sibling cleanup。Planner 在冻结 call graph 上以有限格求 least fixed point；solve 期间不新增 node/edge，也不回写 type 或 effect。

每个 executable body 的 ephemeral CFG 使用 `Empty`、`Live`、`Moved` 与 `MaybeMoved` 状态处理 branch、loop、failure 和 handler join。`Take` 保存 exact source value并立即清空 source；assignment 固定为“求值完整 RHS → ownership 转入 temporary → Drop 旧 target → 写入 target → 清空 temporary ownership”。RHS divergence 没有后继。

Planner 输出的 certificate 记录冻结图身份、seed、最终 cell、每次单调提升的规则与前提、CFG state 和每个资源指令 witness。Verifier只检查 certificate 与 RcIR，不运行 resolver 或第二个 ownership solver。Codegen 只接受验证过的 RcIR。

## ABI 与 C11 后端

AbiIR 是语言语义与目标表示之间的唯一边界。它只能投影已经存在的 call、control、resource 和 effect事实，不得增加 fallback、隐式 call 或 ownership。

C11 主路径遵守：

- 发射单个标准 C11 translation unit，并调用外部 C toolchain；
- type id、tag、field、symbol、prototype、closure、dictionary、effect evidence、failure 与 drop glue 全部来自 AbiIR；
- 需要定序的操作先物化为 temporary；
- 字符串携带显式长度并保持 binary-safe；
- fixed-width integer 运算显式实现语言的 overflow 与 division 规则，避免 C signed-overflow undefined behavior；
- binary64 运算显式保留语言规定的舍入、特殊值与截断余数结果，不能依赖 C 浮点环境、隐式 contraction、额外精度或 flush-to-zero；
- match 与 catch 保持 source arm order；
- 生成文本对相同输入确定，source mapping 可回到原始 span。

后端可以利用 target 属性和优化器，但没有等价机制时必须保留正确性，不能复制类型、effect、pattern 或 ownership 推断。

## FFI、HostImport 与 unsafe

用户 C ABI declaration 只存在于 top-level `extern fn` 与 `extern type`。Impl member 不承载 extern declaration；method 形态由普通 wrapper 表达。`extern fn` 必须显式写出外层 effect row（pure 也写 `with {}`），并要求所在 module 拥有 `unsafe` capability；声明者负责保证签名忠实，调用仍按声明的 type、effect 与 ownership contract 检查。

Host-facing operation 以 exact `SymbolRef`/`CalleeRef` 进入 TypedHIR，并在 AbiIR 成为包含 ABI symbol、参数、返回、failure 与 system-effect contract 的 `HostImport`。Target 只选择 provider，不能按调用叶名恢复能力或 ABI。

`Ptr<T>` 是可复制、非 RC 的 raw address value；保存或传递地址本身不产生 `unsafe`。Allocation、deallocation、dereference、move-in/move-out、pointer arithmetic 与 raw copy 等操作产生 `unsafe` obligation，且只能由词法 `unsafe { ... }` discharge。`unsafe` block 不消除其中的 system、failure、mutation 或 handled effect。

Raw memory 中的 initialized state 与 ownership 由 unsafe 封装作者负责。安全值的内部布局不通过泛型 address-of 暴露；任何 C-compatible field layout 都需要独立、完整的语言 contract，不能由默认 layout 推断。

## 后端无关数据契约

- Numeric behavior 由语言规范决定，后端不得从 host width 或 C 的 undefined/implementation-defined behavior 推导语言语义。
- `Str` 是 UTF-8 byte string；长度、索引、切片和容量的默认单位是 byte。Unicode scalar 或 grapheme 操作必须使用名称明确的独立接口。
- 默认 aggregate layout 不公开；字段重排、boxing、unboxing 与 reuse 只能在不可观测时进行。
- Tail position、signature-compatible 且没有待执行 `Drop` obligation 的调用保证 bounded stack。Direct self recursion 可降为 loop，其它情况使用 trampoline 或 target 保证，不能依赖优化器偶然完成。

## 验证边界

每个阶段都验证自己冻结的 contract，并拒绝上游 unknown 或下游事实提前出现。至少保持以下双向边界：

- ResolvedAST 后没有普通 unresolved name；闭合 owner-member lookup 不能留下空 target。待 Checker 决定的 member/associated selection 必须已有 exact occurrence 与全部已知 base/owner，不能退化为字符串占位。AST 不预装 semantic identity。
- TypedHIR 后没有 raw type/effect metavariable；AST/ResolvedAST 不预装最终 type selection。
- CoreHIR 后没有 implicit language behavior；CoreHIR 不含 resource operation 或 target layout。
- FlowIR 后 binder、call graph 与 CFG topology 不变；FlowIR 不含 RC instruction。
- RcIR 中资源行为显式且有 certificate；AbiIR 不重新规划资源。
- AbiIR 后只允许机械 target projection；C serializer 不解释语言语义。

Static inspection 只能证明结构事实；behavior claim 必须绑定 exact candidate、命令、环境和 observed stage。
