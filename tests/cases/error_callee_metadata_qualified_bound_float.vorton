// expect error: E0503
// A qualified two-hop DirectCallable must validate its exact live bound.

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

fn main() {
    print(facade::target(1.5))
}
