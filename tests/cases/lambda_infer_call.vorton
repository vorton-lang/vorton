fn apply(f: fn(Int) -> Int, x: Int) -> Int {
    f(x)
}

fn apply2(f: fn(Int, Int) -> Int, a: Int, b: Int) -> Int {
    f(a, b)
}

fn transform(items: List<Int>, f: fn(Int) -> Int) -> List<Int> {
    items.map(f)
}

fn main() {
    // Lambda param types inferred from function signature
    let result = apply(fn(x) { x + 1 }, 5)
    assert(result == 6, "infer lambda param in call")

    let sum = apply2(fn(a, b) { a + b }, 3, 4)
    assert(sum == 7, "infer multi-param lambda in call")

    // Lambda as second argument
    let doubled = transform([1, 2, 3], fn(x) { x * 2 })
    assert(doubled.len() == 3, "transform length")
    assert(doubled.get(0).unwrap_or(0) == 2, "transform first")

    print("lambda_infer_call: all tests passed")
}
