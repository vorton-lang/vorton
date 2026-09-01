// Audit #258 tail-row rules under R1 dynamic handled evidence. Ordinary
// closures borrow exact evidence at each call and never capture creation-site
// handlers. A complete custom-effect table removes the whole exact effect from
// its body row; an unknown callback tail remains open and propagates outward.
// Tail-resumptive arms are internal runtime objects: they may retain explicit
// outer evidence so a same-effect re-perform escapes the current handler.

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
        Probe.bottom() => 0,
    }
}

// The internal inner arm retains the outer Relay evidence. Its re-perform
// therefore propagates to the enclosing handler instead of recursing into itself.
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

// The callback is invoked under an outer GenericProbe<Str> handler. The inner
// GenericProbe<Int> arm must not intercept that exact Str effect merely because
// the callback row is still open.
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

// A callback created and invoked inside the handled body borrows the current
// handler at the call. Its explicit OpenEcho<Str> label also connects both
// generic operation arms to the performed instance.
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
        Probe.bottom() => 0,
    }
}

fn bottom_handler() -> Int {
    handle {
        handle {
            Probe.bottom()
        } with {
            Probe.value(seed) => seed,
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
