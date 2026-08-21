// ============================================================
// andor_lower.ring — B-104 D7: `&&` / `||` lowered to if-else
// ============================================================
//
// Runs once per module at the end of checking (checker.ring), BEFORE
// dict_lower / perceus and BOTH backends, so And/Or never reach the RC pass,
// the verifier, or either codegen as BinOps (dict_lower.ring precedent).
//
//   a && b   →   if a { b } else { false }
//   a || b   →   if a { true } else { b }
//
// Short-circuit semantics are preserved by construction (an IfExpr branch is
// evaluated only on its taken edge).  Motivation (D5 attribution, 2026-06-12):
// the LLVM gen_and/gen_or phi yielded the RHS operand box VERBATIM on the
// taken edge — possibly a borrow — so the result could never be dropped
// (x-andor, ≈69M = 31% of native residual live @2.382B) and an entire family
// of RC special cases existed solely to keep that phi from being freed
// (anf_cond_in_own_scope on the RHS, the non-blanket W3a branch recursion,
// the D2-#3 visible-owned gate instance, is_fresh_owned_bool_value's And/Or
// arm).  Post-lower the arms are ordinary branch blocks:
//   * arm-internal owned temporaries materialise + scope-end-drop inside the
//     branch (D1 machinery — the same leak D5 measured under the old form);
//   * the phi value follows the ordinary IfExpr accounting — droppable-init
//     recursion at bindings, value-position materialisation when all arms are
//     fresh (anf_should_materialize's IfExpr arm), codegen post-unbox drop in
//     while-cond/guard positions (is_fresh_owned_bool_value recursion);
//   * a borrow arm (`a && obj.flag`) keeps the conservative x-cf-value
//     posture — exactly the old And/Or leak-direction conservatism, now with
//     no bespoke machinery.
//
// Codegen emits IfExpr lowering for these: output SHAPE changes, behavior
// does not (`a && b` on Ring Bools ≡ `a ? b : false`).  No HIR node kinds
// are added or removed — BinOp::And/Or simply no longer occur downstream of
// the checker (downstream arms panic).

use ast::{Span, BinOp}
use types::{Type, EffectRow, EMPTY_ROW}
use hir::{HProgram, HDecl, HStmt, HExpr, HMatchArm, HStructFieldInit,
    HStringInterpPart, HEffectHandler, HEffectOp, HTraitMethod}

pub fn lower_andor(program: HProgram) -> HProgram {
    let mut new_decls: List<HDecl> = []
    for d in program.decls {
        new_decls.push(al_decl(d))
    }
    HProgram {
        decls: new_decls,
        derived_impls: program.derived_impls,
        boxed_vars: program.boxed_vars,
        static_dicts: program.static_dicts,
        extern_type_names: program.extern_type_names,
        drop_types: program.drop_types,
        effect_op_identities: program.effect_op_identities
    }
}

fn al_decl(d: HDecl) -> HDecl {
    match d {
        HDecl::Fn { name, def_id, type_params, params, return_type, effects, body, is_pub, trait_bounds, span } =>
            HDecl::Fn { name: name, def_id: def_id, type_params: type_params, params: params,
                return_type: return_type, effects: effects,
                body: al_expr(body),
                is_pub: is_pub, trait_bounds: trait_bounds, span: span },
        HDecl::Impl { target_type, type_params, trait_name, methods, assoc_types, span } => {
            let mut new_methods: List<HDecl> = []
            for m in methods { new_methods.push(al_decl(m)) }
            HDecl::Impl { target_type: target_type, type_params: type_params, trait_name: trait_name,
                methods: new_methods, assoc_types: assoc_types, span: span }
        },
        HDecl::Test { description, body, span } =>
            HDecl::Test { description: description, body: al_expr(body), span: span },
        HDecl::Const { name, def_id, ty, init, is_pub, span } =>
            HDecl::Const { name: name, def_id: def_id, ty: ty,
                init: al_expr(init), is_pub: is_pub, span: span },
        HDecl::ModBlock { name, decls, is_pub, span } => {
            let mut new_inner: List<HDecl> = []
            for md in decls { new_inner.push(al_decl(md)) }
            HDecl::ModBlock { name: name, decls: new_inner, is_pub: is_pub, span: span }
        },
        HDecl::Trait { name, type_params, methods, supertraits, assoc_types, is_pub, span } => {
            // Default method bodies are real HIR (checked by infer) — lower them too.
            let mut new_methods: List<HTraitMethod> = []
            for tm in methods {
                let new_body = match tm.body {
                    some(b) => some(al_expr(b)),
                    none => none,
                }
                new_methods.push(HTraitMethod { name: tm.name,
                    def_id: tm.def_id, params: tm.params,
                    return_type: tm.return_type, effects: tm.effects, has_default: tm.has_default, body: new_body })
            }
            HDecl::Trait { name: name, type_params: type_params, methods: new_methods,
                supertraits: supertraits, assoc_types: assoc_types, is_pub: is_pub, span: span }
        },
        HDecl::Struct { name, type_params, fields, is_pub, span } =>
            HDecl::Struct { name: name, type_params: type_params, fields: fields, is_pub: is_pub, span: span },
        HDecl::Enum { name, type_params, variants, is_pub, span } =>
            HDecl::Enum { name: name, type_params: type_params, variants: variants, is_pub: is_pub, span: span },
        HDecl::Effect { name, type_params, ops, is_pub, span } => {
            let mut new_ops: List<HEffectOp> = []
            for op in ops {
                let new_default_body = match op.default_body {
                    some(body) => some(al_expr(body)),
                    none => none,
                }
                new_ops.push(HEffectOp {
                    name: op.name, def_id: op.def_id,
                    params: op.params, return_type: op.return_type,
                    has_default: op.has_default, default_body: new_default_body
                })
            }
            HDecl::Effect { name: name, type_params: type_params, ops: new_ops, is_pub: is_pub, span: span }
        },
        HDecl::ExternFn { name, abi_name, def_id, type_params, params, return_type, effects, is_pub, span } =>
            HDecl::ExternFn { name: name, abi_name: abi_name, def_id: def_id, type_params: type_params, params: params, return_type: return_type, effects: effects, is_pub: is_pub, span: span },
        HDecl::ExternType { name, type_params, is_pub, span } =>
            HDecl::ExternType { name: name, type_params: type_params, is_pub: is_pub, span: span },
        HDecl::TypeAlias { name, ty, is_pub, span } =>
            HDecl::TypeAlias { name: name, ty: ty, is_pub: is_pub, span: span },
        HDecl::Sig { name, members, is_pub, span } =>
            HDecl::Sig { name: name, members: members, is_pub: is_pub, span: span },
    }
}

// ============================================================
// Structural walkers
// ============================================================

fn al_expr(e: HExpr) -> HExpr {
    match e {
        HExpr::IntLit { value, ty, effects, span } =>
            HExpr::IntLit { value: value, ty: ty, effects: effects, span: span },
        HExpr::FloatLit { value, ty, effects, span } =>
            HExpr::FloatLit { value: value, ty: ty, effects: effects, span: span },
        HExpr::StrLit { value, ty, effects, span } =>
            HExpr::StrLit { value: value, ty: ty, effects: effects, span: span },
        HExpr::BoolLit { value, ty, effects, span } =>
            HExpr::BoolLit { value: value, ty: ty, effects: effects, span: span },
        HExpr::Ident { name, resolved_name, def_id, dict_closure_dicts, ty, effects, span } =>
            HExpr::Ident { name: name, resolved_name: resolved_name, def_id: def_id, dict_closure_dicts: dict_closure_dicts, ty: ty, effects: effects, span: span },
        HExpr::BinOp { op, left, right, eq_dispatch, ord_dispatch, ty, effects, span } => {
            let new_left = al_expr(left)
            let new_right = al_expr(right)
            match op {
                // a && b → if a { b } else { false }.  The else arm is a fresh
                // BoolLit (a per-evaluation box at LLVM, reclaimed by the same
                // accounting as the then arm); ty/effects of the whole phi are
                // the BinOp's (Bool, union of operand effects).
                BinOp::And => HExpr::IfExpr {
                    condition: new_left,
                    then_branch: new_right,
                    else_branch: some(HExpr::BoolLit { value: false, ty: Type::BoolType, effects: EMPTY_ROW, span: span }),
                    ty: ty, effects: effects, span: span
                },
                // a || b → if a { true } else { b }.
                BinOp::Or => HExpr::IfExpr {
                    condition: new_left,
                    then_branch: HExpr::BoolLit { value: true, ty: Type::BoolType, effects: EMPTY_ROW, span: span },
                    else_branch: some(new_right),
                    ty: ty, effects: effects, span: span
                },
                _ => HExpr::BinOp { op: op, left: new_left, right: new_right,
                    eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch,
                    ty: ty, effects: effects, span: span },
            }
        },
        HExpr::UnaryOp { op, operand, ty, effects, span } =>
            HExpr::UnaryOp { op: op, operand: al_expr(operand), ty: ty, effects: effects, span: span },
        HExpr::Call { callee, callee_def_id, callable_result_def_id,
                      args, type_args, resolved_dicts, dict_dispatch,
                      ty, effects, span } => {
            let new_callee = al_expr(callee)
            let mut new_args: List<HExpr> = []
            for a in args { new_args.push(al_expr(a)) }
            HExpr::Call { callee: new_callee,
                callee_def_id: callee_def_id,
                callable_result_def_id: callable_result_def_id,
                args: new_args, type_args: type_args,
                resolved_dicts: resolved_dicts, dict_dispatch: dict_dispatch,
                ty: ty, effects: effects, span: span }
        },
        HExpr::FieldAccess { receiver, field, ty, effects, span } =>
            HExpr::FieldAccess { receiver: al_expr(receiver), field: field, ty: ty, effects: effects, span: span },
        HExpr::StructLit { name, type_args, fields, spread, ty, effects, span } => {
            let mut new_fields: List<HStructFieldInit> = []
            for f in fields {
                new_fields.push(HStructFieldInit { name: f.name, value: al_expr(f.value) })
            }
            let new_spread = match spread {
                some(s) => some(al_expr(s)),
                none => none,
            }
            HExpr::StructLit { name: name, type_args: type_args, fields: new_fields, spread: new_spread, ty: ty, effects: effects, span: span }
        },
        HExpr::NamedVariantConstruct { enum_name, variant_name, fields, spread, ty, effects, span } => {
            let mut new_fields: List<HStructFieldInit> = []
            for f in fields {
                new_fields.push(HStructFieldInit { name: f.name, value: al_expr(f.value) })
            }
            let new_spread = match spread {
                some(s) => some(al_expr(s)),
                none => none,
            }
            HExpr::NamedVariantConstruct { enum_name: enum_name, variant_name: variant_name, fields: new_fields, spread: new_spread, ty: ty, effects: effects, span: span }
        },
        HExpr::MatchExpr { scrutinee, arms, ty, effects, span } =>
            HExpr::MatchExpr { scrutinee: al_expr(scrutinee),
                arms: al_arms(arms), ty: ty, effects: effects, span: span },
        HExpr::Block { stmts, tail, ty, effects, span } => {
            let mut new_stmts: List<HStmt> = []
            for s in stmts { new_stmts.push(al_stmt(s)) }
            let new_tail = match tail {
                some(t) => some(al_expr(t)),
                none => none,
            }
            HExpr::Block { stmts: new_stmts, tail: new_tail, ty: ty, effects: effects, span: span }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, ty, effects, span } => {
            let new_else = match else_branch {
                some(eb) => some(al_expr(eb)),
                none => none,
            }
            HExpr::IfExpr { condition: al_expr(condition),
                then_branch: al_expr(then_branch),
                else_branch: new_else, ty: ty, effects: effects, span: span }
        },
        HExpr::StringInterp { parts, ty, effects, span } => {
            let mut new_parts: List<HStringInterpPart> = []
            for p in parts {
                match p {
                    HStringInterpPart::Literal(s) => new_parts.push(HStringInterpPart::Literal(s)),
                    HStringInterpPart::Expression(ex) => new_parts.push(HStringInterpPart::Expression(al_expr(ex))),
                }
            }
            HExpr::StringInterp { parts: new_parts, ty: ty, effects: effects, span: span }
        },
        HExpr::TryCatch { body, arms, ty, effects, span } =>
            HExpr::TryCatch { body: al_expr(body),
                arms: al_arms(arms), ty: ty, effects: effects, span: span },
        HExpr::HandleExpr { body, handlers, ty, effects, span } => {
            let mut new_handlers: List<HEffectHandler> = []
            for h in handlers {
                new_handlers.push(HEffectHandler { effect_name: h.effect_name,
                    op_name: h.op_name, op_def_id: h.op_def_id,
                    params: h.params, resume_binding: h.resume_binding,
                    body: al_expr(h.body) })
            }
            HExpr::HandleExpr { body: al_expr(body), handlers: new_handlers, ty: ty, effects: effects, span: span }
        },
        HExpr::Lambda { def_id, params, return_type, body, ty, effects, span } =>
            HExpr::Lambda { def_id: def_id,
                params: params, return_type: return_type,
                body: al_expr(body), ty: ty, effects: effects, span: span },
        HExpr::EffectOp { effect_name, op_name, op_def_id,
                          args, ty, effects, span } => {
            let mut new_args: List<HExpr> = []
            for a in args { new_args.push(al_expr(a)) }
            HExpr::EffectOp { effect_name: effect_name, op_name: op_name,
                op_def_id: op_def_id, args: new_args,
                ty: ty, effects: effects, span: span }
        },
        HExpr::RangeExpr { start, end, inclusive, ty, effects, span } =>
            HExpr::RangeExpr { start: al_expr(start),
                end: al_expr(end), inclusive: inclusive, ty: ty, effects: effects, span: span },
        HExpr::ListLit { elements, ty, effects, span } => {
            let mut new_elems: List<HExpr> = []
            for el in elements { new_elems.push(al_expr(el)) }
            HExpr::ListLit { elements: new_elems, ty: ty, effects: effects, span: span }
        },
        HExpr::TupleLit { elements, ty, effects, span } => {
            let mut new_elems: List<HExpr> = []
            for el in elements { new_elems.push(al_expr(el)) }
            HExpr::TupleLit { elements: new_elems, ty: ty, effects: effects, span: span }
        },
        HExpr::IndexExpr { receiver, index, ty, effects, span } =>
            HExpr::IndexExpr { receiver: al_expr(receiver),
                index: al_expr(index), ty: ty, effects: effects, span: span },
        // Created by dict_lower, which runs AFTER this pass — never present.
        HExpr::DictConstruct { base_dict, trait_name, inner, ty, effects, span } =>
            HExpr::DictConstruct { base_dict: base_dict, trait_name: trait_name, inner: inner, ty: ty, effects: effects, span: span },
        // Clone is inserted by perceus (runs after this pass) — never present.
        HExpr::Clone { inner, ty, effects, span } =>
            HExpr::Clone { inner: al_expr(inner), ty: ty, effects: effects, span: span },
        // B-113: return in expression position (match arm)
        HExpr::ReturnExpr { value, ty, effects, span } => match value {
            some(v) => HExpr::ReturnExpr { value: some(al_expr(v)), ty: ty, effects: effects, span: span },
            none => HExpr::ReturnExpr { value: none, ty: ty, effects: effects, span: span },
        },
        // B-125: unsafe block — recurse into body
        HExpr::UnsafeBlock { body, ty, effects, span } =>
            HExpr::UnsafeBlock { body: al_expr(body), ty: ty, effects: effects, span: span },
    }
}

fn al_arms(arms: List<HMatchArm>) -> List<HMatchArm> {
    let mut out: List<HMatchArm> = []
    for arm in arms {
        let new_guard = match arm.guard {
            some(g) => some(al_expr(g)),
            none => none,
        }
        out.push(HMatchArm { pattern: arm.pattern, bindings: arm.bindings,
            guard: new_guard,
            body: al_expr(arm.body), span: arm.span })
    }
    out
}

fn al_stmt(s: HStmt) -> HStmt {
    match s {
        HStmt::Let { name, name_span, def_id, ty, init, span } =>
            HStmt::Let { name: name, name_span: name_span, def_id: def_id, ty: ty,
                init: al_expr(init), span: span },
        HStmt::Var { name, name_span, def_id, ty, init, span } =>
            HStmt::Var { name: name, name_span: name_span, def_id: def_id, ty: ty,
                init: al_expr(init), span: span },
        HStmt::Assign { target, value, span } =>
            HStmt::Assign { target: al_expr(target),
                value: al_expr(value), span: span },
        HStmt::ExprStmt { expr, span } =>
            HStmt::ExprStmt { expr: al_expr(expr), span: span },
        HStmt::Return { value, span } => {
            let new_value = match value {
                some(v) => some(al_expr(v)),
                none => none,
            }
            HStmt::Return { value: new_value, span: span }
        },
        HStmt::While { condition, body, span } =>
            HStmt::While { condition: al_expr(condition),
                body: al_expr(body), span: span },
        HStmt::ForIn { binding, binding_span, def_id, destructure, iterable, body, iterable_type_name, iter_type_name, span } =>
            HStmt::ForIn { binding: binding, binding_span: binding_span, def_id: def_id,
                destructure: destructure,
                iterable: al_expr(iterable),
                body: al_expr(body),
                iterable_type_name: iterable_type_name, iter_type_name: iter_type_name, span: span },
        HStmt::Break { span } => HStmt::Break { span: span },
        HStmt::Continue { span } => HStmt::Continue { span: span },
        HStmt::LetDestructure { pattern, bindings, init, span } =>
            HStmt::LetDestructure { pattern: pattern, bindings: bindings,
                init: al_expr(init), span: span },
        HStmt::IfLet { pattern, bindings, expr, then_block, else_block, span } => {
            let new_else = match else_block {
                some(eb) => some(al_expr(eb)),
                none => none,
            }
            HStmt::IfLet { pattern: pattern, bindings: bindings,
                expr: al_expr(expr),
                then_block: al_expr(then_block), else_block: new_else, span: span }
        },
        // RC ops are inserted by perceus (after this pass) — never present.
        HStmt::Drop { name, def_id, ty, span } =>
            HStmt::Drop { name: name, def_id: def_id, ty: ty, span: span }
    }
}
