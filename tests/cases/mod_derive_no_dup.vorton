mod geo {
    pub struct Point { pub x: Int, pub y: Int }
}

fn main() {
    let a = geo::Point { x: 1, y: 2 }
    let b = a.clone()
    assert(a == b, "clone should be equal")
    assert(a.debug() == "geo::Point { x: 1, y: 2 }", "debug should work")
    print("mod derive no dup: ok")
}
