// Test: tuple patterns in match — with wildcards and nested

fn classify(pair: (Int, Int)) -> Str {
    match pair {
        (0, 0) => "origin",
        (0, _) => "y-axis",
        (_, 0) => "x-axis",
        (x, y) if x == y => "diagonal",
        _ => "other",
    }
}

fn first_or_second(t: (Int, Str)) -> Str {
    let (n, s) = t
    if n > 0 { "${n}" } else { s }
}

fn main() {
    assert(classify((0, 0)) == "origin", "origin")
    assert(classify((0, 5)) == "y-axis", "y-axis")
    assert(classify((3, 0)) == "x-axis", "x-axis")
    assert(classify((4, 4)) == "diagonal", "diagonal")
    assert(classify((1, 2)) == "other", "other")

    assert(first_or_second((5, "hello")) == "5", "first positive")
    assert(first_or_second((-1, "fallback")) == "fallback", "second on negative")

    // Triple tuple destructure
    let (a, b, c) = (1, 2, 3)
    assert(a == 1, "triple a")
    assert(b == 2, "triple b")
    assert(c == 3, "triple c")

    print("match_tuple_pattern: all tests passed")
}
