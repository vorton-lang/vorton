fn main() {
    let mut sb = string_builder()
    sb.add("hello")
    sb.add(" ")
    sb.add("world")
    assert(sb.to_str() == "hello world", "basic add")

    let mut sb2 = string_builder()
    sb2.line("first")
    sb2.line("second")
    let result = sb2.to_str()
    assert(result.contains("first"), "line first")
    assert(result.contains("second"), "line second")

    let mut sb3 = string_builder()
    sb3.add("count: ")
    sb3.add_int(42)
    assert(sb3.to_str() == "count: 42", "add_int")

    let mut empty = string_builder()
    assert(empty.to_str() == "", "empty builder")
    assert(empty.len() == 0, "empty len")

    print("string_builder: all tests passed")
}
