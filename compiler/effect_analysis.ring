// effect_analysis.ring — shared effect/callee analysis functions used by codegen.

use types::{Type, Effect, EffectRow, effect_kind_name}
use hir::{HExpr, HStmt, HDecl, HParam, HStructField, HEnumVariant,
    HStringInterpPart, HMatchArm, HEffectHandler, HStructFieldInit,
    hexpr_type}

// ============================================================
// Effect name extraction (from codegen_ctx.ring)
// ============================================================

pub fn extract_effect_names(effects: EffectRow) -> List<Str> {
    let mut names: List<Str> = []
    for e in effects.effects {
        // Only custom handled effects have runtime evidence. System effects
        // are static HostImport capabilities; fail/mut/unsafe have dedicated
        // non-evidence semantics.
        match e {
            Effect::CustomEffect { .. } => {
                let n = effect_kind_name(e)
                if names.contains(n) == false {
                    names.push(n)
                }
            },
            Effect::SystemEffect { .. } => {},
            Effect::FailEffect { .. } => {},
            Effect::MutEffect { .. } => {},
            Effect::UnsafeEffect => {}
        }
    }
    names.sort()
    names
}

// ============================================================
// Callee collection
// ============================================================

pub fn collect_fn_callees(decls: List<HDecl>, local_names: Set<Str>, mut fn_callees: Map<Str, Set<Str>>) {
    for decl in decls {
        match decl {
            HDecl::Fn { name, body, .. } => {
                let mut callees = set_new()
                collect_local_calls(body, local_names, callees)
                fn_callees.insert(name, callees)
            },
            HDecl::Impl { target_type, methods, .. } => {
                for m in methods {
                    match m {
                        HDecl::Fn { name: mn, body: mb, .. } => {
                            let mut callees = set_new()
                            collect_local_calls(mb, local_names, callees)
                            // Use qualified key matching scan_fn_effects / collect_local_names_rec
                            let qualified = "${target_type}_${mn}"
                            fn_callees.insert(qualified, callees)
                        },
                        _ => {},
                    }
                }
            },
            HDecl::ModBlock { decls: mod_decls, .. } => {
                collect_fn_callees(mod_decls, local_names, fn_callees)
            },
            _ => {},
        }
    }
}

pub fn collect_local_calls(expr: HExpr, local_names: Set<Str>, mut out: Set<Str>) {
    match expr {
        HExpr::Call { callee, args, .. } => {
            match callee {
                HExpr::Ident { name, .. } => {
                    if local_names.contains(name) { out.insert(name) }
                },
                HExpr::FieldAccess { receiver: recv, field, .. } => {
                    // Try qualified name first for impl methods (LLVM backend
                    // registers impl methods as "TypeName_method" in local_names).
                    // Only fall back to unqualified name when no qualified match
                    // is found — prevents collisions with same-named top-level fns.
                    let mut found_qualified = false
                    match hexpr_type(recv) {
                        Type::StructType { name: tn, .. } => {
                            let qn = "${tn}_${field}"
                            if local_names.contains(qn) {
                                out.insert(qn)
                                found_qualified = true
                            }
                        },
                        Type::EnumType { name: tn, .. } => {
                            let qn = "${tn}_${field}"
                            if local_names.contains(qn) {
                                out.insert(qn)
                                found_qualified = true
                            }
                        },
                        // #211: GenericType wraps a base type with type args
                        // (e.g. GenericType { base: StructType { name: "List" }, args: [IntType] }).
                        // Extract the base type name for qualified lookup.
                        Type::GenericType { base, .. } => {
                            match base {
                                Type::StructType { name: tn, .. } => {
                                    let qn = "${tn}_${field}"
                                    if local_names.contains(qn) {
                                        out.insert(qn)
                                        found_qualified = true
                                    }
                                },
                                Type::EnumType { name: tn, .. } => {
                                    let qn = "${tn}_${field}"
                                    if local_names.contains(qn) {
                                        out.insert(qn)
                                        found_qualified = true
                                    }
                                },
                                _ => {},
                            }
                        },
                        _ => {},
                    }
                    if !found_qualified {
                        if local_names.contains(field) { out.insert(field) }
                    }
                },
                _ => {},
            }
            collect_local_calls(callee, local_names, out)
            for a in args { collect_local_calls(a, local_names, out) }
        },
        HExpr::Block { stmts, tail, .. } => {
            for s in stmts { collect_local_calls_stmt(s, local_names, out) }
            match tail {
                some(t) => collect_local_calls(t, local_names, out),
                none => {},
            }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            collect_local_calls(condition, local_names, out)
            collect_local_calls(then_branch, local_names, out)
            match else_branch {
                some(eb) => collect_local_calls(eb, local_names, out),
                none => {},
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            collect_local_calls(scrutinee, local_names, out)
            for arm in arms {
                collect_local_calls(arm.body, local_names, out)
                match arm.guard {
                    some(g) => collect_local_calls(g, local_names, out),
                    none => {},
                }
            }
        },
        HExpr::BinOp { left, right, .. } => {
            collect_local_calls(left, local_names, out)
            collect_local_calls(right, local_names, out)
        },
        HExpr::UnaryOp { operand, .. } => {
            collect_local_calls(operand, local_names, out)
        },
        HExpr::FieldAccess { receiver, .. } => {
            collect_local_calls(receiver, local_names, out)
        },
        HExpr::StructLit { fields, spread, .. } => {
            for f in fields { collect_local_calls(f.value, local_names, out) }
            match spread {
                some(s) => collect_local_calls(s, local_names, out),
                none => {},
            }
        },
        HExpr::NamedVariantConstruct { fields, spread, .. } => {
            for f in fields { collect_local_calls(f.value, local_names, out) }
            match spread {
                some(s) => collect_local_calls(s, local_names, out),
                none => {},
            }
        },
        HExpr::StringInterp { parts, .. } => {
            for p in parts {
                match p {
                    HStringInterpPart::Expression(e) => collect_local_calls(e, local_names, out),
                    HStringInterpPart::Literal(_) => {},
                }
            }
        },
        HExpr::TryCatch { body, arms, .. } => {
            collect_local_calls(body, local_names, out)
            for arm in arms {
                match arm.guard {
                    some(g) => collect_local_calls(g, local_names, out),
                    none => {},
                }
                collect_local_calls(arm.body, local_names, out)
            }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            collect_local_calls(body, local_names, out)
            for h in handlers { collect_local_calls(h.body, local_names, out) }
        },
        HExpr::Lambda { body, .. } => {
            collect_local_calls(body, local_names, out)
        },
        HExpr::RangeExpr { start, end, .. } => {
            collect_local_calls(start, local_names, out)
            collect_local_calls(end, local_names, out)
        },
        HExpr::ListLit { elements, .. } => {
            for e in elements { collect_local_calls(e, local_names, out) }
        },
        HExpr::TupleLit { elements, .. } => {
            for e in elements { collect_local_calls(e, local_names, out) }
        },
        HExpr::EffectOp { args, .. } => {
            for a in args { collect_local_calls(a, local_names, out) }
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            collect_local_calls(receiver, local_names, out)
            collect_local_calls(index, local_names, out)
        },
        HExpr::ReturnExpr { value, .. } => {
            match value {
                some(v) => collect_local_calls(v, local_names, out),
                none => {},
            }
        },
        HExpr::Clone { inner, .. } => {
            collect_local_calls(inner, local_names, out)
        },
        HExpr::Take { source, .. } => {
            collect_local_calls(source, local_names, out)
        },
        // B-125: unsafe block — recurse into body
        HExpr::UnsafeBlock { body, .. } => {
            collect_local_calls(body, local_names, out)
        },
        _ => {},
    }
}

pub fn collect_local_calls_stmt(stmt: HStmt, local_names: Set<Str>, mut out: Set<Str>) {
    match stmt {
        HStmt::Let { init, .. } => collect_local_calls(init, local_names, out),
        HStmt::Var { init, .. } => collect_local_calls(init, local_names, out),
        HStmt::Assign { target, value, .. } => {
            collect_local_calls(target, local_names, out)
            collect_local_calls(value, local_names, out)
        },
        HStmt::ExprStmt { expr, .. } => collect_local_calls(expr, local_names, out),
        HStmt::Return { value, .. } => {
            match value {
                some(v) => collect_local_calls(v, local_names, out),
                none => {},
            }
        },
        HStmt::While { condition, body, .. } => {
            collect_local_calls(condition, local_names, out)
            collect_local_calls(body, local_names, out)
        },
        HStmt::ForIn { iterable, body, .. } => {
            collect_local_calls(iterable, local_names, out)
            collect_local_calls(body, local_names, out)
        },
        HStmt::LetDestructure { init, .. } => collect_local_calls(init, local_names, out),
        HStmt::IfLet { expr, then_block, else_block, .. } => {
            collect_local_calls(expr, local_names, out)
            collect_local_calls(then_block, local_names, out)
            match else_block {
                some(eb) => collect_local_calls(eb, local_names, out),
                none => {},
            }
        },
        _ => {},
    }
}
