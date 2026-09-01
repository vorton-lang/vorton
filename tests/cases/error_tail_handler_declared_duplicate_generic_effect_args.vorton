// Audit #258 negative: duplicate generic labels inside one declared effect row
// must agree before name-based row deduplication.

effect Slot<T> {
    fn get() -> T
}

fn conflicting_declared_row() -> Int with {Slot<Int>, Slot<Str>} {
    0
}

fn force_declared_row_merge() -> Int with {Slot<Int>} {
    conflicting_declared_row()
}

fn main() {}
