use types::{Type}

// ============================================================
// Union-Find substitution for O(alpha(n)) type variable resolution
// Replaces plain Map<Int, Type> substitution
// ============================================================

pub struct UnionFind {
    pub parent: Map<Int, Int>,
    pub rank: Map<Int, Int>,
    pub types: Map<Int, Type>
}

pub fn new_union_find() -> UnionFind {
    UnionFind {
        parent: map_new(),
        rank: map_new(),
        types: map_new()
    }
}

// Find the root representative for a type variable id.
// Performs path compression for amortized O(alpha(n)) performance.
// Note: path compression mutates parent map (reference type) in-place.
pub fn uf_find(
    mut uf: UnionFind, id: Int
) -> Int with {mut<UnionFind>} {
    match uf.parent.get(id) {
        none => id,
        some(p) => {
            if p == id { return id }
            let root = uf_find(uf, p)
            // Path compression: point directly to root
            uf.parent.insert(id, root)
            root
        }
    }
}

// Bind a type variable to a type. Binds at the root representative.
pub fn uf_bind(
    mut uf: UnionFind, id: Int, ty: Type
) with {mut<UnionFind>} {
    let root = uf_find(uf, id)
    uf.types.insert(root, ty)
}

// Look up the type bound to a type variable. Returns the type at the root representative.
pub fn uf_lookup(
    mut uf: UnionFind, id: Int
) -> Type? with {mut<UnionFind>} {
    let root = uf_find(uf, id)
    uf.types.get(root)
}

// Union two type variable equivalence classes by rank.
pub fn uf_union(mut uf: UnionFind, a: Int, b: Int) {
    let ra = uf_find(uf, a)
    let rb = uf_find(uf, b)
    if ra == rb { return }
    let rank_a = match uf.rank.get(ra) { some(r) => r, none => 0 }
    let rank_b = match uf.rank.get(rb) { some(r) => r, none => 0 }
    if rank_a < rank_b {
        uf.parent.insert(ra, rb)
        // Transfer type binding if only ra had one
        match uf.types.get(ra) {
            some(ty) => match uf.types.get(rb) {
                none => { uf.types.insert(rb, ty) },
                some(existing) => {
                    panic("unreachable: uf_union both nodes have type bindings")
                }
            },
            none => {}
        }
    } else {
        uf.parent.insert(rb, ra)
        // Transfer type binding if only rb had one
        match uf.types.get(rb) {
            some(ty) => match uf.types.get(ra) {
                none => { uf.types.insert(ra, ty) },
                some(existing) => {
                    panic("unreachable: uf_union both nodes have type bindings")
                }
            },
            none => {}
        }
        if rank_a == rank_b {
            uf.rank.insert(ra, rank_a + 1)
        }
    }
}

// Insert a binding directly (for row variable bindings, effect row bindings, etc.)
// This performs find first, then inserts at the root.
pub fn uf_insert(
    mut uf: UnionFind, id: Int, ty: Type
) with {mut<UnionFind>} {
    let root = uf_find(uf, id)
    uf.types.insert(root, ty)
}
