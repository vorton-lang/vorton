pub trait Source {
    type Item
    fn get(self) -> Self::Item
}

pub struct Good {}

impl Source for Good {
    type Item = Int
    fn get(self) -> Int { 9 }
}

// T occurs only in the HOF effect payload.  The body-inferred fail<T> row is
// propagated from f(), then rebind_fn_type must attach it to the registered T
// without dropping Source<Item = Int>.
pub fn invoke<T: Source<Item = Int>>(f: fn() -> Int with {fail<T>}) -> Int {
    f()
}

pub fn fail_good() -> Int with {fail<Good>} {
    fail.raise(Good {})
}
