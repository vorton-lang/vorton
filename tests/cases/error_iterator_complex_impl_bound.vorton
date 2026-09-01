trait HasItem {
    type Item
}

struct ComplexIter<T> {}

impl<T> Iterator for ComplexIter<T> {
    type Item = T
    fn next(mut self) -> T? { none }
}

struct ComplexSource<T> { pub value: T }

impl<T: HasItem<Item = Int>> Iterable for ComplexSource<T> {
    type Item = T
    type Iter = ComplexIter<T>
    fn iter(self) -> ComplexIter<T> { ComplexIter {} }
}

fn main() {}
