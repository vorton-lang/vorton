fn describe(s: Str) -> Str {
    match s {
        "hello" => "greeting",
        "bye" => "farewell",
        _ => "unknown",
    }
}

fn main() {
    assert(describe("hello") == "greeting", "match hello")
    assert(describe("bye") == "farewell", "match bye")
    assert(describe("x") == "unknown", "match wildcard")
    print("match_string: all tests passed")
}
