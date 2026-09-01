// Test: Str supplementary methods — pad_start, repeat, char_code_at
fn main() {
    let s = "42"
    let padded = s.pad_start(5, "0")
    print(padded)

    let r = "ab".repeat(3)
    print(r)

    match "A".char_code_at(0) {
        some(code) => print(code),
        none => print("none"),
    }
    match "A".char_code_at(100) {
        some(code) => print(code),
        none => print("none"),
    }
}

// expect: 00042
// expect: ababab
// expect: 65
// expect: none
