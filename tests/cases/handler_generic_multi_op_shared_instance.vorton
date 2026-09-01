effect Pair<T> {
    fn ping() -> Unit
    fn get() -> T
}

fn read_pair() -> Int with {Pair<Int>} {
    Pair.ping()
    Pair.get()
}

fn main() {
    let value = handle {
        read_pair()
    } with {
        Pair.get() => 42,
        Pair.ping() => {},
    }
    print("handler-generic-pair:${value}")
}
