// expect error: E0503
// A Hash impl for Wrap<T> requires T: Hash.  Coercing hash_one to a function
// over Wrap<Float> must reject the missing inner evidence at the HOF site.

struct Wrap<T> {
    value: T
}

impl<T: Hash> Hash for Wrap<T> {
    fn hash(self) -> Int {
        self.value.hash()
    }
}

fn hash_one<T: Hash>(value: T) -> Int with {} {
    value.hash()
}

fn apply_float_wrap(
    f: fn(Wrap<Float>) -> Int,
    value: Wrap<Float>
) -> Int {
    f(value)
}

fn main() {
    print(apply_float_wrap(hash_one, Wrap { value: 1.5 }))
}
