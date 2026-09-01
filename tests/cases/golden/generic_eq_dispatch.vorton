fn my_contains<T: Eq>(xs: List<T>, item: T) -> Bool {
    for x in xs {
        if x == item { return true }
    }
    false
}

fn main() {
    // direct (concrete) string equality
    let a = "hello"
    let b = "hello"
    print("direct str ==: ${a == b}")          // true

    // generic Eq dispatch over strings
    print("generic str contains: ${my_contains(["a", "b"], "a")}")   // true
    print("generic str miss:     ${my_contains(["a", "b"], "z")}")   // false

    // generic Eq dispatch over ints
    print("generic int contains: ${my_contains([1, 2, 3], 2)}")      // true

    // builtin List.contains over strings
    let xs = ["x", "y"]
    print("builtin str contains: ${xs.contains("x")}")               // true
}
