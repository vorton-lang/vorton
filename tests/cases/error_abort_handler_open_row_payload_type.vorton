// Audit #251 negative: recover's callback starts with an open effect row. The
// abort arm refines its scheme to fail<Str> plus a residual row, so a fail<Int>
// callback must be rejected at this call site rather than reaching codegen.

fn recover(callback: fn() -> Int) -> Int {
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
    let value = recover(fn() -> Int { raise_number() })
    print(value)
}
