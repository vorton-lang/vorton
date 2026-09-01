mod geo {
    pub struct Vec2 { pub x: Int, pub y: Int }

    impl Vec2 {
        pub fn magnitude(self) -> Int { self.x + self.y }
    }

    pub fn create() -> Vec2 {
        let v = Vec2 { x: 3, y: 4 }
        v
    }

    pub fn with_spread() -> Vec2 {
        let a = Vec2 { x: 1, y: 2 }
        Vec2 { ..a, x: 10 }
    }
}

fn main() {
    let v = geo::create()
    assert(v.magnitude() == 7, "magnitude should be 7")
    let v2 = geo::with_spread()
    assert(v2.x == 10, "spread x should be 10")
    assert(v2.y == 2, "spread y should be 2")
    print("mod struct literal: ok")
}
