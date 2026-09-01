# Vorton

Vorton 是 [Ring](docs/lang-spec/README.md) 语言的当前编译器仓库。Ring 面向 native 应用开发：源码保持接近 Python 的低标注体验，编译器负责推断类型、effect、trait 约束与资源行为，并把无法证明的边界显式暴露出来。

仓库已经迁移到 [`vorton-lang/vorton`](https://github.com/vorton-lang/vorton)。当前工程路线是在 Rust 宿主上重建编译器；首个实现纵切由 [Issue #3](https://github.com/vorton-lang/vorton/issues/3) 跟踪。仓库中的旧 Ring/C11 compiler、tracked C、runtime 与测试随历史保留，只作迁移蓝本、语义 oracle 和已知缺陷复现，不是当前 build、bootstrap、CI 或发布门。

## Ring 语言一瞥

```ring
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

```ring
effect Greeting {
    fn word() -> Str;
}

fn greet() -> Str with {Greeting} {
    "${Greeting.word()}, Ring"
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

当前 CI 只运行零第三方依赖的仓库治理 validator：

```powershell
python .agents/scripts/validate_workflow.py
```

它验证当前工作流、Issue 模板、冻结历史文档与 CI 自身的约束；它不宣称旧 compiler 或未来 Rust compiler 已通过。

## 参与工作

- [GitHub Issues](https://github.com/vorton-lang/vorton/issues) 是活动范围、状态与验收的唯一真值。
- 每个 Issue 只对应一个 active PR；PR 正文使用 `Closes #N`，merge 后由 GitHub 关闭对应 Issue。
- [Ideas Discussion #1](https://github.com/vorton-lang/vorton/discussions/1) 只接收尚不可执行的 post-0.1 想法与升级条件。
- 完整执行规则见 [Vorton 工作流](docs/workflow.md)。`docs/backlog.md` 与 `docs/audit-report.md` 已冻结，仅供历史检索。

## 文档

- [语言规范](docs/lang-spec/README.md)：Ring 当前公开语法与语义
- [设计哲学](docs/philosophy.md)：语言公理与仲裁层级
- [编译器与 runtime 设计](docs/design.md)：目标架构和不变量
- [竞品与行业定位](docs/competitive-analysis.md)：有事实截止日期的比较基线
- [Agent 入口](AGENTS.md)：当前技术路线与仓库约定
