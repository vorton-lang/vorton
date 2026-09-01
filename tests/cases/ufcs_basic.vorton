// TestGap T6: Plain UFCS (non-trait impl methods)
struct Counter { value: Int }

impl Counter {
    fn increment(self) -> Counter {
        Counter { value: self.value + 1 }
    }

    fn get(self) -> Int {
        self.value
    }
}

fn main() {
    let c = Counter { value: 0 }
    let c2 = c.increment()
    print(c2.get())
}
