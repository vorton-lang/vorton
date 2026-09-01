// Test: closures capturing variables from enclosing scope

fn make_adder(n: Int) -> fn(Int) -> Int {
    fn(x: Int) -> Int { x + n }
}

fn make_counter() -> fn() -> Int {
    let mut count = 0
    fn() -> Int {
        count = count + 1
        count
    }
}

fn main() {
    // Capture immutable binding
    let add5 = make_adder(5)
    assert(add5(10) == 15, "closure captures immutable")
    assert(add5(0) == 5, "closure captures immutable 2")

    // Capture mutable variable
    let counter = make_counter()
    assert(counter() == 1, "counter call 1")
    assert(counter() == 2, "counter call 2")
    assert(counter() == 3, "counter call 3")

    // Multiple closures sharing captured mutable variable
    let mut shared = 0
    let inc = fn() { shared = shared + 1 }
    let get = fn() -> Int { shared }
    inc()
    inc()
    assert(get() == 2, "shared mutable capture")

    // Nested closure capture
    let outer = 10
    let f = fn() -> fn() -> Int {
        let middle = 20
        fn() -> Int { outer + middle }
    }
    assert(f()() == 30, "nested closure capture")

    print("closure_capture: all tests passed")
}
