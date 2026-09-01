struct BoundIter<T> {
    pub items: List<T>,
    pub index: Int
}

impl<T> Iterator for BoundIter<T> {
    type Item = T
    fn next(mut self) -> T? {
        if self.index < self.items.len() {
            let value = self.items.get(self.index)
            self.index = self.index + 1
            value
        } else {
            none
        }
    }
}

struct BoundSource<T> { pub items: List<T> }

impl<T: Hash> Iterable for BoundSource<T> {
    type Item = T
    type Iter = BoundIter<T>
    fn iter(self) -> BoundIter<T> {
        BoundIter { items: self.items, index: 0 }
    }
}

fn main() {
    for value in (BoundSource { items: [3, 4] }) {
        print(value)
    }
}
