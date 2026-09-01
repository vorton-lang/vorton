// Test: parser recovers from malformed if condition and continues parsing
// The if condition has a syntax error (missing closing paren in call),
// but subsequent declarations should still parse.

fn bad_if() -> Int {
    if foo( {
        1
    } else {
        2
    }
}

fn after_if() -> Int {
    let y: Str = 42
    y
}
