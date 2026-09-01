// B-100 P1.1: recursive data type parity — recursive enum (tree), recursive
// traversal, and recursive struct (linked list via Option).

enum Tree {
    Leaf(Int),
    Node(Tree, Tree),
}

fn tree_sum(t: Tree) -> Int {
    match t {
        Tree::Leaf(n) => n,
        Tree::Node(left, right) => tree_sum(left) + tree_sum(right),
    }
}

fn tree_depth(t: Tree) -> Int {
    match t {
        Tree::Leaf(_) => 1,
        Tree::Node(left, right) => {
            let ld = tree_depth(left)
            let rd = tree_depth(right)
            if ld > rd { ld + 1 } else { rd + 1 }
        },
    }
}

fn tree_count(t: Tree) -> Int {
    match t {
        Tree::Leaf(_) => 1,
        Tree::Node(left, right) => tree_count(left) + tree_count(right),
    }
}

// Recursive struct (linked list) via Option
struct ListNode {
    value: Int,
    next: Option<ListNode>,
}

fn list_sum(node: ListNode) -> Int {
    match node.next {
        some(next_node) => node.value + list_sum(next_node),
        none => node.value,
    }
}

fn list_len(node: ListNode) -> Int {
    match node.next {
        some(next_node) => 1 + list_len(next_node),
        none => 1,
    }
}

// Recursive enum: expression evaluator
enum Expr {
    Lit(Int),
    Neg(Expr),
    Add(Expr, Expr),
}

fn eval(e: Expr) -> Int {
    match e {
        Expr::Lit(n) => n,
        Expr::Neg(inner) => 0 - eval(inner),
        Expr::Add(left, right) => eval(left) + eval(right),
    }
}

fn main() {
    // binary tree
    let tree = Tree::Node(
        Tree::Node(Tree::Leaf(1), Tree::Leaf(2)),
        Tree::Node(Tree::Leaf(3), Tree::Leaf(4))
    )
    print(tree_sum(tree))
    print(tree_depth(tree))
    print(tree_count(tree))

    // single leaf
    print(tree_sum(Tree::Leaf(42)))
    print(tree_depth(Tree::Leaf(42)))

    // linked list: 1 -> 2 -> 3 -> nil
    let list = ListNode {
        value: 1,
        next: some(ListNode {
            value: 2,
            next: some(ListNode {
                value: 3,
                next: none,
            }),
        }),
    }
    print(list_sum(list))
    print(list_len(list))

    // single node list
    let single = ListNode { value: 99, next: none }
    print(list_sum(single))
    print(list_len(single))

    // expression evaluator
    let expr = Expr::Add(
        Expr::Lit(10),
        Expr::Neg(Expr::Add(Expr::Lit(3), Expr::Lit(4)))
    )
    print(eval(expr))

    // simple expressions
    print(eval(Expr::Lit(42)))
    print(eval(Expr::Neg(Expr::Lit(5))))
}
