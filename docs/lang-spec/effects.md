# Effect 与能力

函数可能做的事分成两类，规则完全不同：

| | 实例 | 是否属于函数类型 | 由谁处理 |
|---|---|---|---|
| **effect**（注入） | 用户 `effect` 声明、`fail<E>` | 是：调用方需要知道自己要处理什么 | 调用方用 `handle...with` 或 `catch` 提供实现 |
| **能力** | `console`、`fs`、`process`、`unsafe`，以及可能写入哪些实体 | 否：由编译器在全仓库范围推断 | 由宿主执行；模块用 `requires` 设上限 |

有 body 的函数通常省略 effect 标注，由编译器推断；显式 `with { ... }` 是公开允许的上界，不能覆盖或隐藏 body 的实际 effect。`with` 中只写 effect，不写能力。

修改调用方的数据只经由签名中的 `&mut` 参数或 `Cell` 发生，不作为 effect 追踪；见[类型系统](type-system.md#借出)。

Effect 声明、标注、`handle` 与 `catch` 的唯一产生式见[语法](syntax.md)；本页只定义类型与运行语义。

## Effect 分类与消除权

Effect row 中的 atom 共享组合与推断机制，但消除规则不同：

| 分类 | 实例 | 唯一消除规则 |
|---|---|---|
| Handled effect | 用户 `effect` 声明 | 进入 typed evidence，由显式 `handle...with` 消除 |
| Failure | `fail<E>` | 由 `catch` 或显式 failure handler 消除 |

Effect 的分类是固定的。未消除的 handled effect 与 failure 不得逃出 `main`。

`fail<T>` 由语言提供，不由隐藏源码或自动 prelude 声明。它与能力名 `console`、`fs`、`process`、`unsafe` 都不能被源码 effect/alias、import 或 re-export 重定义；相同拼写在其他 namespace 仍按各自规则处理。

Effect 与 effect alias 只在 Effect 上下文中作为 exact identity；它们不能作为 Type/Value 的 `::` 选择基础。Failure 的 `fail.raise` 是下文定义的语言操作。

## Effect Row

```text
EffectRow = { e₁, e₂, ..., eₙ }          // 封闭 row
EffectRow = { e₁, e₂, ..., eₙ, ..α }     // 开放 row
```

- 封闭 row 恰好包含列出的 effect；
- 开放 row 至少包含列出的 effect，其余由尾变量 `α` 捕获；
- `{}` 表示纯计算。

`..α` 只是语义规则中的元记号，不是源码写法。

具名函数可以在普通类型参数后声明 effect-row 参数。effect 在签名中的呈现方式（包括 `effect E` 参数）待 Milestone 4 定稿，下文按现行写法描述：

```vorton
fn apply<T, effect E>(value: T, callback: fn(T) with {E}) with {E} {
    callback(value)
}
```

在源码 row 中，已绑定的 `E` 表示整条 row，不是一个 atom；`with {E, Logger}` 表示把 `E` 的内容与 `Logger` 合并。多个 formal 可以同时出现，例如 `{E1, E2}`。没有差集、补集、条件 effect 或任意 effect 层函数。

函数类型写作 `fn(T₁, ..., Tₙ) -> R with { ... }`，是普通类型。函数类型中省略 `with` 时的 effect 多态规则待 Milestone 4 定稿。

普通推断变量必须在类型检查结束前求解。只有由函数 scheme 正式量化的开放尾可以保留；无法归属某个 scheme 的开放尾是编译错误。Effect alias 在此之前递归展开。

### Identity 与合并

合并两个 row 时：

1. `fail<T>` 与 `fail<U>` 匹配时统一 payload 类型；
2. 同一 exact handled effect 只对应一份 evidence，其类型参数必须统一；
3. 未匹配的 effect 只能进入开放尾，封闭侧不接受额外 effect。

不同开放尾都带未匹配项时，row unification 创建共享的新尾，并分别保留对侧未匹配项。Effect 分类不因 row 合并、alias 展开或 import 而改变。

泛型 custom effect 可以参数化，闭合实例保持不同的 identity，例如 `Reader<Int>` 与 `Reader<Str>`。实际用于 operation 查找、handler 安装或函数 contract 的 handled-effect 实例，其类型参数必须完全闭合；不能依赖运行时名称查找、类型擦除或特化补救。`fail<T>` 与 effect-row 参数不受这项限制。

## 函数的 may-effect contract

设有 body 函数的推断 row 为 `A`。`A` 是静态的 may-effect，可以保守合并所有可能分支：

- 普通函数、闭包、固有方法和 impl 方法省略外层 `with` 时，公开调用 contract 为 `A`；
- 显式 `with {B}` 把 `B` 固定为允许上界。编译器检查 `A ⊆ B`，公开调用和函数值类型都使用 `B`，不因当前 body 更纯而收窄；
- `with {}` 严格要求 `A = {}`，但纯计算不保证不会 panic 或一定终止；
- `extern fn` 没有 body，必须显式写外层 `with`，包括 pure 的 `with {}`；
- trait 方法省略外层 `with` 的含义由[按 impl 关联的 effect scheme](traits.md#按-impl-关联的-effect-scheme)规定；effect operation 调用只产生其所属的 handled effect，operation 本身不写外层 `with`。

```vorton
fn read_config(path: Str) -> Config with {Logger, fail<ConfigError>} {
    read_and_parse(path)
}
```

即使当前 `read_and_parse` 只产生 `fail<ConfigError>`，`read_config` 的公开 row 仍是 `{Logger, fail<ConfigError>}`。若 body 后来产生上界之外的 effect，编译器报错。

函数值只允许把自身 row 从较小的 row 适配到期望上界。参数数量、参数类型与借出方式、返回类型必须结构匹配；不引入参数或返回 variance、递归函数子类型或隐式 wrapper。

调用处对 effect formal 求唯一合法的最小解。纯 callback 使 `E = {}`；多个 callback 约束同一 `E` 时，取它们公开 row 的最小合法合并，并继续满足其他显式关系和上界。不存在唯一最小解时报错，不能任意扩大：

```vorton
fn sequence<effect E>(first: fn() with {E}, second: fn() with {E}) with {E} {
    first()
    second()
}
```

## Panic

Panic 是不可恢复的程序终止，不是 effect atom，也不等于 `fail<E>`。`catch` 和 `handle...with` 都不能捕获 panic；`Int` 算术可能 panic，但不会因此向 row 加入 effect。

Panic 发生后不再求值后续表达式，并终止整个程序。语言不保证对尚存的实体执行 `Drop`，也不做 stack unwinding。此前已经发生的修改、IO、实体移交或其他 effect 保持发生，不回滚。正常返回、failure、`break`、`continue` 与 handler 退出仍执行结构化 cleanup。

`with {}` 只表示没有 row effect，不保证函数不会 panic、一定终止或没有浮点舍入误差。本规范不规定 panic 的输出文字、退出码或栈追踪。

## 完整方法 scheme 引用

本节写法待 Milestone 4 定稿。

Effect row 可以用 `TraitPath::method<SelfActual, ..., effect {row}>` 引用 trait 方法的完整公开 scheme。`TraitPath` 必须解析到 exact trait，末段必须是该 trait 的 exact 方法；别名可以改变可见路径，但不改变 identity。裸方法名、`T::method` 或按名称从 impl 集合猜测都非法。

实参顺序固定为 `SelfActual`、trait 类型实参、方法类型实参，最后是各 effect-row 实参。它们与 trait evidence 必须来自同一次实例化。引用取得的是完整公开 scheme，而不是某个 body 的较窄 row；显式上界不能直接或间接引用自身。

Effect alias 可以用自己的类型参数引用已给定参数的方法 scheme；alias 不成为 effect formal 的量化 owner，也不改变透明展开规则。没有独立的 associated effect 成员、匿名 effect 函数或全局 impl-effect 并集。

## 有限 row 合并义务与递归

泛型 scheme 可以携带由 row 合并规则产生的有限合法性义务：

```vorton
fn attempt<T, effect E>(error: T, callback: fn() with {E}) with {E, fail<T>} {
    callback()
    fail.raise(error)
}
```

若某次实例化的 `E` 已含 `fail<U>`，合并时按既有规则统一 `T` 与 `U`；不兼容时在该调用处报告冲突来源。编译器不在运行时检查，也不为此建立通用约束语言。

普通函数的递归按调用图的强连通分量闭合：

```vorton
fn repeat<effect E>(done: Bool, callback: fn() with {E}) with {E} {
    if done { callback() } else { repeat(true, callback) }
}
```

这里递归 body 只消费已声明的 `E`，不以自己的最终公开结果定义自己。相反，`trait Loop { fn step(&self) with {Loop::step<Self>} }` 的显式 contract 直接自引用，必须拒绝；间接 contract 循环同样拒绝。正常的 body 递归不能因此被误判为 contract 循环。

## 能力

| 能力 | 语义范围 |
|---|---|
| `console` | 标准输出与标准错误输出 |
| `fs` | 文件系统访问，以及依赖工作目录或文件系统的路径解析 |
| `process` | 参数、工作目录、同步子进程与进程退出 |
| `unsafe` | 编译器无法验证其内存安全前提的操作，见下文 |
| 写入的实体 | 函数经 `&mut`、句柄或 `Cell` 可能写入的实体类型与 Region |

纯路径字符串运算不需要 `fs`。能力是静态事实，不是语言内的动态 provider，也不是 sandbox。

- **推断**：编译器沿调用图在全仓库范围推断每个函数的能力。经函数值的调用，按可能流到这里的全部函数合并。
- **不进类型**：能力不写进函数签名或函数类型，也不能被 `handle` 或 `catch` 消除。
- **上限**：模块用 `requires` 设置能力上限，编译器强制执行，见[模块系统](modules.md#inline-mod-与-capability)。检查上限时，存进数据的回调，其能力算在定义它的模块，而不是调用它的模块。
- **宿主声明**：宿主提供的函数没有 body 可供推断，必须声明自己的能力与 `fail<E>` contract；不能因为是 extern、runtime bridge 或 intrinsic 而省略。声明写法与 effect 的签名写法一起在 Milestone 4 定稿。

需要可替换或可 mock 的依赖时，声明用户 handled effect，再用普通 handler 翻译到宿主操作：

```vorton
effect FileAccess {
    fn read(path: Str) -> Str
}

fn load(path: Str) -> Config with {FileAccess} {
    parse(FileAccess.read(path))
}

fn load_from_host(path: Str) -> Config with {fail<FsError>} {
    handle { load(path) } with {
        FileAccess.read(p) => read_file(p)      // read_file 需要 fs 能力
    }
}
```

宿主操作本身不可被 `handle`，因此抽象依赖和真实宿主访问保持分离。

## 用户自定义 Effect

```vorton
effect Logger {
    fn log(message: Str) -> Unit
}

fn write_log(message: Str) with {Logger} {
    Logger.log(message)
}
```

Operation 签名规定参数、返回类型和调用时产生的 handled effect。Operation 通过 `EffectName.operation(...)` 调用；receiver 必须解析到 exact handled-effect 声明（或语言的 failure effect），operation 必须解析到该 effect 的 exact 声明。缺失的 operation、effect alias receiver 或能力名 receiver 在名称解析阶段拒绝。`EffectName::operation(...)` 不是 operation 调用的另一种写法。

Effect operation 只有签名，没有 body。Custom effect 必须由显式 `handle...with` 提供解释；没有默认实现。

### Effect alias

`effect alias` 给一组 effect 命名：

```vorton
effect alias Services = {Logger, Clock}
effect alias Fallible<E> = {fail<E>}
```

Alias 可以泛型化、可以 `pub` 导出，并在类型检查前递归展开；循环 alias 被拒绝。循环检查的节点是 exact effect alias 声明，边来自右侧显式出现的 alias，包括方法 scheme 引用中嵌套的 effect-row 实参。普通 effect、effect formal 与方法 scheme 引用本身不形成边。泛型实参不创建新节点；没被使用的 alias 同样参与循环检查。展开后的 exact atom 才参与 identity 与能力检查，alias 本身不产生 evidence 或新的运行时 effect。

## `unsafe` 能力

`unsafe` 标记编译器无法验证其内存安全前提的操作。这样的操作只能写在词法 `unsafe { ... }` 块中，所在模块必须以 `requires {unsafe}` 获得许可。`unsafe` 不进入函数类型，调用含有 `unsafe` 块的函数不需要任何标记；它作为能力出现在推断结果与仓库地图上。

```vorton
mod raw_buffer requires {unsafe} {
    fn first(ptr: Ptr<Int>) -> Int {
        unsafe { ptr.read() }
    }
}
```

`unsafe { ... }` 块内的 failure 与 handled effect 照常传播。`requires {unsafe}` 只是许可，本身不证明块内的不变量。

## Effect 传播

Effect 按实际求值组合：

| 表达式 | 结果 effect |
|---|---|
| 字面量、标识符 | `{}` |
| 运算、参数列表、代码块 | 已求值子表达式的 row 合并 |
| 函数调用 | 被调函数 row 与参数求值 row 合并 |
| 方法调用 | receiver、方法与参数 row 合并 |
| `if` / `match` | 条件或 scrutinee 与所有分支 row 合并 |
| 闭包 | body row 存入函数类型；创建闭包本身是纯的 |

有 body 的函数没有外层 `with` 时，以 body 推断出的 row 为公开 contract；有显式上界时检查 body row 是其子集，并以上界为公开 contract。

### 带 effect 的函数值

闭包不捕获定义处当前安装的 handled-effect evidence。Body row 冻结在函数类型中，每次调用从调用处当前的动态 handler 环境取得 evidence。没有对应 handler 时，effect 继续传播，不能因为闭包在某个 `handle` 内创建而提前消除。

因此纯的工厂函数可以返回带 effect 的闭包：调用工厂不产生该 effect，调用返回的闭包时才产生。闭包在 handler 内创建后逃逸，不会延长已经结束的 handler 作用域；在新 handler 内调用时使用新的 evidence。

开放的 effect-row formal 原样转发当前上下文。实现不能用全局或线程局部的根 handler、运行时名称查找、闭包隐式捕获 handler 或另一套函数值 ABI 改变这一语义。

## Effect 消除

### `catch`

`catch` 捕获左侧计算的 `fail<E>`，并用 match 分支处理 payload：

```vorton
let value = risky() catch {
    Missing(name) => default_for(name)
    Invalid(message) => repair(message)
}
```

分支对 `E` 做穷尽性检查；只处理一部分时，必须在分支中显式重新 raise。被捕获计算的 failure 被消除，分支新产生的 effect 向外传播。

### `handle ... with`

```vorton
let result = handle {
    Logger.log("hello")
    42
} with {
    Logger.log(message) => record(message)
}
```

Handler 在 body 的动态调用范围内提供 handled-effect 的操作。被完整处理的 exact handled effect 从 body row 中消除；开放尾中的未知 effect 与分支新产生的 effect 继续传播。若 row 是 `{Logger, R}`，处理 `Logger` 后保留 `R`；若 callback row 只有未知 formal `E`，handler 不能假定其中含有 `Logger`，保守地原样传播 `E`。能力不是 effect，不能由 `handle` 删除。

一个 `handle...with` 只要为某个 effect 写了一个操作分支，就必须覆盖该 effect 声明的全部操作，各恰好一次。分支顺序任意；缺失、重复、未知或跨 effect 的分支都是编译错误。只需拦截部分操作时，拆分 effect 或为其余操作写显式转发分支。

## Handler 语义

非 abort 操作是 tail-resumptive：分支结果作为操作的返回值，原计算随后继续。分支结果必须兼容操作的返回类型；返回 `Unit` 的操作丢弃分支值，`Never` 可用于任意返回位置。没有显式 `resume`、resume 之后的代码或 multi-shot continuation。

`fail.raise(error)` 不恢复原计算。捕获它的分支恰好执行一次，分支结果替换整个 `handle` 或 `catch` 表达式；处理当前 failure 时对应 handler 已失效，再次 raise 会逃向外层。

## 高阶 effect formal

具名函数用显式 effect 参数表达 callback 与外层 row 的关系：

```vorton
fn transform<T, U, effect E>(value: T, callback: fn(T) -> U with {E}) -> U with {E} {
    callback(value)
}
```

Callback 的 handled 与 failure effect 都通过 `E` 传播，高阶函数不能假装 callback 是纯的。Callback 的能力由编译器另行推断，不经过 `E`。

`extern fn` 没有 body 可供反推，必须写出完整的 effect 关系与能力。Type/effect alias 透明展开，不成为隐式 formal 的 owner；effect operation 不获得量化能力。

## Drop 边界

用户 `Drop::drop` 的最终推断 row 必须为空，`fail` 与 handled effect 均禁止；0.1 中它也不能使用 `console`、`fs`、`process` 能力。编译器生成的字段递归释放、计数释放与内建 cleanup 不属于用户 effect body。

## 0.1 边界

- Handler 只支持 tail-resumptive 操作与 abortive failure；
- 不支持 resume 之后的代码或多次 resume；
- 能力不是语言内 sandbox，只是可推断、可审计的宿主能力摘要；
- 分配本身不是能力；原始分配操作需要 `unsafe`。

工具默认展示推断结果，诊断优先指出缺少的 effect 或超出上限的能力，以及它们的实际来源。物化推断结果时，不能把 trait 方法的省略项替换为当前某个 impl 的具体 row。
