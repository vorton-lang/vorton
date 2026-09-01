effect TopStep {
    fn apply(value: Int) -> Int
}

fn top_left(
    callback: fn(Int) -> Int,
    value: Int,
    remaining: Int
) -> Int {
    if remaining == 0 {
        value
    } else {
        top_right(callback, callback(value), remaining - 1)
    }
}

fn top_right(
    callback: fn(Int) -> Int,
    value: Int,
    remaining: Int
) -> Int {
    if remaining == 0 {
        value
    } else {
        top_left(callback, callback(value), remaining - 1)
    }
}

fn increment(value: Int) -> Int with {} { value + 1 }

fn top_step(value: Int) -> Int with {TopStep} {
    TopStep.apply(value)
}

fn main() {
    let pure = top_left(increment, 1, 3)
    let handled = handle {
        top_right(top_step, 2, 2)
    } with {
        TopStep.apply(value) => value + 4,
    }

    assert(pure == 4 && handled == 10,
        "top-level mutual recursion shares its callback effect constraints")
    print("D_RECURSIVE_TOP_SCC_OK:${pure}/${handled}")
}
