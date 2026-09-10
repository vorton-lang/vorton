# 语法

本页是 canonical 0.1 从 token 到语法结构的唯一完整 EBNF authority。[词法结构](lexical.md)唯一负责字符到 token；其他语言规范页面解释语义并链接本页，不另行定义产生式。

EBNF 中 `?`、`*`、`+` 分别表示可选、零次以上和一次以上，终结 token spelling 用单引号表示，`(* ... *)` 是产生式约束注释。`Ident`、`IntLit`、`FloatLit`、`StringLit`、`RawStringLit`、`StringInterpStart`、`StringInterpMiddle` 与 `StringInterpEnd` 是词法 token 类别。`'type'`、`'self'`、`'alias'`、`'generate'`、`'scoped'` 与 `'call'` 表示相同拼写的 contextual `Ident`；其余单词终结符是保留关键字。

## Program 与声明

```ebnf
Program          ::= FileRequires? UseDecl* ModuleItem*
FileRequires     ::= 'requires' EffectSet ';'
ModuleItem       ::= Decl | GenerateItem
GenerateItem     ::= 'generate' Ident Block

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

FnDecl           ::= 'const'? 'fn' Ident CallableParams? '(' BodyParams? ')'
                     BodyReturn? EffectAnnotation? Block
BodyParams       ::= BodyParam (',' BodyParam)* ','?
BodyParam        ::= Ident (':' ParamType)?
ParamType        ::= EscapeQual? ParamMode? ParamAnnotation
ParamAnnotation  ::= TypeExpr | ShapeExpr
BodyReturn       ::= '->' (TypeExpr | '(' ShapeExpr ')')

FixedParamMode   ::= '&' 'mut'? | 'move'
ParamMode        ::= FixedParamMode | 'call'
EscapeQual       ::= 'scoped'

SignatureParam   ::= Ident ':' EscapeQual? ParamMode? TypeExpr
FixedSignatureParams ::= FixedSignatureParam (',' FixedSignatureParam)* ','?
FixedSignatureParam ::= Ident ':' EscapeQual? FixedParamMode? TypeExpr
SignatureReturn  ::= '->' TypeExpr

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
                     WhereClause? '{' TraitImplMember* '}'
WhereClause      ::= 'where' WherePredicate (',' WherePredicate)* ','?
WherePredicate   ::= TypeExpr ':' TraitBound ('+' TraitBound)*
InherentImplMember ::= Visibility? FnDecl
                     | Visibility? ImplAssocType
TraitImplMember  ::= FnDecl | ImplAssocType
ImplAssocType    ::= 'type' Ident '=' TypeExpr ';'

TraitDecl        ::= 'trait' Ident TypeParams? Supertraits?
                     '{' TraitMember* '}'
Supertraits      ::= ':' TraitBound ('+' TraitBound)*
TraitMember      ::= TraitMethodSig | TraitAssocType
TraitMethodSig   ::= 'fn' Ident CallableParams? '(' TraitParams? ')'
                     SignatureReturn? EffectAnnotation? ';'
TraitParams      ::= TraitParam (',' TraitParam)* ','?
TraitParam       ::= 'self'
                   | SignatureParam
TraitAssocType   ::= 'type' Ident AssocBounds? ('=' TypeExpr)? ';'
AssocBounds      ::= ':' TraitBound ('+' TraitBound)*

EffectDecl       ::= 'effect' Ident TypeParams? '{' EffectOp* '}'
EffectOp         ::= 'fn' Ident '(' FixedSignatureParams? ')'
                     SignatureReturn ';'
EffectAliasDecl  ::= 'effect' 'alias' Ident TypeParams? '=' EffectSet ';'

ExternDecl       ::= 'extern' ExternKind
ExternKind       ::= 'fn' Ident CallableParams? '(' FixedSignatureParams? ')'
                     SignatureReturn? EffectAnnotation ';'
                   | 'type' Ident TypeParams? ';'

TypeAliasDecl    ::= 'type' Ident TypeParams? '=' TypeExpr ';'
ConstDecl        ::= 'const' Ident (':' TypeExpr)? '=' Expr ';'
ModDecl          ::= 'mod' Ident ('requires' EffectSet)?
                     '{' UseDecl* ModuleItem* '}'

UseDecl          ::= Visibility? 'use' Path UseSuffix? ';'
UseSuffix        ::= 'as' Ident
                   | '::' '{' UseItems? '}'
UseItems         ::= UseItem (',' UseItem)* ','?
UseItem          ::= Ident ('as' Ident)?
```

文件 `requires` 必须是第一项非注释语法且每文件至多一个；随后所有 `use` 必须先于 module item。inline `mod` 内同样先列 `use`。普通声明与 `generate` item 可以按源码次序交错；`generate` 没有 visibility 或尾分号，也不进入函数 `Block`。路径与模块的名称解析约束见[模块系统](modules.md)。

`generate ctx { ... }` 中的 `generate` 只在 module-item 起点按 contextual spelling 识别，`ctx` 是该请求的 source binder，block 复用普通 `Block` AST。Parser 只保存结构，不执行 block，也不判断其 return/effect。`fn generate`、`let generate` 和包含 `generate`／`scoped`／`call` 的普通路径仍合法；`gen` 不是别名。

无 body 的 file `requires`、`use`、type alias、const value、effect alias、`extern fn`、`extern type`、trait method signature、associated type declaration/assignment 与 effect operation 都必须以 `;` 结束。带 body 的 `fn`、`generate`、`struct`、`enum`、`impl`、`trait`、`effect` 和 inline `mod` 后面不写 `;`。Struct field 与 enum variant 由逗号分隔，最后一项可带 trailing comma；effect operation 不接受逗号代替分号。

```vorton
requires {unsafe};
use geometry::{Point, distance};

type Length = Float;
const origin: Point = Point { x: 0.0, y: 0.0 };
extern fn host_distance(left: Point, right: Point) -> Float with {unsafe};

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

Impl block 本身没有 visibility，因此 `pub impl Value {}` 非法；只有 inherent impl member 可以逐项加 `pub`。`const fn` 只允许在 top-level／inline 的具名有-body函数、inherent method 与 trait impl method；`pub const fn` 复用普通 visibility，trait impl member 仍不得写 `pub`。`const` 后的下一 token 是 `fn` 时进入该产生式，否则进入 const value。Trait declaration signature、`extern fn` 与 closure 不接受 `const`。Source trait method 只有以 `;` 结束的签名，`fn method(...) { ... }` 在 trait declaration 中非法。函数默认参数、impl-member `extern fn`、`delegate` 与 `sig` 均没有产生式。

### 参数、receiver 与 closure capture

有 body callable 的入口 mode 由后续 Checker 从真实用途推断；源码 mode 是可省略的 assertion，不改变结果。固定 mode 写作 `item: &Item`、`item: &mut Item` 或 `item: move Item`；旧 `item: mut Item` 非法。`&` 只在这里选择 borrow，不进入普通类型或表达式。

普通 callback 参数还可写 `item: call F`。它保存对同一实际 `F` 的调用能力选择，不是第四种 runtime 访问权限；其 Fn／FnMut／FnOnce 关系由类型检查处理。`call` 只用于有 body 的普通函数／method／closure 参数、trait method 的非-receiver参数，以及 `ShapeParam`。Receiver、`extern fn`、effect operation 与 handler parameter 只接受固定 mode。Call-site assertion 与 capture 继续只接受各自产生式中的 `mut`／`move`，不复用参数的 `&` 或 `call`。

`scoped` 位于 mode 之前，例如 `callback: scoped &F`、`callback: scoped call F`。它只在后面仍有合法 mode／annotation 时作为限定；`value: scoped`、`value: call` 与 `value: call::Type` 仍是普通实际类型。`scoped` 可用于上述具名参数和 `ShapeParam`，不进入普通 `TypeExpr`、capture mode 或 effect atom。

有 body 的普通函数、inherent/trait impl method 与 closure 可以省略普通参数 annotation；也可在直接参数位置写实际 `TypeExpr` 或 `ShapeExpr`。无 body 的 trait method、`extern fn` 与 effect operation 必须写实际 `TypeExpr`，匿名 shape 要改为显式 `F` 及 generic bound；trait receiver 可以单独写作 `self`，其声明类型为 `Self`。Receiver 即使带 annotation 也只接受固定 mode。Trait method 与 `extern fn` 省略返回类型都表示 `Unit`；effect operation 仍必须写返回类型。`extern fn` 必须写外层 `with`，pure 声明写作 `with {}`。

Closure capture list 只属于 closure literal，并固定写在参数列表之前：

```vorton
let update = fn [mut counter: Int, name: Str](step: &Int) {
    counter = counter + step;
    print(name);
};
```

`fn(step) [mut counter] { ... }` 非法。capture list 可完全省略并由编译器推断；它不进入 callable shape，不改变函数类型相等性或调用签名。所有显式 parameter/capture assertion 都必须与推断结果一致；不一致必须产生诊断。

## Path、类型与 effect

```ebnf
Path             ::= PathSegment ('::' PathSegment)*
PathSegment      ::= Ident | 'super'

TypeExpr         ::= NamedType | GroupedType | TupleType
NamedType        ::= Path TypeArgs?
GroupedType      ::= '(' TypeExpr ')'
TupleType        ::= '(' TypeExpr ',' TypeExpr (',' TypeExpr)* ','? ')'

ShapeExpr        ::= CallableShape | '(' ShapeExpr ')'
CallableShape    ::= 'fn' '(' ShapeParams? ')' '->' TypeExpr
                     EffectAnnotation?
ShapeParams      ::= ShapeParam (',' ShapeParam)* ','?
ShapeParam       ::= EscapeQual? ParamMode? TypeExpr

TypeParams       ::= '<' TypeParam (',' TypeParam)* ','? '>'
TypeParam        ::= Ident (':' GenericBound ('+' GenericBound)*)?
GenericBound     ::= NamedType | ShapeExpr
TraitBound       ::= NamedType
CallableParams   ::= '<' TypeParam (',' TypeParam)*
                     (',' EffectParam (',' EffectParam)*)? ','? '>'
                   | '<' EffectParam (',' EffectParam)* ','? '>'
EffectParam      ::= 'effect' Ident
TypeArgs         ::= '<' TypeArgument (',' TypeArgument)* ','? '>'
TypeArgument     ::= TypeExpr | AssocTypeBinding
AssocTypeBinding ::= Ident '=' TypeExpr

EffectAnnotation ::= 'with' EffectSet
EffectSet        ::= '{' (EffectExpr (',' EffectExpr)* ','?)? '}'
EffectExpr       ::= Path EffectApplyArgs?
                   | 'mut'
                   | 'unsafe'
EffectApplyArgs  ::= '<' TypeExpr (',' TypeExpr)*
                     (',' EffectRowArg (',' EffectRowArg)*)? ','? '>'
EffectRowArg     ::= 'effect' EffectSet
```

`CallableParams` 只属于具名 callable：top-level/inline `FnDecl`、inherent/trait impl method、trait method signature 和 top-level `extern fn`。普通 type parameters 必须排在所有 `effect E` parameters 之前。Struct、enum、trait/impl 声明头、effect/effect alias、type alias、`extern type`、`CallableShape` 与 closure 不接受 effect parameter binder。

在 effect row 内，已绑定的 `E` 表示整条 row，因此 `{E, fs}` 合并 `E` 的内容与 `fs`。显式方法 scheme application 使用：

```vorton
TraitPath::method<
    SelfActual,
    trait_type_actuals,
    method_type_actuals,
    effect {row_actuals}
>
```

Type actual 必须全部位于 `effect { ... }` actual 之前；第一个 type actual 是 `SelfActual`。`EffectApplyArgs` 同时承载普通 effect 的既有 type arguments 和这种 method scheme application；名称解析后，普通 effect 不接受 row actual。Row actual 可以包含当前 effect formals、既有 effect atom 和嵌套的确定 method scheme application。Callable shape、closure、effect operation 与 effect alias 不获得独立 effect binder 或匿名 effect 函数。这里的 `<...>` 只属于 effect expression；value call 仍从 receiver/arguments 推断 type/effect actual，不增加 turbofish 或显式 generic-call arguments。

`GroupedType` 是透明分组：`(T)` 与 `T` 表示同一类型，且可以嵌套。它不创建名义类型或单元素 tuple。`TupleType` 仍至少包含两个元素；`(T,)` 与 `()` 都不是合法类型，单位类型写作 `Unit`。

`CallableShape` 是对一个实际 callable 类型的直接约束，不是普通存储类型。它只可直接出现在有 body 的参数 annotation、具名／closure factory 的带括号返回 assertion，以及 `GenericBound`。Shape 的每个参数和结果本身都必须是实际 `TypeExpr`；匿名 shape 不能递归放入 type argument、field、type alias、无 body signature、shape 参数或 shape 结果。复杂高阶关系使用显式 `F`／`G` 与各自 shape bound。

Factory 返回 shape 必须整体带括号，因此 `-> (fn() -> Int)` 合法而 `-> fn() -> Int` 非法。无 body signature 的返回始终是实际 `TypeExpr`；需要 callable 结果时显式返回 `F` 并为 `F` 写 generic bound。普通 grouped type 继续透明但由 AST 保留分组 carrier。

`with` 始终归属最近的 callable。组内 `CallableShape` 的 `EffectAnnotation` 属于 shape；分组闭合后，外层 `EffectAnnotation` 才属于具名函数或 closure。例如 `fn make() -> (fn() -> Int with {fs}) with {} {}` 的 `{fs}` 属于返回 shape，`{}` 属于 `make`。省略 annotation 与显式 `with {}` 保持不同的 source 信息；没有 `with infer` 或其他与省略同义的 marker。Effect operation 没有外层 `EffectAnnotation`。

Trait impl 的 `where` 只接受非空的一阶合取。Predicate subject 是实际 `TypeExpr`，可为 tuple 或 associated projection；每个 bound 仍是 `NamedType`。多个 predicate 由逗号分隔并可带 trailing comma。其它 declaration family 没有 `where` 产生式。

Canonical 0.1 不提供结构化 record 类型；封闭 `{ x: Int }` 与开放 `{ x: Int, ..r }` 在所有 `TypeExpr` 位置均非法。该排除不影响花括号承载的 effect set、block、named construction 与 pattern。

所有命名类型、value path、named-field construction 与 pattern path 都使用统一 `Path`；大小写不参与分类。`super` 的合法层级，以及 path 开头 contextual `self::` / `root::` 的含义由模块解析检查，而非 Lexer 按字符类别区分；`root` 不新增 lexer token。

`Option<T>` 是唯一 Option 类型拼写，类型产生式不含 postfix `?`：

```vorton
let item: Option<Int> = Option::Some(1);
let value = item?;
```

第二行的 `?` 是 expression postfix，不是类型缩写。`Int?` 在类型位置非法。Callable shape 的 mode 写在未命名实际类型前，如 `fn(&List<Int>, move File) -> Unit`；capture list 永不出现在 shape 中。

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
CallArg          ::= Expr | CallAssertMode PlaceExpr
CallAssertMode   ::= 'mut' | 'move'

ControlHead      ::= Expr  (* 禁止 delimiter depth 0 的 NamedConstruct *)
IfExpr           ::= 'if' ControlHead Block
                     ('else' (IfExpr | Block))?
MatchExpr        ::= 'match' ControlHead MatchBody
MatchBody        ::= '{' MatchArm* '}'
MatchArm         ::= OrPattern Guard? '=>' Expr ','?
Guard            ::= 'if' Expr
HandleExpr       ::= 'handle' Block 'with' HandlerBody
HandlerBody      ::= '{' Handler* '}'
Handler          ::= Path '.' Ident '(' HandlerParams? ')' '=>' Expr ','?
HandlerParams    ::= HandlerParam (',' HandlerParam)* ','?
HandlerParam     ::= Ident (':' EscapeQual? FixedParamMode? TypeExpr)?
ClosureExpr      ::= 'fn' CaptureList? '(' BodyParams? ')'
                     BodyReturn? EffectAnnotation? Block
CaptureList      ::= '[' CaptureParams? ']'
CaptureParams    ::= CaptureParam (',' CaptureParam)* ','?
CaptureParam     ::= CaptureMode? Ident (':' TypeExpr)?
CaptureMode      ::= 'mut' | 'move'
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

`mut`/`move` 后必须匹配 `PlaceExpr`；`transfer(mut make_state())`、`transfer(move (file))` 等非-place operand 在语法阶段拒绝。`&` 与 `call` 不属于 call-site assertion。Assertion 不覆盖被调函数推断出的真实 mode，不匹配时按标注失真处理。

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
                   | QualifiedBinding
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
QualifiedBinding ::= BindingQualifier Ident
BindingQualifier ::= 'mut' | 'move'
```

一个 bare single-segment `PathPattern` 可由 Resolver 归为 binding 或零字段 variant；这一决定依据可见声明，不依据首字母大小写。带 `()` 或 `{}` 的 path 是 constructor-shaped pattern，owner identity同样留给 Resolver。Named pattern 支持 field punning 和末尾 `..`。

`QualifiedBinding` 只在 `match`／`catch`／`if let` 的 binding 位置及其 tuple／constructor 子模式中成立。它限定一个普通 binding 名，不能限定 `_`、literal、qualified path、整个 tuple／constructor，或形成 `mut field` 形式的 named-field punning；后者若需限定必须写 `field: mut name`。`LetDestructStmt` 递归排除 `QualifiedBinding`，`ForBinding` 也不扩展。详细绑定、or-pattern 与穷尽性规则见[模式匹配](patterns.md)。

## 明确排除的 0.1 表面

以下形式没有 canonical 产生式，只能在文档中作为非法反例出现：

```vorton
let invalid: Int? = Option::None;            // 非法：类型只能写 Option<Int>
fn invalid(mut value) { value = 1; }         // 非法：binder-prefix mode
fn invalid(mut self) {}                      // 非法：receiver-prefix mode
fn invalid(value: mut Int) {}                // 非法：旧 typed-mut parameter mode
type Invalid = fn(Int) -> Int;               // 非法：shape 不是普通存储类型
pub generate ctx {}                          // 非法：generate 没有 visibility
let invalid = fn(x) [move resource] { x };   // 非法：capture list 在参数之后
test "name" {}                               // 非法：没有 native-test 声明
#[test] fn probe() {}                         // 非法：'#' 不是 token
@derive(Json)                                // 非法：'@' 不是 token
pub impl Value {}                            // 非法：impl block 无 visibility
struct Invalid<effect E> {}                 // 非法：nominal header 无 effect binder
extern fn invalid(value: Int);              // 非法：extern 必须写外层 with
```

同样非法的还有缺失必需 `;` 的普通 statement/无 body declaration、以逗号结束的 effect operation，以及带 body 的 source trait method。Parser 不建立 compatibility mode、feature flag、Attribute/Derive 节点或 future hook。
