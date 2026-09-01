// Closest mirror of apply_subst: recursion threads a Map<Int,Ty> (like UnionFind),
// the TypeVar arm recurses through a map lookup, and .map closures CAPTURE the map.
enum Ty {
    V { id: Int },
    Fn { params: List<Ty>, ret: Ty },
    Gen { base: Ty, args: List<Ty> }
}

fn subst(store: Map<Int, Ty>, t: Ty) -> Ty {
    match t {
        Ty::V { id } => match store.get(id) {
            some(resolved) => subst(store, resolved),
            none => t
        },
        Ty::Fn { params, ret } => Ty::Fn {
            params: params.map(fn(p) { subst(store, p) }),
            ret: subst(store, ret)
        },
        Ty::Gen { base, args } => Ty::Gen {
            base: subst(store, base),
            args: args.map(fn(a) { subst(store, a) })
        }
    }
}

fn describe(t: Ty) -> Str {
    match t {
        Ty::V { id } => "V(${id})",
        Ty::Fn { params, ret } => "Fn(${params.len()}, ${describe(ret)})",
        Ty::Gen { base, args } => "Gen(${describe(base)}, ${args.len()})"
    }
}

fn main() {
    let mut store: Map<Int, Ty> = map_new()
    store.insert(1, Ty::V { id: 100 })
    let t = Ty::Gen { base: Ty::V { id: 1 }, args: [Ty::V { id: 2 }] }
    print("before: ${describe(t)}")
    print("after:  ${describe(subst(store, t))}")
}
