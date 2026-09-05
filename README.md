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

根 workspace 固定使用 Rust `1.98.0`。Compiler library 提供保持独立的两个入口：`vorton_compiler::parse(&str)` 返回完整 surface AST 或结构化 frontend diagnostic；`vorton_compiler::resolve_project(&ProjectSources)` 对纯内存逻辑模块树返回 owned opaque `ResolvedProject` 或带 source key 与 UTF-8 byte span 的结构化 `ProjectDiagnostic`。运行完整本地 gate；把 whitespace 命令中的两个占位符展开为真实的 PR base 与 exact candidate 40-hex SHA：

```powershell
python .agents/scripts/validate_current_tree.py
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
git diff --check <PR base SHA>...<exact candidate SHA>
```

Governance CI 在 Ubuntu 上执行同一组命令；PR whitespace gate 检查 `pull_request.base.sha...pull_request.head.sha`，main push 检查 `before..after`。结构 gate、格式、lint、直接 frontend 行为测试与 committed-diff whitespace 检查共同约束当前 candidate。

## 参与工作

- [GitHub Milestones](https://github.com/vorton-lang/vorton/milestones) 保存持久目标与目标顺序。
- [GitHub Issues](https://github.com/vorton-lang/vorton/issues) 保存当前工作；阶段采用的原生正文修订是 immutable execution contract。
- 所有仓库任务使用 [三阶段 task pipeline](.agents/skills/task-pipeline/SKILL.md)。
- 模板、标签与 [Ideas Discussion #1](https://github.com/vorton-lang/vorton/discussions/1) 的入口见 [GitHub 工作入口](docs/workflow.md)。
- 完成历史只查 PR 与 Git；不建立本地 roadmap 或 backlog。

## 文档

- [语言规范](docs/lang-spec/README.md)：Vorton 当前公开语法与语义
- [设计哲学](docs/philosophy.md)：语言公理与仲裁层级
- [编译器与 runtime 设计](docs/design.md)：目标架构和不变量
- [Agent 入口](AGENTS.md)：项目事实、authority 与用户保留边界
