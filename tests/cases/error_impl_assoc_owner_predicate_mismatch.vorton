trait ItemSource {
    type Item
    fn read(self) -> Item
}

struct StrSource { value: Str }

impl ItemSource for StrSource {
    type Item = Str
    fn read(self) -> Str { self.value }
}

trait ReadSize {
    fn read_size(self) -> Int
}

struct Wrapper<T> { source: T }

impl<T: ItemSource<Item = Int>> ReadSize for Wrapper<T> {
    fn read_size(self) -> Int { self.source.read() }
}

fn main() {
    let wrapped = Wrapper { source: StrSource { value: "wrong" } }
    wrapped.read_size()
}
