// B-056: Closure capturing and mutating outer `let mut` variable injects mut<T> effect
// Tests that the effect system correctly tracks mutation of captured variables.

// 1. Closure modifying captured `let mut` — produces mut effect, observable at runtime
fn test_captured_mut_basic() {
    let mut counter = 0
    let bump = fn() {
        counter = counter + 1
    }
    bump()
    bump()
    assert(counter == 2, "captured mut: counter should be 2")
}

// 2. Closure only reading captured `let mut` — no mut effect
// If mut effect were injected for reads, this would fail with effect violation.
fn test_read_only_capture() {
    let mut x = 42
    let reader = fn() -> Int {
        x
    }
    assert(reader() == 42, "read-only capture works")
}

// 3. Closure modifying its own local `let mut` — no mut effect (B-048 local cancellation)
fn test_local_mut_no_effect() {
    let f = fn() -> Int {
        let mut local = 0
        local = local + 1
        local
    }
    assert(f() == 1, "local mut in closure has no external effect")
}

// 4. Closure capturing and mutating via field access
fn test_captured_field_mut() {
    let mut items: List<Int> = []
    let add_item = fn(x: Int) {
        items.push(x)
    }
    add_item(10)
    add_item(20)
    assert(items.len() == 2, "captured field mut: items should have 2 elements")
}

// 5. Multiple closures sharing same captured `let mut`
fn test_multi_closure_shared_capture() {
    let mut val = 0
    let inc = fn() { val = val + 1 }
    let dec = fn() { val = val - 1 }
    inc()
    inc()
    inc()
    dec()
    assert(val == 2, "multi-closure shared capture: val should be 2")
}

fn main() {
    test_captured_mut_basic()
    test_read_only_capture()
    test_local_mut_no_effect()
    test_captured_field_mut()
    test_multi_closure_shared_capture()
    print("closure_mut_effect: all tests passed")
}
