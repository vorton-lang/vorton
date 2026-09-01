fn main() {
    // List.clear
    let mut xs = [1, 2, 3]
    assert(xs.len() == 3, "list has 3 elements")
    xs.clear()
    assert(xs.len() == 0, "list cleared")
    assert(xs.is_empty(), "list is empty after clear")
    xs.push(42)
    assert(xs.len() == 1, "list usable after clear")

    // Map.clear
    let mut m = map_from([("a", 1), ("b", 2)])
    assert(m.len() == 2, "map has 2 entries")
    m.clear()
    assert(m.len() == 0, "map cleared")
    assert(m.is_empty(), "map is empty after clear")
    m.insert("c", 3)
    assert(m.len() == 1, "map usable after clear")

    // Set.clear
    let mut s = set_from([10, 20, 30])
    assert(s.len() == 3, "set has 3 elements")
    s.clear()
    assert(s.len() == 0, "set cleared")
    assert(s.is_empty(), "set is empty after clear")
    s.insert(99)
    assert(s.len() == 1, "set usable after clear")

    print("collection_clear: all tests passed")
}
