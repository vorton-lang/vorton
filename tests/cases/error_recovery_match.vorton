// Test: parser recovers from malformed match arm and continues parsing
// The first match arm has a syntax error (missing '=>'),
// but the second arm and subsequent function should still parse.

fn bad_match(x: Int) -> Int {
    match x {
        1 "missing arrow",
        2 => 20
    }
}

fn after_match() -> Int {
    let y: Str = 42
    y
}
