// Test: mutually recursive enum types (Type <-> Effect pattern)
// Requires two-phase registration to resolve forward references.

pub struct Field {
    pub name: Str,
    pub ty: Ty
}

pub enum Ty {
    IntTy,
    FnTy { params: List<Ty>, ret: Ty, effs: List<Eff> },
    StructTy { name: Str, fields: List<Field> }
}

pub enum Eff {
    IoEff,
    FailEff { error_type: Ty }
}

fn ty_name(t: Ty) -> Str {
    match t {
        Ty::IntTy => "Int",
        Ty::FnTy { .. } => "Fn",
        Ty::StructTy { name, .. } => name
    }
}

fn eff_name(e: Eff) -> Str {
    match e {
        Eff::IoEff => "io",
        Eff::FailEff { error_type } => "fail<${ty_name(error_type)}>"
    }
}

fn main() {
    let int_ty = Ty::IntTy
    let fail_eff = Eff::FailEff { error_type: int_ty }
    let f = Field { name: "x", ty: int_ty }
    let s = Ty::StructTy { name: "Foo", fields: [f] }

    print(ty_name(int_ty))
    print(eff_name(fail_eff))
    print(ty_name(s))
}
