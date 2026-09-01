// Regression test for audit #92: effects_match_kind must compare MutEffect state_type
// mut<List<Int>> and mut<List<Str>> are distinct effects and must not be matched
// during unification (effects_match_kind must use types_equal, not just variant match)

fn push_int(mut list: List<Int>) {
    list.push(1)
}

fn push_str(mut list: List<Str>) {
    list.push("hello")
}

fn both_mutations(mut ints: List<Int>, mut strs: List<Str>) {
    push_int(ints)
    push_str(strs)
}

fn main() {
    let mut a: List<Int> = []
    let mut b: List<Str> = []
    both_mutations(a, b)
    assert(a.len() == 1, "ints should have 1 element")
    assert(b.len() == 1, "strs should have 1 element")
    print("mut effect multi match: ok")
}
