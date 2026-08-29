// A function type without an explicit `with` row has an open effect tail. The
// same formal must instantiate independently for a pure and an effectful owner.
effect Meter {
    fn adjust(value: Int) -> Int
}

effect Scale {
    fn adjust(value: Int) -> Int
}

effect FixedBase {
    fn adjust(value: Int) -> Int
}

fn apply_polymorphic(
    callback: fn(Int) -> Int,
    value: Int
) -> Int {
    callback(value)
}

// The body contributes one fixed handled effect while the callback contributes
// its independently-instantiated open formal.
fn apply_with_fixed(
    callback: fn(Int) -> Int,
    value: Int
) -> Int {
    let adjusted = FixedBase.adjust(value)
    callback(adjusted)
}

fn pure_value(value: Int) -> Int with {} { value + 1 }

fn measured(value: Int) -> Int with {Meter} {
    Meter.adjust(value)
}

fn measured_twice(value: Int) -> Int with {Meter, Scale} {
    let adjusted = Meter.adjust(value)
    Scale.adjust(adjusted)
}

fn main() {
    let pure = apply_polymorphic(pure_value, 5)
    let effectful = handle {
        apply_polymorphic(measured, 5)
    } with {
        Meter.adjust(value) => value + 7,
    }
    let two_effects = handle {
        apply_polymorphic(measured_twice, 5)
    } with {
        Meter.adjust(value) => value + 7,
        Scale.adjust(value) => value * 2,
    }
    let fixed_and_formal = handle {
        apply_with_fixed(measured, 5)
    } with {
        FixedBase.adjust(value) => value * 2,
        Meter.adjust(value) => value + 7,
    }
    assert(pure == 6 && effectful == 12 && two_effects == 24 &&
        fixed_and_formal == 17,
        "one open formal instantiates pure, one-effect, two-effect, and fixed-plus-formal rows")
    print("D_GENERALIZED_TAIL_OK:${pure}/${effectful}/${two_effects}/${fixed_and_formal}")
}
