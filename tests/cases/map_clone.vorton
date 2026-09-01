// Test: map_clone function

fn main() {
    let original = map_from([(1, "one"), (2, "two"), (3, "three")])
    let mut cloned = map_clone(original)

    // Clone has same content
    assert(cloned.len() == 3, "clone len")
    match cloned.get(2) {
        some(v) => assert(v == "two", "clone get"),
        none => assert(false, "clone should have key 2")
    }

    // Mutating clone doesn't affect original
    cloned.insert(4, "four")
    assert(cloned.len() == 4, "clone mutated")
    assert(original.len() == 3, "original unchanged")

    print("map_clone: all tests passed")
}
