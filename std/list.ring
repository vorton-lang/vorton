// B-152 P2: List<T> — pure Ring struct (replaces pub extern type List<T>)
//
// Layout: { buf: Ptr<T>, len: Int, cap: Int }
// Elements stored in a slot buffer (calloc'd array of void*).
// RC semantics:
//   - ring_slot_read = peek + dup (list keeps ref, caller gets ref)
//   - ring_slot_take = move out (slot set to null, caller owns)
//   - ring_slot_write = direct store (arg 2 transfers ownership to the slot)
//   - ring_slot_replace = borrowed input (dup before store, then drop old)
//   - ring_slot_drop = take + ring_drop (release element)

pub struct List<T> {
    pub buf: Ptr<T>
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
extern fn ring_slot_swap<T>(buf: Ptr<T>, i: Int, j: Int) -> Unit
extern fn ring_slot_move<T>(src: Ptr<T>, src_off: Int, dst: Ptr<T>, dst_off: Int, count: Int) -> Unit
extern fn ring_slot_drop<T>(buf: Ptr<T>, idx: Int) -> Unit

// Sort bridge: C runtime std::sort for O(n log n) with zero RC overhead
extern fn ring_list_sort_bridge<T>(list: List<T>, cmp: fn(T, T) -> Int) -> Unit

// StringBuilder bridge for join (imported from str.ring via prelude)
extern fn ring_str_as_ptr(s: Str) -> Ptr<Int>
extern fn ring_buf_alloc(cap: Int) -> Ptr<Int>
extern fn ring_buf_dealloc(p: Ptr<Int>) -> Unit
extern fn ring_buf_copy_at(dst: Ptr<Int>, offset: Int, src: Ptr<Int>, len: Int) -> Unit
extern fn ring_str_from_ptr(p: Ptr<Int>, len: Int) -> Str

pub fn list_clone<T>(l: List<T>) -> List<T> {
    let n = l.len
    if n == 0 {
        return List { buf: ring_slot_alloc(0), len: 0, cap: 0 }
    }
    let new_buf: Ptr<T> = ring_slot_alloc(n)
    for i in 0..n {
        // ring_slot_read dups the element: fresh list co-owns each element
        let elem = ring_slot_read(l.buf, i)
        ring_slot_write(new_buf, i, elem)
    }
    List { buf: new_buf, len: n, cap: n }
}

fn list_deep_clone<T: Clone>(l: List<T>) -> List<T> {
    let n = l.len
    if n == 0 {
        return List { buf: ring_slot_alloc(0), len: 0, cap: 0 }
    }
    let new_buf: Ptr<T> = ring_slot_alloc(n)
    for i in 0..n {
        let element = ring_slot_read(l.buf, i)
        ring_slot_write(new_buf, i, element.clone())
    }
    List { buf: new_buf, len: n, cap: n }
}

impl<T: Clone> Clone for List<T> {
    fn clone(self: List<T>) -> List<T> { list_deep_clone(self) }
}

impl<T> List {
    pub fn len(self: List<T>) -> Int { self.len }

    pub fn get(self: List<T>, index: Int) -> Option<T> {
        if index < 0 || index >= self.len { return none }
        // ring_slot_read dups the element — fresh Option co-owns it
        some(ring_slot_read(self.buf, index))
    }

    pub fn first(self: List<T>) -> Option<T> {
        if self.len == 0 { return none }
        some(ring_slot_read(self.buf, 0))
    }

    pub fn last(self: List<T>) -> Option<T> {
        if self.len == 0 { return none }
        some(ring_slot_read(self.buf, self.len - 1))
    }

    pub fn is_empty(self: List<T>) -> Bool { self.len == 0 }

    pub fn push(mut self: List<T>, item: T) -> Unit {
        if self.len >= self.cap {
            let new_cap = if self.cap < 4 { 4 } else { self.cap + self.cap / 2 }
            let new_buf: Ptr<T> = ring_slot_alloc(new_cap)
            if self.len > 0 {
                ring_slot_move(self.buf, 0, new_buf, 0, self.len)
            }
            ring_slot_dealloc(self.buf, self.cap)
            self.buf = new_buf
            self.cap = new_cap
        }
        ring_slot_write(self.buf, self.len, item)
        self.len = self.len + 1
    }

    pub fn pop(mut self: List<T>) -> Option<T> {
        if self.len == 0 { return none }
        // take last element (moves out, slot nulled)
        let val = ring_slot_take(self.buf, self.len - 1)
        self.len = self.len - 1
        some(val)
    }

    pub fn concat(self: List<T>, other: List<T>) -> List<T> {
        let total = self.len + other.len
        let new_buf: Ptr<T> = ring_slot_alloc(total)
        // dup each element: fresh list co-owns (owned-container-constructor rule)
        for i in 0..self.len {
            let elem = ring_slot_read(self.buf, i)
            ring_slot_write(new_buf, i, elem)
        }
        for i in 0..other.len {
            let elem = ring_slot_read(other.buf, i)
            ring_slot_write(new_buf, self.len + i, elem)
        }
        List { buf: new_buf, len: total, cap: total }
    }

    pub fn extend(mut self: List<T>, other: List<T>) -> Unit {
        for i in 0..other.len {
            // dup each element: self co-owns element still owned by other
            let elem = ring_slot_read(other.buf, i)
            self.push(elem)
        }
    }

    pub fn slice(self: List<T>, start: Int, end: Int) -> List<T> {
        let s = if start < 0 { 0 } else { start }
        let e = if end > self.len { self.len } else { end }
        if s >= e {
            return List { buf: ring_slot_alloc(0), len: 0, cap: 0 }
        }
        let n = e - s
        let new_buf: Ptr<T> = ring_slot_alloc(n)
        for i in 0..n {
            // dup: fresh slice co-owns elements
            let elem = ring_slot_read(self.buf, s + i)
            ring_slot_write(new_buf, i, elem)
        }
        List { buf: new_buf, len: n, cap: n }
    }

    pub fn reverse(mut self: List<T>) -> Unit {
        // In-place swap — no ownership change, no dup/drop needed
        let mut lo = 0
        let mut hi = self.len - 1
        while lo < hi {
            ring_slot_swap(self.buf, lo, hi)
            lo = lo + 1
            hi = hi - 1
        }
    }

    pub fn join(self: List<Str>, separator: Str) -> Str {
        if self.len == 0 { return "" }
        // Calculate total length for pre-allocation
        let sep_len = separator.len()
        let mut total_len = 0
        for i in 0..self.len {
            let s = ring_slot_read(self.buf, i)
            total_len = total_len + s.len()
        }
        total_len = total_len + sep_len * (self.len - 1)
        // Build result using raw buffer ops
        let out_buf = ring_buf_alloc(total_len + 1)
        let mut offset = 0
        for i in 0..self.len {
            if i > 0 {
                let sep_ptr = ring_str_as_ptr(separator)
                ring_buf_copy_at(out_buf, offset, sep_ptr, sep_len)
                offset = offset + sep_len
            }
            let s = ring_slot_read(self.buf, i)
            let s_ptr = ring_str_as_ptr(s)
            let s_len = s.len()
            ring_buf_copy_at(out_buf, offset, s_ptr, s_len)
            offset = offset + s_len
        }
        let result = ring_str_from_ptr(out_buf, total_len)
        ring_buf_dealloc(out_buf)
        result
    }

    pub fn shift(mut self: List<T>) -> Option<T> {
        if self.len == 0 { return none }
        // Take first element
        let val = ring_slot_take(self.buf, 0)
        // Shift remaining elements left
        if self.len > 1 {
            ring_slot_move(self.buf, 1, self.buf, 0, self.len - 1)
        }
        self.len = self.len - 1
        some(val)
    }

    pub fn clear(mut self: List<T>) -> Unit {
        // Drop all elements
        for i in 0..self.len {
            ring_slot_drop(self.buf, i)
        }
        self.len = 0
    }

    pub fn set(mut self: List<T>, index: Int, value: T) -> Unit {
        if index < 0 || index >= self.len {
            panic("list index out of bounds")
        }
        // Borrowed input: duplicate before releasing the old slot so
        // self-assignment (`xs.set(i, xs[i])`) remains valid.
        ring_slot_replace(self.buf, index, value)
    }

    // Higher-order methods
    // NOTE: these use while loops (not `for i in 0..n`) to avoid introducing
    // the `mut` effect from the range iterator, which would leak into the
    // closure parameter's effect and cause effect mismatch errors.

    pub fn map<U>(self: List<T>, f: fn(T) -> U) -> List<U> {
        let new_buf: Ptr<U> = ring_slot_alloc(self.len)
        let mut i = 0
        while i < self.len {
            let elem = ring_slot_read(self.buf, i)
            let result = f(elem)
            ring_slot_write(new_buf, i, result)
            i = i + 1
        }
        List { buf: new_buf, len: self.len, cap: self.len }
    }

    pub fn filter(self: List<T>, pred: fn(T) -> Bool) -> List<T> {
        let mut result: List<T> = []
        let mut i = 0
        while i < self.len {
            let elem = ring_slot_read(self.buf, i)
            if pred(elem) {
                // Need another dup for the result list since pred consumed one
                let elem2 = ring_slot_read(self.buf, i)
                result.push(elem2)
            }
            i = i + 1
        }
        result
    }

    pub fn for_each(self: List<T>, f: fn(T) -> Unit) -> Unit {
        let mut i = 0
        while i < self.len {
            let elem = ring_slot_read(self.buf, i)
            f(elem)
            i = i + 1
        }
    }

    pub fn any(self: List<T>, pred: fn(T) -> Bool) -> Bool {
        let mut i = 0
        while i < self.len {
            let elem = ring_slot_read(self.buf, i)
            if pred(elem) { return true }
            i = i + 1
        }
        false
    }

    pub fn all(self: List<T>, pred: fn(T) -> Bool) -> Bool {
        let mut i = 0
        while i < self.len {
            let elem = ring_slot_read(self.buf, i)
            if pred(elem) == false { return false }
            i = i + 1
        }
        true
    }

    pub fn find(self: List<T>, pred: fn(T) -> Bool) -> Option<T> {
        let mut i = 0
        while i < self.len {
            let elem = ring_slot_read(self.buf, i)
            if pred(elem) {
                return some(ring_slot_read(self.buf, i))
            }
            i = i + 1
        }
        none
    }

    pub fn find_index(self: List<T>, pred: fn(T) -> Bool) -> Option<Int> {
        let mut i = 0
        while i < self.len {
            let elem = ring_slot_read(self.buf, i)
            if pred(elem) { return some(i) }
            i = i + 1
        }
        none
    }

    pub fn fold<U>(self: List<T>, init: U, f: fn(U, T) -> U) -> U {
        let mut acc = init
        let mut i = 0
        while i < self.len {
            let elem = ring_slot_read(self.buf, i)
            acc = f(acc, elem)
            i = i + 1
        }
        acc
    }

    pub fn flat_map<U>(self: List<T>, f: fn(T) -> List<U>) -> List<U> {
        let mut result: List<U> = []
        let mut i = 0
        while i < self.len {
            let elem = ring_slot_read(self.buf, i)
            let inner = f(elem)
            let mut j = 0
            while j < inner.len {
                let val = ring_slot_read(inner.buf, j)
                result.push(val)
                j = j + 1
            }
            i = i + 1
        }
        result
    }

    pub fn sort_by(mut self: List<T>, cmp: fn(T, T) -> Int) -> Unit {
        // Delegate to C runtime for O(n log n) std::sort with zero RC overhead.
        ring_list_sort_bridge(self, cmp)
    }
}

pub struct ListIterator<T> { pub list: List<T>, pub index: Int }

impl<T> Iterator for ListIterator<T> {
    type Item = T
    fn next(mut self) -> T? {
        if self.index < self.list.len {
            let v = self.list.get(self.index)
            self.index = self.index + 1
            v
        } else {
            none
        }
    }
}

impl<T> Iterable for List<T> {
    type Item = T
    type Iter = ListIterator<T>
    fn iter(self) -> ListIterator<T> {
        ListIterator { list: self, index: 0 }
    }
}

impl<T: Eq> List {
    pub fn contains(self: List<T>, item: T) -> Bool {
        for x in self {
            if x == item { return true }
        }
        false
    }

    pub fn index_of(self: List<T>, item: T) -> Option<Int> {
        for i in 0..self.len {
            match self.get(i) {
                some(v) => if v == item { return some(i) },
                none => {}
            }
        }
        none
    }
}

impl<T: Ord> List {
    pub fn sort(mut self: List<T>) -> Unit {
        self.sort_by(fn(a, b) { if a < b { -1 } else { if a > b { 1 } else { 0 } } })
    }
}

impl<T: Json> Json for List<T> {
    fn to_json(self) -> Str {
        let mut out = string_builder()
        out.add("[")
        let mut i = 0
        while i < self.len {
            if i > 0 {
                out.add(",")
            }
            let value = ring_slot_read(self.buf, i)
            out.add(value.to_json())
            i = i + 1
        }
        out.add("]")
        out.to_str()
    }
}
