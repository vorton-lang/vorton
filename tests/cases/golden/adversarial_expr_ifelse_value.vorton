// B-100 P1.3 adversarial: if-else as value expression.
// `let x = if cond { a() } else { b() }` — only one branch executes,
// so only that branch's temporaries should exist. The other branch's
// temporaries must not be allocated or dropped.

fn make_label(tag: Str) -> Str {
    print("make:${tag}")
    "label-${tag}"
}

fn compute(x: Int) -> Int {
    print("compute:${x}")
    x * x
}

fn main() {
    // Basic if-else as value — string results
    let r1 = if true { "yes" } else { "no" }
    print("r1=${r1}")

    let r2 = if false { "yes" } else { "no" }
    print("r2=${r2}")

    // If-else with side effects — only taken branch executes
    print("--- side-effects ---")
    let r3 = if true { make_label("taken") } else { make_label("skipped") }
    print("r3=${r3}")

    print("--- side-effects-2 ---")
    let r4 = if false { make_label("skipped2") } else { make_label("taken2") }
    print("r4=${r4}")

    // If-else with arithmetic — both branches produce Int
    let r5 = if 3 > 2 { 100 + 1 } else { 200 + 2 }
    print("r5=${r5}")

    // Nested if-else as value
    let val = 15
    let category = if val > 20 {
        "big"
    } else {
        if val > 10 {
            "medium"
        } else {
            "small"
        }
    }
    print("cat=${category}")

    // If-else with function calls in branches
    print("--- compute ---")
    let r6 = if true { compute(5) } else { compute(99) }
    print("r6=${r6}")

    // If-else in a loop — per-iteration conditional
    let mut results: List<Str> = []
    for i in 0..5 {
        let label = if i % 2 == 0 { "even" } else { "odd" }
        results.push(label)
    }
    print("loop=${results.join(",")}")

    // If-else producing list (heap-allocated conditional result)
    let xs = if true { [1, 2, 3] } else { [4, 5] }
    print("list_len=${xs.len()}")

    let ys = if false { [1, 2, 3] } else { [4, 5] }
    print("list_len2=${ys.len()}")

    // Chain of if-else values
    let a = if true { 1 } else { 0 }
    let b = if false { 1 } else { 0 }
    let c = if a > 0 { "pos" } else { "zero" }
    print("chain=${a},${b},${c}")

    // If-else with string interpolation in branches
    let name = "world"
    let greeting = if name.len() > 3 {
        "hello ${name}!"
    } else {
        "hi ${name}"
    }
    print("greeting=${greeting}")
}
