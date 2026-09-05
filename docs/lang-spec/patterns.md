# 模式匹配

模式的唯一 EBNF 见[语法](syntax.md#模式)。本页只定义名称解析后的绑定与穷尽性语义。

## 模式形式

| 模式 | 语法 | 匹配条件 |
|------|------|----------|
| 通配符 | `_` | 任何值 |
| 绑定 | `x` | 任何值，绑定到 `x` |
| 字面量 | `42`、`"hi"`、`true` | 值相等 |
| 位置构造器 | `Option::Some(x)` | enum 变体 tag 匹配，递归匹配字段 |
| 命名构造器 | `Shape::Point { x, y }` | enum 变体 tag 匹配，按名称匹配字段 |
| Tuple | `(a, b)` | 元素逐个匹配 |
| Arm-level Or | `A \| B` | match/catch arm 顶层的任一备选模式匹配 |

### 绑定 vs Unit 变体消歧

Pattern path 使用统一 `Ident`/`Path` token；首字母大小写不参与分类。如果 bare single-segment path 的 exact 名称解析到当前作用域中的零字段 enum variant（如显式导入后的 `None`），它被归为 constructor pattern，否则才是 binding。限定 path 和带 payload 的 pattern 不回退为新 binding，同样只按 exact declaration identity 判断。Enum constructor 默认使用 owner-qualified path；bare constructor 必须经显式 import 建立。

Qualified 或 constructor-shaped pattern 必须在 Resolver 命中 exact enum constructor；已知 named constructor 的 field occurrence 同样必须命中该 owner 的 exact field。缺失 constructor、缺失 field 或错误 member category 不能作为 unresolved-name 占位或 type-dependent selection 下沉。Field 的类型兼容性与 pattern 穷尽性仍由 Checker 处理。

### 命名构造器模式的特殊语法

**Field punning：** `{ x }` 等价于 `{ x: x }`——字段名同时作为绑定名。

**部分匹配：** `{ x, .. }` 忽略未列出的字段。没有 `..` 时，所有字段必须显式列出。

## 模式绑定规则

```
bind_pattern(pattern, τ_expected) → Γ'

── 通配符 ──
bind_pattern(_, τ) = Γ     （无新绑定）

── 绑定 ──
bind_pattern(x, τ) = Γ[x ↦ τ]

── 字面量 ──
bind_pattern(42, Int) = Γ     （无新绑定，验证类型匹配）

── 位置构造器 ──
bind_pattern(V(p₁, ..., pₙ), E<T₁..Tₘ>):
  在 E 的定义中查找变体 V
  实例化变体字段类型：σᵢ' = σᵢ[T₁/P₁, ..., Tₘ/Pₘ]
  对每个 pᵢ：bind_pattern(pᵢ, σᵢ')
  返回扩展后的环境

── 命名构造器 ──
bind_pattern(V { f₁: p₁, ..., fₖ: pₖ, .. }, E<T₁..Tₘ>):
  在 E 的定义中查找变体 V 的命名字段
  按字段名查找每个 fᵢ 对应的类型
  对每个 pᵢ：bind_pattern(pᵢ, field_type)
  `..` 使未列出的字段被忽略
  返回扩展后的环境

── Tuple ──
bind_pattern((p₁, ..., pₙ), (T₁, ..., Tₙ)):
  验证元素个数匹配
  对每个 pᵢ：bind_pattern(pᵢ, Tᵢ)
  返回扩展后的环境

── Or ──
bind_pattern(p₁ | p₂ | ..., τ):
  对每个 pᵢ：bind_pattern(pᵢ, τ)
  所有子模式必须绑定相同变量集
  变量类型必须兼容
  返回统一后的环境
```

同一 pattern 内重复 binder 是错误。Or-pattern 每个 alternative 必须绑定同一 spelling 集合，arm 内对应 spelling 共享同一个 logical binding identity；不同 alternative 的 source occurrence 不会创建多个 arm binding。类型兼容性仍由 Checker 验证。

## 穷尽性检查

使用 Maranget 风格矩阵算法。目标：验证 match 表达式覆盖了被匹配类型的所有可能值。

### 算法概述

```
check_exhaustive(arms, τ_scrutinee) → null | "missing pattern description"
```

1. **过滤 guard**：带 guard 的分支不参与穷尽性检查（guard 可能为 false）
2. **按被匹配类型 dispatch**

### 按类型的穷尽性规则

**Enum 类型：** 每个变体都必须被至少一个模式覆盖。如果变体有字段，递归检查字段模式的穷尽性。

```vorton
// 缺少 None 分支，因此编译失败
match opt {
    Option::Some(x) => x,
}
```

**Bool 类型：** 必须覆盖 `true` 和 `false`。

**Tuple 类型：** 构建模式矩阵，按列检查每个元素的穷尽性。

**其他类型（Int、Str 等）：** 无穷类型，要求有通配符或绑定模式作为兜底。

### 矩阵算法

```
check_matrix(rows: Pattern[][], col_types: Type[]) → null | Pattern[]

基本情况：
  如果 col_types 为空：
    rows 非空 → null（穷尽）
    rows 为空 → []（未覆盖）

递归情况：
  取第一列的类型 T

  如果 T 是有穷类型（Bool、Enum、Unit、Tuple）：
    对 T 的每个构造器 ctor：
      特化 rows：收集匹配 ctor 的行
      子列类型 = ctor.fields ++ 其余列类型
      递归 check_matrix(特化后的 rows, 子列类型)
      如果不穷尽：格式化缺失模式

  如果 T 是无穷类型：
    收集第一列为通配符/绑定的行
    递归 check_matrix(这些行, 其余列类型)
    如果不穷尽：返回 ["_", ...rest_missing]
```

### 行特化（Specialization）

```
specialize_row(row, ctor):
  first = row[0]
  rest = row[1..]

  first 为通配符/绑定 → [..ctor.fields 个通配符, ..rest]
  first 为字面量 → 如果匹配 ctor 的值则展开，否则跳过
  first 为构造器 → 如果匹配 ctor 名称则展开字段，否则跳过
  first 为命名构造器 → 转为位置形式后展开
  first 为 tuple → 匹配则展开元素，否则跳过
```

### 命名字段 → 位置转换

命名字段模式通过 `named_pattern_to_positional` 转换为位置形式，复用现有矩阵算法：

```
named_pattern_to_positional(variant, named_fields):
  对变体声明中的每个字段名（按声明顺序）：
    如果 named_fields 中有该字段 → 使用对应模式
    否则 → 使用通配符 _
  返回位置模式列表
```

### Or-Pattern

Or-Pattern 允许在单个 match/catch arm 中匹配多个模式，语法为 `p₁ | p₂ | ...`，`|` 分隔备选模式。任一子模式匹配即执行该分支。`|` 只在 arm 的最外层解析；它不是表达式运算符，也不能直接嵌套在 tuple 或构造器字段模式中。

```vorton
match color {
    Red | Green => "warm",
    Blue => "cool",
}
```

支持的子模式类型：enum 变体、字面量、构造器模式、绑定变量。

**变量绑定约束：** Or-Pattern 中的所有子模式必须绑定相同的变量集，且对应变量的类型必须兼容。例如：

```vorton
match val {
    Choice::Left(x) | Choice::Right(x) => x, // 合法：两边共享 x
}
```

**穷尽性处理：** Or-Pattern 中的每个子模式被视为独立的备选项。`Red | Green` 在穷尽性矩阵中展开为两行，分别覆盖 `Red` 和 `Green` 变体。

### 行特化中的 Or-Pattern

```
specialize_row(row, ctor):
  first = row[0]

  first 为 Or → 对每个子模式 pᵢ 递归 specialize_row([pᵢ, ..rest], ctor)
              合并所有结果行
```

## Match 表达式语义

### 分支求值顺序

分支从上到下按顺序检查。第一个匹配的分支被执行。

### Guard

```vorton
match x {
    n if n > 0 => "positive",
    _ => "non-positive",
}
```

Guard 是在模式匹配成功后额外检查的布尔条件。Guard 为 false 时跳到下一个分支。Guard 不影响穷尽性——即使所有模式在语法上覆盖了类型，guard 可能导致运行时匹配失败，因此穷尽性检查忽略带 guard 的分支。

### 非穷尽 Match

如果穷尽性检查失败，编译器拒绝该 match。已经通过检查的 match 不存在可到达的无匹配路径。
