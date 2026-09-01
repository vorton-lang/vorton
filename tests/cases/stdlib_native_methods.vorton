fn main() {
    // List.is_empty
    let empty: List<Int> = []
    let nonempty = [1, 2, 3]
    assert(empty.is_empty(), "empty list should be empty")
    assert(!nonempty.is_empty(), "non-empty list should not be empty")

    // List.first
    assert(nonempty.first() == some(1), "first of [1,2,3] should be some(1)")
    assert(empty.first() == none, "first of [] should be none")

    // List.last
    assert(nonempty.last() == some(3), "last of [1,2,3] should be some(3)")
    assert(empty.last() == none, "last of [] should be none")

    // Map.is_empty
    let empty_map: Map<Str, Int> = map_new()
    let nonempty_map = map_from([("a", 1)])
    assert(empty_map.is_empty(), "empty map should be empty")
    assert(!nonempty_map.is_empty(), "non-empty map should not be empty")

    // Set.is_empty
    let empty_set: Set<Int> = set_new()
    let nonempty_set = set_from([1, 2])
    assert(empty_set.is_empty(), "empty set should be empty")
    assert(!nonempty_set.is_empty(), "non-empty set should not be empty")

    print("stdlib_native_methods: all tests passed")
}
