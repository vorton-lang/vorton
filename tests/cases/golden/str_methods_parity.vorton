// B-100 P1.1 parity: string methods full coverage (ASCII-safe only).
// Non-ASCII edge cases may differ across platforms. Outputs must match the golden .expected.

fn main() {
    let s = "Hello, World!"

    // len
    print("len=${s.len()}")                           // len=13

    // contains
    print("contains_yes=${s.contains("World")}")      // contains_yes=true
    print("contains_no=${s.contains("xyz")}")         // contains_no=false

    // starts_with / ends_with
    print("starts=${s.starts_with("Hello")}")         // starts=true
    print("ends=${s.ends_with("!")}")                  // ends=true

    // to_upper / to_lower
    print("upper=${"abc".to_upper()}")                // upper=ABC
    print("lower=${"XYZ".to_lower()}")                // lower=xyz

    // trim (leading + trailing whitespace)
    print("trim=${"  hi  ".trim()}")                  // trim=hi

    // split
    let parts = "a,b,c".split(",")
    print("split_len=${parts.len()}")                 // split_len=3
    print("split_0=${parts[0]}")                      // split_0=a
    print("split_2=${parts[2]}")                      // split_2=c

    // join
    let joined = ["x", "y", "z"].join("-")
    print("join=${joined}")                           // join=x-y-z

    // replace
    print("replace=${"a-b-c".replace("-", "_")}")     // replace=a_b_c

    // slice
    print("slice=${s.slice(0, 5)}")                   // slice=Hello
    print("slice_mid=${s.slice(7, 12)}")              // slice_mid=World
}
