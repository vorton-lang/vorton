# 词法结构

## 注释

```
LineComment  ::= '//' ⟨除换行外的任意字符⟩* ⟨换行 | EOF⟩
```

Ring 仅使用 `//` 行注释，无块注释。

## 空白

空白字符（空格、制表符、换行、回车）用于分隔 token，其他情况下无语义意义。一个例外：

**函数调用同行规则：** `(` token 仅在与前一个表达式同行时，才被解析为调用表达式的后缀。这消除了以下歧义：

```ring
foo
(x, y)    // 两个独立表达式：`foo` 和 tuple `(x, y)`

foo(x, y) // 一个表达式：函数调用
```

## 关键字

以下 35 个标识符是保留关键字：

```
fn     let    mut    const   struct  enum    match   impl
effect handle with   if      else    catch   test    return
for    in     pub    where   true    false   trait   try
while  break  continue loop  use     as      extern  mod
super  requires unsafe
```

注意：`type`、`delegate`、`self`、`sig` 不是关键字。`type`、`delegate`、`self` 在特定上下文中由 Parser 特殊解析；0.1 没有 `sig` 声明，因此 `sig` 是普通标识符。Post-0.1 若重新设计完整 module signature conformance，必须选择不破坏 0.1 标识符的 contextual/versioned syntax。`try` 是保留关键字，使用时产生编译错误。

## 运算符和定界符

### 运算符（按类别）

| 类别 | Token |
|------|-------|
| 算术 | `+`  `-`  `*`  `/`  `%` |
| 比较 | `==`  `!=`  `<`  `>`  `<=`  `>=` |
| 逻辑 | `&&`  `\|\|`  `!` |
| 赋值 | `=`  `+=`  `-=`  `*=`  `/=`  `%=` |
| Or-Pattern 分隔 | `\|` |
| 范围 | `..`  `..=` |
| 访问 | `.`  `::` |
| 可选 | `?` |
| 箭头 | `->`  `=>` |

### 定界符

```
(  )  {  }  [  ]  ,  :  ;
```

分号是可选的语句终止符。解析器接受但不要求分号。

## 运算符优先级

从低到高：

| 级别 | 名称 | 运算符 | 结合性 |
|------|------|--------|--------|
| 1 | Catch | `catch` | 左结合 |
| 2 | LogicOr | `\|\|` | 左结合 |
| 3 | LogicAnd | `&&` | 左结合 |
| 4 | Equality | `==`  `!=` | 不可结合 |
| 5 | Compare | `<`  `>`  `<=`  `>=` | 不可结合 |
| 6 | Range | `..`  `..=` | 左结合 |
| 7 | AddSub | `+`  `-` | 左结合 |
| 8 | MulDiv | `*`  `/`  `%` | 左结合 |
| 9 | Unary | `-`  `!`（前缀） | 右结合 |
| 10 | Postfix | `.`  `()`  `[]`  `?` | 左结合 |

不可结合运算符不能链式使用：`a < b < c` 是解析错误。

## 标识符

```
Ident        ::= ⟨字母 | '_'⟩ ⟨字母 | 数字 | '_'⟩*
```

其中"字母"为 ASCII 字母（`a`-`z`、`A`-`Z`）。

以大写字母（`A`-`Z`）开头的标识符具有特殊意义：在特定上下文中被识别为类型名或 enum 变体构造器（struct 字面量解析、模式匹配）。

## 字面量

### 整数字面量

```
IntLit       ::= ⟨数字⟩+
```

仅十进制整数。不支持十六进制、八进制或二进制前缀。

### 浮点字面量

```
FloatLit     ::= ⟨数字⟩+ '.' ⟨数字⟩+
```

小数点两侧必须有数字。`.5` 和 `5.` 不合法。

### 布尔字面量

```
BoolLit      ::= 'true' | 'false'
```

### 字符串字面量

```
StringLit    ::= '"' ⟨string-char⟩* '"'
```

支持标准转义序列：`\\`、`\"`、`\n`、`\t`、`\r`、`\0`。

### 原始字符串字面量

```
RawStringLit ::= 'r"'  ⟨除 '"' 外的任意字符⟩* '"'
               | 'r#"' ⟨除 '"#' 外的任意字符⟩* '"#'
```

两种形式都不处理转义或插值，并允许跨行。`r"..."` 不能包含双引号；需要双引号时使用单层 hash delimiter `r#"..."#`。当前语法不接受更多层 hash。

### 字符串插值

```
InterpString ::= '"' (⟨string-char⟩ | '${' Expr '}')* '"'
```

插值表达式是任意 Ring 表达式。Lexer 将插值字符串分词为以下序列：

```
StringInterpStart  →  Expr  →  StringInterpMiddle  →  Expr  →  StringInterpEnd
```

支持嵌套插值：`"outer ${inner + "${deep}"}"`。
