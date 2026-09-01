// Regression test for I10: tuple exhaustiveness must check cross-column combinations
// (true, true) + (false, false) does NOT cover (true, false) or (false, true)
fn main() {
    let x: (Bool, Bool) = (true, false)
    let result = match x {
        (true, true) => "tt",
        (false, false) => "ff",
    }
    print(result)
}
