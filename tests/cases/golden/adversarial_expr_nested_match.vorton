// B-100 P1.3 adversarial: nested match expressions
// scrutinee drop timing with match-in-match.

enum Shape {
    Circle(Int),
    Rect(Int, Int),
    None_,
}

fn classify(s: Shape) -> Str {
    match s {
        Shape::Circle(r) => match r {
            0 => "zero-circle",
            _ => "circle-${r}",
        },
        Shape::Rect(w, h) => match w == h {
            true => "square-${w}",
            false => "rect-${w}x${h}",
        },
        Shape::None_ => "none",
    }
}

enum Tree {
    Leaf(Int),
    Node(Tree, Tree),
}

fn tree_sum(t: Tree) -> Int {
    match t {
        Tree::Leaf(v) => v,
        Tree::Node(left, right) => tree_sum(left) + tree_sum(right),
    }
}

fn tree_depth(t: Tree) -> Int {
    match t {
        Tree::Leaf(_) => 1,
        Tree::Node(left, right) => {
            let ld = tree_depth(left)
            let rd = tree_depth(right)
            1 + if ld > rd { ld } else { rd }
        },
    }
}

fn make_shape(kind: Int) -> Shape {
    match kind {
        0 => Shape::Circle(5),
        1 => Shape::Rect(3, 4),
        2 => Shape::Rect(7, 7),
        _ => Shape::None_,
    }
}

fn main() {
    print(classify(Shape::Circle(0)))
    print(classify(Shape::Circle(3)))
    print(classify(Shape::Rect(5, 5)))
    print(classify(Shape::Rect(2, 3)))
    print(classify(Shape::None_))

    let desc = classify(make_shape(1))
    print("from_fn=${desc}")

    let tree = Tree::Node(
        Tree::Leaf(1),
        Tree::Node(Tree::Leaf(2), Tree::Leaf(3))
    )
    print("sum=${tree_sum(tree)}")

    let tree2 = Tree::Node(
        Tree::Node(Tree::Leaf(10), Tree::Leaf(20)),
        Tree::Leaf(30)
    )
    print("depth=${tree_depth(tree2)}")

    let label = match make_shape(2) {
        Shape::Circle(r) => "c${r}",
        Shape::Rect(w, h) => match w * h {
            0 => "empty",
            _ => "area=${w * h}",
        },
        Shape::None_ => "n",
    }
    print("label=${label}")

    let s = "hello"
    let r = match s {
        "hello" => "greeting",
        "bye" => "farewell",
        _ => "unknown",
    }
    print("str_match=${r}")

    for i in 0..4 {
        let shape = make_shape(i)
        let tag = match shape {
            Shape::Circle(_) => "C",
            Shape::Rect(_, _) => "R",
            Shape::None_ => "N",
        }
        print("${i}:${tag}")
    }
}
