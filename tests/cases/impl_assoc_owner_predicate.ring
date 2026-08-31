trait ItemSource {
    type Item
    fn read(self) -> Item
}

struct IntSource { value: Int }

impl ItemSource for IntSource {
    type Item = Int
    fn read(self) -> Int { self.value }
}

trait ReadSize {
    fn read_size(self) -> Int
}

struct Wrapper<T> { source: T }

impl<T: ItemSource<Item = Int>> ReadSize for Wrapper<T> {
    fn read_size(self) -> Int { self.source.read() }
}

fn main() {
    let wrapped = Wrapper { source: IntSource { value: 17 } }
    assert(wrapped.read_size() == 17, "impl assoc predicate")
    print("impl assoc owner predicate: ok")
}
