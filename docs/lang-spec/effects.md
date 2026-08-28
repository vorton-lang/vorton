# Effect 系统

Ring 用 effect row 描述计算可能发生的副作用。函数声明通常省略 effect 标注并由编译器推断；显式 `with { ... }` 是约束和文档，不改变函数体的实际语义。

## Effect 分类与消除权

Effect row 中的 atom 共享组合与推断机制，但并不共享同一种运行时解释或消除规则：

| 分类 | 0.1 实例 | 唯一消除/执行规则 |
|------|----------|-------------------|
| System effect | `console`、`fs`、`process` | 不可 `handle`，不进入 evidence；以 AbiIR HostImport 交给目标 host provider |
| Handled effect | 用户 `effect` 声明 | 进入 typed evidence，必须由显式 `handle...with` 消除 |
| Failure | `fail<E>` | 由 `catch` 或显式 failure handler 消除 |
| Mutation marker | `mut<T>` | 只由局部性/状态作用域规则消除 |
| Unsafe obligation | `unsafe` | 只由词法 `unsafe { ... }` discharge |

该分类在 TypedHIR effect freeze 前固定。System effect 绝不能获得 handler evidence；handled effect 绝不能直接降为 HostImport。`main` 可以保留 system effect，由目标环境直接执行；未消除的用户 handled effect 不得逃出 `main`。

## Effect row closure 与多态

进入CoreHIR前，普通effect推断元变量必须完成求解。一个tail只有在函数scheme中被正式量化时才可保留，并转换为带声明owner与ordinal的稳定effect参数；它表示已确定的多态契约，不是“下游稍后再猜”的未知effect。无法归属正式scheme的raw推断tail是编译错误。

因此callable的冻结契约只有两种形态：closed exact atoms，或exact atoms加一个正式effect参数。Effect alias在此前已递归展开；first-class function value与每个调用点保留同一正式参数及exact实例化关系。CoreHIR、FlowIR、ResourcePlanner、AbiIR与后端均不得重新运行effect inference、按函数名恢复row，或把正式effect参数静默当成空row。System effect实例化仍不产生evidence；handled effect实例化必须与ordered typed evidence一致。

递归 callable 的effect formal按类型系统的递归绑定组规则产生。组内 peer/self 使用共享 provisional row，不在首个引用处实例化或分配正式身份；整组约束求解后，才为最终量化tail生成 canonical `EffectParamRef`、发布 source-formal→actual 关系并原子写回全组header。Top-level、inline module与impl method使用同一协议。禁止premint、first-use/body scan、executable-stack可见性、importer remint或post-SCC HIR patch恢复identity。

递归组body只做一次effect inference；其raw effect row随内部draft等待整组求解，随后恰好一次final-zonk、evidence canonicalization与header publication。每个scheme/callable实例的effect actual必须来自该实例唯一的full mapping receipt，并与type actual、dictionary/evidence共用；禁止按已zonk类型再次结构匹配重建effect或dictionary替换。

## System effects 与 HostImport

0.1 只定义当前真实 API 所需的三类 system effect：

| Effect | 语义范围 |
|--------|----------|
| `console` | 标准输出与标准错误输出 |
| `fs` | 文件系统访问及依赖 cwd/filesystem 的路径解析 |
| `process` | 参数、工作目录、同步子进程与进程退出 |

纯路径字符串运算不产生 `fs`。没有真实 API 时不预先声明 `net`、`clock`、`random` 等未来能力。

System effect 是静态能力事实，不是语言内动态 provider：

1. host extern/intrinsic 声明必须携带 exact system effect 与正交的 `fail<E>` 契约；
2. ResolvedAST/TypedHIR 以 exact `SymbolRef` / `CalleeRef` 保存 operation identity；
3. CoreHIR/FlowIR/RcIR 不生成或传递 system evidence；
4. AbiIR 把调用固化为带 ABI symbol、参数、返回与 failure contract 的 HostImport；
5. native C 链接 runtime symbol，未来 WASM 使用 imports，嵌入式可链接 host provider。任何 target 都不得在 `main` 注入 root handler或按叶名猜操作。

需要可替换/可 mock 的依赖时，定义用户 handled effect，并以普通显式 handler adapter 翻译到 system API：

```ring
effect FileAccess {
    fn read(path: Str) -> Str
}

fn load(path: Str) -> Config with {FileAccess} {
    parse(FileAccess.read(path))
}

fn load_from_os(path: Str) -> Config with {fs, fail<FsError>} {
    handle {
        load(path)
    } with {
        FileAccess.read(p) => fs::read_file(p),
    }
}
```

测试可给 `FileAccess` 提供纯 handler；直接 `fs` 调用本身不可被 `handle`。这使抽象依赖与真实宿主权限保持分域。

## 用户自定义 Effect

```ring
effect Logger {
    fn log(msg: Str) -> Unit;
}

fn write_log(msg: Str) -> Unit with {Logger} {
    Logger.log(msg)
}
```

操作签名规定参数、返回类型和调用时产生的 handled effect。操作通过 `EffectName.operation(...)` 调用。

### 0.1 无 default operation body

用户 effect operation 在 0.1 只有签名，不允许 body。Custom effect 必须由显式 `handle...with` 提供解释；不存在自动 default evidence、部分默认、默认 body 依赖图或 codegen fallback。

Default provider 有真实的建模与人体工学价值，post-0.1 由 B-197 结合实际 consumer 重新比较 op body、显式具名 provider 与普通 wrapper。不得直接恢复 0.1 前的 checker hydration、全局 evidence init 或默认依赖拓扑实现。

### Effect alias

`effect alias` 给一组 effect 命名：

```ring
effect alias HostIO = {console, fs, process}
effect alias Fallible<E> = {fail<E>}
```

Alias 可泛型化、可 `pub` 导出，并在类型检查前递归展开；循环 alias 被拒绝。展开后的 exact atoms 才参与 identity、capability、inspection 与 ABI，alias 本身不制造 evidence或新的运行时 effect。

## `mut<T>` Marker Effect

`mut<T>` 是当前 mutation 可见性机制的一部分，并保留在 effect row 中。

- 修改函数自己的局部 `let mut` 绑定不会让 `mut` 逃逸到函数签名；
- 通过 `mut` 参数修改调用方状态，或修改闭包捕获的外部可变状态，会注入相应的 `mut<T>`；
- 调用要求可变 receiver 的方法仍需可变绑定；effect 不替代这项检查；
- `mod requires { ... }` 会检查逃逸的 `mut<T>`，因此 `requires {}` 的纯模块不能修改外部状态。

`mut<T>` 是多实例 marker。同一 row 可以同时包含 `mut<Int>` 与 `mut<Str>`，它们不得因为都叫 `mut` 而合并。裸标注 `with {mut}` 每次实例化时引入 fresh 状态类型。

## `unsafe` Effect

`unsafe` 标记编译器不能验证其内存安全前提的操作。它进入函数签名并向调用方传播，但不能由普通 `handle` 或 `catch` 消除；唯一 discharge 形式是词法 `unsafe { ... }` block。

```ring
mod raw_buffer requires {unsafe} {
    fn first(ptr: Ptr<Int>) -> Int {
        unsafe { ptr.read() }
    }
}
```

`unsafe { ... }` 只移除 block 内显式产生的 `unsafe`；其中的 system、failure、mutation 或 handled effect 仍传播。模块必须以 `requires {unsafe}` 授权 discharge，该许可本身不证明 block 内不变量。预加载raw pointer操作见[标准库](stdlib.md#ptrt-与-unsafe-原语)。

## Effect Row

```text
EffectRow = { e₁, e₂, ..., eₙ }          // 封闭 row
EffectRow = { e₁, e₂, ..., eₙ, ..α }     // 开放 row
```

- 封闭 row 恰好包含列出的 effect；
- 开放 row 至少包含列出的 effect，其余由尾变量 `α` 捕获；
- `{}` 表示纯计算。

规范中的函数类型可写成 `(T₁, ..., Tₙ) -> R / ε`。源码函数类型用 `fn(T₁, ..., Tₙ) -> R with { ... }` 表示显式 row；省略 `with` 时可保留开放尾以支持 effect 多态。

### Identity 与合并

合并两个 row 时：

1. system effect 按 exact capability identity 去重；`fs`、`console`、`process` 互不相等；
2. `unsafe` 与 `unsafe` 是同一实例；
3. `fail<T>` 与 `fail<U>` 匹配时统一 payload 类型；
4. 同一 exact handled effect 只对应一份 evidence，其类型参数必须统一；
5. `mut<T>` 按完整状态类型区分，可在同一 row 保留多个实例；
6. 未匹配 effect 只能进入开放尾；封闭侧不接受额外 effect。

不同开放尾都带未匹配项时，row unification 创建共享 fresh 尾并分别保留对侧未匹配项。Effect class 不因 row 合并、alias 展开或 module import而改变。

## Effect 传播

Effect 按求值组合：

| 表达式 | 结果 effect |
|--------|-------------|
| 字面量、标识符 | `{}` |
| 运算、参数列表、block | 已求值子表达式的 row 合并 |
| 函数调用 | callee row 与参数求值 row 合并 |
| 方法调用 | receiver、方法和参数 row 合并 |
| `if` / `match` | 条件或 scrutinee 与所有分支 row 合并 |
| Lambda | body row 存入函数类型；创建 lambda 本身是纯的 |

函数声明没有 `with` 时，以函数体推断出的 row 为准。显式封闭 row 漏掉实际 effect 时编译失败。Host operation 不得因为是 `extern`、runtime bridge 或 builtin 而省略 system effect。

### Effectful function value 的 evidence

普通 lambda/closure 不捕获定义点当前安装的 handled-effect evidence。其 body row 冻结在函数类型中；所有Ring callable统一接收一个显式borrowed `EffectCtx*`，每次调用从调用点当前 dynamic handler environment传入。没有对应typed handler entry时，effect继续传播到调用者，不能因为closure在某个`handle`内创建而被提前消除。

因此，一个pure factory可以返回effectful closure：调用factory不需要该effect，调用返回值时才需要。closure在`handle`内创建后逃逸，也不会延长旧handler的动态范围；在新的handler内调用时使用新handler。Handler arm/re-perform的内部runtime对象可显式持有outer evidence，但不改变ordinary user closure规则。

Indirect closure ABI依次传递`env`、普通参数、trait dictionaries、`EffectCtx*`；direct/method调用省略`env`但保持其余相对顺序。Pure与system-only Ring callable传immortal empty context。普通用户top-level extern与不会回调Ring callable的普通HostImport leaf不接收context；exact compiler-owned runtime intrinsic只要会调用Ring callable，就必须显式接收并转发context。0.1当前穷尽集合为`ring_list_sort_bridge`/`ring_list_sort`、`Option.map`、`Option.and_then`、`Option.unwrap_or_else`与`Cell.update`：sort和Option三项转发current context，pure `Cell.update` callback接收immortal empty context。调用同步完成，leaf不保存或retain context；集合由exact compiler intrinsic identity裁决，禁止名字猜测、thunk或通用adapter，也不新增用户extern callback能力。Context entry由完整typed handled instance（exact effect identity + exact type arguments）索引，不能按名字或nominal leaf合并；`GenericProbe<Str>`与`GenericProbe<Int>`是两个不同entry。

`handle`创建owned child overlay并引用parent context；ordinary calls只borrow并转发指针，returned closure不捕获。Closed row可用冻结layout的静态位置，open row通过同一个typed context/view转发。禁止C varargs、TLS/global/root handler、runtime name lookup以及closed/open两套function-pointer ABI。Handler arm/re-perform内部对象可显式持parent context，其生命周期不改变ordinary closure规则。

## Effect 消除

### `catch`

`catch` 捕获左侧计算的 `fail<E>`，并用 match-arm 语法处理 payload：

```ring
let value = risky() catch {
    Missing(name) => default_for(name),
    Invalid(msg) => repair(msg),
}
```

Arms 对 `E` 做穷尽性检查，未覆盖时报 E0601；部分处理必须在 arm 中显式重新 `fail.raise`。被捕获计算的 failure 被消除，arm 新产生的 effect 向外传播。`try` 是保留关键字，不是错误处理语法。

### `handle ... with`

```ring
let result = handle {
    Logger.log("hello")
    42
} with {
    Logger.log(msg) => print(msg),
}
```

Handler 在其body的动态调用范围内提供 handled-effect operations。被显式处理的 exact handled effect 从 body row 中消除；开放尾未知 effect 与 handler arm 新产生的 effect继续传播。System effect、`mut<T>` 与 `unsafe` 不能由 `handle` 删去。只在该范围内创建但未调用的ordinary closure不会捕获handler；它逃逸后的effect仍由未来调用点处理。

## Handler 语义

非 abort operation 是 tail-resumptive：arm 结果作为 operation 返回值，计算随后继续。Arm 结果必须与 operation return type兼容；返回`Unit`的operation位于语句语义位置，arm值被丢弃，`Never`作为bottom可用于任何返回位置。Ring 不支持显式 `resume`、post-resume 或 multi-shot continuation。

`fail.raise(error)` 不恢复原计算。捕获它的 arm 恰好执行一次，arm 结果替换整个 `handle` / `catch` 表达式；处理当前 failure 时对应 handler 已失活，再次 raise 逃向外层。

## HOF Effect 多态

高阶函数 callback row 使用开放尾，例如：

```text
map : (List<T>, (T) -> U / ?ε) -> List<U> / ?ε
```

Callback 的 system、handled、failure、mutation 或 unsafe effect都通过 `?ε` 传播；HOF 不得假装 callback 纯净，也不得把 system effect转成 handler evidence。精确标准库声明以[`std/*.ring`](../../std/)为准。

## Drop 的 0.1 边界

0.1 用户 `Drop::drop` 的最终推断 effect row 必须为空；`fail`、system effect、handled effect与逃逸的 `mut<T>` 均禁止。编译器生成的字段递归释放、RC deallocation 与已验证 intrinsic cleanup 不属于用户 effect body。

0.1 不建立 `DropEffectSet`、latent destruction carrier 或空占位字段。Post-0.1 只有真实 File/Socket/Transaction 等 consumer出现后，B-198 才比较 effectful Drop、显式 close + pure safety-net Drop等方案；若选择 latent destruction contract，它必须在 TypedHIR effect freeze 前进入函数 effect，不能由 ResourcePlanner、AbiIR或system call静默补入。

## 当前实现迁移边界

B-194/B-195/B-196 完成前，编译器仍存在 user default effect body、宽泛 `Effect::IoEffect`、`io.read/write` 与漏标 system effect 的 std host extern，以及允许 effectful Drop 的旧路径。它们是待原子删除的实现事实，不构成 0.1 终态兼容承诺。

## 当前限制

- Handler 仅支持 tail-resumptive operation 与 abortive failure；
- 不支持 post-resume 或多次 resume；
- Full algebraic effects 不在当前实现范围内；
- System effect 不是语言内 sandbox；它提供可推断、可审计的宿主能力摘要，未来 package policy可消费该摘要，但不会把静态声明冒充 OS 权限隔离。
