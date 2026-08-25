pub trait Named {
    fn name(self) -> Str
}

pub trait Greeter: Named {
    fn greet(self) -> Str {
        "Hello ${self.name()}"
    }
}

pub struct Person { value: Str }

impl Named for Person {
    fn name(self) -> Str { self.value }
}

impl Greeter for Person {}

pub fn project_greeting() -> Str {
    let original = Person { value: "Project" }
    let copied = original.clone()
    copied.greet()
}
