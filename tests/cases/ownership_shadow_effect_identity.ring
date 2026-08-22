effect Signal {
    fn emit(value: Int) -> Option<Int>
}

fn main() {
    let result = handle {
        Signal.emit(5)
    } with {
        Signal.emit(value) => some(value + 1),
    }
    match result {
        some(value) => print(value),
        none => print(-1),
    }
}
