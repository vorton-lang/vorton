struct TinyCounter { pub value: Int, pub max: Int }

impl Iterator for TinyCounter {
    type Item = Int
    fn next(mut self) -> Int? {
        if self.value < self.max {
            let value = self.value
            self.value = self.value + 1
            some(value)
        } else {
            none
        }
    }
}

impl Iterable for TinyCounter {
    type Item = Int
    type Iter = TinyCounter
    fn iter(self) -> TinyCounter { self }
}

fn main() {
    let mut total = 0
    for value in (TinyCounter { value: 0, max: 3 }) {
        total = total + value
    }
    print(total)
}
