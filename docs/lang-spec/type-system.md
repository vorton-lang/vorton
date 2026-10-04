# 类型系统

Vorton 采用局部双向类型推断：具名函数的签名写出，函数体内推断。类型检查同时追踪注入的 effect（见 [Effect 系统](effects.md)）与 trait bound（见 [Trait 系统](traits.md)）；能力由编译器另行推断，不属于类型。类型表达式、参数与调用的产生式见[语法](syntax.md)；本页只规定语义。

## 类型

### 原始类型

| 类型 | 描述 |
|------|------|
| `Int` | 固定 64 位有符号整数，范围 −2^63 至 2^63−1 |
| `Float` | IEEE 754 binary64 浮点数 |
| `Str` | 不可变字符串 |
| `Bool` | 布尔值 |
| `Unit` | 唯一值为 `()` 的单位类型 |
| `Never` | 底类型，没有值 |

`Never` 可以出现在任何期望类型的位置，是永不返回的操作（如 `fail.raise`、`return`、`panic`）的类型。

### 名义类型

`struct` 与 `enum` 是名义类型：字段相同但声明不同的两个类型是不同类型。Enum 的 variant 可以有位置字段、命名字段或无字段；同一 enum 的所有 variant 共享同一类型。

### Tuple

`(T₁, ..., Tₙ)`（n ≥ 2）是结构类型：不同位置写出的 `(Int, Str)` 是同一类型。没有单元素 tuple；`(T)` 就是 `T`。

### 函数类型

`fn(P₁, ..., Pₙ) -> R with ε` 是普通类型，可以作为参数、返回值、字段、容器元素与类型实参。参数与返回值可以带借出方式 `&` 或 `&mut`。两个函数类型相等，当且仅当参数个数、各参数的类型与借出方式、返回类型与借出方式分别相等；effect 的匹配规则见 [Effect 系统](effects.md)。函数值不支持 `==`。

### Option 与 Ordering

`Option<T>`（variant `Some(T)`、`None`）与 `Ordering`（`Less`、`Equal`、`Greater`）是官方 core root 公开声明的 enum。默认写作 `Option::Some`、`Ordering::Less`；只有显式 import constructor 后才能直接写 `Some`。没有 `T?` 缩写。

### Language intrinsic 与 core 角色

以下类型由语言直接提供，不来自任何源文件：`Int`、`Float`、`Str`、`Bool`、`Unit`、`Never`、`List<T>`、`Map<K, V>`、`Set<T>`、`Range<T>`、`Region`、`Handle<T>`、`Shared<T>`、`Weak<T>`、`Cell<T>`、`Ptr<T>`。

`Option`、`Ordering`，以及 trait `PartialEq`、`Eq`、`PartialOrd`、`Ord`、`Hash`、`Display`、`Debug`、`Drop`、`Clone`、`Copy`、`Iterator`、`Iterable` 由宿主指定的唯一官方 core root 声明。

这些短名在 Type namespace 中不能被其他声明、import 或类型参数遮蔽；它们不是关键字，不影响 Value 与 Effect namespace 的同名绑定。

以下函数由语言直接提供，在 Value namespace 中可以被遮蔽：

| 函数 | 含义 |
|---|---|
| `print(value)` | 把 `value` 的文本形式和一个换行写到标准输出；`value` 实现 `Display`。需要 `console` 能力 |
| `assert(condition: Bool, message: Str)` | `condition` 为 `false` 时 panic，panic 信息包含 `message` |
| `panic(message: Str) -> Never` | 以 `message` panic |
| `replace(place: &mut T, value: T) -> T` | 把 `value` 放进 `place`，返回原来的内容 |
| `swap(a: &mut T, b: &mut T)` | 交换两个位置的内容 |

`print` 的实参与方法调用的 receiver 一样自动只读借出，调用处不写 `&`。实参按普通调用从左到右求值，因此 `assert` 的 `message` 总会被求值。

List 字面量产生 `List<T>`，range 表达式产生 `Range<Int>`。`Ptr<T>` 只在 `unsafe` 中使用；0.1 中 `Ptr` 与非 RC 的 `extern type` 不能出现在泛型聚合的元素类型里（例如 `List<Ptr<T>>`）。

### Private 字段

字段的 visibility 与编译器所需的布局信息分离。Public struct 的 private 字段可以包含 private 类型；只有 private 类型进入 public 签名、pub 字段或 public enum payload 时才报错。

### 递归类型

struct、enum 与 tuple 不能按值包含自身，无论直接还是经由其他 struct、enum、tuple；这样的类型没有有限的大小，是编译错误。需要递归的数据经由 `List`、`Map` 或 Region 与 `Handle<T>` 保存，它们把内容放在别处：

```vorton
enum Expr {
    Num(Int),
    Add(List<Expr>),           // 可以：元素在 List 里
}
```

## 值与实体

### 值

**值**没有身份：`Int`、`Float`、`Bool`、`Unit`、`Str`、`Handle<T>`、`Range<Int>`，以及字段、payload 与元素全部是值的 struct、enum、tuple，和函数值（见[函数值与闭包](#函数值与闭包)）。

- 赋值、传参、返回、存进字段或容器，都是拷贝。原来那份照样可用，之后修改任何一份都不影响另一份。
- 值类型实现编译器定义的 `Copy`，用户不能为其他类型实现它。泛型代码中，只有 `T: Copy` 的变量在移交后还能继续使用。
- `Str` 不可变。拼接与插值产生新的 `Str`。

### 实体

**实体**有身份：`List`、`Map`、`Set`、`Region`、`Shared`、`Weak`、`Cell`、实现 `Drop` 的类型，以及字段、payload 或元素中含有实体的类型。

- 实体不会被隐式复制。不加标记的赋值、传参、返回与存储都是**移交**：移交之后，原来的名字不能再使用，除非重新赋值。需要副本时显式调用 `clone()`，要求类型实现 `Clone`。
- 实体的所有者是一个变量、另一个实体（作为字段、payload 或元素），或一个 Region。所有者结束时实体释放：
  - 同一作用域中的局部变量，在作用域结束时按声明的逆序释放；
  - 实体先释放自己，再按声明顺序释放字段；
  - Region 释放时，其中的实体按插入的逆序释放；
  - 已经移交出去的实体不在原处释放。
- 实现 `Drop` 的实体在释放时先调用 `drop`。`Drop::drop` 的 effect 限制见 [Effect 系统](effects.md)。

可以移走的位置是局部变量、按值传入的参数，以及从它们只经字段到达的部分（`a.b`、`t.0`）。移走其中一部分后，整个变量视为已经移交，重新给整个变量赋值之前不能再使用；其余部分照常在变量结束时释放。不能从下标（`xs[i]`）或借出中移走实体，要取出这些位置里的实体，用 `replace`、`swap` 或容器的 `remove`。实现 `Drop` 的值的任何部分都不能移走：字段、按值匹配时绑定的实体部分、构造时 `..base` 取走的其余字段都不行，因为 `drop` 要在完整的值上运行；读取其中值类型的部分照常是拷贝。

## 借出

### 借出方式

| 写法 | 含义 |
|---|---|
| `&place` | 只读借出：借出期间只能读，不能写，也不能移走 |
| `&mut place` | 可变借出：借出期间独占，可以读写，但不能移走 |

借出可以出现在以下位置，写法与 Rust 同形：

| 位置 | 拿走（默认） | 只读借出 | 可变借出 |
|---|---|---|---|
| 参数 | `x: T` | `x: &T` | `x: &mut T` |
| 调用处 | `f(x)` | `f(&x)` | `f(&mut x)` |
| receiver | `self` | `&self` | `&mut self` |
| 返回 | `-> T` | `-> &T` | `-> &mut T` |
| 绑定 | `let t = x` | `let t = &x` | `let t = &mut x` |
| 循环 | `for e in xs` | `for e in &xs` | `for e in &mut xs` |
| 匹配 | `match x` | `match &x` | `match &mut x` |

对值来说，“拿走”就是拷贝。

- **借出不是类型。** `&T` 与 `&mut T` 只能写在参数、返回与 `let` 标注处，不能出现在字段、enum payload、tuple 元素、容器元素或泛型实参中。读了借出绑定或实体的闭包本身是借出，不能存放，见[函数值与闭包](#函数值与闭包)。要跨调用指称实体，用 `Handle<T>`。
- **自动解引用。** 借出绑定 `t` 在表达式中就代表它借到的位置：字段、方法、运算符与赋值都直接作用在原位置上，包括整体赋值 `t = v`。没有 `*` 运算符。
- **再借出。** 把借出绑定传给借出参数，同样要写 `&t` 或 `&mut t`。不写就是从借出处移走，这是错误。借出绑定不能写成 `let mut`：它不能改为借出别处。
- **方法调用。** receiver 按方法声明自动借出，调用处不写 `&`。`&mut self` 方法只能在可修改的位置上调用。
- **临时值。** `&` 与 `&mut` 也可以作用于不是位置的表达式，例如 `f(&make())`；临时值活到所在语句结束。

可变借出与赋值要求位置可修改：位置的根是 `let mut` 变量、带 `mut` 的按值参数（`mut x: T`）、`&mut` 借出、`&mut self` 的 `self`，或经句柄访问、且当前函数可写地持有其 Region 的实体。

### 借出持续多久

| 借出 | 持续到 |
|---|---|
| 调用实参 | 调用结束 |
| `let t = &…`、`let t = &mut …` | `t` 最后一次使用 |
| `for e in &…`、`for e in &mut …` | 循环结束 |
| `match &…`、`match &mut …`、`if let` | 分支结束 |
| 函数返回的借出 | 调用方最后一次使用返回结果 |

### 返回借出

`-> &T` 与 `-> &mut T` 返回的位置必须来自以借出方式传入的参数：`-> &T` 可以来自 `&` 或 `&mut` 参数，`-> &mut T` 只能来自 `&mut` 参数。局部变量与按值参数在返回时已经结束，不能借出返回。

返回借出的调用本身就是一个位置：可以直接使用，也可以用 `let` 绑定，绑定得到同样方式的借出。调用方使用这个结果期间，这次调用中所有以借出方式传入的实参都视为仍被借出，方式与传入时相同。这条规则比按参数精确追踪粗，但不需要任何标注；多数情况下只有 `self` 一个借出实参。

```vorton
impl Inventory {
    fn items(&self) -> &List<Item> { &self.items }
    fn items_mut(&mut self) -> &mut List<Item> { &mut self.items }
    fn into_items(self) -> List<Item> { self.items }
}

let n = inv.items().len()
inv.items_mut().push(sword)
let xs = inv.items()          // 只读借出绑定；xs 最后一次使用之前，inv 不能修改
```

### 别名与修改互斥

同一时刻，一个位置要么被任意多处只读借出，要么只被一处可变借出：

1. 可变借出期间，被借出的位置及其任何部分不能被别处借出、写入或移走。别处仍可以读取其中值类型的部分：读取是当场拷贝，读到的是当前状态。
2. 只读借出期间，被借出的位置及其任何部分不能被写入、可变借出或移走。
3. 同一次调用的各个实参之间同样适用：一个位置以 `&mut` 传入后，不能再以任何方式传入这次调用。

判断两个位置是否重叠时：

- 字段按名字区分：`a.b` 与 `a.c` 不重叠。
- 下标按值区分：`xs[i]` 与 `xs[j]` 只在 `i == j` 时重叠；`Map` 按键区分。
- 经句柄的位置按句柄区分；不同类型的句柄必然不重叠。
- 容器的结构（长度与键的集合）与元素是不同的部分。只读取结构的操作（`len`、`is_empty`、`contains_key` 等）不与元素的借出冲突；改变结构的操作（`push`、`insert`、`remove`，以及可能插入新键的 `m[k] = v` 等）与任何元素的借出冲突。

编译器能证明两个位置不重叠时，不做检查；证明不了时，在后一个借出开始处做运行时检查，重叠则 panic。两处写的是完全相同的位置表达式、且中间没有修改下标时，是编译错误。

```vorton
for i in 0..n {
    for j in i + 1..n {
        resolve(&mut bodies[i], &mut bodies[j])   // 能证明 i != j，不做检查
    }
}
resolve(&mut bodies[a], &mut bodies[b])           // 运行时检查 a != b
for e in &mut enemies {
    e.aim(enemies[k].pos)                         // pos 是值，读取不冲突
}
```

语义只是“重叠则 panic”，与编译器能证明多少无关。每一处保留下来的运行时检查都作为代价导出；性能断言可以要求某处不留运行时检查。

### 未读修改

对值类型 `let mut` 变量的修改，如果之后从未被读取，是编译错误。这能捕获修改了拷贝、本应修改原位置的错误：

```vorton
let mut p = world.player.pos   // 拷贝
p.x += 1.0                     // 错误：修改结果从未被读取；修改原位置写作 let p = &mut world.player.pos
```

## Region 与句柄

### Region

`Region` 是实体，用来存放寿命相同的一组实体，并发放指向它们的句柄。一个 Region 可以存放任意类型。

- `Region::new()` 创建空 Region。Region 和其他实体一样由变量、字段或另一个 Region 拥有。
- `r.insert(value)` 把 `value` 移入 `r`，返回 `Handle<T>`；`r.remove(h)` 把实体移出并返回它，之后指向它的句柄全部失效；`r.contains(h)` 判断句柄是否仍然有效。`insert` 与 `remove` 要求可变借出 `r`。
- 没有隐式的 Region。局部变量拥有的实体不在任何 Region 中，用借出交给其他函数。

### 句柄

`Handle<T>` 是值：可以拷贝、用 `==` 判断是否指向同一实体、哈希。句柄不让实体存活，自身也不带访问权。

经句柄访问实体的写法是 `h.field`、`h.method()`、`&h` 与 `&mut h`，它们都作用在句柄指向的实体上。整体替换实体用 `replace(&mut h, value)`；`h = other` 只改变句柄变量本身。

每次经句柄访问，运行时检查三件事：

1. 实体仍然存在。实体已被移出，或它所在的 Region 已释放时，访问 panic。
2. 实体所在的 Region 被当前函数持有；写入与可变借出要求可写地持有。
3. 与正在进行的借出不冲突，见[别名与修改互斥](#别名与修改互斥)。

句柄失效后，访问只会失败，绝不会访问到别的实体。

### 持有

函数持有一个 Region，当且仅当这个 Region 是函数的某个参数或局部绑定本身，或者能从它们经字段路径到达。经句柄或容器元素才能到达的 Region 不算持有；需要时先把它借出到局部绑定，例如 `let level = &mut world.levels[i]`。

经只读借出到达的 Region 只能读；经可变借出、`let mut` 变量或 `mut` 按值参数到达的 Region 可以写。因此函数签名显示了它可能读写哪些 Region。

```vorton
struct Enemy { target: Handle<Player>, hp: Int }

fn chase(level: &mut Region, e: Handle<Enemy>) {
    e.target.hp -= 10          // 检查 e 与 e.target 仍在、都在 level 中
}
```

## 共同所有与内部可变

### Shared 与 Weak

- `Shared::new(value)` 创建共同所有的 `value`。`s.clone()` 增加一个所有者，不复制内容；最后一个所有者释放时，内容随之释放。
- 经 `Shared` 只能读：`s.field`、`&s`。要修改共享的内容，在其中放 `Cell<T>`。
- `Shared::downgrade(&s)` 返回 `Weak<T>`，它不让内容存活；`w.upgrade()` 返回 `Option<Shared<T>>`。

### Cell

`Cell<T>` 是内部可变性的唯一来源。`c.borrow()` 返回 `&T`，`c.borrow_mut()` 返回 `&mut T`；两者都只要求只读地访问 `c`，借出状态在运行时检查：可变借出期间再次借出，或只读借出期间可变借出，都会 panic。

### 成环

值、借出与句柄都不会造成泄漏：句柄成环不影响释放。只有 `Shared` 之间可能成环。一个类型经 `Shared` 的强引用能回到自身、且路径上有 `Cell` 时，编译器判定它可能成环，对它启用运行时环回收；其余 `Shared` 只做计数。

可能成环的类型中不能含有实现 `Drop` 的类型：环回收的时机不确定，而实体的释放必须是确定的。

`Shared` 的计数是否原子、`Cell` 用借用标记还是锁，由编译器按是否跨线程决定。0.1 没有并发。

## 函数值与闭包

具名函数可以作为值使用。带位置字段的 enum constructor 不是函数值，需要时写成闭包：`fn(x) { Option::Some(x) }`。

函数值与其他类型一样，可以拿走，也可以借出：

- **拥有的函数值**写作 `fn(A) -> B`，出现在参数、返回值、字段、容器元素与类型实参中。拿到它的一方可以存放，以后再调用。
- **借出的回调**是写作 `f: &fn(A) -> B` 的参数。被调函数只在这次调用期间使用它：可以调用，可以再借给其他 `&fn` 参数，不能存放，也不能返回。

闭包可以读外部变量，但不能修改它们，也不能从中移走实体；读到的值是拷贝。读了外部的实体或借出绑定的闭包是**借出的闭包**，它本身就是一次借出，与 `let r = &xs` 的 `r` 一样：

- 它可以直接写在 `&fn` 参数位置上，也可以用 `let` 绑定到局部变量；
- 在它还可能被使用期间，它读到的每个外部位置都算作被 `&` 借出，按[别名与修改互斥](#别名与修改互斥)检查；直接写在实参位置上时，这段期间就是这次调用，与这次调用的其他实参一起检查；
- 它可以调用，可以用 `&f` 传给 `&fn` 参数，但不能拷贝、移交、返回，也不能存进字段或容器，因为那样它会离开它读的那些变量。

回调只读不改，要逐个修改外部状态时写 `for` 循环。

```vorton
fn for_each_neighbor(grid: &Grid, pos: Pos, visit: &fn(Pos)) { ... }

let blocked: Set<Pos> = load_walls()
for_each_neighbor(&grid, here, fn(p) { if !blocked.contains(p) { ... } })
print(blocked.len())          // blocked 只在那次调用期间被借出
```

其他闭包只读外部的值，在创建时拷贝它们，是普通的函数值 `fn(A) -> B`：可以拷贝、移交、返回与存放。它不能修改自己拷贝来的变量。所以函数值都是值。

存放的闭包不持有可修改的状态。回调要修改的状态由调用它的一方以 `&mut` 参数传入；要指向某个特定实体时，捕获它的 `Handle`，经参数[持有](#持有)它所在的 Region：

```vorton
struct World { score: Int, players: Region }

fn on_click(button: &mut Button, handler: fn(&mut World)) { ... }

on_click(&mut button, fn(world) { world.score += 1 })
let target: Handle<Player> = world.players.insert(Player { hp: 10 })
on_click(&mut button, fn(world) { target.hp -= 1 })   // 经 world 持有 players
```

存在字段中的函数值通过 `(value.field)(args)` 调用。

## 容器

`List<T>`、`Map<K, V>` 与 `Set<T>` 是实体。

- `xs[i]` 与 `m[k]` 是位置。元素是值时，读取得到拷贝；元素是实体时，要借出（`&xs[i]`）、`clone()` 或用 `remove` 取出。
- 在可修改的位置上，`xs[i] = v` 替换元素，`m[k] = v` 插入或替换。`xs[i]` 越界、读取 `m[k]` 时键不存在，都会 panic。
- `xs.clone()` 复制整个容器，要求元素实现 `Clone`。
- 借出遍历 `for e in &xs` 与 `for e in &mut xs` 在 0.1 中只对 `List`（逐个元素）与 `Map`（逐个值）成立；`Set` 只能 `for e in &s`，逐个拷贝元素，元素不能原地修改。按值遍历 `for e in xs` 拿走容器：`List` 与 `Set` 逐个产出元素，`Map` 逐个产出 `(键, 值)`。

`Map` 按插入顺序保存条目，遍历与 `keys()` 都按这个顺序；替换已有键的值不改变它的位置，删除后再插入的键排在最后。键的类型必须是能用 `==` 比较的值类型：`Int`、`Str`、`Bool`，以及只由它们（和 `Unit`）组成的 tuple、struct 与 enum；`Float` 不能作键，手写了 `PartialEq` 的类型也不能（它没有结构化的 `Hash`）。`Set` 同样按插入顺序保存元素，元素类型的要求与 `Map` 的键相同。

0.1 的容器方法如下，键与插入的值按值传入：

| `List<T>` | 说明 |
|---|---|
| `push(&mut self, value: T)` | 追加到末尾 |
| `pop(&mut self) -> Option<T>` | 取出最后一个元素 |
| `insert(&mut self, index: Int, value: T)` | 插入到 `index`，`index` 可以等于长度 |
| `remove(&mut self, index: Int) -> T` | 取出 `index` 处的元素，后面的元素前移 |
| `clear(&mut self)` | 释放全部元素 |
| `len(&self) -> Int`、`is_empty(&self) -> Bool` | 长度 |
| `contains(&self, value: T) -> Bool` | 只对能用 `==` 比较的值元素提供 |
| `get(&self, index: Int) -> Option<T>` | 只对值元素提供，返回拷贝；越界得到 `None` |

| `Map<K, V>` | 说明 |
|---|---|
| `Map::new() -> Map<K, V>` | 空表；`K`、`V` 由期望类型确定 |
| `insert(&mut self, key: K, value: V) -> Option<V>` | 插入或替换，返回原来的值 |
| `remove(&mut self, key: K) -> Option<V>` | 删除并返回值 |
| `get(&self, key: K) -> Option<V>` | 只对值类型的 `V` 提供，返回拷贝 |
| `contains_key(&self, key: K) -> Bool` | 键是否存在 |
| `keys(&self) -> List<K>` | 按插入顺序的全部键 |
| `clear(&mut self)` | 释放全部条目 |
| `len(&self) -> Int`、`is_empty(&self) -> Bool` | 条目数 |

| `Set<T>` | 说明 |
|---|---|
| `Set::new() -> Set<T>` | 空集；`T` 由期望类型确定 |
| `insert(&mut self, value: T) -> Bool` | 加入元素；原来没有时返回 `true` |
| `remove(&mut self, value: T) -> Bool` | 删除元素；原来有时返回 `true` |
| `contains(&self, value: T) -> Bool` | 元素是否存在 |
| `clear(&mut self)` | 删除全部元素 |
| `len(&self) -> Int`、`is_empty(&self) -> Bool` | 元素数 |

## 字符串

`Str` 是不可变的 UTF-8 字节序列。位置与长度都按字节计；需要逐个字符时用 `chars()`。下列方法的 receiver 都是 `&self`，参数按值传入，不改变原字符串：

| 方法 | 说明 |
|---|---|
| `len(&self) -> Int`、`is_empty(&self) -> Bool` | 字节数 |
| `contains(&self, part: Str) -> Bool` | 是否含有 `part` |
| `starts_with(&self, prefix: Str) -> Bool`、`ends_with(&self, suffix: Str) -> Bool` | 前缀、后缀 |
| `find(&self, part: Str) -> Option<Int>` | `part` 第一次出现的字节位置 |
| `slice(&self, start: Int, end: Int) -> Str` | 字节位置 `start` 到 `end`（不含）；越界、`start > end` 或不在字符边界上时 panic |
| `split(&self, separator: Str) -> List<Str>` | 按分隔符切开，相邻分隔符之间得到空串；分隔符为空时 panic |
| `trim(&self) -> Str` | 去掉两端的 ASCII 空白（空格、`\t`、`\n`、`\r`） |
| `replace(&self, from: Str, to: Str) -> Str` | 替换全部不重叠的出现；`from` 为空时 panic |
| `repeat(&self, count: Int) -> Str` | 重复 `count` 次；`count` 为负时 panic |
| `chars(&self) -> List<Str>` | 逐个 Unicode 字符 |
| `to_upper(&self) -> Str`、`to_lower(&self) -> Str` | 只转换 ASCII 字母 |
| `parse_int(&self) -> Option<Int>` | 可带一个 `+` 或 `-` 的十进制整数；有其他字符或超出 `Int` 时得到 `None` |

## 代价模型

以下保证不需要阅读编译器也能推断；其余优化一律尽力而为，不可依赖：

1. 实体的移交、借出与返回：O(1)，不复制内容。
2. 值的拷贝与值的大小成正比；`Str` 与 `Handle` 的拷贝是 O(1)。
3. `clone()` 复制全部内容；`Shared` 的 `clone()` 只增加计数。
4. 字段只含标量的 struct 与 tuple，在 `List` 中连续存放，布局与 C 数组一致。
5. 实体在所有者结束时释放，顺序见[实体](#实体)。
6. 下标越界、句柄失效与持有、同一位置的重叠借出、`Cell` 的借用都在运行时检查；编译器能证明成立的检查省略，其余作为代价导出。
7. 函数对自身的[尾调用](#尾调用)不增长栈。对其他函数的尾调用在 0.1 中不作保证，之后提供。

### 尾调用

调用返回之后，函数除了原样返回它的结果再没有别的事要做，这个调用才是尾调用：

- 调用处于尾位置：它是函数体的结果或 `return` 的值，或者是处于尾位置的代码块、`if` 分支、`match` 分支的结果。
- 实参不借出本函数的局部变量或临时值。被借出的值要活到被调函数结束，之后才能释放；借出参数，或经借出参数到达的位置，不受此限。
- 调用时，本函数的局部变量与临时值都不可能还持有带手写 `Drop` 的值（包括字段与元素中的），因为它们的 `drop` 要在调用之后执行。已经移走的值不算，例如作为实参传给这次调用的值。

其余局部变量与临时值的释放观察不到，可以提前到调用之前，所以不妨碍尾调用。

## 推断

### 签名与函数体

- 具名函数、方法与 trait 方法的每个参数都必须写类型与借出方式；省略返回类型表示 `Unit`。
- 函数体内的局部变量、闭包参数与闭包返回类型由推断得到。期望类型从外向内传递：`let` 标注、参数类型、返回类型与字段类型都会约束其中的表达式。例如空列表 `[]` 需要期望类型。
- 整数字面量是 `Int`，浮点字面量是 `Float`；数值之间没有隐式转换。
- 局部 `let` 不泛化：同一个绑定只有一个类型。

### 泛型

泛型函数显式声明类型参数，例如 `fn first<T: Copy>(xs: &List<T>) -> Option<T>`。每次调用由实参与期望类型推断类型实参：实参从左到右确定类型实参，仍未确定的再由调用的期望类型确定；某个实参本身需要期望类型（例如 `[]` 或 `Option::None`）而此时还确定不了时，是错误。调用处不能显式写类型实参。

0.1 不支持多态递归：在互相调用（包括直接调用自身）的一组函数内部，每个类型实参要么就是调用方自己的某个类型参数，要么不含任何类型参数。例如 `fn grow<T>(x: T) { grow([x]) }` 是错误。这保证每个泛型函数只需要有限个实例。

类型参数在泛型代码中按实体对待：没有 `Copy` bound 时，移交之后不能再使用。

### 类型相等

两个类型相等，当且仅当它们是同一原始类型、同一名义声明且类型实参分别相等、元素个数相同且对应元素相等的 tuple，或按上文规则相等的函数类型。`Never` 可以用在任何期望类型处。Type alias 是透明的。

## 表达式与语句

- **运算符**：`+ - * / %` 与一元 `-` 要求两侧同为 `Int` 或同为 `Float`。`== !=` 要求类型实现 `PartialEq`；`< > <= >=` 要求实现 `PartialOrd`，见[比较 trait](traits.md#比较-trait)。比较运算符自动只读借出两侧。`&& || !` 作用于 `Bool`。
- **调用**：实参按参数的借出方式检查。`&T` 参数要求 `&e`，`&mut T` 参数要求 `&mut place`，按值参数接受任意表达式：实体从位置移走，值被拷贝。
- **字段与构造**：struct 构造必须给出全部字段，且不能有多余字段；`..base` 用给定的值补齐其余字段。
- **List 字面量**：所有元素同型。**Range**：`a..b` 与 `a..=b` 的两端都是 `Int`。
- **代码块、`if`、`match`**：值的规则见[语法](syntax.md#代码块与语句)。控制无法越过的代码块类型为 `Never`：其中某一项是 `return`、`break`、`continue`，或类型为 `Never` 的表达式，或没有 `break` 的 `loop`。`if` 与 `match` 的各分支必须同型；没有 `else` 的 `if` 类型为 `Unit`。`match` 必须穷尽，见[模式匹配](patterns.md)。
- **字符串插值**：`"${e}"` 只读借出 `e`，要求它实现 `Display`，结果为 `Str`。
- **`catch`、`handle`**：见 [Effect 系统](effects.md)。
- **`for x in e`**：`e` 是 `&place` 或 `&mut place` 时，按[容器](#容器)借出遍历；`e` 是 `Range<Int>` 时编译为计数循环；`e` 是按值的 `List`、`Map` 或 `Set` 时拿走它并逐个产出元素；`e` 实现 `Iterator` 时拿走它并反复调用 `next`；`e` 实现 `Iterable` 时先调用 `iter`。

同一表达式中，子表达式从左到右求值：被调函数或 receiver 先于参数，参数依次求值。赋值也按源码从左到右：`p = e` 先求 `p` 中的下标与键，再求 `e`，最后写入；目标元素是否存在在写入时检查，所以 `e` 改变了容器、目标元素已不存在时 panic。复合赋值 `p op= e` 同样先求 `p` 中的下标，再只求值 `e` 一次，然后读取 `p` 的当前值、运算并写回；`e` 失败时不写回。

## 数值语义

`Int` 与 `Float` 的普通算术只接受同型运算数，不做隐式转换，也没有数值重载。

### `Int`

范围固定为 `−9223372036854775808..=9223372036854775807`，不随平台、构建模式或优化级别变化。`unsafe` 不改变算术语义。

- 加、减、乘或一元取负的数学结果超出范围时 panic；
- 除数为零的 `/` 与 `%` panic；`−9223372036854775808 / -1` 与 `% -1` 也 panic；
- 其余除法向零截断，余数满足 `a = q * b + r`，非零 `r` 与 `a` 同号且 `|r| < |b|`。例如 `−7 / 3 = −2`，`−7 % 3 = −1`。

这些 panic 不引入 `fail` effect，见 [Panic](effects.md#panic)。普通算术不回绕、不饱和。

独立的正整数字面量不得大于 `9223372036854775807`。唯一例外是一元负号直接作用于 `9223372036854775808`（中间可以隔任意层括号），整体表示最小 `Int`：

```vorton
let min = -9223372036854775808
let too_large = 9223372036854775808   // 错误：超出范围
let overflow = -min                   // 运行时 panic
```

### `Float`

采用与 Rust `f64` 相同的 IEEE binary64 值模型，包括 subnormal、正负零、正负 Infinity 与 NaN。`+ - * /` 按 round-to-nearest ties-to-even 舍入；除零、溢出与无效运算按浮点规则得到 Infinity 或 NaN，不 panic。NaN 的 payload 与符号不作保证。

`%` 是截断余数，非零结果与被除数同号，按数学余数得到 binary64 结果：

| 输入 | 结果 |
|---|---|
| `5.5 % 2.0` | `1.5` |
| `-5.5 % 2.0` | `-1.5` |
| `-0.0 % 2.0` | `-0.0` |
| NaN 参与、被除数无限、或除数为零 | NaN |
| 被除数有限、除数无限 | 被除数本身 |

`Float` 的文本形式（`Display`）与 ECMAScript 的 `Number::toString` 相同：取能精确读回同一个值的最短十进制数字；科学记数法的十进制指数 e 满足 −7 < e < 21 时用普通写法，否则用指数写法。例如 `100.0` 写作 `100`，`0.001` 写作 `0.001`，`0.0000001` 写作 `1e-7`，`1e21` 写作 `1e+21`；NaN 写作 `NaN`，无穷写作 `Infinity` 与 `-Infinity`，`-0.0` 写作 `0`。`Int` 写作十进制，`Bool` 写作 `true` 与 `false`。

浮点字面量按精确十进制值恰好舍入一次到 binary64；舍入为 Infinity 时报错。优化不得隐式融合为 FMA、保留额外中间精度或把 subnormal 刷成零。不提供浮点异常标志与可切换的舍入模式。

## 方法解析

`receiver.method(args)` 总是方法调用，按以下顺序查找：

1. receiver 类型的固有方法；
2. `Str`、`Int`、`Float`、`List`、`Map`、`Set`、`Region`、`Shared`、`Weak`、`Cell` 的语言内建方法；
3. receiver 类型可用的 trait impl；
4. receiver 是带 bound 的类型参数时，通过 bound 中的 trait 查找。

receiver 是 `Handle<T>` 时，先按 `Handle` 自身的方法查找，再按 `T` 查找。找不到时报错。

## 作用域

- 作用域是词法嵌套的：函数体、代码块、循环体、`match` 分支、`if let` 分支、闭包各自成为一层。
- `let` 绑定从声明处到所在作用域结束可见；同一作用域中再次 `let` 同名变量会创建新绑定，可以改变类型。
- `match` 与 `catch` 分支的模式绑定只在该分支内可见；`if let` 的绑定只在成功分支可见。
- 类型参数在所属声明的 bound、签名与函数体中可见，也对内部闭包可见。同一列表中不得重名，内层类型参数不得遮蔽仍可见的外层类型参数。
- `effect E` 参数属于 Effect namespace，在所属函数的签名与函数体中可见。
- `Self` 在 struct、enum、trait 与 impl 内部表示当前类型、trait 的实现者或 impl 的目标类型；在这些范围之外使用 `Self` 是错误。

## 待定

- effect 在函数签名中的写法（Milestone 4 定稿）。
- 派生（derive）的写法。
- 按类型遍历 Region 中全部实体的写法。
- 可能为空的借出返回，例如容器按键查找（Rust 的 `Option<&T>`）。
- 用户类型的借出遍历。
- Region 的追踪回收策略。
