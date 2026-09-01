// B-107/B-152 P4: manual Eq + Hash remains usable, including deliberate
// collision chains and Map-backed Set growth/rehash.

struct CollisionKey {
    id: Int,
    label: Str
}

impl Eq for CollisionKey {
    fn eq(self, other: CollisionKey) -> Bool {
        self.id == other.id
    }
}

impl Hash for CollisionKey {
    fn hash(self) -> Int {
        1
    }
}

fn key(id: Int, label: Str) -> CollisionKey {
    CollisionKey { id: id, label: label }
}

fn main() {
    let mut growing: Set<CollisionKey> = set_new()
    for i in 0..96 {
        growing.insert(key(i, "first-${i}"))
    }
    for i in 0..96 {
        growing.insert(key(i, "duplicate-${i}"))
    }
    assert(growing.len() == 96, "colliding equal keys deduplicate after growth")
    assert(growing.contains(key(0, "lookup")), "first collision-chain key found")
    assert(growing.contains(key(95, "lookup")), "last collision-chain key found")

    for i in 0..48 {
        growing.remove(key(i, "remove"))
    }
    assert(growing.len() == 48, "collision-chain removal updates length")
    assert(!growing.contains(key(0, "removed")), "removed key stays absent")
    assert(growing.contains(key(95, "kept")), "remaining key survives tombstones")

    let mut left: Set<CollisionKey> = set_new()
    let mut right: Set<CollisionKey> = set_new()
    for i in 0..64 {
        left.insert(key(i, "left"))
    }
    for i in 32..96 {
        right.insert(key(i, "right"))
    }
    let unioned = left.union(right)
    let intersected = left.intersect(right)
    let differenced = left.difference(right)
    assert(unioned.len() == 96, "union across collision-heavy sets")
    assert(intersected.len() == 32, "intersection across collision-heavy sets")
    assert(differenced.len() == 32, "difference across collision-heavy sets")
    assert(unioned.contains(key(95, "probe")), "union lookup uses manual Hash+Eq")
    assert(intersected.contains(key(40, "probe")), "intersection lookup uses manual Hash+Eq")
    assert(differenced.contains(key(10, "probe")), "difference lookup uses manual Hash+Eq")

    let mut map: Map<CollisionKey, Int> = map_new()
    for i in 0..80 {
        map.insert(key(i, "map"), i * 10)
    }
    match map.get(key(79, "lookup")) {
        some(value) => assert(value == 790, "manual Hash+Eq Map get after rehash"),
        none => assert(false, "manual Hash+Eq Map key missing"),
    }

    print("set_hash_collision_rehash: all tests passed")
}
