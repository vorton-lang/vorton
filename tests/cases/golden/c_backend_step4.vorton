// C-native regression: struct construction (incl. nested +
// spread update), field access chains, struct field assignment, enum
// construction (positional / named / zero-field variants), match compilation
// (tag dispatch, guards, or-patterns, literal & string matches, nested
// constructor patterns with fall-through re-testing, tuple patterns with
// ctor/literal elements), if-let with else, Option/Result matching.
// Deliberately restricted to the step 1-4 feature surface (no closures, no
// trait dict dispatch, no effects/catch) so it runs on BOTH backends during
// the B-163 port — differential-oracle coverage for the C backend's
// struct/enum/match wave.

struct Point {
    x: Int,
    y: Int
}

struct Wrap {
    p: Point,
    label: Str
}

enum Shape {
    Circle(Int),
    Rect(Int, Int),
    Empty
}

enum Tree {
    Leaf(Int),
    Node { left: Tree, right: Tree }
}

fn area(s: Shape) -> Int {
    match s {
        Shape::Circle(r) => 3 * r * r,
        Shape::Rect(w, h) => w * h,
        Shape::Empty => 0,
    }
}

fn sum_tree(t: Tree) -> Int {
    match t {
        Tree::Leaf(n) => n,
        Tree::Node { left, right } => sum_tree(left) + sum_tree(right),
    }
}

fn classify(n: Int) -> Str {
    match n {
        0 | 1 => "small",
        2 => "two",
        k if k > 100 => "huge",
        _ => "medium",
    }
}

fn peel(s: Shape) -> Int {
    match s {
        Shape::Rect(w, _) if w > 5 => w,
        Shape::Rect(_, h) => h,
        _ => -1,
    }
}

fn safe_div(a: Int, b: Int) -> Result<Int, Str> {
    if b == 0 { Err("div by zero") } else { Ok(a / b) }
}

fn main() {
    // struct construction + field access + field assignment
    let mut p = Point { x: 1, y: 2 }
    print("point: ${p.x},${p.y}")
    p.y = 40
    print("assigned: ${p.y}")

    // nested struct + field access chain
    let w = Wrap { p: Point { x: 7, y: 8 }, label: "box" }
    print("nested: ${w.p.x} ${w.label}")

    // spread update (B-098 dup semantics on the non-overridden field)
    let p2 = Point { ..p, x: 100 }
    print("spread: ${p2.x},${p2.y}")

    // enum variants: positional, multi-field, zero-field
    print("area circle: ${area(Shape::Circle(2))}")
    print("area rect: ${area(Shape::Rect(3, 4))}")
    print("area empty: ${area(Shape::Empty)}")

    // named-field variants + recursive enum + named-ctor patterns
    let t = Tree::Node { left: Tree::Leaf(4), right: Tree::Node { left: Tree::Leaf(5), right: Tree::Leaf(6) } }
    print("tree: ${sum_tree(t)}")

    // literal matches, or-pattern, guard, wildcard
    print(classify(0))
    print(classify(1))
    print(classify(2))
    print(classify(50))
    print(classify(500))

    // guards with duplicate ctor tags (fall-through re-testing)
    print("peel wide: ${peel(Shape::Rect(9, 1))}")
    print("peel tall: ${peel(Shape::Rect(2, 33))}")
    print("peel none: ${peel(Shape::Empty)}")

    // if-let with else, both branches
    let o: Int? = some(11)
    if let some(v) = o {
        print("iflet: ${v}")
    } else {
        print("iflet: none")
    }
    let o2: Int? = none
    if let some(v2) = o2 {
        print("iflet2: ${v2}")
    } else {
        print("iflet2: none")
    }

    // Option match
    match o {
        some(x) => print("opt match: ${x}"),
        none => print("opt match: none"),
    }

    // Result match (builtin enum registry, Ok/Err tags)
    match safe_div(10, 2) {
        Ok(v) => print("div ok: ${v}"),
        Err(e) => print("div err: ${e}"),
    }
    match safe_div(1, 0) {
        Ok(v) => print("div ok: ${v}"),
        Err(e) => print("div err: ${e}"),
    }

    // tuple pattern with ctor + literal elements (#B-087 literal element test)
    let pair = (Shape::Circle(1), 5)
    match pair {
        (Shape::Circle(r), 5) => print("tuple: circle ${r} five"),
        (Shape::Circle(r), k) => print("tuple: circle ${r} ${k}"),
        (_, k) => print("tuple: other ${k}"),
    }

    // nested ctor pattern mismatch must fall through to the next arm
    let t2 = Tree::Node { left: Tree::Node { left: Tree::Leaf(1), right: Tree::Leaf(2) }, right: Tree::Leaf(3) }
    match t2 {
        Tree::Node { left: Tree::Leaf(l), .. } => print("nested: leaf ${l}"),
        Tree::Node { .. } => print("nested: node"),
        Tree::Leaf(n) => print("nested: top leaf ${n}"),
    }

    // string literal match
    let msg = match "hi" {
        "yo" => "greeting-yo",
        "hi" => "greeting-hi",
        _ => "unknown",
    }
    print(msg)

    // match as expression feeding arithmetic
    let bonus = match area(Shape::Rect(2, 3)) {
        6 => 100,
        _ => 0,
    }
    print("bonus: ${bonus + 1}")
}
