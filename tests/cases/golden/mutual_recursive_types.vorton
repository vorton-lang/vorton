// B-100 P1.1 parity: mutual recursive types — two enum types that reference
// each other, construction and pattern matching.

enum Ty {
    TyInt,
    TyFn { params: List<Ty>, ret: Ty },
    TyEffectful { base: Ty, effs: List<Eff> },
}

enum Eff {
    EffIO,
    EffFail { error_ty: Ty },
}

fn count_types(t: Ty) -> Int {
    match t {
        TyInt => 1,
        TyFn { params, ret } => {
            let mut total = count_types(ret)
            for p in params {
                total += count_types(p)
            }
            total
        },
        TyEffectful { base, effs } => {
            let mut total = count_types(base)
            for e in effs {
                match e {
                    EffFail { error_ty } => {
                        total += count_types(error_ty)
                    },
                    EffIO => {},
                }
            }
            total
        },
    }
}

fn main() {
    // Simple type
    let t1 = TyInt
    print("int=${count_types(t1)}")

    // Function type: (Int, Int) -> Int = 3 types
    let t2 = TyFn { params: [TyInt, TyInt], ret: TyInt }
    print("fn=${count_types(t2)}")

    // Effectful: Int with fail<Int> = 2 types
    let t3 = TyEffectful {
        base: TyInt,
        effs: [EffFail { error_ty: TyInt }],
    }
    print("eff=${count_types(t3)}")

    // Nested: fn(Int) -> (Int with fail<Int>) = 3 types
    let t4 = TyFn {
        params: [TyInt],
        ret: TyEffectful { base: TyInt, effs: [EffFail { error_ty: TyInt }] },
    }
    print("nested=${count_types(t4)}")
}
