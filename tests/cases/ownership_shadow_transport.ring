fn apply_option(
    constructor: fn(Int) -> Option<Int>,
    value: Int
) -> Option<Int> {
    constructor(value)
}

fn choose(flag: Bool) -> Option<Int> {
    if flag { some(40) } else { none }
}

fn call_default(
    constructor: fn(Int) -> Option<Int> =
        fn(value: Int) -> Option<Int> { some(value) }
) -> Option<Int> {
    constructor(2)
}

fn main() {
    match apply_option(some, 40) {
        some(value) => print(value),
        none => print(-1),
    }
    match choose(false) {
        some(value) => print(value),
        none => print(-1),
    }
    match call_default() {
        some(value) => print(value),
        none => print(-1),
    }
    let defaulted = fn(value: Int) -> Option<Int> { some(value) }
    match defaulted(3) {
        some(value) => print(value),
        none => print(-1),
    }
}
