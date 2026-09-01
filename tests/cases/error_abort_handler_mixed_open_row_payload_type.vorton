// Audit #251 negative: an explicit fail<Str> in the body does not make the
// callback's open row unconstrained. The abort handler requires every open
// contribution to contain the same fail<Str>, so fail<Int> is rejected.

fn recover(callback: fn() -> Int, direct: Bool) -> Int {
    handle {
        if direct {
            fail.raise("direct")
        }
        callback()
    } with {
        fail.raise(message: Str) => message.len(),
    }
}

fn raise_number() -> Int with {fail<Int>} {
    fail.raise(7)
}

fn main() {
    let value = recover(fn() -> Int { raise_number() }, false)
    print(value)
}
