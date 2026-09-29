# 语法

本页是从 token 到语法结构的唯一 EBNF authority。字符到 token 只以[词法结构](lexical.md)为准；其他页面解释语义，不另行定义产生式。

EBNF 中 `?`、`*`、`+` 分别表示可选、零次以上和一次以上；终结 token 用单引号；`(* ... *)` 是约束注释。`Ident`、`IntLit`、`FloatLit`、`StringLit`、`RawStringLit`、`StringInterpStart`、`StringInterpMiddle`、`StringInterpEnd` 是词法类别。`'type'`、`'self'`、`'alias'` 是相同拼写的 contextual `Ident`，其余单词终结符是保留关键字。

## 换行与语句结束

Vorton 用换行结束语句，行尾不写分号。

**语句序列**是以下位置：文件顶层与 `mod` 体、`trait`／`impl`／`effect` 的成员列表、代码块 `{ }`、`match` 的分支列表、handler 列表。在语句序列中，相邻两项必须由换行或 `;` 分隔。其他位置的换行都是普通空白：`()`、`[]` 之内，以及 struct／enum 声明体、named construction、模式字段、effect 集合、`use` 列表的花括号之内。嵌套在 `()` 或 `[]` 里的代码块（例如作为参数的闭包体）重新成为语句序列。

在语句序列中，换行结束当前项，以下情况除外，此时下一行接着算：

1. 换行前最后一个 token 是二元运算符、赋值运算符、`,`、`.`、`::`、`->`、`=>` 或 `|`；
2. 下一行以 `.`、`else`、`catch` 或 `with` 开头。

`;` 只用于在同一行分隔多项，其后同一行必须还有一项；行尾的 `;` 是语法错误。构造的开括号 `{` 必须与构造头部写在同一行。

```vorton
fn update(world: mut World, dt: Float) {
    for e in mut world.enemies {
        e.pos.x += e.vel.x * dt
        e.pos.y += e.vel.y * dt
    }
    let alive = world.enemies
        .filter(fn(e) { e.hp > 0 })
        .map(fn(e) { e.name })
    let total = base_damage * multiplier +
        bonus
    if alive.is_empty() {
        world.log.push("wave cleared")
    } else {
        world.log.push("${alive.len()} alive")
    }
}
```

`callable` 换行后再写 `(args)` 是两项：先求值 `callable`，再求值后一行的括号表达式。跨行调用时把 `(` 留在第一行。

## Program 与声明

下列 EBNF 省略语句序列中的分隔符。

```ebnf
Program          ::= FileRequires? UseDecl* Decl*
FileRequires     ::= 'requires' EffectSet

Decl             ::= ImplDecl | Visibility? DeclKind
Visibility       ::= 'pub'
DeclKind         ::= FnDecl
                   | StructDecl
                   | EnumDecl
                   | TraitDecl
                   | EffectDecl
                   | EffectAliasDecl
                   | ExternDecl
                   | TypeAliasDecl
                   | ConstDecl
                   | ModDecl

FnDecl           ::= FnHeader Block
FnHeader         ::= 'fn' Ident CallableParams? '(' FnParams? ')'
                     ReturnType? EffectAnnotation?
FnParams         ::= Receiver (',' Param)* ','?
                   | Param (',' Param)* ','?
Receiver         ::= 'self' (':' ParamMode 'Self')?
Param            ::= Ident ':' ParamType
ParamType        ::= ParamMode? TypeExpr
ParamMode        ::= 'mut' | 'move'
ReturnType       ::= '->' TypeExpr

StructDecl       ::= 'struct' Ident TypeParams? '{' StructFields? '}'
StructFields     ::= StructField (',' StructField)* ','?
StructField      ::= Visibility? Ident ':' TypeExpr

EnumDecl         ::= 'enum' Ident TypeParams? '{' EnumVariants? '}'
EnumVariants     ::= EnumVariant (',' EnumVariant)* ','?
EnumVariant      ::= Ident VariantFields?
VariantFields    ::= '(' TypeExpr (',' TypeExpr)* ','? ')'
                   | '{' NamedFields? '}'
NamedFields      ::= NamedField (',' NamedField)* ','?
NamedField       ::= Ident ':' TypeExpr

ImplDecl         ::= 'impl' TypeParams? NamedType ('for' NamedType WhereClause?)?
                     '{' ImplMember* '}'
ImplMember       ::= Visibility? FnDecl
                   | Visibility? 'type' Ident '=' TypeExpr
WhereClause      ::= 'where' WherePredicate (',' WherePredicate)* ','?
WherePredicate   ::= TypeExpr ':' TraitBound ('+' TraitBound)*

TraitDecl        ::= 'trait' Ident TypeParams? (':' TraitBound ('+' TraitBound)*)?
                     '{' TraitMember* '}'
TraitMember      ::= FnHeader
                   | 'type' Ident (':' TraitBound ('+' TraitBound)*)? ('=' TypeExpr)?

EffectDecl       ::= 'effect' Ident TypeParams? '{' EffectOp* '}'
EffectOp         ::= 'fn' Ident '(' (Param (',' Param)* ','?)? ')' ReturnType
EffectAliasDecl  ::= 'effect' 'alias' Ident TypeParams? '=' EffectSet

ExternDecl       ::= 'extern' 'fn' Ident CallableParams? '(' (Param (',' Param)* ','?)? ')'
                     ReturnType? EffectAnnotation
                   | 'extern' 'type' Ident TypeParams?

TypeAliasDecl    ::= 'type' Ident TypeParams? '=' TypeExpr
ConstDecl        ::= 'const' Ident (':' TypeExpr)? '=' Expr
ModDecl          ::= 'mod' Ident ('requires' EffectSet)? '{' UseDecl* Decl* '}'

UseDecl          ::= Visibility? 'use' Path ('as' Ident | '::' '{' UseItems? '}')?
UseItems         ::= UseItem (',' UseItem)* ','?
UseItem          ::= Ident ('as' Ident)?
```

文件 `requires` 若存在必须是第一项；所有 `use` 必须先于其他声明，inline `mod` 内同样如此。路径与模块的名称解析见[模块系统](modules.md)。

具名函数、方法和 trait 方法的每个参数都必须写类型；省略返回类型表示 `Unit`。方法的第一个参数可以是 receiver：`self` 只读，`self: mut Self` 就地修改调用者，`self: move Self` 取走调用者（只用于资源）。Trait 成员只有签名，没有函数体。`impl` 本身没有 visibility；inherent impl 的成员可以加 `pub`，trait impl 的成员不能加。Effect operation 必须写返回类型。`extern fn` 必须写 `with`，pure 声明写作 `with {}`。

参数模式的含义见[类型系统](type-system.md#参数与修改)：不写模式表示只读；`mut` 表示就地修改调用方的数据；`move` 表示取走一个资源。

## Path、类型与 effect

```ebnf
Path             ::= PathSegment ('::' PathSegment)*
PathSegment      ::= Ident | 'super'

TypeExpr         ::= NamedType | FnType | TupleType | '(' TypeExpr ')'
NamedType        ::= Path TypeArgs?
TupleType        ::= '(' TypeExpr ',' TypeExpr (',' TypeExpr)* ','? ')'
FnType           ::= 'fn' '(' (ParamType (',' ParamType)* ','?)? ')'
                     ReturnType? EffectAnnotation?

TypeParams       ::= '<' TypeParam (',' TypeParam)* ','? '>'
TypeParam        ::= Ident (':' TraitBound ('+' TraitBound)*)?
TraitBound       ::= NamedType
CallableParams   ::= '<' TypeParam (',' TypeParam)*
                     (',' EffectParam (',' EffectParam)*)? ','? '>'
                   | '<' EffectParam (',' EffectParam)* ','? '>'
EffectParam      ::= 'effect' Ident
TypeArgs         ::= '<' TypeArgument (',' TypeArgument)* ','? '>'
TypeArgument     ::= TypeExpr | Ident '=' TypeExpr

EffectAnnotation ::= 'with' EffectSet
EffectSet        ::= '{' (EffectExpr (',' EffectExpr)* ','?)? '}'
EffectExpr       ::= Path EffectApplyArgs? | 'unsafe'
EffectApplyArgs  ::= '<' TypeExpr (',' TypeExpr)*
                     (',' 'effect' EffectSet)* ','? '>'
```

函数类型是普通类型，可以出现在字段、容器元素、类型参数和返回类型中，例如 `List<fn(Int) -> Int>`。省略返回类型表示 `Unit`；参数可以带 `mut`／`move`，例如 `fn(mut List<Int>)`。`with` 归属最近的函数类型或函数头：`fn make() -> fn() -> Int with {fs}` 中的 `{fs}` 属于返回的函数类型；要标注 `make` 本身，把返回类型加括号：`fn make() -> (fn() -> Int) with {fs}`。

`(T)` 与 `T` 是同一类型。Tuple 至少两个元素；单位类型写作 `Unit`。可选值写作 `Option<T>`，没有 `T?` 缩写。所有命名类型、值路径、构造与模式都使用统一的 `Path`，大小写不参与分类。

Effect 参数（`effect E`）与 `EffectApplyArgs` 中的 `effect { ... }` 实参维持现状；effect 在签名中的呈现方式在 Milestone 4 定稿。

## 代码块与语句

```ebnf
Block            ::= '{' Stmt* '}'

Stmt             ::= LetStmt
                   | AliasStmt
                   | LetDestructStmt
                   | AssignStmt
                   | ReturnStmt
                   | 'break'
                   | 'continue'
                   | IfLetStmt
                   | WhileStmt
                   | ForInStmt
                   | LoopStmt
                   | Expr

LetStmt          ::= 'let' 'mut'? Ident (':' TypeExpr)? '=' Expr
AliasStmt        ::= 'let' Ident (':' TypeExpr)? '=' 'mut' Place
LetDestructStmt  ::= 'let' TuplePattern '=' Expr
AssignStmt       ::= Place AssignOp Expr
AssignOp         ::= '=' | '+=' | '-=' | '*=' | '/=' | '%='
ReturnStmt       ::= 'return' Expr?

IfLetStmt        ::= 'if' 'let' Pattern '=' Operand Block ('else' Block)?
WhileStmt        ::= 'while' ControlHead Block
ForInStmt        ::= 'for' ForBinding 'in' Operand Block
LoopStmt         ::= 'loop' Block
ForBinding       ::= Ident | '(' Ident ',' Ident (',' Ident)* ','? ')'

Operand          ::= 'mut' Place | ControlHead
Place            ::= Ident PlaceSuffix*
PlaceSuffix      ::= '.' Ident | '.' IntLit | '[' Expr ']'
```

代码块的值是最后一项；最后一项不是表达式时，值为 `Unit`。期望类型是 `Unit` 时，最后一项的值被丢弃。非最后一项的表达式，其值总是被丢弃。

`mut` 写在位置（`Place`）前面，表示就地、独占地访问这个位置，出现在四处：调用参数 `f(mut x)`、别名 `let t = mut a.b`、循环 `for e in mut xs`、以及 `match mut x`／`if let P = mut x`。`mut` 写在变量名前面（`let mut n`）表示这个变量本身可以修改。两者的语义见[类型系统](type-system.md#参数与修改)。

```vorton
let t = mut world.scenes[s].nodes[n].transform
t.position.x += dx
t.dirty = true

match mut world.state {
    State::Running { timer } => { timer -= dt }
    State::Paused => ()
}
```

## 表达式

```ebnf
Expr             ::= OrExpr ('catch' MatchBody)*
OrExpr           ::= AndExpr ('||' AndExpr)*
AndExpr          ::= EqualityExpr ('&&' EqualityExpr)*
EqualityExpr     ::= CompareExpr (('==' | '!=') CompareExpr)?
CompareExpr      ::= RangeExpr (('<' | '>' | '<=' | '>=') RangeExpr)?
RangeExpr        ::= AddExpr (('..' | '..=') AddExpr)?
AddExpr          ::= MulExpr (('+' | '-') MulExpr)*
MulExpr          ::= UnaryExpr (('*' | '/' | '%') UnaryExpr)*
UnaryExpr        ::= ('-' | '!') UnaryExpr | PostfixExpr
PostfixExpr      ::= PrimaryExpr Postfix*
Postfix          ::= ArgList
                   | '[' Expr ']'
                   | '.' IntLit
                   | '.' Ident ArgList?

PrimaryExpr      ::= IntLit | FloatLit | StringLit | RawStringLit
                   | InterpolatedString
                   | 'true' | 'false'
                   | Path
                   | NamedConstruct
                   | ListLiteral
                   | '(' ')'
                   | '(' Expr ')'
                   | TupleExpr
                   | Block
                   | IfExpr
                   | MatchExpr
                   | HandleExpr
                   | ClosureExpr
                   | UnsafeExpr

InterpolatedString ::= StringInterpStart Expr (StringInterpMiddle Expr)* StringInterpEnd
NamedConstruct   ::= Path '{' ConstructEntries? '}'
ConstructEntries ::= ('..' Expr | FieldInit) (',' FieldInit)* ','?
FieldInit        ::= Ident (':' Expr)?
ListLiteral      ::= '[' (Expr (',' Expr)* ','?)? ']'
TupleExpr        ::= '(' Expr ',' Expr (',' Expr)* ','? ')'

ArgList          ::= '(' (Arg (',' Arg)* ','?)? ')'
Arg              ::= Expr | 'mut' Place | 'move' Ident

ControlHead      ::= Expr  (* 禁止 delimiter depth 0 的 NamedConstruct *)
IfExpr           ::= 'if' ControlHead Block ('else' (IfExpr | Block))?
MatchExpr        ::= 'match' Operand MatchBody
MatchBody        ::= '{' MatchArm* '}'
MatchArm         ::= OrPattern ('if' Expr)? '=>' Expr
HandleExpr       ::= 'handle' Block 'with' '{' Handler* '}'
Handler          ::= Path '.' Ident '(' (HandlerParam (',' HandlerParam)* ','?)? ')' '=>' Expr
HandlerParam     ::= Ident (':' TypeExpr)?
ClosureExpr      ::= 'fn' '(' (ClosureParam (',' ClosureParam)* ','?)? ')'
                     ReturnType? EffectAnnotation? Block
ClosureParam     ::= Ident (':' ParamType)?
UnsafeExpr       ::= 'unsafe' Block
```

`match` 分支与 handler 各占一项，以换行分隔；写在同一行时用 `,` 分隔，规则与 `;` 相同，行尾的 `,` 是语法错误。分支体是表达式；赋值等语句或多行分支体写成代码块，例如 `=> { timer -= dt }`。

优先级从低到高为 `catch`、`||`、`&&`、相等、比较、range、加减、乘除余、一元、后缀。`catch`、逻辑、加减、乘除余和后缀左结合；一元右结合；相等、比较与 range 不可链式结合，所以 `a < b < c` 是语法错误。

同一表达式内的子表达式按源码从左到右求值：被调函数或 receiver 先于参数；二元运算数、参数、List／tuple／构造字段与字符串插值依次求值；下标先 receiver 后下标。

### 方法调用与字段中的函数

`value.member(args)` 总是方法调用。调用存放在字段里的函数值，必须写成 `(value.member)(args)`。

### 调用处的 `mut` 与 `move`

对 `mut` 参数，调用处写 `f(mut place)`；对 `move` 参数，调用处写 `f(move name)`。`mut` 后必须是位置，`move` 后必须是局部变量名；`f(mut make())` 在语法阶段拒绝。方法的 receiver 不需要调用处标记。

### Control head

`if`、`while`、`for ... in`、`match` 与 `if let` 的头部禁止未加括号的顶层 named construction：`if packet { ready: true } { ... }` 非法，写作 `if (packet { ready: true }).ready { ... }`。

### 闭包

闭包写作 `fn(params) { body }`，参数类型可以省略，由上下文推断。闭包按值捕获它用到的外部变量，不能修改外部变量；捕获资源会取走它。没有 capture list。

## 模式

```ebnf
OrPattern        ::= Pattern ('|' Pattern)*
Pattern          ::= '_'
                   | IntLit | FloatLit | StringLit
                   | 'true' | 'false'
                   | PathPattern
                   | TuplePattern
PathPattern      ::= Path PatternFields?
PatternFields    ::= '(' Pattern (',' Pattern)* ','? ')'
                   | '{' NamedPatternBody? '}'
NamedPatternBody ::= '..' ','?
                   | NamedPatternField (',' NamedPatternField)* (',' '..')? ','?
NamedPatternField ::= Ident (':' Pattern)?
TuplePattern     ::= '(' Pattern ',' Pattern (',' Pattern)* ','? ')'
```

单段 `PathPattern` 由名称解析归为绑定或零字段 variant，依据是可见声明，不是大小写。绑定、or-pattern 与穷尽性规则见[模式匹配](patterns.md)。

## 明确排除的写法

以下写法没有产生式：

```vorton
let x = compute();                  // 行尾分号
fn f()                              // { 不在同一行
{
}
fn f(x: &Int) {}                    // 没有 &
fn f(mut x: Int) {}                 // 参数不能写成本地可变；需要时 let mut y = x
fn f(self: &mut Self) {}            // receiver 写作 self: mut Self
let mut t = mut world.player        // 别名本身已可修改
for mut e in enemies {}             // 就地修改写作 for e in mut enemies
f(mut make())                       // mut 后必须是位置
let v: Int? = Option::None          // 没有 T? 缩写
let v = item?                       // 没有后缀 ?
fn apply<F: Fn>(f: call F) {}       // 没有 Fn trait、call、scoped；函数类型写作 fn(A) -> B
let f = fn [counter](x) { x }       // 没有 capture list
const fn f() {}                     // 没有 const fn
generate ctx {}                     // 没有 generate
test "name" {}                      // 没有 test 声明
#[test] fn probe() {}               // '#' 不是 token
pub impl Value {}                   // impl 没有 visibility
```

Parser 不建立兼容模式、feature flag、attribute 节点或未来 hook。
