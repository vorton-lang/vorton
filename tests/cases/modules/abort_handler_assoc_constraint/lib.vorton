pub trait Source {
    type Item
    fn get(self) -> Self::Item
}

pub struct Numbers {}

impl Source for Numbers {
    type Item = Int
    fn get(self) -> Int { 7 }
}

pub fn raise_number() -> Int with {fail<Int>} {
    fail.raise(7)
}

// The explicit associated constraint is already representable in the
// registration scheme. Rebinding the callback row must not fail closed.
pub fn recover<T: Source<Item = Int>>(
    source: T, callback: fn() -> Int
) -> Int {
    handle {
        callback()
    } with {
        fail.raise(message: T::Item) => 31,
    }
}
