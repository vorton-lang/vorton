fn make_chain() -> fn() -> fn(Int) -> Option<Int> {
    fn() -> fn(Int) -> Option<Int> {
        fn(value: Int) -> Option<Int> { some(value) }
    }
}

fn main() {
    let level_one = make_chain()
    let level_two = level_one()
    match level_two(9) {
        some(value) => print(value),
        none => print(-1),
    }
}
