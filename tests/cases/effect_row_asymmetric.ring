// Test: asymmetric effect row unification (closed vs open)
// Regression test for #104: unmatched effects silently dropped
// when one side is closed and the other is open.

// A function with explicit (closed) effect annotation
fn effectful_io() -> Int with {console} {
    42
}

// A function with explicit closed row [io, fail<Str>]
fn effectful_io_fail() -> Int with {console, fail<Str>} {
    42
}

// Caller with open row — should infer io from callee
fn caller_open() -> Int {
    effectful_io()
}

// Caller with open row — should infer io + fail from callee
fn caller_open2() -> Int {
    effectful_io_fail()
}

// A function that takes a callback with effects and
// returns with the same effects
fn apply_fn(f: fn() -> Int) -> Int {
    f()
}

fn main() {
    let r1 = caller_open()
    assert(r1 == 42, "caller_open")

    let r2 = caller_open2() catch { _ => 0 }
    assert(r2 == 42, "caller_open2")

    // apply_fn with a pure callback
    let r3 = apply_fn(fn() -> Int { 10 })
    assert(r3 == 10, "apply_fn pure")

    // apply_fn with effectful callback
    let r4 = apply_fn(fn() -> Int { effectful_io() })
    assert(r4 == 42, "apply_fn effectful")

    // Closed [io] unified with open row through HOF
    let vals = [1, 2, 3]
    let mut sum = 0
    vals.map(fn(x) {
        sum = sum + x
        x
    })
    assert(sum == 6, "map with side effect")

    print("effect_row_asymmetric: ok")
}
