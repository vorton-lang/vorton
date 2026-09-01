// Regression test for #92: impl target_type prefix in nested mod blocks
// Verifies that prefix_decl_name correctly qualifies impl target_type
// without double-prefixing when already qualified.

mod geo {
    pub struct Point {
        pub x: Int,
        pub y: Int,
    }

    pub impl Point {
        pub fn sum(self) -> Int {
            self.x + self.y
        }
    }

    pub mod shapes {
        pub struct Rect {
            pub w: Int,
            pub h: Int,
        }

        pub impl Rect {
            pub fn area(self) -> Int {
                self.w * self.h
            }
        }
    }
}

fn main() {
    // impl in top-level mod
    let p = geo::Point { x: 3, y: 4 }
    assert(p.sum() == 7, "impl in mod")

    // impl in nested mod
    let r = geo::shapes::Rect { w: 5, h: 6 }
    assert(r.area() == 30, "impl in nested mod")

    print("mod_nested_impl: all tests passed")
}
