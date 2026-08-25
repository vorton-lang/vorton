// B-100 P1.3: adversarial — print ordering around fail.raise.
// Verifies that statements before fail.raise execute and print,
// while statements after fail.raise do NOT execute. Critical for
// longjmp (LLVM) semantics.

enum E { Boom }

fn fail_mid() -> Int with {console, fail<E>} {
    print("before-fail")
    fail.raise(E::Boom)
    // everything below should be unreachable
    print("after-fail")
    42
}

fn fail_in_branch(flag: Bool) -> Str with {console, fail<E>} {
    print("enter")
    if flag {
        print("branch-true-before")
        fail.raise(E::Boom)
        print("branch-true-after")
    }
    print("after-if")
    "ok"
}

fn multi_print_fail() -> Int with {console, fail<E>} {
    print("step-1")
    print("step-2")
    print("step-3")
    fail.raise(E::Boom)
    print("step-4")
    print("step-5")
    0
}

fn main() {
    // Test 1: basic — before prints, after doesn't
    let r1 = fail_mid() catch { _ => -1 }
    print("T1: ${r1.to_str()}")

    // Test 2: fail in branch — "enter" and "branch-true-before" print
    let r2 = fail_in_branch(true) catch { _ => "caught" }
    print("T2: ${r2}")

    // Test 3: no fail path — all prints execute
    let r3 = fail_in_branch(false) catch { _ => "caught" }
    print("T3: ${r3}")

    // Test 4: multiple prints before fail, none after
    let r4 = multi_print_fail() catch { _ => -1 }
    print("T4: ${r4.to_str()}")

    // Test 5: print in catch arm itself
    let r5 = fail_mid() catch {
        _ => {
            print("catch-arm-print")
            99
        }
    }
    print("T5: ${r5.to_str()}")

    print("adversarial_effect_fail_ordering: done")
}
