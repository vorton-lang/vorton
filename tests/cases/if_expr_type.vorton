// Test: if/else as expression in various positions

fn abs(x: Int) -> Int {
    if x < 0 { -x } else { x }
}

fn max(a: Int, b: Int) -> Int {
    if a > b { a } else { b }
}

fn main() {
    // if-else as expression in let
    let sign = if 5 > 0 { "positive" } else { "non-positive" }
    assert(sign == "positive", "if-else in let")

    // Nested if-else expression
    let grade = if 90 > 80 {
        if 90 > 90 { "A+" } else { "A" }
    } else {
        "B"
    }
    assert(grade == "A", "nested if-else expr")

    // if-else in function argument
    assert(abs(-5) == 5, "abs negative")
    assert(abs(3) == 3, "abs positive")

    // if-else with function calls
    assert(max(3, 7) == 7, "max 3 7")
    assert(max(10, 2) == 10, "max 10 2")

    // if-else in match arm body
    let x = 5
    let result = match x {
        5 => if true { "five" } else { "not five" },
        _ => "other",
    }
    assert(result == "five", "if-else in match arm")

    print("if_expr_type: all tests passed")
}
