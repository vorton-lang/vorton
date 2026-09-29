# Vorton 编译器设计

本文件记录编译器与 runtime 的架构和跨层不变量。语言的可观察语法和语义只以 [`lang-spec/`](lang-spec/README.md) 为准；设计公理只以 [`philosophy.md`](philosophy.md) 为准。

## 设计约束

1. **事实只产生一次。** 名称、类型、callee、资源行为各自由信息首次完备的阶段决定，之后以 typed 结构单向传递。
2. **下游不猜测。** 下游不按字符串、叶名称、声明顺序或 span 重建上游事实。
3. **上游不回跑。** 一个阶段完成后，后续阶段不重新执行名称解析或类型推断。
4. **确定。** 相同输入产生相同诊断与相同生成文本。
5. **不支持就明说。** 某个阶段还不支持的构造，报告 `Unsupported` 并指向源码，不当作已检查而放行。
6. **优化不可观测。** 优化不改变求值顺序、effect、panic、资源释放时点或输出。

## 求值顺序

同一表达式内的子表达式按源码从左到右求值：被调函数或 receiver 先于参数，参数、二元运算数、List/tuple/构造字段与字符串插值依次求值。`&&` 与 `||` 短路。生成 C 时先按这个顺序把子表达式存入临时变量，不依赖 C 未规定的求值顺序。

## 编译管线

```text
source → token → AST → 名称解析 → 声明检查 → 类型检查 → C11 → native
```

| 阶段 | 模块 | 职责 |
|---|---|---|
| 词法 | `lexer.rs` | 产生 token 与 span，并为每个 token 记录前面是否有换行 |
| 语法 | `parser.rs` | 按换行规则切分语句，产生 AST；不做名称或类型判断 |
| 名称解析 | `resolver.rs` | 解析纯内存的多库项目，给每个声明、绑定与引用一个包含库归属的精确 identity |
| 声明检查 | `prepare.rs` | 检查 supertrait 目标与 trait、effect alias 的声明图无环 |
| 类型检查 | `checker.rs` | 局部双向推断：签名给出参数与返回类型，函数体内推断；产出带类型的程序 |
| 代码生成 | `codegen.rs` | 把带类型的程序展开成使用临时变量的 C11 代码，并插入字符串的引用计数操作 |
| 构建 | `native.rs` | 调用系统 C 编译器生成可执行文件 |

每个诊断保留 `OriginRef`：库、库内 source 与 UTF-8 字节范围，让诊断回到唯一输入位置。

名称解析不读取文件系统。它消费宿主给出的 entry 库、唯一 core 库和显式依赖图；每个可达的非 core 库必须直接依赖 core。命令行工具把单个源文件作为 entry 库，把随编译器分发的 `core/root.vorton` 作为 core 库。

### 当前支持范围

类型检查与代码生成按 Milestone 扩展。Milestone 1 支持 `Int`、`Float`、`Bool`、`Str`、`Unit`、函数、`let`/`let mut`、赋值、`if`、`while`、`loop`、`break`、`continue`、`return`、字符串插值，以及 `print`、`assert`、`panic`。其他构造都报告 `Unsupported`。

Milestone 2 引入值类型（struct、enum、tuple、`List`、`Map`）后，会在类型检查与 C 生成之间加入一层中间表示，在那里按“最后一次使用即移交”插入引用计数操作，使唯一持有的值可以原地修改。

## Runtime

Runtime 是 [`runtime/vorton_runtime.c`](../runtime/vorton_runtime.c)，编译器把它放在每个生成的翻译单元开头，所以每个程序都是单个 C 文件。

- `Str` 是不可变的 UTF-8 字节串，带引用计数。字符串字面量是静态对象，引用计数为负，从不计数或释放。
- 生成代码的约定：局部变量与临时变量各自持有一个计数；只读参数不持有；作用域结束、`break`、`continue` 或 `return` 时释放本作用域持有的字符串。
- `Int` 运算用 `__builtin_*_overflow` 检查溢出，除零与 `INT64_MIN / -1` 显式检查，因此需要 clang 或 gcc。
- `Float` 的文本形式按规范实现：用 `%.*e` 从 1 位到 17 位寻找能读回原值的最短表示，再按 ECMAScript 规则排版。
- panic 向标准错误输出 `panic: <信息>`，以退出码 101 结束。规范不规定这段文字和退出码。
- 定义 `VT_CHECK_LEAKS` 编译时，runtime 统计存活的堆字符串；程序正常结束时若不为零，就报告并以退出码 102 结束。测试总是这样编译。

C 编译参数固定为 `-std=c11 -O2 -ffp-contract=off -fno-fast-math`，保证 binary64 运算不被合并成 FMA 或改写。

## 命令行与测试

- `vorton run <file>`：编译并运行；`vorton build <file> [-o <output>]`：生成可执行文件；`vorton c <file>`：输出生成的 C。
- C 编译器取 `VORTON_CC`，否则依次尝试 `clang`、`gcc`、`cc`。
- `cargo test` 除了编译器自身的测试，还运行仓库根目录 [`tests/run/`](../tests/run) 下的每个程序：`<name>.expected` 是期望的标准输出，`<name>.panic` 是期望的 panic 信息。这些程序大多移植自旧版本的测试语料。
