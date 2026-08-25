// Regression test for #69: supertrait default method body references undefined dict variable
// When trait Greeter has supertrait Named and a default method calls Named.name(),
// the generated code for __Greeter_greet must receive __ring_self_Named as a parameter.

trait Named {
    fn name(self) -> Str
}

trait Greeter: Named {
    fn greet(self) -> Str {
        "Hello, ${self.name()}!"
    }
}

struct Person { first: Str }

impl Named for Person {
    fn name(self) -> Str { self.first }
}

impl Greeter for Person {}

fn greet_someone<T: Greeter>(x: T) -> Str {
    x.greet()
}

fn main() with {console} {
    let p = Person { first: "Alice" }
    assert(greet_someone(p) == "Hello, Alice!", "supertrait default method should work")
    print("Supertrait default method: passed")
}
