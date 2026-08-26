// A function type without an explicit `with` row has an open effect tail. The
// same formal must instantiate independently for a pure and an effectful owner.
effect Meter {
    fn adjust(value: Int) -> Int
}

fn apply_polymorphic(
    callback: fn(Int) -> Int,
    value: Int
) -> Int {
    callback(value)
}

fn pure_value(value: Int) -> Int { value + 1 }

fn measured(value: Int) -> Int with {Meter} {
    Meter.adjust(value)
}

fn main() {
    let pure = apply_polymorphic(pure_value, 5)
    let effectful = handle {
        apply_polymorphic(measured, 5)
    } with {
        Meter.adjust(value) => value + 7,
    }
    assert(pure == 6 && effectful == 12,
        "one open formal instantiates pure and handled effect rows")
    print("D_GENERALIZED_TAIL_OK:${pure}/${effectful}")
}
