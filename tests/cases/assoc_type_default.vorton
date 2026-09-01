// Associated type with default value in trait
trait Processor {
    type Output = Int
    fn process(self) -> Output
}

struct Doubler {
    value: Int
}

// Uses default: Output = Int (no explicit type Item = ...)
impl Processor for Doubler {
    fn process(self) -> Int {
        self.value * 2
    }
}

struct Greeter {
    name: Str
}

// Overrides default: Output = Str
impl Processor for Greeter {
    type Output = Str
    fn process(self) -> Str {
        "Hello, ${self.name}!"
    }
}

fn main() {
    let d = Doubler { value: 21 }
    assert(d.process() == 42, "Doubler should return 42")
    let g = Greeter { name: "World" }
    assert(g.process() == "Hello, World!", "Greeter should greet")
    print("assoc type default: ok")
}
