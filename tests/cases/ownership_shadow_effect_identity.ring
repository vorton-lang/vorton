effect Signal {
    fn emit(value: Int) -> Int
}

fn main() {
    let result = handle {
        Signal.emit(5)
    } with {
        Signal.emit(value) => value + 1,
    }
    print(result)
}
