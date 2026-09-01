// Audit #266 regression: a bare fail annotation introduces a fresh payload
// variable. Merging it with fail<Str> must bind that variable and preserve the
// resulting substitution in the inferred row, so the catch binder is Str.

fn unknown_payload() -> Int with {fail} {
    1
}

fn raise_text() -> Int with {fail<Str>} {
    fail.raise("text")
}

fn merged(flag: Bool) -> Int {
    if flag {
        unknown_payload()
    } else {
        raise_text()
    }
}

fn main() {
    let value = merged(true) catch { message => message.len() }
    print(value.to_str())
}
