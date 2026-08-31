effect ReadValue {
    fn read(value: Int) -> Int
}

fn main() {
    handle { ReadValue.read(1) } with {
        ReadValue.read(value: Int = 1) => value,
    }
}
