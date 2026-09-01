// #136 + #138 regression: LLVM backend method_to_runtime mapping completeness.
//
// Exercises method mappings that were previously either dead (mapped to
// non-existent runtime symbols) or missing (panic-stub fallback).  Each
// call must produce the correct output (verified via golden .expected snapshot).

fn test_map_is_empty() -> Str {
    let mut m = map_new()
    let e1 = m.is_empty()           // true (empty)
    m.insert("a", 1)
    let e2 = m.is_empty()           // false (one entry)
    "map_empty: ${e1} ${e2}"
}

fn test_set_is_empty() -> Str {
    let mut s: Set<Str> = set_new()
    let e1 = s.is_empty()
    s.insert("x")
    let e2 = s.is_empty()
    "set_empty: ${e1} ${e2}"
}

fn test_map_int_is_empty() -> Str {
    let mut m = map_new()
    let e1 = m.is_empty()
    m.insert(1, "one")
    let e2 = m.is_empty()
    "map_int_empty: ${e1} ${e2}"
}

fn test_set_int_is_empty() -> Str {
    let mut s: Set<Int> = set_new()
    let e1 = s.is_empty()
    s.insert(42)
    let e2 = s.is_empty()
    "set_int_empty: ${e1} ${e2}"
}

fn test_sb_line() -> Str {
    let mut sb = string_builder()
    sb.add("hello")
    sb.line(" world")
    sb.add("done")
    sb.to_str()
}

fn test_sb_add_int() -> Str {
    let mut sb = string_builder()
    sb.add("n=")
    sb.add_int(42)
    sb.to_str()
}

fn test_set_clear() -> Str {
    let mut s: Set<Str> = set_new()
    s.insert("a")
    s.insert("b")
    s.clear()
    "set_clear: len=${s.len()} empty=${s.is_empty()}"
}

fn test_set_int_clear() -> Str {
    let mut s: Set<Int> = set_new()
    s.insert(1)
    s.insert(2)
    s.clear()
    "set_int_clear: len=${s.len()} empty=${s.is_empty()}"
}

fn test_set_union() -> Str {
    let a: Set<Str> = set_from(["a", "b"])
    let b: Set<Str> = set_from(["b", "c"])
    let u = a.union(b)
    "set_union: len=${u.len()}"
}

fn test_set_int_union() -> Str {
    let a: Set<Int> = set_from([1, 2])
    let b: Set<Int> = set_from([2, 3])
    let u = a.union(b)
    "set_int_union: len=${u.len()}"
}

fn test_set_intersect() -> Str {
    let a: Set<Str> = set_from(["a", "b", "c"])
    let b: Set<Str> = set_from(["b", "c", "d"])
    let i = a.intersect(b)
    "set_intersect: len=${i.len()}"
}

fn test_set_int_intersect() -> Str {
    let a: Set<Int> = set_from([1, 2, 3])
    let b: Set<Int> = set_from([2, 3, 4])
    let i = a.intersect(b)
    "set_int_intersect: len=${i.len()}"
}

fn test_set_difference() -> Str {
    let a: Set<Str> = set_from(["a", "b", "c"])
    let b: Set<Str> = set_from(["b", "c", "d"])
    let d = a.difference(b)
    "set_difference: len=${d.len()}"
}

fn test_set_int_difference() -> Str {
    let a: Set<Int> = set_from([1, 2, 3])
    let b: Set<Int> = set_from([2, 3, 4])
    let d = a.difference(b)
    "set_int_difference: len=${d.len()}"
}

fn main() {
    print(test_map_is_empty())
    print(test_set_is_empty())
    print(test_map_int_is_empty())
    print(test_set_int_is_empty())
    print(test_sb_line())
    print(test_sb_add_int())
    print(test_set_clear())
    print(test_set_int_clear())
    print(test_set_union())
    print(test_set_int_union())
    print(test_set_intersect())
    print(test_set_int_intersect())
    print(test_set_difference())
    print(test_set_int_difference())
    print("done")
}
