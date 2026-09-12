# Vorton

Vorton 是一门面向 native 应用开发的编程语言，也是其编译器与仓库的统一名称。源码保持接近 Python 的低标注体验，编译器负责推断类型、effect、trait 约束与资源行为，并把无法证明的边界显式暴露出来。这里的“接近 Python”只指低标注体验；换行和缩进不参与语法。

当前 compiler 以 Rust 为宿主，`crates/vorton-compiler` 是唯一实现 authority；持久目标与顺序见 [GitHub Milestones](https://github.com/vorton-lang/vorton/milestones)，当前可执行工作见 [GitHub Issues](https://github.com/vorton-lang/vorton/issues)，阶段采用的 Issue 原生正文修订是 immutable execution contract。只有 current tree 中实际存在的规范、治理入口和实现属于当前 authority；Git 历史只保存历史。

## Vorton 语言一瞥

```vorton
enum Shape {
    Circle(Float),
    Rect(Float, Float),
}

fn area(shape: Shape) -> Float {
    match shape {
        Shape::Circle(r) => 3.14159 * r * r,
        Shape::Rect(w, h) => w * h,
    }
}

fn sample() -> Float {
    area(Shape::Rect(3.0, 4.0))
}
```

Effect 也参与推断，并可由词法 handler 替换：

```vorton
effect Greeting {
    fn word() -> Str;
}

fn greet() -> Str with {Greeting} {
    "${Greeting.word()}, Vorton"
}

fn message() -> Str {
    handle { greet() } with {
        Greeting.word() => "hello",
    }
}
```

## 当前构建与 CI

根 workspace 固定使用 Rust `1.98.0`。Compiler library 提供五个保持分层的入口：`vorton_compiler::parse(&str)` 返回完整 surface AST 或结构化 frontend diagnostic；`vorton_compiler::resolve_project(&ProjectSources)` 验证并解析显式纯内存库 DAG 及宿主指定的唯一官方 core，返回统一的 owned opaque `ResolvedProject`；`vorton_compiler::prepare_project(ResolvedProject)` 检查 supertrait 目标类别、trait inheritance cycle 与 effect alias cycle，返回 owned opaque `PreparedProject`；`vorton_compiler::decode_contract(&[u8])` 按 [contract format 1](docs/contract-format.md) 读取一份纯内存 JSON 输入，返回 owned opaque `ContractDocument` 或结构化 `ContractDiagnostic`；`vorton_compiler::check_project(&ProjectSources, &BTreeMap<String, LibraryId>, Vec<ContractDocument>)` 将真实项目与选定契约一起闭合为 owned opaque `CheckedProject`。契约读取成功只证明版本、读取 profile 与记录结构成立；owner／引用绑定、受支持 `set` 的一致性和函数体检查只在 `check_project` 中发生。项目阶段失败仍以原有 `ProjectDiagnosticKind` 和真实 origin 包在 `CheckDiagnostic` 中；`parse` 的签名与单 source 行为不依赖项目或契约输入。

```rust
use std::collections::BTreeMap;
use vorton_compiler::{
    LibraryId, LibrarySources, ProjectSources, prepare_project, resolve_project,
};

let app = LibraryId(0);
let model = LibraryId(1);
let core = LibraryId(2);
let core_source = std::fs::read_to_string("core/root.vorton").expect("bundled core source");
let sources = ProjectSources {
    entry: app,
    core,
    libraries: BTreeMap::from([
        (
            app,
            LibrarySources {
                root: "use model::Number; fn run(value: Number) -> Int { value }".to_owned(),
                modules: BTreeMap::new(),
                dependencies: BTreeMap::from([
                    ("model".to_owned(), model),
                    ("foundation".to_owned(), core),
                ]),
            },
        ),
        (
            model,
            LibrarySources {
                root: "pub type Number = Int;".to_owned(),
                modules: BTreeMap::new(),
                dependencies: BTreeMap::from([("runtime".to_owned(), core)]),
            },
        ),
        (
            core,
            LibrarySources {
                root: core_source,
                modules: BTreeMap::new(),
                dependencies: BTreeMap::new(),
            },
        ),
    ]),
};
let resolved = resolve_project(&sources).expect("project resolves");
let prepared = prepare_project(resolved).expect("declaration graphs are valid");
```

契约内容由宿主读取并直接作为字节传入；reader 不读取文件名、cwd、环境或网络：

```rust
use vorton_compiler::{check_project, decode_contract};

let contract_bytes = br#"{
  "format": "vorton.contract",
  "format_version": 1,
  "semantics_version": "0.1",
  "owner": "app",
  "records": []
}"#;
let contract = decode_contract(contract_bytes).expect("contract structure is readable");
let checked = check_project(
    &sources,
    &BTreeMap::from([("app".to_owned(), app)]),
    vec![contract],
)
.expect("the selected narrow source and contract subset checks together");
```

`LibraryId` 只区分本次输入中的库实例；依赖别名由每个 `LibrarySources` 明确给出。宿主读取仓库唯一的 [`core/root.vorton`](core/root.vorton)，把它作为 `core` 对应库的真实 root source 传入；每个可达非 core 库都必须以自己选择的别名直接依赖该 ID。Resolver 不读取磁盘，也不按别名或 ID 数值猜测 core。`PreparedProject` 完整保留名称层结果，并只额外证明 supertrait 指向真实 named trait、trait inheritance graph 与 effect alias declaration graph 无环。

当前 `check_project` 支持普通 module／inline-module 纯函数的受限 HM 推断，包括函数泛型、内部参数与返回类型推断、函数泛化、递归组和逐调用实例化；普通局部 `let` 保持 monotype。类型限于 `Int`、`Float`、`Bool`、`Unit`、`Never`、函数 formal、由它们组成的 tuple，以及受支持的非泛型 alias。它核对双边泛型 contract、Borrow/Move mode、空 effect 上界和空 generic requirements，并检查泛型值的借用与整值移交；需要泛型清理、部分移动或非空 requirement/effect 等超出支持面的用法返回 `CheckDiagnosticKind::Unsupported`。完整边界见[当前 Checker API 支持说明](docs/lang-spec/type-system.md#当前-checker-api-支持边界)。

`CheckedProject` 保留已闭合的 scheme、typed body、调用 mapping，以及真实形成的类型、字面量值、callee、mode 和纯 effect，但不公开内部 ID 或通用查询面，也不代表完整接口、完整 Checker 或最终 TypedHIR。运行完整本地 gate；把 whitespace 命令中的两个占位符展开为真实的 PR base 与 exact candidate 40-hex SHA：

```powershell
python .agents/scripts/validate_current_tree.py
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
git diff --check <PR base SHA>...<exact candidate SHA>
```

Governance CI 在 Ubuntu 上执行同一组命令；PR whitespace gate 检查 `pull_request.base.sha...pull_request.head.sha`，main push 检查 `before..after`。结构 gate、格式、lint、直接 compiler library 行为测试与 committed-diff whitespace 检查共同约束当前 candidate。

## 参与工作

- [GitHub Milestones](https://github.com/vorton-lang/vorton/milestones) 保存持久目标与目标顺序。
- [GitHub Issues](https://github.com/vorton-lang/vorton/issues) 保存当前工作；阶段采用的原生正文修订是 immutable execution contract。
- 所有仓库任务使用 [三阶段 task pipeline](.agents/skills/task-pipeline/SKILL.md)。
- 模板、标签与 [Ideas Discussion #1](https://github.com/vorton-lang/vorton/discussions/1) 的入口见 [GitHub 工作入口](docs/workflow.md)。
- 完成历史只查 PR 与 Git；不建立本地 roadmap 或 backlog。

## 文档

- [语言规范](docs/lang-spec/README.md)：Vorton 当前公开语法与语义
- [契约输入格式](docs/contract-format.md)：纯内存 contract format 1 与额外 wire profile
- [设计哲学](docs/philosophy.md)：语言公理与仲裁层级
- [编译器与 runtime 设计](docs/design.md)：目标架构和不变量
- [Agent 入口](AGENTS.md)：项目事实、authority 与用户保留边界
