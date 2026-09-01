// Test 1: variant with Type field FIRST, List field SECOND (like GenericType),
// recursing on the leading Type field.
enum Ty {
    V { id: Int },
    Gen { base: Ty, args: List<Ty> },
    Fn { params: List<Ty>, ret: Ty, tag: Int }
}

fn subst(t: Ty) -> Ty {
    match t {
        Ty::V { id } => t,
        Ty::Gen { base, args } => Ty::Gen {
            base: subst(base),
            args: args.map(fn(a) { subst(a) })
        },
        Ty::Fn { params, ret, tag } => Ty::Fn {
            params: params.map(fn(p) { subst(p) }),
            ret: subst(ret),
            tag: tag
        }
    }
}

fn describe(t: Ty) -> Str {
    match t {
        Ty::V { id } => "V(${id})",
        Ty::Gen { base, args } => "Gen(${describe(base)}, n=${args.len()})",
        Ty::Fn { params, ret, tag } => "Fn(n=${params.len()}, ${describe(ret)}, ${tag})"
    }
}

fn main() {
    let g = Ty::Gen { base: Ty::V { id: 9 }, args: [Ty::V { id: 1 }] }
    print("gen before: ${describe(g)}")
    print("gen after:  ${describe(subst(g))}")

    let f = Ty::Fn { params: [Ty::V { id: 2 }], ret: Ty::V { id: 3 }, tag: 7 }
    print("fn before: ${describe(f)}")
    print("fn after:  ${describe(subst(f))}")
}
