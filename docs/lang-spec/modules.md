# 模块系统

Vorton 使用基于文件的模块系统。每个 `.vorton` 文件是一个模块。模块通过 `use` 声明导入其他模块的公开符号。

`requires`、`use`、inline `mod` 与 path 的唯一产生式见[语法](syntax.md)；本页只定义解析后的模块身份、可见性与依赖语义。

## 模块标识

模块名由文件路径派生，`::` 分隔符映射到文件系统目录分隔符：

```
use parser::lexer;   →  parser/lexer.vorton
use utils;           →  utils.vorton
```

项目根目录是入口文件所在目录。

## 导入语法

### 单符号导入

```vorton
use parser::Token;
```

从 `parser.vorton` 导入 `Token`。

### 多符号导入

```vorton
use parser::{Token, parse, Lexer};
```

从同一模块导入多个符号。

### 整模块导入

```vorton
use parser;
```

该形式把 `parser` 的所有 `pub` 符号直接导入当前作用域，不创建可通过 `parser::Token` 访问的 module value。

### 重命名导入

```vorton
use parser::{Token as T};
```

命名导入可以用 `as` 创建局部别名。整模块 `use parser as p` 不受支持。

### 嵌套路径

```vorton
use checker::env::TypeEnv;
```

映射到 `checker/env.vorton` 中的 `TypeEnv`。

### 相对路径（`super::`/`self::`）

在 inline `mod` 块内部，可以使用相对路径引用外层模块的符号。

#### `super::` 引用父模块

```vorton
mod outer {
    pub fn value() -> Int { 42 }

    mod inner {
        use super::value;      // 导入父模块 outer 的 value
        pub fn get() -> Int { value() }
    }
}
```

`super::` 可以在 `use` 声明中使用，也可以在表达式中直接使用：

```vorton
mod outer {
    pub fn value() -> Int { 42 }

    mod inner {
        pub fn get() -> Int { super::value() }   // 表达式中直接访问
    }
}
```

支持多级 `super` 链式引用和多符号导入：

```vorton
use super::super::some_fn;        // 向上两层
use super::{value, helper};       // 从父模块导入多个符号
```

在文件顶层使用 `super::` 会因超出模块嵌套深度而报错。

#### `self::` 引用当前模块

```vorton
mod math {
    pub fn add(a: Int, b: Int) -> Int { a + b }

    pub fn double(x: Int) -> Int {
        self::add(x, x)    // 显式引用当前模块的 add
    }
}
```

`self::` 用于消除歧义，显式指定当前模块的符号。

## 导出和可见性

### `pub` 修饰符

```vorton
pub fn greet() -> Str { "hello" }
pub struct Point { pub x: Int, pub y: Int }
```

未标记 `pub` 的声明不可被其他模块导入。`pub` 不改变声明在自身 module 内的可见性。

### `pub use` 再导出

```vorton
pub use inner::greet;
```

将依赖模块的导出提升为当前模块的公开接口。支持模块门面模式。

0.1的public export必须对enum constructor保持owner closure：一个facade若单独公开或重命名constructor，其最终public type exports中也必须包含该constructor的exact owner enum；不要求两者来自同一条`pub use`。

```vorton
// 合法：owner enum 与constructor同时公开
pub use leaf::{Token, Wrap};

// 合法：两者都可重命名
pub use leaf::{Token as PublicToken, Wrap as Make};

// 非法：facade只公开constructor，缺少owner enum
pub use leaf::Wrap;
```

最后一种写法在 re-export 处报错并要求同时公开 owner enum。直接 `pub use` 一个 enum 会携带其 constructors；private/local `use` 不受该 public closure 规则影响。Owner identity 由声明解析决定，不能从 constructor leaf 或 alias spelling 猜测。

### Private field 与private representation

Public struct的private field可以使用private nominal type，例如`pub struct Wrapper { hidden: PrivatePayload }`。外部module可以持有、传递和销毁`Wrapper`，但不能访问`hidden`、命名`PrivatePayload`或用field literal自行构造该值。相反，public函数签名、pub field与public enum variant payload属于真正public interface，仍不得引用更private type。

Compiler 可以随 public root 运输销毁与 layout 所需的 private metadata，但 consumer source namespace 不能因此获得 private type、constructor 或 field。Re-export 与 diamond 必须复用 exact owner，不能按名称重新选择。预声明语言类型的 binding 规则见[类型系统](type-system.md#语言预声明类型)。

## Inline `mod` 块

除了基于文件的模块外，Vorton 支持在同一文件内定义 inline 模块块。

### 基本语法

```vorton
mod math {
    pub fn add(a: Int, b: Int) -> Int { a + b }
    pub fn double(x: Int) -> Int { x + x }
}

fn main() {
    let sum = math::add(1, 2);
}
```

`mod` 块内的声明通过 `mod_name::symbol` 限定路径访问。未标记 `pub` 的声明在模块外不可见。

### 嵌套模块

`mod` 块可以嵌套，形成多级命名空间：

```vorton
mod outer {
    pub mod inner {
        pub fn greet(name: Str) -> Str {
            "hello ${name}"
        }
    }
}

fn main() {
    let msg = outer::inner::greet("world");   // 多级限定路径
}
```

嵌套模块中的 `pub` 控制对外层的可见性——内层模块需要 `pub` 才能被外层模块之外访问，内层的声明也需要 `pub`。

### 声明唯一性（不支持 partial module）

同一 direct parent scope 中，每个 inline module 名称只能声明一次：

```vorton
mod tools {
    pub fn first() -> Int { 1 }
}

mod tools {                         // 非法：重复声明
    pub fn second() -> Int { 2 }
}
```

重复的第二个 `mod tools` 本身就是错误；编译器不会把两个 block 合并后再检查其成员。一个合法 module block 内，同一 namespace 的 direct declaration 同样必须唯一。

相同 leaf 位于不同 parent 时是不同 logical module，因此合法：

```vorton
mod outer {
    mod inner {}
}

mod inner {}
```

`use`、`pub use` 与 same-origin diamond 只是把既有 declaration delivery 到其他 scope；同一 exact origin 的重复 delivery 可以幂等复用，不构成重复 source declaration。多个 `impl` block 也不属于 partial module，按 impl/coherence 规则独立处理。

### `mod` 块内的 `use` 声明

`mod` 块内部可以使用 `use` 导入外部模块的符号，也可以使用 `super::`/`self::` 相对路径（见上文）：

```vorton
mod outer {
    pub fn value() -> Int { 42 }

    mod inner {
        use super::value;
        pub fn get_outer() -> Int { value() }
    }
}
```

### `mod` 块内的声明

`mod` 块内可以包含所有声明类型：函数、struct、enum、trait、impl、effect、const、嵌套 mod 等。

```vorton
mod shapes {
    pub struct Circle { pub radius: Float }

    impl Circle {
        pub fn area(self) -> Float { 3.14159 * self.radius * self.radius }
    }
}
```

### Capability 限制（`requires`）

文件本身是隐式模块。文件模块使用第一项 `requires {effects}` header，inline module 使用 `mod name requires {effects}` clause；两者限制模块内所有函数可以使用的 effect 集合。Module 内函数使用不在有效 `requires` 集合中的 effect 时编译失败。

#### 文件模块 header

```vorton
requires {unsafe};

extern fn host_alloc(count: Int) -> Ptr<Int>;
```

文件 header 必须是第一项非注释语法、每文件至多一次，并位于全部 `use` 与声明之前。有 header 时，它是文件模块的 effect ceiling；省略 header 时，普通 system/handled/fail/mut 不增加额外 ceiling，但 `unsafe` 许可从不隐式获得。使用或 discharge unsafe 原语、以及声明 `extern fn`，都要求有效文件/inline-module `requires` 集合显式包含 `unsafe`。

Header只提供模块许可：unsafe原语仍必须位于`unsafe {}`责任块。Extern声明本身是“签名忠实于C实现”的ABI签字，调用extern函数不向调用点传播unsafe。Vorton不提供逐声明`unsafe extern fn`第二套授权语法。

#### 纯模块（无 effect）

```vorton
mod pure_logic requires {} {
    pub fn add(a: Int, b: Int) -> Int { a + b }
    pub fn double(x: Int) -> Int { x + x }
    // 此模块内不能使用 fs、fail 等任何 effect
}
```

`requires {}` 表示空 effect 集合——模块内只允许纯函数。任何尝试使用 system、handled、fail、mut 或 unsafe effect 的函数都会报错。

#### 受限模块（指定 effect 子集）

```vorton
mod console_layer requires {console} {
    pub fn greet(name: Str) -> Unit with {console} {
        print("Hello, ${name}!");
    }
    // 此模块内只允许 console effect，使用 fs、process 或 fail 会报错
}
```

#### Capability 检查规则

- 检查覆盖模块内所有顶层函数和显式 impl 方法
- 纯函数（无 effect）在任何 `requires` 集合中都合法——开放的 effect row 尾部不会被误判
- `console` / `fs` / `process` 是 system effect：它们参与静态 capability 检查，但不能由 `handle` 消除，也不产生 handler evidence
- 用户 custom effect 是 handled effect：它同样参与 `requires` 检查，并且必须在离开 `main` 前由显式 handler 消除
- `mut<T>` marker effect 参与 capability 检查；`requires {}` 禁止修改参数或捕获状态等会让 mutation effect 逃逸的操作，局部 `let mut` 仍保持局部
- `unsafe` 同时要求 `unsafe { ... }` discharge 与包含 `unsafe` 的文件header或inline-module许可；`extern fn`声明也要求该显式许可

## Module graph

Compiler 从入口文件沿 `use` 发现依赖 module，并在检查 body 前闭合 module graph 与 public interface。循环依赖被拒绝。Module 与 declaration 的 nominal identity 包含完整 module path；不同 module 中同名的 struct、enum、function 或 trait 不会因 leaf name 相同而合并。Target symbol encoding 不属于 module 语义。

## 限制

- 不支持 first-class module；
- 不提供 `sig` declaration 或 module-signature conformance；
- 不支持跨文件相对 path，`super::` 与 `self::` 只在 inline `mod` 中可用。
