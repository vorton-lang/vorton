// Compile-only structural fixture. No function accepting StructuralRawHandle is
// ever executed: the generated C is the oracle for foreign-handle RC exclusion.

extern type StructuralRawHandle

struct StructuralHolder {
    raw: StructuralRawHandle,
    owned: Str
}

enum StructuralChoice {
    Raw(StructuralRawHandle),
    Owned(Str)
}

fn structural_raw_identity(value: StructuralRawHandle) -> StructuralRawHandle {
    let local = value
    local
}

fn structural_owned_identity(value: Str) -> Str {
    let local = value
    local
}

fn structural_raw_option(value: StructuralRawHandle) {
    let wrapped = some(value)
}

fn structural_owned_option(value: Str) {
    let wrapped = some(value)
}

fn structural_raw_list(value: StructuralRawHandle) {
    let mut values: List<StructuralRawHandle> = []
    values.push(value)
}

fn structural_owned_list(value: Str) {
    let mut values: List<Str> = []
    values.push(value)
}

fn main() {
    // Intentionally empty: raw foreign handles cannot be fabricated safely.
}
