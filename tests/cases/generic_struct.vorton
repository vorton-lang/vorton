// Test: generic struct declaration, construction, field access, methods

struct Pair<A, B> {
    first: A,
    second: B,
}

struct Wrapper<T> {
    value: T,
}

fn wrap<T>(x: T) -> Wrapper<T> {
    Wrapper { value: x }
}

fn unwrap<T>(w: Wrapper<T>) -> T {
    w.value
}

fn swap_pair<A, B>(p: Pair<A, B>) -> Pair<B, A> {
    Pair { first: p.second, second: p.first }
}

fn main() {
    // Basic generic struct
    let p = Pair { first: 1, second: "hello" }
    assert(p.first == 1, "pair first")
    assert(p.second == "hello", "pair second")

    // Generic function with struct
    let q = swap_pair(p)
    assert(q.first == "hello", "swap first")
    assert(q.second == 1, "swap second")

    // Nested generic structs
    let w = wrap(Pair { first: true, second: 42 })
    assert(unwrap(w).first == true, "nested generic")
    assert(unwrap(w).second == 42, "nested generic 2")

    // Generic struct with same type for both params
    let p2 = Pair { first: 10, second: 20 }
    assert(p2.first + p2.second == 30, "same type pair")

    // Wrapper around a list
    let wl = Wrapper { value: [1, 2, 3] }
    assert(wl.value.len() == 3, "wrapper of list")

    print("generic_struct: all tests passed")
}
