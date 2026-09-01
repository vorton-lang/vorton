// B-100 P1.3 R3 regression: closure as argument to HOF with effect evidence.
//
// Round 2 fixed closure evidence capture for Call nodes. This test focuses
// on closures that carry effects being used directly (not through non-effectful
// HOFs, which erase effect evidence by design). Tests closures capturing
// variables + calling effectful functions, and list.map/filter with effects.
//
// Exercises:
//   * Closure with fail effect called directly
//   * Closure with fail effect in list.map (implicit HOF)
//   * Multiple closures with different effects in sequence
//   * Closure capturing local var + calling effectful fn

fn validate(x: Int) -> Str with {fail<Str>} {
    if x == 0 { fail.raise("zero") }
    if x < 0 { fail.raise("neg") }
    "valid(${x})"
}

fn first_valid(xs: List<Int>) -> Str with {fail<Str>} {
    for x in xs {
        if x > 0 { return validate(x) }
    }
    fail.raise("none valid")
}

fn main() {
    // Test 1: closure calling effectful fn directly — success
    let f = fn(x: Int) -> Str { validate(x) }
    let r1 = f(42) catch { e => "err: ${e}" }
    print("T1: ${r1}")

    // Test 2: closure calling effectful fn — failure
    let r2 = f(0) catch { e => "err: ${e}" }
    print("T2: ${r2}")

    // Test 3: closure calling effectful fn — negative
    let r3 = f(-5) catch { e => "err: ${e}" }
    print("T3: ${r3}")

    // Test 4: closure capturing local + calling effectful fn
    let threshold = 5
    let checker = fn(x: Int) -> Str {
        if x < threshold { validate(x) } else { "big(${x})" }
    }
    let r4 = checker(3) catch { e => "err: ${e}" }
    print("T4: ${r4}")
    let r4b = checker(10) catch { e => "err: ${e}" }
    print("T4b: ${r4b}")
    let r4c = checker(0) catch { e => "err: ${e}" }
    print("T4c: ${r4c}")

    // Test 5: effectful fn called from list.map via closure — all succeed
    let xs = [1, 2, 3]
    let r5 = xs.map(fn(x) { validate(x) }) catch { e => ["err"] }
    print("T5: ${r5.join(",")}")

    // Test 6: effectful fn in list.map — one fails (short-circuits)
    let mixed = [1, 0, 3]
    let r6 = mixed.map(fn(x) { validate(x) }) catch { _ => ["failed"] }
    print("T6: ${r6.join(",")}")

    // Test 7: first_valid — success
    let r7 = first_valid([0, -1, 5, 3]) catch { e => "err: ${e}" }
    print("T7: ${r7}")

    // Test 8: first_valid — all invalid
    let r8 = first_valid([0, -1, -2]) catch { e => "err: ${e}" }
    print("T8: ${r8}")

    // Test 9: sequential closures with different captures
    let a_tag = "A"
    let b_tag = "B"
    let fa = fn(x: Int) -> Str { "${a_tag}:${validate(x)}" }
    let fb = fn(x: Int) -> Str { "${b_tag}:${validate(x)}" }
    let r9a = fa(1) catch { e => "err" }
    let r9b = fb(2) catch { e => "err" }
    print("T9: ${r9a} ${r9b}")

    // Test 10: closure with effect after catch
    let safe = validate(99) catch { _ => "safe_fallback" }
    let post = fn(s: Str) -> Str { "post(${safe},${s})" }
    print("T10: ${post("end")}")

    print("adversarial_regress_closure_effect_hof: done")
}
