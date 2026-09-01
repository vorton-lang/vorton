// B-087 (B-088 hedged #2): a tuple match arm with a LITERAL element, e.g. (0, s),
// must compare that element against the literal. The LLVM tuple-pattern lowering
// only tag-checked Constructor/NamedConstructor sub-patterns and skipped Literal
// ones, so (0, s) matched ANY first element and every arm collapsed to the first
// literal arm. Fixed: Phase 1 of the tuple-pattern check now emits a literal compare
// (gen_literal_pattern_cond) for Literal elements too.

fn classify(t: (Int, Str)) -> Str {
    match t {
        (0, s) => "zero:${s}",
        (1, s) => "one:${s}",
        (n, s) => "other:${n}:${s}",
    }
}

// literal in the second position + bool/str literals
fn pair_kind(p: (Str, Bool)) -> Str {
    match p {
        ("yes", true)  => "yt",
        ("yes", false) => "yf",
        (other, b)     => "${other}:${b}",
    }
}

fn main() {
    print(classify((0, "a")))      // zero:a
    print(classify((1, "b")))      // one:b
    print(classify((5, "c")))      // other:5:c

    print(pair_kind(("yes", true)))    // yt
    print(pair_kind(("yes", false)))   // yf
    print(pair_kind(("no", true)))     // no:true
}
