mod pure_logic requires {} {
    pub fn add(a: Int, b: Int) -> Int { a + b }
    pub fn double(x: Int) -> Int { x + x }
}

mod io_layer requires {console} {
    pub fn greet(name: Str) -> Unit with {console} {
        print("Hello, ${name}!")
    }
}

fn main() {
    assert(pure_logic::add(1, 2) == 3, "pure mod add")
    assert(pure_logic::double(5) == 10, "pure mod double")
    io_layer::greet("world")
    print("mod_capability: all tests passed")
}
