pub extern type PublicHandle

pub fn keep_public(value: PublicHandle) -> PublicHandle { value }

pub mod ffi {
    pub extern type Handle

    pub fn keep(value: Handle) -> Handle { value }
}

// Deliberately precedes its private source sibling. Export extraction must
// prove the complete hidden_outer::nested::SecretHandle AST path before
// consulting the raw extern registry.
pub mod facade {
    pub use super::hidden_outer::nested::{
        SecretHandle as Handle,
        keep_secret as keep,
    }
}

mod hidden_outer {
    pub mod nested {
        pub extern type SecretHandle

        pub fn keep_secret(value: SecretHandle) -> SecretHandle { value }
    }
}

// The raw extern leaf exists, but the public source is an ordinary function.
// A leaf-only extern fallback would incorrectly export value_facade::LeafDecoy
// as a type.
pub mod value_facade {
    pub use super::ordinary::{LeafDecoy}
}

mod ordinary {
    pub fn LeafDecoy() -> Int { 7 }
}

mod unrelated_ffi {
    extern type LeafDecoy
}

pub mod left {
    extern type ScopedHandle

    fn keep_scoped(value: ScopedHandle) -> ScopedHandle { value }

    enum Choice<T> {
        Empty,
        Same(T),
        Record { value: T },
    }

    pub fn value() -> Int {
        let choice = Same(11)
        match choice {
            Same(value) => value,
            Empty => 0,
            Record { value } => value,
        }
    }

    pub fn empty_value() -> Int {
        let choice: Choice<Int> = Empty
        match choice {
            Same(value) => value,
            Empty => 0,
            Record { value } => value,
        }
    }

    pub fn record_value() -> Int {
        let choice = Record { value: 33 }
        match choice {
            Same(value) => value,
            Empty => 0,
            Record { value } => value,
        }
    }
}

pub mod right {
    enum Choice {
        Empty,
        Same(Int),
    }

    pub fn value() -> Int {
        let choice = Same(22)
        match choice {
            Same(value) => value,
            Empty => 0,
        }
    }
}

pub fn Same(value: Int) -> Int { value + 100 }
