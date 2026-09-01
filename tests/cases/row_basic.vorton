struct User { name: Str, age: Int }
struct Company { name: Str, industry: Str }

fn greet(person: {name: Str, ..rest}) -> Str {
    person.name
}

fn main() {
    print(greet(User { name: "alice", age: 30 }))
}
