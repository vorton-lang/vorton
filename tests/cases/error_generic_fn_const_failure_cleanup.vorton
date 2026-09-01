// expect error: E0503
// A failed final const zonk must roll back its speculative substitution and
// bound-resolution state.  The later independent callable const must still
// type-check instead of inheriting BAD's failed Wrap<Float> evidence.

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

const BAD: fn(Wrap<Float>) -> Int = hash_one

fn plus_one(value: Int) -> Int with {} {
    value + 1
}

const GOOD: fn(Int) -> Int = plus_one

fn apply(f: fn(Int) -> Int, value: Int) -> Int {
    f(value)
}

fn main() {
    print(apply(GOOD, 41))
}
