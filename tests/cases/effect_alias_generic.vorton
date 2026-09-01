effect alias Failable<E> = {fail<E>}

fn parse(s: Str) -> Int with {Failable<Str>} {
    if s == "42" { 42 } else { fail.raise("bad input") }
}

fn main() {
    let result = parse("42") catch { e => 0 }
    assert(result == 42, "parse 42 should return 42")
    let result2 = parse("x") catch { e => -1 }
    assert(result2 == -1, "parse x should fail and catch")
    print("Generic effect alias: all passed")
}
