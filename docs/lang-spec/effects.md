# Effect 系统

Vorton 用 effect row 描述计算可能发生的副作用。函数声明通常省略 effect 标注并由编译器推断；显式 `with { ... }` 是约束和文档，不改变函数体的实际语义。

Effect declaration、annotation、`handle` 与 `catch` 的唯一产生式见[语法](syntax.md)；本页只定义类型与运行语义。

## Effect 分类与消除权

Effect row 中的 atom 共享组合与推断机制，但拥有不同的执行与消除规则：

| 分类 | Canonical instance | 唯一消除或执行规则 |
|---|---|---|
| System effect | `console`、`fs`、`process` | 不可 `handle`，不进入 evidence；由目标 host provider 执行 |
| Handled effect | 用户 `effect` 声明 | 进入 typed evidence，由显式 `handle...with` 消除 |
| Failure | `fail<E>` | 由 `catch` 或显式 failure handler 消除 |
| Mutation marker | `mut<T>` | 只由局部性与状态作用域规则消除 |
| Unsafe obligation | `unsafe` | 只由词法 `unsafe { ... }` discharge |

Effect class 在 typed contract 冻结前固定。System effect 绝不能获得 handler evidence；handled effect 绝不能直接变成 host operation。`main` 可以保留 system effect，由目标环境执行；未消除的用户 handled effect 不得逃出 `main`。

`console`、`fs`、`process`、`fail<T>`、`mut<T>` 与 `unsafe` 使用独立 `Language` origin，不由隐藏 source 或自动 prelude 声明。它们在 Effect namespace 中不可被 source effect/alias、import 或 re-export 重定义；相同 spelling 在其他 namespace 仍按各自规则处理。`mut` 与 `unsafe` 保持已有特殊 surface，其他 language effect 使用普通 resolved path。

Effect 与 effect alias 只在 Effect context 中作为 exact identity；它们不是 Type/Value 的 type-relative `::` selection base。Failure 的 `fail.raise` 是下文明确的 Language operation；system effect 本规范不声明静态 operation member。Resolver 不能因内部 member table 未命中而发明或延期 `console::Item`、`console::operation` 一类选择。

## Effect Row

```text
EffectRow = { e₁, e₂, ..., eₙ }          // 封闭 row
EffectRow = { e₁, e₂, ..., eₙ, ..α }     // 开放 row
```

- 封闭 row 恰好包含列出的 effect；
- 开放 row 至少包含列出的 effect，其余由尾变量 `α` 捕获；
- `{}` 表示纯计算。

规范中的函数类型可写成 `(T₁, ..., Tₙ) -> R / ε`。源码函数类型用 `fn(T₁, ..., Tₙ) -> R with { ... }` 表示显式 row；省略 `with` 时可保留开放尾以支持 effect 多态。该函数类型直接出现在返回箭头后时须按[统一返回类型语法](syntax.md#path类型与-effect)写入透明分组，组内 `with` 仍属于返回的函数类型。

普通推断 metavariable 必须在 TypedHIR 前求解。只有由函数 scheme 正式量化的开放尾可以保留，并获得稳定的 owner 与 ordinal；无法归属 formal scheme 的 raw tail 是编译错误。Effect alias 在此之前递归展开。

具名 callable 作为 first-class value 时还必须满足[同检查单元的 closed-header 规则](type-system.md#同检查单元的具名函数值)；该规则不改变 ordinary direct call 的 effect inference。

### Identity 与合并

合并两个 row 时：

1. system effect 按 exact capability identity 去重；`fs`、`console`、`process` 互不相等；
2. `unsafe` 与 `unsafe` 是同一实例；
3. `fail<T>` 与 `fail<U>` 匹配时统一 payload type；
4. 同一 exact handled effect 只对应一份 evidence，其 type arguments 必须统一；
5. `mut<T>` 按完整 state type 区分，可在同一 row 保留多个实例；
6. 未匹配 effect 只能进入开放尾，封闭侧不接受额外 effect。

不同开放尾都带未匹配项时，row unification 创建共享 fresh tail，并分别保留对侧未匹配项。Effect class 不因 row 合并、alias 展开或 module import 而改变。

Generic custom effect 可以参数化，closed concrete instance 保持不同 typed identity，例如 `Reader<Int>` 与 `Reader<Str>`。任何实际用于 operation lookup、handler install 或 callable contract 的 handled-effect instance，其 type arguments 都必须完全闭合；不能依赖 runtime name lookup、type erasure 或 specialization 补救。`fail<T>`、`mut<T>` 与正式 effect-row parameter 不属于这项 runtime identity 限制。

## System effects

Canonical 0.1 定义三类 system effect：

| Effect | 语义范围 |
|---|---|
| `console` | 标准输出与标准错误输出 |
| `fs` | 文件系统访问及依赖工作目录或文件系统的路径解析 |
| `process` | 参数、工作目录、同步子进程与进程退出 |

纯路径字符串运算不产生 `fs`。System effect 是静态能力事实，不是语言内动态 provider。Host declaration 必须携带 exact system effect 与正交的 `fail<E>` contract；它不能因为是 extern、runtime bridge 或 intrinsic 而省略 capability。

需要可替换或可 mock 的依赖时，程序声明用户 handled effect，再用普通 handler adapter 翻译到 system operation：

```vorton
effect FileAccess {
    fn read(path: Str) -> Str;
}

fn load(path: Str) -> Config with {FileAccess} {
    parse(FileAccess.read(path))
}

fn load_from_host(path: Str) -> Config with {fs, fail<FsError>} {
    handle { load(path) } with {
        FileAccess.read(p) => read_file(p),
    }
}
```

直接 system operation 本身不可被 `handle`，因此抽象依赖和真实宿主访问保持分域。

## 用户自定义 Effect

```vorton
effect Logger {
    fn log(message: Str) -> Unit;
}

fn write_log(message: Str) -> Unit with {Logger} {
    Logger.log(message)
}
```

Operation signature 规定参数、返回类型和调用时产生的 handled effect。Operation 通过 `EffectName.operation(...)` 调用。Receiver 必须解析到 exact handled-effect declaration（或明确的 Language failure effect），operation 必须解析到该 owner 的 exact declaration；缺失 operation、effect alias receiver 或 system-effect receiver 都在 Resolver 拒绝。`EffectName::operation(...)` 不是 operation call 的替代拼写。

Effect operation 只有 signature，不允许 body。Custom effect 必须由显式 `handle...with` 提供解释；不存在自动 default evidence、部分默认或 default-body fallback。

### Effect alias

`effect alias` 给一组 effect 命名：

```vorton
effect alias HostIO = {console, fs, process};
effect alias Fallible<E> = {fail<E>};
```

Alias 可泛型化、可 `pub` 导出，并在类型检查前递归展开；循环 alias 被拒绝。展开后的 exact atom 才参与 identity、capability 与 ABI，alias 本身不制造 evidence 或新的 runtime effect。

## `mut<T>` Marker Effect

`mut<T>` 记录计算触及的外部可变 state type。

- 修改函数自己的局部 `let mut` binding 不让 `mut` 逃逸到函数签名；
- 通过 `mut` parameter 修改 caller state，或修改 closure 捕获的外部可变 state，会注入相应的 `mut<T>`；
- 调用 mutable receiver 仍要求可变 binding；effect 不替代这项检查；
- Module `requires { ... }` 检查逃逸的 `mut<T>`，因此 `requires {}` 的 pure module 不能修改外部 state。

`mut<T>` 是多实例 marker。同一 row 可以同时包含 `mut<Int>` 与 `mut<Str>`，它们不能因为都叫 `mut` 而合并。裸标注 `with {mut}` 每次实例化时引入 fresh state type。

## `unsafe` Effect

`unsafe` 标记编译器不能验证其 memory-safety premise 的 operation。它进入函数签名并向 caller 传播，不能由普通 `handle` 或 `catch` 消除；唯一 discharge 形式是词法 `unsafe { ... }` block。

```vorton
mod raw_buffer requires {unsafe} {
    fn first(ptr: Ptr<Int>) -> Int {
        unsafe { ptr.read() }
    }
}
```

`unsafe { ... }` 只移除 block 内显式产生的 `unsafe`；其中的 system、failure、mutation 或 handled effect 仍传播。Module 必须以 `requires {unsafe}` 授权 discharge，该许可本身不证明 block 内不变量。

## Effect 传播

Effect 按实际求值组合：

| 表达式 | 结果 effect |
|---|---|
| 字面量、标识符 | `{}` |
| 运算、参数列表、block | 已求值子表达式的 row 合并 |
| 函数调用 | callee row 与 argument-evaluation row 合并 |
| 方法调用 | receiver、method 与 argument row 合并 |
| `if` / `match` | condition 或 scrutinee 与所有 branch row 合并 |
| Closure | body row 存入函数类型；创建 closure 本身为 pure |

函数声明没有 `with` 时，以 body 推断出的 row 为准。显式封闭 row 漏掉实际 effect 时编译失败。

### Effectful function value

普通 closure 不捕获定义点当前安装的 handled-effect evidence。Body row 冻结在函数类型中，每次调用从调用点当前 dynamic handler environment 取得 typed evidence。没有对应 handler 时，effect 继续传播，不能因为 closure 在某个 `handle` 内创建而提前消除。

因此 pure factory 可以返回 effectful closure：调用 factory 不产生该 body effect，调用返回值时才产生。Closure 在 handler 内创建后逃逸，不会延长已经结束的 handler dynamic scope；在新 handler 内调用时使用新的 evidence。

Open effect-row formal 原样转发当前 typed context。实现不能使用 global/TLS root handler、runtime name lookup、closure capture 的隐式 handler 或另一套 function-value ABI 改变该语义。

## Effect 消除

### `catch`

`catch` 捕获左侧计算的 `fail<E>`，并用 match-arm 语法处理 payload：

```vorton
let value = risky() catch {
    Missing(name) => default_for(name),
    Invalid(message) => repair(message),
};
```

Arms 对 `E` 做穷尽性检查；部分处理必须在 arm 中显式重新 raise。被捕获计算的 failure 被消除，arm 新产生的 effect 向外传播。`try` 是保留关键字，不是错误处理语法。

### `handle ... with`

```vorton
let result = handle {
    Logger.log("hello");
    42
} with {
    Logger.log(message) => record(message),
};
```

Handler 在 body 的 dynamic call scope 内提供 handled-effect operations。被完整处理的 exact handled effect 从 body row 中消除；open tail 的未知 effect 与 arm 新产生的 effect 继续传播。System effect、`mut<T>` 与 `unsafe` 不能由 `handle` 删除。

Canonical 0.1 使用 whole-effect complete handler：同一个 `handle...with` 只要为某个 exact effect 写出一个 operation arm，就必须覆盖该 effect 声明的全部 operations，各恰好一次。Source arm 顺序任意；missing、duplicate、unknown 或 cross-owner arm 都是编译错误。需要只拦截部分 operation 时，必须拆分 effect 或为其余 operation 写显式 forwarding arm。

## Handler 语义

非-abort operation 是 tail-resumptive：arm result 作为 operation return value，原计算随后继续。Arm result 必须兼容 operation return type；返回 `Unit` 的 operation 丢弃 arm value，`Never` 作为 bottom 可用于任意返回位置。Vorton 不支持显式 `resume`、post-resume 或 multi-shot continuation。

`fail.raise(error)` 不恢复原计算。捕获它的 arm 恰好执行一次，arm result 替换整个 `handle` 或 `catch` expression；处理当前 failure 时对应 handler 已失活，再次 raise 逃向外层。

## 高阶 Effect 多态

高阶函数的 callback row 使用开放尾，例如：

```text
transform : (T, (T) -> U / ?ε) -> U / ?ε
```

Callback 的 system、handled、failure、mutation 或 unsafe effect 都通过 `?ε` 传播。高阶函数不能假装 callback 为 pure，也不能把 system effect 转成 handler evidence。

## Drop 边界

用户 `Drop::drop` 的最终推断 effect row 必须为空；`fail`、system effect、handled effect 与逃逸的 `mut<T>` 均禁止。编译器生成的字段递归释放、RC deallocation 与已验证 intrinsic cleanup 不属于用户 effect body。

## Canonical 边界

- Handler 只支持 tail-resumptive operation 与 abortive failure；
- 不支持显式 post-resume 或 multiple resume；
- System effect 不是语言内 sandbox，只是可推断、可审计的宿主能力摘要；
- Allocation 本身没有独立 effect class；raw allocation operation 仍产生 `unsafe`。
