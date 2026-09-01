// Test: type alias with generic parameters

type MaybeVal<T> = Option<T>

fn parse_num(s: Str) -> MaybeVal<Int> {
    parse_int(s)
}

fn main() {
    let r1 = parse_num("42")
    assert(r1.unwrap_or(0) == 42, "parse success")

    let r2 = parse_num("abc")
    assert(r2.is_none(), "parse fail")

    // Type alias in let binding annotation
    let x: MaybeVal<Str> = some("hello")
    assert(x.unwrap_or("") == "hello", "alias in annotation")

    print("type_alias_generic: all tests passed")
}
