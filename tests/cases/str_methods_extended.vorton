fn main() {
    // trim_start / trim_end
    let s = "  hello  "
    assert(s.trim_start() == "hello  ", "trim_start")
    assert(s.trim_end() == "  hello", "trim_end")

    // is_empty
    assert("".is_empty(), "empty string is_empty")
    assert(!("hello".is_empty()), "non-empty is not empty")

    // last_index_of
    let text = "abcabc"
    match text.last_index_of("bc") {
        some(i) => assert(i == 4, "last_index_of found"),
        none => panic("should find bc")
    }
    match text.last_index_of("xyz") {
        some(_) => panic("should not find xyz"),
        none => {}
    }

    print("all str method tests passed")
}
