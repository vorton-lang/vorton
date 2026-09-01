// Regression test for #61: short-name alias collision between mods
// First alias wins; use qualified names to disambiguate

mod a {
    pub struct Foo {
        pub x: Int,
    }
}

mod b {
    pub struct Foo {
        pub y: Str,
    }
}

fn main() {
    // Qualified access always works
    let fa = a::Foo { x: 42 }
    let fb = b::Foo { y: "hello" }
    print(fa.x)
    print(fb.y)
}
