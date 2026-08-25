struct LateIter { pub value: Int, pub limit: Int }

fn run_before_impls() with {console} {
    for value in (LateIter { value: 0, limit: 2 }) {
        print("value=${value}")
    }
}

impl Iterator for LateIter {
    type Item = Int
    fn next(mut self) -> Int? {
        print("next")
        if self.value < self.limit {
            let value = self.value
            self.value = self.value + 1
            some(value)
        } else {
            none
        }
    }
}

impl Iterable for LateIter {
    type Item = Int
    type Iter = LateIter
    fn iter(self) -> LateIter { self }
}

fn main() {
    run_before_impls()
}
