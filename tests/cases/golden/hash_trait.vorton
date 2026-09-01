fn show_hash_int<T: Hash>(x: T) -> Int {
    x.hash()
}

fn show_hash_str<T: Hash>(x: T) -> Int {
    x.hash()
}

fn main() {
    // Int hashing — deterministic (same input → same output)
    let h1 = show_hash_int(42)
    let h2 = show_hash_int(42)
    assert(h1 == h2, "Int hash must be deterministic")

    // Different ints should (almost certainly) produce different hashes
    let h3 = show_hash_int(0)
    let h4 = show_hash_int(1)
    assert(h3 != h4, "Different ints should hash differently")

    // Str hashing
    let h5 = show_hash_str("hello")
    let h6 = show_hash_str("hello")
    assert(h5 == h6, "Str hash must be deterministic")

    let h7 = show_hash_str("hello")
    let h8 = show_hash_str("world")
    assert(h7 != h8, "Different strings should hash differently")

    // Bool hashing
    let ht = show_hash_int(true)
    let hf = show_hash_int(false)
    assert(ht != hf, "true and false should hash differently")

    // Multi-bound: Hash + Eq
    print("hash_trait: all tests passed")
}
