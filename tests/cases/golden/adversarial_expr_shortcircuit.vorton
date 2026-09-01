// B-100 P1.3 adversarial: short-circuit evaluation side effects.
//
// `a() && b()` / `a() || b()` — does b()'s side effect happen (or not happen)
// consistently? Since &&/|| are lowered to if-else before
// Perceus, the lowered form is `if a() { b() } else { false }` for &&, and
// `if a() { true } else { b() }` for ||.
//
// This test exercises:
//   * && where LHS is false => RHS not evaluated (side effect not printed)
//   * && where LHS is true => RHS evaluated
//   * || where LHS is true => RHS not evaluated
//   * || where LHS is false => RHS evaluated
//   * Chained: a() && b() && c() — c only runs if both a and b are true
//   * Chained: a() || b() || c() — c only runs if both a and b are false
//   * Mixed: (a() && b()) || c()
//   * Side effects in loop with short-circuit
//   * Short-circuit with heap-allocated return values (Str comparison)

fn check(label: Str, val: Bool) -> Bool {
    print("check:${label}")
    val
}

fn get_name(label: Str) -> Str {
    print("get:${label}")
    label
}

fn main() {
    // && with false LHS: RHS NOT evaluated
    print("--- and-false ---")
    let r1 = check("a1", false) && check("b1", true)
    print("r1=${r1}")

    // && with true LHS: RHS IS evaluated
    print("--- and-true ---")
    let r2 = check("a2", true) && check("b2", true)
    print("r2=${r2}")

    // || with true LHS: RHS NOT evaluated
    print("--- or-true ---")
    let r3 = check("a3", true) || check("b3", false)
    print("r3=${r3}")

    // || with false LHS: RHS IS evaluated
    print("--- or-false ---")
    let r4 = check("a4", false) || check("b4", true)
    print("r4=${r4}")

    // Triple chain &&: a && b && c
    print("--- triple-and ---")
    let r5 = check("x1", true) && check("x2", true) && check("x3", false)
    print("r5=${r5}")

    // Triple chain && short-circuit at first:
    print("--- triple-and-short ---")
    let r6 = check("y1", false) && check("y2", true) && check("y3", true)
    print("r6=${r6}")

    // Triple chain ||:
    print("--- triple-or ---")
    let r7 = check("z1", false) || check("z2", false) || check("z3", true)
    print("r7=${r7}")

    // Triple chain || short-circuit at first:
    print("--- triple-or-short ---")
    let r8 = check("w1", true) || check("w2", false) || check("w3", false)
    print("r8=${r8}")

    // Mixed: (a && b) || c
    print("--- mixed ---")
    let r9 = (check("m1", true) && check("m2", false)) || check("m3", true)
    print("r9=${r9}")

    // Short-circuit with string comparison (heap-allocated temps)
    print("--- str-compare ---")
    let name = "hello"
    let r10 = name.len() > 3 && get_name("cmp").len() > 2
    print("r10=${r10}")

    let r11 = name.len() < 2 && get_name("skip").len() > 0
    print("r11=${r11}")

    // Short-circuit in a loop — consistent per-iteration behavior
    print("--- loop ---")
    let mut count = 0
    for i in 0..5 {
        if i > 2 && i < 4 {
            count = count + 1
        }
    }
    print("loop_count=${count}")
}
