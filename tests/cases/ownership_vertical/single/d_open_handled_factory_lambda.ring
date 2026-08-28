effect Probe<T> {
    fn read() -> T
}

fn make_probe<T>() -> fn() -> T {
    fn() -> T { Probe.read() }
}

fn main() {
    let callback = make_probe<Int>()
    let value = handle {
        callback()
    } with {
        Probe.read() => 1,
    }
    assert(value == 1, "closed call cannot legalize the factory's open token")
}
