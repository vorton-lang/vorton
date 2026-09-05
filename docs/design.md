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
| `Token` | Lexer 按唯一词法规范产生 token 与 span；空白和注释不改变语法角色。 |
| `AST` | Parser 忠实保存 canonical surface、结构与 span；不承载名称、类型、effect 或后端结论。 |
| `ResolvedAST` | 每个声明、引用、member、constructor、effect operation、import/re-export 与 extern bridge 都获得 exact identity；下游不再查询名称。 |
| `TypedHIR` | HM metavariable 已求解；类型、effect row、callee、impl、associated type、call-site instantiation 与公开模块接口冻结。合法多态变量转为带 owner 与 ordinal 的 formal；其它 raw 变量被拒绝。 |
| `CoreHIR` | 所有语言级隐式行为已 elaborated 为 explicit typed construct、callable body、edge 或 intrinsic contract。此层是最后的 Vorton semantic representation，不含资源操作。 |
| `FlowIR` | Structured control 降为 ownership-neutral CFG/ANF；pattern projection、scope/control result、normal/failure edge 与全部 cleanup-visible slot 建立；project-wide binder、call、alias 与 capture graph 冻结。 |
| `RcIR` | 唯一 ResourcePlanner 在既有图上显式加入 `Clone`、`Take`、`Drop` 与 `Cleanup`，并输出可独立检查的 certificate；binder 集合与 FlowIR 相同。 |
| `AbiIR` | 已验证语义被投影为 type/tag/field layout、symbol、prototype、closure/dictionary/evidence layout、drop glue、HostImport、extern 与 failure ABI。 |
| `C11` | 对 AbiIR 做确定性、机械的标准 C11 serialization；不再选择方法、推断 effect、解释 pattern 或创建 semantic identity。 |

每个跨层节点保留 `OriginRef`，让诊断回到 source span，而不迫使低层保留整份表面语法。

## Identity 与项目闭包

具名声明和引用使用包含 origin module、namespace、declaration 与 owner 的 exact reference。Re-export 原样转发同一 identity；same-origin diamond 是幂等 delivery，不创建新声明。不同 origin 的相同叶名称永不合并。

局部 binder 使用 owner-scoped identity；normalization 创建的 block、temporary、projection 与 result slot 使用由冻结树位置导出的稳定 path identity。Identity 只由对应阶段建立，不能由共享计数器、遍历顺序或生成符号反推。

所有可执行 body 汇入同一 project-wide `ExecutableInventory`，包括具名函数、method、closure、handler、compiler-defined glue 与 exact intrinsic body。Enum constructor 是 typed construction operation，不冒充 callable。FlowIR freeze 前 inventory 与 call graph 必须闭合；之后新增 executable、binder、edge 或 reachability 都是 internal error。

## 类型、Trait 与 Effect 闭合

HM 类型推断、effect row unification、trait bound 与 associated type selection 在 TypedHIR 前完成。一次 scheme instantiation 只产生一份 mapping receipt；type actual、effect formal-to-actual 与 dictionary/evidence 共同消费该 receipt，不能分别从结果类型重建映射。

自递归和互递归 callable 以调用图的 strongly connected component 为绑定组。组内使用共享 monomorphic provisional variables，所有 body 约束闭合后才原子 final-zonk、generalize 和 publish。组内不支持 polymorphic recursion；组外使用已发布 scheme 正常实例化。

Effect atom 在 TypedHIR 前分为：

```text
SystemEffectRef   console / fs / process
HandledEffectRef  用户 effect 声明
FailEffect        fail<E>
MutEffect         mut<T>
UnsafeEffect      unsafe
```

System effect 只随 exact host call contract 向下传递，不进入 handler evidence，也不能被 `handle`。Handled effect 进入 call/evidence graph并由显式 handler 消除。Failure、mutation 与 unsafe 使用语言规范规定的专用规则。Effect alias 在 CoreHIR 前展开；合法开放尾必须成为正式 `EffectParamRef`，不能作为未解推断变量下沉。

First-class callable 的 body effect 冻结在函数类型中。普通 closure 不捕获创建点的动态 handler 环境；每次调用使用调用点的当前 typed context。该规则对 direct、method 与 indirect call 一致，后端不能建立 closed/open 或 pure/effectful 的平行函数语义。

Trait call 在 TypedHIR 固定为 exact inherent method、builtin intrinsic、concrete trait impl 或 formal dictionary selection。CoreHIR 之后没有 method lookup、impl search 或按名称 dispatch。

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

同一 scope 按 binding 逆序 Drop；aggregate 字段按声明顺序释放，集合元素按其规范顺序释放。Normal return、failure、`break`、`continue` 与 handler exit 都必须执行相同 ownership cleanup。环由显式 weak reference 打破，不引入 cycle collector。

### Mutation 与 alias

Shareable assignment 建立 alias。对任一 alias 的 mutation 使其它仍存活 alias 失效；失效后的读取或写入是编译错误。Liveness 可以把 alias lifetime 缩短到最后使用点，但不能允许 mutation 与其它可观察 alias 并存。

局部 `let mut` 只允许 binding rebind。修改 caller state 的参数、外部 capture 或 mutable receiver 产生相应 `mut<T>` marker，并参与 effect 与 module capability 检查。Call-site mode 和 capture list 是 assertion，不改变推断。

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
- match 与 catch 保持 source arm order；
- 生成文本对相同输入确定，source mapping 可回到原始 span。

后端可以利用 target 属性和优化器，但没有等价机制时必须保留正确性，不能复制类型、effect、pattern 或 ownership 推断。

## FFI、HostImport 与 unsafe

用户 C ABI declaration 只存在于 top-level `extern fn` 与 `extern type`。Impl member 不承载 extern declaration；method 形态由普通 wrapper 表达。Extern declaration 要求所在 module 拥有 `unsafe` capability，声明者负责保证签名忠实；调用仍按声明的 type、effect 与 ownership contract 检查。

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

- ResolvedAST 后没有 unresolved name；AST 不预装 semantic identity。
- TypedHIR 后没有 raw type/effect metavariable；AST/ResolvedAST 不预装最终 type selection。
- CoreHIR 后没有 implicit language behavior；CoreHIR 不含 resource operation 或 target layout。
- FlowIR 后 binder、call graph 与 CFG topology 不变；FlowIR 不含 RC instruction。
- RcIR 中资源行为显式且有 certificate；AbiIR 不重新规划资源。
- AbiIR 后只允许机械 target projection；C serializer 不解释语言语义。

Static inspection 只能证明结构事实；behavior claim 必须绑定 exact candidate、命令、环境和 observed stage。
