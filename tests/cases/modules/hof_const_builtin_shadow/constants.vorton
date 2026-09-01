use provider::{plus_one, plus_two}

pub const print: fn(Int) -> Int = plus_one
pub const Cell: fn(Int) -> Int = plus_two

pub mod const_middle {
    pub use super::print as callable
}

pub mod facade {
    pub use super::const_middle::callable as print_callable
}

pub fn direct_getters(value: Int) -> Int {
    // Each callee is a callable const: first call its zero-argument getter,
    // then invoke the returned closure. Neither builtin extern may intercept.
    print(value) + Cell(value)
}

pub fn two_hop_print() -> fn(Int) -> Int {
    // `print` is a callable const, not the prelude extern. Returning its
    // twice-re-exported display alias exercises ConstGetter provenance as a
    // first-class value without allowing a raw builtin-name fallback.
    facade::print_callable
}
