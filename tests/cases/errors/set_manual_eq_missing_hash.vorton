struct ManualEqOnly {
    id: Int
}

impl Eq for ManualEqOnly {
    fn eq(self, other: ManualEqOnly) -> Bool {
        self.id == other.id
    }
}

fn main() {
    let mut values: Set<ManualEqOnly> = set_new()
    values.insert(ManualEqOnly { id: 1 })
}
