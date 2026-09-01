// B-104 D1 Stage 2 regression: SET-ITERATION conversion temporary.
//
// Set.iter converts the Map-backed Set to a fresh key List (fresh list and
// fresh element copies) that Perceus owns and drops at loop exit. What this
// pins:
//   * the conversion list + elements are released exactly once — a double
//     release (or dropping while body borrows are live) crashes natively;
//   * element ESCAPES out of the loop (push into an outer list) are
//     Clone-wrapped and must survive the merge-point drop — the escaped
//     values are re-read after the loop (the expected output pins them);
//   * `break` routes through merge (the drop still runs — no crash on
//     re-iteration);
//   * both heap-valued Str sets and immediate Int sets.

fn main() {
    let mut s: Set<Str> = set_new()
    s.insert("b")
    s.insert("a")
    s.insert("c")

    // Plain iteration; element escapes into an outer container (re-read after
    // the loop — must survive the conversion-temp drop).  Order-independent
    // assertions (set iteration order differs across backends).
    let mut got: List<Str> = []
    let mut joined_len = 0
    for v in s {
        got.push(v)
        joined_len = joined_len + v.len()
    }
    let has_all = got.contains("a") && got.contains("b") && got.contains("c")
    print("got=${got.len()} chars=${joined_len} all=${has_all}")

    // Iterate the same set again (the set itself must be untouched by the
    // conversion drop).
    let mut count = 0
    for v in s {
        count = count + 1
    }
    print("count=${count}")

    // break path: the conversion temp still drops at merge.
    let mut first = ""
    for v in s {
        first = v
        break
    }
    print("first-nonempty=${first.len() > 0}")

    // Int set (immediate element path).
    let mut si: Set<Int> = set_new()
    si.insert(3)
    si.insert(1)
    let mut sum = 0
    for n in si {
        sum = sum + n
    }
    print("sum=${sum}")
}
