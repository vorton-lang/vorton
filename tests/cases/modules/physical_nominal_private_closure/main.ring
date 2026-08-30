use origin::{PublicBox, make_public, read_public}

fn pass_through(value: PublicBox) -> Int {
    read_public(value)
}

fn main() {
    print(pass_through(make_public(42)))
}
