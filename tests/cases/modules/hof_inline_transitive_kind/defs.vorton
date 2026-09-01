pub mod origin {
    pub fn bump(value: Int) -> Int {
        value + 1
    }
}

pub mod same_leaf {
    pub fn bump(value: Int) -> Int {
        value + 100
    }
}

pub mod middle {
    pub use super::origin::{bump as step}
}

pub mod same_leaf_middle {
    pub use super::same_leaf::{bump as step}
}

pub mod facade {
    pub use super::middle::{step as increment}
    pub use super::same_leaf_middle::{step as decoy_increment}
}
