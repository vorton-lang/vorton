// Audit #258, option C: closures capture custom-effect evidence lexically.
// A handler removes only an explicit matching label from its body row; an
// unknown callback tail remains open and propagates to the outer scope.
// Tail-resumptive arms implement their operation, so their result matches the
// operation return type and their own effects escape the handle.

effect Probe {
    fn value(seed: Int) -> Int
    fn bottom() -> Int
}

effect Relay {
    fn forward(value: Int) -> Int
}

effect GenericProbe<T> {
    fn value() -> T
}

effect OpenEcho<T> {
    fn first(value: T) -> T
    fn second(value: T) -> T
}

fn direct_io_handler() -> Int with {console} {
    handle {
        Probe.value(4)
    } with {
        Probe.value(seed) => {
            print("io-arm:${seed}")
            seed + 1
        },
    }
}

// The inner arm captures the outer Relay evidence. Its re-perform therefore
// propagates to the enclosing handler instead of recursing into itself.
// No annotation pins the inferred effect row: the outer call only receives the
// required evidence when the arm's Relay effect is merged back into this row.
fn relay_once(value: Int) -> Int {
    handle {
        Relay.forward(value)
    } with {
        Relay.forward(inner) => Relay.forward(inner + 1),
    }
}

fn generic_int() -> Int with {GenericProbe<Int>} {
    GenericProbe.value()
}

fn generic_handler() -> Int {
    handle {
        generic_int()
    } with {
        GenericProbe.value() => 9,
    }
}

// The callback is created under an outer GenericProbe<Str> handler. Its
// closure captures that outer evidence. This inner GenericProbe<Int> arm must
// not intercept the callback merely because the callback row is still open.
fn recover_external(callback: fn() -> Int) -> Int {
    handle {
        callback()
    } with {
        GenericProbe.value() => 12,
    }
}

fn text_length() -> Int with {GenericProbe<Str>} {
    let text: Str = GenericProbe.value()
    text.len()
}

// A callback created inside the handled body captures the current handler.
// Its explicit OpenEcho<Str> label also connects both generic operation arms
// to the performed instance.
fn local_callback_handler() -> Str {
    handle {
        let callback = fn() -> Str {
            let first = OpenEcho.first("local")
            OpenEcho.second(first)
        }
        callback()
    } with {
        OpenEcho.first(value) => "${value}-first",
        OpenEcho.second(value) => "${value}-second",
    }
}

fn closed_pure_handler() -> Int {
    handle {
        40
    } with {
        Probe.value(seed) => seed,
    }
}

fn bottom_handler() -> Int {
    handle {
        handle {
            Probe.bottom()
        } with {
            Probe.bottom() => fail.raise("tail-bottom"),
        }
    } with {
        fail.raise(message) => {
            assert(message == "tail-bottom", "Never arm reaches outer fail handler")
            77
        },
    }
}

fn main() {
    let direct_value = direct_io_handler()
    print("direct-value:${direct_value}")

    let relayed = handle {
        relay_once(2)
    } with {
        Relay.forward(value) => value * 10,
    }
    print("relay-value:${relayed}")

    let generic_value = generic_handler()
    print("generic-value:${generic_value}")

    let open_outer_value = handle {
        let callback = fn() -> Int { text_length() }
        recover_external(callback)
    } with {
        GenericProbe.value() => "outer",
    }
    print("open-outer-value:${open_outer_value}")

    let local_value = local_callback_handler()
    print("local-multi:${local_value}")

    let closed_value = closed_pure_handler()
    print("closed-value:${closed_value}")

    let bottom_value = bottom_handler()
    print("bottom-value:${bottom_value}")
}
