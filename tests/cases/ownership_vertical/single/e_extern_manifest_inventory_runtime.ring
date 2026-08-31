fn ascending(left: Int, right: Int) -> Int with {} {
    left - right
}

fn main() {
    let source: Ptr<Int> = ring_slot_alloc(2)
    let destination: Ptr<Int> = ring_slot_alloc(1)
    ring_slot_write(source, 0, 10)
    ring_slot_write(source, 1, 20)
    assert(ring_slot_read(source, 0) == 10, "slot read")
    ring_slot_replace(source, 0, 11)
    ring_slot_swap(source, 0, 1)
    ring_slot_move(source, 0, destination, 0, 1)
    assert(ring_slot_take(source, 1) == 11, "slot take")
    ring_slot_drop(destination, 0)
    ring_slot_dealloc(source, 2)
    ring_slot_dealloc(destination, 1)

    let values = [3, 1, 2]
    ring_list_sort_bridge(values, ascending)
    assert(values[0] == 1 && values[1] == 2 && values[2] == 3,
        "list sort bridge")
    print("E_EXTERN_MANIFEST_10_OF_10_OK")
}
