// B-100 P1.1 parity: for-range variants — exclusive range, inclusive range,
// for-in with continue, for over map with destructuring.

fn main() {
    // Exclusive range 0..5
    let mut sum = 0
    for i in 0..5 {
        sum += i
    }
    print("exclusive=${sum}")

    // Inclusive range 1..=5
    let mut isum = 0
    for i in 1..=5 {
        isum += i
    }
    print("inclusive=${isum}")

    // Inclusive range 0..=0 (single element)
    let mut single = 0
    for i in 0..=0 {
        single += 1
    }
    print("single=${single}")

    // For-in with continue
    let mut csum = 0
    for x in 0..10 {
        if x == 3 { continue }
        if x == 7 { continue }
        csum += x
    }
    print("continue_sum=${csum}")

    // For over list
    let items = [10, 20, 30, 40]
    let mut lsum = 0
    for item in items {
        lsum += item
    }
    print("list_sum=${lsum}")

    // For over map with destructuring
    let m = map_from([(1, "one"), (2, "two"), (3, "three")])
    let mut key_total = 0
    for (k, v) in m {
        key_total += k
    }
    print("map_keys=${key_total}")

    // Nested for loops
    let mut nested = 0
    for i in 0..3 {
        for j in 0..4 {
            nested += 1
        }
    }
    print("nested=${nested}")

    // For range with break
    let mut bsum = 0
    for i in 0..100 {
        if i == 5 { break }
        bsum += i
    }
    print("break_sum=${bsum}")
}
