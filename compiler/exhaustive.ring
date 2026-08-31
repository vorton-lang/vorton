use ast::{Pattern, NamedPatternField, span_zero, LiteralValue}
use types::{Type, StructField, EnumVariant, type_to_string}
use union_find::{UnionFind}
use env::{apply_subst, apply_subst_map, TypeEnv}
use hir::{HMatchArm}

struct Ctor {
    name: Str,
    arity: Int,
    field_types: List<Type>,
    field_names: List<Str>?,
    is_tuple: Bool
}

// ============================================================
// B-132 Performance: Using Map<Str, _> instead of Set<Str> for O(1)
// string lookups (Set<Str> uses __ring_deep_eq linear scan — O(n) per lookup).
// Memoize caches are threaded through function parameters.
// ============================================================

// B-132: Cache containers threaded through check_matrix and friends.
struct ExhCache {
    ftc: Map<Str, List<Ctor>?>,
    tir: Map<Str, Bool>
}

// ============================================================
// B-102 Phase 2 / A2 soundness fix: instantiate variant/field templates.
//
// apply_subst substitutes a composite type's `type_params` but leaves its
// `variants` / `fields` as the original (generic) templates — those payload
// types reference the enum/struct definition's `type_param_vars`. exhaustive.ring
// reads those payload types structurally to derive payload constructors, so it
// MUST first re-derive them from THIS node's concrete `type_params`. Doing so
// also makes the read self-contained (independent of the ambient UnionFind),
// which is what lets apply_subst safely hash-cons (intern) EnumType/StructType:
// the cached node's template payloads no longer leak across instantiations.
//
// The inst_map pattern mirrors infer.ring (field access ~2157, struct lit ~2344,
// variant construct ~2431) and infer_ctx.ring's build_instantiation_map: a
// while-indexed Map<Int,Type> from type_param_vars[i] -> type_params[i], then
// apply_subst_map over each payload. (while loop, not .enumerate() — B-095.)
// ============================================================
fn build_inst_map(type_param_vars: List<Int>, type_params: List<Type>) -> Map<Int, Type> {
    let mut inst_map: Map<Int, Type> = map_new()
    let mut i = 0
    while i < type_param_vars.len() && i < type_params.len() {
        match (type_param_vars.get(i), type_params.get(i)) {
            (some(var_id), some(tp)) => { inst_map.insert(var_id, tp) },
            _ => {}
        }
        i = i + 1
    }
    inst_map
}

// Re-derive an enum's variants with this instantiation's concrete type_params
// substituted into every variant field. Falls back to the (template) variants
// passed in if the enum definition is unknown (builtins / cross-module).
fn instantiate_enum_variants(env: TypeEnv, name: Str, type_params: List<Type>) -> List<EnumVariant> {
    match env.types.enums.get(name) {
        some(enum_def) => {
            let inst_map = build_inst_map(enum_def.type_param_vars, type_params)
            if inst_map.len() == 0 { return enum_def.variants }
            let mut result: List<EnumVariant> = []
            for v in enum_def.variants {
                let inst_fields = v.fields.map(fn(f) { apply_subst_map(inst_map, f) })
                result.push(EnumVariant { name: v.name, fields: inst_fields, field_names: v.field_names })
            }
            result
        },
        none => []
    }
}

// Re-derive a struct's fields with this instantiation's concrete type_params
// substituted into every field type. Falls back to empty list when the struct
// definition is unknown (builtins / cross-module).
fn instantiate_struct_fields(env: TypeEnv, name: Str, type_params: List<Type>) -> List<StructField> {
    match env.types.structs.get(name) {
        some(struct_def) => {
            let inst_map = build_inst_map(struct_def.type_param_vars, type_params)
            if inst_map.len() == 0 { return struct_def.fields }
            let mut result: List<StructField> = []
            for f in struct_def.fields {
                result.push(StructField {
                    name: f.name, ty: apply_subst_map(inst_map, f.ty),
                    is_pub: f.is_pub, field_ref: f.field_ref,
                    field_index: f.field_index, span: f.span
                })
            }
            result
        },
        none => []
    }
}

fn pat_at(list: List<Pattern>, i: Int) -> Pattern {
    match list.get(i) { some(v) => v, none => panic("unreachable: pat_at out of bounds") }
}

fn type_at(list: List<Type>, i: Int) -> Type {
    match list.get(i) { some(v) => v, none => panic("unreachable: type_at out of bounds") }
}

fn str_at(list: List<Str>, i: Int) -> Str {
    match list.get(i) { some(v) => v, none => panic("unreachable: str_at out of bounds") }
}

fn row_at(list: List<List<Pattern>>, i: Int) -> List<Pattern> {
    match list.get(i) { some(v) => v, none => panic("unreachable: row_at out of bounds") }
}

fn ctor_at(list: List<Ctor>, i: Int) -> Ctor {
    match list.get(i) { some(v) => v, none => panic("unreachable: ctor_at out of bounds") }
}

// Check if a type recursively contains itself (used to decide expanding set).
// Memoized via cache.tir to avoid redundant recursive walks.
fn type_is_recursive(env: TypeEnv, ty: Type, key: Str, mut cache: ExhCache) -> Bool {
    match cache.tir.get(key) {
        some(cached) => { return cached },
        none => {}
    }
    let result = match ty {
        Type::EnumType { name, type_params } => {
            let inst_variants = instantiate_enum_variants(env, name, type_params)
            // Use Map<Str, Bool> instead of Set<Str> for O(1) lookups
            let mut visited: Map<Str, Bool> = map_new()
            visited.insert(key, true)
            let mut found = false
            for v in inst_variants {
                for ft in v.fields {
                    if type_contains_key(env, ft, key, visited) { found = true }
                }
            }
            found
        },
        _ => false,
    }
    cache.tir.insert(key, result)
    result
}

// Use Map<Str, Bool> instead of Set<Str> for O(1) string lookups.
// Set<Str> uses __ring_deep_eq linear scan — O(n) per lookup.
fn type_contains_key(
    env: TypeEnv, ty: Type, key: Str, mut visited: Map<Str, Bool>
) -> Bool with {mut<Map<Str, Bool>>} {
    let ty_str = type_to_string(ty)
    if ty_str == key { return true }
    if visited.contains_key(ty_str) { return false }
    visited.insert(ty_str, true)
    match ty {
        Type::EnumType { name, type_params } => {
            let inst_variants = instantiate_enum_variants(env, name, type_params)
            for v in inst_variants {
                for ft in v.fields {
                    if type_contains_key(env, ft, key, visited) { return true }
                }
            }
            false
        },
        Type::StructType { name, type_params } => {
            let inst_fields = instantiate_struct_fields(env, name, type_params)
            for f in inst_fields {
                if type_contains_key(env, f.ty, key, visited) { return true }
            }
            false
        },
        Type::TupleType { elements } => {
            for e in elements {
                if type_contains_key(env, e, key, visited) { return true }
            }
            false
        },
        Type::FnType { params, return_type, .. } => {
            for p in params {
                if type_contains_key(env, p, key, visited) { return true }
            }
            type_contains_key(env, return_type, key, visited)
        },
        _ => false,
    }
}

pub fn check_exhaustive(env: TypeEnv, arms: List<HMatchArm>, scrutinee_type: Type, subst: UnionFind) -> Str? {
    let mut patterns: List<Pattern> = []
    for arm in arms {
        match arm.guard {
            some(_) => {},
            none => patterns.push(arm.pattern),
        }
    }
    check_patterns(env, patterns, scrutinee_type, subst)
}

// Expand or-patterns into flat list of patterns for exhaustiveness checking
fn expand_or_patterns(patterns: List<Pattern>) -> List<Pattern> {
    let mut result: List<Pattern> = []
    for p in patterns {
        match p {
            Pattern::OrPattern { patterns: sub_pats, .. } => {
                for sp in sub_pats {
                    result.push(sp)
                }
            },
            _ => result.push(p),
        }
    }
    result
}

fn check_patterns(env: TypeEnv, patterns: List<Pattern>, ty: Type, subst: UnionFind) -> Str? {
    let resolved = apply_subst(subst, ty)
    let expanded = expand_or_patterns(patterns)

    for p in expanded {
        match p {
            Pattern::Wildcard { .. } => { return none },
            Pattern::Binding { .. } => { return none },
            _ => {},
        }
    }

    // B-132: create per-check_patterns cache for memoizing finite_type_ctors and type_is_recursive
    let mut cache = ExhCache { ftc: map_new(), tir: map_new() }

    match resolved {
        Type::EnumType { name, type_params } => {
            // Re-derive variant payloads with this instantiation's type_params
            // (A2 soundness: template variants reference the enum def's vars).
            let inst_variants = instantiate_enum_variants(env, name, type_params)
            let variant_names = inst_variants.map(fn(v) { v.name })
            // B-132: use Map<Str, Bool> for O(1) lookups instead of Set<Str>
            let mut covered: Map<Str, Bool> = map_new()

            for v in inst_variants {
                let mut sub_patterns_for_variant: List<List<Pattern>> = []
                for p in expanded {
                    match p {
                        Pattern::Constructor { name: pname, fields, .. } => {
                            if pname == v.name {
                                covered.insert(v.name, true)
                                sub_patterns_for_variant.push(fields)
                            }
                        },
                        Pattern::NamedConstructor { name: pname, fields: nfields, .. } => {
                            match v.field_names {
                                some(fnames) => {
                                    if pname == v.name {
                                        covered.insert(v.name, true)
                                        let positional = named_pattern_to_positional(nfields, fnames, v.fields.len())
                                        sub_patterns_for_variant.push(positional)
                                    }
                                },
                                none => {},
                            }
                        },
                        _ => {},
                    }
                }

                if covered.contains_key(v.name) == false {
                    // not covered yet, skip field checking
                } else {
                    if v.fields.len() > 0 {
                        let wild = Pattern::Wildcard { span: span_zero() }
                        let mut normalized: List<List<Pattern>> = []
                        for row in sub_patterns_for_variant {
                            let mut padded = list_clone(row)
                            while padded.len() < v.fields.len() {
                                padded.push(wild)
                            }
                            normalized.push(padded)
                        }
                        // B-132: use Map<Str, Bool> instead of Set<Str>
                        let mut expanding: Map<Str, Bool> = map_new()
                        expanding.insert(type_to_string(resolved), true)
                        let missing_fields = check_matrix(env, normalized, v.fields, subst, expanding, cache)
                        match missing_fields {
                            some(mf) => {
                                let joined = join_strs(mf, ", ")
                                return some("${v.name}(${joined})")
                            },
                            none => {},
                        }
                    }
                }
            }

            for vn in variant_names {
                if covered.contains_key(vn) == false {
                    return some(vn)
                }
            }
            none
        },
        Type::BoolType => {
            let mut has_true = false
            let mut has_false = false
            for p in expanded {
                match p {
                    Pattern::Literal { value, .. } => match value {
                        LiteralValue::BoolVal(b) => {
                            if b { has_true = true } else { has_false = true }
                        },
                        _ => {},
                    },
                    _ => {},
                }
            }
            if has_true == true {
                if has_false == true {
                    none
                } else {
                    some("false")
                }
            } else {
                some("true")
            }
        },
        Type::StructType { name: sname, type_params: stp } => {
            // Re-derive field types with this instantiation's type_params (A2 soundness).
            let inst_fields = instantiate_struct_fields(env, sname, stp)
            let mut covered = false
            let mut sub_patterns: List<List<Pattern>> = []
            let mut field_names: List<Str> = []
            let mut field_types: List<Type> = []
            for f in inst_fields {
                field_names.push(f.name)
                field_types.push(f.ty)
            }
            for p in expanded {
                match p {
                    Pattern::NamedConstructor { name: pname, fields: nfields, .. } => {
                        if names_match_struct(pname, sname) {
                            covered = true
                            let positional = named_pattern_to_positional(nfields, field_names, inst_fields.len())
                            sub_patterns.push(positional)
                        }
                    },
                    Pattern::Constructor { name: pname, fields: cfields, .. } => {
                        if names_match_struct(pname, sname) {
                            covered = true
                            sub_patterns.push(cfields)
                        }
                    },
                    _ => {},
                }
            }
            if covered == false {
                return some(sname)
            }
            if inst_fields.len() > 0 {
                let wild = Pattern::Wildcard { span: span_zero() }
                let mut normalized: List<List<Pattern>> = []
                for row in sub_patterns {
                    let mut padded = list_clone(row)
                    while padded.len() < inst_fields.len() {
                        padded.push(wild)
                    }
                    normalized.push(padded)
                }
                // B-132: use Map<Str, Bool> instead of Set<Str>
                let mut expanding: Map<Str, Bool> = map_new()
                expanding.insert(type_to_string(resolved), true)
                let missing_fields = check_matrix(env, normalized, field_types, subst, expanding, cache)
                match missing_fields {
                    some(mf) => {
                        let joined = join_strs(mf, ", ")
                        return some("${sname}(${joined})")
                    },
                    none => {},
                }
            }
            none
        },
        Type::UnitType => none,
        Type::TupleType { elements } => {
            let mut matrix: List<List<Pattern>> = []
            for p in expanded {
                match p {
                    Pattern::TuplePattern { elements: pelems, .. } => {
                        if pelems.len() == elements.len() {
                            matrix.push(pelems)
                        }
                    },
                    _ => {},
                }
            }
            if matrix.len() == 0 {
                let underscores = elements.map(fn(e: Type) { "_" })
                let joined = join_strs(underscores, ", ")
                return some("(${joined})")
            }
            let missing = check_matrix(env, matrix, elements, subst, map_new(), cache)
            match missing {
                some(m) => {
                    let joined = join_strs(m, ", ")
                    some("(${joined})")
                },
                none => none,
            }
        },
        _ => some("_"),
    }
}

// === Maranget-style pattern matrix exhaustiveness ===

// Memoized via cache.ftc to avoid redundant instantiate_enum_variants /
// instantiate_struct_fields calls for the same type across match arms.
fn finite_type_ctors(env: TypeEnv, ty: Type, mut cache: ExhCache) -> List<Ctor>? {
    let cache_key = type_to_string(ty)
    match cache.ftc.get(cache_key) {
        some(cached) => { return cached },
        none => {}
    }
    let result = match ty {
        Type::BoolType => {
            let mut r: List<Ctor> = []
            r.push(Ctor { name: "true", arity: 0, field_types: [], field_names: none, is_tuple: false })
            r.push(Ctor { name: "false", arity: 0, field_types: [], field_names: none, is_tuple: false })
            some(r)
        },
        Type::EnumType { name, type_params } => {
            // Re-derive variant payloads with this instantiation's type_params (A2 soundness).
            let inst_variants = instantiate_enum_variants(env, name, type_params)
            let mut r: List<Ctor> = []
            for v in inst_variants {
                r.push(Ctor { name: v.name, arity: v.fields.len(), field_types: v.fields, field_names: v.field_names, is_tuple: false })
            }
            some(r)
        },
        Type::StructType { name, type_params } => {
            // Re-derive field types with this instantiation's type_params (A2 soundness).
            let inst_fields = instantiate_struct_fields(env, name, type_params)
            let mut field_types: List<Type> = []
            let mut field_names: List<Str> = []
            for f in inst_fields {
                field_types.push(f.ty)
                field_names.push(f.name)
            }
            let mut r: List<Ctor> = []
            r.push(Ctor { name: name, arity: inst_fields.len(), field_types: field_types, field_names: some(field_names), is_tuple: false })
            some(r)
        },
        Type::UnitType => {
            let mut r: List<Ctor> = []
            r.push(Ctor { name: "()", arity: 0, field_types: [], field_names: none, is_tuple: false })
            some(r)
        },
        Type::TupleType { elements } => {
            let mut r: List<Ctor> = []
            r.push(Ctor { name: "", arity: elements.len(), field_types: elements, field_names: none, is_tuple: true })
            some(r)
        },
        _ => none,
    }
    cache.ftc.insert(cache_key, result)
    result
}

fn wild_pattern() -> Pattern {
    Pattern::Wildcard { span: span_zero() }
}

fn named_pattern_to_positional(fields: List<NamedPatternField>, field_names: List<Str>, arity: Int) -> List<Pattern> {
    let wild = wild_pattern()
    let mut result: List<Pattern> = []
    for i in 0..arity {
        result.push(wild)
    }
    for f in fields {
        let idx = index_of(field_names, f.name)
        if idx >= 0 {
            if idx < arity {
                // B-132: use List.set for O(1) replacement instead of O(n) rebuild
                result.set(idx, f.pattern)
            }
        }
    }
    result
}

fn index_of(list: List<Str>, target: Str) -> Int {
    for i in 0..list.len() {
        if str_at(list, i) == target { return i }
    }
    0 - 1
}

fn specialize_row(row: List<Pattern>, ctor: Ctor) -> List<Pattern>? with {} {
    let first = pat_at(row, 0)
    // B-132: use List.slice instead of element-by-element O(n) copy
    let rest = row.slice(1, row.len())

    match first {
        Pattern::Wildcard { .. } => {
            let mut result: List<Pattern> = []
            let wild = wild_pattern()
            for i in 0..ctor.arity {
                result.push(wild)
            }
            result.extend(rest)
            some(result)
        },
        Pattern::Binding { .. } => {
            let mut result: List<Pattern> = []
            let wild = wild_pattern()
            for i in 0..ctor.arity {
                result.push(wild)
            }
            result.extend(rest)
            some(result)
        },
        Pattern::Literal { value, .. } => {
            match value {
                LiteralValue::BoolVal(b) => {
                    let match_name = if b { "true" } else { "false" }
                    if match_name == ctor.name {
                        some(rest)
                    } else {
                        none
                    }
                },
                _ => none,
            }
        },
        Pattern::Constructor { name, fields, .. } => {
            if names_match_struct(name, ctor.name) {
                let mut sub = list_clone(fields)
                let wild = wild_pattern()
                while sub.len() < ctor.arity {
                    sub.push(wild)
                }
                sub.extend(rest)
                some(sub)
            } else {
                none
            }
        },
        Pattern::NamedConstructor { name, fields: nfields, .. } => {
            if names_match_struct(name, ctor.name) {
                let field_names = match ctor.field_names {
                    some(fns) => fns,
                    none => {
                        let empty: List<Str> = []
                        empty
                    },
                }
                let mut positional = named_pattern_to_positional(nfields, field_names, ctor.arity)
                positional.extend(rest)
                some(positional)
            } else {
                none
            }
        },
        Pattern::TuplePattern { elements, .. } => {
            if ctor.is_tuple == true {
                if elements.len() == ctor.arity {
                    let mut result = list_clone(elements)
                    result.extend(rest)
                    some(result)
                } else {
                    none
                }
            } else {
                none
            }
        },
        Pattern::OrPattern { patterns: sub_pats, .. } => {
            // Try each sub-pattern; return the first that matches
            for sp in sub_pats {
                let mut trial_row: List<Pattern> = [sp]
                trial_row.extend(rest)
                let result = specialize_row(trial_row, ctor)
                match result {
                    some(_) => { return result },
                    none => {},
                }
            }
            none
        },
    }
}

// B-132: expanding uses Map<Str, Bool> for O(1) string lookups instead of
// Set<Str> which uses __ring_deep_eq linear scan.
// cache is threaded through for memoizing finite_type_ctors and type_is_recursive.
fn check_matrix(
    env: TypeEnv,
    rows: List<List<Pattern>>,
    col_types: List<Type>,
    subst: UnionFind,
    expanding: Map<Str, Bool>,
    mut cache: ExhCache
) -> List<Str>? with {mut<UnionFind>, mut<ExhCache>, mut<List<Type>>} {
    if col_types.len() == 0 {
        if rows.len() > 0 {
            return none
        } else {
            let empty: List<Str> = []
            return some(empty)
        }
    }

    let first_type = apply_subst(subst, type_at(col_types, 0))
    // B-132: use List.slice instead of element-by-element O(n) copy
    let rest_types = col_types.slice(1, col_types.len())

    let type_key = match first_type {
        Type::EnumType { .. } => type_to_string(first_type),
        _ => "",
    }
    let is_reentrant = if type_key != "" { expanding.contains_key(type_key) } else { false }
    let ctors = if is_reentrant { none } else { finite_type_ctors(env, first_type, cache) }

    match ctors {
        some(ctor_list) => {
            let mut new_expanding = map_clone(expanding)
            if type_key != "" {
                if type_is_recursive(env, first_type, type_key, cache) {
                    new_expanding.insert(type_key, true)
                }
            }
            for ctor in ctor_list {
                let mut specialized: List<List<Pattern>> = []
                for row in rows {
                    match specialize_row(row, ctor) {
                        some(s) => specialized.push(s),
                        none => {},
                    }
                }
                let mut new_types: List<Type> = []
                new_types.extend(ctor.field_types)
                new_types.extend(rest_types)
                let sub = check_matrix(env, specialized, new_types, subst, new_expanding, cache)
                match sub {
                    some(sub_result) => {
                        // B-132: use List.slice instead of element-by-element copy
                        let ctor_sub = sub_result.slice(0, ctor.arity)
                        let rest_sub = sub_result.slice(ctor.arity, sub_result.len())
                        let mut ctor_str = ""
                        if ctor.is_tuple {
                            let joined_sub = join_strs(ctor_sub, ", ")
                            ctor_str = "(${joined_sub})"
                        } else {
                            if ctor.arity == 0 {
                                ctor_str = ctor.name
                            } else {
                                let joined_sub2 = join_strs(ctor_sub, ", ")
                                ctor_str = "${ctor.name}(${joined_sub2})"
                            }
                        }
                        let mut result: List<Str> = []
                        result.push(ctor_str)
                        result.extend(rest_sub)
                        return some(result)
                    },
                    none => {},
                }
            }
            none
        },
        none => {
            let mut defaults: List<List<Pattern>> = []
            for row in rows {
                let first = pat_at(row, 0)
                let mut is_default = false
                match first {
                    Pattern::Wildcard { .. } => { is_default = true },
                    Pattern::Binding { .. } => { is_default = true },
                    Pattern::OrPattern { patterns: sub_pats, .. } => {
                        for sp in sub_pats {
                            match sp {
                                Pattern::Wildcard { .. } => { is_default = true },
                                Pattern::Binding { .. } => { is_default = true },
                                _ => {},
                            }
                        }
                    },
                    _ => {},
                }
                if is_default {
                    // B-132: use List.slice instead of element-by-element O(n) copy
                    let tail = row.slice(1, row.len())
                    defaults.push(tail)
                }
            }
            let sub = check_matrix(env, defaults, rest_types, subst, expanding, cache)
            match sub {
                some(s) => {
                    let mut result: List<Str> = []
                    result.push("_")
                    result.extend(s)
                    some(result)
                },
                none => none,
            }
        },
    }
}

// Compare pattern name (raw, e.g. "Pair") against type name (possibly qualified, e.g. "inner::Pair").
// Returns true if they are equal or if type_name ends with "::pattern_name" (mod-qualified).
fn names_match_struct(pattern_name: Str, type_name: Str) -> Bool {
    if pattern_name == type_name { return true }
    type_name.ends_with("::${pattern_name}")
}

fn join_strs(parts: List<Str>, sep: Str) -> Str {
    let mut result = ""
    for i in 0..parts.len() {
        if i > 0 { result = "${result}${sep}" }
        let part = str_at(parts, i)
        result = "${result}${part}"
    }
    result
}
