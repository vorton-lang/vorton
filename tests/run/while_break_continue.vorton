// B-100 P1.1 parity: while/break/continue — basic while loops, nested while,
// break exits inner loop only, continue skips iteration.

fn main() {
    // Basic while loop
    let mut i = 0
    let mut sum = 0
    while i < 5 {
        sum += i
        i += 1
    }
    print("while_sum=${sum}")

    // While with break
    let mut j = 0
    let mut break_sum = 0
    while true {
        if j == 5 { break }
        break_sum += j
        j += 1
    }
    print("break_sum=${break_sum}")

    // While with continue
    let mut k = 0
    let mut cont_sum = 0
    while k < 10 {
        k += 1
        if k == 3 { continue }
        if k == 7 { continue }
        cont_sum += k
    }
    print("cont_sum=${cont_sum}")

    // Nested while — break only exits inner loop
    let mut outer_count = 0
    let mut inner_total = 0
    let mut oi = 0
    while oi < 3 {
        let mut oj = 0
        while oj < 10 {
            if oj == 3 { break }
            inner_total += 1
            oj += 1
        }
        outer_count += 1
        oi += 1
    }
    print("outer=${outer_count}")
    print("inner=${inner_total}")

    // Continue in outer, break in inner
    let mut total = 0
    let mut x = 0
    while x < 5 {
        x += 1
        if x == 3 { continue }
        let mut y = 0
        while y < 3 {
            y += 1
            total += 1
        }
    }
    print("nested_total=${total}")
}
