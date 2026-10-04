# 模式匹配

模式的唯一 EBNF 见[语法](syntax.md#模式)。本页只定义名称解析后的绑定与穷尽性语义。

## 模式形式

| 模式 | 语法 | 匹配条件 |
|------|------|----------|
| 通配符 | `_` | 任何值，不绑定 |

`_` 是通配符，不是名字：它不引入绑定，也不能作为表达式读取。`let _ = e` 是用通配符解构，与 `match e { _ => () }` 相同：`e` 是位置时不移走它；不是位置时，它的值是临时值，在语句结束时释放。
| 绑定 | `x` | 任何值，绑定到 `x` |
| 字面量 | `42`、`"hi"`、`true` | 值相等 |
| 位置构造器 | `Option::Some(x)` | enum 变体 tag 匹配，递归匹配字段 |
| 命名构造器 | `Shape::Point { x, y }` | enum 变体 tag 匹配，按名称匹配字段 |
| Tuple | `(a, b)` | 元素逐个匹配 |
| Or | `A \| B` | 分支顶层的任一备选模式匹配 |

### 绑定与零字段变体的区分

大小写不参与分类。单段 path 若在当前作用域解析到零字段 enum variant（例如显式导入后的 `None`），它是构造器模式，否则是新绑定。限定 path 和带字段的模式不会退回为绑定。Enum 构造器默认写成带 owner 的 path；只有显式导入后才能写裸名。

限定 path 或构造器形状的模式必须解析到确切的 enum 构造器；命名字段必须是该构造器的确切字段。字段类型与穷尽性由类型检查处理。

### 命名构造器模式

- **字段简写**：`{ x }` 等价于 `{ x: x }`。
- **部分匹配**：`{ x, .. }` 忽略未列出的字段。没有 `..` 时必须列出全部字段。

## 绑定语义

`match`、`if let` 与 `let` 解构的绑定方式由头部决定：按值、`&` 或 `&mut`，与[借出](type-system.md#借出)的规则一致。

### 按值匹配

`match x { ... }` 与 `if let P = x { ... }` 中，每个绑定得到被匹配部分本身：值被拷贝，实体被移走。

- 只要有模式按值绑定了实体部分，被匹配的东西在 `match` 之后就视为已经移交。被匹配的是局部变量、按值参数或它们经字段到达的部分时，整个变量此后不能再使用；是临时值（例如函数调用结果）时没有限制。
- 被匹配的是下标或借出（及经它们到达的部分）时，不能移走其中的实体，按值绑定实体部分是编译错误；改写为 `match &x` 或 `match &mut x`。移走规则见[实体](type-system.md#实体)。
- 只匹配 tag、只用 `_` 忽略实体部分、或只绑定值部分的模式，不移走任何东西。

```vorton
match shape {
    Shape::Circle(r) => 3.14159 * r * r
    Shape::Rect(w, h) => w * h
}
```

### 只读借出匹配

`match &x { ... }` 与 `if let P = &x { ... }` 中，每个绑定都是被匹配部分的只读借出，持续到它最后一次使用。借出期间 `x` 不能被写入、可变借出或移走。

### 可变借出匹配

`match &mut x { ... }` 与 `if let P = &mut x { ... }` 中，每个绑定都是被匹配部分的可变借出，修改绑定就是修改原数据，因此 `x` 必须可修改。借出从分支开始持续到绑定最后一次使用，期间的冲突规则见[别名与修改互斥](type-system.md#别名与修改互斥)。

```vorton
match &mut world.state {
    State::Running { timer } => { timer -= dt }
    State::Paused => ()
}
```

有 guard 时，guard 求值期间绑定只读；guard 成功后绑定才成为可变借出。

无论按值还是借出匹配，选定分支之前，被匹配的位置都视为只读借出：guard 不能写入、可变借出或移走它及其任何部分，所以每个分支匹配的都是同一个值。按值绑定的实体部分在 guard 成立后才取走，guard 读取它时读的是被匹配位置里的那部分。

### `catch`

`catch` 分支绑定的 failure payload 由分支拿走。

## 绑定规则

```
bind_pattern(pattern, τ_expected) → Γ'

── 通配符 ──
bind_pattern(_, τ) = Γ     （无新绑定）

── 绑定 ──
bind_pattern(x, τ) = Γ[x ↦ τ]     （按值、只读借出或可变借出，取决于头部）

── 字面量 ──
bind_pattern(42, Int) = Γ     （无新绑定，验证类型匹配）

── 位置构造器 ──
bind_pattern(V(p₁, ..., pₙ), E<T₁..Tₘ>):
  在 E 的定义中查找变体 V
  实例化变体字段类型：σᵢ' = σᵢ[T₁/P₁, ..., Tₘ/Pₘ]
  对每个 pᵢ：bind_pattern(pᵢ, σᵢ')

── 命名构造器 ──
bind_pattern(V { f₁: p₁, ..., fₖ: pₖ, .. }, E<T₁..Tₘ>):
  在 E 的定义中查找变体 V 的命名字段
  对每个 pᵢ：bind_pattern(pᵢ, fᵢ 的字段类型)
  `..` 使未列出的字段被忽略

── Tuple ──
bind_pattern((p₁, ..., pₙ), (T₁, ..., Tₙ)):
  验证元素个数匹配
  对每个 pᵢ：bind_pattern(pᵢ, Tᵢ)

── Or ──
bind_pattern(p₁ | p₂ | ..., τ):
  对每个 pᵢ：bind_pattern(pᵢ, τ)
  所有子模式必须绑定相同的名字集合，对应名字类型相同
```

同一模式内重复绑定同一名字是错误。Or-pattern 各备选中同名的绑定是同一个绑定。

### 数值模式与穷尽性边界

数值字面量模式只覆盖与它相等的值。模式语法不含一元运算，因此没有负数字面量模式；负数分支用绑定或通配符加 guard。

`Int`、`Float`、`Str` 属于非封闭模式类型，穷尽性检查不枚举它们的值，必须由通配符或绑定兜底。

## 穷尽性检查

使用 Maranget 风格矩阵算法，验证 match 覆盖被匹配类型的所有可能值。

```
check_exhaustive(arms, τ_scrutinee) → null | "missing pattern description"
```

1. **过滤 guard**：带 guard 的分支不参与穷尽性检查（guard 可能为 false）。
2. **按被匹配类型 dispatch**：
   - **Enum**：每个变体都必须被至少一个模式覆盖；有字段时递归检查字段模式。某个字段的类型没有任何值时（例如没有变体的 enum），这个变体不可能出现，不必覆盖：只写 `Option::None` 的分支就覆盖了 `Option<Empty>`。
   - **Bool**：必须覆盖 `true` 和 `false`。
   - **Tuple**：构建模式矩阵，按列检查。
   - **非封闭模式类型**（`Int`、`Float`、`Str` 等）：要求通配符或绑定兜底。

```vorton
// 缺少 None 分支，编译失败
match opt {
    Option::Some(x) => x
}
```

### 矩阵算法

```
check_matrix(rows: Pattern[][], col_types: Type[]) → null | Pattern[]

基本情况：
  如果 col_types 为空：
    rows 非空 → null（穷尽）
    rows 为空 → []（未覆盖）

递归情况：
  取第一列的类型 T

  如果 T 是封闭构造器类型（Bool、Enum、Unit、Tuple）：
    对 T 的每个构造器 ctor：
      特化 rows：收集匹配 ctor 的行
      子列类型 = ctor.fields ++ 其余列类型
      递归 check_matrix(特化后的 rows, 子列类型)
      如果不穷尽：格式化缺失模式

  如果 T 是非封闭模式类型：
    收集第一列为通配符/绑定的行
    递归 check_matrix(这些行, 其余列类型)
    如果不穷尽：返回 ["_", ...rest_missing]
```

### 行特化

```
specialize_row(row, ctor):
  first = row[0]
  rest = row[1..]

  first 为通配符或绑定 → [..ctor.fields 个通配符, ..rest]
  first 为字面量 → 如果匹配 ctor 的值则展开，否则跳过
  first 为构造器 → 如果匹配 ctor 名称则展开字段，否则跳过
  first 为命名构造器 → 转为位置形式后展开
  first 为 tuple → 匹配则展开元素，否则跳过
  first 为 Or → 对每个子模式 pᵢ 递归 specialize_row([pᵢ, ..rest], ctor)，合并结果行
```

命名字段模式按变体声明中的字段顺序转为位置形式，未列出的字段填 `_`，然后复用上述算法。

### Or-pattern

`p₁ | p₂ | ...` 中任一子模式匹配即执行该分支。`|` 只在分支最外层解析，不能嵌套在 tuple 或构造器字段中。

```vorton
match color {
    Red | Green => "warm"
    Blue => "cool"
}

match val {
    Choice::Left(x) | Choice::Right(x) => x    // 两边共享 x
}
```

穷尽性检查中，每个子模式视为独立的一行。

## Match 表达式语义

分支从上到下检查，执行第一个匹配的分支。

Guard 是模式匹配成功后额外检查的布尔条件，为 false 时尝试下一个分支。Guard 不参与穷尽性证明。

```vorton
match x {
    n if n > 0 => "positive"
    _ => "non-positive"
}
```

穷尽性检查失败时编译器拒绝该 match；通过检查的 match 不存在无匹配的路径。
