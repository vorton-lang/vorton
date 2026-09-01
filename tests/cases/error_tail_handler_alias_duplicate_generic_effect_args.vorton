// Audit #258 negative: alias expansion can place conflicting generic labels
// inside one declared row and must not bypass parameter unification.

effect Slot<T> {
    fn get() -> T
}

effect alias ConflictingSlots = {Slot<Int>, Slot<Str>}

fn conflicting_alias_row() -> Int with {ConflictingSlots} {
    0
}

fn force_alias_row_merge() -> Int with {Slot<Int>} {
    conflicting_alias_row()
}

fn main() {}
