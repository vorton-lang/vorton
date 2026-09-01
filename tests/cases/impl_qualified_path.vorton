mod geo {
    pub struct Vec2 {
        pub x: Int,
        pub y: Int
    }
}

// impl directly with qualified path
impl geo::Vec2 {
    fn magnitude_sq(self) -> Int {
        self.x * self.x + self.y * self.y
    }
}

// impl Trait for qualified path
trait Describable {
    fn describe(self) -> Str
}

impl Describable for geo::Vec2 {
    fn describe(self) -> Str {
        "Vec2(${self.x}, ${self.y})"
    }
}

// Multi-level qualified path: impl a::b::Type
mod math {
    pub mod linalg {
        pub struct Vec3 {
            pub x: Int,
            pub y: Int,
            pub z: Int
        }
    }
}

impl math::linalg::Vec3 {
    fn sum(self) -> Int {
        self.x + self.y + self.z
    }
}

impl Describable for math::linalg::Vec3 {
    fn describe(self) -> Str {
        "Vec3(${self.x}, ${self.y}, ${self.z})"
    }
}

fn main() {
    let v = geo::Vec2 { x: 3, y: 4 }
    assert(v.magnitude_sq() == 25, "magnitude_sq")
    assert(v.describe() == "Vec2(3, 4)", "describe")

    let w = math::linalg::Vec3 { x: 1, y: 2, z: 3 }
    assert(w.sum() == 6, "sum")
    assert(w.describe() == "Vec3(1, 2, 3)", "describe_vec3")

    print("ok")
}
