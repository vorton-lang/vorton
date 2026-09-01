fn main() {
    // basic pad_end
    let s1 = "hi".pad_end(5, ".")
    assert(s1 == "hi...", "pad_end fills to length")

    // already long enough
    let s2 = "hello".pad_end(3, "x")
    assert(s2 == "hello", "pad_end no-op if already long")

    // pad_end with multi-char fill
    let s3 = "a".pad_end(6, "bc")
    assert(s3 == "abcbcb", "pad_end repeats fill pattern")

    // symmetry with pad_start
    let s4 = "42".pad_start(5, "0")
    let s5 = "42".pad_end(5, "0")
    assert(s4 == "00042", "pad_start works")
    assert(s5 == "42000", "pad_end works")

    print("str_pad_end: all tests passed")
}
