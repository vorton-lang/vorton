// B-100 P1.3 R2 adversarial combo: generic function + fail effect.
//
// A generic function that carries both a trait dict (T: Eq) and effect evidence
// (fail<Str>). The LLVM codegen must thread BOTH the dict AND the evidence
// correctly — if the ordering or count of implicit params is wrong, the dict
// and evidence get swapped and dispatch crashes or raises incorrectly.
//
// Exercises:
//   * Generic fn with fail effect — dict + evidence coexist
//   * Generic fn with fail effect calling another generic fn
//   * catch around a call to a generic+effect fn
//   * Effectful generic fn used with different concrete types

fn find_or_fail<T: Eq>(xs: List<T>, target: T) -> T with {fail<Str>} {
    for x in xs {
        if x == target { return x }
    }
    fail.raise("not found")
}

fn contains<T: Eq>(xs: List<T>, target: T) -> Bool {
    for x in xs {
        if x == target { return true }
    }
    false
}

fn find_first_matching<T: Eq>(xs: List<T>, candidates: List<T>) -> T with {fail<Str>} {
    for c in candidates {
        if contains(xs, c) { return c }
    }
    fail.raise("none matched")
}

fn safe_find<T: Eq>(xs: List<T>, target: T, default: T) -> T {
    find_or_fail(xs, target) catch { _ => default }
}

fn main() {
    // Test 1: generic + effect — success path (Int)
    let r1 = find_or_fail([1, 2, 3], 2) catch { e => -1 }
    print("T1: ${r1}")

    // Test 2: generic + effect — failure path (Int)
    let r2 = find_or_fail([1, 2, 3], 99) catch { e => -1 }
    print("T2: ${r2}")

    // Test 3: generic + effect — success path (Str)
    let r3 = find_or_fail(["a", "b", "c"], "b") catch { e => "none" }
    print("T3: ${r3}")

    // Test 4: generic + effect — failure path (Str)
    let r4 = find_or_fail(["a", "b", "c"], "z") catch { e => "none" }
    print("T4: ${r4}")

    // Test 5: chained generic+effect — find_first_matching
    let r5 = find_first_matching([10, 20, 30], [5, 20, 30]) catch { _ => -1 }
    print("T5: ${r5}")

    // Test 6: chained generic+effect — all fail
    let r6 = find_first_matching([10, 20, 30], [1, 2, 3]) catch { _ => -1 }
    print("T6: ${r6}")

    // Test 7: safe_find wraps catch — Int
    let r7 = safe_find([1, 2, 3], 3, 0)
    print("T7: ${r7}")

    // Test 8: safe_find wraps catch — Str miss
    let r8 = safe_find(["x", "y"], "z", "default")
    print("T8: ${r8}")

    print("adversarial_combo_generic_effect: done")
}
