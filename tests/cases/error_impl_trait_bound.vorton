// @error E0503
// Test: impl block trait bounds must be enforced at call site
// Types that don't implement the required trait bound should produce a compile error

struct HasCallback {
    handler: fn(Int) -> Int
}

fn main() {
    // HasCallback cannot derive Ord (function fields are not orderable)
    let mut items: List<HasCallback> = []
    items.sort()
}
