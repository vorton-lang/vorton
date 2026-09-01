// B-113: return in match arm expression position (llvm_diff parity)

fn find_name(id: Int) -> Str {
    match id {
        1 => return "alice"
        2 => "bob"
        _ => "unknown"
    }
}

fn nested(x: Int, y: Int) -> Str {
    match x {
        1 => match y {
            10 => return "one-ten"
            _ => "one-other"
        }
        _ => "other"
    }
}

fn first_positive(nums: List<Int>) -> Int {
    for n in nums {
        match n > 0 {
            true => return n
            false => {}
        }
    }
    0
}

fn main() {
    print(find_name(1))
    print(find_name(2))
    print(find_name(99))

    print(nested(1, 10))
    print(nested(1, 20))
    print(nested(5, 10))

    print(first_positive([-3, -1, 0, 4, 5]).to_str())
}
