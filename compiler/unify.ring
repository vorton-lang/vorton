use types::{Type, Effect, EffectRow, RecordField, StructField, type_to_string, effect_kind_name, effects_match_kind, UNIT}
use union_find::{UnionFind, uf_bind, uf_find, uf_lookup, uf_insert, new_union_find}
use env::{TypeEnv, apply_subst, apply_subst_row, apply_subst_map}

// ============================================================
// Unification error (raised via fail effect, caught by infer-ctx)
// ============================================================

pub struct UnificationError {
    pub message: Str,
    pub is_occurs_check: Bool
}

pub fn empty_subst() -> UnionFind { new_union_find() }

// ============================================================
// Error helpers
// ============================================================

fn unify_error(t1: Type, t2: Type, detail: Str?) -> Never {
    let base = "Type mismatch: cannot unify ${type_to_string(t1)} with ${type_to_string(t2)}"
    let msg = match detail { some(d) => "${base} — ${d}", none => base }
    fail.raise(UnificationError { message: msg, is_occurs_check: false })
}

fn unify_error_occurs(t1: Type, t2: Type) -> Never {
    let msg = "Type mismatch: cannot unify ${type_to_string(t1)} with ${type_to_string(t2)} — infinite type (occurs check)"
    fail.raise(UnificationError { message: msg, is_occurs_check: true })
}

fn unify_error_msg(detail: Str) -> Never {
    fail.raise(UnificationError { message: detail, is_occurs_check: false })
}

// ============================================================
// Occurs check: does var_id appear anywhere in type?
// ============================================================

pub fn occurs_in(var_id: Int, t: Type, subst: UnionFind) -> Bool {
    match t {
        Type::IntType => false,
        Type::FloatType => false,
        Type::StrType => false,
        Type::BoolType => false,
        Type::UnitType => false,
        Type::NeverType => false,
        Type::AnyType => false,
        Type::ErrorType => false,
        Type::TypeVar { id, .. } => {
            let root = uf_find(subst, id)
            if root == var_id { return true }
            match uf_lookup(subst, root) {
                some(resolved) => occurs_in(var_id, resolved, subst),
                none => false
            }
        },
        Type::FnType { params, return_type, effects } =>
            params.any(fn(p) { occurs_in(var_id, p, subst) }) ||
            occurs_in(var_id, return_type, subst) ||
            occurs_in_row(var_id, effects, subst),
        Type::StructType { type_params, .. } =>
            type_params.any(fn(p) { occurs_in(var_id, p, subst) }),
        Type::EnumType { type_params, .. } =>
            type_params.any(fn(p) { occurs_in(var_id, p, subst) }),
        Type::GenericType { base, args } =>
            occurs_in(var_id, base, subst) ||
            args.any(fn(a) { occurs_in(var_id, a, subst) }),
        Type::RecordType { fields, tail, .. } => {
            let in_tail = match tail {
                some(t_id) => {
                    let root = uf_find(subst, t_id)
                    if root == var_id { return true }
                    match uf_lookup(subst, root) {
                        some(resolved) => occurs_in(var_id, resolved, subst),
                        none => false
                    }
                },
                none => false
            }
            in_tail || fields.any(fn(f) { occurs_in(var_id, f.ty, subst) })
        },
        Type::EffectRowType { effects, tail } =>
            occurs_in_row(var_id, EffectRow { effects: effects, tail: tail }, subst),
        Type::TupleType { elements } =>
            elements.any(fn(e) { occurs_in(var_id, e, subst) }),
        Type::PtrType { pointee } =>
            occurs_in(var_id, pointee, subst)
    }
}

fn occurs_in_row(var_id: Int, row: EffectRow, subst: UnionFind) -> Bool {
    let in_tail = match row.tail {
        some(t_id) => {
            let root = uf_find(subst, t_id)
            if root == var_id { return true }
            match uf_lookup(subst, root) {
                some(resolved) => occurs_in(var_id, resolved, subst),
                none => false
            }
        },
        none => false
    }
    in_tail || row.effects.any(fn(e) { occurs_in_effect(var_id, e, subst) })
}

fn occurs_in_effect(var_id: Int, e: Effect, subst: UnionFind) -> Bool {
    match e {
        Effect::FailEffect { error_type } => occurs_in(var_id, error_type, subst),
        Effect::MutEffect { state_type } => occurs_in(var_id, state_type, subst),
        Effect::CustomEffect { type_args, .. } =>
            type_args.any(fn(a) { occurs_in(var_id, a, subst) }),
        Effect::IoEffect => false,
        Effect::UnsafeEffect => false
    }
}

// ============================================================


pub fn unify_effect_params(a: Effect, b: Effect, subst: UnionFind, mut env: TypeEnv) -> UnionFind {
    match (a, b) {
        (Effect::FailEffect { error_type: et_a }, Effect::FailEffect { error_type: et_b }) =>
            unify(et_a, et_b, subst, env),
        (Effect::MutEffect { state_type: sa }, Effect::MutEffect { state_type: sb }) =>
            unify(sa, sb, subst, env),
        (Effect::CustomEffect { name, type_args: ta_a }, Effect::CustomEffect { type_args: ta_b, .. }) => {
            if ta_a.len() != ta_b.len() {
                unify_error_msg("effect '${name}' type argument count mismatch: ${ta_a.len()} vs ${ta_b.len()}")
            }
            let mut s = subst
            let mut i = 0
            while i < ta_a.len() {
                s = unify(
                    ta_a.get(i).unwrap_or(UNIT),
                    ta_b.get(i).unwrap_or(UNIT),
                    s, env
                )
                i = i + 1
            }
            s
        },
        _ => subst
    }
}

// ============================================================
// Index filter helper
// ============================================================

fn filter_by_index_not_in(effects: List<Effect>, excluded: Set<Int>) -> List<Effect> {
    let mut result: List<Effect> = []
    let mut idx = 0
    for e in effects {
        if !excluded.contains(idx) {
            result.push(e)
        }
        idx = idx + 1
    }
    result
}

// ============================================================
// Unify effect rows (Koka-style row variable solving)
// ============================================================

pub fn unify_effect_rows(a: EffectRow, b: EffectRow, subst: UnionFind, mut env: TypeEnv) -> UnionFind {
    let mut s = subst
    let ra = apply_subst_row(s, a)
    let rb = apply_subst_row(s, b)

    let mut a_matched: Set<Int> = set_new()
    let mut b_matched: Set<Int> = set_new()
    let mut ai = 0
    while ai < ra.effects.len() {
        let mut bi = 0
        while bi < rb.effects.len() {
            if !b_matched.contains(bi) {
                match (ra.effects.get(ai), rb.effects.get(bi)) {
                    (some(eff_a), some(eff_b)) => {
                        if effects_match_kind(eff_a, eff_b) {
                            s = unify_effect_params(eff_a, eff_b, s, env)
                            a_matched.insert(ai)
                            b_matched.insert(bi)
                            break
                        }
                    },
                    _ => {}
                }
            }
            bi = bi + 1
        }
        ai = ai + 1
    }

    let a_unmatched = filter_by_index_not_in(ra.effects, a_matched)
    let b_unmatched = filter_by_index_not_in(rb.effects, b_matched)

    if a_unmatched.len() > 0 && rb.tail.is_none() {
        let names = a_unmatched.map(fn(e) { effect_kind_name(e) }).join(", ")
        unify_error_msg("effect mismatch: effects [${names}] not allowed in pure context")
    }
    if b_unmatched.len() > 0 && ra.tail.is_none() {
        let names = b_unmatched.map(fn(e) { effect_kind_name(e) }).join(", ")
        unify_error_msg("effect mismatch: effects [${names}] not allowed in pure context")
    }

    match (ra.tail, rb.tail) {
        (some(ta), some(tb)) => {
            if ta == tb {
                if a_unmatched.len() > 0 || b_unmatched.len() > 0 {
                    let fresh = env.fresh_var_id()
                    let mut all_unmatched: List<Effect> = []
                    for e in a_unmatched { all_unmatched.push(e) }
                    for e in b_unmatched { all_unmatched.push(e) }
                    let extended_row = Type::EffectRowType { effects: all_unmatched, tail: some(fresh) }
                    if occurs_in(ta, extended_row, s) {
                        unify_error_msg("infinite type in effect row variable")
                    }
                    uf_insert(s, ta, extended_row)
                }
            } else if a_unmatched.len() == 0 && b_unmatched.len() == 0 {
                s = unify(Type::TypeVar { id: ta, name: none }, Type::TypeVar { id: tb, name: none }, s, env)
            } else {
                let fresh = env.fresh_var_id()
                if b_unmatched.len() > 0 {
                    let row_for_a_tail = Type::EffectRowType { effects: b_unmatched, tail: some(fresh) }
                    if occurs_in(ta, row_for_a_tail, s) {
                        unify_error_msg("infinite type in effect row variable")
                    }
                    uf_insert(s, ta, row_for_a_tail)
                } else {
                    s = unify(Type::TypeVar { id: ta, name: none }, Type::TypeVar { id: fresh, name: none }, s, env)
                }
                if a_unmatched.len() > 0 {
                    let row_for_b_tail = Type::EffectRowType { effects: a_unmatched, tail: some(fresh) }
                    if occurs_in(tb, row_for_b_tail, s) {
                        unify_error_msg("infinite type in effect row variable")
                    }
                    uf_insert(s, tb, row_for_b_tail)
                } else {
                    s = unify(Type::TypeVar { id: tb, name: none }, Type::TypeVar { id: fresh, name: none }, s, env)
                }
            }
        },
        (none, some(tb)) => {
            // a is closed, b is open — push a's unmatched effects into b's tail
            if a_unmatched.len() > 0 {
                let row_for_b_tail = Type::EffectRowType { effects: a_unmatched, tail: none }
                if occurs_in(tb, row_for_b_tail, s) {
                    unify_error_msg("infinite type in effect row variable")
                }
                uf_insert(s, tb, row_for_b_tail)
            }
            // When a_unmatched is empty, all effects matched — the tail variable
            // is left unbound to avoid over-constraining shared type variables
            // (e.g., effect-polymorphic HOF instantiation tails used by merge_effects).
        },
        (some(ta), none) => {
            // a is open, b is closed — push b's unmatched effects into a's tail
            if b_unmatched.len() > 0 {
                let row_for_a_tail = Type::EffectRowType { effects: b_unmatched, tail: none }
                if occurs_in(ta, row_for_a_tail, s) {
                    unify_error_msg("infinite type in effect row variable")
                }
                uf_insert(s, ta, row_for_a_tail)
            }
            // When b_unmatched is empty, all effects matched — the tail variable
            // is left unbound to avoid over-constraining shared type variables.
        },
        (none, none) => {}
    }

    s
}

// ============================================================
// Record row unification
// ============================================================

fn unify_record_rows(ra: Type, rb: Type, subst: UnionFind, mut env: TypeEnv) -> UnionFind {
    match (ra, rb) {
        (Type::RecordType { fields: a_fields, tail: a_tail, .. },
         Type::RecordType { fields: b_fields, tail: b_tail, .. }) => {
            let mut s = subst

            let mut b_name_set: Set<Str> = set_new()
            for f in b_fields { b_name_set.insert(f.name) }
            let mut a_name_set: Set<Str> = set_new()
            for f in a_fields { a_name_set.insert(f.name) }

            for af in a_fields {
                let bf = b_fields.find(fn(f) { f.name == af.name })
                match bf {
                    some(matched) => { s = unify(af.ty, matched.ty, s, env) },
                    none => {}
                }
            }

            let a_only = a_fields.filter(fn(f) { !b_name_set.contains(f.name) })
            let b_only = b_fields.filter(fn(f) { !a_name_set.contains(f.name) })

            if a_only.len() > 0 && b_tail.is_none() {
                let missing = a_only.map(fn(f) { f.name }).join(", ")
                unify_error(ra, rb, some("record missing fields: ${missing}"))
            }
            if b_only.len() > 0 && a_tail.is_none() {
                let missing = b_only.map(fn(f) { f.name }).join(", ")
                unify_error(ra, rb, some("record missing fields: ${missing}"))
            }

            if a_only.len() > 0 && b_only.len() > 0 && a_tail.is_some() && b_tail.is_some() {
                match (a_tail, b_tail) {
                    (some(ta), some(tb)) => {
                        let fresh_tail = env.fresh_var_id()
                        let a_tail_record = Type::RecordType { fields: b_only, tail: some(fresh_tail), tail_name: none }
                        let b_tail_record = Type::RecordType { fields: a_only, tail: some(fresh_tail), tail_name: none }
                        if occurs_in(ta, a_tail_record, s) {
                            unify_error(ra, rb, some("infinite type in row variable"))
                        }
                        if occurs_in(tb, b_tail_record, s) {
                            unify_error(ra, rb, some("infinite type in row variable"))
                        }
                        uf_insert(s, ta, a_tail_record)
                        uf_insert(s, tb, b_tail_record)
                    },
                    _ => {}
                }
            } else {
                match a_tail {
                    some(ta) => {
                        if b_only.len() > 0 {
                            let record_for_tail = Type::RecordType { fields: b_only, tail: none, tail_name: none }
                            if occurs_in(ta, record_for_tail, s) {
                                unify_error(ra, rb, some("infinite type in row variable"))
                            }
                            uf_insert(s, ta, record_for_tail)
                        }
                    },
                    none => {}
                }
                match b_tail {
                    some(tb) => {
                        if a_only.len() > 0 {
                            let record_for_tail = Type::RecordType { fields: a_only, tail: none, tail_name: none }
                            if occurs_in(tb, record_for_tail, s) {
                                unify_error(ra, rb, some("infinite type in row variable"))
                            }
                            uf_insert(s, tb, record_for_tail)
                        }
                    },
                    none => {}
                }
                match (a_tail, b_tail) {
                    (some(ta), some(tb)) => {
                        if a_only.len() == 0 && b_only.len() == 0 && ta != tb {
                            s = unify(
                                Type::TypeVar { id: ta, name: none },
                                Type::TypeVar { id: tb, name: none },
                                s, env
                            )
                        }
                    },
                    _ => {}
                }
            }

            s
        },
        _ => panic("unreachable: unify_record_rows expected RecordType")
    }
}

// ============================================================
// Struct -> Record coercion
// ============================================================

fn unify_struct_with_record(st: Type, rt: Type, subst: UnionFind, mut env: TypeEnv) -> UnionFind {
    match (st, rt) {
        (Type::StructType { name, type_params, .. },
         Type::RecordType { fields: record_fields, tail: record_tail, .. }) => {
            // Look up struct fields from registry and instantiate with type_params
            let struct_fields = match env.types.structs.get(name) {
                some(struct_def) => {
                    let mut inst_map: Map<Int, Type> = map_new()
                    let mut fi = 0
                    while fi < struct_def.type_param_vars.len() && fi < type_params.len() {
                        match (struct_def.type_param_vars.get(fi), type_params.get(fi)) {
                            (some(var_id), some(tp)) => inst_map.insert(var_id, tp),
                            _ => {}
                        }
                        fi = fi + 1
                    }
                    struct_def.fields.map(fn(f) { StructField { name: f.name, ty: apply_subst_map(inst_map, f.ty), is_pub: f.is_pub } })
                },
                none => {
                    let empty: List<StructField> = []
                    empty
                }
            }
            let mut s = subst

            for rf in record_fields {
                let sf = struct_fields.find(fn(f) { f.name == rf.name })
                match sf {
                    some(matched) => { s = unify(matched.ty, rf.ty, s, env) },
                    none => {
                        let field_names = record_fields.map(fn(f) { f.name }).join(", ")
                        unify_error(st, rt, some("type '${name}' does not satisfy {${field_names}, ..} — missing field '${rf.name}'"))
                    }
                }
            }

            match record_tail {
                some(tail_id) => {
                    let remaining = struct_fields.filter(fn(sf) {
                        !record_fields.any(fn(rf) { rf.name == sf.name })
                    })
                    let remaining_mapped = remaining.map(fn(f) {
                        RecordField { name: f.name, ty: apply_subst(s, f.ty) }
                    })
                    let tail_record = Type::RecordType { fields: remaining_mapped, tail: none, tail_name: none }
                    if occurs_in(tail_id, tail_record, s) {
                        unify_error(st, rt, some("infinite type in row variable"))
                    }
                    uf_insert(s, tail_id, tail_record)
                },
                none => {}
            }

            s
        },
        _ => panic("unreachable: unify_struct_with_record expected StructType and RecordType")
    }
}

// ============================================================
// Type kind helpers (for early returns in unify)
// ============================================================

fn is_any(t: Type) -> Bool { match t { Type::AnyType => true, _ => false } }
fn is_never(t: Type) -> Bool { match t { Type::NeverType => true, _ => false } }
fn var_id(t: Type) -> Int? { match t { Type::TypeVar { id, .. } => some(id), _ => none } }

// ============================================================
// Bind type variable (with occurs check)
// ============================================================

fn bind_var(id: Int, target: Type, t1: Type, t2: Type, subst: UnionFind) -> UnionFind {
    if occurs_in(id, target, subst) {
        unify_error_occurs(t1, t2)
    }
    uf_bind(subst, id, target)
    subst
}

// ============================================================
// Main unification
// ============================================================

pub fn unify(t1: Type, t2: Type, subst: UnionFind, mut env: TypeEnv) -> UnionFind {
    let a = apply_subst(subst, t1)
    let b = apply_subst(subst, t2)

    // ErrorType absorbs: unification with ErrorType always succeeds
    match a { Type::ErrorType => { return subst }, _ => {} }
    match b { Type::ErrorType => { return subst }, _ => {} }

    // any unifies with anything
    if is_any(a) || is_any(b) { return subst }

    // Same type variable
    let va = var_id(a)
    let vb = var_id(b)
    match (va, vb) {
        (some(ia), some(ib)) => { if ia == ib { return subst } },
        _ => {}
    }

    // Bind a variable (must come before never so that unify(?a, never) binds ?a)
    match va {
        some(id) => { return bind_var(id, b, t1, t2, subst) },
        none => {}
    }
    match vb {
        some(id) => { return bind_var(id, a, t1, t2, subst) },
        none => {}
    }

    // never unifies with anything (bottom type)
    if is_never(a) || is_never(b) { return subst }

    // Structured type unification
    match (a, b) {
        // Same primitive types
        (Type::IntType, Type::IntType) => subst,
        (Type::FloatType, Type::FloatType) => subst,
        (Type::StrType, Type::StrType) => subst,
        (Type::BoolType, Type::BoolType) => subst,
        (Type::UnitType, Type::UnitType) => subst,

        // Function types
        (Type::FnType { params: pa, return_type: ra, effects: ea },
         Type::FnType { params: pb, return_type: rb, effects: eb }) => {
            if pa.len() != pb.len() {
                unify_error(t1, t2, some("parameter count mismatch: ${pa.len()} vs ${pb.len()}"))
            }
            let mut s = subst
            let mut i = 0
            while i < pa.len() {
                s = unify(
                    pa.get(i).unwrap_or(UNIT),
                    pb.get(i).unwrap_or(UNIT),
                    s, env
                )
                i = i + 1
            }
            s = unify(ra, rb, s, env)
            s = unify_effect_rows(ea, eb, s, env)
            s
        },

        // Struct types
        (Type::StructType { name: na, type_params: tpa, .. },
         Type::StructType { name: nb, type_params: tpb, .. }) => {
            if na != nb {
                unify_error(t1, t2, some("different struct types"))
            }
            if tpa.len() != tpb.len() {
                unify_error(t1, t2, some("different type parameter counts for struct '${na}'"))
            }
            let mut s = subst
            let mut i = 0
            while i < tpa.len() {
                s = unify(
                    tpa.get(i).unwrap_or(UNIT),
                    tpb.get(i).unwrap_or(UNIT),
                    s, env
                )
                i = i + 1
            }
            s
        },

        // Enum types
        (Type::EnumType { name: na, type_params: tpa, .. },
         Type::EnumType { name: nb, type_params: tpb, .. }) => {
            if na != nb {
                unify_error(t1, t2, some("different enum types"))
            }
            if tpa.len() != tpb.len() {
                unify_error(t1, t2, some("different type parameter counts for enum '${na}'"))
            }
            let mut s = subst
            let mut i = 0
            while i < tpa.len() {
                s = unify(
                    tpa.get(i).unwrap_or(UNIT),
                    tpb.get(i).unwrap_or(UNIT),
                    s, env
                )
                i = i + 1
            }
            s
        },

        // Generic types
        (Type::GenericType { base: ba, args: aa },
         Type::GenericType { base: bb, args: ab }) => {
            let mut s = unify(ba, bb, subst, env)
            if aa.len() != ab.len() {
                unify_error(t1, t2, some("different type argument counts"))
            }
            let mut i = 0
            while i < aa.len() {
                s = unify(
                    aa.get(i).unwrap_or(UNIT),
                    ab.get(i).unwrap_or(UNIT),
                    s, env
                )
                i = i + 1
            }
            s
        },

        // Record types (row unification)
        (Type::RecordType { .. }, Type::RecordType { .. }) =>
            unify_record_rows(a, b, subst, env),

        // Effect row types
        (Type::EffectRowType { effects: ea, tail: ta },
         Type::EffectRowType { effects: eb, tail: tb }) =>
            unify_effect_rows(
                EffectRow { effects: ea, tail: ta },
                EffectRow { effects: eb, tail: tb },
                subst, env
            ),

        // Tuple types
        (Type::TupleType { elements: ea }, Type::TupleType { elements: eb }) => {
            if ea.len() != eb.len() {
                unify_error(t1, t2, some("tuple arity mismatch: ${ea.len()} vs ${eb.len()}"))
            }
            let mut s = subst
            let mut i = 0
            while i < ea.len() {
                s = unify(
                    ea.get(i).unwrap_or(UNIT),
                    eb.get(i).unwrap_or(UNIT),
                    s, env
                )
                i = i + 1
            }
            s
        },

        // Ptr types
        (Type::PtrType { pointee: pa }, Type::PtrType { pointee: pb }) =>
            unify(pa, pb, subst, env),

        // Struct satisfies record constraint (one-direction coercion)
        (Type::StructType { .. }, Type::RecordType { .. }) =>
            unify_struct_with_record(a, b, subst, env),
        (Type::RecordType { .. }, Type::StructType { .. }) =>
            unify_struct_with_record(b, a, subst, env),

        // Mismatch
        _ => unify_error(t1, t2, none)
    }
}
