// B-100 P1.1 parity: row types — structural subtyping with row polymorphism,
// passing structs with extra fields to row-typed parameters.

fn greet(person: {name: Str}) -> Str {
    "hello ${person.name}"
}

fn name_and_age(p: {name: Str, age: Int}) -> Str {
    "${p.name} is ${p.age}"
}

struct User { name: Str, age: Int, email: Str }
struct Simple { name: Str }

fn main() {
    // Simple row type
    let s = Simple { name: "Alice" }
    print("simple=${greet(s)}")

    // Struct with extra fields passed to row-typed param
    let u = User { name: "Bob", age: 30, email: "bob@test" }
    print("user=${greet(u)}")

    // Two-field row type
    print("name_age=${name_and_age(u)}")
}
