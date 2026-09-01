// B-100 P1.3 adversarial: tuples as collection elements in HOF operations.
// Tests tuple creation, field access (.0, .1), and tuple destructuring
// inside map/filter/fold closures.

fn main() {
    // ── Tuple list with map extracting fields ──
    let pairs = [(1, "a"), (2, "b"), (3, "c")]

    // Extract first elements
    let firsts = pairs.map(fn(t) { t.0 })
    print("firsts_len=${firsts.len()}")          // firsts_len=3
    print("firsts_0=${firsts[0]}")               // firsts_0=1
    print("firsts_1=${firsts[1]}")               // firsts_1=2
    print("firsts_2=${firsts[2]}")               // firsts_2=3

    // Extract second elements
    let seconds = pairs.map(fn(t) { t.1 })
    print("seconds_0=${seconds[0]}")             // seconds_0=a
    print("seconds_1=${seconds[1]}")             // seconds_1=b
    print("seconds_2=${seconds[2]}")             // seconds_2=c

    // ── Filter by tuple field ──
    let big = pairs.filter(fn(t) { t.0 > 1 })
    print("big_len=${big.len()}")                // big_len=2
    print("big_0_val=${big[0].0}")               // big_0_val=2
    print("big_1_str=${big[1].1}")               // big_1_str=c

    // ── Fold over tuples ──
    let sum = pairs.fold(0, fn(acc, t) { acc + t.0 })
    print("tuple_sum=${sum}")                    // tuple_sum=6

    let concat = pairs.fold("", fn(acc, t) { "${acc}${t.1}" })
    print("tuple_concat=${concat}")              // tuple_concat=abc

    // ── Tuple with computed values ──
    let computed = [1, 2, 3].map(fn(x) { (x, x * x) })
    print("comp_0=${computed[0].0},${computed[0].1}")   // comp_0=1,1
    print("comp_1=${computed[1].0},${computed[1].1}")   // comp_1=2,4
    print("comp_2=${computed[2].0},${computed[2].1}")   // comp_2=3,9

    // ── Flat_map producing tuples ──
    let expanded = [1, 2].flat_map(fn(x) { [(x, "lo"), (x, "hi")] })
    print("exp_len=${expanded.len()}")           // exp_len=4
    print("exp_0=${expanded[0].0}-${expanded[0].1}")  // exp_0=1-lo
    print("exp_1=${expanded[1].0}-${expanded[1].1}")  // exp_1=1-hi
    print("exp_2=${expanded[2].0}-${expanded[2].1}")  // exp_2=2-lo
    print("exp_3=${expanded[3].0}-${expanded[3].1}")  // exp_3=2-hi

    // ── 3-tuple ──
    let triples = [(1, "x", true), (2, "y", false)]
    print("t3_0=${triples[0].0}")                // t3_0=1
    print("t3_1=${triples[0].1}")                // t3_1=x
    print("t3_2=${triples[0].2}")                // t3_2=true
    print("t3_3=${triples[1].2}")                // t3_3=false

    print("done")
}
