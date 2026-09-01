fn main() {
    let mut xs: List<Int> = [1, 2, 3]
    // xs.push returns Unit (which is actually the receiver in ABI)
    // After fix, the Unit value should be null, not the receiver
    let u = xs.push(4)
    print("len=${xs.len()}")
    print("done")
}
