// B-100 P1.3 adversarial: empty collection operations.
// Empty List/Map/Set edge cases — methods that return Option, Bool, or new collections.

fn main() {
    // ── Empty List ──
    let empty: List<Int> = []
    print("empty_len=${empty.len()}")                    // empty_len=0
    print("empty_is_empty=${empty.is_empty()}")          // empty_is_empty=true

    // HOFs on empty list
    let mapped = empty.map(fn(x) { x * 2 })
    print("empty_map_len=${mapped.len()}")               // empty_map_len=0

    let filtered = empty.filter(fn(x) { x > 0 })
    print("empty_filter_len=${filtered.len()}")          // empty_filter_len=0

    let found = empty.find(fn(x) { x == 1 })
    print("empty_find_none=${found.is_none()}")          // empty_find_none=true

    let any_result = empty.any(fn(x) { x > 0 })
    print("empty_any=${any_result}")                     // empty_any=false

    let all_result = empty.all(fn(x) { x > 0 })
    print("empty_all=${all_result}")                     // empty_all=true

    let fold_result = empty.fold(99, fn(acc, x) { acc + x })
    print("empty_fold=${fold_result}")                   // empty_fold=99

    let flat_mapped = empty.flat_map(fn(x) { [x, x] })
    print("empty_flat_map_len=${flat_mapped.len()}")     // empty_flat_map_len=0

    // get on empty
    let got = empty.get(0)
    print("empty_get_none=${got.is_none()}")             // empty_get_none=true

    // first/last on empty
    let first = empty.first()
    print("empty_first_none=${first.is_none()}")         // empty_first_none=true
    let last = empty.last()
    print("empty_last_none=${last.is_none()}")           // empty_last_none=true

    // ── Empty Str ──
    let s = ""
    print("empty_str_len=${s.len()}")                    // empty_str_len=0
    print("empty_str_is_empty=${s.is_empty()}")          // empty_str_is_empty=true
    let parts = s.split(",")
    print("empty_str_split_len=${parts.len()}")          // empty_str_split_len=1
    print("empty_str_split_0=${parts[0]}")               // empty_str_split_0=

    // ── Empty Map ──
    let m: Map<Str, Int> = map_new()
    print("empty_map_len=${m.len()}")                    // empty_map_len=0
    print("empty_map_is_empty=${m.is_empty()}")          // empty_map_is_empty=true
    let mkeys = m.keys()
    print("empty_map_keys_len=${mkeys.len()}")           // empty_map_keys_len=0
    let mentries = m.entries()
    print("empty_map_entries_len=${mentries.len()}")     // empty_map_entries_len=0
    let mget = m.get("x")
    print("empty_map_get_none=${mget.is_none()}")        // empty_map_get_none=true
    print("empty_map_contains=${m.contains_key("x")}")   // empty_map_contains=false

    // ── Empty Set ──
    let es: Set<Int> = set_new()
    print("empty_set_len=${es.len()}")                   // empty_set_len=0
    print("empty_set_is_empty=${es.is_empty()}")         // empty_set_is_empty=true
    let es_list = es.to_list()
    print("empty_set_to_list_len=${es_list.len()}")      // empty_set_to_list_len=0

    // Set ops on empty sets
    let es2: Set<Int> = set_new()
    let u = es.union(es2)
    print("empty_union_len=${u.len()}")                  // empty_union_len=0
    let i = es.intersect(es2)
    print("empty_intersect_len=${i.len()}")              // empty_intersect_len=0
    let d = es.difference(es2)
    print("empty_diff_len=${d.len()}")                   // empty_diff_len=0

    print("done")
}
