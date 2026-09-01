# Vorton

Vorton 是一门面向 native 应用开发的编程语言，也是其编译器与仓库的统一名称。源码保持接近 Python 的低标注体验，编译器负责推断类型、effect、trait 约束与资源行为，并把无法证明的边界显式暴露出来。

仓库已经迁移到 [`vorton-lang/vorton`](https://github.com/vorton-lang/vorton)。当前工程路线是在 Rust 宿主上重建 Vorton 编译器；首个实现纵切由 [Issue #3](https://github.com/vorton-lang/vorton/issues/3) 跟踪。迁仓前的 C11 compiler、tracked C、runtime 与测试随完整 Git 历史保留，只作迁移蓝本、语义 oracle 和已知缺陷复现，不是当前 build、bootstrap、CI 或发布门。

## Vorton 语言一瞥

```vorton
enum Shape {
    circle(radius: Float),
    rect(width: Float, height: Float),
}

fn area(shape: Shape) -> Float {
    match shape {
        circle(r) => 3.14159 * r * r,
        rect(w, h) => w * h,
    }
}

fn main() {
    let shapes = [circle(2.0), rect(3.0, 4.0)]
    let total = shapes.fold(0.0, fn(sum, shape) { sum + area(shape) })
    print("total = ${total}")
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

fn main() {
    let message = handle { greet() } with {
        Greeting.word() => "hello",
    }
    print(message)
}
```

## 当前构建与 CI

Rust compiler workspace 尚未进入仓库，因此当前没有可声明为 Vorton compiler authority 的本地构建命令。建立 workspace、最小前端纵切与相称测试后，命令和支持平台会随实现一并记录。

当前 CI 只运行两个零第三方依赖的仓库 validator：

```powershell
python .agents/scripts/validate_naming.py
python .agents/scripts/validate_workflow.py
```

它们验证 tracked tree 的技术命名 clean break，以及当前工作流、Issue 模板、历史看板保持删除与 CI 自身的约束；它们不宣称迁移 oracle 或未来 Rust compiler 已通过。

## 参与工作

- [GitHub Issues](https://github.com/vorton-lang/vorton/issues) 是活动范围、状态与验收的唯一真值。
- 每个 Issue 只对应一个 active PR；PR 正文使用 `Closes #N`，merge 后由 GitHub 关闭对应 Issue。
- [Ideas Discussion #1](https://github.com/vorton-lang/vorton/discussions/1) 只接收尚不可执行的 post-0.1 想法与升级条件。
- 完整执行规则见 [Vorton 工作流](docs/workflow.md)。迁仓前 Markdown 看板已从当前树删除，历史只查 Git。

## 文档

- [语言规范](docs/lang-spec/README.md)：Vorton 当前公开语法与语义
- [设计哲学](docs/philosophy.md)：语言公理与仲裁层级
- [编译器与 runtime 设计](docs/design.md)：目标架构和不变量
- [竞品与行业定位](docs/competitive-analysis.md)：有事实截止日期的比较基线
- [Agent 入口](AGENTS.md)：当前技术路线与仓库约定
