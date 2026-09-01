mod seeds {
    enum Shared { V, }
}

mod a {
    use super::seeds::{Shared}
    use super::b::{V}
}

mod b {
    use super::seeds::{Shared}
    use super::c::{V}
}

mod c {
    use super::seeds::{Shared}
    use super::a::{V}
}

fn main() {
    print(1)
}
