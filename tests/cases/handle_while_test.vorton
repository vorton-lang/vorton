effect counter {
    fn tick() -> Int
}

fn main() {
    let result = handle {
        let mut sum = 0
        let mut i = 0
        while i < 3 {
            sum = sum + counter.tick()
            i = i + 1
        }
        sum
    } with {
        counter.tick() => 1,
    }
    print(result.to_str())
}
