effect Pair {
    fn first() -> Int
    fn second() -> Int
}

fn main() {
    handle {
        Pair.first()
    } with {
        Pair.first() => 1,
    }
}
