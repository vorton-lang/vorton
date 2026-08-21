// Exact-none producer lattice plus the bounded S′ mutable-slot checkpoint.

struct Resource {
    id: Int
}

impl Drop for Resource {
    fn drop(self) {
        print("drop ${self.id}")
    }
}

fn if_choice(flag: Bool) {
    let chosen: Option<Resource> = if flag {
        some(Resource { id: 10 })
    } else {
        none
    }
    print(chosen.is_some())
}

fn match_choice(selector: Int) {
    let chosen: Option<Resource> = match selector {
        0 => none,
        _ => some(Resource { id: 20 })
    }
    print(chosen.is_some())
}

fn all_none(flag: Bool) {
    let chosen: Option<Resource> = if flag { none } else { none }
    print(chosen.is_none())
}

fn diverge_or_owned(flag: Bool) {
    let chosen: Option<Resource> = if flag {
        some(Resource { id: 30 })
    } else {
        panic("unreachable fixture branch")
    }
    print(chosen.is_some())
}

fn early_return(flag: Bool) {
    let chosen: Option<Resource> = if flag {
        some(Resource { id: 40 })
    } else {
        none
    }
    if flag { return }
    print(chosen.is_none())
}

fn option_none_var_only() {
    let mut wrapped: Option<Resource> = none
    print(wrapped.is_none())
}

// Mutation ordinals one and two must hit this same exact DefId.
fn option_reset_none() {
    let mut wrapped: Option<Resource> = none
    wrapped = some(Resource { id: 90 })
    wrapped = none
    print(wrapped.is_none())
}

fn option_resource_normal() {
    let mut wrapped: Option<Resource> = none
    wrapped = some(Resource { id: 50 })
    print(wrapped.is_some())
}

fn option_resource_early() {
    let mut wrapped: Option<Resource> = none
    wrapped = some(Resource { id: 51 })
    print("resource early")
    return
}

fn resource_map(id: Int) -> Map<Int, Resource> {
    let mut values: Map<Int, Resource> = map_new()
    values.insert(id, Resource { id: id })
    values
}

fn option_map_normal() {
    let mut wrapped: Option<Map<Int, Resource>> = none
    wrapped = some(resource_map(60))
    print(wrapped.is_some())
}

fn option_map_early() {
    let mut wrapped: Option<Map<Int, Resource>> = none
    wrapped = some(resource_map(61))
    print("map early")
    return
}

fn option_conditional(flag: Bool) {
    let mut wrapped: Option<Resource> = none
    if flag {
        wrapped = some(Resource { id: 70 })
    }
    print(wrapped.is_some())
}

fn option_loop(count: Int) {
    let mut wrapped: Option<Resource> = none
    let mut i = 0
    while i < count {
        wrapped = some(Resource { id: 80 + i })
        i = i + 1
    }
    print(wrapped.is_some())
}

fn option_fresh_bool_tail() -> Bool {
    let mut wrapped: Option<Resource> = none
    wrapped = some(Resource { id: 100 })
    true
}

fn option_nested_fresh_tail() -> Bool {
    let mut wrapped: Option<Resource> = none
    wrapped = some(Resource { id: 101 })
    {
        let local = "nested"
        true
    }
}

// Same spelling is not authority: both exact slots require their own W4/exit.
fn option_shadow() {
    let mut wrapped: Option<Resource> = none
    wrapped = some(Resource { id: 110 })
    {
        let mut wrapped: Option<Resource> = none
        wrapped = some(Resource { id: 111 })
        print(wrapped.is_some())
    }
    print(wrapped.is_some())
}

fn direct_some_control() {
    let wrapped = some(Resource { id: 120 })
    print(wrapped.is_some())
}

fn borrowed_str_block(value: Str) {
    {
        let mut wrapped: Option<Resource> = none
        value
    }
    print(value)
}

fn opaque_option(id: Int) -> Option<Resource> {
    some(Resource { id: id })
}

// A direct Call remains OPAQUE to the all-writes gate.  Normal S′ must reject
// this slot even though current ordinary call-return behavior is unchanged.
fn option_opaque_write_control() {
    let mut wrapped: Option<Resource> = none
    wrapped = opaque_option(140)
    print(wrapped.is_some())
}

fn option_cleanup_fail() -> Bool with {fail<Int>} {
    fail.raise(1)
}

fn option_catch_borrow() {
    let mut wrapped: Option<Resource> = none
    wrapped = some(Resource { id: 130 })
    let caught = option_cleanup_fail() catch {
        _ => wrapped.is_some()
    }
    print(caught)
    print(wrapped.is_some())
}

fn main() {
    if_choice(true)
    if_choice(false)
    match_choice(1)
    match_choice(0)
    all_none(true)
    all_none(false)
    diverge_or_owned(true)
    early_return(true)
    early_return(false)
    option_none_var_only()
    option_resource_normal()
    option_resource_early()
    option_map_normal()
    option_map_early()
    option_conditional(true)
    option_conditional(false)
    option_loop(0)
    option_loop(1)
    option_loop(3)
    option_reset_none()
    print(option_fresh_bool_tail())
    print(option_nested_fresh_tail())
    option_shadow()
    direct_some_control()
    borrowed_str_block("borrowed str")
    option_opaque_write_control()
    option_catch_borrow()
    print("done")
}
