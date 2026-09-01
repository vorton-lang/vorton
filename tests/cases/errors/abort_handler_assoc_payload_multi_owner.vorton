// U::Item has the callback's Str type, but the handler explicitly names
// T::Item. Owner-qualified provenance must therefore reject this call.

trait Source {
    type Item
    fn get(self) -> Self::Item
}

struct Numbers {}
struct Words {}

impl Source for Numbers {
    type Item = Int
    fn get(self) -> Int { 7 }
}

impl Source for Words {
    type Item = Str
    fn get(self) -> Str { "word" }
}

fn raise_text() -> Int with {fail<Str>} {
    fail.raise("wrong-owner")
}

fn recover<T: Source, U: Source>(
    left: T, right: U, callback: fn() -> Int
) -> Int {
    handle {
        callback()
    } with {
        fail.raise(message: T::Item) => 0,
    }
}

fn main() {
    recover(Numbers {}, Words {}, fn() -> Int { raise_text() })
}
