// C-native regression: closure / trait dict / evidence passing.
// Coverage: lambda capture by value, mut-cell write-through capture (B-091),
// HOF chains (map/filter/fold), named local closure calls, closures returned
// from functions (env ownership, B-098), user trait dict dispatch through a
// generic bound (multi-method trait — slot ordering), explicit trait methods,
// derived
// Eq/Ord/Debug/Clone consumed via generic dispatch AND via ==/< operators,
// generic first-class function values carrying trait dicts (#B-087 gap 1),
// wrapped dicts for parameterized types (List<Point> equality).
// Runs on BOTH backends — differential-oracle coverage for step 5.

struct Point {
    x: Int,
    y: Int
}

enum Color {
    Red,
    Green,
    Blue
}

struct Tagged {
    label: Str,
    val: Float,
    on: Bool
}

struct Pair<A, B> {
    a: A,
    b: B
}

struct Nest {
    inner: Pair<Int, Str>
}

trait Describe {
    fn describe(self) -> Str
    fn shout(self) -> Str
}

impl Describe for Point {
    fn describe(self) -> Str {
        "P(${self.x},${self.y})"
    }
    fn shout(self) -> Str { "${self.describe()}!" }
}

impl Describe for Color {
    fn describe(self) -> Str {
        match self {
            Color::Red => "red",
            Color::Green => "green",
            Color::Blue => "blue",
        }
    }
    fn shout(self) -> Str {
        "COLOR ${self.describe()}"
    }
}

// Generic fn with a user-trait bound: dict param + dispatch through it
// (both required methods).
fn present<T: Describe>(v: T) -> Str {
    "${v.describe()} / ${v.shout()}"
}

// Generic fn with Eq + Ord bounds: ==/< through dict dispatch.
fn rank<T: Eq + Ord>(a: T, b: T) -> Str {
    if a == b { "same" } else if a < b { "less" } else { "more" }
}

// Generic first-class fn value: passing `present` around captures its dict.
fn apply_str_fn<T>(f: fn(T) -> Str, v: T) -> Str {
    f(v)
}

fn make_adder(n: Int) -> fn(Int) -> Int {
    fn(x) { x + n }
}

fn twice(f: fn(Int) -> Int, x: Int) -> Int {
    f(f(x))
}

fn main() {
    // --- closure capture by value + closure call through a local ---
    let base = 10
    let add_base = fn(x: Int) { x + base }
    print("capture: ${add_base(5)}")

    // --- mut-cell write-through capture (B-091) ---
    let mut counter = 0
    let bump = fn() { counter = counter + 1 }
    bump()
    bump()
    bump()
    print("cell: ${counter}")

    // --- HOF chain: map / filter / fold ---
    let xs = [1, 2, 3, 4, 5]
    let doubled = xs.map(fn(v) { v * 2 })
    let big = doubled.filter(fn(v) { v > 4 })
    let total = big.fold(0, fn(acc, v) { acc + v })
    print("hof: ${total}")

    // --- closure returned from a function (env outlives the frame) ---
    let add7 = make_adder(7)
    print("returned: ${add7(3)}")

    // --- fn value param called through the uniform closure ABI ---
    print("twice: ${twice(add7, 1)}")
    print("twice lambda: ${twice(fn(v: Int) { v * 3 }, 2)}")

    // --- user trait dict dispatch (two required methods) ---
    print(present(Point { x: 1, y: 2 }))
    print(present(Color::Green))

    // --- direct explicit trait-method call on a concrete type ---
    print("stub: ${Point { x: 9, y: 9 }.shout()}")

    // --- derived Eq/Ord through generic dict dispatch ---
    print("rank int: ${rank(3, 3)}")
    print("rank pt: ${rank(Point { x: 1, y: 5 }, Point { x: 2, y: 0 })}")
    print("rank pt2: ${rank(Point { x: 2, y: 0 }, Point { x: 2, y: 0 })}")
    print("rank color: ${rank(Color::Blue, Color::Red)}")

    // --- derived Eq via == on concrete structs / enums ---
    let p1 = Point { x: 4, y: 4 }
    let p2 = Point { x: 4, y: 4 }
    let p3 = Point { x: 4, y: 9 }
    print("eq: ${p1 == p2} ${p1 == p3} ${p1 != p3}")
    print("enum eq: ${Color::Red == Color::Red} ${Color::Red == Color::Blue}")

    // --- derived Ord via < on structs (lexicographic) ---
    print("ord: ${p1 < p3} ${p3 < p1}")

    // --- derived Eq over Float/Bool/Str fields ---
    let t1 = Tagged { label: "a", val: 1.5, on: true }
    let t2 = Tagged { label: "a", val: 1.5, on: true }
    let t3 = Tagged { label: "b", val: 1.5, on: false }
    print("tagged: ${t1 == t2} ${t1 == t3}")

    // --- derived Clone + Debug ---
    let pc = p1.clone()
    print("clone: ${pc == p1}")
    print("debug: ${p3.debug()}")
    print("debug enum: ${Color::Blue.debug()}")

    // --- wrapped dict: parameterized type equality (Pair<Int, Str>) ---
    let pr1 = Pair { a: 1, b: "x" }
    let pr2 = Pair { a: 1, b: "x" }
    let pr3 = Pair { a: 1, b: "y" }
    print("wrapped: ${pr1 == pr2} ${pr1 == pr3}")

    // --- nested generic struct eq (derived Call action w/ extra dicts) ---
    let n1 = Nest { inner: Pair { a: 5, b: "q" } }
    let n2 = Nest { inner: Pair { a: 5, b: "q" } }
    let n3 = Nest { inner: Pair { a: 6, b: "q" } }
    print("nest: ${n1 == n2} ${n1 == n3}")
    print("nest debug: ${n3.debug()}")

    // --- Option eq (builtin derived impl) ---
    let oa: Int? = some(3)
    let ob: Int? = some(3)
    let oc: Int? = none
    print("opt: ${oa == ob} ${oa == oc} ${oc == none}")

    // --- generic first-class fn value with trait dicts (#B-087 gap 1) ---
    print("fnval: ${apply_str_fn(present, Point { x: 8, y: 8 })}")

    // --- closure capturing a struct + calling trait methods inside ---
    let origin = Point { x: 0, y: 0 }
    let describe_offset = fn(dx: Int) {
        let moved = Point { x: origin.x + dx, y: origin.y }
        moved.describe()
    }
    print("inner: ${describe_offset(5)}")

    // --- sort_by via closure (comparator through closure ABI) ---
    let mut nums = [4, 1, 3, 2]
    nums.sort_by(fn(a, b) { a - b })
    print("sorted: ${nums.map(fn(v) { v.to_str() }).join(",")}")
}
