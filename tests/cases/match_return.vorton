// Test: return from various positions — for loop, while loop, nested if

fn find_in_list(xs: List<Int>, target: Int) -> Int {
    let mut idx = 0
    for x in xs {
        if x == target { return idx }
        idx = idx + 1
    }
    -1
}

fn find_in_while(xs: List<Int>, target: Int) -> Int {
    let mut i = 0
    while i < xs.len() {
        let val = xs.get(i)
        match val {
            some(v) => if v == target { return i },
            none => {},
        }
        i = i + 1
    }
    -1
}

fn classify(x: Int) -> Str {
    if x > 100 { return "huge" }
    if x > 0 { return "positive" }
    if x < 0 { return "negative" }
    "zero"
}

fn main() {
    // return from for loop
    assert(find_in_list([10, 20, 30], 20) == 1, "return from for loop")
    assert(find_in_list([10, 20, 30], 99) == -1, "return default")

    // return from while loop with match
    assert(find_in_while([10, 20, 30], 30) == 2, "return from while")
    assert(find_in_while([10, 20, 30], 99) == -1, "while return default")

    // multi-return from if chain
    assert(classify(200) == "huge", "classify huge")
    assert(classify(5) == "positive", "classify positive")
    assert(classify(-3) == "negative", "classify negative")
    assert(classify(0) == "zero", "classify zero")

    print("match_return: all tests passed")
}
