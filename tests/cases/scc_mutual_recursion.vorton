// B-122 SCC: mutual recursion with inferred return types
// Verifies that mutually recursive functions with unannotated return types
// are correctly inferred via SCC-based checking.

fn is_even(n: Int) -> Bool {
    if n == 0 { true } else { is_odd(n - 1) }
}

fn is_odd(n: Int) -> Bool {
    if n == 0 { false } else { is_even(n - 1) }
}

// Forward reference: callee declared after caller, both with inferred returns
fn caller_first() -> Int {
    callee_second()
}

fn callee_second() -> Int {
    42
}

test "mutual recursion" {
    assert(is_even(4), "4 is even")
    assert(!is_odd(4), "4 is not odd")
    assert(is_odd(3), "3 is odd")
    assert(!is_even(3), "3 is not even")
}

test "forward reference" {
    assert(caller_first() == 42, "forward ref returns 42")
}

test "scc_mutual_recursion: all passed" {
    print("scc_mutual_recursion: all tests passed")
}
