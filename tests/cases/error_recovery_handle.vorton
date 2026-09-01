// Test: parser recovers from malformed effect handler and continues parsing
// The handler arm has a syntax error (missing '.op_name'),
// but subsequent declarations should still parse.

effect ask {
    fn get() -> Int
}

fn bad_handle() -> Int {
    handle {
        ask.get()
    } with {
        ask(x) => 42
    }
}

fn after_handle() -> Int {
    let y: Str = 42
    y
}
