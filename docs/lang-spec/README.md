# Vorton 语言规范

本规范是 Vorton 编程语言的权威参考，独立于任何具体编译器实现。字符到 token 只以[词法结构](lexical.md)为准，token 到完整语法结构只以[语法](syntax.md)中的 canonical EBNF 为准；其余页面只解释语义，不复制产生式。

## 文档结构

| 文档 | 内容 |
|------|------|
| [词法结构](lexical.md) | Token、关键字、字面量、注释、空白规则 |
| [语法](syntax.md) | 所有语言构造的 EBNF 形式文法 |
| [类型系统](type-system.md) | 原始/复合类型、HM 推断、unification、泛化 |
| [Effect 系统](effects.md) | Effect 声明、row types、传播、handling |
| [Trait 系统](traits.md) | Trait 声明、impl 块、约束、关联类型与 dispatch 语义 |
| [模式匹配](patterns.md) | 模式形式、绑定规则、穷尽性检查 |
| [模块系统](modules.md) | 纯内存项目、逻辑模块树、导入、可见性与依赖语义 |

## 记号约定

- `monospace` 表示关键字、标识符或代码片段
- EBNF 使用 `::=` 定义产生式，`|` 表示选择，`?` 表示可选，`*` 表示零或多个，`+` 表示一或多个
- `⟨name⟩` 表示元变量（实际构造的占位符）
- 类型规则使用标准推导记法：前提在横线上方，结论在下方
- `Γ` 表示类型环境，`⊢` 表示类型判断，`/` 分隔类型和 effect row
- `τ`、`σ`、`ρ` 表示类型；`ε` 表示 effect row；`α`、`β` 表示类型变量

## 范围

本规范只包含 canonical 0.1 的公开语言规则。Compiler 架构见 [`../design.md`](../design.md)。标准库的模块、类型、函数与方法不在当前语言规范中定义；规范示例中的自由函数或方法名称若未由本规范明确赋予语言语义，只用于展示语法与类型关系，不构成库 API。
