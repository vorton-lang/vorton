// expect error: E0503
// The same extern value remains statically bounded: selecting T=Float must be
// rejected even though a successful extern closure captures no runtime dict.

extern fn print<T: Hash>(value: T) -> Unit with {console}

fn call_float(
    f: fn(Float) -> Unit with {console},
    value: Float
) -> Unit with {console} {
    f(value)
}

fn main() {
    call_float(print, 1.5)
}
