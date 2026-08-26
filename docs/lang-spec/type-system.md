# 类型系统

Ring 使用 Hindley-Milner 类型推断（let-polymorphism），扩展了 effect row、record row polymorphism 和 trait bound。

## 类型

### 原始类型

| 类型 | 描述 |
|------|------|
| `Int` | 有符号整数 |
| `Float` | 浮点数 |
| `Str` | 字符串 |
| `Bool` | 布尔值 |
| `Unit` | 唯一值为 `()` 的单位类型 |
| `Never` | 底类型（无值） |

`Never` 与任何类型统一（它是类型格的底部元素）。它是永不返回的操作（如 `fail.raise`）的返回类型。

### 函数类型

```
FnType = (T₁, T₂, ..., Tₙ) -> R / ε
```

- `T₁..Tₙ`：参数类型
- `R`：返回类型
- `ε`：effect row（见 [Effect 系统](effects.md)）

**函数声明**省略 effect 标注时，编译器推断 effect row（可能为空 `{}` 或非空）。**函数类型表达式**（如 `fn(Int) -> Str`）省略 `with` 子句时为 open row（支持 effect 多态）。纯函数（无 effect）的 effect row 为 `{}`。

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

Tuple 是结构类型：不同上下文中的 `(Int, Str)` 是同一类型。不支持单元素 tuple；`(T)` 就是 `T`。

### Record 类型（Row Polymorphism）

```
RecordType = { f₁: T₁, ..., fₙ: Tₙ }           (* 封闭 *)
RecordType = { f₁: T₁, ..., fₙ: Tₙ, ..α }      (* 开放，带 row 尾变量 α *)
```

Record 是结构类型。开放 record `{ x: Int, ..α }` 匹配任何至少有 `x: Int` 字段的值。尾变量 `α` 捕获其余字段。

Record 类型仅出现在函数参数位置。没有匿名 record 字面量语法。

**Struct → Record 强制转换：** 如果 struct 有所有必需字段且类型匹配，则 struct 类型满足 record 类型约束。

### Option 类型

```
Option<T> = some(T) | none
```

内置 enum。语法 `T?` 是 `Option<T>` 的语法糖。

### 集合类型

```
List<T>      — 可变有序集合
Map<K, V>    — 可变键值集合
Set<T>       — 可变无序集合
```

三者都在标准库中声明为纯 Ring struct。`List<T>` 的值相等/排序操作分别要求 `T: Eq` / `T: Ord`；Map 的 key lookup 与 Set 的成员操作要求 key/element 满足 `Hash + Eq`。公开方法和当前字段定义以 [`std/list.ring`](../../std/list.ring)、[`std/map.ring`](../../std/map.ring) 与 [`std/set.ring`](../../std/set.ring) 为准。

### 类型变量

```
TypeVar = α, β, γ, ...
```

类型变量在推断过程中被创建为 fresh。每个都有一个由单调计数器分配的唯一数字 ID。类型变量可以是绑定的（type scheme 的一部分）或自由的。

## Type Scheme（多态性）

```
TypeScheme = ∀α₁, ..., αₙ. T    其中 bounds = { αᵢ: Trait, ... }
```

Type scheme 量化类型变量，并可选地用 trait bound 约束它们。Type scheme 被赋予 `let` 绑定、函数声明和方法声明。

### 泛化（Generalization）

推断 `let` 或 `fn` 体的类型后：

```
generalize(τ, Γ):
  free_vars  = ftv(τ)                    // τ 中的自由类型变量
  env_vars   = ftv(Γ)                    // 环境中的自由类型变量
  quantified = free_vars \ env_vars      // 量化不在作用域中的变量
  bounds     = collect_bounds(quantified) // 从 var_bounds 收集 trait bound
  return ∀quantified. τ [bounds]
```

出现在环境中的自由变量不被泛化（它们代表来自外层上下文的约束）。

### 实例化（Instantiation）

在多态绑定的每个使用点：

```
instantiate(∀α₁..αₙ. τ [bounds]):
  for each αᵢ: 创建 fresh β
  mapping = { α₁ ↦ β₁, ..., αₙ ↦ βₙ }
  τ' = apply(mapping, τ)
  将 bounds 从 αᵢ 转移到 βᵢ
  return τ'
```

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
unify(α, τ)  其中 α ∈ ftv(τ)  =  Error(E0302: 无穷类型)

── 底类型 ──
unify(Never, τ) = ∅
unify(τ, Never) = ∅

── 原始类型 ──
unify(Int, Int) = ∅
unify(Str, Str) = ∅
  ...（所有原始类型同理）
unify(Int, Str) = Error(E0301: 类型不匹配)

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

── Record ──
见下方 Record Row Unification。

── Effect Row ──
见 Effect 系统规范。
```

### Record Row Unification

```
unify_record_rows(
  A = { f₁: T₁, ..., fₘ: Tₘ, ..α? },
  B = { g₁: U₁, ..., gₙ: Uₙ, ..β? }
):

第 1 步：统一公共字段
  对 A 和 B 中都有的字段名：统一其类型。

第 2 步：划分非公共字段
  A_only = A 有但 B 没有的字段
  B_only = B 有但 A 没有的字段

第 3 步：检查约束
  如果 A_only 非空但 B 没有尾变量 → Error（B 无法接受额外字段）
  如果 B_only 非空但 A 没有尾变量 → Error（A 无法接受额外字段）

第 4 步：求解尾变量
  两边都开放（α, β），两边都有剩余：
    创建 fresh γ
    绑定 α ↦ { B_only, ..γ }
    绑定 β ↦ { A_only, ..γ }

  两边都开放，一边无剩余：
    将无剩余的尾绑定到另一个尾。

  一边开放，一边封闭：
    将开放尾绑定到剩余字段（无 row 变量）。

  相同尾（α = β）：
    无约束。
```

### 替换应用（Substitution Application）

```
apply(subst, τ):
  对类型变量：追踪绑定链（α → τ₁ → τ₂ → ... → 具体类型）
  对复合类型：递归应用到所有子组件
  对 record/effect row：将尾绑定展平到字段列表中
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
  τ₁ 实现 Eq trait 时解糖为 Eq.eq() / Eq.ne() trait dispatch
  ──────────────────────────────────────
  Γ ⊢ e₁ op e₂ : Bool / (ε₁ ∪ ε₂)

── 排序比较（<, >, <=, >=）──
  Γ ⊢ e₁ : τ₁ / ε₁     Γ ⊢ e₂ : τ₂ / ε₂
  unify(τ₁, τ₂)
  τ₁ 实现 Ord trait 时解糖为 Ord.cmp() trait dispatch
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
  构造器：V : (σ₁..σₘ) → E<P₁..Pₙ>
  调用时：实例化构造器，统一参数
  ─────────────────────────────────────────────
  Γ ⊢ V(e₁..eₘ) : E<α₁..αₙ> / (ε₁ ∪ ... ∪ εₘ)

── Enum 变体构造（命名）──
  当名称解析为有命名字段的 enum 变体时触发。
  按名称匹配字段。支持 punning。缺失/多余字段 → E0203。

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
  所有子模式必须绑定相同的变量名集合，且对应变量类型兼容。
  穷尽性检查将 or-pattern 展开为独立行处理。

── Lambda ──
  Γ, x₁:T₁, ..., xₙ:Tₙ ⊢ body : R / ε_body
  ──────────────────────────────────────────────
  Γ ⊢ fn(x₁:T₁, ..., xₙ:Tₙ) { body } : (T₁..Tₙ) → R / ε_body  /  {}

  Lambda 本身不产生 effect。其 body 的 effect 被捕获在函数类型中。

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

  catch 总是消除 fail effect。catch arms 经穷尽性检查（非穷尽报 E0601）。

── Handle ──
  见 Effect 系统规范。
```

### 语句

```
── Let 绑定 ──
  Γ ⊢ e : τ / ε
  σ = generalize(τ, Γ)
  ─────────────────────────
  Γ ⊢ let x = e ⇒ (Γ[x ↦ σ], ε)     x 不可变

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
  List、Map、Set 均实现 Iterable，也支持自定义迭代器。
  Range<Int> 保留特殊快速路径（直接编译为计数循环）。
```

字段赋值要求其root binding可变，并保持同一字段类型。0.1中`IndexExpr`只产生读取值，不是lvalue；index assignment在进入类型/ownership lowering前稳定拒绝。容器更新通过声明为`mut self`的具名方法参与普通调用与mutation推断。

## 方法解析

方法调用 `receiver.method(args)` 按以下顺序解析：

1. **Struct 字段**：如果 receiver 是 struct 类型，检查是否有名为 `method` 的字段。如果找到且可调用，视为字段访问 + 调用。
2. **固有方法**：检查 receiver 具体类型的 `impl_methods[type_name]`。
3. **原始类型方法**：对于 `Str`、`Int`、`Float`，检查原始类型方法表。
4. **Trait 方法**：搜索 `trait_impls` 中为 receiver 类型实现的 trait。
5. **受约束类型变量**：如果 receiver 是带 trait bound 的类型变量，通过 trait dictionary dispatch。

未找到方法时：错误 E0305（未定义的方法）。

## 作用域规则

- 作用域是词法的且嵌套的（函数体、块、for-in 体、match 分支、if-let 体）。
- 每对 `push_scope` / `pop_scope` 创建一个新的作用域层级。
- `let` / `let mut` 绑定从声明点到封闭作用域末尾可见。
- 函数参数在函数体内可见。
- For-in 循环变量在循环体内可见。
- Match 分支模式绑定在该分支的 body 内可见。
- 所有作用域操作受 try/finally 保护以防类型错误时作用域泄漏。
