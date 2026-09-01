struct Resource {
    id: Int,
    payload: Str
}

impl Drop for Resource {
    fn drop(self) {}
}

struct Pair {
    value: Resource,
    count: Int
}

fn observe(value: Resource) -> Int { value.id }

fn main() {
    let direct = some(Resource { id: 1, payload: "direct" })
    let direct_score = match direct {
        some(value) => observe(value) + value.id,
        none => 0
    }

    let nested = some((2, Resource { id: 3, payload: "nested" }))
    let nested_score = match nested {
        some((count, value)) => count + observe(value) + value.id,
        none => 0
    }

    let pair = Pair {
        value: Resource { id: 5, payload: "struct" },
        count: 4
    }
    let pair_score = match pair {
        Pair { value, count } => count + observe(value) + value.id
    }

    let score = direct_score + nested_score + pair_score
    assert(score == 24, "pattern projection binding ownership")
    print("B_PATTERN_PROJECTION_OK:${score}")
}
