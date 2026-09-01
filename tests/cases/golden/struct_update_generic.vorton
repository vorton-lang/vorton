// B-100 P1.1 parity: struct update with generic types — generic struct spread
// syntax, generic enum variant spread.

struct Pair<A, B> {
    first: A,
    second: B,
}

fn swap_first<A, B>(p: Pair<A, B>, new_first: A) -> Pair<A, B> {
    Pair { ..p, first: new_first }
}

enum Tree<T> {
    Leaf { value: T },
    Node { left: Tree<T>, right: Tree<T>, value: T },
}

fn update_value<T>(t: Tree<T>, v: T) -> Tree<T> {
    match t {
        Node { left, right, value } => Node { ..t, value: v },
        Leaf { value } => Leaf { ..t, value: v },
    }
}

fn main() {
    // Generic struct update
    let p = Pair { first: 1, second: "hello" }
    let p2 = swap_first(p, 42)
    print("first=${p2.first}")
    print("second=${p2.second}")

    // Generic enum variant update
    let tree = Node { left: Leaf { value: 1 }, right: Leaf { value: 2 }, value: 0 }
    let tree2 = update_value(tree, 99)
    match tree2 {
        Node { left, right, value } => {
            print("node_val=${value}")
            match left {
                Leaf { value } => print("left_val=${value}"),
                _ => print("unexpected"),
            }
            match right {
                Leaf { value } => print("right_val=${value}"),
                _ => print("unexpected"),
            }
        },
        _ => print("unexpected"),
    }

    // Simple struct update (non-generic)
    let p3 = Pair { first: 10, second: 20 }
    let p4 = Pair { ..p3, second: 30 }
    print("updated_second=${p4.second}")
    print("kept_first=${p4.first}")
}
