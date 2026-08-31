effect Tick {
    fn value() -> Int
}

fn main() {
    handle {
        Tick.value()
    } with {
        Tick.value() => 1,
        Tick.ghost() => 2,
    }
}
