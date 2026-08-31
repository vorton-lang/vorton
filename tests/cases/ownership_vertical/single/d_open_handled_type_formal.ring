effect NestedPort<T> {
    fn relay(value: T) -> T
}

fn relay_open<T>(value: T) -> T with {NestedPort<T>} {
    NestedPort.relay(value)
}

fn main() {}
