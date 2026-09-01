// B-115: nested quotes inside string interpolation across both backends.
// Inner string literals (incl. escaped quotes / braces), chained calls with
// string args, double-nested interpolation, raw strings inside interpolation,
// and `}` handling at interpolation brace depth > 0.

fn wrap(s: Str) -> Str {
    "<${s}>"
}

fn main() {
    // call with string literal arg inside interpolation
    print("${wrap("arg")}")                          // <arg>

    // chained map lookup with string keys + default
    let mut m: Map<Str, Str> = map_new()
    m.insert("k", "v")
    print("${m.get("k").unwrap_or("d")}")            // v
    print("${m.get("zz").unwrap_or("d")}")           // d

    // inner strings containing braces
    print("${wrap("}")}")                            // <}>
    print("${wrap("{a}")}")                          // <{a}>

    // double-nested interpolation with nested quotes
    let a = "A"
    print("${"L1 ${"L2 ${a}"}"}")                    // L1 L2 A

    // escaped quotes in the inner string
    print("${wrap("\"q\"")}")                        // <"q">

    // braces at interpolation depth > 0 with string arms
    let cond = true
    print("${ if cond { "yes" } else { "no" } }")    // yes

    // raw strings inside interpolation / raw strings never interpolate
    print("${r"raw\n"}")                             // raw\n
    print("${r"}"}")                                 // }
    print(r"${a}")                                   // ${a}
}
