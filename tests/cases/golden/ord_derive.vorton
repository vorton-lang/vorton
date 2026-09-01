// B-100 P1.1 parity: Ord derive for enum + struct — derived ordering on
// enum variants and struct fields, comparison operators.

enum Priority {
    Low,
    Medium,
    High,
}

struct Version {
    major: Int,
    minor: Int,
}

fn max_priority(a: Priority, b: Priority) -> Priority {
    if a > b { a } else { b }
}

fn newer(a: Version, b: Version) -> Bool {
    a > b
}

fn main() {
    // Enum Ord: variant order matches declaration order
    print("low_lt_med=${Priority::Low < Priority::Medium}")
    print("med_lt_high=${Priority::Medium < Priority::High}")
    print("high_gt_low=${Priority::High > Priority::Low}")
    print("low_eq_low=${Priority::Low == Priority::Low}")

    // Max priority
    let m = max_priority(Priority::Low, Priority::High)
    let is_high = m == Priority::High
    print("max_is_high=${is_high}")

    // Struct Ord: field-by-field comparison
    let v1 = Version { major: 1, minor: 0 }
    let v2 = Version { major: 1, minor: 5 }
    let v3 = Version { major: 2, minor: 0 }
    print("v1_lt_v2=${v1 < v2}")
    print("v2_lt_v3=${v2 < v3}")
    print("v3_gt_v1=${v3 > v1}")
    print("v1_eq_v1=${v1 == v1}")

    // Newer check
    print("v2_newer_v1=${newer(v2, v1)}")
    print("v1_newer_v3=${newer(v1, v3)}")

    // Sort list of comparable ints (Ord via sort)
    let mut nums = [3, 1, 4, 1, 5, 9, 2, 6]
    nums.sort()
    print("sorted_first=${nums[0]}")
    print("sorted_last=${nums[nums.len() - 1]}")
}
