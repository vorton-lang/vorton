struct MissingBoundIter<T> {
    pub items: List<T>,
    pub index: Int
}

impl<T> Iterator for MissingBoundIter<T> {
    type Item = T
    fn next(mut self) -> T? { none }
}

struct MissingBoundSource<T> { pub items: List<T> }

impl<T: Hash> Iterable for MissingBoundSource<T> {
    type Item = T
    type Iter = MissingBoundIter<T>
    fn iter(self) -> MissingBoundIter<T> {
        MissingBoundIter { items: self.items, index: 0 }
    }
}

fn main() {
    for value in (MissingBoundSource { items: [1.5] }) {
        print(value)
    }
}
