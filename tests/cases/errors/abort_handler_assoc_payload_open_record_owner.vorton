// Common fields in an open record remain owner evidence after body inference
// expands the row with extra fields. They must still participate in conflict
// detection when T and the field owner U are unified.

trait Source {
    type Item
    fn get(self) -> Self::Item
}

struct Numbers {}
struct Words {}
struct OpenBox<T> { value: T, extra: Int }

impl Source for Numbers {
    type Item = Int
    fn get(self) -> Int { 7 }
}

impl Source for Words {
    type Item = Str
    fn get(self) -> Str { "word" }
}

fn raise_number() -> Int with {fail<Int>} {
    fail.raise(7)
}

fn read_expanded<V>(box: OpenBox<V>) -> Int {
    box.extra
}

fn recover<T: Source, U: Source>(
    left: T, right: {value: U, ..row}, callback: fn() -> Int
) -> Int {
    let same: U = left
    // Unifying the open record with a concrete generic struct binds its row
    // tail to the additional `extra` field, so the checked record has more
    // visible fields than the registration skeleton.
    let expanded = read_expanded(right)
    handle {
        callback()
    } with {
        fail.raise(message: U::Item) => expanded,
    }
}

fn main() {
    recover(
        Numbers {},
        OpenBox { value: Words {}, extra: 1 },
        fn() -> Int { raise_number() }
    )
}
