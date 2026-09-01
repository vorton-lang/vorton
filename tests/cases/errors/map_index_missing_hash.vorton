struct EqOnlyKey { id: Int }

impl Eq for EqOnlyKey {
    fn eq(self, other: EqOnlyKey) -> Bool { self.id == other.id }
}

fn main() {
    let m: Map<EqOnlyKey, Int> = map_new()
    print(m[EqOnlyKey { id: 1 }])
}
