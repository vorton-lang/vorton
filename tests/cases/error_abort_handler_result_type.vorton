// Audit #251 negative: an abort arm result must match the handled body/result.

fn raise_text() -> Int with {fail<Str>} {
    fail.raise("boom")
}

fn mismatch() -> Int {
    handle {
        raise_text()
    } with {
        fail.raise(message) => "wrong type",
    }
}

fn main() {}
