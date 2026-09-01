// Body inference can unify T::Item with another declared variable U. The
// registration scheme cannot encode T::Item = U, so publishing the callback
// fail payload must fail closed instead of choosing either owner.

trait Source {
    type Item
    fn get(self) -> Self::Item
}

fn tie<X>(left: X, right: X) -> Unit {}

fn recover<T: Source, U>(
    source: T, sample: U, callback: fn() -> Int
) -> Int {
    handle {
        callback()
    } with {
        fail.raise(message: T::Item) => {
            tie(message, sample)
            0
        },
    }
}

fn main() {}
