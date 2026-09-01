// Struct NamedConstructor patterns must test every named field by its
// declared name before binding. The deliberately reversed field order and
// nested struct/enum patterns make positional or unconditional lowering fail.

enum Marker {
    Code(Int),
    Empty,
}

struct Inner {
    left: Int,
    marker: Marker,
    label: Str,
    right: Int,
}

struct Envelope {
    first: Int,
    inner: Inner,
    last: Int,
}

struct ScopePoint {
    x: Int,
    y: Int,
}

enum ScopeError {
    ScopePair(Int, Int),
    ScopeOther,
}

fn describe(value: Envelope) -> Str {
    match value {
        Envelope {
            last: 90,
            inner: Inner {
                right: 30,
                label: "hot",
                marker: Code(0),
                left: inner_left,
            },
            first: outer_first,
        } => "special ${outer_first}/${inner_left}",
        Envelope {
            inner: Inner {
                label,
                right,
                left,
                marker: Code(code),
            },
            last,
            first,
        } => "code ${first}/${left}/${code}/${label}/${right}/${last}",
        Envelope {
            last,
            first,
            inner: Inner {
                right,
                label,
                marker: Empty,
                left,
            },
        } => "empty ${first}/${left}/${label}/${right}/${last}",
        _ => "fallback",
    }
}

fn describe_if_let(value: Envelope) {
    if let Envelope {
        last: 90,
        inner: Inner {
            right: 30,
            label: "hot",
            marker: Code(0),
            left: inner_left,
        },
        first: outer_first,
    } = value {
        print("iflet special ${outer_first}/${inner_left}")
    } else {
        print("iflet else")
    }
}

fn check_iflet_scope(value: ScopePoint, x: Int) {
    if let ScopePoint { y: 0, x } = value {
        print("iflet shadow then ${x}")
    } else {
        print("iflet shadow else ${x}")
    }
    print("iflet shadow after ${x}")
}

fn check_match_scope(value: ScopePoint, x: Int) {
    let result = match value {
        ScopePoint { y: 0, x } => "match shadow then ${x}",
        _ if x == 99 => "match shadow else ${x}",
        _ => "match shadow polluted ${x}",
    }
    print(result)
    print("match shadow after ${x}")
}

fn check_switch_scope(value: Marker, code: Int) {
    let result = match value {
        Code(code) => "switch shadow then ${code}",
        _ => "switch shadow else ${code}",
    }
    print(result)
    print("switch shadow after ${code}")
}

fn check_switch_binding_scope(value: Marker, whole: Int) {
    let _ = match value {
        Code(_) => 1,
        whole => 2,
    }
    print("switch binding after ${whole}")
}

fn fail_point(value: ScopePoint) -> Int {
    fail.raise(value)
}

fn check_catch_simple(value: ScopePoint, x: Int) {
    let result = fail_point(value) catch {
        ScopePoint { y, x } => x,
    }
    print("catch simple ${result}")
    print("catch simple after ${x}")
}

fn fail_scope(error: ScopeError) -> Int {
    fail.raise(error)
}

fn check_catch_chain(error: ScopeError, x: Int) {
    let _ = fail_scope(error) catch {
        ScopePair(0, x) => {
            print("catch chain then ${x}")
            1
        },
        _ if x == 99 => {
            print("catch chain outer ${x}")
            2
        },
        _ => {
            print("catch chain polluted ${x}")
            3
        },
    }
    print("catch chain after ${x}")
}

fn main() {
    print(describe(Envelope {
        last: 90,
        first: 10,
        inner: Inner { right: 30, label: "hot", left: 20, marker: Code(0) },
    }))
    print(describe(Envelope {
        first: 10,
        inner: Inner { marker: Code(5), left: 20, label: "hot", right: 30 },
        last: 90,
    }))
    print(describe(Envelope {
        inner: Inner { label: "hot", right: 30, marker: Code(0), left: 20 },
        last: 91,
        first: 10,
    }))
    print(describe(Envelope {
        first: 10,
        last: 90,
        inner: Inner { marker: Code(0), right: 30, left: 20, label: "cold" },
    }))
    print(describe(Envelope {
        inner: Inner { right: 31, left: 20, marker: Code(0), label: "hot" },
        first: 10,
        last: 90,
    }))
    print(describe(Envelope {
        inner: Inner { marker: Empty, label: "idle", right: 9, left: 8 },
        last: 11,
        first: 7,
    }))

    describe_if_let(Envelope {
        last: 90,
        first: 10,
        inner: Inner { right: 30, label: "hot", left: 20, marker: Code(0) },
    })
    describe_if_let(Envelope {
        first: 10,
        inner: Inner { marker: Code(5), left: 20, label: "hot", right: 30 },
        last: 90,
    })
    describe_if_let(Envelope {
        first: 10,
        last: 90,
        inner: Inner { marker: Code(0), right: 30, left: 20, label: "cold" },
    })
    describe_if_let(Envelope {
        inner: Inner { marker: Empty, label: "idle", right: 30, left: 20 },
        last: 90,
        first: 10,
    })

    check_iflet_scope(ScopePoint { x: 1, y: 0 }, 99)
    check_iflet_scope(ScopePoint { x: 2, y: 1 }, 99)
    check_match_scope(ScopePoint { x: 3, y: 0 }, 99)
    check_match_scope(ScopePoint { x: 4, y: 1 }, 99)
    check_switch_scope(Code(5), 99)
    check_switch_scope(Empty, 99)
    check_switch_binding_scope(Empty, 99)
    check_catch_simple(ScopePoint { x: 6, y: 7 }, 99)
    check_catch_chain(ScopePair(0, 8), 99)
    check_catch_chain(ScopePair(1, 9), 99)
}
