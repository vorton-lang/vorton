# Vorton 0.1 语言设计初稿

审阅版 · 2026-09-10

本文按主题整合当前设计，供通读和审阅。它反映已确认的选择，不表示这些能力都已经实现，也不是语言规范或另一份执行合同；可观察规则仍以 [`lang-spec/`](lang-spec/README.md) 为准。设计来源记录在 [Issue #45](https://github.com/vorton-lang/vorton/issues/45) 与 [Discussion #46](https://github.com/vorton-lang/vorton/discussions/46)。

Q84 的具名 callable 泛型显式规则及 Q85–Q87 已确认；源码标注差异的默认诊断与编译期执行的默认额度仍需要真实流程和计数器实测。本文在末尾单独标出 source frontend 已覆盖的部分和仍属于 Checker／generation／native 的设计差距。

## 1. 语言要解决什么问题

Vorton 面向无人回路的开发与演化：程序由人或 LLM 修改时，工具链应提供可靠、可比较的语义事实，让外部 harness 知道代码现在承诺什么、实际满足什么、发生了哪些变化，以及哪些内容无法判断。

它仍是一门 native 语言，面向 CLI、服务端与系统编程；编译器宿主使用 Rust，0.1 继续 C11 输出主路径。采用明确的所有权、确定性资源清理和必要的 RC，不引入强制 GC runtime。Rust 的经验用于设计参照，不构成 Rust 语法、类型系统或 ABI 兼容承诺。

当前设计遵守以下分工：

| 语言工具链 | Harness 与项目工作记录 |
|---|---|
| 按给定源码、契约、依赖检查程序 | 决定为什么改、是否获准、何时接受 |
| 生成可选择的契约候选、导出完整接口 | 选择候选、强度与比较基线 |
| 报告确定的变化、违约与无法判定 | 组织修改、业务验收、合并与发布 |
| 检查公开语义和对应阶段的正确性 | 管理业务意图与工具链未证明的性质 |

契约被修改本身不是语言错误。用新契约检查新实现、用旧契约检查新实现，是两次输入不同的技术检查。是否允许那次契约变更，由 harness 判断。

“低标注”保留为设计偏好：能从实现与明确输入确定的普通类型、mode、effect尽量推断；作者要固定未来承诺时，应有明确表达方式。它不等于所有边界都可以省略信息。具名 callable 自身泛型的显式规则见第4节。

Agent 体工学是明确的设计优先级：在安全、一致、可终止、确定资源和 native 等硬约束内，降低 agent 理解、生成、修改、检查与修复的总成本，同时保留人类对关键变更的审阅能力。低标注只是可调整的局部策略；在没有 agent 性能实测时，不预设更多或更少标注普遍更优。

优化只能在保持可观察语义的前提下进行，包括 Move、别名、修改顺序、failure 前已发生的动作和 Drop。类型与资源规则不因为获得用户授权而被豁免。

## 2. 类型、声明与库

语言采用普通函数、struct、enum、trait 与组合，不引入 class 继承。名义类型按声明身份区分；两个结构相同的 struct 不是同一个类型。透明类型别名可以展开，同一声明的别名或重导出不创建新的实现身份。

基础类型包括 Int、Float、Bool、Unit、Str 等。Int 是有检查溢出的64位整数；数值操作不隐式做跨类型转换。unsafe 不把普通整数运算自动变成 unchecked。具体未改动的词法、运算、路径和控制语法继续按现有规范处理。

可由普通源码表达的 Option、Ordering、比较及资源能力声明进入独立 core。编译器通过指定 core 的真实声明绑定必要语言角色，避免硬编码和源码各维护一份定义。

宿主显式提供完整库依赖图和配套 core。库依赖是 DAG，使用直接依赖与明确导出／重导出；同次构建有一个官方 core。普通 trait impl 按已选择的 coherence 规则检查。内部产物只在匹配工具链与兼容目标配置下复用，不保证跨编译器版本的内部格式兼容。

## 3. 契约是检查的输入

每个对象至多有一份所属库的生效逻辑契约。一份库契约可以覆盖多个对象，也可由多个记录共同表达。调用方读取该库检查后导出的完整接口，不给同一个依赖 API 叠加第二份契约。

契约分为两类条款：

| 条款 | 作用 |
|---|---|
| 设定 type、mode、effect、回调不逃逸等已支持属性 | 在对应语义检查前应用，优先于源码中被选中的普通标注，然后检查函数体 |
| 检查结构、返回 trait、可见性、导出与拒新等性质 | 检查实际目标，不创造缺失声明、提升可见性或偷偷加强输入要求 |

未选择的属性继续由有效源码和正常推断形成。省略不表示空 effect、没有 bound或删除所有旧约束。契约内部冲突直接报错，不按记录顺序覆盖。

泛型结构受第4节的双边显式规则约束，不属于可由普通set任意改造的属性。

目标按本次库输入、逻辑路径、声明类别和真实身份定位。普通参数按调用位置绑定，receiver有独立表示；参数名只是显示信息。改名不改条款位置，插入或重排参数也不会使工具追踪旧变量名。不存在或有歧义的目标不能被静默跳过。

精确类型候选展开透明别名；名义类型保留身份。只检查返回类型的某个trait能力时，允许实现换成另一种满足该trait的实际类型，但完整接口仍报告实际类型变化。条款通过不等于所有旧调用代码都兼容。

候选可以按模块、对象和性质批量选择，并明确选择约束强度。默认不选“拒绝新增接口”；以前保存的筛选条件不会自动把未来匹配对象写入契约。新的公开别名、wrapper或可用impl都属于应报告的接口变化，是否违约由所选条款决定。

版本比较同时保留事实变化与逐条结果：满足、违反、无法判定。确定的违约不能抹掉其他未决项，无法判定也不能当通过。非法源码没有完整接口时，报告实际诊断，不伪造可比较结果。

## 4. 推断与泛型（Q84 已确认）

函数／方法定义在合法边界内保留未来调用的多态性；普通已经求值的数据或factory结果，是本次创建的一个类型实例。后续用途可以帮助推断这个实例，却不能把同一个结果当成多次初始化、不同类型或不同evidence的模板。let mut不泛化。返回的closure即使实际无状态，也不因来自factory而重新泛化。

无契约函数继续遵守原来的HM及上述值实例边界。有契约函数先分为普通与泛型两支。

### 普通函数

| 契约中的类型信息 ＼ 源码中的类型信息 | 无标注 | 具体类型 |
|---|---|---|
| 无标注 | 正常推断，不能增加未声明泛型 | 按源码与正常规则检查 |
| 具体类型 | 按契约提供的类型检查 | 契约覆盖所选普通类型位置，再检查函数体 |

有契约的函数在接口闭合时，若仍需要增加双方未声明的本函数泛型参数，就报错，要求明确具体类型或补齐双边泛型声明。不能静默泛化、默认Any或挑一个调用点的类型发布。

例如：

```vorton
fn identity(x) { x }
```

配输入、输出均为Int的契约，可以形成具体函数。配要求任意T的泛型契约，必须补源码泛型声明。

### 泛型函数

源码与契约都要显式声明泛型，并按目标、所属层级和参数身份一一对应。允许A／T这种纯改名；数量和泛型使用关系须一致。只写一边、合并或拆分变量、把泛型特化为具体类型，都直接报结构不匹配。

对应关系按 target／owner／kind／ordinal 与实际使用关系建立，不按 binder spelling 猜测。`const fn` 与生成目标也遵守同一规则；无 contract 的 generic helper 仍须显式 binder。Concrete actual 可继续推断，outer impl／trait／`Self`、anonymous closure 和一次求值实例边界不因此变成 method 自身的新泛型。

```vorton
fn identity<T>(x: T) -> T { x }
```

可以配同结构的泛型契约；如果body改成仅对Int成立的操作，仍然报错，不能把T缩成Int通过。

普通参数和返回类型标注仍可省略，只要它们能在已显式声明的泛型与所选契约位置中确定。外层impl／trait参数和Self保留原owner，不重复变成method自身参数。多个partial记录先合组，共用同一变量身份。

CallableShape 如果需要额外量化实际类型 F，也按 Q84 显式写出 F；它不获得匿名泛型例外。普通 effect、mode 和既定 trait effect scheme 规则不因本次类型泛型收紧而整体改变。

### 泛型的适用范围

泛型参数声明与generic requirements分别选择：

| 输入 | 检查含义 |
|---|---|
| 不选requirements条款 | 按有效源码和正常规则形成 |
| 显式选择空要求[] | 不许为了函数体通过而新增Clone、Hash等要求 |
| 显式选择P，例如T:Clone | 在P下检查并发布；不得默加Hash，少用P时也不删除P |

空要求不删除外层类型形成、trait或impl条件。已有trait蕴含可使用，例如Copy包含Clone。检查返回trait能力不能为了过关收窄原有输入域。

这条规则的代价是：给隐式泛型函数建立契约时，也要补源码声明。契约候选必须明确指出这个需要，不能自动修改源码或宣称未配套输入已可回放。

## 5. 所有权、参数与有限借用

非Copy值默认Move。Str、List、Rc、Weak不会因为不可变、底层有指针或当前为空就自动Copy。

| 参数写法 | 含义 |
|---|---|
| x或x: T | 有body且未被契约固定时，推断实际类型与入口mode |
| x: &T | 固定只读借入 |
| x: &mut T | 固定独占可变借入 |
| x: move T | 固定拥有移交；Copy类型仍提供副本并保留原值 |
| x: call F | 按同一 F 的 Fn／FnMut／FnOnce evidence 选择固定 Borrow／Mut／Move |

这里的&只表达参数mode，不是一般引用类型或任意位置的借用表达式。0.1不提供能自由返回、放入普通字段或长期保存的通用借用值。

有body的函数按真实用途推断入口需求。无body signature的普通参数必须给出实际类型，省略mode表示固定Borrow；其效果与外部调用责任遵守对应声明规则。

Q85 固定公开输入边界：实际公开的具名函数／method 输入 type 与 mode 必须由 source 或所属 contract 逐位置明确，两者可以分担。无 body signature 保持上述实际 type、固定默认 mode 与 receiver `Self` 规则，trait impl 沿用 owner signature。Private／local／anonymous closure，以及 return／effect／Noescape，不因本条一律强制标注；普通 source/contract 差异仍按既定优先级处理，Q11 的默认诊断策略继续等待实测。

可变借用可以交出拥有值：take、pop、replace等操作允许交出成员，同时给调用方留下完整合法状态。不能挖走必需字段并留下未初始化存储。正常返回和可恢复failure都要保持这种完整性；已经发生的合法修改不自动回滚。

Int、Float、Bool、Unit和raw Ptr可Copy；tuple在成员都Copy时Copy。普通struct／enum默认Move，只有明确选择并通过成员及资源检查后才能Copy；有用户Drop的类型不能Copy。

Copy不调用用户Clone。Clone是显式且由类型定义的操作，不普遍保证递归独立副本。Rc的Clone增加共享owner，不复制载荷、不要求载荷Clone。Clone遵守约定的值关系，实际effect进入调用契约；编译器不声称证明任意手写实现的数学规律。

自己拥有且外层没有用户整体Drop的struct／tuple，可以合法移出non-Copy字段。已经移出的部分归新owner，其余部分按存活状态清理；部分缺失的原对象不能再整体使用。具有外层用户Drop的对象不允许拆走non-Copy字段。

## 6. 闭包、调用能力与scoped

每个closure表达式具有独立具体类型。参数和effect相同，不使两个closure自动统一、装箱或变成函数指针。泛型调用保留实际F；不同结果的共同存储需要显式enum或wrapper等建模。

fn(P) -> R with E是一种调用形状约束，不是可容纳任意closure的统一存储类型。直接有body参数、factory返回assertion和generic bound可使用它；复杂嵌套与普通存储使用实际F／G。相同F可以出现在多个位置来表达类型相等。

```vorton
fn apply<F: Fn + fn(Int) -> Int>(f: call F, x: Int) -> Int {
    f(x)
}

struct Holder<F: Fn + fn(Int) -> Int> {
    callback: F
}
```

调用能力、复制能力和能否逃逸分别检查：

| 调用能力 | 对环境的要求 |
|---|---|
| Fn | 共享访问，可重复调用 |
| FnMut | 每次独占访问，调用后环境仍合法 |
| FnOnce | 取得本实例所有权；非Copy实例移交后不能继续用 |

能力包含关系为Fn ⇒ FnMut ⇒ FnOnce。Move捕获不自动意味着只能FnOnce，共享调用也不自动意味着pure。

Q87 用 `call F` 把有限关系写入 source，同时保持同一个实际 `F`：可见 `Fn` 时选 Borrow；没有 `Fn` 而有 `FnMut` 时选 Mut；只有 `FnOnce` 时选 Move。选择按 type/evidence 许可完成，不为 body 或 caller 权限失败改 mode。调用方实例化同一个 type、evidence、mode 和 effect mapping；不重查依赖 body、不隐式 Clone、不包装或抹去 `F`，也不承诺调用次数。`scoped` 可与 `call` 组合。

省略capture列表时，按真实用途推导Borrow、Mut或Move，并精确到静态struct／tuple字段的不重叠路径。动态索引、List、raw间接访问和动态enum payload不创造独立capture槽。重叠路径合并到所需共同前缀；整体Drop禁令保持。

显式capture列表必须列全用到的外层局部值根；entry只写根名，mut／move固定实际取值方式。空列表禁止外层局部值capture。可以显式捕获未使用的资源来延长其拥有期，不能按unused删掉。列表顺序决定环境字段及逐项Clone／清理顺序，formatter不能排序。

无capture可调用值可Copy／Clone；拥有capture按实际成员能力推导；借用capture的副本不延长有效范围，独占借用不复制权限。拥有Copy计数器的两个closure副本具有各自状态，不隐式共享可变环境。

scoped是回调参数上的不逃逸限定，例如f: scoped &F。它覆盖传入回调及相关副本、包装、泛型转发。实现必须证明它们不通过返回或外部存储逃出允许范围；Move和Clone也不会延长内部借用来源的生命周期。

有body、未固定时可以推断Noescape；无body未给保证时保守MayEscape。MayEscape允许逃逸，不代表一定发生逃逸。普通拥有结果可以返回，返回借入callback及其受限派生值仍受限制。

公开factory可以返回隐藏具体实现的拥有或静态有效closure，无需为每个factory手写public struct。相同factory及相同实例化保持对应具体结果身份；不同factory不因调用形状相同而统一。返回分支仍须统一为一个合法实际类型，不自动装箱；factory结果不重新泛化。

## 7. Effect、资源销毁与Rc

有body且未固定的effect按实际行为推断；显式effect row是允许上界，检查后仍发布该上界。with {}不能隐藏I/O、外部mutation或可能执行的effectful销毁。

公开mutation使用一个mut marker。内部仍追踪状态来源：只有fresh-local、未影响输入、capture或既有外部状态的mutation可消除；存在外部或未知来源时保留mut。返回新建对象本身不自动取消局部性，mut也不授予写权限。

用户Drop可以产生system effect及未消除的mut，完整销毁的effects进入可能执行清理的callable契约。其对外row不能含fail、未处理的handled effect或unsafe obligation；body内部可按普通规则消除它们。Panic仍按终止规则处理，不保证剩余清理。

完整销毁D(T)包含用户hook、剩余字段／元素以及Rc可能最后一个owner释放的载荷清理。D(T)是接口中的语义摘要记号，不是新增source语法。只借用或把拥有值移交出去，不等于本次必然销毁它。

Drop hook只由完整清理调用，不能直接当普通方法调用或取值。需要显式提前释放时用core::drop；需要报告关闭／flush错误时提供独立可失败操作。自动清理不承诺持久化、提交或关闭成功。

泛型用户Drop必须覆盖类型的全部合法实例，所需约束由类型形成条件保证。不能只给Holder<Int>或满足额外条件的一部分Holder<T>增加用户Drop；普通字段自动清理可以随T变化。

Rc的多个owner共存时载荷只读。基础可变入口采用scoped callback：同一allocation须只有一个强owner、零存活Weak且无冲突借用。成功才调用callback；计数不符返回None，不复制载荷、不换allocation、不使Weak失效。借用冲突是静态错误，callback的failure普通传播。它不是自动COW或允许多owner修改的内部可变性协议。

Ptr<T>可以进入普通泛型容器，保存或复制地址不隐式拥有、保活或释放pointee。含raw字段的拥有wrapper仍按自身Drop与字段规则清理。foreign值须具有合法表示及所需布局／ABI事实，不能只凭解除总禁令获得任意按值存储能力。

## 8. 模式、控制流与遍历

Q86 固定 `match`、`catch`、`if let` 的 binding mode：未限定 `name` 默认 Borrow，`mut name` 明示 Mut，`move name` 明示 Move，不按分支 body 用途升级。限定可递归用于 tuple／constructor 子模式和 `field: mut name`／`field: move name`；不扩展普通 `let` 解构、`for`、field punning 或整个 pattern。对应 or-binding 必须 mode 一致。普通 `let` 与 `let` 解构仍建立拥有 binding，不能把两类规则混用。

有guard时，模式检查及guard阶段对匹配对象只读；guard成功才提交payload移交。false时原对象完整，后续分支照常检查。其他不冲突的effects可以发生，false不回滚；failure按当时的拥有状态清理并传播。

选中后移出的值归新owner，剩余字段由原owner清理。分支合流保留各路径的可用性，不能因为某条路径没有Move就恢复所有路径的完整对象。外层用户Drop、Rc权限与借入对象完整性规则继续适用。

0.1的for-in采用拥有式Iterable／Iterator：iter取得输入，next以可变借用返回拥有Item。List按原顺序移交元素，break、return或failure时清理剩余元素。即使元素Copy，遍历仍取得List本身，不隐式Clone。

只读与可变借用for留以后考虑，当前可用已定义的scoped访问或显式Clone组织需求。for只求一次输入和iter，首次None结束，不要求任意iterator永久fused。

## 9. Core的最小协议

这些协议使用真实core声明。省略with的trait method按选定impl关联effect，不能默认当作pure。

```vorton
trait Clone {
    fn clone(self: &Self) -> Self;
}
trait Copy: Clone {}
trait Drop {
    fn drop(self: &mut Self) -> Unit;
}

trait Display {
    fn to_str(self: &Self) -> Str;
}
trait Debug {
    fn debug(self: &Self) -> Str;
}
trait Hash {
    fn hash(self: &Self) -> Int;
}

trait Iterator {
    type Item;
    fn next(self: &mut Self) -> Option<Item>;
}
trait Iterable {
    type Item;
    type Iter: Iterator<Item = Self::Item>;
    fn iter(self: move Self) -> Self::Iter;
}
```

普通字符串插值唯一使用Display::to_str，无Debug fallback。每一项按表达式、转换、追加的顺序完成，再进入下一项；转换及temporary清理effects照常计入。自定义Display手写，Debug可显式结构派生。

Hash返回64位Int，结构派生按结构边界、variant和字段顺序组合。遵守equality／Clone关系，不提供持久ID、加密或跨版本／平台固定值保证。首版不加Formatter、Hasher、seed、locale或格式DSL；接受中间Str和潜在分配。

结构派生使用普通core generic helper固定trait dispatch，不能因字段有同名inherent方法而改选。Copy／Clone只提出实际成员所需条件，不机械要求所有类型参数Copy／Clone。

## 10. 编译期计算与结构化生成

const fn表示经过检查的编译期可用资格；普通数据计算的同一实现可在runtime使用。它不代表每次调用都提前执行，也不只是pure标记。

generate ctx是模块项，使用普通Block、变量、分支、循环与函数调用。ctx明确绑定于请求所在库／模块；生成API查询结构、构造节点并提交声明，不把代码字符串重新parse。API细名属于工程草案。

```vorton
const fn add_one(x: Int) -> Int {
    x + 1
}

generate ctx {
    let target = ctx.type_decl("User");
    let code = derive_debug(ctx, target);
    ctx.emit(code);
}
```

每个库只进行封闭一轮生成。同库所有请求读取同一预生成声明结构，依赖提供已冻结且可见的接口。当前轮产出不能反过来完成生成器检查、被后续lookup反射或触发新生成轮。

输出是指定库／模块中的普通type、function、impl／method和卫生helper；不修改原声明，不新增module、import、source、依赖或生成请求。输出整轮缓冲，任一失败丢弃整轮，再统一走普通名称、类型和coherence检查。

可以同库定义并调用生成器，但编译期依赖无环。普通helper可组合描述数据再一次提交；不需要先登记输出才能继续运算。不存在读取本库当前契约内容来驱动生成的反射入口。

条件impl采用一阶where合取，例如Wrapper<T>: Clone。条件由源码／生成声明明确给出，不从body反推更强适用条件；不新增负bound、OR、specialization或任意等式系统。Drop仍受整族适用限制。

编译期执行首版支持普通标量、Str、tuple、List、struct／enum、控制流、已检查泛型／callable及fail／catch／清理，允许普通单态自／互递归。它不执行guest Rc／Weak、live Ptr／foreign或用户handled effect，不读取I/O、FFI、环境、时间、随机数。描述或生成这些runtime类型／操作，不等于在编译期执行它们。

整个所需body和callee先检查资格，不能靠本次未走到某个分支放过非法操作。执行用确定的work与累计逻辑allocation额度；固定操作、可变规模遍历和资源动作都计数，操作前扣额，释放不返还，耗尽不能被guest catch，整轮产出不采用。不能用wall timeout代替语言预算。

内存API允许明确给出正有限额度；默认值等待真实计数器与代表派生负载实测。计数、输入、配置及缓存复用须保持同一预算结论，guest不能读取剩余额度来改变生成结果。

## 11. 编译器交付与唯一事实来源

源码和契约共同形成一份有效签名，随后由同一套检查闭合类型、trait、mode、effect、调用能力、scope和影响公开接口的资源事实。递归SCC使用同一批临时单态变量，整组完成后一次发布，不能部分发布或允许多态递归。

阶段顺序为：

```text
源码结构、库图与core
  → 先应用编译期目标契约，检查并执行单轮生成
  → 合并source/generated，完成名称与其余契约绑定
  → 联合语义检查，冻结有效接口S与TypedHIR
  → 实例化、资源计划、ABI与C11
  → native
```

完整接口S包含真实归属、导出、类型／effect scheme、参数mode及受限关系、调用能力、不逃逸与scope、Copy／Clone、完整销毁摘要、编译期资格和实际检查范围。它是caller、候选及版本比较共同消费的结果。

泛型body、实际evidence／替换、private representation和生成来源等私有配方从同一检查结果导出，供后续实例化或编译期执行消费。它们不能形成另一套公开接口，也不能在后端重新决定mode或effect。

M2交付纯内存契约读取／绑定／应用、候选筛选、完整接口及比较。M3闭合资源、lowering、ABI和native；M4提供本地文件及CLI产品入口。通过M2不等于native correctness已验收。

## 12. 0.1的明确边界

| 采用 | 当前不纳入 |
|---|---|
| 参数借用与scoped回调 | 自由返回、普通存储的一般借用类型 |
| 具体closure、generic F、合法隐藏factory返回 | 通用动态callable封装、自动装箱或用户调用运算符 |
| 单态化、已定义的trait／effect scheme | rank-N与多态递归 |
| 一库一轮结构化生成 | 本轮生成驱动下一轮生成、代码字符串注入 |
| 拥有式for-in | 只读／可变借用for |
| Rc唯一性下的scoped可变入口 | 自动COW、自动断Weak或额外共享修改协议 |
| C11主路径、Rust宿主 | 并行Rust源码后端或rustc私有集成 |
| 同步handled effect和failure | async／await及异步执行器 |
| 语言与外部宿主编译器先稳定 | 当前self-host目标 |

这些边界不宣称其他路线不可能，也不预先保证未来无返工。遇到当前可复现的矛盾或经用户决定的新需求时，再修改相应范围。

## 13. 与当前仓库的距离

当前 Rust compiler 的 source frontend 已承载 `&T`／`&mut T`／`move T`／`call F`、`scoped`、`const fn`、`generate` module item、CallableShape／generic bound、trait impl `where`、branch binding qualifier 与单一 `mut` effect，并保留相应 source order 和 span。Resolver 机械运输当前可处理的 carrier；纯内存项目入口在 frontend 与 module graph 成功后，对可达 `generate` 返回 generation-stage unsupported 诊断。

这只闭合 source→AST 与当前 Resolver 的责任。Q84–Q87 的 contract 对应、公开输入约束、call evidence/mode、Noescape、pattern 权限／guard／resource 检查仍属于 Checker 及后续阶段；`generate` block 尚不执行，也没有 GenContext API、结构提交、预算或生成后语义闭合。Core、resource、ABI 与 native 的其余设计同样不能由 frontend 成功推断为已实现。

Rust／C 机制见证、静态结构检查和 frontend 测试只能说明各自观测范围，不证明 Vorton Checker、资源或 native 已经通过。本审阅稿用于解释已确认的整体设计，不能替代语言规范、Issue contract 或阶段验收证据。

## 14. 已确认项与仍需证据的决定

现有规则组成这一版审阅稿；下表区分已确认设计和仍需实测的策略。

| 事项 | 状态与取得结论的方式 |
|---|---|
| Agent 体工学优先 | 已确认；服从安全、一致、终止、资源和 native 硬约束 |
| Q84 有契约泛型双边显式且对应 | 已确认；按 target／owner／kind／ordinal 与使用关系核对 |
| Q85 公开具名输入由 source／contract 逐位置明确 | 已确认；不把同一要求扩到 private／local／closure 的全部位置 |
| Q86 branch binding 默认 Borrow，`mut`／`move` 明示 | 已确认；权限、guard 提交和资源检查由 Checker 完成 |
| Q87 `call F` 的有限 mode 关系 | 已确认；消费同一 F/evidence/instantiation，不是 runtime 第四 mode |
| 源码普通标注与契约不同的默认诊断 | 待真实诊断／候选修正流程，比较error加修正与warning加严格策略 |
| 编译期执行默认额度 | 待真实work／allocation计数器与代表派生测量；当前不填任意数字 |

结构不匹配、实际函数体违约及语言硬规则错误始终报错；诊断默认待定不改变这些结论。生命周期追踪是否另立哲学公理也没有被本文默认决定。

[设计来源](https://github.com/vorton-lang/vorton/issues/45) · [契约格式、冻结协议与生成API草案](https://github.com/vorton-lang/vorton/discussions/46)
