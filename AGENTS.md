# Vorton Agent 入口

- 对话与解释用中文；术语、代码、命令保留英文。
- 仓库是 [`vorton-lang/vorton`](https://github.com/vorton-lang/vorton)。编译器用 Rust 1.98.1 编写，唯一实现是 `crates/vorton-compiler`。Self-host 不在目标内。
- 仲裁顺序：[`docs/philosophy.md`](docs/philosophy.md) > [`docs/lang-spec/`](docs/lang-spec/README.md) > [`docs/design.md`](docs/design.md) > 代码。后三者正在向 2026-09-29 的新哲学对齐；发现冲突时以哲学为准，并报告冲突。
- Git 历史只是历史，不是当前规范，也不是验证证据。

## 角色

- **用户**：项目所有者，只决定下面列出的宏观事项。
- **维护者**：仓库的唯一写入者，按 [`MAINTAINING.md`](MAINTAINING.md) 工作。
- **外包**：由维护者派发的 agent。只做派发内容写明的事；不 commit、不 push、不写 GitHub、不删文件。顺手看到的其他问题可以报告，但不修。
- **审计**：由用户运行的外部 agent，按 [`AUDITING.md`](AUDITING.md) 工作。只读仓库，发现的问题挂成 `type:audit` Issue。

## 只由用户决定

- 设计哲学、语言公开语义与保证
- Milestone 的目标与顺序、0.1 范围、平台支持
- 新增外部依赖或工具链、删除整个子系统
- 治理本身：本文件、`MAINTAINING.md` 与 `AUDITING.md`
- 推送 `main` 以外的 GitHub 写入（Issue、Milestone、release、仓库设置）、改写历史、不可恢复的删除。例外：审计按 `AUDITING.md` 开 Issue；维护者开 bug Issue、在 Issue 下评论、用修复 commit 关闭 Issue。

## 检查

提交前以下三项全部通过；CI 运行同样三项。

```text
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
```
