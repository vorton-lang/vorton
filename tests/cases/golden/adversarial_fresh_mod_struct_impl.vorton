// B-100 P1.3 R3 adversarial: inline mod with struct + impl + external call.
//
// Exercises:
//   * Struct defined inside a mod with pub impl methods
//   * Nested mod with struct and impl
//   * External code calling mod-internal methods via qualified paths
//   * Trait impl inside mod, dispatched from outside
//   * Const inside mod referenced from impl method

mod math {
    pub const PI_APPROX: Int = 314

    pub struct Vec2 {
        pub x: Int,
        pub y: Int,
    }

    pub impl Vec2 {
        pub fn magnitude_sq(self) -> Int {
            self.x * self.x + self.y * self.y
        }

        pub fn add(self, other: Vec2) -> Vec2 {
            Vec2 { x: self.x + other.x, y: self.y + other.y }
        }

        pub fn scale(self, factor: Int) -> Vec2 {
            Vec2 { x: self.x * factor, y: self.y * factor }
        }
    }

    pub trait Describable {
        fn describe(self) -> Str
    }

    pub impl Describable for Vec2 {
        fn describe(self) -> Str {
            "(${self.x}, ${self.y})"
        }
    }

    pub mod shapes {
        pub struct Rect {
            pub origin: Vec2,
            pub size: Vec2,
        }

        pub impl Rect {
            pub fn area(self) -> Int {
                self.size.x * self.size.y
            }

            pub fn corner(self) -> Vec2 {
                self.origin.add(self.size)
            }
        }
    }
}

fn describe_it(v: math::Vec2) -> Str {
    v.describe()
}

fn main() {
    // Basic struct in mod
    let v1 = math::Vec2 { x: 3, y: 4 }
    print("mag_sq=${v1.magnitude_sq()}")

    // Method chaining (add + scale)
    let v2 = math::Vec2 { x: 1, y: 2 }
    let v3 = v1.add(v2)
    print("add=${v3.x},${v3.y}")
    let v4 = v2.scale(3)
    print("scale=${v4.x},${v4.y}")

    // Trait dispatch from outside mod
    print("describe=${describe_it(v1)}")

    // Const in mod
    print("pi=${math::PI_APPROX}")

    // Nested mod struct
    let r = math::shapes::Rect {
        origin: math::Vec2 { x: 10, y: 20 },
        size: math::Vec2 { x: 5, y: 3 },
    }
    print("area=${r.area()}")
    let c = r.corner()
    print("corner=${c.x},${c.y}")
}
