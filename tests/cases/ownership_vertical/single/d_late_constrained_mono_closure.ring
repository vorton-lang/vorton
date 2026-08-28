effect GenericProbe<T> {
    fn read() -> T
}

fn main() {
    // `let mut` remains monomorphic. The closure's result/effect instance is
    // closed by a later statement in this same owner, not at let-statement end.
    let mut callback = fn() {
        GenericProbe.read()
    }

    let value: Int = handle {
        callback()
    } with {
        GenericProbe.read() => 41,
    }

    assert(value == 41,
        "later owner constraints close a monomorphic closure token")
    print("D_LATE_CONSTRAINED_MONO_OK:${value}")
}
