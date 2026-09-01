// Test: matching on literal values (Int, Str, Bool)

fn classify_num(n: Int) -> Str {
    match n {
        0 => "zero",
        1 => "one",
        2 => "two",
        _ => "other",
    }
}

fn classify_str(s: Str) -> Str {
    match s {
        "hello" => "greeting",
        "bye" => "farewell",
        _ => "unknown",
    }
}

fn classify_bool(b: Bool) -> Str {
    match b {
        true => "yes",
        false => "no",
    }
}

fn main() {
    assert(classify_num(0) == "zero", "num zero")
    assert(classify_num(1) == "one", "num one")
    assert(classify_num(42) == "other", "num other")

    assert(classify_str("hello") == "greeting", "str hello")
    assert(classify_str("bye") == "farewell", "str bye")
    assert(classify_str("x") == "unknown", "str unknown")

    assert(classify_bool(true) == "yes", "bool true")
    assert(classify_bool(false) == "no", "bool false")

    print("match_literal: all tests passed")
}
