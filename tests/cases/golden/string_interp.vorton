// String interpolation in varied positions: nested interpolation, inside match
// arms (with guards), around expressions with method calls / collection access,
// and folding interpolated fragments while iterating.
//
// NOTE: effect-driven evaluation-order coverage of interpolation holes is NOT
// here because custom-effect handlers themselves diverge on LLVM (recorded under
// B-087 in docs/worker_feedback.md); ordering is only meaningful once that lands.

fn classify(n: Int) -> Str {
    match n {
        0 => "zero",
        x if x % 2 == 0 => "even:${x} (half ${x / 2})",
        x => "odd:${x} (sq ${x * x})"
    }
}

fn label(name: Str, vals: List<Int>) -> Str {
    let mut acc = "${name}["
    let mut first = true
    for v in vals {
        if first {
            acc = "${acc}${v}"
            first = false
        } else {
            acc = "${acc},${v}"
        }
    }
    "${acc}]"
}

fn main() {
    // basic + nested interpolation
    let x = 3
    let y = 4
    print("sum: ${x + y}")                          // sum: 7
    print("nested: ${"inner=${x * y}"}!")           // nested: inner=12!

    // interpolation inside match arm bodies (incl. guarded arms)
    print(classify(0))                              // zero
    print(classify(6))                              // even:6 (half 3)
    print(classify(5))                              // odd:5 (sq 25)

    // interpolation with method calls and collection access
    let xs = [10, 20, 30]
    print("len=${xs.len()} first=${xs.get(0).unwrap_or(-1)}")   // len=3 first=10

    // interpolation accumulated across a loop, with booleans/negatives
    print(label("nums", [1, 2, 3]))                 // nums[1,2,3]
    print(label("empty", []))                       // empty[]
    print("neg=${0 - 5} flag=${1 < 2}")             // neg=-5 flag=true
}
