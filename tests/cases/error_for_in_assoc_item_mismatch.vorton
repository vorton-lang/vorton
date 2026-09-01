struct MismatchedIter {}

impl Iterator for MismatchedIter {
    type Item = Str
    fn next(mut self) -> Str? { none }
}

struct MismatchedSource {}

impl Iterable for MismatchedSource {
    type Item = Int
    type Iter = MismatchedIter
    fn iter(self) -> MismatchedIter { MismatchedIter {} }
}

fn main() {
    for value in (MismatchedSource {}) {
        print(value)
    }
}
