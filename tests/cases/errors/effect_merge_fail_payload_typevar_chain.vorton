// expect-error: E0301
// The first merge binds the bare fail payload to Str. The next merge must use
// that accumulated substitution and reject fail<Int>; best-effort merging used
// to swallow this conflict and accept the function.

fn unknown_payload() -> Int with {fail} {
    1
}

fn raise_text() -> Int with {fail<Str>} {
    fail.raise("text")
}

fn raise_number() -> Int with {fail<Int>} {
    fail.raise(7)
}

fn chained() -> Int {
    unknown_payload()
    raise_text()
    raise_number()
}

fn main() {}
