pub fn same() -> Int { 10 }

// Deliberately precedes its source sibling. Both imports resolve to the same
// canonical payload and must not allocate competing frame facts.
pub mod facade {
    pub use super::left::{same as shared}
    pub use super::left::{same as shared}

    pub fn value() -> Int { shared() }
}

pub mod left {
    pub fn same() -> Int { 20 }

    pub mod nested {
        pub fn same() -> Int { 30 }
        pub fn value() -> Int { same() }
    }

    // Checking nested must restore this frame's same-spelled binding.
    pub fn value() -> Int { same() }
}

pub mod right {
    pub fn same() -> Int { 40 }
    pub fn value() -> Int { same() }
}

// Registering/checking either sibling must restore the file-root binding.
pub fn value() -> Int { same() }
