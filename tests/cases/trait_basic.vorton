trait Greetable {
    fn greet(self) -> Str
}

struct User { name: Str }

impl Greetable for User {
    fn greet(self) -> Str { self.name }
}

fn show<T: Greetable>(x: T) -> Str {
    x.greet()
}

fn main() {
    print(show(User { name: "hello-trait" }))
}
