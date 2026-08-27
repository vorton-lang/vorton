effect Delta {
    fn apply(value: Int) -> Int
}

effect CallablePort {
    fn relay(callback: fn(Int) -> Int) -> fn(Int) -> Int
}

effect NestedPort<T> {
    fn relay(value: T) -> T
}

struct Box<T> {
    value: T
}

enum CallbackPayload {
    Positional(fn(Int) -> Int),
    Named { callback: fn(Int) -> Int }
}

fn delta_step(value: Int) -> Int with {Delta} {
    Delta.apply(value)
}

fn delta_next(value: Int) -> Int with {Delta} {
    Delta.apply(value) + 1
}

fn choose_box(
    use_actual: Bool,
    actual: Box<fn(Int) -> Int>,
    fallback: Box<fn(Int) -> Int>
) -> Box<fn(Int) -> Int> {
    if use_actual { actual } else { fallback }
}

fn call_box(boxed: Box<fn(Int) -> Int>, value: Int) -> Int {
    let callback = boxed.value
    callback(value)
}

fn call_payload(payload: CallbackPayload, value: Int) -> Int {
    match payload {
        CallbackPayload::Positional(callback) => callback(value),
        CallbackPayload::Named { callback } => callback(value)
    }
}

fn relay_operation(
    callback: fn(Int) -> Int
) -> (fn(Int) -> Int) with {CallablePort} {
    CallablePort.relay(callback)
}

fn raise_value<T>(value: T) -> T with {fail<T>} {
    fail.raise(value)
}

fn relay_nested<T>(value: T) -> T with {NestedPort<T>} {
    NestedPort.relay(value)
}

fn main() {
    let actual_box = choose_box(
        true,
        Box { value: delta_step },
        Box { value: delta_next }
    )
    let fallback_box = choose_box(
        false,
        Box { value: delta_step },
        Box { value: delta_next }
    )
    let actual_value = handle {
        call_box(actual_box, 1)
    } with {
        Delta.apply(value) => value + 10,
    }
    let fallback_value = handle {
        call_box(fallback_box, 1)
    } with {
        Delta.apply(value) => value + 10,
    }

    let positional_value = handle {
        call_payload(CallbackPayload::Positional(delta_step), 2)
    } with {
        Delta.apply(value) => value + 10,
    }
    let named_value = handle {
        call_payload(
            CallbackPayload::Named { callback: delta_step }, 3)
    } with {
        Delta.apply(value) => value + 10,
    }

    let operation_callback = handle {
        relay_operation(delta_step)
    } with {
        CallablePort.relay(callback) => callback,
    }
    let operation_value = handle {
        operation_callback(4)
    } with {
        Delta.apply(value) => value + 10,
    }

    let failed_callback = raise_value(delta_step) catch {
        callback => callback
    }
    let failed_value = handle {
        failed_callback(5)
    } with {
        Delta.apply(value) => value + 10,
    }

    let nested_callback = handle {
        relay_nested(delta_step)
    } with {
        NestedPort.relay(callback) => callback,
    }
    let nested_value = handle {
        nested_callback(6)
    } with {
        Delta.apply(value) => value + 10,
    }

    let score = actual_value + fallback_value + positional_value +
        named_value + operation_value + failed_value + nested_value
    assert(score == 93,
        "composite effect headers retain every nested callable tail")
    print("D_EFFECT_HEADER_COMPOSITES_OK:${score}")
}
