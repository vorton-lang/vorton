pub use base::{apply_base}

pub fn apply_beta(
    callback: fn(Int) -> Int,
    value: Int
) -> Int {
    callback(value) + 200
}
