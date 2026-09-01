// @error E0503
// Test: impl block trait bound enforcement must be recursive for nested type parameters
// Wrapper<HasCallback> has a conditional Ord impl (T: Ord), but HasCallback doesn't impl Ord

struct HasCallback {
    handler: fn(Int) -> Int
}

struct Wrapper<T> {
    inner: T
}

fn main() {
    let mut items: List<Wrapper<HasCallback>> = []
    items.sort()
}
