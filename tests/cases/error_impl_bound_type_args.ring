trait Rel<T> {
    fn relate(self, value: T) -> Bool
}

struct Holder<T> { value: T }

impl<T: Rel<Int>> Holder<T> {
    fn present(self) -> Bool { true }
}

fn main() {}
