// B-100 P1.3 R3 adversarial: mutual recursion — two functions calling each other,
// plus mutual recursion with accumulators and string building.
//
// Exercises:
//   * Simple mutual recursion (is_even / is_odd)
//   * Mutual recursion with accumulator parameter
//   * Mutual recursion building a string result
//   * Mutual recursion with different return types interleaved

fn is_even(n: Int) -> Bool {
    if n == 0 { true } else { is_odd(n - 1) }
}

fn is_odd(n: Int) -> Bool {
    if n == 0 { false } else { is_even(n - 1) }
}

// Mutual recursion with accumulator: f counts down by 2, g counts down by 1
fn count_a(n: Int, acc: Int) -> Int {
    if n <= 0 { acc } else { count_b(n - 1, acc + n) }
}

fn count_b(n: Int, acc: Int) -> Int {
    if n <= 0 { acc } else { count_a(n - 2, acc + n) }
}

// Mutual recursion building strings — fizzbuzz-like
fn classify(n: Int) -> Str {
    if n <= 0 {
        ""
    } else {
        let tag = if n % 3 == 0 { "fizz" } else { label(n) }
        let rest = classify(n - 1)
        if rest == "" { tag } else { "${rest},${tag}" }
    }
}

fn label(n: Int) -> Str {
    if n % 5 == 0 { "buzz" } else { n.to_str() }
}

fn main() {
    // is_even / is_odd mutual recursion
    print("even0=${is_even(0)}")
    print("even1=${is_even(1)}")
    print("even4=${is_even(4)}")
    print("even7=${is_even(7)}")
    print("odd0=${is_odd(0)}")
    print("odd3=${is_odd(3)}")
    print("odd6=${is_odd(6)}")

    // accumulator mutual recursion
    print("count5=${count_a(5, 0)}")
    print("count10=${count_a(10, 0)}")
    print("count0=${count_a(0, 0)}")

    // string-building mutual recursion
    print("classify6=${classify(6)}")
}
