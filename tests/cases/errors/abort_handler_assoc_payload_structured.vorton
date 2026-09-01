// If body inference constrains T::Item to a structure, the current scheme
// cannot publish that equality. The callback fail payload must fail closed.

trait Source {
    type Item
    fn get(self) -> Self::Item
}

fn use_ints(values: List<Int>) -> Unit {}

fn recover<T: Source>(source: T, callback: fn() -> Int) -> Int {
    use_ints(source.get())
    handle {
        callback()
    } with {
        fail.raise(message: T::Item) => {
            use_ints(message)
            0
        },
    }
}

fn main() {}
