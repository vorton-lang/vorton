fn my_contains<T: Eq>(xs: List<T>, item: T) -> Bool {
    for x in xs {
        if x == item { return true }
    }
    false
}

fn main() {
    let xs = ["a", "b", "c", "d"]
    print("builtin idx0 (a): ${xs.contains("a")}")   // true
    print("builtin idx2 (c): ${xs.contains("c")}")   // true
    print("builtin idx3 (d): ${xs.contains("d")}")   // true
    print("builtin miss (z): ${xs.contains("z")}")   // false

    print("generic idx3 (d): ${my_contains(xs, "d")}")  // true
}
