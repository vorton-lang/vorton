pub mod facade {
    pub use super::origin::{boom as forwarded}
}

pub mod consumer {
    use super::facade::{forwarded}

    pub fn recover() -> Int {
        forwarded() catch {
            error => error.code,
        }
    }
}

pub mod origin {
    pub struct E {
        pub code: Int,
    }

    pub fn boom() -> Int {
        fail.raise(E { code: 43 })
    }
}

fn main() {
    print(consumer::recover())
}
