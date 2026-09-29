// B-100 P1.1 parity: SCC mutual recursion — mutually recursive functions
// with inferred return types, forward references.

fn is_even(n: Int) -> Bool {
    if n == 0 { true } else { is_odd(n - 1) }
}

fn is_odd(n: Int) -> Bool {
    if n == 0 { false } else { is_even(n - 1) }
}

// Forward reference: callee declared after caller
fn caller_first() -> Int {
    callee_second()
}

fn callee_second() -> Int {
    42
}

// Mutual recursion with more complex logic
fn count_down_a(n: Int) -> Int {
    if n <= 0 { 0 }
    else { n + count_down_b(n - 1) }
}

fn count_down_b(n: Int) -> Int {
    if n <= 0 { 0 }
    else { n + count_down_a(n - 1) }
}

fn main() {
    // Mutual recursion: is_even / is_odd
    print("even4=${is_even(4)}")
    print("odd4=${is_odd(4)}")
    print("even3=${is_even(3)}")
    print("odd3=${is_odd(3)}")
    print("even0=${is_even(0)}")
    print("odd0=${is_odd(0)}")

    // Forward reference
    print("forward=${caller_first()}")

    // Mutual recursion with accumulation
    print("count5=${count_down_a(5)}")
    print("count3=${count_down_a(3)}")
}
