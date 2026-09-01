mod seeds {
    enum A { V, }
    enum B { V, }
    enum C { V, }
}

mod a {
    use super::seeds::{A}
    use super::b::{V}
}

mod b {
    use super::seeds::{B}
    use super::c::{V}
}

mod c {
    use super::seeds::{C}
    use super::a::{V}
}

fn main() {}
