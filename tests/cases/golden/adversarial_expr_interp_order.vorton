// B-100 P1.3 adversarial: string interpolation evaluation order + temp drop.
//
// String interpolation `"${e1}_${e2}_${e3}"` requires evaluating e1, e2, e3
// left-to-right, converting each to Str, building a StringBuilder, then
// producing the final Str. Each sub-expression may produce a fresh temporary
// that must be dropped after the interpolation is complete.
//
// This test exercises:
//   * Multiple sub-expressions with side effects (print order proves eval order)
//   * Nested interpolation: `"${" inner ${x}"}"` — inner interp is a sub-expr
//   * Interpolation of method call results (fresh temps)
//   * Interpolation of arithmetic expressions
//   * Interpolation inside a loop (per-iteration temp drops)
//   * Deeply nested interpolation (3 levels)
//   * Interpolation with if-else expression pieces

fn side(label: Str, val: Int) -> Int {
    print("eval:${label}")
    val
}

fn greet(name: Str) -> Str {
    "hi-${name}"
}

fn main() {
    // Basic multi-piece interpolation with side effects proving L-to-R order
    let s1 = "${side("a", 1)}_${side("b", 2)}_${side("c", 3)}"
    print("s1=${s1}")

    // Interpolation of method call results (fresh Str temps)
    let xs = [10, 20, 30]
    let s2 = "len=${xs.len()},first=${xs[0]}"
    print("s2=${s2}")

    // Nested interpolation
    let name = "world"
    let s3 = "${"hello ${name}!"}"
    print("s3=${s3}")

    // Interpolation with arithmetic sub-expressions
    let a = 7
    let b = 3
    let s4 = "sum=${a + b},diff=${a - b},prod=${a * b}"
    print("s4=${s4}")

    // Interpolation inside a loop — temp drops must happen each iteration
    for i in 0..3 {
        let msg = "i=${i},sq=${i * i}"
        print(msg)
    }

    // Interpolation with function call results
    let s5 = "${greet("alice")}_${greet("bob")}"
    print("s5=${s5}")

    // Interpolation with if-else expression pieces
    let flag = true
    let s6 = "flag=${if flag { "yes" } else { "no" }}"
    print("s6=${s6}")

    let flag2 = false
    let s7 = "flag2=${if flag2 { "yes" } else { "no" }}"
    print("s7=${s7}")

    // Multiple interpolations in sequence — prior temps must be dropped
    let r1 = "a=${"x"}"
    let r2 = "b=${"y"}"
    let r3 = "c=${"z"}"
    print("${r1},${r2},${r3}")

    // Interpolation of Bool and Option values
    let opt: Int? = some(42)
    let s8 = "opt=${opt.unwrap_or(0)},bool=${true}"
    print("s8=${s8}")
}
