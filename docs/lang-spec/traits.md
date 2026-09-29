# Trait 系统

Trait 提供有界多态。具体 receiver 在类型检查时解析到唯一 impl；受 trait bound 约束的类型变量通过隐式 dictionary evidence 调用。Evidence 的目标表示不属于语言规范。

宿主指定的唯一官方 core root 以普通源码声明公开 `PartialEq`、`Eq`、`PartialOrd`、`Ord`、`Drop`、`Display`、`Debug`、`Hash`、`Iterator` 与 `Iterable`。这些 trait 及其成员都保留该 core 的 `LibraryId`、源码与 span，没有平行的语言内建声明。下文 `Show`、`Describable` 等是示例中显式声明的普通 trait。

官方 core 的成员 identity 包括 `PartialEq::eq`、`PartialOrd::partial_cmp`、`Ord::cmp`、`Drop::drop`、`Display::to_str`、`Debug::debug`、`Hash::hash`、`Iterable::{Item, Iter, iter}` 与 `Iterator::{Item, next}`。`Eq` 没有新增成员。名称解析阶段核对这些 identity，但不按命名习惯发明额外成员、签名、impl 或运行时操作；trait 与 impl 的选择在类型检查阶段决定。

值可以直接复制，没有 `Clone` 或 `Copy` trait；实现 `Drop` 的类型是资源，不能复制。见[类型系统](type-system.md)。

## Trait 声明

```vorton
trait Show {
    fn to_str(self) -> Str
}
```

Trait 声明一组类型必须实现的方法。`Self` 是 owner 作用域内的特殊类型，指实现该 trait 的具体类型；它不是全局内建名。

Trait 方法的 receiver 有三种写法：`self` 只读，`self: mut Self` 就地修改调用者，`self: move Self` 取走调用者（只用于资源）。完整产生式见[语法](syntax.md#program-与声明)。

### Visibility

Trait 是完整的行为 contract，方法与关联类型没有独立的 visibility：

- `pub trait T` 的全部成员随 trait 公开；private trait 的成员只在其模块可见范围内可用；
- impl 块本身没有 visibility，`pub impl ...` 非法；
- trait 声明中的 `pub fn`／`pub type` 非法；
- `impl Trait for Type` 中的 `pub fn`／`pub type` 非法，实现项的可见性继承 trait；
- 固有 `impl Type` 的每个方法或关联类型可以独立写 `pub`。

非法的 `pub` 直接报错并建议删除，不能接受后忽略。

impl 中不能写 `extern fn`。用户 FFI 只由顶层 `extern fn` 声明；需要方法形态时，用普通固有方法包装它。

Trait impl 头部可以在目标类型后写非空的 `where` 合取，例如 `impl<T> Show for Box<T> where T: Debug, T::Item: Eq { ... }`。谓词主体是实际类型，可以是 tuple 或关联类型投影；bound 只接受具名 trait。该条件决定 impl 的适用范围，不能从 body 反推更强的条件。

### 公开接口与 private impl

公开项的参数、返回类型、pub 字段、公开 enum payload、泛型 bound 及 effect/trait contract 不得引用更私有的声明。公开 struct 的私有字段可以使用私有类型。`impl PublicTrait for PrivateType` 可以在模块内部合法存在，但不会成为外部可调用的接口。Trait impl 只有在目标类型与 trait 都对调用方可见时才随模块导出；公开类型只导出其 `pub` 方法。

0.1 不支持隐藏返回值具体类型的写法（例如 `impl Trait` 返回类型）；类型位置出现 `impl` 是语法错误。

### 方法只有签名

Trait 成员只有方法签名，没有函数体。Trait 声明中出现方法体时报错，并建议把实现写进每个 `impl Trait for Type`；每个 impl 必须提供 trait 的全部方法。关联类型可以有默认值。

## 官方 core 协议

仓库中的 [`core/root.vorton`](../../core/root.vorton) 是下列声明的源码 authority。除下一节的四个比较 trait 外，形状固定如下；所有方法都没有默认 body，省略 `with` 的位置保留按 impl 关联的 effect scheme：

```vorton
pub trait Drop {
    fn drop(self: mut Self)
}

pub trait Display {
    fn to_str(self) -> Str
}
pub trait Debug {
    fn debug(self) -> Str
}
pub trait Hash {
    fn hash(self) -> Int
}

pub trait Iterator {
    type Item
    fn next(self: mut Self) -> Option<Self::Item>
}
pub trait Iterable {
    type Item
    type Iter: Iterator<Item = Self::Item>
    fn iter(self) -> Self::Iter
}
```

`Display` 与 `Debug` 是不同的方法 identity。`Iterator`／`Iterable` 的关联类型与方法引用必须保持上述 owner 关系。

## 比较 trait

比较能力由官方 core 的四个 trait 与一个 enum 封闭。Core root 必须按下列形状公开声明；其他库不能用同名声明、import 或 re-export 替换这些角色：

```text
PartialEq:
  eq(self, other: Self) -> Bool with {}

Eq: PartialEq
  无新增方法

PartialOrd: PartialEq
  partial_cmp(self, other: Self) -> Option<Ordering> with {}

Ord: Eq + PartialOrd
  cmp(self, other: Self) -> Ordering with {}
```

`self` 与 `other` 都是只读参数，比较方法本身是纯的；运算数在调用前的求值 effect 仍按从左到右规则传播。`Ordering` 的三个 variant 是 `Ordering::Less`、`Ordering::Equal`、`Ordering::Greater`，见[类型系统](type-system.md#option-与-ordering)。

`==` 唯一 dispatch 到 `PartialEq::eq`，`!=` 对同一次调用结果取反；没有 `ne` 成员或第二条相等路径。四个排序运算符各只求值一次 `PartialOrd::partial_cmp`：

| 运算符 | 返回 `true` 的结果 |
|---|---|
| `<` | `Option::Some(Ordering::Less)` |
| `>` | `Option::Some(Ordering::Greater)` |
| `<=` | `Option::Some(Ordering::Less)` 或 `Option::Some(Ordering::Equal)` |
| `>=` | `Option::Some(Ordering::Greater)` 或 `Option::Some(Ordering::Equal)` |

返回 `Option::None` 时四个排序运算符都为 `false`。`Ord::cmp` 供需要全序的调用方显式使用，不是运算符的另一条 dispatch 路径。

`PartialEq` 要求相等对称且传递，`Eq` 再要求自反；`PartialOrd` 必须与 `PartialEq` 一致并满足部分序，`Ord` 必须形成全序并与两者一致。对同一类型，`eq(a, b)` 为 `true` 当且仅当 `partial_cmp(a, b)` 是 `Option::Some(Ordering::Equal)`；具有 `Ord` 时，`partial_cmp(a, b)` 必须总是 `Option::Some(cmp(a, b))`。编译器定义的实现必须满足这些关系；编译器不证明手写 impl 的数学定律，违反它们是实现者的逻辑错误，但不能因此导致未定义行为。

### 原始类型的比较

| 类型 | `PartialEq` | `Eq` | `PartialOrd` | `Ord` | 顺序规则 |
|---|---:|---:|---:|---:|---|
| `Int` | 是 | 是 | 是 | 是 | 64 位有符号数值顺序 |
| `Str` | 是 | 是 | 是 | 是 | UTF-8 字节序列的字典序 |
| `Bool` | 是 | 是 | 是 | 是 | `false < true` |
| `Unit` | 是 | 是 | 是 | 是 | 唯一值只与自身相等 |
| `Float` | 是 | 否 | 是 | 否 | IEEE 754 binary64 的部分比较 |

`Float` 的 NaN 不等于任何值（包括自身），与任何值的 `partial_cmp` 都得到 `Option::None`；正负零相等，无穷按数值关系比较。因此 `NaN != NaN` 为 `true`，涉及 NaN 的四个排序运算符都为 `false`，`-0.0 == 0.0` 为 `true`。`Float` 没有 `Eq` 或 `Ord`。

### 按 impl 关联的 effect scheme

本节规则待 Milestone 4 与 effect 的签名呈现一起定稿。

Trait 方法省略外层 `with` 时，该方法拥有按选定 impl 确定的完整公开 effect scheme。它不是纯的默认值，也不把全部 impl 汇总成一个 row。

设 impl body 推断的 row 为 `A`，impl 显式写出的上界为 `I`，trait 显式上界为 `B`：

- trait 没有 `B`、impl 有 `I`：检查 `A ⊆ I`，该 impl 的公开 scheme 为 `I`；
- trait 与 impl 都省略：该 impl 的公开 scheme 为 `A`；
- trait 有 `B`：impl 有 `I` 时检查 `A ⊆ I ⊆ B`，否则检查 `A ⊆ B`；所有 trait 方法调用与 scheme 引用都使用 `B`。

修改某个 impl 可以改变它尚未固定的推断 contract；增删无关的 impl 不改变其他实现或 trait 的关系。

```vorton
trait Fetch {
    fn fetch<effect E>(self, callback: fn(Str) with {E})
}

struct Memory {}

impl Fetch for Memory {
    fn fetch<effect E>(self, callback: fn(Str) with {E}) {
        callback("cached")
    }
}

struct Disk {}

impl Fetch for Disk {
    fn fetch<effect E>(self, callback: fn(Str) with {E}) {
        callback(read_file("data.txt"))
    }
}
```

于是 `Memory` 得到 `Fetch::fetch(E) = E`，`Disk` 得到 `Fetch::fetch(E) = {fs, E}`；完全不调用 callback 的实现可以不传播 `E`。

受 `T: Trait` 约束的泛型调用方保留正式的方法 scheme；具体调用使用唯一选定 impl 的映射。类型实参、callback 的 effect 实参、trait evidence 与方法 scheme 必须来自同一次实例化。每个方法 scheme 独立；需要引用方法 scheme 时使用 [`TraitPath::method<...>`](effects.md#完整方法-scheme-引用)。

### Supertrait 继承

```vorton
trait Describable {
    fn describe(self) -> Str
}

trait Printable: Describable {
    fn label(self) -> Str
}
```

`trait B: A` 声明 B 的 supertrait 为 A。实现 B 的类型必须同时实现 A，否则报错。

Supertrait 必须解析到真实的具名 trait 声明；原始类型、struct、enum、类型参数、关联类型选择或其他非 trait 类型都不能占用这个位置。

- **多级传递**：若 `T: Printable` 且 `Printable: Describable`，则 `T` 隐含 `Describable`，可以直接调用 `describe()`。
- **Supertrait evidence**：具体 impl 的方法可以调用 supertrait 方法，调用使用同一条 dictionary evidence 链。
- **循环检测**：`trait A: B` 与 `trait B: A` 在声明阶段被拒绝。节点是 exact trait 声明；泛型实参不产生新节点。重复引用、合法继承链与菱形继承不构成循环。
- **impl 验证**：`impl Printable for Foo` 时若没有 `Describable for Foo`，报 supertrait 未满足。

### 关联类型

```vorton
trait Container {
    type Item
    fn get(self) -> Item
}

impl Container for IntBox {
    type Item = Int
    fn get(self) -> Int { self.value }
}
```

泛型函数中用 `T::Item` 引用关联类型，用 `<Item = Int>` 约束其具体值，声明时可以附加 trait bound：

```vorton
fn use_it<T: Producer>(p: T) -> T::Item {
    p.produce()
}

fn sum_source<T: Source<Item = Int>>(s: T) -> Int {
    s.first() + s.second()
}

trait Keyed {
    type Key: Eq
    fn key(self) -> Key
}
```

关联类型可以有默认值，impl 可以省略或覆盖：

```vorton
trait Processor {
    type Output = Int
    fn process(self) -> Output
}

impl Processor for Doubler {
    fn process(self) -> Int { self.value * 2 }
}

impl Processor for Greeter {
    type Output = Str
    fn process(self) -> Str { "Hello, ${self.name}!" }
}
```

关联类型属于 Type namespace，不能命名为 `Self`，也不能使用 `Int` 等语言内建拼写或 `Option`、`Eq` 等受保护的 core 拼写。

## Impl 块

### 固有方法

```vorton
impl Point {
    pub fn distance(self) -> Float { ... }
    pub fn translate(self: mut Self, dx: Float, dy: Float) {
        self.x += dx
        self.y += dy
    }
}
```

固有方法不依赖任何 trait，通过 `point.distance()` 调用。调用 `self: mut Self` 方法时，receiver 必须是可修改的：`let mut` 变量、`mut` 参数、`mut` 别名，或以它们为根的路径。Receiver 不需要调用处标记。

### Trait 实现

```vorton
impl Show for Point {
    fn to_str(self) -> Str {
        "${self.x}, ${self.y}"
    }
}
```

Trait 方法没有默认 body，impl 必须提供全部方法。

### 泛型 impl

```vorton
impl<T: Show> Show for List<T> {
    fn to_str(self) -> Str { ... }
}
```

Impl 块可以有自己的类型参数和约束。Impl 的类型参数在 bound、trait／目标类型、成员签名与 body 中可见；成员自己的类型参数不得遮蔽仍可见的 impl 类型参数。

## Trait bound

```vorton
fn stringify<T: Show>(x: T) -> Str {
    x.to_str()
}

fn process<T: Show + Eq>(x: T, y: T) -> Bool { ... }
```

`T: Show` 要求 `T` 实现 `Show`，函数体内可以调用 `Show` 的方法；`+` 组合多个 bound。泛型函数的 bound 写在签名中，是其类型 scheme 的一部分；每次调用时核对实参类型满足 bound。

## 方法解析与 dictionary evidence

`x.method(args)` 在语法上总是方法调用；调用字段中的函数值要写 `(x.method)(args)`。方法调用按以下顺序解析：

1. receiver 具体类型的固有方法；
2. 原始类型提供的方法；
3. 具体类型唯一可用的 trait impl；
4. receiver 是受约束的类型变量时，从其 trait bound 取得隐式 dictionary evidence。

找不到方法时报未定义方法的类型错误。

```vorton
fn stringify<T: Show>(value: T) -> Str {
    value.to_str()
}

fn show_twice<T: Show>(value: T) -> Str {
    "${stringify(value)} ${stringify(value)}"
}
```

`stringify` 所需的 `Show` evidence 是其约束的一部分，由调用方提供或继续转发；supertrait 调用使用同一条 evidence 链。后端可以直接调用、传递表或采用等价实现，只要观察到的 trait 选择与 effect 行为一致。

没有 `delegate` 声明；组合转发用普通 `impl Trait for Type` 和显式方法调用表达。

## 编译器定义的结构实现

派生方式待定。在定稿前，编译器为所有 struct/enum 自动提供满足字段条件的以下实现：

- **PartialEq**：所有字段都实现 `PartialEq` 时提供。Struct 按字段声明顺序比较，遇到首个不相等字段即结束；enum 先比较 variant，相同 variant 再按字段顺序比较。
- **Eq**：所有字段都实现 `Eq` 时提供，并与同一结构化 `PartialEq` 一致。
- **PartialOrd**：所有字段都实现 `PartialOrd` 时提供。Struct 按字段声明顺序做字典序比较；enum 先按 variant 声明顺序比较，相同 variant 才比较字段。首个非 `Ordering::Equal` 或 `Option::None` 的字段结果就是整体结果。
- **Ord**：所有字段都实现 `Ord` 时提供，并与结构化相等和部分序一致。
- **Hash**：只有当该类型走结构化 `Eq`、且所有字段都有 `Hash` 时提供。Struct 按字段顺序组合 hash；enum 先组合稳定的 variant 编号，再组合字段。手写了 `Eq` 的类型不会隐式获得结构化 `Hash`。
- **Debug**：所有字段都实现 `Debug` 时提供。

```vorton
struct Reading { major: Int, sample: Float }
enum Phase { Start(Float), End(Float) }
```

`Reading` 先比较 `major`，相等时才比较 `sample`；若后者含 NaN，部分序立即得到 `Option::None`。`Phase` 的 `Start` 排在 `End` 之前。两种类型都获得结构化 `PartialEq`／`PartialOrd`，不获得 `Eq`／`Ord`。

每种能力分别要求全部字段具有对应 trait；有 `PartialEq` 或 `PartialOrd` 不会自动产生 `Eq` 或 `Ord`。提供关系按依赖不动点扩展到嵌套与递归类型。`Hash` 的基础实现包括 `Int`、`Str` 与 `Bool`，不包括 `Float` 或 `Unit`。这些实现是编译器定义的封闭语义，不对应源码 attribute；其他 trait 需要显式 impl。

## 限制

- 不支持 `dyn Trait` 动态分发
- 不支持泛型关联类型（GAT）
