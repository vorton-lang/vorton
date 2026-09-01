// Test: recursive functions — mutual recursion, recursion with effects

fn factorial(n: Int) -> Int {
    if n <= 1 { 1 }
    else { n * factorial(n - 1) }
}

fn fib(n: Int) -> Int {
    if n <= 1 { n }
    else { fib(n - 1) + fib(n - 2) }
}

// Recursive with Option
fn find_first_positive(xs: List<Int>) -> Option<Int> {
    if xs.is_empty() { return none }
    let first = xs.get(0)
    match first {
        some(v) => {
            if v > 0 { some(v) }
            else { find_first_positive(xs.slice(1, xs.len())) }
        },
        none => none,
    }
}

fn main() {
    assert(factorial(5) == 120, "factorial 5")
    assert(factorial(1) == 1, "factorial 1")
    assert(factorial(0) == 1, "factorial 0")

    assert(fib(0) == 0, "fib 0")
    assert(fib(1) == 1, "fib 1")
    assert(fib(6) == 8, "fib 6")

    let xs = [-3, -1, 0, 5, 2]
    let result = find_first_positive(xs)
    assert(result.unwrap_or(0) == 5, "find first positive")

    let all_neg = [-1, -2, -3]
    let none_result = find_first_positive(all_neg)
    assert(none_result.is_none(), "no positive in all negative")

    print("recursive_fn: all tests passed")
}
