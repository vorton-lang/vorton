// A function field prevents automatic structural Eq derivation.
struct HashOnly {
    id: Int,
    callback: fn(Int) -> Int
}

impl Hash for HashOnly {
    fn hash(self) -> Int { self.id }
}

fn retain_both<T: Hash + Eq>(items: List<T>) -> List<T> {
    items
}

fn main() {
    // Registration happens while T is unresolved.  The later annotation
    // resolves Hash but not Eq; the HIR call must receive neither dictionary.
    let pending = retain_both([])
    let _typed: List<HashOnly> = pending
}
