# 词法结构

本页是从字符到 token 的唯一 authority。语法结构、优先级和 AST 分类由[语法](syntax.md)定义。Lexer 记录每个 token 之前是否有换行，供语法判断语句结束；它不读取缩进或标识符大小写来猜测语法角色。

## 扫描规则

Lexer 从左到右扫描，并在当前位置选择可成立的最长 token。多字符运算符优先于其前缀；关键字只在完整标识符拼写相等时成立，例如 `mut_value` 是一个 `Ident`，不是 `'mut'` 后跟另一个 token。空白与注释被丢弃，其他字符必须形成下列 token，否则产生词法错误。

除字符串、原始字符串和行注释内容外，源码只接受下文定义的 ASCII 标识符字符、数字、运算符和定界符。`@` 与独立 `#` 没有 token；`@derive(Json)`、`#[test]` 等形式因此在词法阶段非法，不能产生 attribute/derive AST 占位。

## 空白与注释

```ebnf
LineBreak   ::= '\r\n' | '\n' | '\r'
Whitespace  ::= ' ' | '\t' | LineBreak
LineComment ::= '//' NonLineBreakChar* (LineBreak | EOF)
NonLineBreakChar ::= ⟨除 '\r'、'\n' 外的任意字符⟩
EOF         ::= ⟨输入结束位置⟩
```

`NonLineBreakChar` 表示除 `\r`、`\n` 外的任意字符。Vorton 只有 `//` 行注释，没有块注释。空白与注释不产生 token，但 Lexer 为每个 token 记录它与前一个 token 之间是否出现过换行，包括行注释结尾的换行。这个标记何时结束语句只由[语法](syntax.md#换行与语句结束)规定；缩进没有语法意义。

## 标识符与关键字

```ebnf
AsciiLetter   ::= 'A'..'Z' | 'a'..'z'
Digit         ::= '0'..'9'
IdentStart    ::= AsciiLetter | '_'
IdentContinue ::= IdentStart | Digit
Ident         ::= IdentStart IdentContinue*
```

Lexer 只产生一种 `Ident`。首字母大小写不产生 type、value、variant 或 constructor 类别；这些身份由后续名称解析根据声明和使用位置决定。

以下拼写是保留关键字 token：

```text
fn       let      mut      const    struct   enum     match
impl     effect   handle   with     if       else     catch
return   for      in       pub      where    true     false    trait
while    break    continue loop     use      as       extern
mod      super    requires unsafe
```

`type`、`self` 和 `alias` 是 contextual spelling：Lexer 仍把它们生成为 `Ident`，Parser 只在相应产生式中按精确拼写解释。`where` 用于 trait impl header。

## 运算符与定界符

下列每项各产生一个 token，按最长匹配扫描，例如 `..=` 不拆成 `..` 与 `=`。

| 类别 | Token spelling |
|------|----------------|
| 算术 | `+` `-` `*` `/` `%` |
| 比较 | `==` `!=` `<` `>` `<=` `>=` |
| 逻辑与模式 | `&&` `\|\|` `!` `\|` |
| 借出 | `&` |
| 赋值 | `=` `+=` `-=` `*=` `/=` `%=` |
| 范围 | `..` `..=` |
| 访问 | `.` `::` |
| 箭头 | `->` `=>` |
| 定界符 | `(` `)` `{` `}` `[` `]` `,` `:` `;` |

`&&` 总是一个 token，表示逻辑与；借出一个借出没有意义，所以不需要把它拆成两个 `&`。单独的 `?` 不是 token。

## 数值字面量

```ebnf
IntLit   ::= Digit+
FloatLit ::= Digit+ '.' Digit+
```

只接受十进制数字，不接受 radix 前缀或数值后缀。浮点小数点两侧都必须有数字；`.5` 与 `5.` 非法。`1..2` 扫描为 `IntLit('1')`、`'..'`、`IntLit('2')`，不是浮点字面量。

## 字符串字面量

```ebnf
Escape          ::= '\\' ('\\' | '"' | 'n' | 't' | 'r' | '0')
StringPlainChar ::= ⟨除 '"'、'\\'、LineBreak 与 '${' 起点外的任意字符⟩
StringPart      ::= Escape | StringPlainChar
StringLit       ::= '"' StringPart* '"'
```

`StringPlainChar` 可以是 Unicode 字符；它排除未转义的 `"`、`\\`、换行以及二字符序列 `${` 的起点。单独的 `$` 或不紧接 `{` 的 `$` 是普通内容。普通字符串不能跨行。支持的转义只有 `\\`、`\"`、`\n`、`\t`、`\r`、`\0`。

### 原始字符串

```ebnf
RawStringLit ::= 'r"' Raw0Char* '"'
               | 'r#"' Raw1Content '"#'
Raw0Char     ::= ⟨除 '"' 外的任意字符⟩
Raw1Content  ::= ⟨不包含终止序列 '"#' 的任意字符序列⟩
```

`Raw0Char` 是除 `"` 外的任意字符；`Raw1Content` 是不包含终止序列 `"#` 的任意字符序列。原始字符串不处理转义或插值并允许换行。只有零层和一层 hash delimiter；更多层 hash 非法。

### 插值字符串 token

遇到普通字符串中的第一个 `${` 时，Lexer 不产生 `StringLit`，而进入插值模式并产生以下 token 序列：

```ebnf
StringInterpStart  ::= '"' StringPart* '${'
StringInterpMiddle ::= '}' StringPart* '${'
StringInterpEnd    ::= '}' StringPart* '"'
```

`StringInterpStart` 与每个 `StringInterpMiddle` 后，Lexer 以普通源码模式产生 token，直到与该 `${` 配对的 `}`；随后恢复字符串模式。普通源码中的嵌套 `{...}`、嵌套插值字符串及其定界符各自计数，不会提前结束外层插值。最后一个配对 `}` 到闭引号形成 `StringInterpEnd`。表达式如何组合这些 token 只由[语法](syntax.md)规定。
