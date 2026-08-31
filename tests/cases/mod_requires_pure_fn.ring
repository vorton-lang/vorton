// Pure functions inside mod requires {console} should compile without error.
// Regression test for #107: check_effects_capability rejected all open
// effect rows, including those of completely pure functions.

mod restricted requires {console} {
    // Pure function inside mod requires {console} — should compile without error
    pub fn identity(x: Int) -> Int { x }

    pub fn add(a: Int, b: Int) -> Int { a + b }

    // Function that actually uses console — also should compile
    pub fn greet(name: Str) {
        print("hello ${name}")
    }
}

fn main() {
    let x = restricted::identity(42)
    assert(x == 42, "identity works")

    let sum = restricted::add(1, 2)
    assert(sum == 3, "add works")

    restricted::greet("world")

    print("mod requires pure fn: ok")
}
