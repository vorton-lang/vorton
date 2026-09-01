pub trait Source {
    type Item
    fn get(self) -> Self::Item
}

pub struct Bad {}

impl Source for Bad {
    type Item = Str
    fn get(self) -> Str { "bad" }
}

pub fn invoke<T: Source<Item = Int>>(f: fn() -> Int with {fail<T>}) -> Int {
    f()
}

pub fn fail_bad() -> Int with {fail<Bad>} {
    fail.raise(Bad {})
}
