effect NestedPort<T> {
    fn relay(value: T) -> T
}

fn relay_open_callback(
    callback: fn(Int) -> Int
) -> (fn(Int) -> Int) with {NestedPort<fn(Int) -> Int>} {
    NestedPort.relay(callback)
}

fn main() {}
