// B-115: nested quotes inside string interpolation. The lexer keeps one frame
// per open `${` (brace depth + start span), so an inner `"` opens a new string
// instead of terminating the outer one, to arbitrary nesting depth. Also locks
// raw-string interaction and `}` inside inner strings.

fn wrap(s: Str) -> Str {
    "<${s}>"
}

fn main() {
    // spec acceptance: call with string literal arg inside interpolation
    assert("${wrap("arg")}" == "<arg>", "string arg in interp call")

    // spec acceptance: chained calls with string args on a Map
    let mut m: Map<Str, Str> = map_new()
    m.insert("k", "v")
    assert("${m.get("k").unwrap_or("d")}" == "v", "map get hit in interp")
    assert("${m.get("zz").unwrap_or("d")}" == "d", "map get miss in interp")

    // inner strings containing braces
    assert("${wrap("}")}" == "<}>", "closing brace in inner string")
    assert("${wrap("{a}")}" == "<{a}>", "balanced braces in inner string")

    // double-nested: interpolation inside string inside interpolation
    let a = "A"
    assert("${"L1 ${"L2 ${a}"}"}" == "L1 L2 A", "triple-nested interpolation")

    // escaped quotes inside the inner string
    assert("${wrap("\"q\"")}" == "<\"q\">", "escaped quotes in inner string")

    // multiple interpolations with inner strings in one literal
    assert("${wrap("x")} and ${wrap("y")}" == "<x> and <y>", "two interps with inner strings")

    // braces at interpolation depth > 0 with string arms
    let cond = true
    assert("${ if cond { "yes" } else { "no" } }" == "yes", "if-else with string arms in interp")

    // raw strings inside interpolation: no escapes, braces/quotes literal
    assert("${r"raw\n"}" == "raw\\n", "raw string keeps backslash in interp")
    assert("${r"}"}" == "}", "raw string with closing brace in interp")
    assert("${r#"has " quote"#}" == "has \" quote", "hash raw string with quote in interp")

    // raw strings never interpolate
    let x = "X"
    assert(r"${x}" == "\${x}", "raw string does not interpolate")

    print("string_interp_nested_quotes: all tests passed")
}
