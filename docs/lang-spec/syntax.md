# 语法

Ring 的完整 EBNF 文法。产生式按类别分组。可选元素用 `?`，重复用 `*`（零或多个）和 `+`（一或多个）。终结符用 `'单引号'` 括起。

## 程序

```ebnf
Program      ::= FileRequires? UseDecl* Decl*
FileRequires ::= 'requires' EffectSet
```

文件是一个隐式模块。可选的 `requires {effects}` 文件头必须是第一项非注释语法、每文件至多一次；其后是一系列 `use` 声明和其他声明。`use` 声明仍必须出现在所有普通声明之前。文件头与 inline `mod name requires {effects}` 使用同一 capability 语义，详见[模块系统](modules.md#capability-限制requires)。

## 声明

```ebnf
Decl         ::= ImplDecl
               | 'pub'? DeclKind

DeclKind     ::= FnDecl
               | StructDecl
               | EnumDecl
               | TraitDecl
               | EffectDecl
               | EffectAliasDecl
               | ExternDecl
               | TypeAliasDecl
               | TestDecl
               | ConstDecl
               | ModDecl
```

`pub`修饰符控制多文件编译中的可见性。Impl block本身没有visibility，因此`pub impl ...`非法；只有inherent impl member继续允许逐项`pub`。单文件模式仍解析visibility并执行同一语法检查。

### 函数声明

```ebnf
FnDecl       ::= 'fn' Ident TypeParams? '(' Params ')' ('->' TypeExpr)? EffectAnnotation? Block

EffectAnnotation ::= 'with' EffectSet
EffectSet     ::= '{' (EffectExpr (',' EffectExpr)* ','?)? '}'

Params       ::= (Param (',' Param)* ','?)?
Param        ::= 'mut'? Ident (':' TypeExpr)?
```

省略返回类型注解时由推断确定。省略参数类型注解时分配 fresh 类型变量。`mut` 前缀标记参数为可变（允许在函数体内重赋值），也适用于方法的 `mut self`。`with { ... }` 子句声明函数的 effect 签名。

Ring 0.1 不支持函数默认参数；`Param` 后的 `= Expr` 是语法错误。需要默认行为时定义显式 wrapper 函数。该规则不影响 trait method 的默认 body。Effect operation 在 0.1 同样不得带 body，具体边界见下文。

### Struct 声明

```ebnf
StructDecl   ::= 'struct' Ident TypeParams? '{' StructField* '}'

StructField  ::= 'pub'? Ident ':' TypeExpr ','?
```

Ring 0.1 尚未实现 refinement types，字段、参数及其他类型位置均不接受 refinement `where` clause。`where` 在词法层继续保留为未来关键字；出现时必须 hard-fail 并提示删除 clause，不能消费后忽略、降为 warning 或充当 documentation-only annotation。B-001 将来只有在 parser 与实际验证语义原子完成时才重新开放该语法。

### Enum 声明

```ebnf
EnumDecl     ::= 'enum' Ident TypeParams? '{' EnumVariant* '}'

EnumVariant  ::= Ident VariantFields? ','?

VariantFields ::= '(' TypeExpr (',' TypeExpr)* ')'                     (* 位置字段 *)
                | '{' NamedField (',' NamedField)* ','? '}'            (* 命名字段 *)

NamedField   ::= Ident ':' TypeExpr
```

无字段的变体是 unit 变体。位置字段和命名字段变体可在同一 enum 中共存。

### Impl 块

```ebnf
ImplDecl     ::= InherentImplDecl | TraitImplDecl

InherentImplDecl ::= 'impl' TypeParams? Ident TypeArgs? '{' InherentImplMember* '}'
TraitImplDecl    ::= 'impl' TypeParams? Ident 'for' Ident TypeArgs? '{' TraitImplMember* '}'

InherentImplMember ::= 'pub'? FnDecl
                     | 'delegate' Ident ':' Ident (',' Ident)*
                     | 'pub'? AssocTypeDecl

TraitImplMember ::= FnDecl
                  | 'delegate' Ident ':' Ident (',' Ident)*
                  | AssocTypeDecl
```

`impl Type { ... }` 定义固有方法，member可分别`pub`或private。Impl block无visibility，`pub impl ...`是hard error。`impl Trait for Type { ... }`实现trait，全部member visibility继承trait，写`pub`同样hard-error。Ring 0.1不允许impl-member `extern fn`；在inherent或trait impl中写`extern fn`必须于`extern`处hard-fail。用户需要FFI method时使用top-level `extern fn`加普通inherent wrapper；标准库内建方法由编译器的exact intrinsic manifest提供，不形成用户语法。`delegate field: Trait1, Trait2`为每个trait自动生成完整普通impl（替代继承的复用机制）；同一target + trait的手写impl与delegate冲突并报E0509，不支持partial override。关联类型`type Name = TypeExpr`用于满足trait的关联类型要求。

### Trait 声明

```ebnf
TraitDecl    ::= 'trait' Ident TypeParams? (':' TypeBound ('+' TypeBound)*)? '{' TraitMember* '}'

TraitMember  ::= TraitMethod | AssocTypeDecl

TraitMethod  ::= 'fn' Ident TypeParams? '(' Params ')' ('->' TypeExpr)? EffectAnnotation? Block?

AssocTypeDecl ::= 'type' Ident (':' TypeBound ('+' TypeBound)*)? ('=' TypeExpr)?
```

无函数体的方法是抽象方法（必须实现）。有函数体的方法提供默认实现。Supertrait继承通过`:`后的`TypeBound`列表声明（如`trait Ord: Eq`），支持多级传递和循环检测。关联类型通过`type Name`声明，可带bounds约束和默认值。Trait是完整contract：所有member visibility随trait，trait declaration与trait impl member不得单独写`pub`；只有inherent impl保留逐member visibility。

### Effect 声明

```ebnf
EffectDecl   ::= 'effect' Ident TypeParams? '{' EffectOp* '}'

EffectOp     ::= 'fn' Ident '(' Params ')' '->' TypeExpr (';' | ',')?
```

Ring 0.1 的用户自定义 effect operation 只有签名，不允许 body。Custom effect 必须由显式 `handle...with` 提供解释；不存在自动 default evidence、部分默认或默认 body 依赖图。该能力因具有真实抽象价值而保留为 post-0.1 的重新设计议题，但旧实现不得作为兼容路径或直接恢复。

### Effect Alias 声明

```ebnf
EffectAliasDecl ::= 'effect' 'alias' Ident TypeParams? '=' EffectSet
```

Effect alias 给 effect 集合命名，如 `effect alias HostIO = {console, fs, process}` 或 `effect alias Fallible<E> = {fail<E>}`。支持泛型参数、循环检测和 `pub` 模块导出；展开后的 exact effect atoms 才是类型与 inspection 真值。

### Extern 声明

```ebnf
ExternDecl   ::= 'extern' ExternKind

ExternKind   ::= 'fn' Ident TypeParams? '(' Params ')' ('->' TypeExpr)? EffectAnnotation?  (* extern 函数 *)
               | 'type' Ident TypeParams?                                  (* opaque 类型 *)
```

访问宿主的 `extern fn` 必须显式声明其 exact system effect 与正交的 `fail<E>` 契约；省略或写成纯函数不得作为 host operation 的隐式 fallback。具体 system effect 分类见 [Effect 系统](effects.md)。

Top-level `extern fn`声明由目标环境提供实现的函数，类型检查以声明签名为准；它是0.1唯一的用户函数FFI声明位置。`extern type`声明不公开结构的opaque类型；具体ABI与表示不属于语言语法规范。Impl-member `extern fn`不属于`ExternDecl`，必须按上一节hard-fail。

### 类型别名

```ebnf
TypeAliasDecl ::= 'type' Ident TypeParams? '=' TypeExpr
```

### Const 声明

```ebnf
ConstDecl    ::= 'const' Ident (':' TypeExpr)? '=' Expr
```

顶级编译期常量绑定。

### 测试声明

```ebnf
TestDecl     ::= 'test' StringLit Block
```

### Mod 块声明

```ebnf
ModDecl      ::= 'mod' Ident ('requires' EffectSet)? '{' UseDecl* Decl* '}'
```

内联模块块，支持嵌套（`mod a { mod b { ... } }`）。`requires` 子句限制模块内可用的 effect capability。模块内可包含 `use` 声明和任意声明。

### Use 声明

```ebnf
UseDecl      ::= 'pub'? 'use' UsePath UseKind

UsePath      ::= Ident ('::' Ident)*

UseKind      ::= '{' UseItem (',' UseItem)* ','? '}'   (* 分组导入 *)
               | 'as' Ident                             (* 模块别名 *)
               |                                         (* 整模块导入 *)

UseItem      ::= Ident ('as' Ident)?
```

## 类型表达式

```ebnf
TypeExpr     ::= NamedType
               | FnType
               | TupleType
               | RecordType

NamedType    ::= Ident TypeArgs? '?'?

FnType       ::= 'fn' '(' TypeExprList? ')' '->' TypeExpr EffectAnnotation?

TupleType    ::= '(' TypeExpr ',' TypeExprList ')'

RecordType   ::= '{' RecordField (',' RecordField)* (',' '..' Ident)? ','? '}'

RecordField  ::= Ident ':' TypeExpr

TypeExprList ::= TypeExpr (',' TypeExpr)* ','?
```

Ring 0.1不支持return-position`impl Trait`或其他opaque type；`impl`在type position是语法错误。省略返回标注只会推断并保留concrete type，不形成API abstraction。Public interface也不得引用private concrete type；post-0.1的显式opaque return由B-200重新设计。

命名类型的 `?` 后缀是 `Option<T>` 的语法糖：`Int?` ≡ `Option<Int>`。`FnType` 的 `with` 子句标注函数类型的 effect（无标注时为 open row，支持 effect 多态）。

### 类型参数与约束

```ebnf
TypeParams   ::= '<' TypeParam (',' TypeParam)* '>'

TypeParam    ::= Ident (':' TypeBound ('+' TypeBound)*)?

TypeBound    ::= Ident TypeArgs?

TypeArgs     ::= '<' TypeExpr (',' TypeExpr)* '>'
```

类型参数解析使用推测性前瞻：解析器尝试解析 `<Type, ...>`，如果 `<` 实际是比较运算符则回溯。

### Effect 表达式

```ebnf
EffectExpr   ::= EffectName TypeArgs?

EffectName   ::= Ident ('::' Ident)*
               | 'mut'
               | 'unsafe'
```

Effect 表达式用于 effect 标注、effect alias 和 `requires` 子句中。支持限定路径（如 `mod::effect`）和类型参数（如 `fail<Str>`、`mut<List<Int>>`）；裸 `mut` 表示 fresh marker 实例。语义见 [Effect 系统](effects.md)。

## 语句

```ebnf
Stmt         ::= LetStmt
               | LetMutStmt
               | LetDestructStmt
               | IfLetStmt
               | ReturnStmt
               | WhileStmt
               | LoopStmt
               | ForInStmt
               | BreakStmt
               | ContinueStmt
               | AssignStmt
               | ExprStmt
```

### 绑定语句

```ebnf
LetStmt          ::= 'let' Ident (':' TypeExpr)? '=' Expr ';'?
LetMutStmt       ::= 'let' 'mut' Ident (':' TypeExpr)? '=' Expr ';'?
LetDestructStmt  ::= 'let' TuplePattern '=' Expr ';'?
```

`let` 绑定不可变（重赋值报 E0205 错误）。`let mut` 创建可变绑定。

### 控制流语句

```ebnf
IfLetStmt    ::= 'if' 'let' Pattern '=' Expr Block ('else' Block)?

WhileStmt    ::= 'while' Expr Block

LoopStmt     ::= 'loop' Block

ForInStmt    ::= 'for' ForBinding 'in' Expr Block
ForBinding   ::= Ident
               | '(' Ident (',' Ident)+ ')'

BreakStmt    ::= 'break' ';'?
ContinueStmt ::= 'continue' ';'?
ReturnStmt   ::= 'return' Expr? ';'?
```

`break` 和 `continue` 仅在 `while`、`for` 或 `loop` 循环内有效（否则报 E0206 错误）。`loop` 是 `while true` 的语法糖。`for` 接受任何实现了 `Iterable` trait 的类型作为可迭代对象。

### 赋值和表达式语句

```ebnf
AssignStmt   ::= AssignTarget ('=' | '+=' | '-=' | '*=' | '/=' | '%=') Expr ';'?
AssignTarget ::= Ident | Ident ('.' Ident)+
ExprStmt     ::= Expr ';'?
```

赋值目标必须是可变的（`let mut` 绑定、可变参数或其字段等）。0.1 的 index expression 仅可读取；`xs[i] = value`及compound index assignment稳定报错，不按receiver类型隐式改写setter。List mutation使用`xs.set(i, value)`，Map mutation使用`map.insert(key, value)`；完整`IndexMut`不属于0.1语法。

## 表达式

### 求值顺序

同一 evaluation region 内的同级子表达式按源码从左到右求值：callable/receiver 先于 arguments；二元运算数、参数、List/tuple/constructor 字段和字符串插值片段依次求值；index 先 receiver 后 index，range 先 start 后 end。`&&` 与 `||` 先求左侧并短路；条件表达式先求 condition，只求值选中的分支；match 先求 scrutinee，arm 自上而下检查，模式成功后再求 guard。

若任一子表达式产生 `fail`、panic 或 diverge，后续子表达式不再执行。编译器可以重排仅当它证明 effect、mutation、fail/panic、资源 transfer、Drop 时点及结果均不可观察地相同；目标后端自身未规定的 operand / argument order 不改变 Ring 语义。

### 块

```ebnf
Block        ::= '{' Stmt* Expr? '}'
```

块包含零个或多个语句，后跟可选的尾部表达式（无分号）。块的值是尾部表达式的值；无尾部表达式时为 `Unit`。

`unsafe` discharge block 也是表达式：

```ebnf
UnsafeExpr   ::= 'unsafe' Block
```

它只消除 block 内显式产生的 `unsafe` effect，并受模块级 `requires {unsafe}` 许可约束。

### 基本表达式

```ebnf
PrimaryExpr  ::= IntLit | FloatLit | StringLit | RawStringLit
               | 'true' | 'false'
               | InterpString
               | Ident
               | QualifiedVariant
               | StructLit
               | ListLit
               | TupleOrParen
               | Block
               | IfExpr
               | MatchExpr
               | HandleExpr
               | LambdaExpr
               | UnsafeExpr
               | UnaryExpr

QualifiedVariant ::= UpperIdent '::' Ident ArgList?
                   | UpperIdent '::' UpperIdent '{' FieldInit (',' FieldInit)* ','? '}'
```

### Struct 字面量

```ebnf
StructLit    ::= UpperIdent '{' ('..' Expr ',')? FieldInit (',' FieldInit)* ','? '}'

FieldInit    ::= Ident (':' Expr)?
```

大写字母开头的标识符后跟 `{` 触发 struct/变体字面量解析。字段 punning：`{ x }` 是 `{ x: x }` 的语法糖。

`..expr` 前缀是 struct / named enum update 的 **move spread**：基础表达式只求值一次；显式字段 RHS 按源码顺序先全部求值，期间基础值仍可读取或借用；成功后未指定字段从基础值转移到 fresh result，被覆盖的旧字段执行 Drop，最后基础值整体失活。该语法不隐式调用语言级 `.clone()`，也不提供 shareable-only 分支；需要保留基础值时显式使用 `..base.clone()`。在 RHS 中 ownership-move 基础值的子字段会形成 partial move，稳定报错；任一 RHS 失败时不得留下部分 move 的基础值。结果语义上始终是 fresh value，证明基础值物理唯一后允许不可观察的原地复用优化。

### List 字面量

```ebnf
ListLit      ::= '[' (Expr (',' Expr)* ','?)? ']'
```

空列表 `[]` 需要类型上下文推断元素类型（歧义时报 E0301 错误）。

### Tuple 或括号表达式

```ebnf
TupleOrParen ::= '(' Expr ')'                     (* 括号表达式 *)
               | '(' Expr ',' ExprList? ')'        (* tuple，2+ 个元素 *)

ExprList     ::= Expr (',' Expr)* ','?
```

通过第一个表达式后是否有逗号来消歧。不支持单元素 tuple。

### If 表达式

```ebnf
IfExpr       ::= 'if' Expr Block ('else' (IfExpr | Block))?
```

作为表达式使用时，带 `else` 的 `if` 类型为两个分支的统一类型。无 `else` 的 `if` 类型为 `Unit`。

### Match 表达式

```ebnf
MatchExpr    ::= 'match' Expr '{' MatchArm* '}'

MatchArm     ::= OrPattern Guard? '=>' Expr ','?

OrPattern    ::= Pattern ('|' Pattern)*

Guard        ::= 'if' Expr
```

分支从上到下检查。Guard 不影响穷尽性检查。模式语法和穷尽性规则见[模式匹配](patterns.md)。

### Handle 表达式

```ebnf
HandleExpr   ::= 'handle' Block 'with' '{' Handler (',' Handler)* ','? '}'

Handler      ::= Ident '.' Ident '(' Params ')' '=>' Expr
```

每个 handler 绑定 `⟨effect⟩.⟨operation⟩(⟨params⟩)`。被处理的 effect 从 body 的 effect row 中移除。语义见 [Effect 系统](effects.md)。

### Lambda 表达式

```ebnf
LambdaExpr   ::= 'fn' '(' Params ')' ('->' TypeExpr)? Block
```

匿名函数。参数和返回类型注解可选。

### Catch 表达式

```ebnf
CatchExpr    ::= Expr 'catch' '{' MatchArm* '}'
```

捕获 `fail` effect 并用 match-arm 风格的模式匹配分派错误类型。catch arms 经穷尽性检查（非穷尽报 E0601）。结果类型必须与左操作数类型统一。内部用模式匹配分派错误类型；需要部分处理时在 catch 内部 match + re-raise（显式）。

### 后缀表达式

```ebnf
PostfixExpr  ::= Expr '?'              (* option 解包 / fail 传播 *)
               | Expr '.' Ident ArgList (* 方法调用 *)
               | Expr '.' Ident        (* 字段访问 *)
               | Expr '.' IntLit       (* tuple 位置字段访问：.0 .1 .2 *)
               | Expr ArgList          (* 函数调用，同行规则 *)
               | Expr '[' Expr ']'     (* 下标访问 *)

ArgList      ::= '(' (Expr (',' Expr)* ','?)? ')'
```

`?` 后缀对 `Option<T>` 解包 `some` 或传播 `fail`。对带 `fail` effect 的表达式传播错误。下标访问 `list[i]` / `map[key]` / `str[i]` 越界或 key 不存在时 panic，安全访问用 `.get()` 返回 `Option<T>`。

### 二元表达式

```ebnf
BinExpr      ::= Expr BinOp Expr

BinOp        ::= '+' | '-' | '*' | '/' | '%'
               | '==' | '!=' | '<' | '>' | '<=' | '>='
               | '&&' | '||'
```

优先级表见[词法结构](lexical.md)。

### Range 表达式

```ebnf
RangeExpr    ::= Expr '..' Expr        (* 不含右端 *)
               | Expr '..=' Expr       (* 包含右端 *)
```

产生 exact builtin `Range<Int>`。Start 和 end 都必须是 `Int`。

`Range` 是 0.1 type namespace 的内建保留名，而不是 lexer keyword。用户的 struct、enum、extern type、type alias 或 import/re-export 不能在可见 type namespace 绑定 `Range`；冲突在声明或导入处报 `E0207`。普通 value/function namespace 不受此规则影响。

### 一元表达式

```ebnf
UnaryExpr    ::= '-' Expr              (* 数值取反 *)
               | '!' Expr              (* 逻辑 NOT *)
```

## 模式

```ebnf
Pattern      ::= SinglePattern

SinglePattern ::= '_'                                      (* 通配符 *)
               | IntLit | FloatLit | StringLit | BoolLit  (* 字面量 *)
               | Ident                                     (* 绑定或 unit 变体 *)
               | UpperIdent '(' PatList ')'               (* 位置构造器 *)
               | UpperIdent '{' NamedPat* '..'? '}'       (* 命名构造器 *)
               | UpperIdent '::' Ident PatFields?         (* 限定构造器 *)
               | '(' Pattern ',' PatList ')'              (* tuple *)

PatFields    ::= '(' PatList ')'
               | '{' NamedPat* '..'? '}'

PatList      ::= Pattern (',' Pattern)* ','?

NamedPat     ::= Ident (':' Pattern)? ','?
```

`|` 只在 match/catch arm 的最外层 `OrPattern` 中分隔备选模式（如 `A | B => expr`）；它不是通用二元或管道运算符。每个备选可以是 enum 变体、字面量、构造器或绑定模式。**所有备选必须各自恰好一次地绑定相同的非 `_` 变量集合**；同名绑定的类型、可变性与 ownership mode 必须兼容，并在 guard/body 中表示同一个 canonical binding。变量集合不同、单个备选重复绑定同名变量，或同名绑定类型不兼容，均为 E0301。只需合并匹配而不使用不同 payload 时必须写 `_`；需要不同 payload 名时拆成不同 arm。嵌套位置（如 tuple 或构造器字段）不会自行解析 `|`。

与零字段 enum 变体同名的绑定模式会被重分类为构造器模式。命名构造器模式支持字段 punning（`{ x }` ≡ `{ x: x }`）和部分匹配（`..` 忽略其余字段）。

详细绑定规则和穷尽性算法见[模式匹配](patterns.md)。
