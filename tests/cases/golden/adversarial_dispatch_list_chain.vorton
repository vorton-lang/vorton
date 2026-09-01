// B-100 P1.3 adversarial: List operation chains — map/filter/fold combinations.
// Tests intermediate list creation and drop in chained HOF calls.
// Also tests: map.filter vs filter.map equivalence, nested map, flat_map chains.

fn main() {
    // ── map then filter ──
    let r1 = [1, 2, 3, 4, 5, 6]
        .map(fn(x) { x * 2 })
        .filter(fn(x) { x > 6 })
    print("mf_len=${r1.len()}")                // mf_len=3
    print("mf_0=${r1[0]}")                     // mf_0=8
    print("mf_1=${r1[1]}")                     // mf_1=10
    print("mf_2=${r1[2]}")                     // mf_2=12

    // ── filter then map ──
    let r2 = [1, 2, 3, 4, 5, 6]
        .filter(fn(x) { x > 3 })
        .map(fn(x) { x * 2 })
    print("fm_len=${r2.len()}")                // fm_len=3
    print("fm_0=${r2[0]}")                     // fm_0=8
    print("fm_1=${r2[1]}")                     // fm_1=10
    print("fm_2=${r2[2]}")                     // fm_2=12

    // ── map.map (double transform) ──
    let r3 = [1, 2, 3]
        .map(fn(x) { x + 10 })
        .map(fn(x) { x * 2 })
    print("mm_0=${r3[0]}")                     // mm_0=22
    print("mm_1=${r3[1]}")                     // mm_1=24
    print("mm_2=${r3[2]}")                     // mm_2=26

    // ── filter.filter ──
    let r4 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        .filter(fn(x) { x % 2 == 0 })
        .filter(fn(x) { x > 4 })
    print("ff_len=${r4.len()}")                // ff_len=3
    print("ff_0=${r4[0]}")                     // ff_0=6

    // ── map.filter.fold ──
    let r5 = [1, 2, 3, 4, 5]
        .map(fn(x) { x * x })
        .filter(fn(x) { x > 4 })
        .fold(0, fn(acc, x) { acc + x })
    print("mff=${r5}")                         // mff=50

    // ── flat_map chain ──
    let r6 = [1, 2, 3]
        .flat_map(fn(x) { [x, x * 10] })
    print("fm6_len=${r6.len()}")               // fm6_len=6
    print("fm6_0=${r6[0]}")                    // fm6_0=1
    print("fm6_1=${r6[1]}")                    // fm6_1=10
    print("fm6_2=${r6[2]}")                    // fm6_2=2
    print("fm6_3=${r6[3]}")                    // fm6_3=20

    // ── flat_map then filter ──
    let r7 = [1, 2, 3]
        .flat_map(fn(x) { [x, x * 10] })
        .filter(fn(x) { x >= 10 })
    print("fmf_len=${r7.len()}")               // fmf_len=3
    print("fmf_0=${r7[0]}")                    // fmf_0=10
    print("fmf_1=${r7[1]}")                    // fmf_1=20
    print("fmf_2=${r7[2]}")                    // fmf_2=30

    // ── string list chain ──
    let words = ["hello", "world", "foo"]
        .map(fn(s) { s.to_upper() })
        .filter(fn(s) { s.len() > 3 })
    print("sw_len=${words.len()}")             // sw_len=2
    print("sw_0=${words[0]}")                  // sw_0=HELLO
    print("sw_1=${words[1]}")                  // sw_1=WORLD

    // ── find after map ──
    let found = [1, 2, 3, 4, 5]
        .map(fn(x) { x * 3 })
        .find(fn(x) { x > 10 })
    print("find_map=${found.unwrap_or(-1)}")   // find_map=12

    // ── any/all after filter ──
    let has_big = [1, 2, 3, 4, 5]
        .filter(fn(x) { x > 2 })
        .any(fn(x) { x == 4 })
    print("any_filter=${has_big}")             // any_filter=true

    let all_pos = [1, 2, 3, 4, 5]
        .filter(fn(x) { x > 0 })
        .all(fn(x) { x < 100 })
    print("all_filter=${all_pos}")             // all_filter=true

    print("done")
}
