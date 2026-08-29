fn apply_pure(
    callback: fn(Int) -> Int,
    value: Int
) -> Int {
    callback(value)
}

fn apply_console(
    callback: fn(Int) -> Int with {console},
    value: Int
) -> Int with {console} {
    callback(value)
}

fn call_system_extern(
    callback: fn(Int) -> Unit with {console},
    value: Int
) -> Unit with {console} {
    callback(value)
}

fn pure_value(value: Int) -> Int with {} { value + 1 }

fn console_value(value: Int) -> Int with {console} {
    print("console:${value}")
    value + 2
}

fn main() {
    let pure = apply_pure(pure_value, 3)
    let effectful = apply_console(console_value, 4)
    call_system_extern(print, 9)
    assert(pure == 4 && effectful == 6,
        "pure and console callables with the same signature stay distinct")
    print("D_SYSTEM_HOF_OK:${pure}/${effectful}")
}
