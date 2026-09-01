// Test: raw strings — r"..." and r#"..."#

fn main() {
    // r"..." basic raw string — no escape processing
    let raw = r"hello\nworld"
    assert(raw.contains("\\"), "raw contains backslash")
    assert(raw.len() == 12, "raw length is 12")

    // r"..." does not trigger interpolation
    let raw2 = r"${not_a_var}"
    assert(raw2.contains("\${"), "raw no interpolation")
    assert(raw2.len() == 12, "raw2 length")

    // r#"..."# can contain double quotes
    let raw3 = r#"say "hello""#
    let quote = "\""
    assert(raw3.contains(quote), "raw with quotes")
    assert(raw3.len() == 11, "raw3 length")

    // r"..." multiline
    let raw_ml = r"line1
line2"
    assert(raw_ml.contains("line1"), "raw multiline line1")
    assert(raw_ml.contains("line2"), "raw multiline line2")

    // r"..." backslash sequences are literal
    let raw_esc = r"a\tb\nc"
    assert(raw_esc.len() == 7, "raw escape literal length")

    print("raw_string: all tests passed")
}
