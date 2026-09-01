struct GenericIter<T> {
    pub items: List<T>,
    pub index: Int
}

impl<T> Iterator for GenericIter<T> {
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

struct GenericSource<T> { pub items: List<T> }

impl<T> Iterable for GenericSource<T> {
    type Item = T
    type Iter = GenericIter<T>
    fn iter(self) -> GenericIter<T> {
        GenericIter { items: self.items, index: 0 }
    }
}

fn main() {
    for value in (GenericSource { items: [1, 2] }) {
        print("int=${value}")
    }
    for value in (GenericSource { items: ["a", "b"] }) {
        print("str=${value}")
    }
}
