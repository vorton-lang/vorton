// @error E0503
// Test: impl<T: Eq> List.contains() bound must be enforced at call site
// HasCallback cannot derive Eq (function fields are not equatable)

struct HasCallback {
    handler: fn(Int) -> Int
}

fn main() {
    let items: List<HasCallback> = []
    let found = items.contains(HasCallback { handler: fn(x) { x } })
}
