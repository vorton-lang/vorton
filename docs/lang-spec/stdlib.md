# 标准库

本页说明预加载 builtin 与标准库模块的语义边界，不复制完整 API 表。`std/` 模块的公开声明、trait bound 与 effect 标注以 [`std/*.ring`](../../std/) 中的源码为准；由编译器预加载的类型和原语会在下文明确标出，其精确签名以 builtin 注册表为准。

## Core 与预加载类型

`Option<T>` 是内建 enum，`T?` 是它的类型语法糖：

```ring
Option<T> = some(T) | none
```

`some` / `none`、安全解包与 HOF 方法由 core 环境提供。`?`、`catch` 和 `fail<E>` 的关系分别见[语法](syntax.md)与 [Effect 系统](effects.md)。

`print`、`assert`、`panic` 与 JSON 字符串化等基础入口声明在 [`std/io.ring`](../../std/io.ring)。0.1 capability cutover 后，console 输出携带 `console`；进程退出归 `process`。`panic` 是不可恢复的终止；可恢复错误使用 `fail<E>`。B-195 完成前源码仍存在宽泛 `io` 与漏标 host extern 的过渡实现，不能把该现状当作终态规范。

`json_stringify<T: Json>(value: T) -> Str` 只接受可取得 `Json` evidence 的类型。标准库为 `Int`、`Float`、`Bool`、`Str` 和 `List<T: Json>` 提供实现；用户 struct/enum 使用 `@derive(Json)` 显式请求结构化实现。Struct 输出按字段声明顺序组成对象；enum 输出以 `"_tag"` 保存 variant 名，随后按声明顺序输出 named 字段或 `_0`、`_1` 等 positional 字段。没有 `Json` evidence 的调用在编译期拒绝。

### `Cell<T>`

`Cell<T>` 是预加载的共享可变容器。构造本身是纯的；读取与修改都显式产生对应状态类型的 `mut<T>` marker effect：

| 操作 | 公开签名 |
|------|----------|
| `Cell(value)` | `<T>(value: T) -> Cell<T> with {}` |
| `get` | `(self: Cell<T>) -> T with {mut<T>}` |
| `set` | `(self: Cell<T>, value: T) -> Unit with {mut<T>}` |
| `update` | `(self: Cell<T>, f: fn(T) -> T with {}) -> Unit with {mut<T>}` |

`update` 的 callback 必须是纯函数。与只修改局部 `let mut` 不同，`Cell` 的 `get`、`set` 和 `update` 都跨越共享状态边界，因此 effect 不会作为局部 mutation 被豁免；不同 `T` 的 Cell 产生可共存的不同 `mut<T>` 实例。完整规则见 [Effect 系统](effects.md)。

### `Ptr<T>` 与 unsafe 原语

`Ptr<T>` 是预加载的 typed raw pointer：指针值本身可以传递和存储，不参与自动资源管理；编译器不证明它指向的内存有效、已初始化、对齐或仍存活。内存访问与生命周期操作因此进入 `unsafe` effect 边界。

- `alloc<T>(count)`、`dealloc<T>(ptr, count)` 和 `ptr_copy<T>(src, dst, count)` 产生 `unsafe`；`alloc` 返回未初始化存储，分配与释放责任由调用方配对。
- `ptr.read()`、`ptr.take()`、`ptr.write(value)` 和 `ptr.offset(index)` 产生 `unsafe`。`read` 是保留原 slot 的读取，`take` 把值移出并使原 slot 不再有效，`write` 写入新值但不负责释放旧值。
- `ptr.cast<U>()`、`ptr.addr()` 和 `ptr_from_addr<T>(address)` 只转换或观察指针值，本身是纯操作；后续访问内存仍需 `unsafe`。

这些操作必须服从 [`unsafe` effect 与 discharge 规则](effects.md#unsafe-effect)。精确名称和类型签名以 [`compiler/builtins.ring`](../../compiler/builtins.ring) 的 builtin 注册为准；host ABI 与目标表示不属于语言层 API。

## 字符串与数值

- [`std/str.ring`](../../std/str.ring) 为 `Str` 提供常用查询、切分、替换和大小写操作，并定义 Ring struct `StringBuilder`。
- [`std/num.ring`](../../std/num.ring) 提供数值转字符串及 `parse_int` / `parse_float` 等解析入口；解析失败返回 `Option`。

字符串不支持 `+` 拼接；使用插值或标准库连接操作。字符串下标失败会 panic，安全访问使用返回 `Option` 的方法。

## 集合

`List<T>`、`Map<K, V>` 和 `Set<T>` 都是标准库中定义的纯 Ring struct。它们的容器算法和公开方法位于 Ring 源码中；底层存储 bridge 不属于语言层 API 或规范表示。

### `List<T>`

[`std/list.ring`](../../std/list.ring) 定义可变、有序集合 `List<T>`。列表字面量 `[]` 产生该类型；读取、切片和 HOF 操作返回新值或 `Option`，原地操作要求可变 receiver。`List<T>` 实现 `Iterable`；依赖值相等或排序的操作分别要求 `T: Eq` 或 `T: Ord`。

```ring
let mut values = [3, 1, 2]
values.push(4)
let doubled = values.map(fn(x) { x * 2 })
```

### `Map<K, V>`

[`std/map.ring`](../../std/map.ring) 定义可变键值集合 `Map<K, V>`。长度、枚举键值等不执行 key lookup 的操作不要求额外 evidence；构造自 entries、查找、下标、插入和删除等 key 操作要求 `K: Hash + Eq`。

`map[key]` 在 key 不存在时 panic；安全查找使用 `get`，返回 `Option<V>`。当 `K: Hash + Eq` 时，`Map` 实现 `Iterable`，迭代项是 `(K, V)`。

### `Set<T>`

[`std/set.ring`](../../std/set.ring) 定义 `Set<T>`，其语言层实现是 `Map<T, Unit>` 的 Ring wrapper。成员查询、插入、删除、集合代数和需要重新建表的过滤操作要求 `T: Hash + Eq`。迭代顺序不构成语义保证。

```ring
let mut seen: Set<Str> = set_new()
seen.insert("ring")
assert(seen.contains("ring"), "membership")
```

### `Hash + Eq` 契约

Map key 与 Set element 使用同一份 `Hash + Eq` 契约：

- 相等的两个值必须产生相同 hash；
- 碰撞不代表相等，查找仍以 `Eq` 判定；
- `Int`、`Str`、`Bool` 提供内建 `Hash`；
- 用户 struct/enum 在满足 [Trait 自动派生规则](traits.md)时获得结构化 `Hash`；否则需要显式实现或会因缺少 bound 而拒绝编译。

## `Result<T, E>`

[`std/result.ring`](../../std/result.ring) 定义：

```ring
pub enum Result<T, E> {
    Ok(T),
    Err(E),
}
```

该模块提供状态查询、解包、映射等常用操作，以及把 `fail<E>` 计算捕获为 `Result<T, E>` 的 `to_result`。`Result` 是数据；`fail<E>` 是计算 effect。

## Iterator / Iterable

[`std/iterator.ring`](../../std/iterator.ring) 定义 `Iterator` 与 `Iterable` 的关联类型协议。`for x in value` 对非 range 值要求 `value` 实现 `Iterable`；List、Map 和 Set 都提供实现。自定义集合可返回自己的 iterator：

```ring
pub trait Iterator {
    type Item
    fn next(mut self) -> Item?
}

pub trait Iterable {
    type Item
    type Iter: Iterator
    fn iter(self) -> Iter
}
```

精确声明仍以源码为准；上面的短定义只展示协议形状。

## 主机服务模块

以下模块集中声明由当前 native runtime 提供的外部能力：

| 模块 | 语义范围 |
|------|----------|
| [`std/fs.ring`](../../std/fs.ring) | 文件读取、写入、存在性与删除；携带 `fs`，可恢复失败按各operation的显式`fail<E>`契约另列 |
| [`std/path.ring`](../../std/path.ring) | 纯路径拼接/目录名/文件名/扩展名；访问 cwd/filesystem 的 resolve 形态携带 `fs` |
| [`std/process.ring`](../../std/process.ring) | 参数、工作目录、退出与同步子进程携带 `process`；stderr 输出携带 `console` |

0.1 只建立已有真实 API 所需的 `console`、`fs`、`process`，不预造 `net`、`clock` 或 `random`。这些 system effect 是静态、不可 `handle` 的 effect atoms，不进入 evidence vector；宿主调用以 exact extern/intrinsic contract 进入 AbiIR HostImport。Native C 链接 runtime symbol，未来 WASM/嵌入式可替换链接 provider，但语言层不注入 root handler。需要动态 mock 时，程序声明 custom handled effect，并用显式 adapter handler把它翻译成上述 system API。

每个 host operation 只有一个公开/typed authority；宽泛 `io.read` 与无 effect 的 `read_file` 之类双路径必须在 B-195 中原子收口。Capability 只说明访问哪类宿主能力，失败仍由独立 `fail<E>` 描述。规范不按 runtime symbol、叶名或后端映射重建这些事实。

## Mutation 与 effect

集合和 iterator 的原地方法使用 `mut self`。对局部 `let mut` 的修改不会把 mutation effect 泄漏到函数签名；修改可变参数或捕获的外部状态时，编译器注入对应的多实例 `mut<T>` marker effect。完整规则见 [Effect 系统](effects.md)。
