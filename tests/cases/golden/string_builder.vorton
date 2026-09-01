// B-100 P1.1 parity: string builder — StringBuilder API: add, line,
// add_int, to_str, len.

fn main() {
    // Basic string builder
    let mut sb = string_builder()
    sb.add("hello")
    sb.add(" ")
    sb.add("world")
    let result = sb.to_str()
    print("basic=${result}")

    // String builder with line
    let mut sb2 = string_builder()
    sb2.add("line1")
    sb2.line("")
    sb2.add("line2")
    let r2 = sb2.to_str()
    print("has_line1=${r2.contains("line1")}")
    print("has_line2=${r2.contains("line2")}")

    // String builder with add_int
    let mut sb3 = string_builder()
    sb3.add("val=")
    sb3.add_int(42)
    print("int=${sb3.to_str()}")

    // Empty string builder
    let mut sb4 = string_builder()
    print("empty_len=${sb4.to_str().len()}")

    // Chain multiple operations
    let mut sb5 = string_builder()
    sb5.add("a")
    sb5.add("b")
    sb5.add("c")
    sb5.add_int(1)
    sb5.add_int(2)
    sb5.add_int(3)
    print("chain=${sb5.to_str()}")
}
