// Audit #251 negative: an abort arm runs outside the current handler, so its
// io effect must remain visible to the enclosing function signature.

fn raise_text() -> Int with {fail<Str>} {
    fail.raise("boom")
}

fn pure_abort_arm_io() -> Int with {} {
    handle {
        raise_text()
    } with {
        fail.raise(message) => {
            print(message)
            0 - 1
        },
    }
}

fn main() {}
