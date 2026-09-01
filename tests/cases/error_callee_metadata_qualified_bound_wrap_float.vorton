// expect error: E0503
// Wrapped evidence must also follow the exact two-hop DirectCallable target.

struct Wrap<T> {
    value: T
}

impl<T: Hash> Hash for Wrap<T> {
    fn hash(self) -> Int {
        self.value.hash()
    }
}

pub mod origin {
    pub fn fingerprint<T: Hash>(value: T) -> Int {
        value.hash()
    }
}

pub mod same_leaf {
    pub fn fingerprint<T>(_value: T) -> Int {
        0
    }
}

pub mod middle {
    pub use super::origin::fingerprint as relay
}

pub mod decoy_middle {
    pub use super::same_leaf::fingerprint as relay
}

pub mod facade {
    pub use super::middle::relay as target
    pub use super::decoy_middle::relay as decoy
}

fn apply(
    fingerprint: fn(Wrap<Float>) -> Int,
    value: Wrap<Float>
) -> Int {
    fingerprint(value)
}

fn main() {
    print(apply(facade::target, Wrap { value: 1.5 }))
}
