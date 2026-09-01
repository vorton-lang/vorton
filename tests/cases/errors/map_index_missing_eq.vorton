// A function field prevents the automatic structural Eq derivation.
struct HashOnlyKey {
    id: Int,
    callback: fn(Int) -> Int
}

impl Hash for HashOnlyKey {
    fn hash(self) -> Int { self.id }
}

fn main() {
    let m: Map<HashOnlyKey, Int> = map_new()
    print(m[HashOnlyKey { id: 1, callback: fn(x) { x } }])
}
