// Audit #251 negative: the abort handler parameter must have the concrete
// error type raised by the handled body.

fn raise_number() -> Int with {fail<Int>} {
    fail.raise(7)
}

fn mismatched_payload() -> Int {
    handle {
        raise_number()
    } with {
        // The arm result is Int, so only the payload contract can reject this.
        fail.raise(message: Str) => message.len(),
    }
}

fn main() {}
