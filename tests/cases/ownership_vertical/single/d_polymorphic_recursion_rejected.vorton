fn polymorphic_cycle<T>(value: T, remaining: Int) -> Int {
    if remaining == 0 {
        0
    } else {
        polymorphic_cycle([value], remaining - 1)
    }
}

fn main() {
    let result = polymorphic_cycle(1, 1)
    assert(result == 0, "unreachable when polymorphic recursion is rejected")
}
