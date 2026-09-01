// Test: UFCS method calls inside lambda/callback contexts
// Bug: Str methods called via UFCS inside HOF lambdas compile to
//   v.to_upper() instead of Str_to_upper(v)

fn main() {
    // Direct UFCS call works fine
    let s = "hello"
    assert(s.to_upper() == "HELLO", "direct UFCS works")

    // UFCS in list.map lambda
    let words = ["hello", "world"]
    let upper = words.map(fn(w) { w.to_upper() })
    assert(upper.get(0).unwrap_or("") == "HELLO", "ufcs in list.map lambda")
    assert(upper.get(1).unwrap_or("") == "WORLD", "ufcs in list.map lambda 2")

    print("ufcs_in_lambda: all tests passed")
}
