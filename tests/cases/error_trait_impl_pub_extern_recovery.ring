trait Visible {
    fn preserved(self) -> Int
}

struct Wrapper<T> {
    value: T
}

impl<T> Visible for Wrapper<T> {
    pub extern fn blocked<U>(self: Wrapper<T>, value: U) -> Int with {fail<Str>}
    fn preserved(self) -> Int { 7 }
}

fn main() {}
