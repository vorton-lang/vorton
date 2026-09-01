// T::Item must map to T's registration-time associated type, not become an
// independently generalized callback payload.

trait Source {
    type Item
    fn get(self) -> Self::Item
}

struct Numbers {}

impl Source for Numbers {
    type Item = Int
    fn get(self) -> Int { 7 }
}

fn raise_text() -> Int with {fail<Str>} {
    fail.raise("wrong")
}

fn recover<T: Source>(source: T, callback: fn() -> Int) -> Int {
    handle {
        callback()
    } with {
        fail.raise(message: T::Item) => 0,
    }
}

fn main() {
    recover(Numbers {}, fn() -> Int { raise_text() })
}
