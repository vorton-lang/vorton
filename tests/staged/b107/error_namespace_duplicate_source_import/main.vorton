mod same {
    pub enum First {
        Clash,
    }
    pub struct Handle {}
}

mod same {
    pub enum Second {
        Clash,
    }
    pub extern type Handle
}

mod target {
    use super::same::{Clash, Handle}
}

fn main() {}
