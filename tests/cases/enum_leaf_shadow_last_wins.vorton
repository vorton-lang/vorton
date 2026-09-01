// B-107 verdict (2026-07-31): bare enum-leaf ctor sharing keeps main-parity
// last-wins shadow semantics — the bare spelling binds the ctor of the LAST
// declared enum. This locks the current single-file behaviour surface:
// bare = last declaration, plus qualified addressing on the winning side.
// (Qualified addressing of the SHADOWED side in a single file is still
// misresolved by the legacy path on main; the plan pipeline already fixes
// it in project mode — locked by
// tests/cases/modules/project_namespace_same_frame_enum_leaf_shadow.)
// NOTE: if the language later tightens silent bare-name shadowing (open
// lang-design item), flip this case into a negative test (bare use of a
// duplicated leaf must become an ambiguity error) instead of deleting it.

enum First {
    Shared(Int),
    OnlyFirst
}

enum Second {
    Shared(Int),
    OnlySecond
}

fn main() {
    // Bare spelling binds Second::Shared (last declaration wins).
    let bare: Second = Shared(21)
    match bare {
        Second::Shared(n) => print(n),
        Second::OnlySecond => print(-2)
    }
    // Qualified member of the winning side stays addressable.
    let second: Second = Second::Shared(11)
    match second {
        Second::Shared(n) => print(n),
        Second::OnlySecond => print(-2)
    }
}
