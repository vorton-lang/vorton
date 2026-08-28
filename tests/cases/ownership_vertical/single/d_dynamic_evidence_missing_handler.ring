effect MissingDynamic {
    fn apply(value: Int) -> Int
}

fn missing_step(value: Int) -> Int with {MissingDynamic} {
    MissingDynamic.apply(value)
}

fn make_missing(
    callback: fn(Int) -> Int
) -> fn(Int) -> Int {
    fn(value: Int) { callback(value) }
}

fn main() {
    let escaped = handle {
        make_missing(missing_step)
    } with {
        MissingDynamic.apply(value) => value + 100,
    }
    let unused = escaped(1)
}
