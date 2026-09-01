# Vorton 语言规范

状态：当前公开语言子集；编译器正在 Rust 宿主上重建

本规范是 Vorton 编程语言的权威参考，独立于任何具体编译器实现。

当前实现路线先闭合 Rust `source → token → AST → diagnostic` 纵切，再按 GitHub Issue 推进其余阶段。迁移前的 Vorton/C11 compiler、tracked C、runtime 与 E2E/golden 测试只作语义 oracle 和已知缺陷复现，不是当前 Rust compiler 的实现、CI、bootstrap 或发布 authority。

## 文档结构

| 文档 | 内容 |
|------|------|
| [词法结构](lexical.md) | Token、关键字、字面量、注释、空白规则 |
| [语法](syntax.md) | 所有语言构造的 EBNF 形式文法 |
| [类型系统](type-system.md) | 原始/复合类型、HM 推断、unification、泛化 |
| [Effect 系统](effects.md) | Effect 声明、row types、传播、handling |
| [Trait 系统](traits.md) | Trait 声明、impl 块、约束、关联类型与 dispatch 语义 |
| [模式匹配](patterns.md) | 模式形式、绑定规则、穷尽性检查 |
| [模块系统](modules.md) | 基于文件的模块、导入、可见性与依赖语义 |
| [标准库](stdlib.md) | 内置类型、函数和方法 |

## 记号约定

- `monospace` 表示关键字、标识符或代码片段
- EBNF 使用 `::=` 定义产生式，`|` 表示选择，`?` 表示可选，`*` 表示零或多个，`+` 表示一或多个
- `⟨name⟩` 表示元变量（实际构造的占位符）
- 类型规则使用标准推导记法：前提在横线上方，结论在下方
- `Γ` 表示类型环境，`⊢` 表示类型判断，`/` 分隔类型和 effect row
- `τ`、`σ`、`ρ` 表示类型；`ε` 表示 effect row；`α`、`β` 表示类型变量

## 版本说明

本规范仅涵盖已经确认的公开语言子集。架构见[`../design.md`](../design.md)；尚未实现的设想不自动成为本规范的一部分。当前实现覆盖与验收由 GitHub Issue 及进入 Rust compiler 后建立的真实 gate 表达；迁移前 E2E/golden 只提供 oracle，不得冒充当前实现通过。
