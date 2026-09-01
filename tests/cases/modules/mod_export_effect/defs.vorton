// Regression test for #88: pub mod should export traits and impl across files
// Without fix, trait defined in pub mod is silently dropped from exports,
// making cross-module trait dispatch fail.

pub mod protocol {
    pub trait Greetable {
        fn greet(self) -> Str
    }

    pub struct Person {
        pub name: Str,
    }

    impl Greetable for Person {
        fn greet(self) -> Str {
            "Hello, ${self.name}!"
        }
    }
}

pub fn greet_someone(name: Str) -> Str {
    let p = protocol::Person { name: name }
    p.greet()
}
