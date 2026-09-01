mod same {
    enum Shared {
        FirstOnly,
        SecondOnly,
    }

    fn SecondOnly() -> Int { 10 }
    fn FirstOnly() -> Int { 20 }
}

pub mod target {
    pub use super::same::{Shared}

    pub fn accept(value: Shared) -> Int { 1 }
}

fn main() {
    print(
        target::accept(target::FirstOnly) +
        target::accept(target::SecondOnly) +
        target::accept(target::Shared::FirstOnly) +
        target::accept(target::Shared::SecondOnly)
    )
}
