# vorton-lang 设计文档

**Rust 的安全性 + Python 的书写体验 + 效果系统让编译器知道一切，然后用这些信息优化性能。**

核心定位（2026-05-24 确定）：

**三支柱**：

1. **推断一切** — 类型 + effect + 可变性 + 所有权，全推断。写代码的体验接近 Python，编译器内部看到完整类型+效果+所有权信息。标注由 formatter 按配置等级自动生成，人只控制详细度。Rust 的安全性不应以标注负担为代价。
2. **追踪一切** — 签名即完整行为契约。函数的副作用（IO、失败、可变、异步）全部由 effect system 在类型层追踪。LLM 和人都能从签名读出全部副作用，无需查看实现。
3. **语义驱动性能** — 在 HIR 消费 effect purity / linearity 信息，再通过 native 后端实现 bounds check 消除、RC 省略、纯函数重排/并行化。前两个支柱产生的类型信息是优化燃料，而不是绑定某个 codegen 的 metadata。

**实验赌注**：Refinement types（类型附带值级谓词，Z3 集成编译器）。成了在第三支柱上再加一层（refinement proof → 消除运行时检查，消灭 `unsafe`），不成前三个支柱自洽。

额外目标：让 LLM 也喜欢写这门语言——模块签名信息密度最大化，LLM 在零训练数据的情况下只需签名即可正确使用 API。

**当前实现状态**：编译器正在 Rust 宿主上重建，先闭合 `source → token → AST → diagnostic` 最小纵切，再按 GitHub Milestone 的目标顺序通过当前 Issue 推进 checker、IR、ownership、C11 后端与 CLI。迁移前的 `compiler/*.vorton`、`compiler/dist-c/main.c`、`vorton_runtime.cpp` 与旧测试只作迁移蓝本、语义 oracle 和已知缺陷复现，不是当前 compiler build、CI、bootstrap 或发布 authority。以下涉及旧 C/self-host 实现的段落记录历史设计与可复用约束，不表示当前 Rust compiler 已实现或通过相应门。

## 设计公理

**全文唯一真值源 = `docs/philosophy.md`（本节只留速记，消除双真值源）**：**层 0 目标** ④ 不信任程序员 · 编译器是最终权威（渐近表达 = 无人回路 × 全场景；推论：失真必须响 / 优化不可观测 / 人类审查面可枚举）。**层 1 硬约束** ⑤ 编译器必须终止（可判定片段 + fuel）⑥ 确定性资源语义（Drop = scope-end 语义 + as-if 条款；RC 无 GC；环用 Weak）⑦ 场景不可堵死（native / 零强制 runtime / C ABI）。**层 2 策略** ① 类型即模型，不是谜题 ② 效果即可见性 ③ 推断为王，标注为仆 ⑧ 一种事一种写法 ⑨ 语法借用。仲裁：策略让位约束；约束修订由用户决定。

> LLM 友好性三原则（语法借用像原主 / 错误信息 LLM 可消费 / 高级特性两路径）详见 §11。

---

## 确定性求值顺序

Vorton 在同一 evaluation region 内按源码 **从左到右** 求值同级子表达式，不采用 C 式 unspecified operand / argument order。callable/receiver 先于 arguments；二元运算数、参数、List/tuple/constructor 字段、字符串插值片段按源码顺序；index 先 receiver 后 index，range 先 start 后 end。`&&` / `||` 保持左侧优先与短路；条件表达式先求 condition 且只求选中分支；match 先求 scrutinee，再从上到下检查 arm，模式成功后才求 guard。任一子表达式产生 `fail`、panic 或 diverge 后，后续子表达式不执行。

优化器只有在证明观测等价时才可重排；观测包括 effect、mutation、fail/panic、资源 transfer 与 Drop 时点，而不只包括最终数值。C 后端必须把需要定序的子表达式先按 Vorton 顺序物化为 temporary，再发出 C operator/call，不能把 Vorton 语义委托给 C 自身未规定的求值顺序。现有 CoreHIR → FlowIR 的 evaluation-region lowering 是该公开语义的唯一 operational authority，不新增平行 pass。

---

## 1. 类型系统

### 1.1 基础层：ADT + Trait

所有抽象由三种构造完成，无 class、无继承：

```
struct Point { x: Float, y: Float }

enum Shape {
    circle(radius: Float),
    rect(width: Float, height: Float),
    polygon(vertices: List<Point>),
}

fn area(s: Shape) -> Float {
    match s {
        circle(r)    => pi * r * r,
        rect(w, h)   => w * h,
        polygon(vs)  => polygon_area(vs),
    }
}

trait Drawable {
    type Surface
    fn draw(self, target: Surface) -> Unit
}

impl Drawable for Shape {
    type Surface = Canvas
    fn draw(self, target: Canvas) -> Unit {
        match self { ... }
    }
}
```

Trait 泛型约束：

```
fn sort<T: Ord>(list: List<T>) -> List<T> { ... }

fn serialize_sorted<T: Ord + Serialize>(list: List<T>) -> Bytes {
    list.sort().map(to_bytes).concat()
}

trait Collection {
    type Item
    type Iter: Iterator<item = Item>
    fn iter(self) -> Iter
}
```

**Trait / impl visibility（2026-08-23 用户决定，0.1 对齐 Rust）**：trait 是完整 contract，不为 method 或 associated type建立第二层 visibility。`pub trait` 的全部 associated items 随 trait 公开；private trait 的全部 associated items 保持 module-private。Impl block本身没有visibility，字面`pub impl ...`非法；trait declaration 与 `impl Trait for Type` 中写 `pub` 同样 hard-fail并建议删除，trait impl method visibility继承trait。只有 inherent `impl Type` 继续允许每个method/associated item独立写`pub`或保持private。未来若需要sealed trait，必须显式设计，不以private required method偷渡；dictionary、ImplProviderRef、ExecutableInventory与CoreHIR不得携带per-trait-member visibility bit。

**Public interface 与 private implementation（2026-08-23 用户决定）**：public item的参数、返回类型、字段、generic bound与effect/trait contract不得引用更private的declaration，违反即hard error。`impl PublicTrait for PrivateType`可合法留在module/project internal coherence registry，但不构成外部callable surface；trait impl只有target与trait均可见时才对外发布，public inherent type只发布其`pub` methods。0.1不把private concrete type的推断泄漏冒充opaque type；需要隐藏具体返回类型时留待post-0.1 B-200显式设计。

**Private representation 与compiler metadata（2026-08-30 用户批准 B，supersede Cut-A）**：对齐Rust，public struct可以用private field隐藏private nominal representation；consumer可持有、传递和Drop public wrapper，但不能访问private field或命名private type。Private type仍不得出现在public fn签名、pub field、public enum payload或其他真正public interface。Compiler metadata以exact `RegisteredNominalRef`运输public root所需的transitive private layout/Drop closure，但不得把private type安装进consumer source namespace，也不得先按canonical name选择后再验证owner。该metadata是唯一physical authority，不是第二resolver/type registry。

**Impl-member extern 边界（2026-08-24 用户决定）**：0.1 的用户 FFI 声明只有 top-level `extern fn` / `extern type`；inherent impl 与 trait impl 都不接受 `extern fn` member。现有 Str、Int、Float 的宿主桥接方法仍保持普通 public inherent method 的调用表面，但由编译器在唯一 builtin assembly 中以 exact `BuiltinMethodSite + IntrinsicRef + signature` 安装，不能从 target/method 字符串、span 或声明顺序恢复。CoreHIR 在闭合前必须看见该 exact intrinsic contract，AbiIR 只按穷尽 intrinsic tag 做机械 ABI 投影；C 后端不得保留 `method_to_runtime_c(type, name)` 一类隐式表。该 clean break 不改变 top-level extern、runtime ABI 或 B-156 的 capability 边界。

### 1.1a JSON 编码支持域（2026-08-06 D-001）

`json_stringify` 的公开支持域由公开 `Json` trait 裁决，签名为 `json_stringify<T: Json>(value: T) -> Str`，不再承诺无约束的任意 `T`。Int、Float、Bool、Str 与 `List<T: Json>` 提供标准实现；用户 struct/enum 只有在显式请求 `Json` derive 时才获得结构化实现，不做无提示的全局 auto-derive。

结构化编码保持历史字段、enum `_tag` 形状与 Float 编码规则；这些输出属于可回归的公开行为。调用点缺少 `Json` evidence 时必须在编译期拒绝。实现复用普通 trait dictionary 作为类型证据，native runtime 不按值表示猜测类型，也不为 unknown 类型提供 fallback。显式 derive 的具体表面语法与实现分层在 #260 planning/review 中对齐现有 trait/derive 机制，但不得改变上述支持域和 fail-closed 边界。

### 1.1b Union Type（匿名 enum 语法糖，2026-05-25 决策）

`A | B | C` 是匿名 enum 的语法糖。纯编译期展开，不引入子类型，HM 推断不受影响。

> **排期边界（2026-08-23 用户复核）**：本节既有语义与 2026-06-15 的 match 消歧裁决继续有效。匿名 sum 提供结构等价、自动注入与错误类型组合，具有独立建模/组合价值，不属于 `T?` 一类纯缩写；但它不是 0.1 urgent 能力，B-072 明确顺延到首次 0.1 发布后实现。

```
// 写法
fn process(x: Str | I64) -> Str {
    match x {
        Str(s) => s,
        I64(n) => n.to_str(),
    }
}
process("hello")   // 编译器自动包装为 union 的 Str 分支
process(42)        // 编译器自动包装为 union 的 I64 分支

// 错误组合——核心用例
fn load_config(path: Str) -> Config with {fail<IoError | ParseError>} {
    let raw = read_file(path)        // fail<IoError>，自动包装进 union
    let parsed = parse_json(raw)     // fail<ParseError>，自动包装进 union
    parsed
}
```

**语义规则**：
- `A | B` 展开为编译器生成的匿名 enum，tag + payload 与普通 enum 相同
- 归一化：按类型名字典序排列（`I64 | Str` = `Str | I64` 不成立，canonical form 按名字序）
- 去重：`A | A` = `A`
- 扁平化：`(A | B) | C` = `A | B | C`
- 结构等价：两处写 `Str | I64` 是同一类型
- 调用点隐式包装：传入 `Str` 值到 `Str | I64` 参数时编译器自动插入 enum 构造
- match 使用类型名作为 pattern（具体语法待定，见 backlog）

**不引入的东西**：
- 无子类型关系（`Str` 不是 `Str | I64` 的子类型——是隐式包装，不是子类型）
- 无运行时类型检查（tag 区分，同 enum）
- 无 `Any` 类型

### 1.2 Refinement Types

> **0.1 surface 边界（2026-08-23 用户决定）**：refinement 尚未实现，语言不得保留“可解析但不验证”的占位语法。B-193 删除当前 struct-field `where` 的 token 消费与 W0002 路径；完成后 field、parameter 等 refinement clause 均稳定 hard-fail。`where` 继续保留为未来关键字，不在 0.1 变成普通标识符。B-001 将来必须把 parser、可判定静态验证、明确允许的 runtime fallback、诊断与验证证据原子闭合后才可重新开放语法，禁止再次先 parse/transport、后补语义。

类型附带谓词，编译器尽力静态检查，无法证明时插入运行时检查：

```
type Positive    = Int where it > 0
type NonEmpty<T> = List<T> where it.len() > 0
type Percentage  = Float where 0.0 <= it <= 100.0
type Email       = Str where it.matches(r"^[^@]+@[^@]+\.[^@]+$")

fn divide(a: Float, b: Float where b != 0.0) -> Float {
    a / b
}

struct Portfolio {
    weights: List<Percentage> where it.sum() == 100.0,
    assets:  NonEmpty<Asset>,
}

let x = 42
divide(1.0, x)      // 编译器证明 42 != 0 ✓

let y = read_input()
divide(1.0, y)      // 编译器插入运行时检查，失败触发 fail effect
```

### 1.3 Const Generics（值参数化类型）

> 原"Dependent Types Lite"（B-003）。2026-05-25 决策：不作为独立特性——其能力 = Const Generics（B-070 起步）+ Refinement predicates on const params（B-001）。不引入"依赖类型"概念——对用户来说就是"带编译期常量参数的泛型 + 约束"。

类型可参数化于编译期常量值，配合 refinement 约束实现维度安全：

```
// 固定长度数组（B-070）
let key: [U8; 32] = [0; 32]

// 等式约束：两个 N 必须相等（HM unification 自然处理）
fn zip<T, U, const N>(a: [T; N], b: [U; N]) -> [(T, U); N] { ... }

// Refinement on const param（B-001 SSA 约束传播）
fn head<T, const N where N > 0>(v: [T; N]) -> T {
    v[0]
}

// 远期：用户自定义类型的 const generics
// struct Mat<const M, const K> { data: [F64; M * K] }
// fn matmul<const M, K, N>(a: Mat<M, K>, b: Mat<K, N>) -> Mat<M, N>
```

### 1.4 Row Polymorphism（语法糖定位，2026-05-25 决策）

结构化多态——函数参数按字段匹配，无需定义 trait。**定位为语法糖**：编译期通过单态化消除，不作为类型系统一等概念。

```
fn greet(person: {name: Str, ..rest}) -> Str {
    "hello, ${person.name}"
}

struct User    { name: Str, age: I64, email: Str }
struct Company { name: Str, industry: Str }

greet(User { ... })       // ✓ 单态化为 greet__User
greet(Company { ... })    // ✓ 单态化为 greet__Company
```

**编译策略**：
- 编译器收集所有调用点的具体类型，为每个生成特化版本（同泛型单态化）
- 如果存在覆盖所需字段的 trait，归化为 trait 约束（trait 归化）
- `RecordType` 不出现在最终类型表示中——编译期消除
- **pub fn 不允许 row poly 参数**——模块边界必须使用具名类型或 trait

**签名显示**（lv2 formatter）：
- 有匹配 trait → 显示 trait 约束：`fn greet<T: Named>(person: T) -> Str`
- 无匹配 trait → 显示具体调用类型的 union：`fn greet(person: User | Company) -> Str`（使用 1.1b union type 语法）
- pub fn → 不适用（已禁止 row poly）

**实现时序**：当前 `RecordType` + row unification 实现保留；公开边界收口与单态化 pass 按 backlog 排期，在共享 HIR 完成。

### 1.5 错误的生命周期模型

Vorton 的错误处理基于一个核心洞察：**错误有生命周期——诞生（raise）、流动（propagate）、有时落地（materialize）。** effect 是错误的运动形态，Result 是错误的静止形态。两者不是竞争关系，是同一个错误在不同阶段的表现。

- **`fail<E>` effect 是主模型** —— 错误默认以 effect 形式存在和流动，零语法自动传播
- **`to_result()` 是"物化"操作** —— 当需要存储、序列化、收集多个错误时，将 effect 转为数据
- **`catch` 是就地恢复** —— 捕获 fail effect 并提供替代值，总是消除 fail effect
- **`Option<T>` 是独立的数据类型** —— 表达"有或没有"，通过 `to_fail()` 进入 effect 世界

> **公开类型拼写（2026-08-22 用户决定）**：最终只保留显式 `Option<T>`。当前编译器接受的 `T?` 是历史纯缩写语法糖，不提供独立语义；在 B-180 性能专项后由 B-191 做未发布期 clean break，并在 preview 产品面前完成。迁移前不新增或扩张 `T?` 用法，当前实现事实仍以 lang-spec 与可执行 parser 为准。

```
// Option 是显式数据类型；没有 nullable/null 语义
enum Option<T> { some(T), none }

struct User {
    name:     Str,
    nickname: Option<Str>,         // 数据层面的"有或没有"
}

// Option → 值：unwrap 方法
let nick = user.nickname.unwrap()              // none → panic
let nick = user.nickname.unwrap_or("匿名")     // none → 默认值
let nick = user.nickname.unwrap_or_else(fn() { compute_default() })

// Option → fail effect：to_fail 方法（从数据进入 effect 世界）
fn get_nickname(user: User) -> Str {
    user.nickname.to_fail()       // none → raise(Unit)，自动冒泡
}

// fail effect → 就地恢复：catch 表达式（总是消除 fail）
let config = load_config(path) catch {
    IoError(e) => default_config(),
    _          => panic("unexpected error"),
}

// fail effect → 物化为数据：to_result（当需要错误作为持久数据时）
let result: Result<Config, Str> = to_result(fn() { load_config(path) })
```

**什么时候用哪个：**

| 场景 | 机制 | 理由 |
|------|------|------|
| 不关心错误，让上层处理 | 零语法（自由传播） | 错误在流动，不需要干预 |
| 在调用点就地恢复 | `catch { ... }` | 错误到此为止，提供替代值 |
| 需要错误作为数据（收集/序列化/测试断言） | `to_result()` | 错误需要落地成持久值 |
| 拦截/替换 effect 实现（mock/DI） | `handle...with` | 不只是错误，是 effect 语义替换 |

设计原则：**错误在 effect 世界诞生和流动（零开销），只在需要持久化时物化为数据。大多数代码不需要物化。**

### 1.6 可变性模型

Vorton 的可变性由唯一关键字 `mut` 统一管理。设计原则：**局部 mutation 不是 side effect，共享 mutation 才是。**

**`let` vs `let mut`：**

```
let x = 10                   // 不可变——不可重绑定，不可调用 mut self 方法
let mut counter = 0          // 可变——可重绑定，可调用 mut self 方法

let list = [1, 2, 3]
list.push(4)                 // ERROR — push 是 mut self 方法，需要 let mut
list.len()                   // ok — len 是只读方法

let mut list = [1, 2, 3]
list.push(4)                 // ok
list = [5, 6]                // ok — 重绑定
```

**`mut` 参数——传入可变引用：**

```
fn increment(mut counter: Int) {
    counter = counter + 1    // 直接赋值，修改调用方的变量
}

let mut n = 0
increment(n)                 // 编译器从签名推断需要 box
print(n)                     // 1

// formatter preset "review"+ 自动插入 mut 标记：
increment(mut n)             // 等价写法，可选语法，方便人阅读
```

编译器为 `mut` 参数自动 box（`{ value }` 对象），用户无感。调用方的 `mut` 前缀是**可选标注**——编译器接受两种写法，语义相同。formatter 按配置决定是否插入：`preset = "none"` 省略，`preset = "review"+` 插入（代码审查时副作用可见）。

**`mut self`——可变方法：**

```
impl List<T> {
    fn len(self) -> Int { ... }           // 只读
    fn push(mut self, value: T) { ... }   // 可变——调用方需要 let mut 绑定
    fn clear(mut self) { ... }            // 可变
}
```

**闭包捕获——编译器透明 box：**

```
let mut counter = 0
let inc = fn() { counter = counter + 1 }  // 闭包捕获 mut 绑定
let get = fn() { counter }

inc(); inc(); inc()
get()  // 3
```

编译器检测到 `counter` 被闭包捕获且为 `let mut`，自动 box 为 `{ value: 0 }`。闭包和外层作用域共享同一个 box。用户写的是直觉代码，编译器干脏活。

**Mutation 追踪**：`mut<T>` 是可多实例 marker effect（见 §7.9）；参数位 `x: mut T` 与闭包捕获列表 `[mut counter]` 则分别标明被修改的参数和绑定，三者不能互相替代。

**自动 box 规则**（不变）：

| 场景 | 是否 box | 理由 |
|------|---------|------|
| `let mut x` 纯局部使用 | 不 box | 局部 mutation 不是 side effect |
| `let mut x` 被闭包捕获 | 自动 box | 共享 mutation 需要间接 |
| `mut` 参数传递 | 调用方 box | 修改外部状态需要间接 |
| struct 字段修改（`let mut s; s.f = v`） | 不 box | 局部持有的 struct 修改是局部行为 |

普通局部、可变参数和闭包捕获不要求用户手写包装；编译器按上表自动选择直接存储或 box。当前内建 `Cell<T>` 仍是显式共享状态值，也是 `mut<T>` marker effect 的标准载体；它不替代 `let mut`，也不能被文档写成已消除。`Ref<T>` 不作为另一套公开 mutation 模型。

**闭包内的 `return` 语义**：闭包内的 `return` 返回闭包本身，不影响外层函数。这与 Rust/Kotlin 一致，与 Ruby/Smalltalk 不同。作为 HOF 回调时（如 `list.map(fn(x) { return x * 2 })`），`return` 也只影响该回调；所有后端必须保持 B-022 回归，不让 block lowering 改写控制目标。

### 1.6b 类型系统特性交互矩阵（2026-05-24 确定）

Refinement types、Linear types、Effect system 三个特性单独设计清晰，但组合后存在语义交互。以下为六个交互场景的已确定规则。

#### Refinement × Ownership（正交）

Refinement 是值级谓词——描述值本身的性质（`Int where it > 0`），不引用外部可变状态。Ownership 追踪值的所有者。两者正交。

- 值 move 后，refinement 随值转移到新 owner
- **约束**：refinement 谓词不允许引用可变绑定。`x: Int where x < len` 中 `len` 必须是 `let` 绑定或常量，否则编译错误。这保证谓词在值的整个生命周期内恒成立

#### Refinement × Effect（无冲突）

- **Abort 路径**（`fail.raise`）：refined 值随栈帧一起销毁，无需特殊清理——refinement 是编译期信息，没有运行时资源
- **Tail-resumptive 路径**（custom handled effect）：计算继续，refined 值不受影响；system effect不是 handler operation
- **Handler resume 值**：handler 提供的恢复值必须满足恢复点的 refinement 约束（编译器检查）

#### Ownership × Effect（RAII / Drop trait）

`impl Drop` 的类型在所有路径自动 drop（RAII）。Rust 风格所有权模型，无 borrow checker。

```
trait Drop {
    fn drop(mut self)             // 0.1 必须 effect-free
}
```

**所有权规则（2026-06-24 更新，见 §7）**：
- Drop 类型赋值 auto-move（§7.2），rc 恒 1，scope-end drop = Rust 析构时机
- 非 Drop 类型赋值 = rc+1 共享（§7.2），别名追踪保证 mutation 安全（§7.4）
- `impl Drop` 禁止 `impl Clone`（资源不可复制）
- `drop(x)` 提前释放，`leak(x)` 显式逃逸
- 共享 Drop 类型 → `Rc<T>`（非 Drop 包装，§7.7）
- 复合类型含 Drop 字段 → 自动 derive Drop
- abort-unwind：语义目标是 fail/abort 穿越任意调用帧时逐帧执行 Drop、全路径 RAII；C-native 实现模型由 B-168 在 cleanup stack + `setjmp`/`longjmp` 与显式 failure-status/continuation lowering 之间实测拍板

**不引入 `defer` 关键字**——RAII 覆盖资源清理。**0.1 clean break（2026-08-23 用户决定）**：用户 `Drop::drop` 的最终推断 effect row 必须为空；不仅禁止 `fail`，也禁止 system/handled effect 与逃逸 `mut<T>`。编译器生成的字段递归释放和已验证 intrinsic cleanup不属于用户 body。0.1 不建立 `DropEffectSet` 占位；effectful destructor 在 post-0.1 出现真实宿主资源 consumer 后由 B-198 重新设计。

#### Ownership × async（Move 语义）

`spawn` 闭包捕获 Drop 值 = ownership 转移。原作用域失去访问权（编译错误）。

- 一个 Drop 值不能被两个 `spawn` 闭包同时捕获（违反所有权，编译错误）
- 子任务取消时，被取消的任务走 `Cancelled` fail 路径 → 触发 Drop（同 Ownership × Effect 规则）

#### Refinement × async（成立）

值级谓词不受 await 挂起/恢复影响——`id: Int where id > 0` 在 await 前后恒成立。因为交互 1 已确定 refinement 不引用可变外部状态。

#### 三系统组合（无新规则）

前五个交互规则的自然组合。典型场景：

```
fn safe_write(file: FileHandle, data: Str where data.len() > 0) with {fail<Str>, async} {
    // file: impl Drop → scope 结束自动 close（正常 + abort 均 RAII）
    // data: refined → 保证非空，跨 await 稳定
    let written = await(file.write(data))
    if written == 0 {
        fail.raise("write failed")   // abort → file.drop() 自动触发
    }
    file.close()                      // 也可提前显式消耗
}
```

三系统的类型检查算法各自独立运行，无循环依赖。

#### 扩展交互矩阵（2026-05-24 确定）

以上六个交互覆盖 Refinement × Ownership × Effects 三大支柱。以下为其余重要特性交互的已确定规则。

**GADTs × Or-Pattern（类型等式与绑定环境分别兼容）**

Or-pattern 合并的 GADT 变体必须同时满足两道独立门：各 alternative 携带兼容的类型等式，并按语言规范绑定完全相同、类型/模式兼容的变量集合。`Lit(_) | Add(_, _)` 合法（两边绑定集合均为空，且均给出 T=Int）；`Lit(n) | Add(a, b)` 非法，即使两边都是 T=Int，shared arm 也不存在对每条成功路径都已初始化的共同绑定环境；要使用不同 payload 必须拆成两个 arm。`Lit(_) | IsZero(_)` 同样非法，因为 T=Int 与 T=Bool 的 GADT 等式冲突。编译器在 or-pattern authority 中分别验证绑定集合/同名类型与 GADT 约束，任一不兼容均报编译错误。

**Refinement × mut 参数（赋值点重新验证）**

`fn foo(mut x: Int where x > 0)` 的 refinement 必须在每次赋值后重新成立。编译器通过 SSA 约束传播在每个赋值点验证新值满足谓词。这和 refinement 本身的流分析实现是同一层复杂度，不单独拆分。Refinement 的核心价值是使用点的保证，不只是入口检查。

**Auto-Boxing × Linear（透明）**

Auto-boxing 是 codegen 实现细节，对 HIR linearity checker 透明。被闭包写穿捕获的 `let mut` 局部（`boxed_vars`，checker 标记 def_id）必须降低为外层作用域与 closure env 共享的单槽 cell；读写都指向同一 cell，具体 ABI 由当前后端实现。赋值只替换 cell 内容，不能消费仍被外层/closure 持有的 cell 指针；cell 本身按普通 owned 堆值参与 RC（捕获点 dup、作用域末 drop，或 move 进返回 closure）。该不变量由 B-091 回归钉住。

**显式组合 × Associated Types**

包装类型通过普通trait impl完成组合，并显式声明associated type与forwarding method。Vorton 0.1不从字段自动生成impl，也不推导wrapper的associated binding。

**Associated Types × Supertrait（自然组合）**

`T: Collection` 蕴含 `T: Iterable`，`T::Item` 等 supertrait 关联类型自动可用。实现时 supertrait bound 展开时带上关联类型即可，无需额外规则。

**GADTs × Effects（正交）**

GADT 的 scoped type equality 是编译期 unification，effect evidence 是运行时值传递，两层不交叉。

**mut\<T\> × Ownership（隐式借用 + 无 borrow checker）**

`mut self` 方法调用 Drop 值时，语义为隐式借用（不消耗所有权）。Drop 值在 scope 内可通过 `mut self` 被修改，scope 结束时自动 drop（RAII）或提前 `drop(x)` / `x.close()` 显式消耗。Vorton 不引入 borrow checker——Perceus RC + Ownership + mut\<T\> + Drop 已覆盖安全性需求（内存安全由 Perceus RC 保证，资源安全由 Ownership + Drop 保证，mutation 追踪由 mut\<T\> effect 保证，数据竞争由结构化并发 + move 语义排除）。不设 borrow checker 的残余可变别名窗口（`f(xs, mut xs)` 同值双借）由句法禁止收口；其余别名由 move 语义（§7.5，use-after-move 编译错误）杜绝，COW 因此为不可观测的内部优化（2026-06-11 拍板，B-110）。

### 1.7 语义规范（后端无关，2026-05-24 确定）

Vorton 语言的语义规范与后端无关。历史实现中，JS 后端已归档（B-100 Phase 2，commit `5df6c99`），随后 main 曾只保留 C11 codegen，覆盖单文件、project/module 与 self-host，`compiler/dist-c/main.c` 曾是 tracked bootstrap anchor；最后 LLVM lane 只由 `llvm-c-backend-final` tag 保存。当前路线是在 Rust 宿主上重建编译器，这些旧后端与 anchor 仅作迁移 oracle，不属于现行 compiler、CI、bootstrap 或发布门。

#### 数值类型（2026-05-25 更新）

14 个固定宽度类型，无别名：`I8, I16, I32, I64, I128, U8, U16, U32, U64, U128, F32, F64, ISize, USize`。每个类型名自带宽度信息，拒绝 C 系 `int` 的平台歧义。

**字面量规则**：
- `42` → `I64`，`3.14` → `F64`，永远确定，无歧义
- 无后缀语法（不支持 `42u8`——可由社区反馈驱动后续添加）
- 类型标注窄化：`let x: U8 = 42`（编译期常量折叠 + 范围检查，`256` → 编译错误）
- 方法窄化：`42.to_u8()`（等价于类型标注）
- 运行时窄化：`some_int.to_u8()`（溢出 → fail effect）

**零隐式转换**：
- 不同宽度类型之间无隐式转换（无 widening、无 narrowing）
- `u8_val + i64_val` → 编译错误，要求 `u8_val.to_i64() + i64_val`
- 算术运算只在同类型之间

#### 内存布局（2026-05-24 决策）

默认布局不保证（编译器可重排字段）。`@repr(C)` C 兼容布局（FFI）、`@repr(packed)` 紧凑布局（协议解析）、`@align(N)` 显式对齐。属性标注机制。

#### 运算符重载（2026-05-24 决策）

通过 trait 实现。算术（`Add/Sub/Mul/Div/Rem/Neg`）、比较（`Eq/Ord`，`Ord: Eq`）、位运算（`BitAnd/BitOr/BitXor/BitNot/Shl/Shr`）与索引读取（`Index`）。不支持跨类型运算。14 个数值类型各自 impl 全套 trait（编译器内置）。0.1 不支持 `IndexMut` 或 `x[i] = value`；容器 mutation 使用具名方法，完整 index-assignment 语义仅由 post-0.1 B-202 在真实 consumer 下重新设计。

Vorton 0.1 的 builtin public `Eq` contract 只有 exact `eq` member。`==` dispatch 到 `Eq.eq`，`!=` 固定降低为同一 exact dispatch 的 Bool 取反；不存在 `Eq.ne`、独立 `Ne` intrinsic、override slot、derived body 或默认特化。一般source trait method body也已由convergence clean break删除；builtin/derived exact ordinary impl body仍保留。

#### 尾调用优化（2026-05-24 决策）

编译器自动检测，无新语法。尾位置 + 无 Drop + 签名匹配 → 保证 TCO（debug/release 都做）。自递归转循环；互递归/间接尾调用由后端使用受保证的 tail-call 机制或 trampoline 实现，不能把优化器“碰巧消除”当作语义保证。

| 维度 | Vorton 语义 | 备注 |
|------|----------|------|
| **整数范围** | 各类型固定宽度（I64 = ±2^63，I32 = ±2^31 等） | 与 host 整数宽度无关 |
| **整数溢出** | Debug panic / Release 二补数回绕 | 后端必须避免 C signed-overflow UB |
| **浮点精度** | F64 = IEEE 754 double，F32 = IEEE 754 single | 后端保持显式宽度 |
| **字符串编码** | UTF-8 字节串（§1.7.1） | embedded NUL 合法，ABI 携带长度 |
| **`str[i]`** | 第 i 个字节（返回单字节 `Str`），越界 panic | code point 级访问用 `.chars()` 迭代器 |
| **`str.len()`** | 字节数，O(1) | code point 数用 `.char_count()`，O(n) |
| **数组越界** | panic | 安全访问用 `.get(i)` 返回 `Option<T>`。已是当前行为 |
| **整数除零** | panic | 所有 native lane 一致 |
| **栈溢出** | 实现定义的 panic 或 abort | 不保证所有平台均可捕获 |

**0.1 保留 type binding gate（2026-08-30 用户批准 Nominal B）**：0.1 的 type namespace 暂时保留完整集合 `Int Float Str Bool Unit Never Ptr Range Cell Option List ListIterator Map MapIterator Set SetIterator StringBuilder Result`。用户的 struct、enum、extern type、type alias 或 import/re-export 不得建立这些最终本地绑定名，冲突稳定报 `E0207`；只有固定 canonical builtin/std loader producer可建立它们。该集合不是 lexer keyword，也不限制 value、function、trait、effect 或 module namespace。实现不得用local-wins覆盖、Type name side map或exact-owner Type纵切绕过本门。

其中真正的语言 builtin type继续永久不可覆盖；当前以内建方式注入但最终属于标准库的类型，本门明确作为0.1已知限制。它们随既有标准库/RIIR迁移逐项成为ordinary module type后解除对应保留名，同名来源通过qualified path或import alias消歧，不静默覆盖。该解锁复用既有迁移真值，不新增post-0.1 item。`Range<T>`仍是语言预声明nominal；range语法、annotation、构造与`for-in`特化固定引用同一exact builtin owner。

#### 1.7.1 字符串编码模型

**公开契约**：`Str` 是 UTF-8 字节串。默认长度、索引、切片和容量以 byte 为单位；Unicode scalar/code point、grapheme 等操作必须使用名称明确的独立 API，不能让同一个 `len` 或 `slice` 随上下文改变单位。

- 字符串常量与 C ABI 传递必须携带显式长度；内部可额外保留尾随 NUL，但 NUL 不属于值。
- byte 索引/切片必须做边界检查；需要 code point 语义时先验证 UTF-8 边界并返回显式 iterator/结果。
- `StringBuilder`、split/join/replace 与容器 bridge 均按 binary-safe 字节契约实现。
- 公开 API 的单位写入名称、签名或文档；禁止依赖 host 字符编码、C `strlen` 或某个后端的内部表示推断语义。

当前实现仍有未完全对齐本契约的路径，由 backlog B-133 跟踪。实现状态、迁移清单和逐后端差异不写入本节；活动验收只看 B-133，完成过程由 Git 保存。

---

## 2. Effect 系统

Effect row 统一描述副作用，但不同 effect class 拥有不同的执行与消除权。System effect 是静态宿主能力，custom handled effect 才走动态 handler/evidence；failure、mutation 与 unsafe各有专用规则。

### 2.1 Effect class 与宿主能力

```text
EffectAtom
├─ SystemEffectRef     console / fs / process
├─ HandledEffectRef    用户 custom effect
├─ FailEffect          fail<E>
├─ MutEffect           mut<T>
└─ UnsafeEffect        unsafe
```

**System effect（2026-08-23 用户决定）**：0.1 只建立已有真实 API 所需的 `console`、`fs`、`process`。它们不进入 evidence、不可被 `handle`，也没有 root handler；host extern/intrinsic 以 exact contract进入 AbiIR HostImport，native/WASM/嵌入式只在链接 provider处不同。宽泛 special `io` 与 `io.read`/无 effect `read_file` 双authority由B-195原子删除。Capability 表示宿主访问类别，错误仍正交地写作 `fail<E>`。

**Handled effect**：用户 `effect` 声明产生 nominal operation set，进入 typed evidence并由显式 `handle...with` 消除。需要 mock host dependency 时，声明如 `FileAccess` 的 custom effect，再用普通 handler adapter翻译到 `fs` API；system call自身不动态截获。

**Allocation-effect boundary（2026-08-23 用户决定）**：0.1 不建立 `AllocEffect`，也不预留 OOM profile、effect carrier 或空 metadata。现有 `alloc<T>()` 是 `unsafe` raw-memory 原语，不代表普通 List/Map/Str 分配会进入 effect row。只有 post-0.1 出现真实 no-heap、real-time 或 embedded consumer 后，才重新 Argument 分配可见性、OOM 语义与 allocator contract；不能从旧研究草案直接恢复 `with {alloc}`。

### 2.2 0.1 无用户 default handler

```vorton
effect Logger {
    fn log(msg: Str) -> Unit
}
```

0.1 effect operation只有签名，不允许 body；不存在自动default evidence、部分默认或默认依赖拓扑。该能力具有真实建模/人体工学价值，并非永久否决：B-197在post-0.1结合真实consumer比较operation body、显式具名provider与普通wrapper，但不得直接恢复旧checker/codegen authority。

### 2.3 Effect 推断

你不写 effect 标注，编译器全推断：

```
// 你写的：
fn load_portfolio(path: Str) -> Portfolio {
    let raw = fs::read_file(path)
    let data = json.parse(raw)
    let weights = validate(data)
    Portfolio { weights, assets: data.assets }
}

// 编译器推断的完整签名（IDE hover 可见）：
// fn load_portfolio(path: Str) -> Portfolio
//     with {fs, fail<ParseError | ValidationError>}
```

### 2.4 错误处理——生命周期模型

错误有生命周期：诞生（raise）→ 流动（propagate）→ 落地（materialize 或 catch）。大多数代码只涉及前两个阶段。

**阶段 1：诞生与流动——零语法**

```
fn load_portfolio(path: Str) -> Portfolio {
    let raw = fs::read_file(path) // fs + fail 自动冒泡
    let data = json.parse(raw)    // fail 自动冒泡
    validate(data)                 // fail 自动冒泡
}
```

80% 的错误处理到此结束。函数签名自动推断出 `with {fs, fail<...>}`，调用方继续传播。

**阶段 2：就地恢复——`catch` 表达式**

```
let config = load_config(path) catch {
    IoError(e)    => { log(e); default_config() },
    ParseError(e) => fallback(path),
    _             => panic("unexpected"),
}
```

`catch` 总是消除 `fail` effect——它是一个完整捕获点。内部用模式匹配分派不同错误类型。如果需要选择性处理（只处理部分错误、其余继续传播），在 catch 内部 match + re-raise：

```
let config = load_config(path) catch { e =>
    match e {
        IoError(io_err) => default_config(),
        other           => raise(other),    // 显式重新抛出
    }
}
```

这样"部分处理"是显式的（re-raise），而非隐式的（有没有 catch-all arm）。

**阶段 3a：物化为数据——`to_result()`**

当需要错误作为持久数据时（收集多个错误、序列化、测试断言、跨 API 边界传递）：

```
let result: Result<Config, Str> = to_result(fn() { load_config(path) })
match result {
    ok(config) => use_config(config),
    err(e)     => log("failed: ${e}"),
}

// 典型场景：验证收集
let results = fields.map(fn(f) { to_result(fn() { validate_field(f) }) })
let errors = results.filter(fn(r) { r.is_err() })
```

**阶段 3b：effect 替换——`handle...with`（高级）**

用于拦截和替换 effect 实现，不限于错误处理（mock、DI、自定义 effect）：

```
handle {
    let result = complex_pipeline()
    save(result)
} with {
    Logger.log(msg) => print(msg),          // custom handled effect
}
```

`console` / `fs` / `process` 是 system effect，不能在此处被 `handle`；需要替换宿主依赖时，业务函数使用 custom effect，生产 adapter再调用system API。

**0.1 complete handler（2026-08-30 用户批准 A）**：一个`handle...with`若包含某exact custom `HandledEffectRef`的任一operation arm，就必须按对应`EffectDef`完整覆盖全部declared `EffectOperationRef`，各恰好一次；源码顺序任意，TypedHIR按声明ordinal冻结dense evidence。Missing、duplicate、unknown或cross-owner arm在发布handler facts及消除effect atom前稳定报错，Core复核exact owner/count/`0..N-1`全集，现有dense C ABI不变。0.1不实现partial residual row、未覆盖operation parent forwarding或sparse evidence；System effect仍不可handle。

### 2.5 Effect Handler 用于测试 Mock

```
effect FileAccess {
    fn read(path: Str) -> Str
}

test "load_portfolio parses correctly" {
    let mock_data = r#"{"weights": [25, 25, 25, 25], ...}"#

    handle {
        let p = load_portfolio_via_file_access("fake.json")
        assert(p.weights.len() == 4)
    } with {
        FileAccess.read(_path) => mock_data,
    }
}
```

### 2.6 Effect 多态

当前 handler 支持两种语义：

- **Tail-resumptive**（已实现）：handler 返回值即 resume 值，计算继续。覆盖 custom-effect mock 与 adapter 等场景。
- **Abort**（已实现）：`fail.raise` 专用，handler 替换整个计算结果。

```
// tail-resumptive：handler 返回值替代 custom operation 的返回值，计算继续
handle {
    let data = FileAccess.read("config.toml") // → "mock-data"
    "got: ${data}"                       // → "got: mock-data"
} with {
    FileAccess.read(path) => "mock-data",
}
```

**一等 effectful function value 的调用点动态 evidence（2026-08-28 用户批准 R1，0.1 最终语义）**：lambda/closure 创建本身是 pure，body effect只进入函数类型；ordinary user closure 永不捕获定义处的 handled-effect evidence。所有 Vorton callable 统一接收一个显式 borrowed `EffectCtx*`，每次 direct/method/indirect 调用传入当前 dynamic handler context；当前调用点没有对应 handler 时 context 中没有该 typed entry，effect 继续向外传播，不能被创建处状态或 unknown open tail 静默消除。

`handle` 安装的 evidence 只在其动态调用范围内生效。closure 即使在 `handle` 内创建，逃逸后调用也不得继续使用已经结束的 handler；若在另一层 handler 内调用，则使用新的当前 evidence。实现 handler arm/re-perform 的内部 runtime handler object 可持有其显式 outer evidence 和普通词法值，但该内部对象不得与返回给用户的 ordinary closure capture 规则混用。

**P2 统一 evidence context ABI（2026-08-28 用户批准）**：共享 callable ABI 固定为 `closure env`（仅 indirect closure）→ ordinary arguments → trait dictionaries → `EffectCtx*`。Pure 与 system-only Vorton callable同样接收 immortal empty context。普通用户 top-level extern 与不会回调 Vorton callable 的普通 HostImport leaf 保持原 ABI，Vorton wrapper接收但不向其转发context；这条边界不适用于必须从 C 回调 Vorton closure 的 exact compiler-owned bridge。Context key是完整typed handled instance（exact `HandledEffectRef`及其exact type arguments），由TypedHIR/Core/AbiIR产生并跨import/re-export原样运输；runtime/C不得按name、nominal leaf、import顺序或临时hash重建。

**D1 fully-closed runtime handled instance（2026-08-28 用户批准）**：generic custom effect声明与`Reader<Int>`、`Reader<Str>`等closed concrete实例继续合法；但任何进入runtime token census的custom handled instance，其type arguments在TypedHIR最终化时必须递归fully closed。它们不得含callable自身、impl/trait inherited、outer callable或nested lambda owner chain中的type formal，不得含nested callable effect formal/open row、open structural row，或任何会被后续instantiation改变的formal。因此`fn relay<T>() with {NestedPort<T>}`、`NestedPort<List<T>>`及返回执行`Probe<T>`的generic factory在0.1稳定hard-fail。`fail<T>`、`mut<T>`不属于handled token，generic effect alias在Core前展开后按本规则检查；callable顶层effect-row formal仍可原样forward，因为callee不会以它执行runtime token lookup。

Generic custom effect声明只是interface/template，不因bodyless operation header自动生成runtime token。Project token table只收集可执行body中真实lookup/install及其他确实emit token的carrier；禁止用declaration kind、名字或module扫描保活token。TypedHIR/A1在atomic publish/export前给用户诊断，Core type graph复用同一closed predicate二次fail closed，不运行新solver。

`EffectCtx`是显式typed overlay：empty context为never-drop singleton；每个`handle`拥有一个child overlay，记录其安装的ordered exact entries并引用parent，inner exact typed match优先；ordinary call只borrow一个context指针，不逐effect改变prototype，也不在closure env捕获context。Closed/fixed contract可用冻结layout的静态位置；open effect-row formal只以同一context pointer转发，Core中的typed view只证明layout关系而不物化runtime remap。禁止stack remap view、closure remap descriptor、handler ABI cutover、variadic、TLS/global/root handler或runtime name lookup。Planner只处理overlay/evidence的Borrow/Own与all-exit cleanup，不求解effect；handler arm/re-perform内部对象可显式持parent context，但与ordinary callable ABI分域。

**Exact compiler-owned callback intrinsic set（2026-08-28 用户批准）**：任何0.1 exact compiler-owned runtime intrinsic leaf，只要会调用Vorton callable，就必须显式接收并按统一Vorton closure ABI转发borrowed `EffectCtx*`。当前穷尽集合固定为 `vorton_list_sort_bridge`/`vorton_list_sort`、`Option.map`、`Option.and_then`、`Option.unwrap_or_else` 与 `Cell.update`；前四项转发调用点current context，`Cell.update`因callback typed contract为pure而传immortal empty context。身份只由exact `CompilerExternRef`/`IntrinsicRef` tag裁决，missing或extra callback tag必须fail closed，runtime/C不得按symbol name猜测。调用同步完成，leaf不得保存或retain context；不得建立临时thunk、adapter object、通用adapter inventory或第二套function-pointer ABI。无tracked 0.1 producer的legacy `vorton_fn_*` List HOF不构成保活理由，用户extern callback能力不随本集合扩大，纯Vorton重写这些方法也不并入#268/#269。P1 mixed trailing-args+formal-pack因prototype不兼容删除，P3双ABI+adapter inventory因更大authority与维护成本拒绝。R1/B-167纵切按P2前移并入#268/#269；B-168 failure/control与B-169其余研究仍按原排期并兼容该ABI。

> **边界**：Vorton 不计划实现 post-resume / multi-resume Full Algebraic Effects。现行公开模型固定为 tail-resumptive + abort；需要并发挂起的场景由 async 设计单独建模。

### 2.7 Effect 冒泡可见性

冒泡点是人的需求，不是编译器的需求。由 IDE 层解决：

```
// IDE 模式 A：行尾幽灵文字
let raw = fs::read_file(path)     ░ fs, fail<FsError> ░
let data = json.parse(raw)        ░ fail<ParseError> ░

// IDE 模式 B：底色高亮
// 纯表达式 = 无底色
// fail 效果 = 淡黄底色
// system capability = 淡蓝底色
// async 效果 = 淡紫底色
```

Formatter 可选将 effect 标注固化为源码注释：

```
//: 前缀注释，formatter 自动维护
let raw = fs::read_file(path)     //: fs, fail<FsError>
let data = json.parse(raw)        //: fail<ParseError>
```

---

## 3. 类型推断与标注系统

### 3.1 三层推断

```
// 局部推断
let x = 42                        // Int
let names = ["a", "b", "c"]      // List<Str>

// 双向推断
let f: fn(Int) -> Bool = fn(x) { x > 0 }

// 全局约束求解 + row poly
fn process(items) {
    items.filter(fn(x) { x.age > 18 }).map(fn(x) { x.name })
}
// 推断: items: List<{age: Int, name: Str, ..rest}>
```

**延迟解析（2026-05-24 确定）**：`let x = []` 允许——类型变量延迟到后续 usage 消歧。函数结束时类型变量仍未确定 → 报错（要求标注）。标准 HM unification 天然支持，无需特殊处理。

**有 bounds 的函数标识符不泛化（2026-06-27）**：`let f = display`（display 有 trait bounds）使 f 单态——f 的类型在 let 点实例化，不保留多态性。即 `f(42); f("hello")` 不合法（f 已绑定到首次使用的具体类型）。这是 HM value restriction 的自然延伸：有 bounds 的函数赋值给变量后，bounds 无法在变量层面泛化。若未来需要"多态函数变量"需重新审视此设计。

**递归组泛化（2026-08-28 用户决定）**：自递归与互递归 callable 先按现有调用图形成 SCC；组内所有成员共享 registration 产生的 monomorphic provisional variables，peer/self 引用不得在组闭合前执行普通 scheme instantiation。整组 body 约束求解完成后，才相对组外环境一次性 final-zonk、generalize、生成 canonical type/effect schema、最终化 HIR provenance，并原子 rebind 全组；失败不得发布部分成员。该协议统一覆盖 top-level、inline module 与 impl method SCC，不能为三个入口各建一套推断或 post-HIR patch authority。组间仍按依赖顺序使用已闭合 scheme。

**A1 单次推断实现边界（2026-08-28 用户批准）**：每个递归组成员的 body 只能执行一次 inference，产出 checker-internal `FnDraft`；draft 保留 raw params/return/effect/HExpr、exact owner/registration、final-zonk 所需的 type-param/bound/qualified-assoc provenance，以及 owner-scoped pending dictionary/evidence/anonymous-callable facts，但不得 drain、zonk、canonicalize evidence、重写 callable 或保存整个 `InferCtx`。整组共享唯一 constraint/UnionFind；全部 body 无诊断后，每个 draft 在最终 group 解上恰好一次消费 pending facts、final-zonk 与生成 HIR/schema。全组结果先完整验证，再原子 rebind/publish；禁止“constraint pass 后安装 scheme、再重新 infer body”的双 authority，也禁止把 raw UF/pending state塞进 TypedHIR/CoreHIR 延迟处理。

**Prelude A1 适配边界（2026-08-29 用户批准）**：compiler-owned prelude的Phase 1仍先注册全部固定std文件；Phase 2按已验证的0.1 file DAG顺序逐文件处理，每个文件的全部ordinary `Fn`/`Impl`只通过现有`infer_decl::check_registered_body` call graph、Tarjan SCC与A1 group runner，并由薄adapter安装该文件的exact file/frame/site。每个真实SCC才共享UF；same-file forward/self/mutual call不依赖源码声明顺序。Struct/Enum/Trait/Const/Extern等必要阶段保持；non-publishing duplicate extern先由现有single-decl路径finalize scheme，再从该file的Program排除，不能形成第二Fn checker。

`STD_FILES`只定义当前固定prelude文件inventory及跨文件无环顺序，不是函数声明依赖authority。0.1不建立跨文件recursive prelude SCC或multi-frame scheduler；发现反向跨文件edge/cycle必须在preflight稳定fail loud，禁止手工挪声明、调整文件顺序来掩盖依赖、premint schema或instantiate fallback。首次0.1发布后只有真实跨文件递归consumer出现时才重新审视完整global scheduler，不为它预留carrier或新backlog item。

**0.1 同检查单元具名函数值 closed-header 边界（2026-08-29 用户批准 H0）**：在同一个尚未完成A1闭合的scheduling unit中，具名callable作为first-class value使用时，其registration header必须已经递归closed；尤其不得依赖后续body inference才能确定effect tail。源码中pure provider写显式`with {}`，effectful provider写完整封闭`with { ... }`。若provider header仍开放，唯一infer binding result在该使用点给稳定source diagnostic，并建议补完整header或使用lambda wrapper；该失败不得反向给Tarjan补edge、不得触发name/scope扫描或提前发布provider scheme。

本限制不影响direct call、已经冻结header的import/re-export provider、lambda、函数参数转发、factory closure、dynamic call或HOF formal自身的open effect row。0.1迁移只给受影响provider补header，不改使用点，也不保留`e0986b7c`式SCC mini-resolver、ResolvedAST占位carrier或fallback。Post-0.1由高优先级B-204建立proper callable-occurrence ResolvedAST纵切并恢复同检查单元省略`with`的一等具名函数值；B-204完成前H0是唯一规范。

**0.1 enum constructor 函数值边界（2026-08-30 用户批准 B）**：带payload的位置constructor只允许以直接构造语法调用，例如`some(value)`或`Payload::Value(value)`；constructor标识符本身不能作为first-class function value传参、返回、存储或参与dynamic call。此类使用必须稳定报source diagnostic并建议显式lambda，例如`fn(value) { some(value) }`；编译器不得静默生成wrapper。直接位置构造、named-field构造、用户nullary variant每次求值产生fresh值，以及builtin `Option.none`的borrowed immortal singleton语义全部保持。

TypedHIR/PreCore必须把直接constructor语法按resolver/registry已选定的exact `VariantRef`与field refs降低为显式Core construct；constructor不产生callable effect row、generic callable schema或`ExecutableInventory`条目，也不进入dynamic callable candidate。只有源码显式lambda才作为普通callable进入后续管线。`compiler/`、`std/`与`examples/`当前没有constructor函数值consumer，0.1不为其保留implicit-wrapper、旧C constructor-callable shell、fallback、IR hook或post-0.1 backlog；首次发布后只有真实consumer与新的用户决定才能重开。

**0.1 public constructor re-export closure（2026-08-30 用户批准 B）**：一个facade的最终public exports中，每个单独公开或重命名的enum constructor都必须同时存在其exact `VariantRef.owner`对应的public enum type；两者不要求写在同一条`pub use`。因此`pub use leaf::{Token, Wrap}`及`pub use leaf::{Token as PublicToken, Wrap as Make}`合法，而只写`pub use leaf::Wrap`必须在re-export处稳定报source diagnostic并建议同时公开owner enum。直接公开enum仍自动携带其constructors；private/local import不受此public closure约束。

该规则由ModuleExports最终closure按exact owner验证，失败不得发布部分facade。0.1不新增constructor-owner transport、importer private registry、隐式公开owner、名字推断或future hook；constructor的字段类型、generic schema与physical identity始终只来自已公开owner enum的唯一definition/import contract。

一次 scheme instantiation 只产生一份完整 mapping receipt。type actual、effect formal→actual 与 trait dictionary/evidence 必须共同消费这份 receipt；禁止任何消费者再用 `build_scheme_var_map`、类型结构匹配或等价算法重建替换关系。receipt 是当前调用/函数值的 typed provenance，不是新 solver，最终随 HIR/Core 的 exact instantiation 关系运输。

Vorton 0.1 明确不支持 **polymorphic recursion**：递归环中的同一 callable 不能以彼此不可统一的类型实例调用自己或 peer。普通泛型递归仍支持，只要递归环内共享同一组类型参数；函数离开递归组后仍是正常泛型 scheme。Post-0.1 只有真实 consumer 证明该限制无法由普通泛型递归、显式数据建模或非递归 wrapper 表达时，才由 B-203 重新评估；0.1 不预留相关 IR、annotation 或 fallback。

**函数默认参数（2026-08-23 用户决定）**：Vorton 0.1 不支持 `fn f(x: T = expr)`。默认参数只省略调用点实参，显式 wrapper 函数可完整表达，却要求保存/复制 typed HIR template、freshen 全部 binder identity 并给每个下游阶段保留 default-specialization authority；compiler/std/examples 当前无 consumer。0.1 clean break 删除该语法与 call-site expansion，不影响 trait method default body。未来若出现独立 API 建模价值，再作为新 feature 评估，不保留兼容路径。

### 3.2 Formatter：标注密度管理器

Vorton 的 formatter 不只是语法格式化工具（缩进/空白/换行），它同时管理**标注密度**——基于编译器的类型推断结果，在源码上增删类型和 effect 标注。源码是规范形式，标注是可增减的文档层。

**核心设计原则：标注是文档，不是语义。** 编译器永远从函数体推断 convention，标注不改变编译行为（编译产物与无标注时相同）。标注缺失 = 最多 warning；标注存在即检查，**与推断不一致 = 编译错误**——统一信号「标注过期了」，修复手段是 `vorton fmt` 刷新（内部标注）或人工确认 pub 契约变更（见 3.2.3/3.2.4），而非改代码迁就标注。lv0 能编译的代码补全**正确**标注后编译行为不变。（2026-06-11 订正：原「不一致 = warning 从不 error」表述与 3.2.3「不匹配 = 编译错误」矛盾，以 3.2.3 为准。）

#### 3.2.1 Git 存储模型：lv0 / lv2（2026-05-24 确定）

Vorton 采用两级标注模型管理源码的标注密度：

| 等级 | 场景 | 标注密度 | 说明 |
|------|------|----------|------|
| **lv0** | 写时 | 零标注 | 编译器全推断。开发者本地编辑用 |
| **lv2** | Git 存储/推荐 | 完整语义标注 | 所有标注项均为合法可选语法 |

`vorton fmt` 将 lv0 自动补全为 lv2，幂等确定性。

**lv2 具体标注内容**：

| 标注项 | lv2 标注 | 说明 |
|--------|:---:|------|
| 函数返回类型 | ✅ | `fn f(...) -> Int` |
| effect row | ✅ | `with {fs, fail<E>}` |
| move 参数（声明） | ✅ | `fn f(move x: T)` |
| mut callsite | ✅ | `f(mut list)` |
| 闭包 effect | ✅ | 闭包的 effect 签名 |
| move callsite | ❌ | 编译器 use-after-move 够用，标了噪音大 |
| 局部变量类型 | ❌ | 过于繁琐（与 Rust/TS 一致） |
| borrow 参数 | ❌ | 默认即 borrow，标了是噪音 |
| 泛型实例化类型参数 | ❌ | `Vec.new()` 不写 `::<Int>` |

纯函数省略 `with` = 空 effect。lv2 中纯函数和 lv0 写法相同（无冗余标注）。

**模块边界标注（pub fn/trait/type）**：

| 标注项 | 规则 | 说明 |
|--------|------|------|
| return type | 必须有 | `vorton check` 缺失报 warning |
| effect row | 必须有 | 纯函数省略 with = 空 effect |
| move 参数 | 必须有 | 有 move 推断但无标注 → warning |
| mut 参数 | 必须有 | 已有 |
| 泛型约束 | 必须有 | `<T: Ord>` |
| borrow 参数 | 不标注 | 默认 |

**pub fn Formatter 策略**：

| 源码状态 | `vorton fmt` | `vorton fmt --force` | `vorton check` |
|---------|-----------|-------------------|-------------|
| 无标注（新 fn） | 直接补全 | 直接补全 | ⚠ warning "missing" |
| 标注正确 | 无操作 | 无操作 | ✅ |
| 标注 ≠ 推断 | 只报 warning，不改 | 更新标注 | ⚠ warning "stale" |

Breaking change 附加提示（不影响编译，只影响 warning 措辞）：
- borrow → move: ⚠ "breaking: callers' values will be consumed"
- move → borrow: ℹ "non-breaking: callers retain ownership"
- effect 新增: ⚠ "breaking: callers need additional effect"
- effect 减少: ℹ "non-breaking: fewer requirements"

**环境适配**：
- IDE：clean view 写 lv0，保存/提交时 fmt 补全为 lv2
- vim/emacs + LSP：inlay hints + 保存时 fmt
- GitHub 网页端：直接看 lv2（Git 存的就是）
- 纯文本编辑器：文件中是 lv2，手动 `vorton fmt` 补全

#### 3.2.2 扩展预设（不同上下文的查看模式）

lv0/lv2 是 Git 存储模型。在此之上，formatter 提供更多预设用于不同查看场景：

配置 `.vortonfmt.toml`：

```toml
[annotations]
preset = "api"
# 预设（常用组合的快捷方式）：
#   "none"   = 零标注，只格式化语法
#   "api"    = pub 函数签名（返回类型 + 参数类型 + effect）
#   "review" = 所有函数签名 + 调用点 mut 标记 + 模块 capability
#   "audit"  = review + 调用点 effect 冒泡（//: 注释）+ 复杂表达式中间类型
#   "full"   = 全标注（let 类型、lambda 返回类型、泛型实例化、推断 trait bound）

# 维度开关（覆盖预设的个别维度）：
[annotations.types]
# pub_fn = true         # pub 函数参数 + 返回类型
# internal_fn = false   # 内部函数签名
# lambda_params = false # lambda 参数类型
# lambda_return = false # lambda 返回类型
# let_bindings = false  # let 绑定类型
# generic_instantiation = false  # 泛型实例化参数

[annotations.effects]
# pub_fn = true         # pub 函数 with {...}
# internal_fn = false   # 内部函数 effect 签名
# callsite = false      # 调用点 //: effect 冒泡标注
# module_capability = false  # file / inline mod requires {...}

[annotations.mut]
# callsite = false      # 调用点 mut 参数标记：increment(mut n)

[annotations.traits]
# inferred_bounds = false  # 推断的 trait bound
```

预设是常用维度组合的快捷方式，维度开关可覆盖预设中的个别维度。例如 `preset = "review"` 再开 `callsite = true` 只加调用点 effect 标注，不开其他 audit 级内容。

同一份代码在不同等级下的表现：

```vorton
// preset = "none" — 零噪音
fn process(items) {
    items.filter(fn(x) { x.age > 18 }).map(fn(x) { x.name })
}

// preset = "review" — code review / 团队协作
fn process(items: List<User>) -> List<Str> with {console} {
    items.filter(fn(x: User) -> Bool { x.age > 18 }).map(fn(x: User) -> Str { x.name })
}

// preset = "audit" — 逐行审查，调用点 effect 可见
fn process(items: List<User>) -> List<Str> with {console} {
    items
        .filter(fn(x: User) -> Bool { x.age > 18 })  //: pure
        .map(fn(x: User) -> Str { x.name })           //: pure
}
```

降级/升级标注只需一个命令：

```bash
vorton fmt --preset=full    # code review 时全展开
vorton fmt --preset=none    # 日常开发最简洁
vorton fmt                  # 使用 .vortonfmt.toml 配置
vorton fmt --check          # CI 检查：是否符合配置（不修改文件）
```

#### 3.2.3 标注语义：pub 契约 vs. 内部文档

标注在两种位置有不同的语义强度：

| 位置 | 语义 | 编译器行为 | 理由 |
|------|------|-----------|------|
| `pub fn` 签名（返回类型 + effect） | **契约** | 不匹配 = 编译错误 | 调用方依赖此签名，是 API 边界 |
| 内部（let 类型、lambda 参数、局部 fn） | **文档** | 不匹配 = 编译错误 | 引导开发者运行 formatter 刷新 |

两者都在编译时检查，但 formatter 对它们的处理策略不同：

| 标注状态 | 内部标注 | pub 签名标注 |
|----------|---------|-------------|
| 缺失 | 按 level 补上 | 按 level 补上 |
| 正确（匹配推断） | 保持 | 保持 |
| **错误（不匹配推断）** | **直接更新** | **不动，报 warning** |

关键区别：内部标注是 formatter 管辖范围，过期了直接刷新；pub 签名是 API 契约，可能是有意的 breaking change，也可能是无意的 body 改动，formatter 不替人做判断。

#### 3.2.4 工作流

```
编辑代码
  → vorton fmt        # 内部标注自动刷新；pub 不一致的报 warning
  → vorton check      # pub 标注仍不一致 → 编译错误
  → 人决定是否更新 pub 签名
  → vorton fmt        # 确认一致
```

**Intentional breaking change**：改了 pub fn 的 body 后，编译器报"标注 Int，推断 Option\<Int\>"。开发者主动修改标注 → 这个改标注的动作本身就是 breaking change 的显式声明。

**Force mode**（绕过 pub 保护）：`vorton fmt --level=0` 去掉所有标注 → `vorton fmt --level=N` 重新生成 → pub 签名被重置为推断结果。两步操作 = 显式意图，不需要额外 flag。

**不想管标注的人**：工作在 Level 0，没标注就没不一致的问题。需要时一键 `vorton fmt --level=4` 全量生成。

#### 3.2.5 机械约束

三层保证标注与推断的一致性：

**1. 编译器**：标注存在就检查。不匹配 = 编译错误。不区分 pub/内部——统一的信号："标注过期了"。

**2. Formatter 性质**：
- **幂等性**：`fmt(fmt(code)) == fmt(code)` — 格式化两次 = 格式化一次
- **Round-trip**：`fmt(level=0, fmt(level=N, code)) == fmt(level=0, code)` — 升级再降级 = 降级
- **语义不变**：`compile(fmt(level=0, code)) == compile(fmt(level=N, code))` — 任何 level 编译到相同结果
- **规范化**：effect 排序、类型表示、空白 — formatter 输出唯一确定

**3. CI**：`vorton fmt --check` 验证文件是否符合配置等级，不符合 → 非零退出码。

#### 3.2.6 架构：Formatter 是 Checker 的下游

Formatter 需要类型推断结果才能生成标注，因此它在编译管线中的位置是 checker 之后：

```
源码 → Parser → AST → Checker → HIR（含完整类型 + effect）
                                   ↓
                             Formatter（读 HIR，按 level 回写标注到源码）
                                   ↓
                             格式化后的源码
```

纯语法格式化（`vorton fmt` 不带 `--level`）只需要 AST，不需要 checker。标注密度调整需要 checker 结果。Formatter 与 LSP 共享 checker 基础设施。

```toml
[annotations.effects]
ide_display = "inline"          # inline | gutter | highlight | none
materialize_as = "comment"      # comment | annotation | none
```

---

## 4. 方法调用与 impl 块

### 4.1 方法调用与 `::` 模块路径——两个独立范畴

Vorton 没有 UFCS（Uniform Function Call Syntax）。`::` 和 `.method()` 是两个不互通的世界：

- **`::`（模块路径）**：解析模块内的函数/常量/类型。`std::fs::read_file(path)` 调用 `std/fs` 模块的自由函数。
- **`.method()`（方法调用）**：解析 receiver 的方法。解析链：impl 方法 > trait 方法 > builtin 方法。**不**回退到自由函数。

```vorton
impl List<T> {
    fn map<U>(self, f: fn(T) -> U) -> List<U> { ... }
}

my_list.map(fn(x) { x + 1 })   // 解析到 List.map（impl 方法）
```

**自由函数不能通过 `.method()` 调用**：

```vorton
fn double(x: I64) -> I64 { x * 2 }
42.double()   // ❌ 编译错误——double 是自由函数，不在方法解析链中
double(42)    // ✅ 唯一正确写法
```

**方法不能通过 `::` 调用**：

```vorton
List::map(my_list, f)   // ❌ 不存在——:: 是模块路径，不是类型限定符
```

公理⑧在此被编译器结构天然保障——`::` 和 `.` 是两个互不重叠的语法域。LLM 训练数据里对数学函数用自由函数、对容器操作用方法的惯例足以区分，不需要编译器允许两种写法。

### 4.2 impl 的定位

impl 不是 OOP——没有继承、没有 vtable、没有 this 指针。self 就是第一个参数，impl 就是给函数挂了个类型标签做查找。

### 4.3 Trait Effect 子类型（2026-05-24 确定）

Trait 方法声明 = effect 上界（契约）。实现可以更窄：

- Implementer 的 effect 可以 ⊆ trait 声明（更窄有效）
- 泛型调用（`S: Storage`）：编译器用 trait 声明的 effect（保守）
- 具体类型调用（已知 `MemoryStorage`）：编译器用 impl 的实际 effect（精确）
- 私有 trait：effect 完全推断（所有 impl 的并集）
- impl effect 超出 trait 声明 → 编译错误

### 4.4 Trait 系统约束（2026-05-24 确定）

Vorton 有意选择简单 trait 系统，换取更强推断能力：

- 支持 blanket impl（`impl<T: A> B for T`），不允许 overlap
- 不支持 specialization（blanket impl + 具体类型覆盖）
- 性能特化由编译器单态化 + Phase E 热路径优化替代
- 0.1 trait只有方法签名；复用通过普通函数与显式impl表达
- 不支持函数重载（破坏 HM principal types）

### 4.5 泛型约束推断（2026-05-24 确定）

所有函数（pub/私有）统一推断泛型约束（类型检查 + lv2 标注）。单态化是 codegen 优化，和类型系统无关。

**推断算法**：方法调用 → 反查提供该方法的 trait → 添加约束。

- 方法名全局唯一时 100% 能推断
- 方法名冲突 = 语义错误（ambiguous method）
- 最小约束 = 只含实际调用方法对应的 trait（不做 supertrait 归并）
- 方法属于具体类型固有方法（非 trait）→ 推断为具体类型参数（非泛型）
- 0.1 不支持 return-position `impl Trait` / opaque return。推断只减少作者标注，不能隐藏 public API 的 concrete type；post-0.1 仅在真实 factory/iterator/closure consumer 下由 B-200 重审

---

## 5. OOP 手感模拟

底层没有 OOP 包袱，但给习惯 OOP 的场景提供等价的人体工学。

### 5.1 Trait contract 与显式实现

```
trait Describable {
    fn name(self) -> Str
    fn kind(self) -> Str
    fn describe(self) -> Str
}

struct User { name: Str, age: Int }

impl Describable for User {
    fn name(self) -> Str { self.name }
    fn kind(self) -> Str { "用户" }
    fn describe(self) -> Str { "${self.kind()}: ${self.name()}" }
}
```

Vorton 0.1不允许trait method body；每个impl显式实现完整contract。共同逻辑提取为普通generic helper，而不是由trait声明生成隐藏body。

### 5.2 Trait 组合（"多继承"无菱形问题）

```
trait Loggable {
    fn log_tag(self) -> Str
    fn log(self, msg: Str) -> Unit with {console}
}

trait Serializable {
    fn to_json(self) -> Str
}

impl Loggable for User {
    fn log_tag(self) -> Str { "User:${self.name}" }
    fn log(self, msg: Str) -> Unit with {console} {
        print("[${self.log_tag()}] ${msg}")
    }
}

impl Serializable for User {
    fn to_json(self) -> Str { ... }
}

// User 现在有 .describe() + .log() + .to_json()
```

### 5.3 显式组合转发

```
struct Admin {
    base: User,
    permissions: List<Str>,
}

impl Describable for Admin {
    fn name(self) -> Str { self.base.name() }
    fn kind(self) -> Str { self.base.kind() }
    fn describe(self) -> Str { self.base.describe() }
}

admin.describe()    // 显式转发到 base.describe()
```

Vorton 0.1不提供`delegate`surface。需要组合复用时写普通impl与普通method call；编译器不生成wrapper、associated binding或evidence forwarding。

### 5.4 Row Poly + Trait 交叉

```
fn greet_and_log<T: Loggable>(entity: {name: Str, ..} & T) -> Str {
    entity.log("被打招呼了")
    "你好, ${entity.name}"
}
```

### 5.5 动态分发（opt-in）⚠️ 设计愿景，尚未实现

```
fn process_all(items: List<dyn Describable>) {
    for item in items {
        print(item.describe())     // 动态分发
    }
}

let things: List<dyn Describable> = [user, admin, company]
process_all(things)
```

默认静态分发（泛型单态化），`dyn` 是主动选择运行时多态的标志。

### 5.6 OOP 概念映射表

| OOP 概念 | 本语言等价物 |
|----------|------------|
| class | struct + impl |
| 继承 | 多trait显式impl + 普通组合转发 |
| 接口 | trait |
| 多态 | 泛型（静态）/ dyn（动态） |
| 鸭子类型 | row polymorphism |
| mixin | 多 trait impl |
| 向下转型 | pattern match on enum |

---

## 6. 模块系统

文件即模块。每个 `.vorton` 文件是一个模块，通过 `use` 导入、`pub` 控制可见性。

### 6.1 文件级模块

```
// config.vorton
pub struct Config {
    pub db_url: Str,
    pub port:   Int,
}

pub fn load(path: Str) -> Config {
    let raw = fs::read_file(path)
    let table = toml.parse(raw)
    Config {
        db_url: table.get("db_url"),
        port:   table.get_int("port"),
    }
}
```

### 6.2 导入与可见性

```
// main.vorton
use config                          // 导入 config.vorton

let cfg = config::load("app.toml")

// 可以 pub use 重导出
pub use config
```

`pub` 可见性在多文件模式下强制执行，单文件模式不强制（向后兼容）。

### 6.2a Inline module 声明唯一性（2026-08-22 用户决定）

Vorton 0.1 不支持 partial/reopened inline module。同一 direct parent scope 的 module namespace 中，`mod name { ... }` 只能有一个 source declaration；第二个同名 `mod` 在其 AstSite 直接报 `E0207 Duplicate definition`，不得因两段具有相同 canonical owner/payload 而合并，也不得把 source duplicate 降为 `E0707 Ambiguous import`。不同 parent 下的同名 leaf（例如 `outer::inner` 与顶层 `inner`）仍是不同 logical module。

Import、re-export 与 same-origin diamond 是同一既有 declaration 的重复 delivery，可按 exact origin 幂等复用，不属于 source declaration reopening。多个 `impl` block 也不是 partial module，继续服从既有 impl/coherence 规则。若公开发布后出现跨文件 aggregation、generated extension 或 conditional compilation 等真实需求，必须以显式 `partial mod`、`namespace` 或 extension 设计重新立项；不能让普通重复 `mod` 静默获得第二种含义。

### 6.2b 文件模块 capability header（2026-08-23 用户决定）

文件本身是隐式模块。0.1 允许一个可选的 `requires {effects}` 文件头；它必须是文件中第一项非注释语法、每文件至多一次，并与 inline `mod name requires {effects}` 使用同一 capability checker：

```vorton
requires {unsafe}

use std::ptr
extern fn vorton_raw_alloc(count: Int) -> Ptr<Int>
```

存在 header 时，它是该文件模块的 effect ceiling；`requires {}` 表示纯文件模块。省略 header 时，普通 system/handled/fail/mut 不增加额外 ceiling，但 `unsafe` 从不隐式授权：使用或 discharge unsafe 原语、以及声明 `extern fn`，都要求有效的文件/inline-module `requires` 集合显式包含 `unsafe`。`unsafe {}` 仍是逐块责任签字，header 不能替代它；extern 声明本身是 ABI 签字，调用点保持 safe。拒绝再增加逐声明 `unsafe extern fn` 第二套授权语法。实现与仓内迁移由 B-156 跟踪。

### 6.3 未来方向 ⚠️ 设计愿景，尚未实现

- 完整 module signature conformance（post-0.1，B-192）：0.1 删除当前只注册 `SigDef`、不约束任何 module 的 `sig` placeholder；未来只有连同真实 `mod/module : Signature` conformance 一起才可重新加入
- 一等模块（模块作为值传递）
- ~~`inline mod` 块~~ ✅ 已实现（`pub mod name { ... }` 嵌套命名空间，声明自动加前缀 `mod_name::decl_name`）
- 相对路径导入（`super::`/`self::`）
- ~~Inline module capability 限制~~ ✅ 已实现（`mod name requires {effects} { ... }` 语法，E0405 检查函数推断 effect 是否在 requires 集合内）
- 文件模块 capability header（0.1，B-156）：`requires {effects}` 已拍板，尚未实现

---

## 7. 资源管理模型（2026-06-24 重新设计）

> **资源模型边界**：目标是 ownership + move + borrow + Drop/RAII，底层由 Perceus RC 兑现而不暴露 lifetime/borrow 类型。旧四通道总账、COW 三支柱和 `&T`/`&mut T` 二等类型等方案已废弃；现行 RC 契约见 §7.10–§7.11，历史过程只查 Git。

### 7.1 设计目标

用户心智模型和 Rust 一致——值有 owner，赋值有 move 语义，传参是 borrow，Drop 在 scope-end 执行。Vorton 不要求 lifetime 标注，没有 borrow checker，没有 `&T`/`&mut T` 一等类型。

**与 Rust 的核心差异**：

| | Rust | Vorton |
|---|---|---|
| 内存安全保证 | borrow checker（静态） | Perceus RC（运行时） |
| 引用类型 | `&T` / `&mut T` 一等类型 | 无——borrow 是调用约定，mutation 是推断 |
| 赋值（非 Copy/非 Drop） | move（源失效） | rc+1 共享（源仍可用） |
| 赋值（Drop 类型） | move（源失效） | 同 Rust（auto-move，推断） |
| 标注负担 | lifetime、`&`/`&mut`、turbofish | 零（lv0），formatter 补全（lv2） |

**设计原则**：
- 默认 borrow，显式 clone，Drop 自动 move——一条规则贯穿所有位置
- `mut` 关键字用户只在 `let mut`（rebind）手写；参数位的 mutation 由编译器推断
- 无 `&T`/`&mut T` 类型，无二等类型，无逃逸规则——用 rc+1 代替零成本引用，概念简洁
- 性能：rc+1 的代价由后续优化（reuse analysis / RC 消除 / 逃逸分析）收敛至零

### 7.2 赋值语义

| 场景 | `let x = y` | y 之后 |
|------|------------|--------|
| y 是右值（函数返回、字面量、构造器） | x 拥有 fresh 值 | 无 y |
| y 是左值，非 Drop 类型 | rc+1，x 与 y 共享同一对象 | y 仍可用 |
| y 是左值，Drop 类型 | auto-move（编译器推断） | y 失效（use-after-move 编译错误） |
| y 是标量（Int/Float/Bool/Char） | auto-copy（memcpy） | y 仍可用 |

```vorton
// 非 Drop：rc+1 共享
let xs = [1, 2, 3]
let ys = xs            // rc+1，两者指向同一 List
print(ys.len())        // ✅

// Drop 类型：auto-move
let f = File.open("x")
let g = f              // auto-move，f 失效
print(f.path())        // ❌ 编译错误：f 已 move

// 显式独立副本
let zs = xs.clone()    // 递归深拷贝，完全独立
```

**lv2 formatter**：对 Drop 类型的赋值显式标注 `move`——`let g = move f`。lv0 不写。

**无 `&T`/`&mut T` 类型**：非 Drop 赋值用 rc+1 代替零成本引用。rc+1 不是深拷贝（仅一个计数器加一），且可被后续优化（reuse / RC 消除 / 逃逸分析）消除至零成本。不引入二等类型、逃逸规则等复杂度。

#### 7.2.1 Struct update spread

对 struct，`Type { ..base, field: value }` 采用 **move spread**。它是消费 `base` 构造 fresh result 的语法，不是隐式 `.clone()`，也不按字段是否 shareable 选择不同的公开语义。

求值顺序固定为：`base` 只求值一次但暂不消费；随后所有显式 override RHS 按源码顺序完整求值，此时可继续读取或借用 `base`；只有全部 RHS 成功后，未覆盖字段才以 Own transfer 进入 fresh result，被覆盖字段在 `base` 中的旧值执行 Drop，override temporary 再转入对应结果字段，最后 `base` 整体失活。若任一 RHS 产生 `fail`，不得留下部分 move 的 `base`。override RHS 若试图在提交前 ownership-move `base` 的子字段，则按既有 partial-move 禁令拒绝；要保留该字段就省略 override，要保留整个 base 则显式写 `Type { ..base.clone(), ... }`。

**迁移前 0.1 internal-checkpoint Known Issue（2026-08-30 用户决定）**：上述是目标语义，迁移前 compiler并未对所有字段形状建立验证保证。当时的self-host只依赖8处全shareable spread；该历史路径使用physical RC dup并保留base完整。若未覆盖字段为owning或其资源行为依赖type parameter、因而需要exact Take，旧 compiler可能接受源码但错误处理source clear/Drop，产生leak、double-drop、UAF或错误析构顺序。该缺陷与反例作为迁移 oracle/已知问题保留；当前 Rust 重建只有在相应 Issue 与真实 gate 闭合后才能宣称 owning spread 已正确，不从旧 internal checkpoint 推导现行保证。

Vorton 0.1 不支持 named enum / variant update spread。`Variant { ..base, field: value }` 稳定产生 source diagnostic；在已经匹配出 exact variant 的 arm 中，显式重建全部字段，例如 `Circle { radius, color: next }`。这不影响 named-field variant construction、generic enum、pattern matching、字段 move 或普通 struct spread。编译器不为该纯缩写引入 runtime tag check、variant-refinement carrier、fallback 或第二条 MoveUpdate 路径。

### 7.3 参数传递

参数默认 borrow（调用约定：传指针，不 dup，不转移所有权）。

| 传参约定 | 语义 | lv0（用户写） | lv2（formatter 展示） |
|----------|------|-------------|---------------------|
| 只读借用 | callee 不修改，caller 保留 | `fn f(x: T)` | `fn f(x: T)` |
| 可变借用 | callee 修改，caller 可见 | `fn f(x: T)` | `fn f(x: mut T)` |
| 移动 | callee 取得所有权，caller 失去 | `fn f(x: T)` | `fn f(x: move T)` |

**用户定义函数的标注由编译器从函数体推断**：
- 函数体只读参数 → borrow
- 函数体修改参数（调用 mutating 方法、赋值字段） → mut（lv2 显示 `x: mut T`）
- 函数体将参数返回/存入字段/跨 spawn → move（lv2 显示 `x: move T`）
- Drop 类型参数被消耗 → auto-move

**extern fn 必须显式标注 `mut`**：编译器无法分析 FFI 函数体，mutation 必须由声明者标注。未标注 = 只读借用。

```vorton
// extern fn 的 mut 标注
extern fn sort_in_place(arr: mut List<Int>)          // mutates arr
extern fn read_all(path: Str) -> Str / {fs, fail<FsError>} // path is readonly
```

调用点 lv2 同步显示：`f(mut list)` / `f(move file)`。lv0 一律写 `f(x)`。

**`mut` 语法位置区分含义**：
- `mut` 在名称前（`let mut x`）= 关于名称（rebind）
- `mut` 在类型前（`x: mut T`）= 关于值（mutation）

函数类型中同样标注约定：`fn(T)` = borrow，`fn(mut T)` = mutable，`fn(move T)` = move。

#### 7.3.1 FlowIR 单一 Resource Planner（2026-08-22 用户理解并批准）

本节取代 2026-08-06 A′ 的实现分层，但不改变上文公开参数语义。此前实际尝试把 ownership authority 放在 checker 一侧，同时仍允许后续 lowering 与 Perceus ANF/RC 补造 cleanup-visible 槽，迫使 checker、Perceus、verifier 与 codegen 分别猜 ownership；`some(Resource)` 的 source slot 在 planner 之后才成为 `__anf`，因此出现接管后仍 Drop 的 double-drop。终态只允许一条无回边流水线：

```text
Parse / project Resolver / Type+Effect
→ 全部语义 lowering
→ ownership-neutral ANF + pattern projection + scope-result normalization
→ project-wide FlowIR identity/binder freeze
→ ONE ResourcePlanner
→ RcIR + ranked ResourceCertificate
→ certificate verifier
→ mechanical C codegen
```

**FlowIR 契约**：TypedHIR → CoreHIR 已完成derive、protocol for-in、and/or、dictionary、extern-forward与handled-effect evidence等0.1 semantic elaboration；函数默认参数、source trait default body、`delegate`、effect default body、`sig`与impl-member `extern fn`不属于0.1 surface。FlowIR只接收canonical CoreHIR body/contract；所有非原子值、pattern projection与value-yielding control result已有exact typed slot；Test、Const、Lambda/handler、derived/intrinsic/drop/dict helper等所有真实callable或helper body及显式contract进入一个共享`ExecutableInventory`。Enum constructor则是携带exact `VariantRef`与field refs的typed construction operation，不是callable inventory节点。Builtin inherent method在Core闭合前已是exact `IntrinsicRef` contract，而不是由backend按类型名/方法名补造的FFI body。System effect只随exact call contract进入AbiIR HostImport，不成为executable handler root。每个first-class callable同时携带freeze后的effect contract；dynamic candidate不得只按参数/返回类型匹配而丢失system/handled/fail/mut/unsafe或正式effect参数。Neutral ANF只保持同一evaluation region内严格左到右求值，不跨short-circuit、branch、loop/lambda、guard、catch/handle、unsafe或control-transfer边界，也不产生`Clone/Take/Drop/Cleanup`。FlowIR freeze后任何阶段新增binder都是internal error。

**Core effect closure（2026-08-26 用户批准）**：CoreHIR不存在“稍后再解”的effect。TypedHIR freeze先求解普通effect inference metavariable；合法多态tail必须generalize为带`owner + ordinal`的稳定`EffectParamRef`，无法归属formal scheme的raw UnionFind/type-var tail直接fail loud。`CoreCallableEffectContract`只允许canonical exact atoms（`SystemEffectRef`、`HandledEffectRef`、`fail<CoreTypeRef>`、`mut<CoreTypeRef>`、`unsafe`）及至多一个正式`EffectParamRef`；effect alias已展开。每个调用点在进入Core前固定formal effect参数的exact实例化。Core/Flow只运输、比较和验证这些契约，不重跑effect inference；ResourcePlanner不消费effect格。正式effect参数等价于已量化类型参数，不等于未解析变量。

递归 callable 的正式 effect 参数服从 §3.1 的递归组泛化：registration/provisional scheme 只提供组内共享 raw constraints，不能提前 mint `EffectParamRef`；definition schema 与 source-formal→actual instantiation 只在整组求解后发布。禁止按 first use、当前 executable stack、body/HIR 扫描、import 顺序或 raw id 猜 owner，也禁止在组后另建 HIR 修补 pass。现有 SCC scheduler、HM constraint/UnionFind 与 canonical header schema 是唯一 authority；inline/top-level/impl method 复用同一 group finalization。

**Identity**：具名 source/member 使用 resolver/registry 已选定 origin 构造的 typed `SymbolRef { origin_module_key, namespace_kind, canonical_payload, declaration_site_path }`；re-export 原样携带，same-origin diamond 自然相等，不消耗共享 source counter。局部槽使用 `SlotRef(module_key, domain, local_def_id)`；Lambda、call-result、ANF/result/projection 等 synthetic identity 使用 final normalized tree 的 owner+path `PathRef`，只服务 planner/certificate，不进入 C 名称。Static call 必须携带 `CalleeRef`；dynamic call 必须落到 exact callable slot，freeze 后缺 identity 直接 fatal，Planner 不查 name/resolver/FnType fallback。

**唯一 Planner 的固定内部顺序**：

1. `Logical OwnershipShape` 与 `Physical RcShape` 分轴求有限最小不动点。前者记录 direct Drop / may-unique-own / type-parameter 依赖，决定 compile-time失效与 `Take`；后者分别记录 aggregate shell RC、direct payload 的 `NoRc/VortonRc`、boxing/drop glue 与参数依赖，决定物理 `Clone/Drop`。Foreign/raw payload只能令对应字段或formal为`NoRc`，不得抑制外层aggregate shell或managed sibling的cleanup。Int/Ptr 的显式 FORCE 可逻辑失效但不参与 RC；shareable RC 的 Own edge 产生 `Clone`，unique Resource 的 Own edge 产生 whole-slot `Take`。
2. Project-wide callable graph在solve前一次冻结，统一direct/member/extern/effect/dictionary、explicit ImplFn、function value/HOF、Lambda、factory/call-result、re-export/diamond与extern bridge。Enum construction只贡献其显式字段Own/value-result edge，不伪装为callable node。参数格为有限`Borrow < MutBorrow < Own`，FORCE独立；返回值保留owned/borrowed contract。Worklist从bottom单调求least fixed point，solve期间禁止新增node/edge，也不回写或重跑type/effect inference。
3. 每个 executable body 建 ephemeral CFG，以 `Empty / Live / Moved / MaybeMoved` 做 branch/loop/catch join，并一次性输出 `Clone/Take/Drop/Cleanup`。每个 value edge 必须精确分类 Borrow/MutBorrow/Own/Discard；may-own projection 的 partial move 按现行设计 fail loud，只有完整 slot 可 `Take`。

**0.1 raw generic aggregate clean break（2026-08-30 用户批准）**：`Ptr`或non-RC extern payload不得递归进入generic aggregate storage。Checker在TypedHIR/Core publish前稳定拒绝`List<Ptr<T>>`、`Option<ForeignHandle>`、`Map<K, Ptr<V>>`及用户generic struct/enum的同类actual；direct raw value与普通Vorton-managed generic container/HOF保持。由此B-min hidden evidence、packed shell mask、payload-policy LFP与runtime `NoRc/VortonRc`分支全部不存在，也不得以name/header sniff、function table或第二solver恢复。Aggregate shell继续按普通owner规则release；该规则不授权whole-value foreign cleanup veto。

**A′ 与 S′ 统一**：exact source clear、overwrite old-value Drop、exact-none 与 scope/early-exit cleanup属于同一个 slot-state machine，不再有独立 S′ producer/tail analysis。所有可能 physical-own 的 storage 在 normalization 预建并初始化为空；Assign 固定为“完整求值 RHS → ownership转入预建 temp → Drop旧target → temp写入target → 清temp ownership”，RHS divergence无后继。`Take` 固定为保存 exact source 值并立即清空 source；normal/return/break/continue/current-frame catch/handler exit按逆词法序显式 cleanup。`vorton_drop(NULL)`、tagged scalar与never-drop `Option::none`均no-op；Extern/Ptr/NoDrop仍由Physical RcShape排除。

**Planner 后职责**：RcIR 的 binder set 与 FlowIR 完全相同，资源操作全部显式；旧 Perceus 不再是独立 ownership pass，不造 `__anf/__rc_scope`、不猜 fresh/escape/sink/producer。Verifier不运行resolver或第二solver：certificate记录frozen graph hash、seeds、final cells、每次提升的rule/premises/严格较低rank、CFG states与每个RC op witness；检查全部约束与有限推导两侧，从而证明 claimed 解恰是least fixed point，并验证每条路径的owner守恒。Codegen只接受verified RcIR，机械lower `Clone`、`Take(save; source=NULL)`、`Drop`与cleanup。

**终止性与入口统一**：FlowIR的type/callable/edge/slot/CFG集合有限且solve前冻结；shape bit只升一次，param mode最多升两次，FORCE只升一次，result与CFG格有限，固定worklist必停，无timeout或任意fuel。Single-file包装为单节点ModuleGraph，和project共享prelude/intrinsic inventory、identity freeze、Planner、certificate verifier与codegen入口；`ModuleKey`属于identity，prefix只影响输出符号。

**现行能力边界保持**：普通closure/可逃逸tail-resumptive handler不得捕获may-unique-own外部binding；未解析TypeVar fail closed；partial move拒绝。B-168固定failure/control ABI前，任何必须跨现行`setjmp`边界修改外层cleanup-visible slot的Take继续fail loud；跨帧abort unwind由B-168/B-002以同一FlowIR/ResourcePlanner failure edge续接，不冒充本checkpoint已完成。

### 7.4 别名追踪与 mutation 安全

非 Drop 类型的 `let x = y` 创建别名（rc+1，同一对象）。编译器在函数内追踪别名关系，**mutation 后旧别名失效**：

```vorton
let xs = [1, 2, 3]
let ys = xs             // ys 别名 xs
print(ys.len())         // ✅ mutation 之前，ys 有效
xs.push(4)              // mutation 点——ys 在此失效
print(xs)               // ✅ xs 是 mutator
print(ys)               // ❌ 编译错误：ys 在 xs mutation 后失效
```

**规则**：
1. `let y = x` 建立别名关系（编译器记录 y 来自 x）
2. 对 x 的 mutation（调用 mutating 方法、赋值字段）使所有 x 的别名失效
3. 对别名 y 的 mutation 同样使 x 和 x 的其他别名失效
4. 失效后使用 = 编译错误
5. 别名的生存期到其所在**大括号作用域**结束——不是函数末尾
6. 编译器可**隐式缩小别名生存期**至最后使用点（NLL 风格），使本来受限的代码通过检查——精度待定（见下文设计探针）
7. **不跨函数追踪**，不需要 lifetime 标注

**mutation 判定（自底向上，完备要求）**：
- **赋值** = mutation：binding 重赋值与字段赋值（`x.field = val`）。0.1 的 index expression 只读；`x[i] = val` 与 compound index assignment 稳定拒绝，不隐式改写成 setter
- **容器 mutation**：使用显式 mutator，例如 `xs.set(i, value)` 与 `map.insert(key, value)`；这些方法的 `mut self` / callable resource contract 是唯一 mutation authority，不能由赋值语法或后端名称表重建
- **用户函数**：编译器分析函数体——若函数体 mutates 参数，该参数推断为 `mut T`，该调用即 mutation
- **extern fn**：必须在声明时显式标注 `mut`（§7.3）——未标注 = 只读
- **完备性要求**：别名追踪系统上线时 mutation 判定必须覆盖所有路径（赋值 + 推断 + FFI 标注），不接受渐进白名单。否则会出现漏报导致运行时 UAF——与 Rust 对 `&mut` 的要求同等严格

**别名在循环中的行为**：参考 Rust 的循环别名规则——循环体内的 mutation 使循环外定义的别名在**整个循环体**内失效（保守假设循环体执行多次）。

**NLL 设计探针（待完成）**：Rust 从词法作用域（1.0）演进到 Non-Lexical Lifetimes（1.31，2018 edition），使用 CFG-based liveness 精确计算引用生存期。Vorton 需要研究：(1) Rust NLL 的实现复杂度（CFG 构建 + dataflow）；(2) 简化版（块级 liveness，不做完整 CFG）是否够用；(3) 对用户体验的影响（哪些 pattern 在哪种精度下会被拒绝）。决策后更新本节。

**修复方式**：
```vorton
// 方式 1：clone 拿独立副本
let ys = xs.clone()     // 递归深拷贝，完全独立
xs.push(4)              // ✅

// 方式 2：别名用完再 mutate（NLL 可能自动通过）
let ys = xs
print(ys)               // ys 最后使用
xs.push(4)              // ✅ NLL 检测到 ys 此后无使用，别名已结束

// 方式 3：显式作用域限制别名
{
    let ys = xs
    print(ys)
}                       // ys 作用域结束
xs.push(4)              // ✅
```

**参数的别名安全**：callee 推断为 `x: mut T` 时，caller 在调用期间不能有其他别名指向同一值。编译器在调用点检查。

### 7.5 `mut` 关键字

`mut` 在用户代码中**只有一个含义**：rebind（重新绑定）。

```vorton
let x = 5               // 不可 rebind
let mut x = 5            // 可 rebind
x = 10                   // ✅
```

参数位的 `mut`（表示可变借用，`x: mut T`）和 `move`（表示所有权转移，`x: move T`）**由编译器推断**，用户不写（lv0）。lv2 formatter 展示推断结果。

`mut` 不出现在类型系统中——没有 `&mut T` 类型。Mutation 信息通过参数推断 + lv2 标注 + 闭包捕获列表传达可见性。

### 7.6 Drop / RAII

```vorton
impl Drop for FileHandle {
    fn drop(self) {
        self.close_internal()
    }
}
```

**规则**：
- `impl Drop` 的类型在赋值时 auto-move（编译器推断，lv2 显示 `move`）
- Drop 类型 rc 恒为 1（auto-move 保证唯一 owner）→ scope-end drop = rc 归零 = **与 Rust 析构时机完全一致**
- Drop 类型不可 Clone（`impl Drop` 禁止 `impl Clone`——资源不可复制）
- 0.1 用户 Drop body 的最终推断 effect row 必须为空；system/handled/fail/逃逸 mut均fail loud。词法 `unsafe` 即使被discharge，仍须满足模块许可
- 当前无处在对象分配中保存析构所需的 runtime trait evidence，因此 `impl<T: Trait> Drop for Box<T>` 这类带 type-parameter bound 的实现必须在注册前 fail loud；不需要 runtime evidence 的无 bound `impl<T> Drop for Box<T>` 仍可使用。未来若支持前者，evidence 必须成为对象布局与 drop glue 的显式、可验证契约，不能在析构调用处填占位值。
- Drop 顺序对齐 Rust：同 scope 逆序 / struct 字段声明序 / 容器元素序
- `drop(x)` 提前释放
- abort 路径（fail/catch）的 drop-aware unwind 保证全路径 RAII；当前 C 后端尚未兑现，B-168 先确定可审计、可移植的控制流模型，再由 B-002 Phase 2 实现
- Effectful destructor与latent destruction contract不属于0.1；B-198只在真实File/Socket/Transaction consumer出现后重新Argument，不预建空`DropEffectSet`

### 7.7 `Rc<T>` 与 Clone

**`Rc<T>`**：非 Drop 包装器，用于共享 Drop 类型。

```vorton
let f = Rc.new(File.open("data.txt"))
let g = f              // rc+1（Rc 本身是非 Drop 类型），两边都活
// 最后一个 Rc 引用消亡时，内部 File 的 Drop 执行
```

非 Drop 类型天然 rc+1 共享，不需要 Rc。Rc 只在"需要共享一个 Drop 类型"时使用。`Weak<T>` 配合 `Rc<T>` 打破循环引用（`.downgrade()` / `.upgrade() -> Option<T>`）。

**`.clone()` = 递归深拷贝**（Rust Clone trait 语义）：

```vorton
let a = [[1, 2], [3, 4]]
let b = a.clone()        // 新外层 List，新内层 List，元素 copy
b[0].push(5)
print(a)                 // [[1, 2], [3, 4]]——不受影响
```

- struct/enum：逐字段递归 clone
- 容器（List/Map/Set）：新容器，元素递归 clone
- 标量：copy
- Drop 类型不可 Clone（compile error）
- 所有非 Drop 类型自动 derive Clone

**与 `let x = y` 的区别**：`let x = y` = rc+1（共享同一对象，受别名追踪约束）；`x.clone()` = 完全独立副本（无别名关系）。

### 7.8 闭包捕获

闭包捕获由编译器推断。lv2 formatter 展示捕获列表：

```vorton
// lv0
let mut counter = 0
let name = "hello"
let inc = fn() { counter = counter + 1; print(name) }

// lv2（formatter 展示）
let inc = fn() [mut counter: Int, name: Str] { ... }
```

**捕获规则**：
- 只读使用且捕获类型已证明 non-may-own → borrow 捕获（rc+1 on captured value）
- mutation 使用 → mut 捕获（共享可变绑定，box 化）
- spawn 闭包 → move 捕获（强制，防止 data race）

当前普通 closure 没有 FnOnce/consume-call 形态，也没有在 `FnType` 中携带 capture ownership shape。因此 ordinary borrow/mut capture 不得接收 may-own 外部 binding；未解析 TypeVar 按 may-own fail closed。需要把资源交给 closure 的代码必须等待显式 consume-capture 模型，不能通过隐式 rc+1 延后 Drop，也不能把所有普通函数值统一线性化。该限制不影响 closure 内部新建并在自身作用域内消费的资源；nested closure 仍按各自 exact free-binding identity 独立检查。

Tail-resumptive handler arm 会被物化进 effect evidence；该 evidence 又可能由 handler 内创建的 effectful function value 持有并逃出 `handle`。因此 handler 构造时必须按 exact `DefId` 检查 outer capture：Resource、transitive may-own wrapper、`Any` 与未解析 TypeVar 一律 fail loud，不能把借用藏进可逃逸 evidence。已证明 non-may-own 的捕获仍按现行词法 evidence ABI 保留；其中只有 physical-RC-eligible 值取得 `vorton_dup` 并在 env mask 中标为 owned，`Ptr`、direct extern 与 contains-extern 值保持 RC-excluded。`fail.raise` abort arm 由 C 后端在 `setjmp`/`longjmp` catch path 内联执行，不创建 handler closure；它保留现有 outer-move 禁令，并在当前函数作用域读取外层值。

**可变捕获豁免别名规则**：闭包的 mut 捕获创建共享可变绑定（原变量和闭包双方均可修改），不适用 §7.4 的别名失效规则——这是共享可变的 explicit opt-in。lv2 捕获列表 `[mut counter]` 标明。

### 7.9 `mut<T>` marker effect

`mut<T>` 是 effect row 中的参数化 marker，用于记录当前计算触及的可变状态类型。它采用**多实例**语义：`mut<Int>` 与 `mut<Str>` 可以同时存在；bare `{mut}` 每次实例化为新的 marker，不能按普通同名 custom effect 强行合并 payload。

它与另外两种 mutation 信息互补而不互相替代：

- 参数位 `x: mut T`：调用会修改哪个参数；
- 闭包捕获 `[mut counter]`：闭包共享修改哪个绑定；
- effect row `mut<T>`：计算能力/effect 多态中的 mutation marker。

局部 `let mut` 的纯局部变化在函数边界由 `cancel_local_mut_effects` 取消；range iterator 等真正携带 marker 的调用仍会传播。模块 capability、effect alias 与 handler 只按现行 effect-row 规则处理，不能依据旧“已移除”叙述丢弃它。

### 7.10 Perceus RC 实现模型

用户面语义（§7.2–§7.8）不变，本节定义 RC 如何兑现这些语义。

**分层**：

| 层 | 内容 | 状态 | backlog |
|----|------|------|---------|
| **L0 RC 核心** | dup/drop 插入，归零即 free | ✅ | B-012 |
| **L1 借用引擎** | clone-all-escape，参数 borrow 不 dup | ✅ | B-098 |
| **L0/L1 完整化** | total drop pass + 静态 leak verifier（verify_rc.vorton） | ✅ | B-104 |
| **L4 标记指针** | 标量低位 tag，不进堆 | ✅ | B-080 |
| **L2 Drop/RAII** | 用户 impl Drop，abort unwind，Weak\<T\>，**含简单 move checker**（consumed-flag） | 待做 | B-002 |
| **L1.5 别名追踪** | §7.4 非 Drop 类型 mutation 安全 + mutation 推断 + NLL（deferred: L2） | 待做 | B-110 |
| **L3 Reuse (FBIP)** | rc==1 原地改写，drop-reuse 配对 | 待做 | B-079 |
| **L5 RC 消除** | 编译器证明 rc 恒 1 → 跳过 dup/drop | 未排期 | — |

**关键映射**：
- `let x = y`（非 Drop）→ perceus 发 `vorton_dup`（rc+1）
- `let x = y`（Drop）→ perceus 不 dup（move，指针转移）
- 参数传递 → 不 dup（borrow 调用约定）
- 逃逸（return / 存入容器）→ clone（`HExpr::Clone`，rc+1）
- scope-end → `vorton_drop`（rc-1，rc=0 则释放）
- Drop 类型 rc 恒 1 → scope-end drop 总是释放 = Rust 语义

**循环引用策略**：`Weak<T>` 配合 `Rc<T>`（§7.7）。不引入 cycle collector（破坏 RAII 确定性析构）。图结构推荐 arena + index 模式。

**RC 性能立场**：RC 计数操作当前有运行时代价——是优化器成熟度问题，非模型税。树状所有权（静态可证唯一）处的计数操作全部可被优化消除（L3 reuse / L5 RC 消除 / 逃逸分析）；计数只保留在真共享处——该场景 Rust 同样付 `Rc`/`Arc` 的钱。

> **实现细节记录**：L0–L4 的完整实现过程（clone-all-escape 模型、B-103 return-mode 分类、B-104 D1–D9 nine-pass 演进、verify_rc 静态检查、Type-DAG RC 试错等）见 git history（2026-06-04 至 2026-06-16 的 design.md 版本）。

### 7.11 RC 正确性边界

- Drop 的公开时机是 scope-end；只有类型无用户 Drop 且不被 `Weak<T>` 指向时，后端才可按 as-if 提前释放。
- Perceus 以 owner/borrow/escape 分类插入 clone/drop；函数参数默认 borrow，逃逸值取得独立所有权。
- total drop pass 覆盖 named value 与中间 fresh-owned 临时；post-RC HIR 必须通过 `verify_rc` 的 LEAK/UAF/BALANCE 检查。
- trait/effect evidence 的构造和生命周期必须在共享 HIR 可见；后端不得私自合成 verifier 看不见的 owned 图。
- 无环数据要求精确回收；环通过 `Weak<T>` 显式打破，不引入 cycle collector。
- 旧 clone-all-escape 试错、D1–D9 逐轮测量、分配计数和 commit 过程只保存在 Git；它们不是当前设计契约。

### 7.12 unsafe 区域图景（2026-06-11 确定，细化归 B-106）

**定位：unsafe 区是所有权模型全部张力的最终出处——它定义「语言不在安全区处理什么」。** 三栏总账，每个表达力缺口必居其一、不允许悬空：

| 栏 | 内容 |
|---|---|
| **A 安全区**（目标 ≥99% 用户代码）| 共享→Rc/Arc，环→Weak（§7.7），视图→Span/(offset,len)/arena+index，深层可变→mut 参数线程化 + 嵌套 lvalue path，性能→引擎优化（reuse/unboxing/RC 消除）|
| **B unsafe 区**（库作者，少数）| 零拷贝视图（指进 buffer 的 slice）、自引用/侵入式结构、RIIR 容器底层（malloc/指针算术/未初始化内存）、FFI 裸指针 |
| **C 明确不做** | first-class 借用 / lifetime 标注 / borrow checker；安全区的跨函数零拷贝视图；cycle collector |

栏 C 的可信度由栏 B 背书：「X 不在安全区」的回答是「去 unsafe 区」，与 Rust 同构——撤销旧「Vorton 用类型系统消除 unsafe 的需求」立场（原 backlog「不做的控制力」表）。

**形态 = `unsafe` effect**：unsafe 原语操作产生 `unsafe` effect，签名可见、自动冒泡。不可被普通 handler 处理——唯一消除方式是 discharge。

**Discharge 模型 = 两级，关键字与 Rust 一致（2026-06-11 用户拍板）**：
- **模块级 = 许可**：文件模块用第一项 `requires {unsafe}` header，inline module 用 `mod name requires {unsafe}`；未显式授权的模块内不可使用 unsafe 原语；
- **块级 = 责任**：`unsafe { ... }` 吸收块内 unsafe effect，块 = 作者签字「此处不变量已人工验证」，等价 Rust unsafe block。安全封装因此成立：std 容器内部 unsafe、pub 签名纯净；
- 配套 `vorton audit unsafe`：列出全代码库 discharge 点。

**与公理④（不信任程序员）的接法**：discharge 点清单 = 整个代码库需要人类审查的全部位置——有限、可枚举、签名可定位。agent 在安全区自由工作；lint 可配「agent 不得新增 unsafe 块」，使人类审查面的增长本身受控。Rust 只有隔离（靠人 grep），effect 系统补上类型层自动追踪。

**与 RC 的交互（雏形已验证）**：unsafe 区裸指针不参与 RC——extern type 类型级 RC 排除（B-104 D1 规则①：不 Clone/不 Drop/不入 owned）即此规则的现实先例，`Ptr<T>`（2026-06-13 定名）为其推广。跨界点 = 所有权显式移交（per-type 三件套，见下）。

**B-106 正文拍定（2026-06-13 Discussion，下列即真值）**：

**`Ptr<T>` 形态**：typed（offset 按 `size_of<T>` 步进，reinterpret 走显式 `cast`）；**单一类型不分 const/mut**（Rust `*const`/`*mut` 三作用中 variance 与借用来源追踪对 Vorton 不存在，仅剩文档价值——公理⑧不分，const 意图归注释与封装 API 命名）；`Ptr<T>` 是**普通值**——copy 语义、不参与 RC、存字段/传参/比较皆 safe，**操作才产生 unsafe effect**（effect 挂操作不挂类型，与 fail 同构；安全封装因此成立——RIIR 容器 struct `{data: Ptr<T>, len, cap}` 定义本身不被感染）。

**原语集 v1**（由栏 B 四场景倒推）：

| 原语 | 签名（示意） | effect | 备注 |
|---|---|---|---|
| alloc | `alloc<T>(count: Int) -> Ptr<T>` | unsafe | 返回**未初始化**内存 |
| dealloc | `dealloc<T>(p: Ptr<T>, count: Int)` | unsafe | 带 count：对齐正确性 + sized-dealloc 留门 |
| read | `p.read() -> T` | unsafe | 读出 + **dup（RC+1）**，buffer slot 不受影响（peek 语义） |
| take | `p.take() -> T` | unsafe | 读出**不 dup**，buffer slot 作废（move out 语义） |
| write | `p.write(v: T)` | unsafe | 按位 move in，**不 drop 旧值**，v 从 RC 世界移出 |
| offset | `p.offset(i: Int) -> Ptr<T>` | unsafe | **inbounds 语义**（程序员承诺 → `getelementptr inbounds`，换别名分析/向量化） |
| cast | `p.cast<U>() -> Ptr<U>` | safe | 造值不炸，deref 才炸 |
| copy | `copy(src: Ptr<T>, dst: Ptr<T>, count: Int)` | unsafe | memmove 语义；nonoverlapping 变体按实测需求后加 |
| addr / from_addr | `p.addr() -> Int` / `Ptr::from_addr<T>(a: Int)` | safe | 对齐计算/tagged pointer；危险链条被 deref（unsafe）卡死 |

**read/take/write 所有权语义 = Perceus 接口承重墙**（2026-06-27 Discussion 拍板 read/take 拆分）：

- **`read`（peek）**：读出值 + `vorton_dup`（RC+1），buffer slot 保持有效。可重复读。Perceus 视为「产 owned」——落进 B-103 return-mode 既有分类，零特殊化。RIIR 容器 `get()` = `self.data.offset(i).read()`，一行搞定。
- **`take`（move out）**：读出值、不 dup。buffer slot 作废（重复 take 同位 = double-free，签字内容）。等价 Rust `ptr::read` 契约。RIIR 容器 `pop()` = `self.data.offset(self.len-1).take()`、`drop` 清理 = 逐元素 take。
- **`write`（move in）**：v 按位写入裸内存，不 drop 旧值（旧值可能未初始化）。v 从 RC 世界移出。RIIR 容器 `push()` = `self.data.offset(self.len).write(v)`。
- **`replace` = `take` + `write`**：RIIR 容器 `set(i, v)` = `self.data.offset(i).take(); self.data.offset(i).write(v)`——take 旧值（scope-end drop）+ write 新值，两步显式。

buffer 内的值 = RC 世界之外、所有权由封装作者人工记账。拆分 read/take 的设计动机：Rust 的 `ptr::read`（= Vorton 的 `take`）是 move 语义，但 RIIR 容器的 `get()`（非破坏性读取）是最高频操作——如果 "read" 是 move，get 需要 read+dup+write_back 三步，啰嗦且易错；拆为 read（peek）+ take（move）后，高频路径一行完成，低频路径（pop/drop）用 take 同样清晰。

**相对 Rust 的三处简化（明确不做）**：① 无 `MaybeUninit`——Rust 需要它是因为 safe 区要能持有未初始化值，Vorton 的未初始化内存只活在 Ptr 后面、永不以值形态进安全区，「read 前已 init」即签字内容；② 无泛型 `transmute`——99% 用例 = 指针 reinterpret（走 cast）+ 标量 bits 互转（具体 intrinsic 按需提供），最危险的门开最窄；③ v1 无 volatile/atomic——§8 并发定型后随 B-007 系再议。

**extern fn 边界 = 声明处签字**：extern fn 声明要求所在文件 header 或 inline module clause 的有效 `requires` 集合显式包含 `unsafe`，声明 = 签字「签名忠实于 C 实现」，调用点 safe（与现状 std extern 调用兼容；Rust 2024 `unsafe extern` 同方向）。**`extern type` 与 `Ptr<T>` 并存两层**：extern type = 不透明句柄（不可 deref/offset，持有传递天然 safe）；`Ptr<T>` = 可算术可解引用的真指针。大量 FFI 永远停留在句柄层，分层本身是缩小 unsafe 面的杠杆。

**跨界移交 = per-type 三件套，不做泛型 `addr_of`**：泛型「对任意安全值取指针」把引擎私有的值表示（box 布局/unboxing/单例化——B-104 D4 dict、D6 none/const 均在动）变成可观测 API，「优化不可观测」被堵死。跨界走容器显式 API：`List<T>::from_raw_parts(p, len, cap)`（移交进 RC 世界）/ `list.into_raw_parts()`（移交出，consume）/ `list.as_ptr()`（borrow 性质，指针有效期 ≤ 宿主存活 = 签字内容）；Str 同构。FFI 调用保活无需新机制（实参 borrow 语义已覆盖）。

**`@repr(C)` 的精确角色**：read/write 按位搬 **T 的值表示**（box 指针或 unboxed 标量），任意 T 永远合法（容器场景无需布局承诺）；需要 `@repr(C)` 门票的是**字段级解释**（把 C 填的内存按字段读、字段指针投影）——默认布局编译器自由重排。投影形态（`offset_of` intrinsic vs 投影语法）归实现项 B-125。

**验收工具 v1** = ASan 两档纪律 + `vorton audit unsafe`；miri 类解释器远期挂账不立项。

**RIIR 边界已定（2026-06-13 拍板）= 全部自己实现**：容器底层（vector/string/unordered_map）全部用纯 Vorton + `Ptr<T>` 重写，不保留 C++ STL 依赖（「系统语言标准库借 C++ = 玩具」）。unsafe 原语实现 = B-125（P3，XL）；容器 RIIR = B-125 后立项。

**RIIR 最终形态（2026-06-30 拍板）= `vorton_runtime.c` 纯 C ~400 行**：

作为 native 语言，runtime 中不应有 C++ 成分。RIIR 完成后 `vorton_runtime.cpp` 改为 `vorton_runtime.c`（纯 C11），消除全部 C++ STL 依赖（`std::string` / `std::unordered_map` / `std::unordered_set` / `std::vector` / `std::algorithm` / `std::sstream`）。最终 runtime 只保留以下纯 C 内容：

| 层 | 内容 | 约行数 | 理由 |
|----|------|--------|------|
| RC 核心 | `vorton_alloc` / `vorton_dup` / `vorton_drop` / `drop_table` / typeid 常量 | ~150 | 自举循环依赖——Vorton 的 RC 系统无法管理自己的 RC 系统；这是唯一不可消除的 C 层 |
| Boxing | `vorton_box_int` / `vorton_unbox_int` / `vorton_box_float` / `vorton_box_bool` | ~30 | 极简 C，codegen 内联调用频繁 |
| IO / OS | `vorton_print` / `vorton_read_file` / `vorton_write_file` / `vorton_args` / `vorton_cwd` / `vorton_exit` / `vorton_path_*` / `vorton_file_exists` | ~100 | C ABI syscall wrapper，本来就是纯 C |
| Fail effect | `vorton_catch_push` / `vorton_catch_pop` / `vorton_raise` / `vorton_try` + `setjmp`/`longjmp` | ~60 | C ABI，Vorton 无对应原语 |
| Ptr 原语 | `vorton_raw_alloc` / `vorton_raw_dealloc` / `vorton_ptr_copy` / `vorton_slot_*` | ~30 | `malloc`/`free`/`memmove` 薄 wrapper |
| 初始化 | `vorton_runtime_init` / `main` | ~30 | 入口 |

**迁移到 Vorton 侧的内容**（B-152 P0–P5）：

| 内容 | 迁出方式 |
|------|---------|
| Map / MapInt（`std::unordered_map`） | P3：Vorton 开放寻址哈希表 + Hash trait |
| Set / SetInt（`std::unordered_set`） | P4：`Map<T, Unit>` wrapper；公开操作要求 `Hash + Eq`，expected O(1)，无隐式线性 fallback |
| StringBuilder（`std::string`） | P0（pilot） |
| Str 操作中的 `std::string` 临时计算（replace/pad_start/pad_end） | P1 Step 2 |
| List HOF（map/filter/fold/any/all/find 等） | 已部分迁移（P2），HOF 可全迁 Vorton |
| `vorton_get_builtin_dict` + primitive trait closures | primitive `impl Eq/Ord/Debug/Hash for Int/Str/...` 全用 Vorton 写后自然消失 |
| 诊断 profiling（`VORTON_BOX_PROFILE` / `VORTON_ALLOC_STATS`） | P5 清理时删除或用 Vorton 重写 |

**P5 清理步骤**：B-152 P0–P4 完成后，(1) 删除所有 C++ 残留（`#include <string>` 等、placement new、析构调用）；(2) 将 `.cpp` 改为 `.c`，编译命令从 `clang++` 改为 `clang`；(3) 验证自举 + 全量测试。

---

## 8. 并发模型 ⚠️ 设计愿景，尚未实现

### 8.1 结构化并发

```
fn fetch_portfolio_data() -> PortfolioData {
    scope {
        let stocks_task = spawn { fetch_stocks() }
        let bonds_task  = spawn { fetch_bonds() }
        let gold_task   = spawn { fetch_gold() }

        PortfolioData {
            stocks: await(stocks_task),
            bonds:  await(bonds_task),
            gold:   await(gold_task),
        }
    }
}
```

### 8.2 async 是 effect，不是颜色

async 和 sync 代码无缝组合。handler 决定执行策略（设计已确定 2026-05-23）：

```
effect async {
    fn spawn<T>(task: fn() -> T with {async}) -> Future<T>
    fn await<T>(f: Future<T>) -> T
}

fn fetch_both() -> (Data, Data) with {async} {
    scope {
        let a = spawn { fetch_stocks() }
        let b = spawn { fetch_bonds() }
        (await(a), await(b))
    }
}

// 生产环境：默认 async handler 驱动
fn main() with {console, async} {
    let result = fetch_both()
    print(result.debug())
}

// 测试环境：sync handler 直接执行
fn test_fetch() {
    let result = handle fetch_both() with {
        async.spawn(task) => task(),
        async.await(f) => f,
    }
    assert(result.0 == expected)
}
```

**实现策略尚未拍板**。公开语义固定为 effect + structured scope；native lowering 由 B-116 比较状态机、continuation/evidence 等候选后再写入本节，退役后端不约束选型。

**结构化并发**：spawn 必须在 `scope { }` 内。scope 结束等待所有子任务；scope 提前退出取消未完成子任务。

**取消机制**：被取消的任务在下一个 `await` 点收到 `Cancelled` fail effect。两个 await 之间的同步代码一定完整执行。`Cancelled` 可 `catch` 做补偿（如回滚事务）。

### 8.3 Channel 通信

```
fn producer_consumer() with {async} {
    let ch = channel<Int>(buffer: 16)
    scope {
        spawn { for i in 0..100 { ch.send(i) }; ch.close() }
        spawn { for msg in ch { log("received: ${msg}") } }
    }
}
```

---

## 9. GPU 计算与语义级 Profiling ⚠️ 远期愿景

GPU 操作建模为 effect（`gpu_mem` effect），编译器从 effect/type 信息生成语义 map → 关联硬件计数器（CUPTI/NSight），自动报告"哪个 effect scope memory-bound + 为什么"。三层：编译期标注（零开销）→ 硬件计数器关联 → 编译期性能预测。开发阶段可用 effect handler 插桩做 trace（有扰动）。

**前置**：经 Argument 选定的 GPU codegen/toolchain + GPU 内存 effect 建模 + 固定数组（B-070）+ 硬件计数器集成。**差异化**：用 effect/type 语义关联源码与硬件事件，而不是绑定某个已退役 CPU 后端。

---

## 10. 实现策略

> 已退役后端的 §10.1–10.3 映射已删除；需要时从 Git 历史查阅。

### 10.4 后端策略

**迁移前 C11 后端状态（历史，2026-08-03）**：C11 曾是 main 唯一 codegen 与 bootstrap lane，支持单文件、project/module 与 self-host；`compiler/dist-c/main.c` 曾作为 tracked stage-0 做字节固定点验证。LLVM-C/addon、`codegen_llvm*`、旧 `compiler/dist/` 与 `dist-llvm/` 已从当时的 main 删除；`llvm-c-backend-final` tag 是历史恢复点。当前编译器在 Rust 宿主上重建，以上 C/self-host 资产只作 oracle，不是产品依赖或现行 gate。

**C11 主路径的长期契约**：

- 发射标准 C11 单翻译单元，调用 clang；不依赖 clang 私有语法，保留 gcc/MSVC 作为去相关验证信道。
- 值表示、typeid、closure、dictionary、effect evidence 与 runtime ABI 由共享分层 IR 与 AbiIR 契约决定；后端不得按类型叶名、字符串或声明顺序自行猜测。
- 字符串常量携带显式长度并保持 binary-safe；`#line` 默认开启，生成 C 与 bootstrap 固定点要求字节确定。
- 整数算术使用显式 wrap/除零规则，避免 C signed-overflow UB；Float 比较保持既定 ordered NaN 语义。
- match/catch 按源码 arm 顺序，穷尽失败 fail loud；Drop、cleanup 与 evidence 生命周期在嵌套函数边界隔离，并由共享 RC/verifier 契约审计。
- 编译器进程只生成文本并调用外部编译器，不恢复 LLVM-C 式进程内 FFI/IR builder 信道。

**迁移前内部检查点与发布边界（历史，2026-08-30 用户决定）**：当时的0.1检查点只要求C-only tracked anchor生成可用 compiler、连续self-host到文本fixed point并完成仓库/GitHub治理迁移；它不要求critical correctness清零，也不是公开preview。相关反馈速度、Known Issues、CLI/agent contract、candidate打包与生成程序性能事项现只按 GitHub Issue 追踪。当前 Rust 重建不恢复连续self-host门；未来后端仍只能消费同一HIR/ABI契约，不能恢复进程内LLVM-C FFI或成为未经新用户决定的唯一bootstrap。

**未来 LLVM target 重启门**：只有代表性负载证明 C 不可表达的性能瓶颈、Vorton 级调试信息刚需，或目标平台缺少成熟 C 工具链时才重新立项。届时 C 后端永久保留为 reference/stage-0，LLVM 只能是第二信道，并且只发文本 `.ll`，不得恢复进程内 LLVM-C FFI。

**信任阶梯**：确定性 C + 工具链指纹 → clang/gcc/MSVC 交叉差分 → 按需 Diverse Double-Compiling → 远期朴素信任种子后端。自有机器码后端若实施，只能作为可审计的第三信道/DDC 种子，不进入生产工具链，也不做性能优化。

### 10.5 FFI 设计

Top-level `extern fn` / `extern type` 是0.1唯一面向C ABI的用户声明。`extern fn`不能出现在inherent或trait impl中；需要用户自定义的FFI method时，先声明top-level extern，再写普通inherent wrapper。标准库既有的Str/Int/Float宿主方法不构成第二套用户FFI：它们以exact builtin intrinsic contract进入CoreHIR，再由AbiIR按intrinsic tag投影到既有runtime symbol；backend不得从receiver类型名与method leaf猜link symbol。

unsafe原语（`Ptr<T>` + alloc/read/write等）已设计定案（§7.12），实现=B-125。B-201原子删除impl-member extern假表面及backend字符串映射；B-156只继续约束top-level extern声明处的`requires {unsafe}`。容器RIIR后top-level extern数量持续减少。

---

## 11. LLM 友好性设计

> 核心论点与三原则（语法借用 / 一种事一种写法 / 高级特性两路径）详见 philosophy.md §8/§9。本节只记 philosophy.md 未覆盖的具体化内容。

### 11.2 `--error-format=llm`

结构化错误输出，包含可直接复制的修复代码建议：

```json
{
  "error": "refinement_unsatisfied",
  "expected": "Int where 1024 < it < 65536",
  "actual": "Int",
  "fix_hint": "let port = parse_int(raw); if port <= 1024 ... { raise(...) }",
  "alternative": "parse_int(raw) or 8080"
}
```

### 11.3 量化指标

| 指标 | 含义 |
|------|------|
| 首次编译通过率 | 同一 prompt，LLM 生成后首次编译通过的比例 |
| 运行时错误率 | 编译通过后实际运行时出错的比例（本语言应远低于 TS） |
| 自修正轮数 | 首次生成到编译+测试通过的迭代次数 |
| Token 效率 | 完成同一功能的总 token 数（生成+修正） |
| 大库一致性 | 100+ 文件代码库中风格/模式的一致性评分 |

核心赌注：首次编译通过率可能低于 TS（编译器更严格），但运行时错误率和总迭代轮数远低于 TS。

### 11.3.1 代价分配原则

类型系统复杂度增加的是语言的上限，不抬高下限。LLM 友好性的设计分三层：

- **推断能解决的，自动推断**：effect 推断、泛型参数推断。LLM 不需要学，编译器自动处理
- **安全性相关的，编译器强制**：linear types（资源必须消费）、exhaustive match。LLM 不学就编译不过，编译器错误信息就是教程
- **表达力增强的，opt-in**：refinement types、associated types。LLM/用户可以不用，不影响代码正确性；用了可以获得更强的编译期保证

代价分配逻辑：**类型系统的复杂度由 LLM 承担（编译器错误循环迭代），收益由终端用户享受（零 runtime surprise）。** runtime error = 用户介入 = 体验降级；LLM 与编译器搏斗十轮的代价远低于一个 runtime panic 到达用户面前的代价。

### 11.4 控制论视角：编译器替代人类审查

设计公理 4 的理论根基。当前LLM开发工具链中，人类在回路里承担三个控制论角色：

| 角色 | 控制论术语 | 人类做什么 |
|------|-----------|-----------|
| 观测器 | Observer | 看代码对不对、看行为是否符合预期 |
| 判决器 | Controller | approve / reject / 修正方向 |
| 兜底 | Stability guarantee | 系统再怎么跑偏，人最终能拉回来 |

**把人踢出回路，这三个功能不会消失，必须由语言和工具链接管。**

**前馈控制——编译器替代观测器和判决器：**

控制论中前馈控制在错误发生前阻止，反馈控制在错误发生后纠正。Vorton 的安全特性本质上是把反馈控制（测试、review、监控）转化为前馈控制（编译时拦截）：

| 语言特性 | 替代人类的哪个判断 |
|----------|------------------|
| Refinement types | "这个参数合法吗？" — 编译器直接拦截非法值 |
| Linear types | "资源释放了吗？" — 编译器保证恰好使用一次 |
| Effect 标注 | "这个函数有副作用吗？" — 签名可见，不需读实现 |
| 穷尽匹配 | "所有 case 都处理了吗？" — 编译器强制穷尽 |
| `--error-format=llm` | "错误信息看懂了吗？" — 结构化输出，LLM 直接消费 |

**每加一个类型安全特性，就是把一个原本需要人当观测器+判决器的场景，交给编译器自动完成。**

**反馈控制——补全编译器覆盖不到的语义正确性：**

前馈控制（编译器）不可能覆盖全部——编译通过 ≠ 语义正确。反馈回路仍然必要：

- **自举 dogfooding**：Vorton 编译器用 Vorton 写，编译器自身的 bug 是最直接的反馈信号——修类型系统 → 同类 bug 永远消失。这比测试驱动更强，因为修的是约束本身
- **Property-based testing / fuzzing**：编译器保证类型正确，自动测试保证语义正确，两层叠加后 LLM 输出才能不经人审就上线
- **Effect 系统作为可观测性**：副作用被类型追踪后，运行时行为变得可预测，等于自带观测器

**飞轮策略的控制论表述：**

飞轮（见 13.4 节学术验证）用控制论语言重新表述：

> **用类型系统最大化前馈控制的覆盖面，用自动测试补全反馈控制，直到闭环足够紧密，人可以退出回路。**

"critical correctness 优先于性能"的判断等价于：**先保证控制器不会给出错误裁决，再提升控制回路的采样频率。** 2026-08-03 用户进一步明确：critical 清零后，`check`、RC/self-verify 与完整门的反馈时延本身就是层 0 瓶颈，B-176/B-180 优先于其余非 critical feature/重构；这不是用速度交换覆盖率，而是让同一套控制器更频繁地运行。生成程序优化、JIT 与扩大优化边界仍排在语义/ownership 稳定和 B-181 证据之后。

---

## 12. 性能优化策略

当前性能路线分两类，不再混用一份 baseline：

1. **开发反馈性能**：B-176 测 `vorton check`、RC/self-verify、runner/clang 调度与 self-compile，B-180 以 2× wall-time 改善为退出门；可以优化编译器算法、缓存和有界并行，但不得减少测试覆盖或吞掉原始失败。
2. **生成程序性能**：B-181 测 runtime、内存/分配和产物尺寸，再决定 RcIR reuse、dict 缓存等优化；仍以 backend-neutral TypedHIR/CoreHIR/FlowIR/RcIR → AbiIR → C11/clang 为主，见 §14.6。

退役实现的性能分析只留 Git 历史。两类工作都记录 cold/warm、CPU/RSS、compiler/anchor/toolchain 指纹，禁止用并行 wall-time、编译器构建优化或 microbenchmark 混报产品 runtime 收益。

## 13. 竞品与行业定位

详细分析见 [`docs/competitive-analysis.md`](competitive-analysis.md)。核心结论：

截至 2026-07-28，尚未发现一个项目**同时交付** Vorton 的完整默认路径：面向应用开发的低标注表面 + HM 类型/effect inference + system/fail/mut/handled-effect 行为签名 + tail-resumptive/abort handler + Perceus RC/native/自举 + 可测量的 agent 闭环。这里的差异是**组合与默认体验**，不是任何单项机制无人实现；也不能用搜索空集证明「无竞品」。

最近邻必须按不同轴描述：Koka/Flix/Effekt 是 effect 与 handler 机制近邻，Unison 是 abilities + semantic codebase 近邻，MoonBit 是应用语言产品与实验性验证近邻，Zero 是 graph-native agent workflow 近邻，Verus 是权限/SMT/AI proof 近邻；TypeScript 7、Python 与 Rust 则构成强大的「够用就行」替代。Vorton 对外定位因此收窄为：**把可推断的行为契约、确定性资源语义和 agent 验证闭环放在同一条 application-native 默认路径上，并用 B-111 的可复现实验证明收益。**

迁移前已发货边界也必须按历史事实陈述：旧宽泛 `io`、`fail/mut`、有限 handler、C11 native/self-host 与 tracked `dist-c` 曾存在，但现在只作迁移 oracle。当前 Rust 重建不得据此宣传 system/handled clean break、Async、refinement、Drop abort-unwind/Weak 或 RIIR 已实现；这些能力的活动范围与验收只查对应 GitHub Issue。

---

## 14. 企业级性能路线

核心研究问题已有 Koka 等参考实现；Vorton 仍需用自身 workload 与当前 native 路径验证。

### 14.1 Koka 的启示

Koka（微软研究院）通过两项技术达到 C 性能的 75-85%：
- **Evidence passing**：effect handler 编译为函数调用 + evidence 向量查找，开销等价于 OOP 虚方法调用
- **Perceus**：精确引用计数 + 就地复用分析，完全消除 GC 停顿

### 14.2 编译目标

native 仍是目标产品编译方向；迁移前 codegen/bootstrapping 曾为 C11-only（JS 已归档，最后 LLVM lane 只在历史 tag），但当前 Rust compiler 尚未建立发布后端 gate。旧性能证据必须注明 compiler commit、`dist-c` 指纹、C compiler/version、生成程序与 runtime 优化级别、机器和冷/热缓存状态，且不作为当前基线。新的开发反馈、生成程序 baseline 与 release budget 只能由对应 GitHub Issue 在 Rust 路线上重新建立。

### 14.3 泛型单态化策略（2026-05-24 决策）

按类型表示自动分流，借鉴 C#/.NET Tiered Compilation。不是全单态化 vs 全 boxing 的二选一。

**分流规则**：
- 值类型（I8/I32/I64/F64/`@value struct`）：size/layout 不同，必须单态化
- 引用类型（List/Map/Str/struct）：底层都是指针，共享一份泛型实现（trait dictionary dispatch）
- 热路径：PGO/JIT 决定是否对特定引用类型也单态化

**构建模式**：

| 模式 | 策略 | 编译速度 | 运行时性能 |
|------|------|---------|-----------|
| Debug | 全 boxing（共享泛型） | 快 | 慢（可接受） |
| Release | 值类型单态化 + 引用类型共享 | 中 | 好 |
| Release + PGO | 上面 + profile 驱动的热路径单态化 | 两次编译 | 很好 |
| JIT（远期） | 运行时 tiered compilation | — | 最佳 |

**与 Rust 的根本差异**：Vorton 只要求值类型单态化，引用类型默认共享代码；能否显著降低编译膨胀必须由 B-105 与性能基线验证，不能只凭架构推断。

**与generic raw payload边界的关系**：0.1已禁止raw/non-RC payload进入generic aggregate storage，因此单态化路线不承担删除B-min mask的前置责任——mask在0.1中根本不存在。Full reachable monomorphization feasibility只评估普通generic callable/body的正确性、代码规模与性能收益，不得借机恢复raw generic aggregate surface。

**编译性能额外措施（按需实现）**：
- Debug 快速路径：只有实测证明 clang 路径不足后才单独选型，不预设 Cranelift 或其他永久依赖
- 增量 check/build：B-180 证明 unchanged-module 重复工作仍主导后，B-105 先做内容寻址的 module HIR/export/object cache；effect row 与 public signature 进入精确失效边界
- 函数级增量只在 module granularity 仍不足时继续细化，不预先承担复杂 cache coherence
- 并行编译：模块间 codegen 完全并行（check 完成后签名固定）

### 14.4 关键技术路径

- **C11 → clang native** 是唯一产品主路径；Linux 的 gcc/MSVC 等只作为生成 C 的去相关验证信道。语义优化必须在对应的 backend-neutral TypedHIR/CoreHIR/FlowIR/RcIR 层完成，避免重新把语言语义绑定到某一 codegen。
- **Perceus 引用计数** 替换 GC。无停顿、确定性析构、函数式代码可就地复用已死对象的内存。语言设计无需修改——Perceus 是编译器优化，用户代码不感知。
- **Evidence passing** 替换 generator effect handler。同样是编译器优化，用户代码不感知。

### 14.5 先例

- **Swift**：~4 年从"脚本手感"到系统级性能（Apple 全力投入）
- **Kotlin**：JVM → LLVM native，与 Swift 性能差距 ~15%
- **Koka**：已达到 C 的 75-85%，纯研究院项目

### 14.6 后端中立的双层优化架构

effect、linearity、refinement 与 purity 必须先在相应的 TypedHIR/CoreHIR/FlowIR/RcIR 层消费；C/clang 或未来后端只能继续利用可安全降为标准属性、`assume` 或受控代码形态的子集。

```text
TypedHIR / CoreHIR / FlowIR 契约
→ Vorton passes（RC/reuse、bounds、specialize、dead effect）
→ AbiIR / C11 受控形态与属性 → clang → native
```

| 静态事实 | Vorton 层责任 | 下游可选提示 |
|---|---|---|
| 无 effect / 只读 | 证明重排与消除合法 | pure/readonly 属性 |
| refinement range | 决定检查能否删除 | range assumption |
| move 后唯一所有权 | 维持恰好消费一次 | alias/escape hint |
| 穷尽 match | fail-loud 并删除死分支 | unreachable |
| 尾调用保证 | 选择 loop/trampoline/受保证机制 | target tail-call hint |

后端没有等价提示时，正确性和语义优化仍在 HIR 完成；不得为追求 downstream 优化重新复制 effect、RC 或类型推理。

---

## 15. 编译器实现

迁移前编译器曾用 Vorton 自举，并经 legacy HIR → Perceus RC → static verifier → C11 codegen 生成 tracked `dist-c` 固定点；这些结果现在只作迁移 oracle 与历史证据。当前 main 的 compiler 路线是在 Rust 宿主上重建，下述分层架构描述目标契约而非已通过实现。长期后端契约以 §10.4 为准；历史 TypeScript/JS/LLVM 翻译过程与里程碑留在 Git/tag，不在设计真值重复维护。

### 15.1 分层 IR 总架构（2026-08-22 用户批准）

§7.3.1 的 FlowIR / ResourcePlanner / RcIR 不是 ownership 专用补丁，而是编译器总分层的第一个落地消费者。每项语义事实只能由信息首次完备的最高层产生一次，以 typed carrier 单向传递；下游不得按字符串、类型叶名、声明顺序或 backend fallback 重新解释，上游也不得因下游需要而回跑 resolver、type/effect inference 或 instance selection。

```text
Source
→ AST
→ ResolvedAST
→ TypedHIR
→ CoreHIR
→ FlowIR
→ RcIR
→ AbiIR
→ mechanical C11 serialization
→ clang / native
```

| 层 | 冻结契约；通过后下游不得重做 |
|---|---|
| `AST` | 忠实保存表面语法、注释所需形状与 Span；不承载名字、类型或后端结论。 |
| `ResolvedAST` | 每个声明、引用、member、constructor、effect op、import/re-export 与 extern bridge 都携带 exact `SymbolRef`；下游不再查询 resolver 或按叶名回退。 |
| `TypedHIR` | HM inference metavariable 已收敛；可泛化的type/effect tail已转换为带owner/ordinal的显式量化参数，无法归属formal scheme的raw变量拒绝。类型、effect row、callee/impl/associated-type 选择、call-site effect实例化与公开 module interface 已固定；ownership mode 可仍为 symbolic contract，但不得回写普通 type/effect 结果。 |
| `CoreHIR` | 所有0.1语言级隐式语义已elaborated：derive、protocol for-in、short-circuit、trait dictionary、handled-effect evidence、closure/capture、constructor与intrinsic均成为explicit body、typed edge、typed construction operation或`IntrinsicContract`；source trait default body与`delegate`不在0.1 surface。真实callable的共享`ExecutableInventory`封闭，enum constructor不冒充callable节点。每个callable携带closed atoms或atoms+正式`EffectParamRef`的effect contract；不存在raw effect metavariable。System effect只携带exact host call contract且不进入evidence。函数默认参数、effect default body与`sig`同样不在0.1 surface。此层仍不含资源操作。 |
| `FlowIR` | ownership-neutral ANF、pattern decision/projection、scope/control result、normal/failure edge 与全部 cleanup-visible slot 已建立；project-wide identity、binder、call/alias/capture graph 冻结，后续新增 node/binder 是 internal error。 |
| `RcIR` | 唯一 ResourcePlanner 输出 `Clone/Take/Drop/Cleanup` 与 ranked certificate；binder set 与 FlowIR 相同，资源语义完全显式。 |
| `AbiIR` | 只把已验证语义降为 typeid/tag/field layout、symbol、prototype、closure/dict/evidence layout、drop glue、exact HostImport、extern 与 failure ABI；不得新增调用、控制边、owner、effect class 或语言 fallback。 |
| `C11` | 对 AbiIR 做确定性序列化并调用工具链；不再选择方法、求 effect closure、解释 pattern、生成未规划 executable body 或分配语义 identity。 |

**术语与物理形态（2026-08-23 用户最终命名）**：`CoreHIR` 名称保留；它是广义 IR，也是最后的 Vorton semantic representation，其物理形态仍是 structured typed expression/tree，而非 basic-block graph。原 `FinalHIR` clean break 命名为 `FlowIR`，原 `RcHIR` 命名为 `RcIR`；不保留alias或双口径。`CoreHIR → FlowIR` 是唯一 operational lowering：把 structured control、canonical typed pattern 与隐含 evaluation order 变为 fixed blocks/instructions/terminators，创建仅供执行编排的 ANF temp、scope/control result slot，以及 control/data/call/projection/capture/exit edge。它可以新增这些 administrative binder/block/edge，但不得新增语言级 operation、executable、impl、callee/evidence 选择或其他 semantic obligation。

`FlowIR` 是第一层传统 MIR/CFG-style IR，但不要求 LLVM 式 SSA/phi，也不含 `Clone/Take/Drop/Cleanup`、目标 layout 或 ABI。FlowIR freeze 后，ResourcePlanner 不得创建或改变 semantic CFG、call graph 或 reachability；只可在既有 topology 上决定资源流，并把既有 edge 物化为保持相同端点/可达性的显式 cleanup sequence。`RcIR → AbiIR` 才继续进入资源已验证后的物理表示下降。

**System / handled effect 生命周期（2026-08-23 用户决定）**：effect class在TypedHIR freeze前固定。`SystemEffectRef`（0.1为`console/fs/process`）只随exact extern/intrinsic call向下传递，不进入evidence vector、不能被`handle`、没有main/root handler；AbiIR将其变为HostImport，target仅选择native symbol、WASM import或embedded link provider。`HandledEffectRef`才进入call/evidence graph并必须显式handle；它不得直接降为HostImport。新增宿主能力必须由真实API产生，只增加typed declaration/HostImport provider，不增加按capability名字的compiler branch。Validator与mutation必须双向杀死system→evidence和handled→HostImport越界。

**隐式行为时点**：纯拼写糖可在 AST/CoreHIR 内展开，不必为每个 pass 新建永久 IR；exhaustiveness matrix、call graph、CFG 等可作为所属层的 finite plan/certificate。凡会改变求值顺序、调用图、effect、capture、binder、控制边或 executable inventory 的行为，必须在 FlowIR freeze 前显式化；freeze 后只允许资源操作与机器表示下降。每个跨层节点保留 `OriginRef`，使诊断能回到源码而不迫使低层保留表面语法。

**CoreHIR semantic elaboration closure（2026-08-23 用户决定）**：CoreHIR 是大多数语言 feature 的统一去糖终点，不是允许下游继续补语义的中转层。每个新 surface feature 必须给出唯一 TypedHIR → CoreHIR lowering，或明确证明自身就是 canonical core construct；否则不得进入实现。CoreHIR validator 必须拒绝 surface-only variant、未选择的 callee/impl/evidence、待生成 executable/body 与其他 implicit obligation。CoreHIR 之后不得再读取 AST/source spelling、调用 resolver/type/effect/trait selection，或在 verifier/codegen 临时生成语言级行为。FlowIR 仅规范化 evaluation/control/pattern 并冻结 binder/node/edge，RcIR 仅显式化资源操作，AbiIR 仅显式化 representation/ABI。

**渐进迁移而非平行重写**：#268/#269 先建立通用 typed identity、executable inventory、neutral normalization、FlowIR/RcIR 与 validator 骨架；后续 type/effect/evidence、failure/control、RIIR/FFI、optimization 各自在既有 backlog 里迁入其唯一所属层。一个事实切换到新层时必须原子迁移全部消费者并删除旧 fallback/side map；禁止长期双写、shadow authority 或以“兼容”保留旧解释路径。B-190 负责在相应消费者已迁移并有证据后删除遗留重复 authority，不把本架构变成一次无界全仓 rewrite。

**迁移前 0.1 internal self-host implementation boundary（历史，2026-08-30 supersede）**：当时的#268/#269只覆盖tracked anchor、连续self-host/fixed point、compiler/hello最小smoke与迁仓 consumer；其他外部程序缺陷继续作为Known Issues。当前 Rust 重建不继承这些完成声明，IR纵切、matrix、full/RC/ASan与一般correctness/ownership证明必须由现行 GitHub Issue 和真实 gate 重新建立。未来能力仍不得要求当前IR预留空节点、unknown占位、fallback或双authority。

**Koka 作为参考实现**：Effect 推断（`InferEffect.hs`）和 evidence passing（`Evidence.hs`）的算法翻译自 Koka 编译器（MIT 许可）。Perceus 引用计数已翻译其 POPL'21 实现落地（§7.11）。

迁移前自举是 Vorton 曾承载自身编译器的历史证据，不是当前 Rust compiler gate；LLM 开发效率主张仍必须由现行 Issue 下的可复现实验验证。

---

## 设计取舍

| 拿到了什么 | 付出了什么 |
|-----------|-----------|
| Effect 系统统一所有副作用 | 编译器实现极其复杂 |
| Refinement types 编码业务规则 | 静态验证有极限，部分退化为运行时检查 |
| 全推断 + formatter 维护标注 | 类型错误信息可能难以理解 |
| C11 native 主路径 + Perceus RC | 编译器与 runtime 自身进入信任/自举链 |
| Row poly + OOP 手感 | 与现有 class-based 生态互操作需要 extern 声明 |
| Const generics + refinement 组合 | 约束求解可能不可判定，需要保守边界 |
| LLM 友好的严格编译器 | 首次编译通过率可能低于 TS |
| 一种事一种写法 | 老手可能觉得缺乏灵活性 |

## 附录：公理仲裁决策表

> philosophy.md「层级与仲裁」规则 2/3 的记录处。公理间冲突、修宪程序、体系级元决策均落此表；per-topic 设计决策仍散于各节，仅涉公理仲裁者入表。2026-06-12 建表。

| 日期 | 议题 | 裁决 | 适用规则 | 可证伪锚点 |
|------|------|------|---------|-----------|
| 2026-06-12 | 体系结构：平铺六条无优先序 → 冲突无法仲裁（D-2） | 三层结构（0 目标 / 1 约束 / 2 策略）+ 四条仲裁规则 + 修宪程序；④ 改写为「无人回路 × 全场景」（全场景 = 量词非第二目标）；⑦「场景不可堵死」自 ⑥ GC 记录升格成文；编号永不重排 | 元决策 | B-111（层 0 判据的测量仪） |
| 2026-06-12 | GC vs ⑥：no-GC 是否站得住（所有权讨论引发重审） | 维持 ⑥：语义层费用引擎无关（②④ 独立强迫 move 语义）+ 不可逆性不对称 + ⑦ 场景路径；性能（GC 停顿）明确不是理由。全文 dossier 见 philosophy.md ⑥ | 规则 3（修宪程序，首例） | B-089 re-measure：native RC plateau vs V8 自编译基线 |
| 2026-06-12 | 优化可观测性：引擎优化（COW/reuse/unboxing）vs 用户可见语义 | 优化不可观测原则（④ 推论，philosophy.md 成文）：引擎优化绝不改变可观测语义；§7.12 安全区表「见决策表」指此条 | ④ 推论成文 | — |
| 2026-06-12 | Drop 时机（D-1）：⑥ 原文「scope 退出/最后使用处」二点歧义违反 ⑥ 自身；`Weak.upgrade()` 使时机可观测 → 与「优化不可观测」（④ 推论）+ L3/FBIP（B-079）预定相撞，gates B-104 D3 | 语义 = scope-end + as-if 条款：引擎仅对「无用户 Drop impl 且非 Weak 目标」类型（类型级可判定）允许提前 drop；B-104 D3 Weak 按 scope-end 落地；⑥「无 GC 停顿」改「无不可预期停顿」（级联 drop 诚实记账）。细则 §7.11 | ⑥ 自身消歧（约束内修正，非修宪） | Weak/Drop 用例在 reuse 启用前后输出一致，走当前 C/native gate |
| 2026-06-12 | ③ 推论「标注非语义」vs ④「失真必须响」（D-3）：过时标注 = 意图与真值的失真，却只 warning | agent profile 下 warnings 即 errors（CI gate 升级 W 类为 must-fix）；人类场景保留 warning，gradual guarantee 不破；标注语义化否决（毁 formatter 自动维护） | 规则 2（策略间，层 0 判据） | B-111 可测：标注漂移引发的 agent 迭代轮数差 |
| 2026-06-12 | ① 无判定程序、无否决记录，与 GADT/refinement 路线图潜在互蹭（D-4） | 重写为可判定标准：lv0 常见用例零标注可用 + 推断失败错误可被 LLM 单轮修复；B-033/B-001 评审以此投票 | 元决策 | B-033/B-001 评审实际使用该标准 |
| 2026-06-12 | ⑤ 做实（D-5）：HM 最坏指数与「耗时可预期」字面冲突；B-001 SMT 半可判定预定碰撞；trait instance 终止性未证 | 推断 fuel/深度上限、超限=编译错误（B-119）；B-001 spec 补具名可判定片段条款（QF_LIA 类，超出=要求 runtime check）；trait 终止性审计（B-119） | ⑤ 自身做实（约束内修正） | B-119 验收 |
| 2026-06-12 | 公理名单与实战否决记录错位 + 性能地位空白（D-6） | ⑧「一种事一种写法」⑨「语法借用」自「语法原则」升格为层 2 公理；性能成文为非公理工程目标（让位全部公理，受 ⑥⑦ 间接保护，优先级锚点=层 0 判据） | 元决策 | — |
| 2026-06-12 | ② 可见性载体失真：「IDE 幽灵标注」对主受众LLM无效 | 主载体改写为formatter物化标注、模块签名与`--error-format=llm`；IDE只作人类适配层 | 规则 2 | — |
| 2026-06-12 | B-111 优先级（D-7）：层 0 判据（公理④「LLM 写 Vorton 优于 TS」）至今零测量、缺测量仪 | B-111 P2→P1，地位等价公理⑥的 B-089 锚点；只改优先级不动排程（B-104 里程碑照旧先行）。条目见 backlog B-111 | 规则 2（层 0 判据） | B-111 验收 |
| 2026-06-15 | 字符串编码模型：code point API 与既有后端行为失真 | 选 A（UTF-8 字节串）：`len`=字节数 O(1)、`chars()`/`char_count()` 提供 code point API；否决 B（code point）理由=O(n) len + 需 ByteStr 补位违反⑧。§1.7 已修正，实现归 B-133 | ⑥⑦⑧（5/7 判据 A 胜出） | B-133 按 backlog 的 C/native、Unicode 与 FFI gate 验收 |
| 2026-06-24 | 层 0 重构：④ 原名「无人回路 × 全场景」绑定 LLM 叙事——核心 claim 应比 agent 窗口更根本 | ④ 改名「不信任程序员 · 编译器是最终权威」；「无人回路 × 全场景」降为渐近表达；出发点从「agent 验证瓶颈」回溯到「程序员不可信是永恒事实」（C/Rust/Vorton 三角定位）；LLM-first 降格为推论；核心赌注分两层 | 元决策 | — |
| 2026-08-22 | 纯缩写语法糖准入与历史 `T?`：少写字符是否足以换取第二种公开类型拼写 | 否。语法糖必须提供独立建模/认知/验证/组合价值；`Option<T>` 为唯一目标拼写，`T?` 由 B-191 在 B-180 后、B-174 前 clean break 删除；当前 correctness/性能主线不被打断 | ⑧（层 2 策略，用户方向） | B-191 的负例、仓内原子迁移与 self-host fixed point |
| 2026-08-23 | 0.1 effect/capability surface：宽泛 `io`、host root handler、user default operation body与隐式effectful Drop会形成重复authority并隐藏能力 | SystemEffectRef=`console/fs/process`且不进evidence/不可handle/无root；HandledEffectRef才显式handle；host call只经AbiIR HostImport。0.1删除user effect default body与effectful Drop，后两者在post-0.1有真实consumer时分别由B-197/B-198重审。Refinement占位语法同步删除；已批准匿名union语义保留但实现顺延post-0.1 | ②④⑤⑧（可见性、失真必须响、有限authority、一种写法） | B-193~B-198及system/handled crossing mutations |

## 状态真值

本文件只保存稳定设计。当前技术入口以 `AGENTS.md` 为准；持久目标与目标顺序只查 GitHub Milestones，当前依赖、范围与验收只查 GitHub Issues，完成历史、被否决方案和逐轮调查只查 PR 与 Git。解析但无语义效果的“幽灵功能”必须进入经用户确认的 GitHub Issue，不能在设计附录另建第二张看板。

## 一句话

纯函数为心脏，effect 为血管，类型为骨骼，推断为皮肤——摸到的是 Python 的手感，内部跑的是 Haskell 的引擎。
