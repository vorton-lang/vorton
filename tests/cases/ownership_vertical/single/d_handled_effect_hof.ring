effect Offset {
    fn adjust(value: Int) -> Int
}

effect Scale {
    fn adjust(value: Int) -> Int
}

fn apply_polymorphic(
    callback: fn(Int) -> Int,
    value: Int
) -> Int {
    callback(value)
}

fn measured(value: Int) -> Int with {Offset, Scale} {
    let offset = Offset.adjust(value)
    let scale = Scale.adjust(value)
    offset * 100 + scale
}

fn main() {
    let result = handle {
        apply_polymorphic(measured, 5)
    } with {
        Offset.adjust(value) => value + 7,
        Scale.adjust(value) => value * 7,
    }
    // Both effects deliberately share one operation signature. Swapping only
    // one evidence-vector boundary remains ABI-compatible but yields 3512.
    assert(result == 1235,
        "two exact handled effects preserve positional evidence agreement")
    print("D_HANDLED_HOF_OK:${result}")
}
