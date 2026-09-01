// expect-error: E0513
trait Source {
    type Item
    fn get(self) -> Self::Item
}

struct Bad {}

impl Source for Bad {
    type Item = Str
    fn get(self) -> Str { "bad" }
}

fn invoke<T: Source<Item = Int>>(f: fn() -> Int with {fail<T>}) -> Int {
    f()
}

fn fail_bad() -> Int with {fail<Bad>} {
    fail.raise(Bad {})
}

fn main() {
    let value = invoke(fail_bad) catch { _ => 0 }
    print(value)
}
