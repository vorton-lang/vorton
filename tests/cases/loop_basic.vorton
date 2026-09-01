fn main() {
    let mut count = 0
    loop {
        count = count + 1
        if count == 5 { break }
    }
    assert(count == 5, "loop with break")

    let mut sum = 0
    let mut i = 0
    loop {
        i = i + 1
        if i > 10 { break }
        if i % 2 == 0 { continue }
        sum = sum + i
    }
    assert(sum == 25, "loop with continue: 1+3+5+7+9")

    print("loop_basic: all tests passed")
}
