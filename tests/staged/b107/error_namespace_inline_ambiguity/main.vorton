mod first {
    pub fn one() -> Int { 1 }
    pub struct One {}
}

mod second {
    pub fn two() -> Int { 2 }
    pub struct Two {}
}

pub mod facade {
    pub use super::first::{one as Clash, One as TypeClash}
    pub use super::second::{two as Clash, Two as TypeClash}
}

fn main() {}
