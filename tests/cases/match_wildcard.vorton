// Regression test for C1: match with wildcard + constructor patterns
// Previously generated duplicate default: in switch, causing SyntaxError

enum Animal {
    cat,
    dog,
    bird,
}

fn is_cat(a: Animal) -> Str {
    match a {
        cat => "yes",
        _ => "no",
    }
}

fn describe(a: Animal) -> Str {
    match a {
        cat => "meow",
        dog => "woof",
        _ => "other",
    }
}

fn main() {
    print(is_cat(cat))
    print(is_cat(dog))
    print(describe(bird))
}
