# Vorton

Vorton 是一门面向 native 应用开发的编程语言，也是其编译器与仓库的统一名称。源码保持接近 Python 的低标注体验，编译器负责推断类型、effect、trait 约束与资源行为，并把无法证明的边界显式暴露出来。这里的“接近 Python”只指低标注体验；换行和缩进不参与语法。

当前 compiler 以 Rust 为宿主，`crates/vorton-compiler` 是唯一实现；目标与顺序见 [GitHub Milestones](https://github.com/vorton-lang/vorton/milestones)。

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

## 当前状态

正在按 [Milestone](https://github.com/vorton-lang/vorton/milestones) 重建：每个 Milestone 结束时，都有一批新程序能从源码编译成 native 并运行。当前 Rust workspace 固定使用 Rust `1.98.1`，`crates/vorton-compiler` 提供三个入口：`parse` 把单个源文件解析成 AST，`resolve_project` 解析纯内存的多库项目并完成名称解析，`prepare_project` 检查 trait 继承与 effect alias 无环。类型检查、代码生成与 runtime 正在按 Milestone 1 重建。

本地检查与 CI 运行同样三项：

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
```

## 参与工作

角色、用户保留事项与维护方式见 [`AGENTS.md`](AGENTS.md) 和 [`MAINTAINING.md`](MAINTAINING.md)。

## 文档

- [语言规范](docs/lang-spec/README.md)：Vorton 公开语法与语义（正在按新哲学重写）
- [设计哲学](docs/philosophy.md)：语言公理与仲裁层级
- [编译器与 runtime 设计](docs/design.md)：目标架构和不变量
- [Agent 入口](AGENTS.md)：角色、仲裁顺序与用户保留事项
- [维护手册](MAINTAINING.md)：日常工作、记录、汇报与外包派发
