struct DeclaredIter {}
impl Iterator for DeclaredIter {
    type Item = Int
    fn next(mut self) -> Int? { none }
}

struct ActualIter {}
impl Iterator for ActualIter {
    type Item = Int
    fn next(mut self) -> Int? { none }
}

struct WrongIterSource {}
impl Iterable for WrongIterSource {
    type Item = Int
    type Iter = DeclaredIter
    fn iter(self) -> ActualIter { ActualIter {} }
}

fn main() {
    for value in (WrongIterSource {}) {
        print(value)
    }
}
