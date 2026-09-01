// Negative test: multiple type errors across declarations
// With declaration-level recovery, checker should report ALL errors, not just the first

fn bad1() -> Str {
    42
}

fn bad2() -> Int {
    "hello"
}

fn good() -> Int {
    1 + 2
}
