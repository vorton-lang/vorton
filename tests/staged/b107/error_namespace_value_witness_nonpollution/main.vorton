mod seeds {
    enum P { V, }
    enum Q { V, }
    enum R { V, }
}

mod bad_a {
    use super::seeds::{P}
    use super::bad_b::{V}
}

mod bad_b {
    use super::seeds::{Q}
    use super::bad_a::{V}
}

mod good_a {
    use super::bad_a::{V}
    use super::seeds::{R}
    use super::good_b::{V}
}

mod good_b {
    use super::seeds::{R}
    use super::good_a::{V}
}

fn main() {}
