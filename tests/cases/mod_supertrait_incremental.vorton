// Regression test for #83: supertrait lookup in mod blocks
// register_trait needs short-name aliases for supertraits defined in the same mod.
// insert_mod_aliases must run incrementally (after traits) so that
// `Printable: HasArea` can resolve `HasArea` by short name.

mod shapes {
    pub trait HasArea {
        fn area(self) -> Int
    }

    pub trait Printable: HasArea {
        fn describe(self) -> Str
    }

    pub struct Circle { pub radius: Int }

    impl HasArea for Circle {
        fn area(self) -> Int { self.radius * self.radius * 3 }
    }

    impl Printable for Circle {
        fn describe(self) -> Str { "Circle with area ${self.area()}" }
    }
}

fn main() {
    let c = shapes::Circle { radius: 5 }
    assert(c.area() == 75, "area should be 75")
    assert(c.describe() == "Circle with area 75", "describe should work")
    print("mod supertrait incremental: ok")
}
