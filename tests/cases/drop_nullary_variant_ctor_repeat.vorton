// A fieldless variant is a fresh construction on every evaluation, even when
// its enum implements Drop. The move checker must not consume the ctor binding.
enum Resource {
    Empty,
}

impl Drop for Resource {
    fn drop(self) {}
}

fn main() {
    let first = Resource::Empty
    let second = Resource::Empty
    print("ok")
}
