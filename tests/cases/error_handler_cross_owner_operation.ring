effect Left {
    fn value() -> Int
}

effect Right {
    fn other() -> Int
}

fn main() {
    handle {
        Left.value()
    } with {
        Left.value() => 1,
        Left.other() => 2,
    }
}
