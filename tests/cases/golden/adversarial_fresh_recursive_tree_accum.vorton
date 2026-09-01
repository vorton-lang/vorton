// B-100 P1.3 R3 adversarial: recursive enum (Tree) with accumulator-style
// traversal and closures passed into recursive functions.
//
// Exercises:
//   * Recursive enum (binary tree) with positional and named variants
//   * Tree traversal with accumulator (fold-style)
//   * Recursive function that takes a closure parameter
//   * Building a tree, then map + fold over it
//   * Tree depth with recursive max

enum Tree<T> {
    Leaf(T),
    Branch(Tree<T>, Tree<T>),
}

// Fold over tree with accumulator — closure applied at leaves
fn tree_fold<T, A>(t: Tree<T>, init: A, f: fn(A, T) -> A) -> A {
    match t {
        Tree::Leaf(v) => f(init, v),
        Tree::Branch(left, right) => {
            let acc1 = tree_fold(left, init, f)
            tree_fold(right, acc1, f)
        },
    }
}

// Map over tree — closure transforms each leaf value
fn tree_map<T, U>(t: Tree<T>, f: fn(T) -> U) -> Tree<U> {
    match t {
        Tree::Leaf(v) => Tree::Leaf(f(v)),
        Tree::Branch(left, right) => {
            Tree::Branch(tree_map(left, f), tree_map(right, f))
        },
    }
}

// Depth calculation (recursive max)
fn tree_depth<T>(t: Tree<T>) -> Int {
    match t {
        Tree::Leaf(_) => 1,
        Tree::Branch(left, right) => {
            let ld = tree_depth(left)
            let rd = tree_depth(right)
            1 + if ld > rd { ld } else { rd }
        },
    }
}

// Count leaves
fn tree_count<T>(t: Tree<T>) -> Int {
    match t {
        Tree::Leaf(_) => 1,
        Tree::Branch(left, right) => tree_count(left) + tree_count(right),
    }
}

// Collect all leaves into a list (in-order) via fold
fn tree_leaves(t: Tree<Int>) -> List<Int> {
    tree_fold(t, [], fn(acc: List<Int>, v) {
        let mut result = acc
        result.push(v)
        result
    })
}

fn main() {
    // Build a tree:
    //        *
    //       / \
    //      *   *
    //     / \ / \
    //    1  2 3  4
    let t = Tree::Branch(
        Tree::Branch(Tree::Leaf(1), Tree::Leaf(2)),
        Tree::Branch(Tree::Leaf(3), Tree::Leaf(4))
    )

    // fold: sum all leaves
    let sum = tree_fold(t, 0, fn(acc, v) { acc + v })
    print("sum=${sum}")

    // fold: product of all leaves
    let prod = tree_fold(t, 1, fn(acc, v) { acc * v })
    print("prod=${prod}")

    // depth
    print("depth=${tree_depth(t)}")

    // count
    print("count=${tree_count(t)}")

    // map: double each leaf, then sum
    let doubled = tree_map(t, fn(v) { v * 2 })
    let dsum = tree_fold(doubled, 0, fn(acc, v) { acc + v })
    print("doubled_sum=${dsum}")

    // leaves in-order
    let leaves = tree_leaves(t)
    let mut leaf_str = ""
    for v in leaves {
        if leaf_str == "" {
            leaf_str = v.to_str()
        } else {
            leaf_str = "${leaf_str},${v.to_str()}"
        }
    }
    print("leaves=${leaf_str}")

    // Single leaf tree
    let single = Tree::Leaf(99)
    print("single_sum=${tree_fold(single, 0, fn(acc, v) { acc + v })}")
    print("single_depth=${tree_depth(single)}")

    // Asymmetric tree (deep left)
    let asym = Tree::Branch(
        Tree::Branch(Tree::Leaf(10), Tree::Branch(Tree::Leaf(20), Tree::Leaf(30))),
        Tree::Leaf(40)
    )
    print("asym_sum=${tree_fold(asym, 0, fn(acc, v) { acc + v })}")
    print("asym_depth=${tree_depth(asym)}")
}
