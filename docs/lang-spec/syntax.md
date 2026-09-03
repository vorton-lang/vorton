# 语法

本页是 canonical 0.1 从 token 到语法结构的唯一完整 EBNF authority。[词法结构](lexical.md)唯一负责字符到 token；其他语言规范页面解释语义并链接本页，不另行定义产生式。

EBNF 中 `?`、`*`、`+` 分别表示可选、零次以上和一次以上，终结 token spelling 用单引号表示，`(* ... *)` 是产生式约束注释。`Ident`、`IntLit`、`FloatLit`、`StringLit`、`RawStringLit`、`StringInterpStart`、`StringInterpMiddle` 与 `StringInterpEnd` 是词法 token 类别。`'type'`、`'self'`、`'alias'` 表示相同拼写的 contextual `Ident`；其余单词终结符是保留关键字。

## Program 与声明

```ebnf
Program          ::= FileRequires? UseDecl* Decl*
FileRequires     ::= 'requires' EffectSet ';'

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
                   | TestDecl
                   | ModDecl

FnDecl           ::= 'fn' Ident TypeParams? '(' NamedParams? ')'
                     ReturnType? EffectAnnotation? Block
ReturnType       ::= '->' TypeExpr

NamedParams      ::= NamedParam (',' NamedParam)* ','?
NamedParam       ::= Ident (':' ParamType)?
ParamType        ::= ParamMode? TypeExpr
ParamMode        ::= 'mut' | 'move'

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

ImplDecl         ::= InherentImplDecl | TraitImplDecl
InherentImplDecl ::= 'impl' TypeParams? NamedType '{' InherentImplMember* '}'
TraitImplDecl    ::= 'impl' TypeParams? NamedType 'for' NamedType
                     '{' TraitImplMember* '}'
InherentImplMember ::= Visibility? FnDecl
                     | Visibility? ImplAssocType
TraitImplMember  ::= FnDecl | ImplAssocType
ImplAssocType    ::= 'type' Ident '=' TypeExpr ';'

TraitDecl        ::= 'trait' Ident TypeParams? Supertraits?
                     '{' TraitMember* '}'
Supertraits      ::= ':' TypeBound ('+' TypeBound)*
TraitMember      ::= TraitMethodSig | TraitAssocType
TraitMethodSig   ::= 'fn' Ident TypeParams? '(' NamedParams? ')'
                     ReturnType? EffectAnnotation? ';'
TraitAssocType   ::= 'type' Ident AssocBounds? ('=' TypeExpr)? ';'
AssocBounds      ::= ':' TypeBound ('+' TypeBound)*

EffectDecl       ::= 'effect' Ident TypeParams? '{' EffectOp* '}'
EffectOp         ::= 'fn' Ident '(' NamedParams? ')' '->' TypeExpr ';'
EffectAliasDecl  ::= 'effect' 'alias' Ident TypeParams? '=' EffectSet ';'

ExternDecl       ::= 'extern' ExternKind
ExternKind       ::= 'fn' Ident TypeParams? '(' NamedParams? ')'
                     ReturnType? EffectAnnotation? ';'
                   | 'type' Ident TypeParams? ';'

TypeAliasDecl    ::= 'type' Ident TypeParams? '=' TypeExpr ';'
ConstDecl        ::= 'const' Ident (':' TypeExpr)? '=' Expr ';'
TestDecl         ::= 'test' StringLit Block
ModDecl          ::= 'mod' Ident ('requires' EffectSet)?
                     '{' UseDecl* Decl* '}'

UseDecl          ::= Visibility? 'use' Path UseSuffix? ';'
UseSuffix        ::= 'as' Ident
                   | '::' '{' UseItems? '}'
UseItems         ::= UseItem (',' UseItem)* ','?
UseItem          ::= Ident ('as' Ident)?
```

文件 `requires` 必须是第一项非注释语法且每文件至多一个；随后所有 `use` 必须先于普通声明。inline `mod` 内同样先列 `use`。路径与模块的名称解析约束见[模块系统](modules.md)。

无 body 的 file `requires`、`use`、type alias、const、effect alias、`extern fn`、`extern type`、trait method signature、associated type declaration/assignment 与 effect operation 都必须以 `;` 结束。带 body 的 `fn`、`struct`、`enum`、`impl`、`trait`、`effect`、inline `mod` 和 `test` 后面不写 `;`。Struct field 与 enum variant 由逗号分隔，最后一项可带 trailing comma；effect operation 不接受逗号代替分号。

```vorton
requires {unsafe};
use geometry::{Point, distance};

type Length = Float;
const origin: Point = Point { x: 0.0, y: 0.0 };
extern fn host_distance(left: Point, right: Point) -> Float;

trait Measure {
    type Output;
    fn measure(self: Self) -> Output;
}

effect Trace {
    fn emit(message: Str) -> Unit;
}

struct Pair {
    left: Int,
    right: Int,
}
```

Impl block 本身没有 visibility，因此 `pub impl Value {}` 非法；只有 inherent impl member 可以逐项加 `pub`。Source trait method 只有以 `;` 结束的签名，`fn method(...) { ... }` 在 trait declaration 中非法。函数默认参数、impl-member `extern fn`、`delegate` 与 `sig` 均没有产生式。

### 参数、receiver 与 closure capture

参数的 ownership/mutation mode 由编译器推断；源码 mode 是可省略的 assertion，不改变推断结果。Named parameter 的 mode 只能出现在冒号后、类型前：`item: mut Item` 或 `item: move Item`。Receiver 使用同一形式，例如 `self: mut Self`、`self: move Self`；`fn update(mut item)` 与 `fn update(mut self)` 都非法。未命名函数类型参数则写 `fn(mut Item, move Resource) -> Unit`。

Closure capture list 只属于 closure literal，并固定写在参数列表之前：

```vorton
let update = fn [mut counter: Int, name: Str](step: Int) {
    counter = counter + step;
    print(name);
};
```

`fn(step) [mut counter] { ... }` 非法。capture list 可在 lv0 完全省略并由编译器推断，lv2 formatter 可物化；它不进入 `FnType`，不改变函数类型相等性或调用签名。所有显式 mode/capture assertion 都必须与推断结果一致；不一致遵守现有 warning 及 agent profile 的 warning-as-error 规则。

## Path、类型与 effect

```ebnf
Path             ::= PathSegment ('::' PathSegment)*
PathSegment      ::= Ident | 'super'

TypeExpr         ::= NamedType | FnType | TupleType | RecordType
NamedType        ::= Path TypeArgs?
FnType           ::= 'fn' '(' FnTypeParams? ')' '->' TypeExpr
                     EffectAnnotation?
FnTypeParams     ::= FnTypeParam (',' FnTypeParam)* ','?
FnTypeParam      ::= ParamMode? TypeExpr
TupleType        ::= '(' TypeExpr ',' TypeExpr (',' TypeExpr)* ','? ')'
RecordType       ::= '{' RecordField (',' RecordField)*
                     (',' '..' Ident)? ','? '}'
RecordField      ::= Ident ':' TypeExpr

TypeParams       ::= '<' TypeParam (',' TypeParam)* ','? '>'
TypeParam        ::= Ident (':' TypeBound ('+' TypeBound)*)?
TypeBound        ::= NamedType
TypeArgs         ::= '<' TypeArgument (',' TypeArgument)* ','? '>'
TypeArgument     ::= TypeExpr | AssocTypeBinding
AssocTypeBinding ::= Ident '=' TypeExpr

EffectAnnotation ::= 'with' EffectSet
EffectSet        ::= '{' (EffectExpr (',' EffectExpr)* ','?)? '}'
EffectExpr       ::= Path EffectArgs?
                   | 'mut' EffectArgs?
                   | 'unsafe'
EffectArgs       ::= '<' TypeExpr (',' TypeExpr)* ','? '>'
```

所有命名类型、value path、named-field construction 与 pattern path 都使用统一 `Path`；大小写不参与分类。`super` 的合法层级以及 contextual `self` 的路径位置由模块解析检查，而非 Lexer 按字符类别区分。

`Option<T>` 是唯一 Option 类型拼写，类型产生式不含 postfix `?`：

```vorton
let item: Option<Int> = some(1);
let value = item?;
```

第二行的 `?` 是 expression postfix，不是类型缩写。`Int?` 在类型位置非法。函数类型的 mode 写在未命名类型前，如 `fn(mut List<Int>, move File) -> Unit`；capture list 永不出现在函数类型中。

## Block 与语句

```ebnf
Block            ::= '{' BlockItems? '}'
BlockItems       ::= TerminatedStmt BlockItems?
                   | StructuredStmt BlockItems?
                   | ExpressionWithBlock BlockItems
                   | Expr

TerminatedStmt   ::= LetStmt
                   | LetMutStmt
                   | LetDestructStmt
                   | ReturnStmt
                   | BreakStmt
                   | ContinueStmt
                   | AssignStmt
                   | ExprStmt
LetStmt          ::= 'let' Ident (':' TypeExpr)? '=' Expr ';'
LetMutStmt       ::= 'let' 'mut' Ident (':' TypeExpr)? '=' Expr ';'
LetDestructStmt  ::= 'let' TuplePattern '=' Expr ';'
ReturnStmt       ::= 'return' Expr? ';'
BreakStmt        ::= 'break' ';'
ContinueStmt     ::= 'continue' ';'
AssignStmt       ::= PlaceExpr AssignOp Expr ';'
AssignOp         ::= '=' | '+=' | '-=' | '*=' | '/=' | '%='
ExprStmt         ::= Expr ';'

StructuredStmt   ::= IfLetStmt | WhileStmt | ForInStmt | LoopStmt
IfLetStmt        ::= 'if' 'let' Pattern '=' ControlHead Block
                     ('else' Block)?
WhileStmt        ::= 'while' ControlHead Block
ForInStmt        ::= 'for' ForBinding 'in' ControlHead Block
LoopStmt         ::= 'loop' Block
ForBinding       ::= Ident
                   | '(' Ident ',' Ident (',' Ident)* ','? ')'

PlaceExpr        ::= Ident ('.' Ident)*
ExpressionWithBlock ::= Block
                      | IfExpr
                      | MatchExpr
                      | HandleExpr
                      | UnsafeExpr
                      | CatchExpr
```

`let`、赋值、`return`、`break`、`continue` 和普通 expression statement 必须有 `;`。`if let`、`while`、`for` 与 `loop` 自带 block，不接受尾随 `;`。`ExpressionWithBlock` 作为非末尾 statement 时可省略 `;`；它也可以通过 `ExprStmt` 显式带 `;`。

Block 最后一个无分号 `Expr` 总是 tail，其值就是 block value；没有 tail 时 block value 为 `Unit`。右递归的 `BlockItems` 只允许无分号 `ExpressionWithBlock` 在后面仍有 item 时充当 statement，因此最后一个 direct `ExpressionWithBlock` 唯一经 `Expr` 分支成为 tail。Parser 必须先消费能继续当前表达式的 postfix/operator token，换行不能提前截断它；例如 direct `if` 后的 `(arg)` 会构成外层 call，而不是开始第二个 item。加 `;` 会丢弃该值，并在没有其他 tail 时令 block 为 `Unit`。不存在 `yield` 或第二套 block 返回机制。

```vorton
fn choose(flag: Bool) -> Int {
    if flag { 1 } else { 2 }
}

fn run(flag: Bool) -> Unit {
    if flag {
        start();
    }
    finish();
}

fn stop_or_continue(done: Bool) -> Unit {
    loop {
        if done {
            break;
        }
        continue;
    }
}

fn one() -> Int {
    return 1;
}

fn discard_value() -> Unit {
    42;
}
```

第一例的直接 `if` 是 tail；第二例的非末尾直接 `if` 可省略分号，而普通调用 `finish()` 必须带分号。随后两例显示 `loop`/`if` 自带 block 而不加分号，`break`、`continue` 与 `return` 自身必须加分号。最后一例的 `42;` 被丢弃，因此 block value 是 `Unit`。

只有最外层正好是 `Block`、`IfExpr`、`MatchExpr`、`HandleExpr`、`UnsafeExpr` 或 `CatchExpr` 的表达式属于 `ExpressionWithBlock`。外层一旦增加括号、call、method、field、index、unary、binary 或 range，整体就恢复为普通表达式，作为 statement 必须写 `;`。Closure literal 不属于该集合：

```vorton
(if flag { 1 } else { 2 });
fn() { work(); };
```

## 表达式

```ebnf
Expr             ::= CatchExpr | LogicOrExpr
CatchExpr        ::= LogicOrExpr 'catch' MatchBody
                     ('catch' MatchBody)*
LogicOrExpr      ::= LogicAndExpr ('||' LogicAndExpr)*
LogicAndExpr     ::= EqualityExpr ('&&' EqualityExpr)*
EqualityExpr     ::= CompareExpr (EqualityOp CompareExpr)?
EqualityOp       ::= '==' | '!='
CompareExpr      ::= RangeExpr (CompareOp RangeExpr)?
CompareOp        ::= '<' | '>' | '<=' | '>='
RangeExpr        ::= AddExpr (RangeOp AddExpr)*
RangeOp          ::= '..' | '..='
AddExpr          ::= MulExpr (AddOp MulExpr)*
AddOp            ::= '+' | '-'
MulExpr          ::= UnaryExpr (MulOp UnaryExpr)*
MulOp            ::= '*' | '/' | '%'
UnaryExpr        ::= ('-' | '!') UnaryExpr | PostfixExpr
PostfixExpr      ::= PrimaryExpr PostfixTail?
PostfixTail      ::= '?'
                     PostfixTail?
                   | ArgList PostfixTail?
                   | '[' Expr ']' PostfixTail?
                   | '.' IntLit PostfixTail?
                   | '.' Ident MemberTail?
MemberTail       ::= ArgList PostfixTail?  (* immediately preceding member forms a method call *)
                   | '?' PostfixTail?
                   | '[' Expr ']' PostfixTail?
                   | '.' IntLit PostfixTail?
                   | '.' Ident MemberTail?

PrimaryExpr      ::= IntLit
                   | FloatLit
                   | StringLit
                   | RawStringLit
                   | InterpolatedString
                   | 'true'
                   | 'false'
                   | Path
                   | NamedConstruct
                   | ListLiteral
                   | UnitExpr
                   | ParenExpr
                   | TupleExpr
                   | Block
                   | IfExpr
                   | MatchExpr
                   | HandleExpr
                   | ClosureExpr
                   | UnsafeExpr

InterpolatedString ::= StringInterpStart Expr
                       (StringInterpMiddle Expr)* StringInterpEnd
NamedConstruct   ::= Path '{' ConstructEntries? '}'
ConstructEntries ::= SpreadInit (',' FieldInit)* ','?
                   | FieldInit (',' FieldInit)* ','?
SpreadInit       ::= '..' Expr
FieldInit        ::= Ident (':' Expr)?
ListLiteral      ::= '[' (Expr (',' Expr)* ','?)? ']'
UnitExpr         ::= '(' ')'
ParenExpr        ::= '(' Expr ')'
TupleExpr        ::= '(' Expr ',' Expr (',' Expr)* ','? ')'

ArgList          ::= '(' CallArgs? ')'
CallArgs         ::= CallArg (',' CallArg)* ','?
CallArg          ::= Expr | ParamMode PlaceExpr

ControlHead      ::= Expr  (* 禁止 delimiter depth 0 的 NamedConstruct *)
IfExpr           ::= 'if' ControlHead Block
                     ('else' (IfExpr | Block))?
MatchExpr        ::= 'match' ControlHead MatchBody
MatchBody        ::= '{' MatchArm* '}'
MatchArm         ::= OrPattern Guard? '=>' Expr ','?
Guard            ::= 'if' Expr
HandleExpr       ::= 'handle' Block 'with' HandlerBody
HandlerBody      ::= '{' Handler* '}'
Handler          ::= Path '.' Ident '(' NamedParams? ')' '=>' Expr ','?
ClosureExpr      ::= 'fn' CaptureList? '(' NamedParams? ')'
                     ReturnType? EffectAnnotation? Block
CaptureList      ::= '[' CaptureParams? ']'
CaptureParams    ::= CaptureParam (',' CaptureParam)* ','?
CaptureParam     ::= ParamMode? Ident (':' TypeExpr)?
UnsafeExpr       ::= 'unsafe' Block
```

优先级从低到高为 catch、`||`、`&&`、equality、comparison、range、加减、乘除余、unary、postfix。Catch、逻辑、range、加减、乘除余和 postfix 左结合；unary 右结合；equality 与 comparison 各自不可链式结合，所以 `a < b < c` 和 `a == b == c` 都是语法错误。

同一 evaluation region 内的同级子表达式按源码从左到右求值：callable/receiver 先于 arguments；binary operands、arguments、List/tuple/construction fields 与字符串插值依次求值；index 先 receiver 后 index，range 先 start 后 end。短路、branch、match arm、failure 与 Drop 的完整语义见对应语义页。

### Postfix、member call 与 place assertion

换行是普通空白，因此 `callable\n(args)` 仍由 `ArgList` 形成一个 call。对 member suffix，Parser 必须贪婪地把 `.` `Ident` 后紧随的 `ArgList` 归为同一个 MethodCall，不能把它解释成 FieldAccess 后再 Call：

```vorton
value.member(args);       // MethodCall
(value.member)(args);     // Call(Paren(FieldAccess), args)
```

调用函数值字段必须使用第二种显式括号形式。空白或换行不改变这个分类，故 `value.member\n(args)` 仍是 MethodCall。

Call-site mode assertion 只接受 syntactic place：

```vorton
transfer(mut state, move file);
```

`mut`/`move` 后必须匹配 `PlaceExpr`；`transfer(mut make_state())`、`transfer(move (file))` 等非-place operand 在语法阶段拒绝。Assertion 不覆盖被调函数推断出的真实 mode，不匹配时按标注失真处理。

### 统一 Path 与 named construction

`Path(args)` 使用普通 call 形状；Parser 不根据 path 大小写猜它是函数还是 positional constructor。`Path { fields }` 是统一 named-field construction 形状；具体 struct/variant owner 由 Resolver 决定。Pattern 同样使用 `Path`。

```vorton
let lower = packet { size: 1 };
let upper = BUILD(1);
```

两行都能被 Parser 分类；名字是否存在、是 type/value/variant，以及 call 是否为合法 constructor，均留给 Resolver 和 Checker。

`if`、`if let`、`while`、`for ... in` 与 `match` 的 `ControlHead` 额外禁止未加括号的顶层 brace-form `NamedConstruct`。这里“顶层”指 construction 的 `{` 出现在 control head 的 delimiter depth 0；括号会把它移入内层。这是 `ControlHead` 唯一相对普通 `Expr` 的句法限制，嵌套于括号后即可使用：

```vorton
if (packet { ready: true }).ready {
    start();
}

match (token { kind: 1 }) {
    value => consume(value),
}
```

`if packet { ready: true } { ... }` 与 `match token { kind: 1 } { ... }` 非法；Parser 不把第一个 `{` 猜成 construction 或 control body。相同限制适用于 `if let` initializer、`while` condition 和 `for ... in` iterable。

## 模式

```ebnf
OrPattern        ::= Pattern ('|' Pattern)*
Pattern          ::= '_'
                   | IntLit
                   | FloatLit
                   | StringLit
                   | 'true'
                   | 'false'
                   | PathPattern
                   | TuplePattern
PathPattern      ::= Path PatternFields?
PatternFields    ::= '(' PatternList ')'
                   | '{' NamedPatternBody? '}'
PatternList      ::= Pattern (',' Pattern)* ','?
NamedPatternBody ::= '..' ','?
                   | NamedPatternList (',' '..')? ','?
NamedPatternList ::= NamedPatternField (',' NamedPatternField)*
NamedPatternField ::= Ident (':' Pattern)?
TuplePattern     ::= '(' Pattern ',' Pattern (',' Pattern)* ','? ')'
```

一个 bare single-segment `PathPattern` 可由 Resolver 归为 binding 或零字段 variant；这一决定依据可见声明，不依据首字母大小写。带 `()` 或 `{}` 的 path 是 constructor-shaped pattern，owner identity同样留给 Resolver。Named pattern 支持 field punning 和末尾 `..`；详细绑定、or-pattern 与穷尽性规则见[模式匹配](patterns.md)。

## 明确排除的 0.1 表面

以下形式没有 canonical 产生式，只能在文档中作为非法反例出现：

```vorton
let invalid: Int? = none;                    // 非法：类型只能写 Option<Int>
fn invalid(mut value) { value = 1; }         // 非法：binder-prefix mode
fn invalid(mut self) {}                      // 非法：receiver-prefix mode
let invalid = fn(x) [move resource] { x };   // 非法：capture list 在参数之后
@derive(Json)                            // 非法：'@' 不是 token
pub impl Value {}                        // 非法：impl block 无 visibility
```

同样非法的还有缺失必需 `;` 的普通 statement/无 body declaration、以逗号结束的 effect operation，以及带 body 的 source trait method。Parser 不建立 compatibility mode、feature flag、Attribute/Derive 节点或 future hook。
