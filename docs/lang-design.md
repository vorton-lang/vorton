# Ring 语言设计文档

> 语言层面的设计决策追踪。已确定的决策 + 未成熟的研究方向。
> 成熟后需要实施的条目转入 `backlog.md` 排队；backlog 只放 implementer 能按验收门直接执行的工作。

## 1. 文档边界

本文件只保存尚未形式化、仍需实现前重审的语言研究与远期决策。已经稳定或发货的公开语义归 `docs/design.md` 与 `docs/lang-spec/`；可执行工作归 `docs/backlog.md`；完成过程与被否决方案只查 Git。

## 2. 方向索引（已拍板约束与待立项边界）

| 方向 | 当前约束 | 活动入口 |
|---|---|---|
| 同帧同名 enum variant | 裸名歧义报错并列候选；qualified `E::V` 合法 | B-171 |
| 数值类型 | 固定宽度、零隐式数值转换；转换显式且可检查 | design §1.7 |
| 内存布局 | 默认布局不保证、编译器可重排；显式 ABI/packed/alignment 由 `@repr` / `@align` 承载 | design §1.7 |
| 动态分发 | 默认静态 dispatch；`dyn Trait` 为显式 opt-in | B-006 |
| TCO | 符合“尾位置 + 无 Drop + 签名匹配”的调用必须保证；后端用 loop、trampoline 或受保证机制，不能依赖偶然优化 | design §1.7 |
| 运算符 | 不开放任意用户重载；内建类型与 trait 语义必须唯一 | design §1.7 |
| 并发 | structured scope；spawn 生命周期不能逃逸 | B-116 → B-007 |
| Generator/yield | 不作为独立表面机制；仅在 async lowering 选型需要时重审 | B-116 |
| ABI | C ABI 是 FFI 地基；公开 ABI 稳定性需单独版本化决策 | design §10.4–§10.5 |
| 包管理 | 先保证可复现、内容寻址和锁定依赖，再设计 registry 用户面 | 实现前立项 |
| Newtype / alias | 目标是区分 nominal wrapper 与透明 alias；具体语法、转换和互操作尚未拍板 | 实现前立项 |
| 可变参数 | 不引入不安全 C varargs 语义；优先 List/tuple 等显式载体 | 实现前立项 |
| 命名参数 | 只有在不制造第二套调用语义时才考虑 | 实现前立项 |
| 固定数组 | `[T; N]` 与 const generic/refinement 联动 | B-070 |
| 循环引用 | RC 环由 `Weak<T>` 显式打破，不引入 cycle collector | B-002 Phase 2 |
| 跨线程共享 | 普通 RC 不跨线程；共享模型必须显式并保持确定性 Drop | 并发设计时重审 |
| 单态化 | 确定性、可缓存；跨模块拆分与增量编译共同设计 | B-105 |

索引不是 implementation spec。进入 planning 前必须在 backlog 中写清当前源码边界、公开契约、依赖和可证伪验收，不能把旧后端文件清单直接复用。

## 10. TODO / 待形式化

- [ ] 逃逸检查完备性证明（闭包间接逃逸 + 泛型间接逃逸的覆盖）
- [ ] mut 闭包共享 box 的安全性证明（spawn 阻止跨线程共享）
- [ ] Refinement types 的可判定片段定义
- [ ] GADTs 的标注要求（哪些位置需要类型签名）
- [ ] B-038：GAT projection 与受限 rank-1 HKT 的 kind/partial-application 可判定边界选型（消费 B-169 effect/type 融洽性结论）
- [ ] 闭包捕获借用的精确边界 case
- [ ] `lang.toml` formatter preset 配置格式
- [ ] 方法名冲突的 qualified call 语法设计
- [ ] 命名参数是否引入（实现默认参数时评估）
（同名 variant 裸名歧义已拍板收紧，执行入口见 B-171。）
（comptime 设计已定，见 §12.4）
（`io` 效果拆分已设计，见 §12.1；本条 TODO 替换为指向该节。）

---

## 11. PL 理论前沿追踪

> 未成熟的研究方向。观察、评估、记录，不排入 backlog。成熟后提取具体 spec 转 backlog。

### 11.1 Algebraic Subtyping（MLsub）

**来源**：Stephen Dolan, 2017, Cambridge PhD thesis

**核心**：用 biunification（双向合一）替代标准 unification，在 HM 里加子类型 + union/intersection types，不丢 principal types，推断仍可判定。通过极性类型（polar types）保证唯一最优解存在。

**与 Ring 的关系**：如果采用，union type 可以从匿名 enum sugar 升级为真正的类型系统概念，同时保留推断性质。当前 Ring 选择 enum sugar（design.md 1.1b）是因为假设子类型 = 丢 principal types——algebraic subtyping 打破了这个假设。

**升级路径**：替换推断引擎（unification → biunification），union/intersection 成为一等类型。

**风险**：
- 整个推断引擎大重写
- 错误信息生成更难（极性类型的报错比 unification 失败更抽象）
- 工业验证不足（只有 MLsub 原型 + 少数后续实现，无工业语言采用）

**成熟度**：★★☆☆ | **观察**，不投入。等有工业语言验证后重新评估。

### 11.2 Liquid Types — 自动化 Refinement 推断

**来源**：Rondon, Kawaguchi, Jhala 2008 (UCSD). 实现：Liquid Haskell, **Flux (Rust refinement types, 2023)**

**核心**：不让用户写任意谓词——从程序中自动提取候选谓词（qualifiers），限制为 qualifier 模板的布尔组合，然后 SMT 自动求解。比完整依赖类型务实得多。

**与 Ring 的关系**：直接适用于 B-001 refinement types。Ring 当前设计"编译器尽力静态验证 + 运行时兜底"和 liquid types 的 fallback 策略一致。Flux 已在 Rust 上验证——证明数组不越界、整数不溢出，和 ownership 系统共存。

**升级路径**：B-001 实现时参考 Flux 的 qualifier 提取 + SMT 验证策略，不从零设计。

**风险**：低——理论成熟，有 Rust 工程验证。

**成熟度**：★★★☆ | **B-001 实施时直接参考 Flux**。最值得投资的前沿方向。

### 11.3 Quantitative Type Theory (QTT)

**来源**：Atkey 2018, McBride 2016. 实现：Idris 2

**核心**：每个变量绑定带使用量注释——0（编译期擦除）、1（线性，恰好一次）、ω（不限）。线性类型、仿射类型、擦除类型全部是 usage annotation 的特例。

**与 Ring 的关系**：Ring 的 ownership（move = 1, borrow = ω, Drop = 必须恰好 1）可以看作 QTT {0, 1, ω} 子集的工程实现。如果未来 ownership 模型表达力不足（如需要区分"恰好用 2 次"或"最多 N 次"），QTT 是理论上最干净的升级路径。

**风险**：中——Idris 2 是唯一采用者，工程反馈不足。

**成熟度**：★★☆☆ | **观察**。Ring 的 ownership 模型如果工程上够用就不迁移。

### 11.4 Graded Modal Types — Effect + Linearity 统一

**来源**：Orchard, Liepelt, Eades 2019. 实现：Granule 语言

**核心**：用分级模态（graded modality）统一 effects、coeffects、linearity。每个绑定带一个来自半环的 grade——不同半环表达不同性质（使用次数、副作用、信息流、敏感度）。

**与 Ring 的关系**：Ring 目前 effect system 和 ownership 是两套独立机制，B-043 交互矩阵定义了 6 条交互规则。Graded modal types 证明它们可以在同一个框架里统一。如果交互规则持续膨胀，可以考虑用 graded types 重新形式化。

**风险**：高——纯研究原型，无工业验证。

**成熟度**：★☆☆☆ | **纯理论关注**。

### 11.5 Typed Multi-Stage Programming

**来源**：Taha, Sheard 1997. 实现：MetaOCaml（成熟）

**核心**：代码生成有类型安全保证。quote/splice 机制，类型系统保证生成的代码类型正确，不需要再过 type checker。

**与 Ring 的关系**：Ring 的 comptime Phase E `emit(decls)` 生成声明后需要再过 type checker 验证。Typed staging 可以在生成时就保证正确——更高效，且消除了"生成的代码有类型错误"这一类 bug。

**风险**：低——MetaOCaml 已有长期工程验证。

**成熟度**：★★★☆ | **Phase E comptime 设计时参考**。

### 11.6 Call-by-Push-Value（CBPV）

**来源**：Paul Blain Levy 2001, Birmingham PhD thesis

**核心**：显式区分**值（value）**和**计算（computation）**。值是已求值的数据，计算是待执行的代码（可能有 effect）。两个原语：`thunk`（冻结计算为值 = 闭包创建）、`force`（执行冻结的计算 = 闭包调用）。

**与 Ring 的关系**：Ring 已有隐式的值/计算区分——`@value struct`/I64/F64（值类型，memcpy 语义）vs 带 effect 的函数（计算）。CBPV 将这个区分形式化，可以精确指导 HIR 设计：

| CBPV 概念 | Ring 对应 |
|---|---|
| 值类型 A | `@value struct`、I64/F64/Bool |
| 计算类型 B | `fn() -> T with {effects}` |
| thunk: B → U(B) | 闭包捕获 |
| force: U(B) → B | 函数调用 |
| F(A)（值提升为计算） | 纯值 return 到 effect 上下文 |

**升级路径**：HIR 重设计时，用 CBPV 的值/计算分类指导节点类型设计——哪些 HIR 节点是值节点（可 unbox、可内联存储、零 RC）、哪些是计算节点（可能分配、需要 thunk/force 消除优化）。GHC 的 Core 语言受 CBPV 影响，是成功的工程先例。

**风险**：低——理论框架，纯编译器内部参考，不影响用户面语法。

**成熟度**：★★★☆ | **HIR 重设计时参考**。理论成熟，GHC 验证，但作为 IR 设计方法论的显式落地案例不多。

### 11.7 为可判定性放弃的特性清单

> 记录 Ring 为保持 HM 可判定推断而放弃的特性，以及替代方案。前沿研究可能恢复其中部分能力。

| # | 放弃的特性 | 原因 | Ring 替代 | 可能的恢复路径 |
|---|-----------|------|----------|--------------|
| 1 | 函数重载 | 破坏 principal types | 不同名或泛型 | — |
| 2 | 真 union type（子类型） | 等式→不等式 | 匿名 enum sugar | Algebraic Subtyping (11.1) |
| 3 | Rank-2+ 多态 | 推断不可判定 | trait 对象 | — |
| 4 | Trait overlap / specialization | solver 递归 + soundness | 默认方法 + 编译器优化 | — |
| 5 | 隐式数值 widening | 推断复杂度 | 显式 .to_xxx() | — |
| 6 | Impredicative 多态 | 推断不可判定 | struct/trait 包装 | — |
| 7 | GADT 完整推断 | 不可判定 | scrutinee 需已知类型 | — |
| 8 | FunDep | solver 复杂度 | 关联类型 | — |

---

## 12. 待实施设计（暂定，实现前重新审视）

> 以下设计方向已确定但未排入 backlog。实现前需以当前上下文重审，确认前提仍然成立。

### 12.1 效果分类：旧 `os/net` 草案已被 active 设计 supersede

> **2026-08-23 用户完成实施前重审**：本节2026-06-23的`os/net`二分只是“实现前重新审视”的暂定方向，现由[`design.md` §2](design.md#2-effect-系统)、[`lang-spec/effects.md`](lang-spec/effects.md)与B-195的active真值取代，不再是实现候选。

最终0.1边界为：删除宽泛special `io`；只为当前真实API建立`SystemEffectRef(console/fs/process)`，system不可`handle`、不进evidence、无main/root handler，只经AbiIR HostImport与target link provider执行；用户custom `HandledEffectRef`才走显式handler。没有真实API时不预造`net/clock/random`，未来新增能力也不形成sub-effect层次或compiler name branch。

旧草案中“联网是唯一值得独立追踪的宿主边界”与把filesystem/console/process合并进`os`的判断被本轮否决：这些能力对agent审计、module requires、inspection与未来package policy均有独立价值。历史推导只查Git；实施与验收以B-195为准。

### 12.2 `alloc` 效果：堆分配可见化

**状态：暂定（2026-06-23 Discussion）。实现前审视。**

#### 动机

当前 Ring 的堆分配对效果系统是不可见的——`List.push()`、`Map.insert()`、`Str` 拼接在效果上是纯函数。这意味着：

- 无法从签名区分"零分配"函数和"可能分配"函数
- 嵌入式/no-std/实时场景无法**静态禁止**堆分配——只能靠约定
- OOM 是不可恢复的 panic，而非可处理的 fail effect
- 与公理⑦（场景不可堵死）存在张力：嵌入式/WASM 场景下 OOM 是常态

**先例**：Zig 将分配器作为显式参数传递，所有可能分配的函数签名携带分配器信息，编译期即可审计"哪些代码路径需要分配"。Ring 的选择是用效果系统承载同一信息——推断 + 自动冒泡，零语法负担。

#### 设计

`alloc` 是一个内建效果，操作集合：

| 操作 | 说明 |
|------|------|
| `alloc.heap(size: USize, align: USize) -> Ptr<U8>` | 堆分配原始字节 |
| `alloc.free(ptr: Ptr<U8>, size: USize, align: USize)` | 释放 |

高层操作（`List.push`、`Map.insert`、`Str` 拼接、`.clone()` 等）内部调用 `alloc.heap`，其所在函数需要 `with {alloc}`。

`alloc.free` 不被视为需要 `alloc` 效果的调用——它不失败、不阻塞、不增复杂度。只有**分配**方向携带效果。

#### 什么不产生 alloc 效果

- 值类型操作：I64/F64/Bool/Char 的 copy、`@value struct` 的 memcpy
- RC 计数操作：`ring_dup`（写对象头 rc 字段）、`ring_drop`（读/写对象头）——对象已存在，计数值变化不分配
- 栈分配：`let x = some_struct(a, b)`（alloca）
- dealloc：`ring_drop` 最终释放（已有 RC 语义，不另标）

#### 签名语义

```ring
fn pure_fn(xs: List<I64>) -> I64 with {}           // 零堆分配——纯计算
fn process(xs: List<I64>) -> List<I64> with {alloc} // 可能分配（push / clone）
fn main() -> Unit with {os, alloc}                  // 正常程序
```

**Perceus RC 区分**：`ring_dup` 不产生 `alloc` effect——dup 操作的是已存在的堆对象头。只有首次分配（malloc）产生 `alloc` effect。这是与 C++ `new` / Rust `Box::new` / Zig `allocator.alloc` 一致的语义——分配和引用计数是两个不同层。

#### 编译器自身的影响

Ring 编译器是重度分配 workload；原型必须测量 `alloc` 在真实签名中的传播范围与噪音，不能用一次机器侧 allocation 计数直接决定语言面。若它几乎总与 `os` 连体且不能提供独立控制价值，就不应作为独立 effect。

但 `alloc` 和 `os` 不绑定——分配可以在无 OS 的场景（嵌入式、WASM、裸机）通过自定义 allocator 满足。这正是 Zig 模型的核心：分配器独立于 OS。

#### OOM 处理（实现时核定）

`alloc` 效果可带 OOM fail 语义——分配失败 raise `fail<Oom>` 而非 panic。这对嵌入式场景是必须的。对桌面/服务端，OOM 通常是 fatal（OS overcommit 让 OOM 语义本身不可靠），两种策略可能不同：

- 桌面 profile：`alloc` 不产生 fail effect，OOM 直接 panic（当前行为）
- 嵌入式 profile：`alloc.heap` 可 raise `fail<Oom>`，由调用栈处理

#### 与 unsafe 的关系

`alloc` 和 `unsafe` 是正交的：
- `alloc`：告知"此函数需要堆内存"，签名级可见
- `unsafe`：告知"此函数执行了绕过类型安全的内存操作"

两者可共存（`with {alloc, unsafe}` = 手动管理内存）、独立存在（`with {alloc}` = List.push，安全分配）、或都不存在（纯计算）。

#### 实施要点（实现时核定）

- `alloc` 的粒度：是否需要 `alloc.heap` / `alloc.arena` / `alloc.bump` 子效果，还是只一个顶层 `alloc`
- Perceus RC 层：`ring_malloc` / `ring_free` 的调用点是否在 HIR 层显式化（当前是 codegen/runtime 层）
- 值类型定义：`@value struct` 的判定规则——不含任何堆分配字段
- 与 B-002（Drop/RAII）的交互：Drop 执行期间不应该分配（或应显式标注 `with {alloc}`）
- 迁移：标准库逐个函数审视——哪些无分配（如 `List.len`）、哪些有分配（如 `List.push`）

### 12.3 已落地能力

`unsafe` effect、两级 discharge 与 `Ptr<T>` core 已实现，现行契约见 `docs/design.md` §7.12 与语言规范；剩余 extern 声明处签字检查由 B-156 跟踪，不在研究文档重复实施计划。

### 12.4 Comptime：解释器路线（B1）

**状态：暂定（2026-06-23 Discussion 设计定案）。实现前审视。**

#### 决策

选择 **comptime 模型（Zig 路线 B1：编译期解释器）**，不采用 macro 模型（Rust 路线 A：token 流变换）。理由：

1. **Ring 是类型推断优先的语言。** macro 在类型检查之前运行，拿不到推断结果，退化为字符串处理——与 Ring 的设计根基冲突。
2. **内置 derive 覆盖常见 metaprogramming 需求**（`Eq`/`Clone`/`Ord`/`Debug`/`Hash`/`Serialize`/`Deserialize`）。用户只写属性名，不写生成代码。
3. **自定义 derive 主要面向库作者。** 其 TypeInfo API 必须有独立 primer 和可执行示例，不能假定模型已有训练语料。
4. **macro 系统是一套完整的第二语言**（token 流 → AST → 类型信息不可用 → 输出 token 流）；为剩余场景引入第二套表面机制违反公理⑧。

**LLM 兼容评估**：内置 derive 使用熟悉的 `@derive(Debug)` 形态；自定义 comptime 函数必须依靠仓库 primer、签名与诊断形成闭环，不把外部训练数据量当作设计保证。

#### 模型

```ring
// 内置 derive（编译器实现，用户零代码）
@derive(Debug, Clone, Eq, Hash)
struct User { name: Str, age: I64 }

// 自定义 derive（库作者写 comptime 函数）
comptime fn builder(info: TypeInfo) -> List<Decl> {
    let methods = info.fields.map(fn(f) {
        method_decl("with_${f.name}", [param("self"), param("val", f.type_name)],
            f.type_name, body: [set_field("self", f.name, "val")])
    })
    [impl_decl(info.name, methods)]
}

@builder
struct Config { host: Str, port: I64 }
```

#### 实现策略（实现前重审）

若采用 B1，默认候选是编译器内建、受 fuel 限制的 Ring 解释器；已归档 JS bootstrap 不再是实现路径。JIT/动态加载会扩大平台与信任边界，只有实测证明解释器不足时才进入独立 Argument。

#### Comptime 做什么 / 不做什么

| 做什么 | 不做什么 |
|--------|---------|
| 内置 derive（用户只写 `@derive`） | 外部代码生成（protobuf/OpenAPI/C 头 → .ring）——这是构建系统任务，不应进编译器 |
| 自定义 derive（库作者用 TypeInfo） | 运行时反射——comptime 在编译期求值后彻底擦除 |
| 编译期常量计算（纯函数求值） | |
| 条件编译（`comptime if`） | |

#### 外部代码生成的定位

protobuf / OpenAPI / C header → Ring 代码的生成是**构建系统任务**，由独立的 CLI 工具产出 `.ring` 文件后交给编译器。不嵌入编译器——编译器不需要嵌 protobuf 解析器、不需要发网络请求取 schema。这些是 file → file 的转换，不是类型级元编程。

#### 判定性约束

comptime 代码必须终止（公理⑤）：递归、循环和总求值步数都受显式 fuel/budget 限制；默认值在实现时用真实 workload 核定。超出预算必须给出可定位的编译错误，不允许 timeout 或挂起成为语义。

#### 实施要点（实现时核定）

- comptime 求值器的实现路径：受限解释器；是否需要 JIT 由独立性能证据决定
- TypeInfo API 的完整度：字段/变体/方法/泛型参数/约束/effect 签名具体提供多少
- `emit(decls)` 的类型检查：生成的声明需要再过 checker 验证（和 typed staging 的区别，lang-design.md §11.5）
- comptime 的 effect 约束：comptime 代码是否允许 `with {os}`（读文件？）——纯函数约束足够（公理②）
