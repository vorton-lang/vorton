// Test: mut<Int> and mut<Str> are distinct effects, not merged

struct Counter { value: Int }
struct Logger { log: Str }

fn update_counter(mut c: Counter) {
    c.value = c.value + 1
}

fn update_logger(mut l: Logger) {
    l.log = "${l.log}x"
}

fn update_both(mut c: Counter, mut l: Logger) {
    update_counter(c)
    update_logger(l)
}

fn main() {
    let mut c = Counter { value: 0 }
    let mut l = Logger { log: "" }
    update_both(c, l)
    assert(c.value == 1, "counter should be 1")
    assert(l.log == "x", "logger should have x")
    print("mut_effect_multi_type: all tests passed")
}
