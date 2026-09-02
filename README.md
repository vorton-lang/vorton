# Vorton

Vorton 是一门面向 native 应用开发的编程语言，也是其编译器与仓库的统一名称。源码保持接近 Python 的低标注体验，编译器负责推断类型、effect、trait 约束与资源行为，并把无法证明的边界显式暴露出来。

仓库已经迁移到 [`vorton-lang/vorton`](https://github.com/vorton-lang/vorton)。当前工程路线是在 Rust 宿主上重建 Vorton 编译器；首个实现纵切由 [Issue #3](https://github.com/vorton-lang/vorton/issues/3) 跟踪。迁仓前的 C11 compiler、tracked C、runtime 与语义输入随完整 Git 历史保留，只作迁移蓝本、语义 oracle 和已知缺陷复现，不是当前 build、bootstrap、CI 或发布门。

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

Rust compiler workspace 尚未进入仓库，因此当前没有可声明为 Vorton compiler authority 的本地构建命令。当前 CI 只运行两个零第三方依赖的仓库 validator：

```powershell
python .agents/scripts/validate_naming.py
python .agents/scripts/validate_workflow.py
```

它们验证 tracked tree 的技术命名 clean break，以及 task pipeline、GitHub 模板、标签入口和 CI 自身的一致性；它们不宣称迁移 oracle 或未来 Rust compiler 已通过。

## 参与工作

- [GitHub Issues](https://github.com/vorton-lang/vorton/issues) 是活动范围、状态与验收的唯一真值。
- 所有仓库任务使用 [三阶段 task pipeline](.agents/skills/task-pipeline/SKILL.md)。
- 模板、标签与 [Ideas Discussion #1](https://github.com/vorton-lang/vorton/discussions/1) 的入口见 [GitHub 工作入口](docs/workflow.md)。
- 完成历史只查 PR 与 Git；迁仓前 Markdown 看板保持删除。

## 文档

- [语言规范](docs/lang-spec/README.md)：Vorton 当前公开语法与语义
- [设计哲学](docs/philosophy.md)：语言公理与仲裁层级
- [编译器与 runtime 设计](docs/design.md)：目标架构和不变量
- [竞品与行业定位](docs/competitive-analysis.md)：有事实截止日期的比较基线
- [Agent 入口](AGENTS.md)：项目事实、authority 与用户保留边界
