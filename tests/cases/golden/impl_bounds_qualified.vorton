// B-100 P1.1 parity: impl bounds + qualified path — impl with trait bounds
// on type parameters, impl for qualified (module-scoped) types, impl Trait
// for qualified types.

// --- impl with trait bounds ---

impl<T: Eq> List {
    pub fn has_item(self, item: T) -> Bool {
        for x in self {
            if x == item { return true }
        }
        false
    }
}

// --- impl for qualified path ---

mod geo {
    pub struct Vec2 {
        pub x: Int,
        pub y: Int,
    }
}

impl geo::Vec2 {
    fn magnitude_sq(self) -> Int {
        self.x * self.x + self.y * self.y
    }
}

trait Printable {
    fn to_display(self) -> Str
}

impl Printable for geo::Vec2 {
    fn to_display(self) -> Str {
        "Vec2(${self.x}, ${self.y})"
    }
}

// --- multi-level qualified path ---

mod math {
    pub mod linalg {
        pub struct Vec3 {
            pub x: Int,
            pub y: Int,
            pub z: Int,
        }
    }
}

impl math::linalg::Vec3 {
    fn sum(self) -> Int {
        self.x + self.y + self.z
    }
}

impl Printable for math::linalg::Vec3 {
    fn to_display(self) -> Str {
        "Vec3(${self.x}, ${self.y}, ${self.z})"
    }
}

fn main() {
    // impl with trait bounds
    let nums = [1, 2, 3, 4, 5]
    print("has2=${nums.has_item(2)}")
    print("has9=${nums.has_item(9)}")

    // impl for qualified path
    let v = geo::Vec2 { x: 3, y: 4 }
    print("mag_sq=${v.magnitude_sq()}")
    print("display=${v.to_display()}")

    // multi-level qualified path
    let w = math::linalg::Vec3 { x: 1, y: 2, z: 3 }
    print("vec3_sum=${w.sum()}")
    print("vec3_display=${w.to_display()}")
}
