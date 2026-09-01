// B-100 P1.1: function type with effect annotation — passing functions with
// effect annotations as arguments, calling them, and verifying that the
// evidence threading is correct.

fn apply_io(f: fn(Int) -> Str with {console}, x: Int) -> Str with {console} {
    f(x)
}

fn format_with_print(n: Int) -> Str with {console} {
    print("formatting ${n.to_str()}")
    "val=${n.to_str()}"
}

fn apply_pure(f: fn(Int) -> Int, x: Int) -> Int {
    f(x)
}

fn double(x: Int) -> Int with {} {
    x * 2
}

fn apply_fail(f: fn(Int) -> Int with {fail<Str>}, x: Int) -> Int with {fail<Str>} {
    f(x)
}

fn checked_div(x: Int) -> Int with {fail<Str>} {
    if x == 0 { fail.raise("zero") }
    100 / x
}

fn compose_io(f: fn(Str) -> Str with {console}, g: fn(Str) -> Str with {console}, x: Str) -> Str with {console} {
    g(f(x))
}

fn prepend_tag(s: Str) -> Str with {console} {
    print("prepend")
    "tag:${s}"
}

fn append_end(s: Str) -> Str with {console} {
    print("append")
    "${s}:end"
}

fn main() {
    // Test 1: fn type with io effect
    let r1 = apply_io(format_with_print, 42)
    print("T1: ${r1}")

    // Test 2: pure fn type (no effect)
    let r2 = apply_pure(double, 21)
    print("T2: ${r2.to_str()}")

    // Test 3: fn type with fail effect — success
    let r3 = apply_fail(checked_div, 5) catch { _ => -1 }
    print("T3: ${r3.to_str()}")

    // Test 4: fn type with fail effect — failure
    let r4 = apply_fail(checked_div, 0) catch { e => -1 }
    print("T4: ${r4.to_str()}")

    // Test 5: composition of effectful fn types
    let r5 = compose_io(prepend_tag, append_end, "hello")
    print("T5: ${r5}")

    print("fn_type_effect: done")
}
