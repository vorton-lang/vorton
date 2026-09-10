# 模块系统

Vorton 的每个库由 file source 与 inline `mod` 组成一棵逻辑模块树，多个库由宿主提供的直接依赖 DAG 组成一次项目输入。`requires`、`use`、inline `mod` 与 path 的唯一产生式见[语法](syntax.md)；本页只定义解析后的库／模块身份、可见性、导入与项目闭包语义。

## 项目输入与模块身份

Compiler library 接受一个显式、纯内存的库图：

```rust
pub struct LibraryId(pub u32);

pub struct LibrarySources {
    pub root: String,
    pub modules: BTreeMap<FileModulePath, String>,
    pub dependencies: BTreeMap<String, LibraryId>,
}

pub struct ProjectSources {
    pub entry: LibraryId,
    pub libraries: BTreeMap<LibraryId, LibrarySources>,
}
```

`LibraryId` 由宿主为本次输入指定，只区分库实例。它不是依赖别名、包名、版本、文件路径或 Compiler 按遍历顺序分配的 ordinal；不同输入中相同数值不承诺代表同一版本。一个 key 只有一份 `LibrarySources`，多条边指向同一 key 时消费同一库实例；源码相同但 ID 不同仍是两个库。

`dependencies` 的 key 是所属库选择的直接依赖别名，value 必须是 `libraries` 中的真实库。别名是单个 ASCII `Ident`，不能是保留关键字或 `self`、`super`、`root`；contextual `type`、`alias`、`generate`、`scoped`、`call` 与 `_` 的既有规则保持。别名不是 OS 地址或联网定位信息，之后仍按 root Type namespace 的保留名与冲突规则检查。

Resolver 在读取 source 前验证整个显式图：`entry` 必须存在，所有别名必须合法，所有 target 必须存在，依赖图必须无环；自依赖同样拒绝。结构化 input diagnostic 记录实际 entry，或 owner／alias／target，或首个稳定的实际循环链，不虚构 source span。缺 entry 最先；其余别名与缺失引用先于库环，同类按 `LibraryId` 与别名的确定顺序选择。

只有从 `entry` 沿显式依赖边可达的库进入解析结果，但不可达库的依赖图仍必须结构合法。每个可达库的 root 都会解析，即使所属 dependency alias 没有在 source 中使用。字符串碰巧等于某个 ID 或其它库的别名不会增加边。

每个库的 `modules` 以非空 identifier segment 序列为 key。Key 是该库内大小写敏感的抽象地址，不是文件名、扩展名、工作目录或操作系统路径。宿主负责把实际文件投影为这个输入；目录遍历、cwd、symlink、扩展名补全和 OS 错误不属于语言或 Resolver。

File source key 的每个 segment 必须符合 ASCII `Ident` 字符规则，且不能是保留关键字或 `self`、`super`、`root`。Contextual `type`、`alias`、`generate`、`scoped`、`call` 与 `_` 仍可作 segment。平台文件名冲突由宿主 adapter 处理。

Key 的目录前缀形成没有 source body 的 synthetic module。例如某库仅提供 `parser::lexer` source 时，`parser` 仍是该库内可寻址的 module。一个路径可以同时拥有 body 和 child：`parser` 与 `parser::lexer` 可以都是 file source。一个库内逻辑路径至多拥有一个 body；file body 与 inline body 撞到同一路径、或两个 inline body 重复声明同一路径时拒绝，不支持 partial module 或静默合并。不同库可以使用相同 key，二者没有 identity 或 source 归属关系。

```text
LibraryId(7) root source
├── parser                 file body 或 synthetic node
│   └── lexer              file body
└── tools                  inline body
```

每个库的 root 本身是 exact module entity。Source module、具名 declaration、owner、generic/local binding 与引用的 identity 包含所属 `LibraryId` 和完整逻辑 module path；不同库中 path、source、span 与 leaf spelling 都相同也不能合并。Language declaration 保持独立 `Language` origin，不伪装成某个 source library。Target symbol encoding 不是 module identity。

## 可达 source

Compiler 先解析所有可达库各自的 root。之后每个库只有通过该库已解析 source 中实际 `use` / `pub use` 路径可达的 file body 才被解析；同一已解析 source 内的全部 inline module 一并进入该库闭包。依赖边已经使目标库 root 进入闭包，不需要 source `use` 才启动该库。

库的 source 闭包只由自己的输入与上述规则决定。Consumer 的 `use` 只能消费依赖库已经闭合的 public 名称和 module export，不能打开依赖库尚未到达的 file body，也不能因 caller 不同形成另一套声明集合。库要让某个 file body 参与解析，由自己的 `use` / `pub use` 令它可达；随后 public 内容再按正常 module path 与 export 规则消费。

可达解析先于 import 唯一性：`use` path 触达的每个 module candidate 都先加入 frontend 解析闭包，随后才在完整候选集上检查歧义。例如 module 与 function 同名导致该 import 最终歧义时，被 path 触达的 module source 若有 Lexer/Parser 错误，仍先返回该 source 的 frontend diagnostic。

未达 file body 不执行 Lexer、Parser 或语义检查，因此其中的坏源码不影响当前库闭包。普通表达式、类型或 pattern 中的限定 path 不能触发 source 载入；需要 file body 时必须由所属库的实际 import/re-export 令它可达。一个库的 path 永远不能载入另一个库中相同 key 的 source。

## Path 起点

路径规则对 file 与 inline module 完全一致：

- 裸 path 从当前源码所属库的当前逻辑 module 出发；
- `self::` 明确从当前 module 出发；
- 一个或多个 `super::` 逐级从逻辑父 module 出发，越过所属库 root 报错，不能进入依赖方或项目 entry；
- contextual `root::` 从当前源码所属库的 root 出发。`root` 仍是普通 `Ident` token，不新增 lexer token。

```vorton
use parser::Token;
use self::helpers::format;
use super::shared::Config;
use root::platform::clock;
```

`LibraryId` 没有 source 拼写，也不能作为 path escape。每个直接依赖别名只在所属库的 root 建立一个默认不公开的 Type-namespace module binding，指向目标库的真实 root；它不把目标声明注入本地，也不向每个 child module 复制 alias table。Root source 可直接使用别名，child module 通过 `root::alias` 到达：

```vorton
use model::Config;

mod feature {
    use root::model::Config;
}
```

限定 path 可跨 file/inline 边界。Resolver 对每个适用 namespace 先取得词法上最内层的 binding，再按 root、每个 `::` container 与 terminal category 筛选并合并候选。同 namespace 不回退被 generic/local 遮蔽的外层 declaration；另一个 namespace 中不符合该语法的 candidate 也不能抢占合法 module、type 或 value。

Lexical/nominal root 与已知 declaration 必须 exact。Enum constructor 等当前语法要求从闭合 owner 集合中选择的 member 缺失或类别错误时立即拒绝。只有 field/method receiver、generic/`Self` 的 associated item、适用 impl 等确实依赖 Checker 类型信息的选择才保留显式 obligation；它保存 occurrence 与所有已知 exact base/owner，不伪造 target。Effect declaration、effect alias 与 Language effect 不能冒充 Type/Value 的 type-relative `::` base。

## 导入与别名

直接依赖别名本身不自动成为 public export。它可以像真实 module target 一样用现有 `use`、`as` 与 `pub use` 导入或显式 re-export；普通 `use` 不构成重导出。Consumer 不能看到依赖的 private dependency alias，不能凭输入图中存在某个节点使用传递依赖，也不能绕过 facade 访问 private declaration。依赖别名与 root 中同名 module、type、trait 或 import 使用现有 Type namespace 冲突规则，不选择某一方覆盖另一方。

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

未标 `pub` 的 declaration 只对同一库内的 owner module 及其 descendants 可见；另一个库中相同或更深的 module path 不取得 descendant 权限。跨库访问只能经过真实 public export。File module 和 synthetic prefix 没有隐含 private/pub 文件属性，但其 body 必须先由所属库自己的 source 闭包到达；inline module 的 visibility 由其 declaration 决定。

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

库 root 与 re-exported dependency root 都是 exact module target。显式 module facade 只公开该 target 中真实 public 且已经进入其所属库闭包的内容；root entity 不使 private declaration 或 private dependency alias 自动公开。

Public constructor export 必须保持 owner closure：当前 facade 的最终 public Type exports 中必须包含 constructor 的 exact owner enum。Owner 与 constructor 可由不同 import、使用不同 alias、按任意声明顺序送达；缺 owner 时在 constructor re-export 处报错，Compiler 不会自动 re-export owner。

```vorton
pub use root::leaf::Shape as PublicShape;
pub use root::leaf::Shape::{Circle as MakeCircle}; // 合法
```

Public struct 的 private field 可以包含 private nominal type；外部 source 可以持有该 public value，但不能访问 private field 或命名 private representation。Public signature、pub field 与 public enum payload 的完整 interface visibility 由 Checker 在类型信息完备后检查。

## Inline `mod` 与 capability

Inline module 可嵌套，并可在开头的全部 `use` 之后包含普通 declaration 与 `generate` module item：

```vorton
mod math requires {} {
    pub fn add(left: Int, right: Int) -> Int { left + right }

    pub mod integer {
        pub fn twice(value: Int) -> Int { super::add(value, value) }
    }
}
```

File body 的第一项 `requires {effects};` 与 inline `mod name requires {effects}` 都给 module 设置 effect ceiling。省略 ceiling 时普通 system/handled/fail/mut 不增加额外限制，但 `unsafe` 许可从不隐式获得。`requires {}` 只允许 pure computation；单一 `mut` marker 对 caller/capture state 的修改参与 ceiling，局部 `let mut` rebind 仍保持局部。Extern declaration 与 unsafe primitive 还必须满足 [Effect 规范](effects.md)中的专用规则。

## Module graph 与 ResolvedAST

Resolver 在一个 owned 结果中保留 entry 与可达的直接依赖图，统一闭合这些库的 module graph、declaration index 和 import/export fixed point，再执行 body-name 检查。可以按依赖顺序消费已经闭合的名称 export，但不各跑一次单库 Resolver 后拼接结果。一个库内部的普通 module 可以相互引用，包括父 module 令 child source 可达、child 引用父 declaration；库依赖必须是 DAG 不会禁止这些库内回边。只要每条 import 最终唯一到达真实 source 或 Language entity，module 回边本身不是错误。

当前 generation 阶段尚未接入 `resolve_project`。全部可达库的全部可达 source 通过 frontend 且 module graph 已检查后，只要 inventory 含 `GenerateItem`，入口就在 declaration index／import／body-name 之前返回 generation-stage unsupported 诊断，绝不返回伪完整 `ResolvedProject`。依赖库 root 中的请求即使未被 consumer `use` 也会拒绝；未达 file source 与不可达库不扫描。多个请求按 `LibraryId`、logical module path、`generate` keyword 的 UTF-8 span 与稳定错误规则选首个。该临时拒绝只描述当前 stage 边界，generation 实现接入时由对应合同移除。

仅由 import/re-export 相互转发、没有任何真实 declaration origin 的无解环仍报错。该规则不放宽 effect alias 循环、trait 继承循环或 Checker 中其他非法递归。

ResolvedAST 为每个 source module、lexical/nominal declaration、owner、generic/local binding、import 与引用保存含 `LibraryId` 的 exact identity。Re-export 转发原 identity；同一声明经 dependency diamond 多次送达仍幂等，不同库的声明即使文本相同也不合并。Language entity 使用独立 Language origin，不伪装成隐藏 source library。依赖类型的 member/associated selection 保存 occurrence、已知 exact base/owner、选择 spelling 及其正确库来源，留给 Checker 冻结最终 target。ResolvedAST 之后不得重新 parse 或执行第二套 lexical resolver。

项目每次只返回一个结构化首错，不暴露 partial ResolvedAST。阶段优先级依次为库图输入、全部可达 source frontend、module graph、当前 generation-stage support、declaration/index、import/export 与 body-name；source 阶段同类错误按 `LibraryId`、logical module path、primary UTF-8 byte span 与稳定错误类别排序。普通 primary/related origin 均为 `LibraryId + SourceRef + UTF-8 byte span`。物理 source key、名称 spelling、map 插入顺序、拓扑遍历、table/subpass 或全局计数器不能改变结果；related origins 同样保持稳定顺序。

## 0.1 限制

- 不支持 first-class module；
- 不支持 glob import；
- 不支持 scoped visibility；
- 不提供 `sig` declaration 或 module-signature conformance；
- Compiler library 不提供 OS loader、package manager 或 source discovery adapter。
- 依赖别名只表达宿主已经给定的直接边，不提供 package registry、版本选择或联网解析。
