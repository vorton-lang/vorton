effect NestedPort<T> {
    fn relay(value: T) -> T
}

fn relay_list<T>(value: List<T>) -> List<T> with {NestedPort<List<T>>} {
    NestedPort.relay(value)
}

fn main() {}
