// Test: bounded impl method-to-method calls in prelude (regression for #97)
// Set.has() calls Set.contains(), both in impl<T: Hash + Eq> Set

fn main() {
    let s = set_from([1, 2, 3])
    assert(s.has(2), "has should find 2")
    assert(!s.has(5), "has should not find 5")
    assert(s.contains(1), "contains should find 1")
    print("ok")
}
