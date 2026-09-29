# 类型系统

Vorton 采用局部双向类型推断：具名函数的签名写出，函数体内推断。类型检查同时追踪 effect row（见 [Effect 系统](effects.md)）与 trait bound（见 [Trait 系统](traits.md)）。类型表达式、参数与调用的产生式见[语法](syntax.md)；本页只规定语义。

## 类型

### 原始类型

| 类型 | 描述 |
|------|------|
| `Int` | 固定 64 位有符号整数，范围 −2^63 至 2^63−1 |
| `Float` | IEEE 754 binary64 浮点数 |
| `Str` | 字符串 |
| `Bool` | 布尔值 |
| `Unit` | 唯一值为 `()` 的单位类型 |
| `Never` | 底类型，没有值 |

`Never` 可以出现在任何期望类型的位置，是永不返回的操作（如 `fail.raise`、`return`、`panic`）的类型。

### 名义类型

`struct` 与 `enum` 是名义类型：字段相同但声明不同的两个类型是不同类型。Enum 的 variant 可以有位置字段、命名字段或无字段；同一 enum 的所有 variant 共享同一类型。

### Tuple

`(T₁, ..., Tₙ)`（n ≥ 2）是结构类型：不同位置写出的 `(Int, Str)` 是同一类型。没有单元素 tuple；`(T)` 就是 `T`。

### 函数类型

`fn(P₁, ..., Pₙ) -> R with ε` 是普通类型，可以作为参数、返回值、字段、容器元素与类型实参。参数可以带 `mut`／`move` 模式；两个函数类型相等，当且仅当参数个数、参数类型与模式、返回类型分别相等；effect 的匹配规则见 [Effect 系统](effects.md)。函数值不支持 `==`。

### Option 与 Ordering

`Option<T>`（variant `Some(T)`、`None`）与 `Ordering`（`Less`、`Equal`、`Greater`）是官方 core root 公开声明的 enum。默认写作 `Option::Some`、`Ordering::Less`；只有显式 import constructor 后才能直接写 `Some`。没有 `T?` 缩写。

### Language intrinsic 与 core 角色

以下类型由语言直接提供，不来自任何源文件：`Int`、`Float`、`Str`、`Bool`、`Unit`、`Never`、`List<T>`、`Map<K, V>`、`Range<T>`、`Ptr<T>`。

`Option`、`Ordering`，以及 trait `PartialEq`、`Eq`、`PartialOrd`、`Ord`、`Hash`、`Display`、`Debug`、`Drop`、`Iterator`、`Iterable` 由宿主指定的唯一官方 core root 声明。

这些短名在 Type namespace 中不能被其他声明、import 或类型参数遮蔽；它们不是关键字，不影响 Value 与 Effect namespace 的同名绑定。

List 字面量产生 `List<T>`，range 表达式产生 `Range<Int>`。`Ptr<T>` 只在 `unsafe` 中使用；0.1 中 `Ptr` 与非 RC 的 `extern type` 不能出现在泛型聚合的元素类型里（例如 `List<Ptr<T>>`）。

### Private 字段

字段的 visibility 与编译器所需的布局信息分离。Public struct 的 private 字段可以包含 private 类型；只有 private 类型进入 public 签名、pub 字段或 public enum payload 时才报错。

## 值与资源

### 值

普通数据是**值**：数值、`Str`、tuple、不含资源的 struct 与 enum、`List`、`Map`、函数值。

- 赋值、传参、返回、存进字段或容器，都是逻辑上的拷贝。之后修改任何一份，其他各份不受影响。
- 值之间没有引用，因此不会形成环。图结构用 arena 加下标或句柄表达。
- 底层用引用计数实现：唯一持有时原地修改，共享时写时复制。值何时释放不可观察。

```vorton
let a = [1, 2, 3]
let mut b = a
b.push(4)            // a 仍是 [1, 2, 3]
```

### 资源

实现 `Drop` 的类型是**资源**；字段、payload、元素或捕获中含有资源的 struct、enum、tuple、容器与闭包，本身也是资源。

- 资源不能复制。赋值、传参、返回与存储都是移交；移交之后，原来的名字不能再使用。
- 资源在所属作用域结束时释放，同一作用域中按声明的逆序；已经移交出去的资源不在原处释放。`Drop::drop` 的 effect 限制见 [Effect 系统](effects.md)。
- 资源作为泛型实参时的规则待定。

## 参数与修改

### 参数模式

| 参数写法 | 调用处 | 含义 |
|---|---|---|
| `x: T` | `f(a)` | 只读。被调函数看到一个值，不能修改它 |
| `x: mut T` | `f(mut place)` | 就地修改调用方的这份数据 |
| `x: move T` | `f(move name)` | 取走调用方的资源 |

Receiver 同理：`self` 只读，`self: mut Self` 就地修改调用者，`self: move Self` 取走调用者。方法调用不需要调用处标记，但 `self: mut Self` 方法只能在可修改的位置上调用。

`mut` 参数的语义等价于“传入、修改、调用结束时写回”，底层传地址、不复制。它不是可以保存的引用：把它赋给别的变量、存进字段、返回或被闭包捕获，得到的都是当时的值拷贝。不能把资源从 `mut` 参数中移走。

`move` 只用于资源；参数类型不是资源时写 `move` 是编译错误。

### 统一的 `mut` 规则

`mut` 写在**位置**前面，表示对这个位置就地、独占的访问；在访问持续期间，原路径不能以任何方式使用：

| 写法 | 访问持续到 |
|---|---|
| `f(mut place)` | 调用结束 |
| `for x in mut place { ... }` | 循环结束；`x` 是当前元素的就地别名 |
| `let t = mut place` | `t` 最后一次使用 |
| `match mut place { ... }`、`if let P = mut place { ... }` | 分支结束；模式绑定是被匹配部分的就地别名 |

对就地别名的修改，包括整体赋值 `t = v`，都直接作用在原位置上。

`mut` 写在**变量名**前面（`let mut n`），表示这个变量本身可以修改。

一个位置可以修改，当且仅当它的根是以下之一：`let mut` 变量、`mut` 参数、`self: mut Self` 的 `self`、就地别名。修改包括整体赋值、字段赋值、下标赋值 `xs[i] = v`、复合赋值、调用 `self: mut Self` 方法，以及以 `mut` 传入。

`for x in mut place` 在 0.1 中只对 `List`（逐个元素）与 `Map`（逐个值）成立。

### 独占规则

编译器只检查以下两条，两条都只看一次调用或一个代码范围：

1. 同一次调用中，一份数据以 `mut` 传入后，不能再以任何方式传入这次调用。
2. 就地访问持续期间，不能再访问被占用的路径及其任何部分。下标不区分：`xs[i]` 与 `xs[j]` 都算作路径 `xs`。

```vorton
f(mut world, world.log)                  // 错误：违反第 1 条
let t = mut world.player
world.player.hp = 0                      // 错误：t 之后还会使用
t.hp -= 1
```

### 快照与未读修改

只读的 `let t = a.b` 得到一份快照：之后通过 `a` 的修改不会反映到 `t`。

对 `let mut` 变量的修改，如果之后从未被读取，是编译错误。这能捕获本应写成就地别名、却修改了副本的错误：

```vorton
let mut t = world.player    // 副本
t.hp -= 1                   // 错误：修改结果从未被读取；就地修改写作 let t = mut world.player
```

## 函数值与闭包

具名函数可以作为值使用。带位置字段的 enum constructor 不是函数值，需要时写成闭包：`fn(x) { Option::Some(x) }`。

闭包在创建时按值捕获它用到的外部变量。闭包不能修改外部变量；捕获资源会把它移交给闭包，这个闭包因此成为资源。

存在字段中的函数值通过 `(value.field)(args)` 调用。

## 容器

`List<T>` 与 `Map<K, V>` 遵循值语义。`xs[i]` 读取得到一份值；在可修改的位置上，`xs[i] = v` 与 `m[k] = v` 修改元素。下标越界时 panic。元素含资源的容器是资源。容器 API 不在本页定义。

## 代价模型

以下保证不需要阅读编译器也能推断；其余优化一律尽力而为，不可依赖：

1. 唯一持有的值被修改时，原地修改，不复制。
2. 赋值、只读传参、返回、存进字段或容器：O(1)，不复制内容。
3. `mut` 传参与就地别名：O(1)。
4. 修改一份正被共享的值时，先复制一次。复制是浅的：嵌套容器只复制被修改路径上的那几层，其余部分继续共享。
5. 字段只含标量的 struct 与 tuple，在 `List` 中连续存放，布局与 C 数组一致。
6. 资源在所属作用域结束时释放。
7. 函数在尾位置直接调用自身时不增长栈。其他尾调用在 0.1 中不作保证，之后提供。

## 推断

### 签名与函数体

- 具名函数、方法与 trait 方法的每个参数都必须写类型；省略返回类型表示 `Unit`。
- 函数体内的局部变量、闭包参数与闭包返回类型由推断得到。期望类型从外向内传递：`let` 标注、参数类型、返回类型与字段类型都会约束其中的表达式。例如空列表 `[]` 需要期望类型。
- 整数字面量是 `Int`，浮点字面量是 `Float`；数值之间没有隐式转换。
- 局部 `let` 不泛化：同一个绑定只有一个类型。

### 泛型

泛型函数显式声明类型参数，例如 `fn first<T>(xs: List<T>) -> Option<T>`。每次调用由实参与期望类型推断类型实参；调用处不能显式写类型实参。0.1 不支持多态递归：递归调用必须使用与自身相同的类型实参。

### 类型相等

两个类型相等，当且仅当它们是同一原始类型、同一名义声明且类型实参分别相等、元素个数相同且对应元素相等的 tuple，或按上文规则相等的函数类型。`Never` 可以用在任何期望类型处。Type alias 是透明的。

## 表达式与语句

- **运算符**：`+ - * / %` 与一元 `-` 要求两侧同为 `Int` 或同为 `Float`。`== !=` 要求类型实现 `PartialEq`；`< > <= >=` 要求实现 `PartialOrd`，见[比较 trait](traits.md#比较-trait)。`&& || !` 作用于 `Bool`。
- **调用**：实参按参数模式检查。只读参数接受任意表达式；`mut` 参数要求 `mut place`；`move` 参数要求 `move name`。
- **字段与构造**：struct 构造必须给出全部字段，且不能有多余字段；`..base` 用给定的值补齐其余字段。
- **List 字面量**：所有元素同型。**Range**：`a..b` 与 `a..=b` 的两端都是 `Int`。
- **代码块、`if`、`match`**：值的规则见[语法](syntax.md#代码块与语句)。`if` 与 `match` 的各分支必须同型；没有 `else` 的 `if` 类型为 `Unit`。`match` 必须穷尽，见[模式匹配](patterns.md)。
- **字符串插值**：`"${e}"` 中的 `e` 要求实现 `Display`，结果为 `Str`。
- **`catch`、`handle`**：见 [Effect 系统](effects.md)。
- **`for x in coll`**：`coll` 实现 `Iterable`；`Range<Int>` 直接编译为计数循环。

同一表达式中，子表达式从左到右求值：被调函数或 receiver 先于参数，参数依次求值。复合赋值 `p op= e` 只求值 `e` 一次，然后读取 `p` 的当前值、运算并写回；`e` 失败时不写回。

## 数值语义

`Int` 与 `Float` 的普通算术只接受同型运算数，不做隐式转换，也没有数值重载。

### `Int`

范围固定为 `−9223372036854775808..=9223372036854775807`，不随平台、构建模式或优化级别变化。`unsafe` 不改变算术语义。

- 加、减、乘或一元取负的数学结果超出范围时 panic；
- 除数为零的 `/` 与 `%` panic；`−9223372036854775808 / -1` 与 `% -1` 也 panic；
- 其余除法向零截断，余数满足 `a = q * b + r`，非零 `r` 与 `a` 同号且 `|r| < |b|`。例如 `−7 / 3 = −2`，`−7 % 3 = −1`。

这些 panic 不引入 `fail` effect，见 [Panic](effects.md#panic)。普通算术不回绕、不饱和。

独立的正整数字面量不得大于 `9223372036854775807`。唯一例外是一元负号直接作用于 `9223372036854775808`（中间可以隔任意层括号），整体表示最小 `Int`：

```vorton
let min = -9223372036854775808
let too_large = 9223372036854775808   // 错误：超出范围
let overflow = -min                   // 运行时 panic
```

### `Float`

采用与 Rust `f64` 相同的 IEEE binary64 值模型，包括 subnormal、正负零、正负 Infinity 与 NaN。`+ - * /` 按 round-to-nearest ties-to-even 舍入；除零、溢出与无效运算按浮点规则得到 Infinity 或 NaN，不 panic。NaN 的 payload 与符号不作保证。

`%` 是截断余数，非零结果与被除数同号，按数学余数得到 binary64 结果：

| 输入 | 结果 |
|---|---|
| `5.5 % 2.0` | `1.5` |
| `-5.5 % 2.0` | `-1.5` |
| `-0.0 % 2.0` | `-0.0` |
| NaN 参与、被除数无限、或除数为零 | NaN |
| 被除数有限、除数无限 | 被除数本身 |

浮点字面量按精确十进制值恰好舍入一次到 binary64；舍入为 Infinity 时报错。优化不得隐式融合为 FMA、保留额外中间精度或把 subnormal 刷成零。不提供浮点异常标志与可切换的舍入模式。

## 方法解析

`receiver.method(args)` 总是方法调用，按以下顺序查找：

1. receiver 类型的固有方法；
2. `Str`、`Int`、`Float`、`List`、`Map` 的语言内建方法；
3. receiver 类型可用的 trait impl；
4. receiver 是带 bound 的类型参数时，通过 bound 中的 trait 查找。

找不到时报错。

## 作用域

- 作用域是词法嵌套的：函数体、代码块、循环体、`match` 分支、`if let` 分支、闭包各自成为一层。
- `let` 绑定从声明处到所在作用域结束可见；同一作用域中再次 `let` 同名变量会创建新绑定，可以改变类型。
- `match` 与 `catch` 分支的模式绑定只在该分支内可见；`if let` 的绑定只在成功分支可见。
- 类型参数在所属声明的 bound、签名与函数体中可见，也对内部闭包可见。同一列表中不得重名，内层类型参数不得遮蔽仍可见的外层类型参数。
- `effect E` 参数属于 Effect namespace，在所属函数的签名与函数体中可见。
- `Self` 在 struct、enum、trait 与 impl 内部表示当前类型、trait 的实现者或 impl 的目标类型；在这些范围之外使用 `Self` 是错误。

## 待定

- effect 在函数签名中的写法（Milestone 4 定稿）。
- 派生（derive）的写法。
- 资源作为泛型实参的规则。
