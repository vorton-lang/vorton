# 模块系统

Vorton 的 file source 与 inline `mod` 共同组成一棵逻辑模块树。`requires`、`use`、inline `mod` 与 path 的唯一产生式见[语法](syntax.md)；本页只定义解析后的模块身份、可见性、导入与项目闭包语义。

## 项目输入与模块身份

Compiler library 接受一个纯内存项目：匿名根 source，以及以非空 identifier segment 序列为 key 的 file sources。Key 是大小写敏感的抽象地址，不是文件名、扩展名、工作目录或操作系统路径。宿主负责把实际文件投影为这个输入；目录遍历、cwd、symlink、扩展名补全和 OS 错误不属于语言或 Resolver。

File source key 的每个 segment 必须符合 ASCII `Ident` 字符规则，且不能是保留关键字或 `self`、`super`、`root`。Contextual `type`、`alias` 与 `_` 仍可作 segment。平台文件名冲突由宿主 adapter 处理。

Key 的目录前缀形成没有 source body 的 synthetic module。例如仅提供 `parser::lexer` source 时，`parser` 仍是可寻址 module。一个路径可以同时拥有 body 和 child：`parser` 与 `parser::lexer` 可以都是 file source。一个逻辑路径至多拥有一个 body；file body 与 inline body 撞到同一路径、或两个 inline body 重复声明同一路径时拒绝，不支持 partial module 或静默合并。

```text
匿名根 source
├── parser                 file body 或 synthetic node
│   └── lexer              file body
└── tools                  inline body
```

Module 与具名 declaration 的 identity 包含完整逻辑 module path；不同 module 中相同 leaf spelling 永不因此合并。Target symbol encoding 不是 module identity。

## 可达 source

Compiler 总是解析匿名根 source。之后只有通过已解析 source 中实际 `use` / `pub use` 路径可达的 file body 才被解析；同一已解析 source 内的全部 inline module 一并进入项目。输入 key 自身的合法性仍属于项目输入检查。

可达解析先于 import 唯一性：`use` path 触达的每个 module candidate 都先加入 frontend 解析闭包，随后才在完整候选集上检查歧义。例如 module 与 function 同名导致该 import 最终歧义时，被 path 触达的 module source 若有 Lexer/Parser 错误，仍先返回该 source 的 frontend diagnostic。

未达 file body 不执行 Lexer、Parser 或语义检查，因此其中的坏源码不影响当前项目闭包。普通表达式、类型或 pattern 中的限定 path 不能触发 source 载入；需要 file body 时必须有实际 import/re-export 令它可达。

## Path 起点

路径规则对 file 与 inline module 完全一致：

- 裸 path 从当前逻辑 module 出发；
- `self::` 明确从当前 module 出发；
- 一个或多个 `super::` 逐级从逻辑父 module 出发，越过匿名根时报错；
- contextual `root::` 从匿名根出发。`root` 仍是普通 `Ident` token，不新增 lexer token。

```vorton
use parser::Token;
use self::helpers::format;
use super::shared::Config;
use root::platform::clock;
```

限定 path 可跨 file/inline 边界。Resolver 对每个适用 namespace 先取得词法上最内层的 binding，再按 root、每个 `::` container 与 terminal category 筛选并合并候选。同 namespace 不回退被 generic/local 遮蔽的外层 declaration；另一个 namespace 中不符合该语法的 candidate 也不能抢占合法 module、type 或 value。

Lexical/nominal root 与已知 declaration 必须 exact。Enum constructor 等当前语法要求从闭合 owner 集合中选择的 member 缺失或类别错误时立即拒绝。只有 field/method receiver、generic/`Self` 的 associated item、适用 impl 等确实依赖 Checker 类型信息的选择才保留显式 obligation；它保存 occurrence 与所有已知 exact base/owner，不伪造 target。Effect declaration、effect alias 与 Language effect 不能冒充 Type/Value 的 type-relative `::` base。

## 导入与别名

### 单 entity 与分组导入

```vorton
use parser::Token;
use parser::{Lexer, parse as parse_token};
```

每个 `use` item 必须跨合法 namespace 唯一对应一个 exact entity。若同一 spelling 同时可指 module、function 或其他不同 entity，单项、分组、alias 与 `pub use` 都报歧义；一次 `use` 不会同时向多个 namespace 注入名称。

### Module-only binding

```vorton
use parser;
use parser as syntax;

fn read(token: syntax::Token) {}
```

`use parser;` 只把 `parser` module 本身绑定到当前 Type namespace，不导入其全部 symbol。Module 可以用 `as` 改名。0.1 没有 glob import。

### Enum constructor

Enum constructor 默认只能由 owner-qualified path 使用：

```vorton
Shape::Circle
Option::Some(value)
Option::None
```

只有显式导入才建立 bare constructor binding：

```vorton
use Shape::{Circle, Rect};
use Option::{Some, None};
```

导入或 re-export enum 本身不会隐式导入、导出或注入其 constructors。

## Namespace 与声明

普通 module scope 有三个 namespace：

- Type：module、struct、enum、type alias、extern type、trait、generic type parameter 与语言预声明 type/trait；
- Value：function、const、extern function、enum constructor，以及 parameter、local/pattern binding；
- Effect：effect declaration、effect alias 与语言 effect binding。

Field、method、associated item 与 effect operation 保持 owner-scoped，不向普通 module scope 隐式注入。Module declaration、普通具名 declaration 与 import 在整个 module scope 可见，因而支持 forward reference。

同一 scope、namespace 与 spelling 若对应不同 exact entity 就冲突。声明顺序、先导入者或后覆盖者都没有优先级。相同 exact origin 经多条 import/re-export path 重复 delivery 是幂等的；不同 alias 可以指向同一 entity。两个 source declaration 始终是不同 declaration，不能用 diamond 规则合并。

## Visibility 与 re-export

未标 `pub` 的 declaration 对 owner module 及其 descendants 可见；其他 module 只能经过可访问的 path 使用 `pub` entity。File module 和 synthetic prefix 没有隐含 private/pub 文件属性；inline module 的 visibility 由其 declaration 决定。

```vorton
pub fn greet() -> Str { "hello" }
pub struct Point { pub x: Int, y: Int }
```

合法 `pub use` facade 可以公开 private module 中的 `pub` item，但不能把 private item 变成 public：

```vorton
pub use hidden::greet;

mod hidden {
    pub fn greet() -> Str { "hello" }
}
```

Public constructor export 必须保持 owner closure：当前 facade 的最终 public Type exports 中必须包含 constructor 的 exact owner enum。Owner 与 constructor 可由不同 import、使用不同 alias、按任意声明顺序送达；缺 owner 时在 constructor re-export 处报错，Compiler 不会自动 re-export owner。

```vorton
pub use root::leaf::Shape as PublicShape;
pub use root::leaf::Shape::{Circle as MakeCircle}; // 合法
```

Public struct 的 private field 可以包含 private nominal type；外部 source 可以持有该 public value，但不能访问 private field 或命名 private representation。Public signature、pub field 与 public enum payload 的完整 interface visibility 由 Checker 在类型信息完备后检查。

## Inline `mod` 与 capability

Inline module 可嵌套，并可包含全部普通 declaration family：

```vorton
mod math requires {} {
    pub fn add(left: Int, right: Int) -> Int { left + right }

    pub mod integer {
        pub fn twice(value: Int) -> Int { super::add(value, value) }
    }
}
```

File body 的第一项 `requires {effects};` 与 inline `mod name requires {effects}` 都给 module 设置 effect ceiling。省略 ceiling 时普通 system/handled/fail/mut 不增加额外限制，但 `unsafe` 许可从不隐式获得。`requires {}` 只允许纯 computation；`mut<T>` 对 caller/capture state 的修改参与 ceiling，局部 `let mut` rebind 仍保持局部。Extern declaration 与 unsafe primitive 还必须满足 [Effect 规范](effects.md)中的专用规则。

## Module graph 与 ResolvedAST

Resolver 在 body-name 检查前闭合当前可达 module graph、declaration index 和 import/export fixed point。普通 module 可以相互引用，包括父 module 令 child source 可达、child 引用父 declaration；只要每条 import 最终唯一到达真实 source 或 Language entity，回边本身不是错误。

仅由 import/re-export 相互转发、没有任何真实 declaration origin 的无解环仍报错。该规则不放宽 effect alias 循环、trait 继承循环或 Checker 中其他非法递归。

ResolvedAST 为每个 lexical/nominal declaration、binding、import 与引用保存 exact identity。Re-export 转发原 identity；Language entity 使用独立 Language origin，不伪装成隐藏 source。依赖类型的 member/associated selection 保存 occurrence、已知 base/owner 与选择 spelling，留给 Checker 冻结最终 target。ResolvedAST 之后不得重新 parse 或执行第二套 lexical resolver。

项目每次只返回一个结构化首错，不暴露 partial ResolvedAST。阶段优先级依次为项目输入、可达 source frontend、module graph、declaration/index、import/export 与 body-name；同阶段按错误所属 logical module path、primary UTF-8 byte span 与稳定错误类别排序。物理 source key、名称 spelling、table/subpass 或遍历偶然性不能改变结果；related origins 同样保持稳定顺序。

## 0.1 限制

- 不支持 first-class module；
- 不支持 glob import；
- 不支持 scoped visibility；
- 不提供 `sig` declaration 或 module-signature conformance；
- Compiler library 不提供 OS loader、package manager 或 source discovery adapter。
