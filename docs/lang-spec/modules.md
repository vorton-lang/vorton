# 模块系统

Ring 使用基于文件的模块系统。每个 `.ring` 文件是一个模块。模块通过 `use` 声明导入其他模块的公开符号。

## 模块标识

模块名由文件路径派生，`::` 分隔符映射到文件系统目录分隔符：

```
use parser::lexer    →  parser/lexer.ring
use utils            →  utils.ring
```

项目根目录是入口文件所在目录。

## 导入语法

### 单符号导入

```ring
use parser::Token
```

从 `parser.ring` 导入 `Token`。

### 多符号导入

```ring
use parser::{Token, parse, Lexer}
```

从同一模块导入多个符号。

### 整模块导入

```ring
use parser
```

当前实现把 `parser` 的所有 `pub` 符号直接导入当前作用域。该形式不会创建可通过 `parser::Token` 访问的模块值。

### 重命名导入

```ring
use parser::{Token as T}
```

命名导入可以用 `as` 创建局部别名。整模块 `use parser as p` 当前不受支持。

### 嵌套路径

```ring
use checker::env::TypeEnv
```

映射到 `checker/env.ring` 中的 `TypeEnv`。

### 相对路径（`super::`/`self::`）

在 inline `mod` 块内部，可以使用相对路径引用外层模块的符号。

#### `super::` 引用父模块

```ring
mod outer {
    pub fn value() -> Int { 42 }

    mod inner {
        use super::value       // 导入父模块 outer 的 value
        pub fn get() -> Int { value() }
    }
}
```

`super::` 可以在 `use` 声明中使用，也可以在表达式中直接使用：

```ring
mod outer {
    pub fn value() -> Int { 42 }

    mod inner {
        pub fn get() -> Int { super::value() }   // 表达式中直接访问
    }
}
```

支持多级 `super` 链式引用和多符号导入：

```ring
use super::super::some_fn         // 向上两层
use super::{value, helper}        // 从父模块导入多个符号
```

在文件顶层使用 `super::` 会报 E0705 错误（超出模块嵌套深度）。

#### `self::` 引用当前模块

```ring
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

```ring
pub fn greet() -> Str { "hello" }
pub struct Point { pub x: Int, pub y: Int }
```

在多文件模式下，未标记 `pub` 的声明不可被其他模块导入。导入非 pub 符号报 E0701 错误。

单文件模式下 `pub` 被接受但不强制执行（向后兼容）。

### `pub use` 再导出

```ring
pub use inner::greet
```

将依赖模块的导出提升为当前模块的公开接口。支持模块门面模式。

0.1的public export必须对enum constructor保持owner closure：一个facade若单独公开或重命名constructor，其最终public type exports中也必须包含该constructor的exact owner enum；不要求两者来自同一条`pub use`。

```ring
// 合法：owner enum 与constructor同时公开
pub use leaf::{Token, Wrap}

// 合法：两者都可重命名
pub use leaf::{Token as PublicToken, Wrap as Make}

// 非法：facade只公开constructor，缺少owner enum
pub use leaf::Wrap
```

最后一种写法在re-export处稳定报错并建议同时公开owner enum。直接`pub use`一个enum仍自动携带其constructors；private/local `use`不受该public closure规则影响。实现按exact `VariantRef.owner`核对，不能从constructor leaf、alias spelling或唯一名字猜owner，也不能为接受constructor-only facade而隐式扩大type/impl可见性。

### Private field 与private representation

Public struct的private field可以使用private nominal type，例如`pub struct Wrapper { hidden: PrivatePayload }`。外部module可以持有、传递和销毁`Wrapper`，但不能访问`hidden`、命名`PrivatePayload`或用field literal自行构造该值。相反，public函数签名、pub field与public enum variant payload属于真正public interface，仍不得引用更private type。

Provider随正常public root输出仅供compiler使用的exact physical metadata closure；consumer checker不把其中private nominal加入source-visible`types`、import或constructor namespace。Re-export/diamond原样复用exact owner，metadata lookup只接受`RegisteredNominalRef`，禁止name-first fallback。

### 0.1 保留 type binding 与模块冲突

0.1 的 type namespace 保留集合为：`Int Float Str Bool Unit Never Ptr Range Cell Option List ListIterator Map MapIterator Set SetIterator StringBuilder Result`。Direct type declaration、`use` 或 `pub use` 的最终本地绑定名若命中该集合，稳定报 `E0207`；same-origin delivery或re-export不能豁免保留名冲突，alias只按其最终本地名字判定，改成非保留名后服从普通模块规则。只有固定 canonical builtin/std loader producer 具有内部豁免。该规则不限制 value、function、trait、effect 或 module namespace 的同名符号。

这是一项 0.1 已知限制：最终上移到标准库的类型完成既有标准库/RIIR 迁移后，会逐项恢复为普通 module type；此后两个来源的同名 type binding 不能静默互相覆盖，用户应保留限定路径或使用非冲突的 import alias。真正的语言 builtin type仍保持不可覆盖。该迁移不需要在本规范中建立新的 post-0.1 item。

## Inline `mod` 块

除了基于文件的模块外，Ring 支持在同一文件内定义 inline 模块块。

### 基本语法

```ring
mod math {
    pub fn add(a: Int, b: Int) -> Int { a + b }
    pub fn double(x: Int) -> Int { x + x }
}

fn main() {
    let sum = math::add(1, 2)
}
```

`mod` 块内的声明通过 `mod_name::symbol` 限定路径访问。未标记 `pub` 的声明在模块外不可见。

### 嵌套模块

`mod` 块可以嵌套，形成多级命名空间：

```ring
mod outer {
    pub mod inner {
        pub fn greet(name: Str) -> Str {
            "hello ${name}"
        }
    }
}

fn main() {
    let msg = outer::inner::greet("world")    // 多级限定路径
}
```

嵌套模块中的 `pub` 控制对外层的可见性——内层模块需要 `pub` 才能被外层模块之外访问，内层的声明也需要 `pub`。

### 声明唯一性（不支持 partial module）

同一 direct parent scope 中，每个 inline module 名称只能声明一次：

```ring
mod tools {
    pub fn first() -> Int { 1 }
}

mod tools {                         // E0207: Duplicate definition
    pub fn second() -> Int { 2 }
}
```

重复的第二个 `mod tools` 本身就是错误；编译器不会把两个 block 合并后再检查其成员。一个合法 module block 内，同一 namespace 的 direct declaration 同样必须唯一。

相同 leaf 位于不同 parent 时是不同 logical module，因此合法：

```ring
mod outer {
    mod inner {}
}

mod inner {}
```

`use`、`pub use` 与 same-origin diamond 只是把既有 declaration delivery 到其他 scope；同一 exact origin 的重复 delivery 可以幂等复用，不构成重复 source declaration。多个 `impl` block 也不属于 partial module，按 impl/coherence 规则独立处理。

### `mod` 块内的 `use` 声明

`mod` 块内部可以使用 `use` 导入外部模块的符号，也可以使用 `super::`/`self::` 相对路径（见上文）：

```ring
mod outer {
    pub fn value() -> Int { 42 }

    mod inner {
        use super::value
        pub fn get_outer() -> Int { value() }
    }
}
```

### `mod` 块内的声明

`mod` 块内可以包含所有声明类型：函数、struct、enum、trait、impl、effect、const、嵌套 mod 等。

```ring
mod shapes {
    pub struct Circle { pub radius: Float }

    pub impl Circle {
        pub fn area(self) -> Float { 3.14159 * self.radius * self.radius }
    }
}
```

### Capability 限制（`requires`）

文件本身是隐式模块。文件模块使用第一项 `requires {effects}` header，inline module 使用 `mod name requires {effects}` clause；两者限制模块内所有函数可以使用的 effect 集合，并由同一 typed capability checker 验证。模块内函数使用不在有效 `requires` 集合中的 effect 时，报 E0405。

#### 文件模块 header

```ring
requires {unsafe}

use std::ptr
extern fn ring_raw_alloc(count: Int) -> Ptr<Int>
```

文件 header 必须是第一项非注释语法、每文件至多一次，并位于全部 `use` 与声明之前。有 header 时，它是文件模块的 effect ceiling；省略 header 时，普通 system/handled/fail/mut 不增加额外 ceiling，但 `unsafe` 许可从不隐式获得。使用或 discharge unsafe 原语、以及声明 `extern fn`，都要求有效文件/inline-module `requires` 集合显式包含 `unsafe`。

Header只提供模块许可：unsafe原语仍必须位于`unsafe {}`责任块。Extern声明本身是“签名忠实于C实现”的ABI签字，调用extern函数不向调用点传播unsafe。Ring不提供逐声明`unsafe extern fn`第二套授权语法。

#### 纯模块（无 effect）

```ring
mod pure_logic requires {} {
    pub fn add(a: Int, b: Int) -> Int { a + b }
    pub fn double(x: Int) -> Int { x + x }
    // 此模块内不能使用 fs、fail 等任何 effect
}
```

`requires {}` 表示空 effect 集合——模块内只允许纯函数。任何尝试使用 system、handled、fail、mut 或 unsafe effect 的函数都会报错。

#### 受限模块（指定 effect 子集）

```ring
mod console_layer requires {console} {
    pub fn greet(name: Str) -> Unit with {console} {
        print("Hello, ${name}!")
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

## 编译模型

### 自动检测

编译器通过检查源文件中是否有 `use` 声明来决定编译模式。有 `use` → 多文件模式，无 `use` → 单文件模式。

### 编译流程

```
1. 从入口文件开始，BFS 发现所有依赖模块
2. 拓扑排序（Kahn 算法）确定编译顺序
3. 按序处理每个模块：
   a. Parse → AST
   b. 在依赖模块的公开接口环境中 Check → HIR
   c. 合并为保持模块身份的程序级 HIR
4. 将程序级 HIR 交给选定 target lowering；目标文件表示与链接策略不属于模块语义
```

### 循环依赖

循环依赖在拓扑排序阶段检测，报 E0704 错误。

模块与声明的名义身份包含完整模块路径。不同模块中同名的 struct、enum、函数或 trait 不会因为叶名称相同而合并；具体目标符号编码由后端决定。

## 错误码

| 错误码 | 描述 |
|--------|------|
| E0207 | 同一 scope/namespace 中的重复 source declaration（包括重复 inline `mod`） |
| E0405 | Capability 限制或许可违反（文件/inline `requires` 中使用了不允许的 effect，或缺少显式 unsafe 许可） |
| E0701 | 导入非 pub 符号 |
| E0702 | 模块未找到 |
| E0703 | 模块中无此符号 |
| E0704 | 循环依赖 |
| E0705 | 重复导入 / 相对路径超出模块嵌套深度 |
| E0706 | `use` 不在文件顶部 |
| E0707 | 来自不同 origin 的导入歧义；不用于 source duplicate |
| E0708 | 项目内 `extern fn` forward declaration 匹配到多个实现 |

## 限制

- 不支持 first-class modules
- 0.1 不提供 `sig` 声明或 module-signature conformance；post-0.1 的 B-192 只有在真实 conformance 一并实现时才会重新设计该能力
- 不支持跨文件相对路径（`super::`/`self::` 仅在 inline `mod` 块内可用）
- LSP 当前不可用，因此跨文件跳转、引用查找与 hover 尚无受支持入口
