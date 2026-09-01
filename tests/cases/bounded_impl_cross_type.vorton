// Regression test for #72: impl<T: Eq> bounded impl cross-type call conflict
// When calling a bounded impl method on different concrete types in the same scope,
// the second call should not leak type variable unification from the first call.

impl<T: Eq> List {
    fn has_item(self, item: T) -> Bool {
        for x in self {
            if x == item { return true }
        }
        false
    }
}

fn main() {
    // Core regression: different concrete types in same scope
    assert([1, 2, 3].has_item(2), "int has_item")
    assert(["a", "b"].has_item("a"), "str has_item")

    // Same type multiple calls should still work
    assert([10, 20].has_item(10), "int has_item again")
    assert(!["x"].has_item("y"), "str not has_item")

    // Bool type as third distinct type
    assert([true, false].has_item(true), "bool has_item")

    print("bounded_impl_cross_type: all tests passed")
}
