trait Source {
    type Item
    fn item(self) -> Item
}

struct IntSource {}
impl Source for IntSource {
    type Item = Int
    fn item(self) -> Int { 1 }
}

fn unknown<T>() -> T {
    panic("callable assoc fixed-point probe is not executed")
}

fn hash_identity<T: Hash>(value: T) -> T { value }

fn attach_source<T, S: Source<Item = T>>(source: S, _value: T) -> S with {} {
    source
}

fn main() {
    if false {
        let pending = hash_identity(unknown())
        let source_fn = attach_source
        // The LocalBorrow call links source_fn's S/T to IntSource and the
        // earlier pending value.  Only the bounded callable value's exact
        // Source<Item=T> scheme can then supply T = Int.
        let local = fn(source: IntSource) {
            let selected: IntSource = source_fn(source, pending)
            selected
        }
        let _unused = local
    }
    print("callable-assoc=ok")
}
