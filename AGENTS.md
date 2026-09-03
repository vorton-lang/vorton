# Vorton Agent Entry

## 语言与 authority

- 所有对话回复、解释和讨论使用中文；技术术语、代码和命令可保留英文。
- 当前仓库是 [`vorton-lang/vorton`](https://github.com/vorton-lang/vorton)。[GitHub Milestones](https://github.com/vorton-lang/vorton/milestones) 是持久目标与目标顺序的唯一真值；GitHub Issue 是当前范围、设计、验收与依赖的 immutable execution contract；完成历史只查 PR 与 Git。
- 所有仓库变更、PR verification 与 merge 路由必须完整读取并遵守 [`task-pipeline`](.agents/skills/task-pipeline/SKILL.md)；它是唯一任务 lifecycle authority。
- 语言公理见 [`docs/philosophy.md`](docs/philosophy.md)，稳定设计见 [`docs/design.md`](docs/design.md)，用户规范见 [`docs/lang-spec/`](docs/lang-spec/)。GitHub Milestone、模板和标签入口见 [`docs/workflow.md`](docs/workflow.md)。

## 当前项目事实

- Vorton 当前以 Rust 重建编译器，先闭合 `source → token → AST → diagnostic`，再按 Milestone 目标顺序通过当前 Issue 推进 checker、IR、ownership、C11 后端与 CLI。
- Rust workspace 与真实 compiler build/test gate 由对应实现 Issue 建立；进入仓库前不得声称 Cargo、compiler 或发布门已通过。
- `compiler/*.vorton`、`compiler/dist-c/main.c`、`vorton_runtime.cpp`、`std/` 与 `tests/cases/` 只作迁移蓝本、语义 oracle 和已知缺陷复现，不是当前 bootstrap、CI 或发布 authority。
- 目标管线是 Lexer → Parser → AST → Checker（HM + effects）→ HIR → Core/Flow ResourcePlanner → RcIR → C11 → native。具体阶段与 ABI/ownership 不变量只以稳定设计和语言规范为准。
- Self-host 已后置；只有语言与外部宿主编译器稳定后，经用户新决定才可恢复。

## 用户保留决定

以下事项只由用户拍板：语言公开语义与保证、breaking API/ABI、平台支持、新 P0、重大路线与显著投入、Issue 创建、repository transfer/rename、外部写入、release、历史重写和不可恢复删除。

## Security 边界

本仓库是单人项目。没有当前可复现问题或用户明确需求时，不主动建设或规划 GitHub App、token broker、webhook、权限矩阵、CODEOWNERS、安全 ruleset、签名、供应链扫描、sandbox、secret 基础设施或 untrusted-fork 模型。Compiler crash、wrong-code、UB、数据损坏和 ownership/RC 错误按普通 correctness 处理。
