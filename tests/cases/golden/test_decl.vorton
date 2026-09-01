// B-163 Phase 2 parity: HDecl::Test is emitted and executed in source order.
// Deliberately no fn main: the backend-generated entry point must run tests.

fn label(n: Int) -> Str {
    "test-${n}"
}

test "first declaration" {
    assert(1 + 1 == 2, "first assertion")
    print("${label(1)}:first")
}

test "second declaration" {
    print("${label(2)}:before-assert")
    assert(label(2) == "test-2", "second assertion")
    print("${label(2)}:after-assert")
}

test "third declaration" {
    assert(true, "third assertion")
    print("${label(3)}:last")
}
