effect BoxActualEffect {
    fn resolve(value: Int) -> Int
}

effect BoxFallbackEffect {
    fn resolve(value: Int) -> Int
}

effect PositionalEffect {
    fn resolve(value: Int) -> Int
}

effect NamedEffect {
    fn resolve(value: Int) -> Int
}

effect OperationParamEffect {
    fn resolve(value: Int) -> Int
}

effect OperationResultEffect {
    fn resolve(value: Int) -> Int
}

effect FailedCallbackEffect {
    fn resolve(value: Int) -> Int
}

effect CustomNestedEffect {
    fn resolve(value: Int) -> Int
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

fn box_actual_step(
    value: Int
) -> Int with {BoxActualEffect, BoxFallbackEffect} {
    BoxActualEffect.resolve(value)
}

fn box_fallback_step(
    value: Int
) -> Int with {BoxActualEffect, BoxFallbackEffect} {
    BoxFallbackEffect.resolve(value)
}

fn positional_step(value: Int) -> Int with {PositionalEffect} {
    PositionalEffect.resolve(value)
}

fn named_step(value: Int) -> Int with {NamedEffect} {
    NamedEffect.resolve(value)
}

fn operation_param_step(value: Int) -> Int with {OperationParamEffect} {
    OperationParamEffect.resolve(value)
}

fn operation_result_step(value: Int) -> Int with {OperationResultEffect} {
    OperationResultEffect.resolve(value)
}

fn failed_step(value: Int) -> Int with {FailedCallbackEffect} {
    FailedCallbackEffect.resolve(value)
}

fn custom_nested_step(value: Int) -> Int with {CustomNestedEffect} {
    CustomNestedEffect.resolve(value)
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

fn call_positional(payload: CallbackPayload, value: Int) -> Int {
    match payload {
        CallbackPayload::Positional(callback) => callback(value),
        CallbackPayload::Named { .. } => -1
    }
}

fn call_named(payload: CallbackPayload, value: Int) -> Int {
    match payload {
        CallbackPayload::Positional(_) => -1,
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

fn relay_nested(
    value: fn(Int) -> Int with {CustomNestedEffect}
) -> (fn(Int) -> Int with {CustomNestedEffect}) with {
    NestedPort<fn(Int) -> Int with {CustomNestedEffect}>
} {
    NestedPort.relay(value)
}

fn main() {
    let actual_box = choose_box(
        true,
        Box { value: box_actual_step },
        Box { value: box_fallback_step }
    )
    let fallback_box = choose_box(
        false,
        Box { value: box_actual_step },
        Box { value: box_fallback_step }
    )
    let box_actual = handle {
        call_box(actual_box, 1)
    } with {
        BoxActualEffect.resolve(value) => 101,
        BoxFallbackEffect.resolve(value) => 202,
    }
    let box_fallback = handle {
        call_box(fallback_box, 2)
    } with {
        BoxActualEffect.resolve(value) => 101,
        BoxFallbackEffect.resolve(value) => 202,
    }
    assert(box_actual == 101, "Box actual branch keeps its exact effect")
    assert(box_fallback == 202,
        "Box fallback branch keeps its exact effect")

    let positional = handle {
        call_positional(CallbackPayload::Positional(positional_step), 3)
    } with {
        PositionalEffect.resolve(value) => 303,
    }
    let named = handle {
        call_named(CallbackPayload::Named { callback: named_step }, 4)
    } with {
        NamedEffect.resolve(value) => 404,
    }
    assert(positional == 303,
        "positional enum field keeps its exact callable effect")
    assert(named == 404,
        "named enum field keeps its exact callable effect")

    let operation_param = handle {
        operation_param_step(5)
    } with {
        OperationParamEffect.resolve(value) => 505,
    }
    let operation_callback = handle {
        relay_operation(operation_param_step)
    } with {
        CallablePort.relay(callback) => {
            let observed_param = handle {
                callback(55)
            } with {
                OperationParamEffect.resolve(value) => 505,
            }
            assert(observed_param == 505,
                "effect operation handler receives the exact parameter callable")
            operation_result_step
        },
    }
    let operation_result = handle {
        operation_callback(6)
    } with {
        OperationResultEffect.resolve(value) => 606,
    }
    assert(operation_param == 505,
        "effect operation callable parameter keeps its exact effect")
    assert(operation_result == 606,
        "effect operation callable result keeps its exact effect")

    let failed_callback = raise_value(failed_step) catch {
        callback => callback
    }
    let failed = handle {
        failed_callback(7)
    } with {
        FailedCallbackEffect.resolve(value) => 707,
    }
    assert(failed == 707,
        "generic fail<T> keeps the nested callable actual effect")

    let custom_callback = handle {
        relay_nested(custom_nested_step)
    } with {
        NestedPort.relay(callback) => callback,
    }
    let custom = handle {
        custom_callback(8)
    } with {
        CustomNestedEffect.resolve(value) => 808,
    }
    assert(custom == 808,
        "fully closed custom effect keeps its nested callable token")

    print("D_EFFECT_HEADER_COMPOSITES_OK:box=${box_actual}/${box_fallback};enum=${positional}/${named};op=${operation_param}/${operation_result};fail=${failed};custom=${custom}")
}
