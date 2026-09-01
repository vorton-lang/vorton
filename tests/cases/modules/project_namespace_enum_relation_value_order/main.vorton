use defs::{score_b}
use values::{}

pub mod compat_strong_compat {
    pub use defs::{A}
    pub use values::{V}
    pub use defs::{B}
}

pub mod compat_compat_strong {
    pub use defs::{A}
    pub use defs::{B}
    pub use values::{V}
}

pub mod strong_compat_compat {
    pub use values::{V}
    pub use defs::{A}
    pub use defs::{B}
}

fn compat_strong_compat_run() -> Int {
    score_b(compat_strong_compat::V(3))
}

fn compat_strong_compat_exact() -> Int {
    score_b(compat_strong_compat::V(11)) +
        score_b(compat_strong_compat::V(13))
}

fn strong_compat_compat_run() -> Int {
    score_b(strong_compat_compat::V(7))
}

fn main() {
    print(compat_strong_compat_run())
    print(compat_strong_compat_exact())
    print(compat_compat_strong::V(5))
    print(strong_compat_compat_run())
}
