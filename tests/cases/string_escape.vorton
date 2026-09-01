// Test: string escape sequences and edge cases

fn main() {
    // Basic escape sequences
    let newline = "hello\nworld"
    assert(newline.len() == 11, "newline in string")

    let tab = "a\tb"
    assert(tab.len() == 3, "tab in string")

    let backslash = "a\\b"
    assert(backslash.len() == 3, "backslash in string")

    let quote = "a\"b"
    assert(quote.len() == 3, "quote in string")

    // Empty string
    let empty = ""
    assert(empty.len() == 0, "empty string")

    // String concatenation via interpolation
    let a = "hello"
    let b = "world"
    let combined = "${a} ${b}"
    assert(combined == "hello world", "interpolation concat")

    // Multi-level interpolation
    let x = 42
    let msg = "val=${x}"
    assert(msg == "val=42", "simple interp")

    print("string_escape: all tests passed")
}
