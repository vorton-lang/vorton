enum DuplicateChoice {
    Pair(Int, Int),
    Other(Int, Int),
}

fn read(choice: DuplicateChoice) -> Int {
    match choice {
        Pair(value, value) | Other(value, _) => 0,
    }
}

fn main() {
    print(read(Pair(1, 2)))
}
