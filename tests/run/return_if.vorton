// Regression C10: return inside if block must exit outer function
fn abs(x: Int) -> Int {
    if x < 0 { return -x }
    x
}

fn classify(n: Int) -> Str {
    if n > 0 { return "positive" }
    if n < 0 { return "negative" }
    "zero"
}

fn main() {
    print(abs(-5))
    print(abs(3))
    print(classify(10))
    print(classify(-7))
    print(classify(0))
}
