// Audit #251 negative: removing the handled body's fail row must not swallow a
// fail re-raised by the abort arm after the current handler is inactive.

fn raise_text() -> Int with {fail<Str>} {
    fail.raise("boom")
}

fn pure_abort_arm_reraise() -> Int with {} {
    handle {
        raise_text()
    } with {
        fail.raise(message) => fail.raise(message),
    }
}

fn main() {}
