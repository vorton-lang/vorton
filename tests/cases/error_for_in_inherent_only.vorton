struct FauxIter { pub value: Int }

impl FauxIter {
    fn iter(self) -> FauxIter { self }
    fn next(mut self) -> Int? { none }
}

fn main() {
    for value in (FauxIter { value: 0 }) {
        print(value)
    }
}
