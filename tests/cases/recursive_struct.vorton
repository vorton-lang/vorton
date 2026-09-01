// Test: recursive struct types (self-referential through Option<T>)

struct LinkedNode {
    value: Int,
    next: Option<LinkedNode>
}

fn sum_list(node: LinkedNode) -> Int {
    match node.next {
        some(next_node) => node.value + sum_list(next_node),
        none => node.value
    }
}

fn main() {
    let c = LinkedNode { value: 3, next: none }
    let b = LinkedNode { value: 2, next: some(c) }
    let a = LinkedNode { value: 1, next: some(b) }

    assert(sum_list(c) == 3, "single node")
    assert(sum_list(b) == 5, "two nodes")
    assert(sum_list(a) == 6, "three nodes")

    print("recursive_struct: all tests passed")
}
