// B-152 P3: Map<K, V> — pure Ring struct (replaces pub extern type Map<K, V>)
//
// Layout: { meta: Ptr<Int>, keys: Ptr<K>, values: Ptr<V>, len: Int, cap: Int }
// Open-addressing hash table with linear probing + tombstone deletion.
// meta byte values: 0=empty, 1=occupied, 2=tombstone
// RC semantics (same bridge pattern as List<T>):
//   - ring_slot_read = peek + dup (map keeps ref, caller gets ref)
//   - ring_slot_take = move out (slot set to null, caller owns)
//   - ring_slot_write = direct store (arg 2 transfers ownership to the slot)
//   - ring_slot_replace = borrowed input (dup before store, then drop old)
//   - ring_slot_drop = take + ring_drop (release element)

pub struct Map<K, V> {
    pub meta: Ptr<Int>
    pub keys: Ptr<K>
    pub values: Ptr<V>
    pub len: Int
    pub cap: Int
}

// Bridge functions (C ABI, implemented in ring_runtime.cpp)
extern fn ring_slot_alloc<T>(count: Int) -> Ptr<T>
extern fn ring_slot_dealloc<T>(buf: Ptr<T>, count: Int) -> Unit
extern fn ring_slot_read<T>(buf: Ptr<T>, idx: Int) -> T
extern fn ring_slot_take<T>(buf: Ptr<T>, idx: Int) -> T
extern fn ring_slot_write<T>(buf: Ptr<T>, idx: Int, val: T) -> Unit
extern fn ring_slot_replace<T>(buf: Ptr<T>, idx: Int, val: T) -> Unit
extern fn ring_slot_drop<T>(buf: Ptr<T>, idx: Int) -> Unit
extern fn ring_buf_alloc(cap: Int) -> Ptr<Int>
extern fn ring_buf_dealloc(p: Ptr<Int>) -> Unit
extern fn ring_buf_get_byte(p: Ptr<Int>, offset: Int) -> Int
extern fn ring_buf_set_byte(p: Ptr<Int>, offset: Int, val: Int) -> Unit

extern fn ring_buf_alloc_zeroed(cap: Int) -> Ptr<Int>

pub fn map_new<K, V>() -> Map<K, V> {
    // Start with the 8-slot minimum used by open addressing and later growth.
    // Use ring_buf_alloc_zeroed instead of a while loop to avoid mut effect leak.
    Map {
        meta: ring_buf_alloc_zeroed(8),
        keys: ring_slot_alloc(8),
        values: ring_slot_alloc(8),
        len: 0,
        cap: 8
    }
}

pub fn map_from<K: Hash + Eq, V>(entries: List<(K, V)>) -> Map<K, V> {
    let mut m: Map<K, V> = map_new()
    let mut i = 0
    while i < entries.len() {
        match entries.get(i) {
            some(pair) => {
                m.insert(pair.0, pair.1)
            },
            none => {},
        }
        i = i + 1
    }
    m
}

pub fn map_clone<K, V>(m: Map<K, V>) -> Map<K, V> {
    if m.len == 0 {
        return map_new()
    }
    let new_meta = ring_buf_alloc(m.cap)
    let new_keys: Ptr<K> = ring_slot_alloc(m.cap)
    let new_values: Ptr<V> = ring_slot_alloc(m.cap)
    let mut i = 0
    while i < m.cap {
        let meta = ring_buf_get_byte(m.meta, i)
        ring_buf_set_byte(new_meta, i, meta)
        if meta == 1 {
            let k = ring_slot_read(m.keys, i)
            let v = ring_slot_read(m.values, i)
            ring_slot_write(new_keys, i, k)
            ring_slot_write(new_values, i, v)
        }
        i = i + 1
    }
    Map { meta: new_meta, keys: new_keys, values: new_values, len: m.len, cap: m.cap }
}

fn map_deep_clone<K: Clone, V: Clone>(m: Map<K, V>) -> Map<K, V> {
    if m.len == 0 { return map_new() }
    let new_meta = ring_buf_alloc(m.cap)
    let new_keys: Ptr<K> = ring_slot_alloc(m.cap)
    let new_values: Ptr<V> = ring_slot_alloc(m.cap)
    let mut i = 0
    while i < m.cap {
        let meta = ring_buf_get_byte(m.meta, i)
        ring_buf_set_byte(new_meta, i, meta)
        if meta == 1 {
            let key = ring_slot_read(m.keys, i)
            let value = ring_slot_read(m.values, i)
            ring_slot_write(new_keys, i, key.clone())
            ring_slot_write(new_values, i, value.clone())
        }
        i = i + 1
    }
    Map {
        meta: new_meta, keys: new_keys, values: new_values,
        len: m.len, cap: m.cap
    }
}

impl<K: Clone, V: Clone> Clone for Map<K, V> {
    fn clone(self: Map<K, V>) -> Map<K, V> { map_deep_clone(self) }
}

// Panic-on-miss subscript access (used by codegen for m[key] IndexExpr)
pub fn map_get_panic<K: Hash + Eq, V>(m: Map<K, V>, key: K) -> V {
    if m.cap == 0 {
        panic("ring panic: map key not found")
    }
    let idx = map_probe_index(m, key)
    if idx < 0 || ring_buf_get_byte(m.meta, idx) != 1 {
        panic("ring panic: map key not found")
    }
    ring_slot_read(m.values, idx)
}

// Probe: find slot index for key. Returns index of matching occupied slot,
// or first insertable slot (empty/tombstone) if key not found.
// Returns -1 if cap == 0.
// Caller checks ring_buf_get_byte(m.meta, idx) == 1 to distinguish hit/miss.
fn map_probe_index<K: Hash + Eq, V>(m: Map<K, V>, key: K) -> Int {
    if m.cap == 0 { return 0 - 1 }
    let h = key.hash()
    let mut idx = h % m.cap
    if idx < 0 { idx = idx + m.cap }
    let mut first_tombstone = 0 - 1
    let mut guard = 0
    while guard < m.cap {
        let meta = ring_buf_get_byte(m.meta, idx)
        if meta == 0 {
            // Empty: key doesn't exist
            return if first_tombstone >= 0 { first_tombstone } else { idx }
        }
        if meta == 2 {
            // Tombstone: record first insertable position
            if first_tombstone < 0 { first_tombstone = idx }
        }
        if meta == 1 {
            // Occupied: compare key
            let existing = ring_slot_read(m.keys, idx)
            if existing == key {
                return idx
            }
        }
        idx = (idx + 1) % m.cap
        guard = guard + 1
    }
    // Table is full of tombstones — return first tombstone
    if first_tombstone >= 0 { first_tombstone } else { idx }
}

// Methods that do NOT require Hash + Eq bounds
impl<K, V> Map {
    pub fn len(self: Map<K, V>) -> Int { self.len }

    pub fn is_empty(self: Map<K, V>) -> Bool { self.len == 0 }

    pub fn keys(self: Map<K, V>) -> List<K> {
        let mut result: List<K> = []
        let mut i = 0
        while i < self.cap {
            if ring_buf_get_byte(self.meta, i) == 1 {
                result.push(ring_slot_read(self.keys, i))
            }
            i = i + 1
        }
        result
    }

    pub fn values(self: Map<K, V>) -> List<V> {
        let mut result: List<V> = []
        let mut i = 0
        while i < self.cap {
            if ring_buf_get_byte(self.meta, i) == 1 {
                result.push(ring_slot_read(self.values, i))
            }
            i = i + 1
        }
        result
    }

    pub fn entries(self: Map<K, V>) -> List<(K, V)> {
        let mut result: List<(K, V)> = []
        let mut i = 0
        while i < self.cap {
            if ring_buf_get_byte(self.meta, i) == 1 {
                let k = ring_slot_read(self.keys, i)
                let v = ring_slot_read(self.values, i)
                result.push((k, v))
            }
            i = i + 1
        }
        result
    }

    pub fn clear(mut self: Map<K, V>) -> Unit {
        let mut i = 0
        while i < self.cap {
            if ring_buf_get_byte(self.meta, i) == 1 {
                ring_slot_drop(self.keys, i)
                ring_slot_drop(self.values, i)
                ring_buf_set_byte(self.meta, i, 0)
            }
            i = i + 1
        }
        self.len = 0
    }

    // Higher-order methods
    // NOTE: these use while loops to avoid introducing the `mut` effect
    // from the range iterator, which would leak into the closure parameter's
    // effect and cause effect mismatch errors.

    pub fn for_each(self: Map<K, V>, f: fn(K, V) -> Unit) -> Unit {
        let mut i = 0
        while i < self.cap {
            if ring_buf_get_byte(self.meta, i) == 1 {
                let k = ring_slot_read(self.keys, i)
                let v = ring_slot_read(self.values, i)
                f(k, v)
            }
            i = i + 1
        }
    }

    pub fn fold<U>(self: Map<K, V>, init: U, f: fn(U, K, V) -> U) -> U {
        let mut acc = init
        let mut i = 0
        while i < self.cap {
            if ring_buf_get_byte(self.meta, i) == 1 {
                let k = ring_slot_read(self.keys, i)
                let v = ring_slot_read(self.values, i)
                acc = f(acc, k, v)
            }
            i = i + 1
        }
        acc
    }

    pub fn any(self: Map<K, V>, pred: fn(K, V) -> Bool) -> Bool {
        let mut i = 0
        while i < self.cap {
            if ring_buf_get_byte(self.meta, i) == 1 {
                let k = ring_slot_read(self.keys, i)
                let v = ring_slot_read(self.values, i)
                if pred(k, v) { return true }
            }
            i = i + 1
        }
        false
    }
}

// Methods that REQUIRE Hash + Eq bounds on K
impl<K: Hash + Eq, V> Map {
    pub fn get(self: Map<K, V>, key: K) -> Option<V> {
        if self.cap == 0 { return none }
        let idx = map_probe_index(self, key)
        if idx < 0 { return none }
        if ring_buf_get_byte(self.meta, idx) == 1 {
            some(ring_slot_read(self.values, idx))
        } else {
            none
        }
    }

    pub fn contains_key(self: Map<K, V>, key: K) -> Bool {
        if self.cap == 0 { return false }
        let idx = map_probe_index(self, key)
        if idx < 0 { return false }
        ring_buf_get_byte(self.meta, idx) == 1
    }

    pub fn insert(mut self: Map<K, V>, key: K, value: V) -> Unit {
        // Ensure capacity — grow if load factor > 0.75
        if self.cap == 0 || self.len * 4 >= self.cap * 3 {
            // Grow the table
            let new_cap = if self.cap < 8 { 8 } else { self.cap * 2 }
            let new_meta = ring_buf_alloc(new_cap)
            let new_keys: Ptr<K> = ring_slot_alloc(new_cap)
            let new_values: Ptr<V> = ring_slot_alloc(new_cap)
            // Initialize meta to all 0 (empty)
            let mut gi = 0
            while gi < new_cap {
                ring_buf_set_byte(new_meta, gi, 0)
                gi = gi + 1
            }
            // Rehash old entries
            gi = 0
            while gi < self.cap {
                if ring_buf_get_byte(self.meta, gi) == 1 {
                    let rk = ring_slot_take(self.keys, gi)
                    let rv = ring_slot_take(self.values, gi)
                    let h = rk.hash()
                    let mut ri = h % new_cap
                    if ri < 0 { ri = ri + new_cap }
                    while ring_buf_get_byte(new_meta, ri) == 1 {
                        ri = (ri + 1) % new_cap
                    }
                    ring_buf_set_byte(new_meta, ri, 1)
                    ring_slot_write(new_keys, ri, rk)
                    ring_slot_write(new_values, ri, rv)
                }
                gi = gi + 1
            }
            // Dealloc old buffers by ownership, independent of logical capacity.
            ring_buf_dealloc(self.meta)
            ring_slot_dealloc(self.keys, self.cap)
            ring_slot_dealloc(self.values, self.cap)
            self.meta = new_meta
            self.keys = new_keys
            self.values = new_values
            self.cap = new_cap
        }
        // Probe and insert
        let idx = map_probe_index(self, key)
        if ring_buf_get_byte(self.meta, idx) == 1 {
            // Key exists: preserve the first inserted key.  The value input is
            // borrowed, so replace duplicates it before dropping the old slot
            // (including the self-assignment case).
            ring_slot_replace(self.values, idx, value)
        } else {
            // New entry
            ring_buf_set_byte(self.meta, idx, 1)
            ring_slot_write(self.keys, idx, key)
            ring_slot_write(self.values, idx, value)
            self.len = self.len + 1
        }
    }

    pub fn remove(mut self: Map<K, V>, key: K) -> Unit {
        if self.cap == 0 { return }
        let idx = map_probe_index(self, key)
        if idx < 0 { return }
        if ring_buf_get_byte(self.meta, idx) == 1 {
            ring_slot_drop(self.keys, idx)
            ring_slot_drop(self.values, idx)
            ring_buf_set_byte(self.meta, idx, 2)  // tombstone
            self.len = self.len - 1
        }
    }

    pub fn filter(self: Map<K, V>, pred: fn(K, V) -> Bool) -> Map<K, V> {
        let mut result: Map<K, V> = map_new()
        let mut i = 0
        while i < self.cap {
            if ring_buf_get_byte(self.meta, i) == 1 {
                let k = ring_slot_read(self.keys, i)
                let v = ring_slot_read(self.values, i)
                if pred(k, v) {
                    // Need another read for key/value since pred consumed the first
                    let k2 = ring_slot_read(self.keys, i)
                    let v2 = ring_slot_read(self.values, i)
                    result.insert(k2, v2)
                }
            }
            i = i + 1
        }
        result
    }

    pub fn map_values<U>(self: Map<K, V>, f: fn(V) -> U) -> Map<K, U> {
        let mut result: Map<K, U> = map_new()
        let mut i = 0
        while i < self.cap {
            if ring_buf_get_byte(self.meta, i) == 1 {
                let k = ring_slot_read(self.keys, i)
                let v = ring_slot_read(self.values, i)
                result.insert(k, f(v))
            }
            i = i + 1
        }
        result
    }
}

pub struct MapIterator<K, V> { pub entries: List<(K, V)>, pub index: Int }

impl<K, V> Iterator for MapIterator<K, V> {
    type Item = (K, V)
    fn next(mut self) -> Option<(K, V)> {
        if self.index < self.entries.len() {
            let v = self.entries.get(self.index)
            self.index = self.index + 1
            v
        } else {
            none
        }
    }
}

impl<K: Hash + Eq, V> Iterable for Map<K, V> {
    type Item = (K, V)
    type Iter = MapIterator<K, V>
    fn iter(self) -> MapIterator<K, V> {
        MapIterator { entries: self.entries(), index: 0 }
    }
}
