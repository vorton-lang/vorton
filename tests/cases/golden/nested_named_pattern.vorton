// Test field-order robustness: literal & pattern in non-declaration order.
enum E { V { a: Int, b: Int, c: Int } }

enum Tree { Leaf { a: Int, b: Int }, Node { kid: Tree, label: Int } }

fn main() {
    // (1) top-level: literal reordered, pattern reordered
    let v = E::V { c: 3, a: 1, b: 2 }
    match v {
        E::V { b: bb, c: cc, a: aa } => print("top: a=${aa} b=${bb} c=${cc}")
    }

    // (2) nested named-constructor pattern with reordered inner fields
    let t = Tree::Node { kid: Tree::Leaf { a: 10, b: 20 }, label: 9 }
    match t {
        Tree::Node { kid: Tree::Leaf { b: bb, a: aa }, label } =>
            print("nested: a=${aa} b=${bb} label=${label}"),
        _ => print("fallback")
    }
}
