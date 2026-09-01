// B-100 P1.3 R3 adversarial: type aliases with generics — aliases used in
// function signatures, nested aliases, generic aliases with multiple type params.
//
// Exercises:
//   * Simple alias used in function params and return types
//   * Generic alias (MaybeVal<T>) in function signatures
//   * Alias for complex generic type (List<(T, T)>)
//   * Alias used with trait bounds
//   * Multiple aliases in same function

type Pair<T> = (T, T)

type IntPair = Pair<Int>

type StrPair = Pair<Str>

type MaybeVal<T> = Option<T>

type IntList = List<Int>

type StrList = List<Str>

fn swap_pair<T>(p: Pair<T>) -> Pair<T> {
    let (a, b) = p
    (b, a)
}

fn sum_int_pair(p: IntPair) -> Int {
    let (a, b) = p
    a + b
}

fn join_str_pair(p: StrPair, sep: Str) -> Str {
    let (a, b) = p
    "${a}${sep}${b}"
}

fn unwrap_maybe<T>(m: MaybeVal<T>, default: T) -> T {
    m.unwrap_or(default)
}

fn sum_int_list(xs: IntList) -> Int {
    let mut total = 0
    for x in xs {
        total = total + x
    }
    total
}

fn join_str_list(xs: StrList, sep: Str) -> Str {
    let mut result = ""
    for s in xs {
        if result == "" {
            result = s
        } else {
            result = "${result}${sep}${s}"
        }
    }
    result
}

// Function using multiple aliases
fn process(pair: IntPair, extra: MaybeVal<Int>) -> Int {
    let base = sum_int_pair(pair)
    let bonus = unwrap_maybe(extra, 0)
    base + bonus
}

fn main() {
    // swap_pair with ints
    let p1: IntPair = (10, 20)
    let swapped = swap_pair(p1)
    let (a, b) = swapped
    print("swap_int=${a},${b}")

    // swap_pair with strings
    let p2: StrPair = ("hello", "world")
    let swapped2 = swap_pair(p2)
    let (sa, sb) = swapped2
    print("swap_str=${sa},${sb}")

    // sum_int_pair
    print("sum_pair=${sum_int_pair((3, 7))}")

    // join_str_pair
    print("join=${join_str_pair(("foo", "bar"), "-")}")

    // unwrap_maybe
    let m1: MaybeVal<Int> = some(42)
    let m2: MaybeVal<Int> = none
    print("unwrap_some=${unwrap_maybe(m1, 0)}")
    print("unwrap_none=${unwrap_maybe(m2, 0)}")

    // sum_int_list
    let xs: IntList = [1, 2, 3, 4, 5]
    print("sum_list=${sum_int_list(xs)}")

    // join_str_list
    let words: StrList = ["a", "b", "c"]
    print("join_list=${join_str_list(words, ",")}")

    // process (multiple aliases)
    print("process1=${process((10, 20), some(5))}")
    print("process2=${process((10, 20), none)}")
}
