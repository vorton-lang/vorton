// The inferred fail payload inside an unannotated callback parameter remains
// monomorphic: the first call fixes it to Int and the second cannot use Str.

fn recover_any(callback) -> Int {
    handle {
        callback()
    } with {
        fail.raise(unused) => 0,
    }
}

fn raise_number() -> Int with {fail<Int>} {
    fail.raise(7)
}

fn raise_text() -> Int with {fail<Str>} {
    fail.raise("text")
}

fn main() {
    recover_any(fn() -> Int { raise_number() })
    recover_any(fn() -> Int { raise_text() })
}
