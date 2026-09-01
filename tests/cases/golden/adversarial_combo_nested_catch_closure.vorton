// B-100 P1.3 R2 adversarial combo: nested catch + closure interaction.
//
// Closures created between nested catch scopes may capture variables
// whose lifetimes are affected by the catch unwinding. This tests that
// the LLVM backend correctly handles RC for closures across catch scopes
// and that evidence is properly threaded when closures are used inside
// and across catch boundaries.
//
// Exercises:
//   * Closure created before catch, used inside catch
//   * Closure created inside catch, used after catch
//   * Nested catch with closure capturing outer catch result
//   * Multiple closures alive across catch boundaries

fn maybe_fail(x: Int) -> Str with {fail<Str>} {
    if x < 0 { fail.raise("negative") }
    "ok(${x})"
}

fn apply(f: fn(Str) -> Str, x: Str) -> Str {
    f(x)
}

fn main() {
    // Test 1: closure created BEFORE catch, used inside catch arm
    let prefix = "pre"
    let fmt = fn(s: Str) -> Str { "${prefix}:${s}" }
    let r1 = maybe_fail(5) catch { e => fmt(e) }
    print("T1: ${r1}")

    // Test 2: same closure, failure path
    let r2 = maybe_fail(-1) catch { e => fmt(e) }
    print("T2: ${r2}")

    // Test 3: closure created after catch result, used later
    let r3 = maybe_fail(3) catch { _ => "caught" }
    let post_fmt = fn(s: Str) -> Str { "after(${s})" }
    print("T3: ${post_fmt(r3)}")

    // Test 4: nested catch — inner catch result used in outer scope closure
    let outer_tag = "outer"
    let inner = maybe_fail(10) catch { _ => "inner_caught" }
    let outer = maybe_fail(-5) catch { e => "${outer_tag}:${inner}:${e}" }
    print("T4: ${outer}")

    // Test 5: closure across nested catches — both succeed
    let tag = "ctx"
    let a = maybe_fail(1) catch { _ => "a_err" }
    let b = maybe_fail(2) catch { _ => "b_err" }
    let combine = fn(x: Str) -> Str { "${tag}(${a},${b},${x})" }
    print("T5: ${combine("end")}")

    // Test 6: closure across nested catches — first fails
    let c = maybe_fail(-1) catch { e => e }
    let d = maybe_fail(7) catch { _ => "d_err" }
    let combine2 = fn(x: Str) -> Str { "${c}+${d}+${x}" }
    print("T6: ${combine2("tail")}")

    // Test 7: HOF with closure carrying caught result
    let caught_val = maybe_fail(-3) catch { _ => "fallback" }
    let wrapper = fn(s: Str) -> Str { "${caught_val}/${s}" }
    let r7 = apply(wrapper, "input")
    print("T7: ${r7}")

    // Test 8: deeply nested catch
    let level1 = maybe_fail(1) catch { _ => "L1" }
    let level2 = maybe_fail(-1) catch { _ => level1 }
    let level3 = maybe_fail(-1) catch { _ => level2 }
    print("T8: ${level3}")

    print("adversarial_combo_nested_catch_closure: done")
}
