# 类型系统

Vorton 使用 Hindley-Milner 类型推断，并扩展 effect row 和 trait bound。具名函数声明可以泛化；普通局部 `let` 保持 monotype，同一次求值的结果不会因重新绑定而获得多态实例。

类型表达式、参数和调用的唯一 source EBNF 见[语法](syntax.md)；本页的公式是名称解析后的类型规则，不是第二份 parser grammar。

## 类型

### 原始类型

| 类型 | 描述 |
|------|------|
| `Int` | 固定 64 位的有符号整数，范围为 −2^63 至 2^63−1 |
| `Float` | 采用 IEEE 754 binary64 值模型的浮点数 |
| `Str` | 字符串 |
| `Bool` | 布尔值 |
| `Unit` | 唯一值为 `()` 的单位类型 |
| `Never` | 底类型（无值） |

`Never` 与任何类型统一（它是类型格的底部元素）。它是永不返回的操作（如 `fail.raise`）的返回类型。

### 当前 Checker API 支持边界

当前 `vorton_compiler::check_project` 闭合普通 module／inline-module 函数的第一段 HM 子集。类型限于 `Int`、`Float`、`Bool`、`Unit`、`Never`、这些类型或函数 formal 组成的 tuple，以及可展开到同一集合的非泛型 type alias。函数可声明无 bound 的 type parameters；内部函数可省略参数和返回类型并由 body 推断、泛化。Metavariable、声明 formal 和已发布 scheme 在内部保持不同身份，成功的 `CheckedProject` 不保留未解 metavariable。`Str`、container、用户 nominal、generic alias、associated type、callable shape、Trait bound 和 effect formal 仍稳定返回 `Unsupported`。

直接调用对已发布 scheme 每次产生一份 fresh mapping，参数与返回关系共同消费该 mapping。同一强连通递归组在未发布状态下共享 monomorphic provisional 类型；每个 body 只形成一次 typed draft，整组求解后才 final-zonk、泛化并原子发布。组外调用可分别实例化为不同 concrete 类型，组内 polymorphic recursion 和 occurs-check 无限类型拒绝。

普通局部绑定保持同一个 monotype。这个入口继续支持 literal、参数／不可变 local 引用、顺序 shadowing、tuple 构造和 concrete ordinal projection、block、if/else、简单 `let`、expression statement、return、本文定义的 primitive 运算与 exact ordinary-function direct call。已解析但不在这组 expression／statement carrier 内的表面仍返回 `Unsupported`。

无 bound 的 generic formal 不默认具有 `Copy`。Checker 对当前子集保留 whole-binding 的 live／moved 状态：完整返回、`let` 转移和 Move 参数调用会转移 owner；互斥分支可各自完整转移一次，顺序重复转移、移交后使用和借入值变成 owned 结果会拒绝。只借用或所有正常出口都已完整移交的 generic owner 可形成 Pure 结果；需要 `D(T)` cleanup、generic partial projection 或 Copy evidence 的路径返回 `Unsupported`。现有 concrete scalar 及全元素 concrete-Copy tuple 保持 Copy 行为。

Source 与 format-1 contract 的 generic function 必须都显式声明同一 formal 数量；已选择的参数／返回条款通过 exact target、declaration binder、type kind、ordinal 和使用关系对齐，未选择的条款无需重复整份 signature。Formal 显示名可以 alpha 改名。Contract 不能把源码推断出的 generic 关系用 concrete type 单态化。`generic_requirements` 未选择和显式 `[]` 继续保持不同输入事实，非空 requirement 尚未支持。实际导出的 public 输入类型和 mode 逐 position 由 source 或所属 contract 明确；private 输入、返回类型和 empty effect 可继续推断。

省略 source effect header 或显式 `with {}` 只有在 body operation 和 exact direct-call graph 都落在上述纯子集，且所有正常出口没有待清理 generic owner 时才形成 empty row。`CheckedProject` 内部保留 closed scheme、调用 mapping、normalized type、数值、exact callee、mode、empty effect、binding/use origin 和每个函数唯一的 typed body，但不公开可编辑 identity／通用查询接口，也不表示完整接口 S 或最终 `TypedHIR`。

## 数值语义

Lexer、Parser 与 AST 只按[词法和语法规范](lexical.md#数值字面量)忠实保留十进制字面量拼写；范围检查与数值解释由 Checker 完成。`Int` 与 `Float` 的普通算术只接受同型 operand，不做隐式跨数值类型转换，也不建立数值重载体系。

### `Int` 算术与字面量

`Int` 的范围固定为 `−9223372036854775808..=9223372036854775807`，不随宿主字长、目标平台、构建模式或优化级别变化。普通 `+`、`-`、`*`、`/`、`%`、一元 `-` 及对应复合赋值始终检查；`unsafe` block 不改变这些运算符的语义。

- 加、减、乘或一元取负的数学结果超出 `Int` 范围时 panic；
- 除数为零的 `/` 与 `%` 均 panic；
- `−9223372036854775808 / -1` 与 `−9223372036854775808 % -1` 均 panic；
- 其他合法除法的商向零截断，余数满足 `a = q * b + r`；非零 `r` 与 `a` 同号，且 `|r| < |b|`。

因此 `7 / 3 = 2`、`7 % 3 = 1`，而 `−7 / 3 = −2`、`−7 % 3 = −1`。这些 panic 不引入 `fail` effect；不可恢复终止与资源边界见 [Panic](effects.md#panic)。普通运算不得静默回绕或饱和。将来的未检查算术只能作为独立 `unsafe` 库或语言能力另行决定，回绕算术只能由独立库能力提供；本规范不设计接口或预留实现占位。

独立的正 `Int` 字面量不得大于 `9223372036854775807`。唯一边界特例是一元负号直接作用于十进制拼写 `9223372036854775808`；负号和字面量之间可以只有任意层透明括号。Checker 将整个形状解释为最小 `Int`：

```vorton
let min = -9223372036854775808;
let grouped_min = -((9223372036854775808));
let too_large = 9223372036854775808; // 错误：独立正字面量超出范围
let overflow = -min;                 // 运行时 panic：这是普通取负
```

该特例不扩展到任意子表达式；其他超范围 `Int` 字面量均被拒绝。模式语法也没有负字面量，详细边界见[模式匹配](patterns.md#数值模式与穷尽性边界)。源码字面量检查只解释当前 literal，不构成通用 const evaluator。

### `Float` 值、算术与字面量

`Float` 采用与 Rust `f64` 对应的 IEEE binary64 值模型，包括有限正常值、subnormal、正负零、正负 Infinity 与 NaN。普通 `+`、`-`、`*`、`/` 的结果按 round-to-nearest ties-to-even 舍入；运算不读取用户可改变的动态舍入环境。一元 `-` 是对应的浮点符号操作。

浮点除零、溢出和无效算术按对应普通浮点规则产生 Infinity、NaN 等结果，不使用整数的 checked panic，也不增加 `fail` effect。下溢正常产生 subnormal 或有符号零。NaN 的算术传播和 bit pattern 只采用 Rust 的对应保证；Vorton 不额外固定算术 NaN 的 payload、符号或跨目标 bitwise 结果。

普通 `%` 是截断余数，非零结果与被除数同号。它按数学余数语义得到对应 binary64 结果，不要求后端通过可能发生额外舍入或溢出的浮点除、乘、减序列实现：

| 输入 | 结果 |
|---|---|
| `5.5 % 2.0` | `1.5` |
| `-5.5 % 2.0` | `-1.5` |
| `1.0 / 0.0` | positive Infinity |
| `0.0 / 0.0` | NaN |
| `-0.0 % 2.0` | `-0.0` |
| NaN 参与、无限被除数、或正负零除数 | NaN |
| 有限被除数、无限除数 | 被除数本身 |
| 结果为零 | 保留被除数的符号 |

源码 `Float` 字面量先作为精确十进制值解释，再恰好舍入一次到 binary64，使用 round-to-nearest ties-to-even。舍入为 Infinity 时 Checker 报字面量范围错误；subnormal 或舍入为零都合法。Infinity 与 NaN 是运行时值，不是新增的 source 关键字或字面量。

普通运算不能因优化而隐式融合为 FMA、保留额外中间精度或 flush subnormal to zero；只有保持上述可观察结果的优化才合法。Vorton 不承诺可观察 IEEE exception flags、可切换的全局舍入模式或完整浮点环境；普通 `%` 也不映射到 IEEE nearest-integer remainder，本规范不增加第二个 remainder API。这里固定的对应边界以 Rust 的 [`f64`](https://doc.rust-lang.org/std/primitive.f64.html) 与 [`Rem`](https://doc.rust-lang.org/std/ops/trait.Rem.html) 普通行为为参考，不把 Rust 文档的后续变化自动纳入 Vorton，也不由此引入 Rust 的其余数值 API。

### 数值复合赋值

`+=`、`-=`、`*=`、`/=`、`%=` 使用对应的普通数值运算，目标和 RHS 必须是同型 `Int` 或同型 `Float`。每次复合赋值依次完整求值 RHS 一次、取得目标当前值、执行运算并写回；不得复制 place 或 RHS 求值。RHS failure 不执行本次写回，RHS 已经发生的其他 mutation、IO 或资源移交不自动回滚。具体 lowering 在后续实现阶段决定。

### Callable 类型与 source shape

```
CallableType = (T₁, T₂, ..., Tₙ) -> R / ε
```

- `T₁..Tₙ`：参数类型
- `R`：返回类型
- `ε`：effect row（见 [Effect 系统](effects.md)）

每个函数或 closure 值都有一个实际 callable 类型。Source 的 `fn(Int) -> Str` 是直接约束该实际类型的 `CallableShape`，不是可放入字段、type argument 或 alias 的匿名存储类型。Shape 只出现在有 body 的直接参数、具名／closure factory 的带括号返回 assertion和 generic bound；其它位置显式使用实际 `F`／`G`。Shape 的参数与结果也都是实际类型，复杂高阶关系必须给每层实际类型显式命名。

有 body **函数声明**省略 effect 标注时，编译器推断公开 effect row（可能为空 `{}` 或非空）；显式 row 是允许上界，完整规则见 [Callable may-effect contract](effects.md#callable-的-may-effect-contract)。`CallableShape` 省略 `with` 时保留开放 row，显式 `with {}` 则是 closed pure row；两种 source 信息不能合并。

函数值适配只允许把该函数值自身的 effect row 从较小 row 扩大到期望上界。参数数量、经普通 substitution 后的参数类型、返回类型与最终固定 mode 必须结构匹配；参数和返回类型没有额外 variance，Borrow／Mut／Move 也不能因 effect 可扩大而互换。Source `call F` 先依据同一实例化中的 Fn／FnMut／FnOnce evidence 选择其中一个固定 mode，不增加第四种 runtime mode。Callable shape 不声明自己的 generic/effect binder，canonical 0.1 不支持 rank-N effect。

固定 parameter mode 的 source assertion 分别是 `&T`、`&mut T` 与 `move T`；省略 mode 保留对应 callable family 的既定推断或固定 Borrow 规则。`&` 不构造引用类型。`scoped` 是 parameter 的不逃逸限定，和 type identity、mode 分别检查；它可与固定 mode 或 `call F` 组合。具名函数／method 需要量化新的实际 callable 类型时显式声明 `F` 并写 shape bound，例如 `F: Fn + fn(Int) -> Int`；匿名 shape 不能绕过这一 binder。

### Struct 类型

```
StructType = Name<T₁, ..., Tₙ> { f₁: S₁, ..., fₘ: Sₘ }
```

Struct 是名义类型：字段相同但名字不同的两个 struct 是不同类型。

### Enum 类型

```
EnumType = Name<T₁, ..., Tₙ> { V₁(S₁, ...) | V₂ { f: S, ... } | V₃ }
```

变体可有位置字段、命名字段或无字段（unit 变体）。同一 enum 的所有变体共享同一类型。

### Tuple 类型

```
TupleType = (T₁, T₂, ..., Tₙ)    其中 n ≥ 2
```

Tuple 是结构类型：不同上下文中的 `(Int, Str)` 是同一类型。不支持单元素 tuple；source 中的 `(T)` 是透明类型分组，仍表示 `T`。AST 保留分组与 span，类型检查时仍按透明分组处理。Factory 返回 shape 的括号要求见[语法](syntax.md#path类型与-effect)。

### Option 类型

```
Option<T> = Some(T) | None
```

`Option<T>` 是指定官方 core root 的公开 source enum，也是唯一类型拼写。Constructor 的精确拼写是 `Some` 与 `None`；默认使用 `Option::Some` / `Option::None`，只有显式 constructor import 才产生 bare binding。类型位置不接受 `T?`；表达式位置的 postfix `expr?` 是独立的传播语法。

### Ordering 类型

`Ordering` 是指定官方 core root 的公开 source enum，按顺序只有 `Less`、`Equal`、`Greater` 三个无 payload variant。Constructor 默认写作 `Ordering::Less`、`Ordering::Equal`、`Ordering::Greater`；只有显式 constructor import 才产生 bare binding。它承载比较 trait 的结果，不隐式提供额外数值方法。

### Language intrinsic 与官方 core 角色

下列 primitive/container identity 由语言以独立 `Language` origin 提供，不是隐藏 source file、虚构 module 或 source prelude：

- Type：`Int`、`Float`、`Str`、`Bool`、`Unit`、`Never`、`List<T>`、`Range<T>`、`Ptr<T>`。

`Option<T>`、`Ordering` 以及 `PartialEq`、`Eq`、`PartialOrd`、`Ord`、`Clone`、`Copy`、`Drop`、`Display`、`Debug`、`Hash`、`FnOnce`、`FnMut`、`Fn`、`Iterator`、`Iterable` 由宿主指定的唯一官方 core root 直接公开声明。Resolver 保存这些 declaration/member 的真实 source identity，并在成功前核对当前名称层可判定的固定轮廓；它不嵌入第二份源码或签名表，也不把该检查称为完整类型或运行语义。

List literal 产生 `List<T>`，range expression 产生 `Range<Int>`，raw address 使用 `Ptr<T>`。本规范不为这些 intrinsic type 声明普通方法，也不把 `Weak`、`Show`、`Json`、`Result`、`Cell`、`Map`、`Set` 或 `StringBuilder` 等普通 source/library 名称隐式加入 Language origin 或 core 角色集合。

### 0.1 raw payload 的 generic aggregate 边界

Vorton 0.1 不允许 `Ptr` 或 non-RC `extern type` 递归出现在 generic aggregate 的 storage type argument 中；例如 `List<Ptr<T>>`、`Option<ForeignHandle>`、`Table<K, Ptr<V>>` 以及用户 generic struct/enum 中保存同类 actual 均报错。Direct `Ptr`/extern value、top-level extern ABI 与只使用普通 Vorton-managed actual 的 generic container/HOF 不受影响。

该限制使 shared generic aggregate 不需要按 payload 名称或布局猜测资源策略。若 generic function 不形成这类 aggregate storage，本条不额外禁止 direct type actual；其 ownership 仍由类型与 ResourcePlanner contract 决定。

Language intrinsic type 与上述 core enum/trait 的短名在 Type namespace 中不可被 file/inline module、其他 source declaration、import/re-export 到不同 identity、任一 generic parameter list 或 owner-scoped associated Type declaration 覆盖。只有指定 core root 的对应真实 declaration 可以定义 core 短名；指向同一 exact identity 的普通 alias/re-export 仍按 module 规则处理。Trait、inherent impl 与 trait impl 的 associated Type 不是保留名检查的例外。这些名字不是词法关键字，不限制 Value 或 Effect namespace 的同名 binding。

### Private nominal representation

字段名称visibility与compiler所需representation metadata分离。Public struct的private field可以递归包含private nominal；该private type不因布局需要而成为source-public。Compiler以exact-owner metadata取得size/tag/field/Drop信息，consumer源码仍不能命名或取得private field。只有private type进入public函数签名、pub field、public enum payload等真正public interface时才稳定报visibility错误。

### 类型变量

```
TypeVar = α, β, γ, ...
```

类型变量在推断过程中被创建为 fresh。每个都有一个由单调计数器分配的唯一数字 ID。类型变量可以是绑定的（type scheme 的一部分）或自由的。

## Type Scheme（多态性）

```
TypeScheme     = ∀α₁, ..., αₙ. T
CallableScheme = ∀α₁, ..., αₙ; E₁, ..., Eₘ. CallableType
                 [trait bounds, finite row-merge obligations]
```

Type scheme 量化类型变量，并可选地用 trait bound 约束它们。Callable scheme 还可以量化由具名 header 显式声明、或由 trait signature 合法结构位置产生的 effect formals。每个 formal 都有 owner 与 ordinal；普通推断 metavariable 不能冒充 formal。Scheme 被赋予函数声明和方法声明；普通局部 `let` 只保存 monotype。Method 的按 impl effect 关系见 [Trait 系统](traits.md#按-impl-关联的-effect-scheme)。

### 泛化（Generalization）

推断具名 `fn` 绑定组的类型后：

```
generalize(τ, Γ):
  free_vars  = ftv(τ)                    // τ 中的自由类型变量
  env_vars   = ftv(Γ)                    // 环境中的自由类型变量
  quantified = free_vars \ env_vars      // 量化不在作用域中的变量
  bounds     = collect_bounds(quantified) // 收集这些变量上的 trait bound
  return ∀quantified. τ [bounds]
```

出现在环境中的自由变量不被泛化（它们代表来自外层上下文的约束）。

### 递归绑定组

自递归和互递归函数/方法按调用图的强连通分量组成递归绑定组。组内成员在推断期间使用同一批 monomorphic provisional variables：引用自己或 peer 时复用该草稿类型，不执行普通多态实例化。整组 body 约束全部求解后，编译器才相对组外环境对每个成员 final-zonk 与 generalize，并原子发布全组 type scheme；任一成员失败时不得留下部分更新。

每个成员的 body 只推断一次。推断结果以尚未 final-zonk 的内部 draft 保留；dictionary/evidence选择、类型替换与最终HIR生成均等到整组约束闭合后执行一次。编译器不得为生成最终HIR重新推断同一body，也不得把未完成的推断状态带入TypedHIR或CoreHIR。

该规则同样适用于顶层函数、inline module 函数和 impl methods。普通泛型递归合法，只要递归环内保持同一类型参数关系：

```vorton
fn repeat<T>(value: T, depth: Int) -> T {
    if depth == 0 { value } else { repeat(value, depth - 1) }
}
```

Vorton 0.1 不支持 polymorphic recursion：同一递归组成员不能在递归环中以彼此不可统一的类型实例调用自己或 peer。该限制不影响函数在递归组闭合后被外部调用点正常多态实例化。

### 实例化（Instantiation）

在多态绑定的每个使用点：

```
instantiate(∀α₁..αₙ; E₁..Eₘ. τ [bounds, row obligations]):
  for each αᵢ: 创建 fresh β
  for each Eᵢ: 创建 fresh effect row εᵢ
  mapping = { α₁ ↦ β₁, ..., αₙ ↦ βₙ,
              E₁ ↦ ε₁, ..., Eₘ ↦ εₘ }
  τ' = apply(mapping, τ)
  将 bounds 从 αᵢ 转移到 βᵢ
  将有限 row-merge obligations 转移到同一 mapping
  return τ'
```

上述实例化只适用于已经闭合并发布的 type scheme。递归组的 provisional scheme 以及尚未完成 final-zonk/generalize 的 callable 不得走该规则。

### 同检查单元的具名函数值

在同一个尚未闭合的检查单元中，具名 callable 作为 first-class value 使用时，其 declaration header 必须已经递归 closed。Pure provider 以显式 `with {}` 闭合 effect，effectful provider 写出完整封闭 row；开放 header 在函数值使用点被拒绝，可改为完整 header 或显式 lambda wrapper。

该限制不影响 direct call、已经发布 scheme 的 import/re-export provider、lambda、函数参数转发、factory closure、dynamic call 或高阶函数 formal 自身的 open effect row。Provider body 仍只推断一次，函数值使用不能提前 generalize 或 publish provider。

一次实例化的 `mapping` 是唯一替换真值：普通类型实参、effect actual、trait dictionary/evidence 与显式 method scheme application 必须使用同一份结果。它们不得分别从最终类型结构重新推导替换关系。Call site 的 effect actual 取满足全部约束的唯一最小正规解；无唯一合法最小解时诊断，不任意扩大或按当前 impl 集合猜测。

每个使用点获得 fresh 类型变量，实现多态复用。

## Unification

类型等式约束求解的核心算法。

### 规则

```
unify(τ₁, τ₂) → Substitution | Error

── 自反性 ──
unify(α, α) = ∅

── 变量绑定 ──
unify(α, τ)  其中 α ∉ ftv(τ)  =  { α ↦ τ }
unify(τ, α)  其中 α ∉ ftv(τ)  =  { α ↦ τ }

── Occurs check ──
unify(α, τ)  其中 α ∈ ftv(τ)  =  Error(无穷类型)

── 底类型 ──
unify(Never, τ) = ∅
unify(τ, Never) = ∅

── 原始类型 ──
unify(Int, Int) = ∅
unify(Str, Str) = ∅
  ...（所有原始类型同理）
unify(Int, Str) = Error(类型不匹配)

── 函数 ──
unify((T₁..Tₙ) → R₁ / ε₁,  (U₁..Uₙ) → R₂ / ε₂)
  = unify(T₁, U₁) ∧ ... ∧ unify(Tₙ, Uₙ) ∧ unify(R₁, R₂) ∧ unify_effect_rows(ε₁, ε₂)
  参数数量不匹配 (n ≠ m) → Error

── Struct ──
unify(S<T₁..Tₙ>, S<U₁..Uₙ>)  =  unify(T₁, U₁) ∧ ... ∧ unify(Tₙ, Uₙ)
unify(S<..>, R<..>)  其中 S ≠ R  =  Error

── Enum ──
unify(E<T₁..Tₙ>, E<U₁..Uₙ>)  =  unify(T₁, U₁) ∧ ... ∧ unify(Tₙ, Uₙ)

── Tuple ──
unify((T₁..Tₙ), (U₁..Uₘ))  其中 n = m  =  unify(T₁, U₁) ∧ ... ∧ unify(Tₙ, Uₙ)
unify((T₁..Tₙ), (U₁..Uₘ))  其中 n ≠ m  =  Error

── Effect Row ──
见 Effect 系统规范。
```

### 替换应用（Substitution Application）

```
apply(subst, τ):
  对类型变量：追踪绑定链（α → τ₁ → τ₂ → ... → 具体类型）
  对复合类型：递归应用到所有子组件
  对 effect row：将尾绑定展平到 row 中
```

## 推断规则

### 表达式

```
── 整数字面量 ──
Γ ⊢ n : Int / {}

── 浮点字面量 ──
Γ ⊢ f : Float / {}

── 字符串字面量 ──
Γ ⊢ s : Str / {}

── 布尔字面量 ──
Γ ⊢ b : Bool / {}

── 标识符 ──
  (x : σ) ∈ Γ
  ─────────────
  Γ ⊢ x : instantiate(σ) / {}

── 二元算术（+, -, *, /, %）──
  Γ ⊢ e₁ : τ₁ / ε₁     Γ ⊢ e₂ : τ₂ / ε₂
  unify(τ₁, τ₂)     τ₁ ∈ { Int, Float }
  ──────────────────────────────────────
  Γ ⊢ e₁ op e₂ : τ₁ / (ε₁ ∪ ε₂)

── 比较（==, !=）──
  Γ ⊢ e₁ : τ₁ / ε₁     Γ ⊢ e₂ : τ₂ / ε₂
  unify(τ₁, τ₂)
  τ₁ 实现 PartialEq trait；== 解糖为 exact PartialEq::eq trait dispatch，
  != 解糖为同一次 exact PartialEq::eq dispatch 结果的 Bool 取反
  ──────────────────────────────────────
  Γ ⊢ e₁ op e₂ : Bool / (ε₁ ∪ ε₂)

── 排序比较（<, >, <=, >=）──
  Γ ⊢ e₁ : τ₁ / ε₁     Γ ⊢ e₂ : τ₂ / ε₂
  unify(τ₁, τ₂)
  τ₁ 实现 PartialOrd trait；求值一次 exact PartialOrd::partial_cmp dispatch，
  按返回的 Option<Ordering> 映射当前运算符
  ──────────────────────────────────────
  Γ ⊢ e₁ op e₂ : Bool / (ε₁ ∪ ε₂)

── 逻辑（&&, ||）──
  Γ ⊢ e₁ : Bool / ε₁     Γ ⊢ e₂ : Bool / ε₂
  ─────────────────────────────────────────────
  Γ ⊢ e₁ op e₂ : Bool / (ε₁ ∪ ε₂)

── 一元取反（-）──
  Γ ⊢ e : τ / ε     τ ∈ { Int, Float }
  ─────────────────────────────────────
  Γ ⊢ -e : τ / ε

── 逻辑 NOT（!）──
  Γ ⊢ e : Bool / ε
  ─────────────────
  Γ ⊢ !e : Bool / ε

── 函数调用 ──
  Γ ⊢ f : (T₁..Tₙ) → R / εf
  Γ ⊢ aᵢ : Aᵢ / εᵢ     unify(Aᵢ, Tᵢ)
  ──────────────────────────────────────
  Γ ⊢ f(a₁..aₙ) : R / (εf ∪ ε₁ ∪ ... ∪ εₙ)

── 方法调用 ──
  Γ ⊢ recv : τ_recv / ε_recv
  在 τ_recv 的 impl_methods 中查找方法 M
  M : (Self, T₁..Tₙ) → R / εm
  Γ ⊢ aᵢ : Aᵢ / εᵢ     unify(τ_recv, Self)     unify(Aᵢ, Tᵢ)
  ─────────────────────────────────────────────────────────────
  Γ ⊢ recv.M(a₁..aₙ) : R / (ε_recv ∪ εm ∪ ε₁ ∪ ... ∪ εₙ)

── 字段访问 ──
  Γ ⊢ e : S<T₁..Tₙ> / ε     字段 f : σ 在 S 的定义中
  σ' = σ[T₁/P₁, ..., Tₙ/Pₙ]     （替换类型参数）
  ────────────────────────────────────────────────────────
  Γ ⊢ e.f : σ' / ε

── Struct 字面量 ──
  struct S<P₁..Pₙ> { f₁: σ₁, ..., fₘ: σₘ }
  fresh α₁..αₙ     mapping = { P₁ ↦ α₁, ..., Pₙ ↦ αₙ }
  Γ ⊢ eᵢ : Eᵢ / εᵢ     unify(Eᵢ, σᵢ[mapping])
  所有声明字段必须提供，不可有额外字段
  ────────────────────────────────────────────
  Γ ⊢ S { f₁: e₁, ..., fₘ: eₘ } : S<α₁..αₙ> / (ε₁ ∪ ... ∪ εₘ)

── Enum 变体构造（位置）──
  枚举 E<P₁..Pₙ> 的变体 V 有字段 (σ₁, ..., σₘ)
  直接构造 V(e₁..eₘ) 时实例化 E 的类型参数并统一字段
  ─────────────────────────────────────────────
  Γ ⊢ V(e₁..eₘ) : E<α₁..αₙ> / (ε₁ ∪ ... ∪ εₘ)

0.1 的位置 constructor 不是普通函数值。带 payload 的 constructor 标识符不能脱离直接构造语法作为参数、返回值、变量或 dynamic callee；例如 `apply(Some, value)` 非法，必须显式写成 `apply(fn(x) { Option::Some(x) }, value)`。直接位置构造、named-field 构造与 nullary variant 求值保持各自语义；编译器不得隐式生成 constructor wrapper。

── Enum 变体构造（命名）──
  当名称解析为有命名字段的 enum 变体时触发。
  按名称匹配字段。支持 punning。缺失或多余字段 → 类型错误。

── List 字面量 ──
  Γ ⊢ eᵢ : Tᵢ / εᵢ     unify(T₁, T₂), ..., unify(Tₙ₋₁, Tₙ)
  ────────────────────────────────────────────────────────────
  Γ ⊢ [e₁, ..., eₙ] : List<T₁> / (ε₁ ∪ ... ∪ εₙ)

── Tuple 字面量 ──
  Γ ⊢ eᵢ : Tᵢ / εᵢ
  ─────────────────────────
  Γ ⊢ (e₁, ..., eₙ) : (T₁, ..., Tₙ) / (ε₁ ∪ ... ∪ εₙ)

── Range ──
  Γ ⊢ start : Int / ε₁     Γ ⊢ end : Int / ε₂
  ──────────────────────────────────────────────
  Γ ⊢ start..end : Range<Int> / (ε₁ ∪ ε₂)
  Γ ⊢ start..=end : Range<Int> / (ε₁ ∪ ε₂)

这里的 `Range` 必须是预声明语言类型；source declaration 或 import 不得以同名 type binding 遮蔽它。

── 块 ──
  Γ ⊢ stmt₁ ⇒ (Γ₁, ε₁)
  Γ₁ ⊢ stmt₂ ⇒ (Γ₂, ε₂)
  ...
  Γₙ ⊢ tail : τ / ε_tail
  ────────────────────────────────────────────────
  Γ ⊢ { stmt₁; ...; tail } : τ / (ε₁ ∪ ... ∪ ε_tail)

  无尾部表达式的块：类型为 Unit。

── If-else ──
  Γ ⊢ cond : Bool / ε₀
  Γ ⊢ then : τ₁ / ε₁     Γ ⊢ else : τ₂ / ε₂
  unify(τ₁, τ₂)
  ─────────────────────────────────────────────
  Γ ⊢ if cond { then } else { else } : τ₁ / (ε₀ ∪ ε₁ ∪ ε₂)

  无 else 的 if：类型为 Unit。

── Match ──
  Γ ⊢ scrutinee : τ_s / ε_s
  对每个分支：bind_pattern(pᵢ, τ_s) → Γᵢ
    Γᵢ ⊢ bodyᵢ : τᵢ / εᵢ
    unify(τ₀, τᵢ)
  check_exhaustive(patterns, τ_s)
  ──────────────────────────────────
  Γ ⊢ match scrutinee { arms } : τ₀ / (ε_s ∪ ε₁ ∪ ... ∪ εₙ)

  支持 arm-level Or-Pattern：p₁ | p₂ | ... | pₖ => body
  所有子模式必须绑定相同的变量名集合和 mode，且对应变量类型兼容。
  穷尽性检查将 or-pattern 展开为独立行处理。

── Lambda ──
  Γ, x₁:T₁, ..., xₙ:Tₙ ⊢ body : R / ε_body
  ──────────────────────────────────────────────
  Γ ⊢ fn(x₁:T₁, ..., xₙ:Tₙ) { body } : (T₁..Tₙ) → R / ε_body  /  {}

  Lambda 本身不产生 effect。其 body 的 effect 被捕获在实际 callable 类型中。

── 字符串插值 ──
  Γ ⊢ eᵢ : τᵢ / εᵢ
  ────────────────────────────
  Γ ⊢ "...${e₁}...${e₂}..." : Str / (ε₁ ∪ ... ∪ εₙ)

── Catch ──
  Γ ⊢ e : τ / ε     fail<E> ∈ ε
  对每个分支：bind_pattern(pᵢ, E) → Γᵢ
    Γᵢ ⊢ handlerᵢ : σᵢ / ε_hᵢ
    unify(τ, σᵢ)
  check_exhaustive(patterns, E)
  ε' = remove_fail(ε ∪ ε_h₁ ∪ ... ∪ ε_hₙ, E)
  ──────────────────────────────────────────────
  Γ ⊢ e catch { p₁ => handler₁, ..., pₙ => handlerₙ } : τ / ε'

  catch 总是消除 fail effect。catch arms 经穷尽性检查，非穷尽时编译失败。

── Handle ──
  见 Effect 系统规范。
```

四个比较 trait 的 exact member、运算符映射、primitive evidence 和关系律见 [Trait 系统](traits.md#比较-trait)。`PartialEq` 只有 `eq`，`Eq` 没有新增方法；不存在 `ne` member、override slot 或默认 body。`Ord::cmp` 是显式全序接口，不会成为排序运算符的第二条 dispatch 路径。Source trait 同样只允许 method signature，不提供 default method body。

### 语句

```
── Let 绑定 ──
  Γ ⊢ e : τ / ε
  ─────────────────────────
  Γ ⊢ let x = e ⇒ (Γ[x ↦ τ], ε)     x 不可变且保持 monotype

── Let Mut 绑定 ──
  Γ ⊢ e : τ / ε
  ─────────────────────────
  Γ ⊢ let mut x = e ⇒ (Γ[x ↦ τ], ε)     x 可变，不泛化

── Let 解构 ──
  Γ ⊢ e : (T₁, ..., Tₙ) / ε
  ─────────────────────────────
  Γ ⊢ let (x₁, ..., xₙ) = e ⇒ (Γ[x₁ ↦ T₁, ..., xₙ ↦ Tₙ], ε)

── 赋值 ──
  x 可变     Γ ⊢ e : τ / ε     unify(Γ(x), τ)
  ─────────────────────────────────────────────────────
  Γ ⊢ x = e ⇒ (Γ, ε)

── 数值复合赋值 ──
  p 是可变 place     Γ(p) = τ     Γ ⊢ e : τ / ε     τ ∈ { Int, Float }
  op ∈ { +, -, *, /, % }
  ────────────────────────────────────────────────────────────────
  Γ ⊢ p op= e ⇒ (Γ, ε)

── If-let ──
  Γ ⊢ e : τ / ε₀
  bind_pattern(p, τ) → Γ'
  Γ' ⊢ then_body ⇒ ε₁     Γ ⊢ else_body ⇒ ε₂
  ──────────────────────────────────────────────
  Γ ⊢ if let p = e { then } else { else } ⇒ (Γ, ε₀ ∪ ε₁ ∪ ε₂)

── While ──
  Γ ⊢ cond : Bool / ε₀     Γ ⊢ body ⇒ ε₁
  ─────────────────────────────────────────
  Γ ⊢ while cond { body } ⇒ (Γ, ε₀ ∪ ε₁)

── For-in ──
  Γ ⊢ coll : C / ε₀     C 实现 Iterable trait
  Iterable::Item = T     Iterable::Iter = I     I 实现 Iterator trait
  Γ, x: T ⊢ body ⇒ ε₁
  ──────────────────────────────
  Γ ⊢ for x in coll { body } ⇒ (Γ, ε₀ ∪ ε₁)

  通过 Iterable trait 协议脱糖：coll.iter() 获取迭代器，循环调用 .next()。
  任何提供该 protocol 的类型都可参与 `for-in`。
  Range<Int> 保留特殊快速路径（直接编译为计数循环）。
```

字段赋值要求其root binding可变，并保持同一字段类型。0.1中`IndexExpr`只产生读取值，不是lvalue；index assignment在进入类型/ownership lowering前稳定拒绝。容器更新通过物化签名为`self: &mut Self`的具名方法参与普通调用与mutation推断。

数值复合赋值遵守[同一数值运算和确定求值顺序](#数值复合赋值)：RHS 只求值一次，随后读取目标当前值并完成一次写回。运算 panic 前已经发生的 RHS effects 不回滚；RHS failure 则不执行该次写回。

所有 direct、method 与 indirect call 都先求 callable/receiver，再按源码从左到右逐个求 argument，并完成该 argument 对应的资源移交。后续 argument 求值或 callee failure 不恢复已经完成的移交；callee 尚未进入时，已经取得的 argument temporary 仍必须按其 ownership contract 清理。Struct update 的提交规则不扩展为普通调用事务。Checker 冻结 type、effect 与 parameter mode contract，资源阶段只消费该 contract 安排操作，不能反向改变 mode 或 effect。一般业务回滚、callback 的次数和业务时机、重试策略仍由库 contract 规定，不成为新的语言事务保证。

## 方法解析

语法先把 `receiver.method(args)` 唯一分类为 MethodCall；它不能解释为函数值字段调用。函数值字段必须显式写 `(receiver.method)(args)`，后者是 FieldAccess 外加普通 Call。MethodCall 按以下顺序解析：

1. **固有方法**：检查 receiver 具体类型声明的固有方法。
2. **原始类型方法**：对于 `Str`、`Int`、`Float`，检查原始类型方法表。
3. **Trait 方法**：检查 receiver 类型可用的 trait impl。
4. **受约束类型变量**：如果 receiver 是带 trait bound 的类型变量，通过 trait dictionary dispatch。

未找到方法时产生未定义方法的类型错误。

## 作用域规则

- 作用域是词法的且嵌套的（函数体、块、for-in 体、match 分支、if-let 体）。
- `let` / `let mut` 绑定从声明点到封闭作用域末尾可见。
- `let` 的 RHS 使用旧环境；同 scope 后续同名 `let` 创建新的 exact identity，可改变类型，不是 assignment。
- 函数参数在函数体内可见。
- For-in 循环变量在循环体内可见。
- Match/catch 分支模式绑定在该分支的 guard 与 body 内可见，不泄露到其他 arm。
- If-let pattern 只在成功分支可见；loop/branch/closure 各保持自己的 lexical scope。
- 显式 closure capture entry 在 closure 创建点的外层 Value scope 解析，不创建新 source binder；capture 完整性、mode/type assertion 与 escape/ownership 由后续检查完成。

Generic parameter 在所属 declaration 的 bounds、signature 与 body 全部可见；trait/impl 外层 generic 也对 member 与内部 closure 可见。所有声明 family 和 member generic list 使用同一规则：同一 table 不得重复，内层 generic 不得遮蔽仍可见的外层 generic。Generic 可以遮蔽普通 module Type binding，但不能遮蔽 Language intrinsic 或受保护 core Type/Trait；筛选 qualified-path candidate 时不能绕过这项同 namespace shadowing。

显式 effect parameter 属于 Effect namespace，并以所属 callable scheme 为 owner；它在该 callable 的参数、返回、外层 effect row 与 body（包括内部 closure）中可见，不进入 Type namespace。一个 callable 的 effect parameter table 不得重复，也不能遮蔽仍可见的外层 effect formal；Language effect spelling 不能被 formal 覆盖。普通 Type parameter 与 effect parameter 的 kind 由各自 namespace 固定，不能在使用处互换。

`Self` 是 struct、enum、trait 与 impl owner scope 中的特殊 Type identity，并由内部 method 与 closure 继承。Owner 环境先于该声明的 generic bounds 和 header 建立，因此 `Self` 覆盖 struct/enum/trait 的 bounds、fields/members，以及 impl 的 bounds、trait/target、member signature/body。它分别表示当前 nominal、trait 的实现者或 impl target，不是全局 Language builtin，也不是 lexer keyword。普通 Type declaration/module/generic binder 与 owner-scoped associated Type 都不能占用 `Self`；owner scope 外按特殊 Type 使用 `Self` 报错。Substitution、associated selection 与 impl/coherence 仍由 Checker 完成。
