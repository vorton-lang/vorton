// Regression test: effect alias type param should not shadow
// outer type params with the same name (#76)
effect alias Failable<T> = {fail<T>}

// T in the function's type params is independent from T in the alias definition
fn parse<T>(s: Str, default_val: T) -> T with {Failable<Str>} {
    if s == "" {
        fail.raise("empty input")
    }
    default_val
}

// Nested alias: alias type param T should not collide with
// outer usage of T in another alias
effect alias MyIO<T> = {console, fail<T>}

fn greet(name: Str) -> Str with {MyIO<Str>} {
    print("hello ${name}")
    name
}

fn main() {
    let result = parse("hello", 42) catch { _ => -1 }
    assert(result == 42, "parse with non-empty should return default_val")
    let result2 = parse("", 42) catch { _ => -1 }
    assert(result2 == -1, "parse with empty should fail and catch")
    let name = greet("world") catch { _ => "nobody" }
    assert(name == "world", "greet should return the name")
    print("Effect alias shadowing: all passed")
}
