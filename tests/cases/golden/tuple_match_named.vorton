// Tuple match with NamedConstructor sub-patterns (like unify's `match (a,b)`).
// The wrong arm must NOT be selected when tags differ.
enum Ty {
    V { id: Int },
    Fn { params: List<Ty>, ret: Ty },
    Str2 { name: Str, tparams: List<Ty> }
}

fn classify(a: Ty, b: Ty) -> Str {
    match (a, b) {
        (Ty::Fn { params: pa, ret: ra }, Ty::Fn { params: pb, ret: rb }) =>
            "both Fn (np=${pa.len()}/${pb.len()})",
        (Ty::Str2 { name: na, tparams: ta }, Ty::Str2 { name: nb, tparams: tb }) =>
            "both Str2 ${na}/${nb} (nt=${ta.len()}/${tb.len()})",
        _ => "other"
    }
}

fn main() {
    let a = Ty::Str2 { name: "X", tparams: [Ty::V { id: 1 }] }
    let b = Ty::Str2 { name: "Y", tparams: [Ty::V { id: 2 }] }
    print(classify(a, b))   // expect: both Str2 X/Y (nt=1/1)

    let f = Ty::Fn { params: [Ty::V { id: 3 }], ret: Ty::V { id: 4 } }
    print(classify(f, f))   // expect: both Fn (np=1/1)

    print(classify(a, f))   // expect: other
}
