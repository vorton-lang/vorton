// An unannotated top-level parameter is monomorphic. Direct refinement from a
// registration TypeVar to a callback shape may be published, but its Str abort
// payload contract cannot be instantiated as Int.

fn recover(callback) -> Int {
    handle {
        callback()
    } with {
        fail.raise(message: Str) => message.len(),
    }
}

fn raise_number() -> Int with {fail<Int>} {
    fail.raise(7)
}

fn main() {
    recover(fn() -> Int { raise_number() })
}
