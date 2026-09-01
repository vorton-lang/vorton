fn main() {
    let mut xs = [10, 20, 30]

    // pop returns last element
    if let some(last) = xs.pop() {
        assert(last == 30, "pop returns last element")
    } else {
        panic("expected some")
    }
    assert(xs.len() == 2, "list shrinks after pop")

    // pop again
    if let some(second) = xs.pop() {
        assert(second == 20, "pop returns new last")
    } else {
        panic("expected some")
    }

    // pop last remaining
    if let some(first) = xs.pop() {
        assert(first == 10, "pop returns first")
    } else {
        panic("expected some")
    }

    // pop on empty returns none
    assert(xs.is_empty(), "list now empty")
    match xs.pop() {
        none => assert(true, "pop on empty is none"),
        some(v) => panic("should be none"),
    }

    print("list_pop: all tests passed")
}
