fn main() {
    let mut xs = [10, 20, 30]
    xs.set(1, 99)
    assert(xs.get(1) == some(99), "set middle element")

    xs.set(0, 1)
    assert(xs.get(0) == some(1), "set first element")

    xs.set(2, 3)
    assert(xs.get(2) == some(3), "set last element")

    assert(xs.len() == 3, "length unchanged after set")

    print("list_set: all tests passed")
}
