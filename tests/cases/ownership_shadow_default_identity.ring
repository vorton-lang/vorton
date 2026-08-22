effect Signal {
    fn emit(value: Int) -> Option<Int>
}

fn make_callback() -> fn(Int) -> Option<Int> {
    fn(value: Int) -> Option<Int> { some(value) }
}

fn use_default(
    callback: fn(Int) -> Option<Int> =
        fn(value: Int) -> Option<Int> {
            let produced = make_callback()
            handle {
                Signal.emit(value)
            } with {
                Signal.emit(inner) => match produced(inner) {
                    some(result) => some(result),
                    none => none,
                },
            }
        }
) -> Option<Int> {
    callback(4)
}

fn print_result(value: Option<Int>) {
    match value {
        some(result) => print(result),
        none => print(-1),
    }
}

fn main() {
    print_result(use_default())
    print_result(use_default())
}
