// B-100 P1.3: adversarial — return from functions that use catch.
// Tests that catch results feed into subsequent control flow (return,
// match, if) correctly.

enum E { Err { code: Int } }

fn may_fail(x: Int) -> Int with {fail<E>} {
    if x < 0 { fail.raise(E::Err { code: x }) }
    x * 2
}

fn process(x: Int) -> Str {
    // catch produces a sentinel value, then early-return based on it
    let r = may_fail(x) catch { _ => -999 }
    if r == -999 {
        print("returning early")
        return "error"
    }
    print("normal path: ${r.to_str()}")
    "ok:${r.to_str()}"
}

fn process_multi(a: Int, b: Int) -> Str {
    let r1 = may_fail(a) catch { _ => -999 }
    if r1 == -999 { return "fail-a" }
    let r2 = may_fail(b) catch { _ => -999 }
    if r2 == -999 { return "fail-b" }
    "both-ok:${r1.to_str()},${r2.to_str()}"
}

fn process_chain(xs: List<Int>) -> Str {
    // Multiple catches in sequence with early returns
    let mut sum = 0
    for x in xs {
        let r = may_fail(x) catch { _ => -999 }
        if r == -999 { return "failed-at-${x.to_str()}" }
        sum = sum + r
    }
    "sum:${sum.to_str()}"
}

fn main() {
    // Test 1: no error — normal path
    print("T1: ${process(5)}")

    // Test 2: error — early return
    print("T2: ${process(-3)}")

    // Test 3: first succeeds, second fails
    print("T3: ${process_multi(5, -2)}")

    // Test 4: first fails — second never reached
    print("T4: ${process_multi(-1, 5)}")

    // Test 5: both succeed
    print("T5: ${process_multi(3, 4)}")

    // Test 6: chain — fail at third element
    print("T6: ${process_chain([1, 2, -1, 4])}")

    // Test 7: chain — all succeed
    print("T7: ${process_chain([1, 2, 3])}")

    print("adversarial_effect_return_across_catch: done")
}
