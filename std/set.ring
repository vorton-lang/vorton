// B-152 P4: Set<T> is a pure Ring wrapper over Map<T, Unit>.
// Membership, mutation, and set algebra share Map's Hash + Eq probing path;
// iteration order is intentionally unspecified.

pub struct Set<T> {
    entries: Map<T, Unit>
}

pub fn set_new<T>() -> Set<T> {
    Set { entries: map_new() }
}

pub fn set_from<T: Hash + Eq>(items: List<T>) -> Set<T> {
    let mut result: Set<T> = set_new()
    let mut i = 0
    while i < items.len() {
        match items.get(i) {
            some(item) => result.insert(item),
            none => {},
        }
        i = i + 1
    }
    result
}

// Structural clone does not probe: Map.clone copies occupied slots and
// duplicates their owned values.
pub fn set_clone<T>(s: Set<T>) -> Set<T> {
    Set { entries: map_clone(s.entries) }
}

fn set_deep_clone<T: Clone>(s: Set<T>) -> Set<T> {
    let source = s.entries
    if source.len == 0 { return set_new() }
    let new_meta = ring_buf_alloc(source.cap)
    let new_keys: Ptr<T> = ring_slot_alloc(source.cap)
    let new_values: Ptr<Unit> = ring_slot_alloc(source.cap)
    let mut i = 0
    while i < source.cap {
        let meta = ring_buf_get_byte(source.meta, i)
        ring_buf_set_byte(new_meta, i, meta)
        if meta == 1 {
            let key = ring_slot_read(source.keys, i)
            ring_slot_write(new_keys, i, key.clone())
            ring_slot_write(new_values, i, ())
        }
        i = i + 1
    }
    Set { entries: Map {
        meta: new_meta, keys: new_keys, values: new_values,
        len: source.len, cap: source.cap
    } }
}

impl<T: Clone> Clone for Set<T> {
    fn clone(self: Set<T>) -> Set<T> { set_deep_clone(self) }
}

pub struct SetIterator<T> { pub items: List<T>, pub index: Int }

impl<T> Iterator for SetIterator<T> {
    type Item = T
    fn next(mut self) -> T? {
        if self.index < self.items.len() {
            let v = self.items.get(self.index)
            self.index = self.index + 1
            v
        } else {
            none
        }
    }
}

impl<T> Iterable for Set<T> {
    type Item = T
    type Iter = SetIterator<T>
    fn iter(self) -> SetIterator<T> {
        SetIterator { items: self.to_list(), index: 0 }
    }
}

// Operations that only inspect the Map layout do not need lookup evidence.
impl<T> Set {
    pub fn len(self: Set<T>) -> Int {
        self.entries.len()
    }

    pub fn is_empty(self: Set<T>) -> Bool {
        self.entries.is_empty()
    }

    pub fn to_list(self: Set<T>) -> List<T> {
        self.entries.keys()
    }

    pub fn clear(mut self: Set<T>) -> Unit {
        self.entries.clear()
    }

    pub fn for_each(self: Set<T>, f: fn(T) -> Unit) -> Unit {
        let items = self.to_list()
        let mut i = 0
        while i < items.len() {
            match items.get(i) {
                some(item) => f(item),
                none => {},
            }
            i = i + 1
        }
    }

    pub fn fold<U>(self: Set<T>, init: U, f: fn(U, T) -> U) -> U {
        let items = self.to_list()
        let mut acc = init
        let mut i = 0
        while i < items.len() {
            match items.get(i) {
                some(item) => { acc = f(acc, item) },
                none => {},
            }
            i = i + 1
        }
        acc
    }

    pub fn any(self: Set<T>, pred: fn(T) -> Bool) -> Bool {
        let items = self.to_list()
        let mut i = 0
        while i < items.len() {
            match items.get(i) {
                some(item) => {
                    if pred(item) { return true }
                },
                none => {},
            }
            i = i + 1
        }
        false
    }

    pub fn all(self: Set<T>, pred: fn(T) -> Bool) -> Bool {
        let items = self.to_list()
        let mut i = 0
        while i < items.len() {
            match items.get(i) {
                some(item) => {
                    if pred(item) == false { return false }
                },
                none => {},
            }
            i = i + 1
        }
        true
    }
}

// Every lookup or mutation delegates to Map's single Hash + Eq path.
impl<T: Hash + Eq> Set {
    pub fn insert(mut self: Set<T>, item: T) -> Unit {
        self.entries.insert(item, ())
    }

    pub fn remove(mut self: Set<T>, item: T) -> Unit {
        self.entries.remove(item)
    }

    pub fn contains(self: Set<T>, item: T) -> Bool {
        self.entries.contains_key(item)
    }

    pub fn has(self: Set<T>, item: T) -> Bool {
        self.contains(item)
    }

    pub fn union(self: Set<T>, other: Set<T>) -> Set<T> {
        let mut result = set_clone(self)
        let items = other.to_list()
        let mut i = 0
        while i < items.len() {
            match items.get(i) {
                some(item) => result.insert(item),
                none => {},
            }
            i = i + 1
        }
        result
    }

    pub fn intersect(self: Set<T>, other: Set<T>) -> Set<T> {
        let mut result: Set<T> = set_new()
        let items = self.to_list()
        let mut i = 0
        while i < items.len() {
            match items.get(i) {
                some(item) => {
                    if other.contains(item) {
                        result.insert(item)
                    }
                },
                none => {},
            }
            i = i + 1
        }
        result
    }

    pub fn difference(self: Set<T>, other: Set<T>) -> Set<T> {
        let mut result: Set<T> = set_new()
        let items = self.to_list()
        let mut i = 0
        while i < items.len() {
            match items.get(i) {
                some(item) => {
                    if other.contains(item) == false {
                        result.insert(item)
                    }
                },
                none => {},
            }
            i = i + 1
        }
        result
    }

    pub fn filter(self: Set<T>, pred: fn(T) -> Bool) -> Set<T> {
        let mut result: Set<T> = set_new()
        let items = self.to_list()
        let mut i = 0
        while i < items.len() {
            match items.get(i) {
                some(item) => {
                    if pred(item) {
                        // The callback may consume its argument; read a fresh
                        // owned value before storing it in the result.
                        match items.get(i) {
                            some(kept) => result.insert(kept),
                            none => {},
                        }
                    }
                },
                none => {},
            }
            i = i + 1
        }
        result
    }
}
