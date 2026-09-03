# Trait 系统

Vorton 的 trait 系统提供有界多态性（bounded polymorphism）。具体 receiver 在类型检查时解析到唯一 impl；受 trait bound 的类型变量通过隐式 dictionary evidence 调用。Evidence 的目标表示不是语言规范的一部分。

## Trait 声明

```vorton
trait Show {
    fn to_str(self: Self) -> Str;
}
```

声明一组类型必须实现的方法。`Self` 类型变量引用实现该 trait 的具体类型。

完整且唯一的 trait、impl、method signature 与 associated type 产生式见[语法](syntax.md#program-与声明)。本页不建立第二份文法。

### Visibility

Trait 是完整的行为 contract，不为method或associated type提供独立visibility：

- `pub trait T`的全部associated items随trait公开；private trait的全部items只在其module visibility内可用；
- impl block本身没有visibility，`pub impl ...`非法；
- trait declaration中的`pub fn`/`pub type`非法；
- `impl Trait for Type`中的`pub fn`/`pub type`非法，implementation item的visibility继承Trait；
- inherent `impl Type`仍允许每个method/associated item独立写`pub`或保持private。

非法`pub`必须hard-fail并给删除修复，不能接受后忽略。Trait dictionary、provider identity与CoreHIR不保存per-member visibility。需要sealed trait时将来使用显式设计，不以private required method模拟。

Vorton 0.1的inherent impl与trait impl都不接受`extern fn` member；这与visibility无关，写在impl中的`extern fn`一律hard-fail。用户FFI只由top-level `extern fn`声明；需要method形态时以普通inherent wrapper调用该top-level extern。标准库内建方法由编译器exact intrinsic manifest提供，不是trait/impl语法成员。

### Public interface、private impl 与 opaque return

Public item的参数、返回类型、pub field、public enum payload、generic bound及effect/trait contract不得引用更private的declaration；违反时hard-fail。Public struct的private field可以包含private nominal，因为该representation只经compiler metadata运输，不进入source interface。`impl PublicTrait for PrivateType`可在module内部合法存在并参与project coherence，但不会成为外部callable surface。Trait impl只有target与trait均对调用方可见时才随module export，public inherent type也只导出其`pub`methods。

Vorton 0.1不支持return-position`impl Trait`、opaque type或由推断产生的匿名public concrete type。需要隐藏返回值具体类型时，当前使用显式public wrapper/generic contract；post-0.1由B-200在真实consumer下重新设计。`impl`出现在type position必须稳定parse error，不能先建立只transport不约束的占位节点。

### 0.1 方法签名边界

Vorton 0.1 的 source trait member 只有方法签名，不允许函数体。Trait declaration 中出现 `{ ... }` 方法体必须稳定报错，并建议把实现写入每个 `impl Trait for Type`；每个 impl 必须显式提供 trait 的全部方法。该限制不删除 associated type default，也不影响编译器内建或 auto-derived 的 exact impl body。

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

**多级传递**：约束自动沿继承链传递——若 `T: Printable` 且 `Printable: Describable`，则 `T` 隐含 `Describable`，可直接调用 `describe()`。

**Supertrait evidence**：具体 impl 方法可以调用 supertrait 方法；调用使用同一 exact dictionary evidence 链，不需要 source default body。

**循环检测**：`trait A: B` + `trait B: A` 在声明阶段检测，报 E0501。

**impl 验证**：`impl Printable for Foo` 时若未实现 `Describable for Foo`，报 supertrait 未满足错误。

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

**错误码**：

| 错误码 | 含义 |
|--------|------|
| E0510 | 缺少必需的关联类型实现 |
| E0511 | 引用了 trait 中不存在的关联类型 |
| E0512 | 关联类型歧义 |
| E0513 | 关联类型 bound 不满足 |
| E0514 | 出现了意外的关联类型 |

## Impl 块

### 固有方法

```vorton
impl Point {
    pub fn distance(self) -> Float { ... }
}
```

为类型定义方法，不依赖任何 trait。通过 `.method()` 调用：`point.distance()`。

固有impl只包含普通函数与关联类型，不承载FFI link identity，也不包含`delegate`声明。编译器内建的Str/Int/Float方法在语言层仍表现为普通固有方法，其宿主映射属于CoreHIR/AbiIR的exact intrinsic contract。

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

泛化时 trait bound 从 `var_bounds` 收集并存入 type scheme。实例化时 bound 从旧变量转移到 fresh 变量。

## 方法解析与 Dictionary Evidence

`x.method(args)` 在语法阶段始终是 MethodCall，不会先按函数值字段解释。函数值字段必须显式写 `(x.method)(args)`。MethodCall 随后按以下语义顺序解析：

1. receiver 具体类型的固有方法；
2. 原始类型提供的方法；
3. 具体类型唯一可用的 trait impl；
4. receiver 是受约束类型变量时，从其 trait bound 取得隐式 dictionary evidence。

找不到方法时报 E0305。

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

Vorton 0.1 不提供 `delegate` declaration。Impl 中以 `delegate field: Trait` 形式出现的旧表面必须稳定报错，并建议写普通 `impl Trait for Type`，由每个方法显式调用相应字段。普通 trait、associated type、supertrait、dictionary evidence 与手写 forwarding impl 均保持；编译器不得生成 delegate owner、wrapper body或专属 Core/ABI carrier。

## Compiler-defined 结构实现

编译器自动为所有 struct/enum 类型派生可派生的 trait。当前支持的 auto-derive trait：

- **Eq**: 当所有字段都实现 Eq 时自动派生。`==`/`!=` 运算符解糖为 `Eq.eq()` 调用。
- **Hash**: 仅当该 struct/enum 同时走编译器的结构化 auto-Eq 路径，且所有字段都可获得 Hash evidence 时自动派生。Struct 按字段声明顺序组合 hash；enum 先组合稳定的 variant discriminator，再组合字段。已有 manual Eq 不会隐式获得结构化 Hash，避免 `Eq` / `Hash` coherence 失配。
- **Clone**: 当所有字段都实现 Clone 时自动派生。
- **Debug**: 当所有字段都实现 Debug 时自动派生。
- **Ord**: 当所有字段都实现 Ord 时自动派生。`<`/`>`/`<=`/`>=` 运算符解糖为 `Ord.cmp()` 调用。

派生按依赖 fixpoint 扩展到嵌套与递归用户类型。`Hash` 的内建基础 evidence 当前包括 `Int`、`Str`、`Bool`，不包括 `Float` 或 `Unit`；缺少所需 evidence 时保持 fail closed，并在实际 trait bound 被要求时报告 E0503。

这些实现是 compiler-defined 的封闭语义，不对应 source attribute，也不能作为开放 derive 系统的入口。`Json` 不在该集合中；它是普通公开 trait，用户 struct/enum 只能写普通显式 impl，JSON 形状完全由该 impl 决定：

```vorton
struct Label {
    text: Str,
}

impl Json for Label {
    fn to_json(self: Self) -> Str {
        json_stringify(self.text)
    }
}
```

canonical 0.1 没有 `@` token、attribute grammar 或 source-level derive directive。缺少 `Json` evidence 的 `json_stringify` 调用报告 E0503；编译器不按用户类型字段自动生成 JSON 对象、variant tag 或 impl body。

## 限制

- 不支持 `dyn Trait` 动态分发
- 不支持 GATs（Generic Associated Types）
