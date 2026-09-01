// If body inference unifies the generic owners T and U themselves, a
// first-position mapping must not make U::Item inherit T's registration owner.

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

fn require_same<V>(left: V, right: V) -> Unit {}

fn raise_number() -> Int with {fail<Int>} {
    fail.raise(7)
}

fn recover<T: Source, U: Source>(
    left: T, right: U, callback: fn() -> Int
) -> Int {
    require_same(left, right)
    handle {
        callback()
    } with {
        fail.raise(message: U::Item) => 0,
    }
}

fn main() {
    recover(Numbers {}, Words {}, fn() -> Int { raise_number() })
}
