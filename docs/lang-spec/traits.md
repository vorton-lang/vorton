# Trait 系统

Vorton 的 trait 系统提供有界多态性（bounded polymorphism）。具体 receiver 在类型检查时解析到唯一 impl；受 trait bound 的类型变量通过隐式 dictionary evidence 调用。Evidence 的目标表示不是语言规范的一部分。

宿主指定的唯一官方 core root 以普通 source declaration 公开 `PartialEq`、`Eq`、`PartialOrd`、`Ord`、`Clone`、`Copy`、`Drop`、`Display`、`Debug`、`Hash`、`FnOnce`、`FnMut`、`Fn`、`Iterator` 与 `Iterable`。这些 trait 及其 member、Self、generic、reference 都保留该 core 的 `LibraryId`、source 与 span；它们不再拥有平行的 `Language` declaration。下文 `Show`、`Describable` 等均是示例中显式声明的普通 source trait，不构成额外 core 协议。

官方 core 的 source member identity 包括 `PartialEq::eq`、`PartialOrd::partial_cmp`、`Ord::cmp`、`Clone::clone`、`Drop::drop`、`Display::to_str`、`Debug::debug`、`Hash::hash`、`Iterable::{Item, Iter, iter}` 与 `Iterator::{Item, next}`。`Eq`、`Copy`、`FnOnce`、`FnMut` 与 `Fn` 没有新增 member。Resolver 在成功前冻结并核对这些 owner/member identity，但不由命名习惯发明额外 member、signature、impl 或 runtime operation；trait/impl selection 在 Checker 信息完备后决定。

`PartialEq`、`PartialOrd`、`Ordering` 及其成员是后续 Resolver/Checker 共同消费的指定 core source identity。Resolver 对 core profile 的成功只证明声明 identity 与下文固定轮廓，不表示已经完成任意 impl 的类型/effect conformance、数值检查、比较执行、Copy/Drop 资格、dispatch 或 derive。

## Trait 声明

```vorton
trait Show {
    fn to_str(self: Self) -> Str;
}
```

声明一组类型必须实现的方法。`Self` 是 owner-scoped 的特殊 Type identity，引用实现该 trait 的具体类型；它不是全局 builtin。Owner 环境在 trait generic bounds、supertrait 与 member signature 解析前建立，并由内部 method/closure 继承。

完整且唯一的 trait、impl、method signature 与 associated type 产生式见[语法](syntax.md#program-与声明)。本页不建立第二份文法。

### Visibility

Trait 是完整的行为 contract，不为method或associated type提供独立visibility：

- `pub trait T`的全部associated items随trait公开；private trait的全部items只在其module visibility内可用；
- impl block本身没有visibility，`pub impl ...`非法；
- trait declaration中的`pub fn`/`pub type`非法；
- `impl Trait for Type`中的`pub fn`/`pub type`非法，implementation item的visibility继承Trait；
- inherent `impl Type`仍允许每个method/associated item独立写`pub`或保持private。

非法 `pub` 必须 hard-fail 并给出删除修复，不能接受后忽略。Trait dictionary、provider identity 与 CoreHIR 不保存 per-member visibility。Private required method 不产生 sealed-trait 语义。

Vorton 0.1 的 inherent impl 与 trait impl 都不接受 `extern fn` member；这与 visibility 无关，写在 impl 中的 `extern fn` 一律 hard-fail。用户 FFI 只由 top-level `extern fn` 声明；需要 method 形态时以普通 inherent wrapper 调用该 top-level extern。

Trait impl header 可以在 target 后写非空 `where` 合取，例如 `impl<T> Show for Box<T> where T: Debug, T::Item: Eq { ... }`。Predicate subject 是实际类型，bound 只接受 named trait；tuple subject 与 associated projection 均可用。该条件决定 impl 的适用域，不能从 body 反推更强条件；其它 declaration family 不获得同名 header。

`Fn`、`FnMut` 与 `FnOnce` 表示同一实际 callable 类型可提供的调用能力，包含关系为 `Fn ⇒ FnMut ⇒ FnOnce`。Source `call F` 按当前实例化可见的最强保留能力选择固定入口 mode：有 `Fn` 取 Borrow，没有 `Fn` 而有 `FnMut` 取 Mut，只有 `FnOnce` 时取 Move。选择消费同一份 `F`、trait evidence、type/effect instantiation；权限或 body 失败后不得改选另一行。`call` 不提供额外方法、Clone、调用次数或动态包装。

### Public interface、private impl 与 opaque return

Public item的参数、返回类型、pub field、public enum payload、generic bound及effect/trait contract不得引用更private的declaration；违反时hard-fail。Public struct的private field可以包含private nominal，因为该representation只经compiler metadata运输，不进入source interface。`impl PublicTrait for PrivateType`可在module内部合法存在并参与project coherence，但不会成为外部callable surface。Trait impl只有target与trait均对调用方可见时才随module export，public inherent type也只导出其`pub`methods。

Vorton 0.1 不支持 return-position `impl Trait`、opaque type 或由推断产生的匿名 public concrete type。需要隐藏返回值具体类型时使用显式 public wrapper 或 generic contract。`impl` 出现在 type position 必须产生 parse error。

### 0.1 方法签名边界

Vorton 0.1 的 source trait member 只有方法签名，不允许函数体。Trait declaration 中出现 `{ ... }` 方法体必须稳定报错，并建议把实现写入每个 `impl Trait for Type`；每个 impl 必须显式提供 trait 的全部方法。该限制不删除 associated type default，也不影响编译器内建或显式派生生成的 exact impl body。

## 官方 core 协议轮廓

仓库随 compiler 配套的 [`core/root.vorton`](../../core/root.vorton) 是下列 declaration 的 source authority。除下一节的四个比较 trait 外，固定轮廓如下；所有 method 都没有 default body，省略 `with` 的位置保留按选定 impl 关联的 effect scheme：

```vorton
pub trait Clone {
    fn clone(self: &Self) -> Self;
}
pub trait Copy: Clone {}
pub trait Drop {
    fn drop(self: &mut Self) -> Unit;
}

pub trait Display {
    fn to_str(self: &Self) -> Str;
}
pub trait Debug {
    fn debug(self: &Self) -> Str;
}
pub trait Hash {
    fn hash(self: &Self) -> Int;
}

pub trait FnOnce {}
pub trait FnMut: FnOnce {}
pub trait Fn: FnMut {}

pub trait Iterator {
    type Item;
    fn next(self: &mut Self) -> Option<Self::Item>;
}
pub trait Iterable {
    type Item;
    type Iter: Iterator<Item = Self::Item>;
    fn iter(self: move Self) -> Self::Iter;
}
```

`Copy` 只在声明层表达 `Clone` supertrait 且没有新增 member；具体类型是否具备 Copy 资格留给 Checker 与资源阶段。`Display` 与 `Debug` 使用不同 exact method identity。`Fn`／`FnMut`／`FnOnce` 是封闭调用能力标记，不声明 variadic call member 或自定义调用运算符。`Iterator`／`Iterable` 的 associated type 与 method reference 必须保持上述 exact owner 关系。

## 比较 trait

比较能力由指定官方 core 的四个 source trait 与一个 source enum 封闭。Core root 必须按下列轮廓直接公开声明；其他库不能用同名 source declaration、import 或 re-export 替换这些角色：

```text
PartialEq:
  eq(self: &Self, other: &Self) -> Bool with {}

Eq: PartialEq
  无新增方法

PartialOrd: PartialEq
  partial_cmp(self: &Self, other: &Self) -> Option<Ordering> with {}

Ord: Eq + PartialOrd
  cmp(self: &Self, other: &Self) -> Ordering with {}
```

`self` 与 `other` 都按 `borrow` 传递，比较方法本身是 closed pure；operand 在调用前的求值 effects 仍按普通从左到右规则传播。`Ordering` 的三个 variant 是 `Ordering::Less`、`Ordering::Equal`、`Ordering::Greater`，完整类型身份见[类型系统](type-system.md#ordering-类型)。

`==` 唯一 dispatch 到 exact `PartialEq::eq`，`!=` 对同一次调用结果取 Bool 反值，不存在 `ne` member、默认 body 或第二条 equality 路径。四个排序运算符各只求值一次 exact `PartialOrd::partial_cmp`：

| 运算符 | 返回 `true` 的结果 |
|---|---|
| `<` | `Option::Some(Ordering::Less)` |
| `>` | `Option::Some(Ordering::Greater)` |
| `<=` | `Option::Some(Ordering::Less)` 或 `Option::Some(Ordering::Equal)` |
| `>=` | `Option::Some(Ordering::Greater)` 或 `Option::Some(Ordering::Equal)` |

返回 `Option::None` 时四个排序运算符都为 `false`。`Ord::cmp` 是供显式全序消费方使用的唯一接口，不作为运算符的额外 dispatch 分支。

`PartialEq` 要求 equality 对称且传递，`Eq` 再要求自反；`PartialOrd` 必须与 `PartialEq` 一致并满足其部分序关系，`Ord` 必须形成全序且与两者一致。对同一类型，`PartialEq::eq(a, b)` 为 `true` 当且仅当 `PartialOrd::partial_cmp(a, b)` 是 `Option::Some(Ordering::Equal)`；具有 `Ord` 时，`partial_cmp(a, b)` 必须总是 `Option::Some(cmp(a, b))`。Compiler-defined primitive 和结构实现必须满足这些关系。编译器不承诺证明任意手写 impl 的数学定律；违反关系律是实现者的逻辑错误，不能据此使 compiler 或 `unsafe` 产生 undefined behavior。这些边界对应 Rust 的 [`PartialEq`](https://doc.rust-lang.org/std/cmp/trait.PartialEq.html)、[`Eq`](https://doc.rust-lang.org/std/cmp/trait.Eq.html)、[`PartialOrd`](https://doc.rust-lang.org/std/cmp/trait.PartialOrd.html) 与 [`Ord`](https://doc.rust-lang.org/std/cmp/trait.Ord.html)，但后续 Rust 文档变化不会自动修改 Vorton contract。

### Primitive comparison evidence

| 类型 | `PartialEq` | `Eq` | `PartialOrd` | `Ord` | 顺序规则 |
|---|---:|---:|---:|---:|---|
| `Int` | 是 | 是 | 是 | 是 | 64 位有符号数值顺序 |
| `Str` | 是 | 是 | 是 | 是 | UTF-8 byte sequence 的词典序 |
| `Bool` | 是 | 是 | 是 | 是 | `false < true` |
| `Unit` | 是 | 是 | 是 | 是 | 唯一值只与自身相等 |
| `Float` | 是 | 否 | 是 | 否 | Rust `f64` 对应的部分比较 |

`Float` 的 NaN 不等于自身或任何值，并且与任何值的 `partial_cmp` 都得到 `Option::None`；正负零相等，Infinity 按对应数值关系比较。因此 `NaN != NaN` 为 `true`，四个涉及 NaN 的排序运算符均为 `false`，`-0.0 == 0.0` 为 `true`。语言不为 `Float` 提供 `Eq` 或 `Ord` evidence，也不通过 `total_cmp` 一类全序接口暗中补足它。

### 按 impl 关联的 effect scheme

Trait method 省略外层 `with` 时，声明该 exact method 拥有按选定 impl 确定的完整公开 effect scheme。它不是 pure 默认值，不是待补的 contract，也不把当前全部 impl 汇总为一个 row。

设 impl body 推断 row 为 `A`，impl 自己显式写出的上界为 `I`，trait 显式上界为 `B`：

- trait 无 `B`、impl 有 `I`：检查 `A ⊆ I`，该 impl 的公开关联 scheme 为 `I`；
- trait 与 impl 都省略：该 impl 的公开关联 scheme 为 `A`；
- trait 有 `B`：impl 有 `I` 时检查 `A ⊆ I ⊆ B`，否则检查 `A ⊆ B`；所有普通 trait-method 调用与 scheme 引用都使用 `B`。

这些关系对合法 type/effect formal 的每次实例化成立。修改某个 impl 可以改变该 impl 尚未固定的推断 contract；增删无关 impl 不得改写其他实现或 trait 的抽象关系。Trait 暂时没有 impl 也不会被默认判定为 pure，具体调用仍需要合法 evidence。

```vorton
trait Fetch {
    fn fetch<F: Fn + fn(Str) -> Unit with {E}, effect E>(
        self,
        callback: call F
    ) -> Unit;
}

struct Memory {}

impl Fetch for Memory {
    fn fetch<F: Fn + fn(Str) -> Unit with {E}, effect E>(
        self,
        callback: call F
    ) -> Unit {
        callback("cached")
    }
}

struct Disk {}

impl Fetch for Disk {
    fn fetch<F: Fn + fn(Str) -> Unit with {E}, effect E>(
        self,
        callback: call F
    ) -> Unit {
        callback(read_file("data.txt"))
    }
}
```

Checker 将对应 signature 位置映射到 trait formal。于是 `Memory` 可以得到 `Fetch::fetch(E) = E`，`Disk` 可以得到 `Fetch::fetch(E) = {fs, E}`；完全不调用 callback 的实现也可以不传播 `E`。Scheme 关联整个 method effect 表达式，而不是给 impl 附加一个固定集合。

受 `T: Trait` evidence 约束的 generic caller 保留正式 method scheme application；concrete call 使用唯一选定 impl 的 mapping。Type actual、callback effect actual、trait evidence 与 method scheme 必须来自同一次实例化，不能为 generic body 重新推断一份关系。

每个 method scheme 独立。Canonical 0.1 不表达跨方法共享或相等的抽象 effect，也不同时提供“保留每个 impl 精度”和“单独声明全局 cap”的第二种 contract 模式。需要引用 method scheme 时使用 [exact `TraitPath::method<...>` 形式](effects.md#完整方法-scheme-引用)。

### Supertrait 继承

```vorton
trait Describable {
    fn describe(self: Self) -> Str;
}

trait Printable: Describable {
    fn label(self: Self) -> Str;
}
```

`trait B: A` 声明 B 的 supertrait 为 A。实现 B 的类型必须同时实现 A，否则报错。

Supertrait 必须名称解析到真实 named trait declaration。Import 与 re-export alias 只转发该 declaration 的 exact identity；primitive、struct、enum、type parameter、associated selection 或其它非 trait Type 都不能占用这个位置。需要 Checker 才能闭合的 type-relative selection 也不能伪装成已经确认的 trait。

**多级传递**：约束自动沿继承链传递——若 `T: Printable` 且 `Printable: Describable`，则 `T` 隐含 `Describable`，可直接调用 `describe()`。

**Supertrait evidence**：具体 impl 方法可以调用 supertrait 方法；调用使用同一 exact dictionary evidence 链，不需要 source default body。

**循环检测**：`trait A: B` 与 `trait B: A` 的循环在声明阶段被拒绝。节点是 exact trait declaration；generic actual 不会把同一 declaration 变成新节点。重复引用、合法继承链与共享 diamond 不构成循环。

**impl 验证**：`impl Printable for Foo` 时若没有 `Describable for Foo`，报 supertrait 未满足错误。

### 关联类型

```vorton
trait Container {
    type Item;
    fn get(self: Self) -> Item;
}
```

关联类型在 trait 内声明一个类型成员。`Item` 在方法签名中可作为类型使用。

**impl 中赋值**：

```vorton
impl Container for IntBox {
    type Item = Int;
    fn get(self) -> Int { self.value }
}
```

**限定路径**：泛型函数中通过 `T::Item` 引用关联类型。

```vorton
fn use_it<T: Producer>(p: T) -> T::Item {
    p.produce()
}
```

**约束语法**：`<Item = Int>` 约束关联类型的具体值。

```vorton
fn sum_source<T: Source<Item = Int>>(s: T) -> Int {
    s.next() + s.next()
}
```

**关联类型 bound**：声明关联类型时可附加 trait 约束。

```vorton
trait Container {
    type Item: Eq;   // Item 必须实现 Eq
    fn get(self: Self) -> Item;
}
```

**默认关联类型**：声明时可提供默认值，impl 可省略或覆盖。

```vorton
trait Processor {
    type Output = Int;           // 默认为 Int
    fn process(self: Self) -> Output;
}

impl Processor for Doubler {    // 使用默认 Output = Int
    fn process(self) -> Int { self.value * 2 }
}

impl Processor for Greeter {    // 覆盖为 Str
    type Output = Str;
    fn process(self) -> Str { "Hello, ${self.name}!" }
}
```

Associated Type 仍属于 Type namespace 的 owner-scoped declaration，因此不能命名为 `Self`，也不能使用 `Int` 等 Language intrinsic spelling 或 `Option`、`Eq` 等受保护 core spelling；该规则同样覆盖 trait declaration、inherent impl 与 trait impl。普通 Value method 或其他 namespace 的同名 declaration 不受此条影响。

## Impl 块

### 固有方法

```vorton
impl Point {
    pub fn distance(self) -> Float { ... }
}
```

为类型定义方法，不依赖任何 trait。通过 `.method()` 调用：`point.distance()`。

固有 impl 只包含普通函数与关联类型，不承载 FFI link identity，也不包含 `delegate` 声明。

### Trait 实现

```vorton
impl Show for Point {
    fn to_str(self: Self) -> Str {
        "${self.x}, ${self.y}"
    }
}
```

为具体类型实现 trait。Source trait method 没有默认 body，因此 impl 必须提供全部方法；缺少方法时报错。

### 泛型 Impl

```vorton
impl<T: Show> Show for List<T> {
    fn to_str(self: Self) -> Str { ... }
}
```

Impl 块可以有自己的类型参数和约束。

Impl 的 owner `Self` 在 generic bounds、trait/target 与 member 之前建立；impl generic 随后在整个 bounds、trait/target、member signature/body 与内部 closure 中可见。Member generic 不得遮蔽仍可见的 impl generic。具体 substitution、适用 impl 与 associated selection 在 Checker 完成。

## Trait Bound

### 函数约束

```vorton
fn stringify<T: Show>(x: T) -> Str {
    x.to_str()
}
```

`T: Show` 约束要求 `T` 实现 `Show` trait。函数体内可调用 `Show` 的方法。

### 多约束

```vorton
fn process<T: Show + Eq>(x: T, y: T) -> Bool { ... }
```

`+` 组合多个 trait bound。`T` 必须同时实现 `Show` 和 `Eq`。

### Bound 在 Type Scheme 中的传播

```
TypeScheme = ∀α₁..αₙ. τ [bounds]
bounds = { (α₁, "Show"), (α₂, "Eq"), ... }
```

泛化时把 quantified variable 上的 trait bound 存入 type scheme。实例化时 bound 从 quantified variable 转移到 fresh variable。

## 方法解析与 Dictionary Evidence

`x.method(args)` 在语法阶段始终是 MethodCall，不会先按函数值字段解释。函数值字段必须显式写 `(x.method)(args)`。MethodCall 随后按以下语义顺序解析：

1. receiver 具体类型的固有方法；
2. 原始类型提供的方法；
3. 具体类型唯一可用的 trait impl；
4. receiver 是受约束类型变量时，从其 trait bound 取得隐式 dictionary evidence。

找不到方法时产生未定义方法的类型错误。

```vorton
fn stringify<T: Show>(value: T) -> Str {
    value.to_str()
}

fn show_twice<T: Show>(value: T) -> Str {
    "${stringify(value)} ${stringify(value)}"
}
```

`stringify` 所需的 `Show<T>` evidence 是函数约束的一部分。调用者负责提供或继续转发它；supertrait 调用也使用同一 evidence 链。后端可以直接调用、传递表或采用等价 lowering，只要观察到的 trait 选择与 effect 行为一致。

## 显式转发

Vorton 0.1 不提供 `delegate` declaration。`delegate field: Trait` 必须产生语法错误；组合转发通过普通 `impl Trait for Type` 和显式 method call 表达。编译器不得生成 delegate owner、wrapper body 或专属 Core/ABI carrier。

## 显式结构派生

普通 struct/enum 不因字段满足约束而自动获得 PartialEq/Eq/PartialOrd/Ord/Hash/Clone/Debug 或 Copy。结构派生由显式生成请求产生普通 impl，再通过相同的类型、effect、visibility 与 coherence 检查；没有手写接管或自动抑制的平行选择路径。当前 Checker 尚不执行生成器。

生成的比较按声明顺序检查字段；enum 先比较 variant，再比较同一 variant 的字段。各能力分别要求其对应 evidence，不能从 PartialEq/PartialOrd 自动取得 Eq/Ord。生成 body 通过普通 generic helper 固定 dictionary，不受字段类型的同名 inherent method 抢选。手写 Hash、Clone 等实现也必须遵守已定义的关系律和实际 effect。

Primitive comparison 的 compiler-provided evidence 保留既定 scalar 范围和 exact core identity。当前 Checker 允许受支持 core signature 的显式 source impl，尚不开放用户 Copy/Drop 或生成器派生，也不因此接受完整 core/std 协议。

## 限制

- 不支持 `dyn Trait` 动态分发
- 不支持 GATs（Generic Associated Types）
