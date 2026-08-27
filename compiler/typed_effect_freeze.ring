// TypedHIR's one-way effect-formal freeze.
//
// This pass runs after all semantic lowering and ordinary zonking, but before
// Core assembly.  It assigns each still-generalized effect-row tail a stable
// exact owner and owner-local ordinal.  Core receives only this immutable
// relation: it may look a tail up, but may not choose an owner, allocate an
// ordinal, or reopen effect inference.

use types::{Type, Effect, EffectRow, types_equal}
use env::{TypeEnv}
use hir::{
    HProgram, HDecl, HExpr, HStmt, HParam, HMatchArm, HEffectHandler,
    HStringInterpPart, DerivedImpl, DerivedFieldRef,
    hexpr_type, hexpr_effects,
    h_delegate_methods, h_delegate_assoc_bindings,
    h_delegate_method_executable, h_delegate_method_parameter_types,
    h_delegate_method_result_type, h_delegate_method_effects,
    h_delegate_method_child_call, h_delegate_assoc_member,
    h_delegate_assoc_type,
    h_default_specialization_generated_executable,
    h_default_specialization_parameter_types,
    h_default_specialization_result_type,
    h_default_specialization_effects,
    h_default_specialization_forward_call,
    h_exact_call_signature, method_call_ref_signature,
    h_projection_kind, h_projection_nominal, h_projection_variant
}
use builtins::{
    builtin_method_contract_facts, builtin_method_contract_intrinsic,
    builtin_method_contract_scheme
}
use ir_identity::{
    OriginRef, SymbolRef,
    make_symbol_origin_ref, make_path_origin_ref, origin_ref_same,
    registered_nominal_ref_symbol,
    nominal_field_ref_member, variant_field_ref_member,
    impl_owner_ref_provider, impl_provider_ref_site,
    intrinsic_ref_symbol, symbol_ref_same
}
use ir_inventory::{
    ExecutableRef, executable_ref_is_named, executable_ref_named_symbol,
    executable_ref_anonymous_path, executable_ref_same,
    make_named_executable_ref,
    effect_operation_ref_callable, effect_operation_ref_effect
}
use effect_contract::{
    TypedEffectFormalFact, make_typed_effect_formal_fact,
    typed_effect_formal_raw_tail, typed_effect_formal_parameter,
    make_effect_param_ref,
    effect_param_owner, effect_param_ref_same
}

struct TypedEffectFreezeState {
    env: TypeEnv,
    facts: List<TypedEffectFormalFact>,
    callables: List<TypedCallableEffectFact>,
    visited_nominals: List<SymbolRef>,
    header_tails: List<Int>,
    schema_use_tails: List<Int>,
    scope_owners: List<OriginRef>
}

enum EffectFormalScanMode {
    HeaderFormal,
    SchemaUseFormal,
    ValidateFormal
}

pub struct TypedCallableEffectFact {
    reference: ExecutableRef,
    row: EffectRow
}

pub fn typed_callable_effect_reference(
    value: TypedCallableEffectFact
) -> ExecutableRef { value.reference }

pub fn typed_callable_effect_row(
    value: TypedCallableEffectFact
) -> EffectRow {
    EffectRow { effects: value.row.effects, tail: value.row.tail }
}

pub struct TypedEffectFreezeResult {
    formals: List<TypedEffectFormalFact>,
    callables: List<TypedCallableEffectFact>
}

pub fn typed_effect_freeze_formals(
    value: TypedEffectFreezeResult
) -> List<TypedEffectFormalFact> {
    value.formals.map(fn(fact) { fact })
}

pub fn typed_effect_freeze_callables(
    value: TypedEffectFreezeResult
) -> List<TypedCallableEffectFact> {
    value.callables.map(fn(fact) { fact })
}

fn executable_origin(value: ExecutableRef) -> OriginRef {
    if executable_ref_is_named(value) {
        make_symbol_origin_ref(executable_ref_named_symbol(value))
    } else {
        make_path_origin_ref(executable_ref_anonymous_path(value))
    }
}

fn enter_formal_scope(
    mut state: TypedEffectFreezeState, owner: OriginRef
) { state.scope_owners.push(owner) }

fn exit_formal_scope(mut state: TypedEffectFreezeState, owner: OriginRef) {
    match state.scope_owners.pop() {
        some(actual) => if !origin_ref_same(actual, owner) {
            panic("typed effect freeze: lexical owner stack drifted")
        },
        none => panic("typed effect freeze: lexical owner stack underflow")
    }
}

fn formal_fact_for_raw(
    state: TypedEffectFreezeState, raw_tail: Int
) -> TypedEffectFormalFact? {
    let mut found: TypedEffectFormalFact? = none
    for fact in state.facts {
        if typed_effect_formal_raw_tail(fact) == raw_tail {
            if found.is_some() {
                panic("typed effect freeze: raw tail has two binders")
            }
            found = some(fact)
        }
    }
    found
}

fn owner_is_visible(
    state: TypedEffectFreezeState, owner: OriginRef,
    current_owner: OriginRef
) -> Bool {
    if origin_ref_same(owner, current_owner) { return true }
    state.scope_owners.any(fn(ancestor) {
        origin_ref_same(ancestor, owner)
    })
}

fn mint_formal(
    mut state: TypedEffectFreezeState, raw_tail: Int, owner: OriginRef
) {
    if raw_tail < 0 {
        panic("typed effect freeze: invalid generalized row tail")
    }
    let mut ordinal = 0
    for fact in state.facts {
        if origin_ref_same(
                effect_param_owner(typed_effect_formal_parameter(fact)),
                owner) {
            ordinal = ordinal + 1
        }
    }
    let parameter = make_effect_param_ref(owner, ordinal)
    for fact in state.facts {
        if effect_param_ref_same(
                typed_effect_formal_parameter(fact), parameter) {
            panic("typed effect freeze: two row tails share one formal")
        }
    }
    state.facts.push(make_typed_effect_formal_fact(raw_tail, parameter))
}

fn scan_formal(
    mut state: TypedEffectFreezeState, raw_tail: Int, owner: OriginRef,
    mode: EffectFormalScanMode
) {
    match mode {
        EffectFormalScanMode::HeaderFormal => match formal_fact_for_raw(
                state, raw_tail) {
            some(fact) => {
                let existing_owner = effect_param_owner(
                    typed_effect_formal_parameter(fact))
                if !owner_is_visible(state, existing_owner, owner) {
                    panic("typed effect freeze: unrelated headers share a row tail")
                }
            },
            none => mint_formal(state, raw_tail, owner)
        },
        EffectFormalScanMode::SchemaUseFormal => match formal_fact_for_raw(
                state, raw_tail) {
            some(fact) => {
                let existing_owner = effect_param_owner(
                    typed_effect_formal_parameter(fact))
                if state.header_tails.contains(raw_tail) &&
                   owner_is_visible(state, existing_owner, owner) {
                    return
                }
                panic("typed effect freeze: two schema uses share a row tail")
            },
            none => {
                if state.schema_use_tails.contains(raw_tail) {
                    panic("typed effect freeze: schema-use row tail repeats")
                }
                state.schema_use_tails.push(raw_tail)
                mint_formal(state, raw_tail, owner)
            }
        },
        EffectFormalScanMode::ValidateFormal => match formal_fact_for_raw(
                state, raw_tail) {
            some(fact) => {
                let existing_owner = effect_param_owner(
                    typed_effect_formal_parameter(fact))
                if !owner_is_visible(state, existing_owner, owner) {
                    panic("typed effect freeze: row-tail use escaped its binder")
                }
            },
            none => panic("typed effect freeze: row-tail use has no binder")
        }
    }
    match mode {
        EffectFormalScanMode::HeaderFormal => if
                !state.header_tails.contains(raw_tail) {
            state.header_tails.push(raw_tail)
        },
        _ => {}
    }
}

fn register_callable_effect(
    mut state: TypedEffectFreezeState, reference: ExecutableRef, row: EffectRow
) {
    for existing in state.callables {
        if executable_ref_same(existing.reference, reference) {
            if !types_equal(
                    Type::EffectRowType {
                        effects: existing.row.effects, tail: existing.row.tail
                    },
                    Type::EffectRowType {
                        effects: row.effects, tail: row.tail
                    }) {
                panic("typed effect freeze: callable effect contract changed")
            }
            return
        }
    }
    state.callables.push(TypedCallableEffectFact {
        reference: reference,
        row: EffectRow { effects: row.effects, tail: row.tail }
    })
}

fn scan_effect_mode(
    mut state: TypedEffectFreezeState, value: Effect, owner: OriginRef,
    mode: EffectFormalScanMode
) {
    match value {
        Effect::FailEffect { error_type } => scan_type_mode(
            state, error_type, owner, mode),
        Effect::MutEffect { state_type } => scan_type_mode(
            state, state_type, owner, mode),
        Effect::CustomEffect { type_args, .. } => {
            for argument in type_args {
                scan_type_mode(
                    state, argument, owner, mode)
            }
        },
        Effect::SystemEffect { .. } | Effect::UnsafeEffect => {}
    }
}

fn scan_row_mode(
    mut state: TypedEffectFreezeState, row: EffectRow, owner: OriginRef,
    mode: EffectFormalScanMode
) {
    for item in row.effects {
        scan_effect_mode(state, item, owner, mode)
    }
    match row.tail {
        some(raw_tail) => scan_formal(state, raw_tail, owner, mode),
        none => {}
    }
}

fn scan_header_row(
    mut state: TypedEffectFreezeState, row: EffectRow, owner: OriginRef
) { scan_row_mode(state, row, owner, EffectFormalScanMode::HeaderFormal) }

fn scan_schema_use_row(
    mut state: TypedEffectFreezeState, row: EffectRow, owner: OriginRef
) { scan_row_mode(state, row, owner, EffectFormalScanMode::SchemaUseFormal) }

fn validate_row(
    mut state: TypedEffectFreezeState, row: EffectRow, owner: OriginRef
) { scan_row_mode(state, row, owner, EffectFormalScanMode::ValidateFormal) }

fn nominal_was_visited(
    state: TypedEffectFreezeState, owner: SymbolRef
) -> Bool {
    state.visited_nominals.any(fn(existing) {
        symbol_ref_same(existing, owner)
    })
}

fn mark_nominal_visited(
    mut state: TypedEffectFreezeState, owner: SymbolRef
) -> Bool {
    if nominal_was_visited(state, owner) { return false }
    state.visited_nominals.push(owner)
    true
}

fn scan_struct_schema(mut state: TypedEffectFreezeState, name: Str) {
    match state.env.types.structs.get(name) {
        some(def) => {
            let nominal = registered_nominal_ref_symbol(def.owner_ref)
            if !mark_nominal_visited(state, nominal) { return }
            for field in def.fields {
                scan_header_type(state, field.ty,
                    make_symbol_origin_ref(
                        nominal_field_ref_member(field.field_ref)))
            }
        },
        none => {}
    }
}

fn scan_enum_schema(mut state: TypedEffectFreezeState, name: Str) {
    match state.env.types.enums.get(name) {
        some(def) => {
            let nominal = registered_nominal_ref_symbol(def.owner_ref)
            if !mark_nominal_visited(state, nominal) { return }
            if def.variants.len() != def.variant_field_refs.len() {
                panic("typed effect freeze: enum field identity census differs")
            }
            let mut variant_index = 0
            while variant_index < def.variants.len() {
                let variant = def.variants.get(variant_index).unwrap()
                let field_refs = def.variant_field_refs.get(
                    variant_index).unwrap()
                if variant.fields.len() != field_refs.len() {
                    panic("typed effect freeze: enum payload identity census differs")
                }
                let mut field_index = 0
                while field_index < variant.fields.len() {
                    scan_header_type(state,
                        variant.fields.get(field_index).unwrap(),
                        make_symbol_origin_ref(variant_field_ref_member(
                            field_refs.get(field_index).unwrap())))
                    field_index = field_index + 1
                }
                variant_index = variant_index + 1
            }
        },
        none => {}
    }
}

fn scan_type_mode(
    mut state: TypedEffectFreezeState, value: Type, owner: OriginRef,
    mode: EffectFormalScanMode
) {
    match value {
        Type::FnType { params, return_type, effects } => {
            for parameter in params {
                scan_type_mode(
                    state, parameter, owner, mode)
            }
            scan_type_mode(
                state, return_type, owner, mode)
            scan_row_mode(state, effects, owner, mode)
        },
        Type::StructType { name, type_params } => {
            for argument in type_params {
                scan_type_mode(
                    state, argument, owner, mode)
            }
            scan_struct_schema(state, name)
        },
        Type::EnumType { name, type_params } => {
            for argument in type_params {
                scan_type_mode(
                    state, argument, owner, mode)
            }
            scan_enum_schema(state, name)
        },
        Type::GenericType { base, args } => {
            scan_type_mode(state, base, owner, mode)
            for argument in args {
                scan_type_mode(
                    state, argument, owner, mode)
            }
        },
        Type::RecordType { fields, .. } => {
            for field in fields {
                scan_type_mode(state, field.ty, owner, mode)
            }
        },
        Type::EffectRowType { effects, tail } => scan_row_mode(
            state, EffectRow { effects: effects, tail: tail }, owner,
            mode),
        Type::TupleType { elements } => {
            for element in elements {
                scan_type_mode(
                    state, element, owner, mode)
            }
        },
        Type::PtrType { pointee } => scan_type_mode(
            state, pointee, owner, mode),
        _ => {}
    }
}

fn scan_header_type(
    mut state: TypedEffectFreezeState, value: Type, owner: OriginRef
) { scan_type_mode(state, value, owner, EffectFormalScanMode::HeaderFormal) }

fn scan_schema_use_type(
    mut state: TypedEffectFreezeState, value: Type, owner: OriginRef
) { scan_type_mode(state, value, owner, EffectFormalScanMode::SchemaUseFormal) }

fn validate_type(
    mut state: TypedEffectFreezeState, value: Type, owner: OriginRef
) { scan_type_mode(state, value, owner, EffectFormalScanMode::ValidateFormal) }

fn scan_param(
    mut state: TypedEffectFreezeState, value: HParam, owner: OriginRef
) { scan_header_type(state, value.ty, owner) }

fn scan_match_arm(
    mut state: TypedEffectFreezeState, value: HMatchArm, owner: OriginRef
) {
    for binding in value.bindings {
        scan_schema_use_type(state, binding.ty, owner)
    }
    match value.guard {
        some(guard) => scan_expr(state, guard, owner), none => {}
    }
    scan_expr(state, value.body, owner)
}

fn scan_handler(
    mut state: TypedEffectFreezeState, value: HEffectHandler
) {
    let owner = executable_origin(value.executable_ref)
    register_callable_effect(
        state, value.executable_ref, hexpr_effects(value.body))
    for parameter in value.params { scan_param(state, parameter, owner) }
    scan_header_type(state, hexpr_type(value.body), owner)
    scan_header_row(state, hexpr_effects(value.body), owner)
    enter_formal_scope(state, owner)
    match value.resume_binding {
        some(binding) => scan_schema_use_type(
            state, binding.ty, owner),
        none => {}
    }
    for capture in value.captures {
        match capture.value {
            some(expr) => scan_expr(state, expr, owner), none => {}
        }
    }
    scan_expr(state, value.body, owner)
    exit_formal_scope(state, owner)
}

fn scan_stmt(
    mut state: TypedEffectFreezeState, value: HStmt, owner: OriginRef
) {
    match value {
        HStmt::Let { ty, init, .. } | HStmt::Var { ty, init, .. } => {
            scan_expr(state, init, owner); validate_type(state, ty, owner)
        },
        HStmt::Assign { target, value, .. } => {
            scan_expr(state, target, owner); scan_expr(state, value, owner)
        },
        HStmt::ExprStmt { expr, .. } => scan_expr(state, expr, owner),
        HStmt::Return { value, .. } => match value {
            some(expr) => scan_expr(state, expr, owner), none => {}
        },
        HStmt::While { condition, body, .. } => {
            scan_expr(state, condition, owner); scan_expr(state, body, owner)
        },
        HStmt::ForIn { iterable, body, .. } => {
            scan_expr(state, iterable, owner); scan_expr(state, body, owner)
        },
        HStmt::LetDestructure { bindings, init, .. } => {
            scan_expr(state, init, owner)
            for binding in bindings {
                scan_schema_use_type(state, binding.ty, owner)
            }
        },
        HStmt::IfLet { bindings, expr, then_block, else_block, .. } => {
            scan_expr(state, expr, owner)
            for binding in bindings {
                scan_schema_use_type(state, binding.ty, owner)
            }
            scan_expr(state, then_block, owner)
            match else_block {
                some(branch) => scan_expr(state, branch, owner), none => {}
            }
        },
        HStmt::Drop { ty, place_target, .. } => {
            match place_target {
                some(expr) => scan_expr(state, expr, owner), none => {}
            }
            validate_type(state, ty, owner)
        },
        HStmt::Break { .. } | HStmt::Continue { .. } => {}
    }
}

fn scan_expr(
    mut state: TypedEffectFreezeState, value: HExpr, owner: OriginRef
) {
    let mut type_bound = false
    match value {
        HExpr::Lambda { executable_ref, .. } => {
            scan_header_type(
                state, hexpr_type(value), executable_origin(executable_ref))
            type_bound = true
        },
        HExpr::Ident {
            source_slot: none, callee_identity: some(_), ..
        } | HExpr::FieldAccess { .. } | HExpr::EffectOp { .. } => {
            scan_schema_use_type(state, hexpr_type(value), owner)
            type_bound = true
        },
        _ => {}
    }
    match value {
        HExpr::IntLit { .. } | HExpr::FloatLit { .. } |
        HExpr::StrLit { .. } | HExpr::BoolLit { .. } |
        HExpr::Ident { .. } | HExpr::DictConstruct { .. } => {},
        HExpr::UnaryOp { operand, .. } |
        HExpr::Clone { inner: operand, .. } => scan_expr(state, operand, owner),
        HExpr::BinOp { left, right, .. } => {
            scan_expr(state, left, owner); scan_expr(state, right, owner)
        },
        HExpr::Call { callee, args, type_args, method_ref, .. } => {
            scan_expr(state, callee, owner)
            for argument in args { scan_expr(state, argument, owner) }
            for argument in type_args {
                validate_type(state, argument, owner)
            }
            match method_ref {
                some(method) => validate_type(
                    state, method_call_ref_signature(method), owner),
                none => {}
            }
        },
        HExpr::FieldAccess { receiver, .. } => scan_expr(state, receiver, owner),
        HExpr::StructLit { type_args, fields, spread, .. } => {
            for argument in type_args {
                validate_type(state, argument, owner)
            }
            for field in fields { scan_expr(state, field.value, owner) }
            match spread {
                some(base) => scan_expr(state, base, owner), none => {}
            }
        },
        HExpr::NamedVariantConstruct { fields, spread, .. } => {
            for field in fields { scan_expr(state, field.value, owner) }
            match spread {
                some(base) => scan_expr(state, base, owner), none => {}
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            scan_expr(state, scrutinee, owner)
            for arm in arms { scan_match_arm(state, arm, owner) }
        },
        HExpr::Block { stmts, tail, .. } => {
            for stmt in stmts { scan_stmt(state, stmt, owner) }
            match tail { some(expr) => scan_expr(state, expr, owner), none => {} }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            scan_expr(state, condition, owner)
            scan_expr(state, then_branch, owner)
            match else_branch {
                some(branch) => scan_expr(state, branch, owner), none => {}
            }
        },
        HExpr::StringInterp { parts, .. } => {
            for part in parts {
                match part {
                    HStringInterpPart::Expression(expr) =>
                        scan_expr(state, expr, owner),
                    _ => {}
                }
            }
        },
        HExpr::TryCatch { body, arms, .. } => {
            scan_expr(state, body, owner)
            for arm in arms { scan_match_arm(state, arm, owner) }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            scan_expr(state, body, owner)
            for handler in handlers { scan_handler(state, handler) }
        },
        HExpr::Lambda {
            executable_ref, params, captures, return_type, body, ..
        } => {
            let lambda_owner = executable_origin(executable_ref)
            register_callable_effect(
                state, executable_ref, hexpr_effects(body))
            for parameter in params { scan_param(state, parameter, lambda_owner) }
            scan_header_type(state, return_type, lambda_owner)
            scan_header_row(state, hexpr_effects(body), lambda_owner)
            enter_formal_scope(state, lambda_owner)
            for capture in captures {
                match capture.value {
                    some(expr) => scan_expr(state, expr, lambda_owner), none => {}
                }
            }
            scan_expr(state, body, lambda_owner)
            exit_formal_scope(state, lambda_owner)
        },
        HExpr::EffectOp { args, .. } => {
            for argument in args { scan_expr(state, argument, owner) }
        },
        HExpr::ListLit { elements, .. } |
        HExpr::TupleLit { elements, .. } => {
            for element in elements { scan_expr(state, element, owner) }
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            scan_expr(state, receiver, owner); scan_expr(state, index, owner)
        },
        HExpr::Take { source, .. } => scan_expr(state, source, owner),
        HExpr::ReturnExpr { value, .. } => match value {
            some(expr) => scan_expr(state, expr, owner), none => {}
        },
        HExpr::UnsafeBlock { body, .. } => scan_expr(state, body, owner)
    }
    if !type_bound { validate_type(state, hexpr_type(value), owner) }
    validate_row(state, hexpr_effects(value), owner)
}

fn scan_callable(
    mut state: TypedEffectFreezeState, executable: ExecutableRef,
    params: List<HParam>, result: Type, effects: EffectRow, body: HExpr?
) {
    let owner = executable_origin(executable)
    register_callable_effect(state, executable, effects)
    for parameter in params { scan_param(state, parameter, owner) }
    scan_header_type(state, result, owner)
    scan_header_row(state, effects, owner)
    enter_formal_scope(state, owner)
    match body { some(expr) => scan_expr(state, expr, owner), none => {} }
    exit_formal_scope(state, owner)
}

fn scan_decls(mut state: TypedEffectFreezeState, values: List<HDecl>) {
    for value in values {
        match value {
            HDecl::Fn { executable_ref, params, return_type, effects,
                        body, .. } => scan_callable(
                state, executable_ref, params, return_type, effects, some(body)),
            HDecl::Struct { owner_ref, fields, .. } => {
                let nominal = registered_nominal_ref_symbol(owner_ref)
                let _ = mark_nominal_visited(state, nominal)
                for field in fields {
                    scan_header_type(state, field.ty, make_symbol_origin_ref(
                        nominal_field_ref_member(field.field_ref)))
                }
            },
            HDecl::Enum { owner_ref, variants, .. } => {
                let nominal = registered_nominal_ref_symbol(owner_ref)
                let _ = mark_nominal_visited(state, nominal)
                for variant in variants {
                    if variant.fields.len() != variant.field_refs.len() {
                        panic("typed effect freeze: enum payload identity differs")
                    }
                    let mut index = 0
                    while index < variant.fields.len() {
                        scan_header_type(
                            state, variant.fields.get(index).unwrap(),
                            make_symbol_origin_ref(variant_field_ref_member(
                                variant.field_refs.get(index).unwrap())))
                        index = index + 1
                    }
                }
            },
            HDecl::Impl {
                target_ty, owner_ref, methods, assoc_types,
                default_specializations, delegate_plan, ..
            } => {
                let owner = make_path_origin_ref(impl_provider_ref_site(
                    impl_owner_ref_provider(owner_ref)))
                scan_header_type(state, target_ty, owner)
                for assoc in assoc_types {
                    match assoc.concrete {
                        some(ty) => scan_header_type(state, ty,
                            make_symbol_origin_ref(assoc.member_ref)),
                        none => {}
                    }
                }
                scan_decls(state, methods)
                for plan in default_specializations {
                    let generated = h_default_specialization_generated_executable(plan)
                    let generated_owner = executable_origin(generated)
                    for ty in h_default_specialization_parameter_types(plan) {
                        scan_header_type(state, ty, generated_owner)
                    }
                    scan_header_type(state,
                        h_default_specialization_result_type(plan), generated_owner)
                    scan_header_row(state,
                        h_default_specialization_effects(plan), generated_owner)
                    register_callable_effect(state, generated,
                        h_default_specialization_effects(plan))
                    scan_schema_use_type(state, h_exact_call_signature(
                        h_default_specialization_forward_call(plan)),
                        generated_owner)
                }
                match delegate_plan {
                    some(plan) => {
                        for method in h_delegate_methods(plan) {
                            let generated_owner = executable_origin(
                                h_delegate_method_executable(method))
                            for ty in h_delegate_method_parameter_types(method) {
                                scan_header_type(state, ty, generated_owner)
                            }
                            scan_header_type(state,
                                h_delegate_method_result_type(method),
                                generated_owner)
                            scan_header_row(state,
                                h_delegate_method_effects(method),
                                generated_owner)
                            register_callable_effect(
                                state, h_delegate_method_executable(method),
                                h_delegate_method_effects(method))
                            scan_schema_use_type(
                                state, method_call_ref_signature(
                                h_delegate_method_child_call(method)),
                                generated_owner)
                        }
                        for assoc in h_delegate_assoc_bindings(plan) {
                            scan_header_type(
                                state, h_delegate_assoc_type(assoc),
                                make_symbol_origin_ref(
                                    h_delegate_assoc_member(assoc)))
                        }
                    },
                    none => {}
                }
            },
            HDecl::Effect { name, type_params, ops, .. } => {
                let type_args = type_params.map(fn(parameter) {
                    Type::TypeVar {
                        id: parameter.type_var_id,
                        name: some(parameter.source.name)
                    }
                })
                for op in ops {
                    match op.operation_ref {
                        some(reference) => scan_callable(
                            state, effect_operation_ref_callable(reference),
                            op.params, op.return_type, EffectRow {
                                effects: [Effect::CustomEffect {
                                    reference: effect_operation_ref_effect(reference),
                                    name: name, type_args: type_args
                                }], tail: none
                            }, none),
                        none => panic(
                            "typed effect freeze: effect operation lacks identity")
                    }
                }
            },
            HDecl::Test { executable_ref, body, .. } => scan_callable(
                state, executable_ref, [], hexpr_type(body),
                hexpr_effects(body), some(body)),
            HDecl::Trait { methods, assoc_types, .. } => {
                for method in methods {
                    scan_callable(state, method.executable_ref, method.params,
                        method.return_type, method.effects, method.body)
                }
                for assoc in assoc_types {
                    match assoc.concrete {
                        some(ty) => scan_header_type(state, ty,
                            make_symbol_origin_ref(assoc.member_ref)),
                        none => {}
                    }
                }
            },
            HDecl::ExternFn { executable_ref, params, return_type, effects,
                              .. } => scan_callable(
                state, executable_ref, params, return_type, effects, none),
            HDecl::Const { executable_ref, ty, init, .. } => scan_callable(
                state, executable_ref, [], ty, hexpr_effects(init), some(init)),
            HDecl::ModBlock { decls, .. } => scan_decls(state, decls),
            // Alias bodies have no Core identity.  Type checking has already
            // expanded each use with fresh variables, so those authored outer
            // positions are scanned instead of assigning the alias an owner.
            HDecl::TypeAlias { .. } | HDecl::ExternType { .. } => {}
        }
    }
}

fn scan_derived(
    mut state: TypedEffectFreezeState, values: List<DerivedImpl>
) {
    for derived in values {
        let owner = make_path_origin_ref(impl_provider_ref_site(
            impl_owner_ref_provider(derived.owner_ref)))
        scan_header_type(state, derived.target_type, owner)
        match derived.struct_fields {
            some(fields) => {
                for field in fields {
                    let field_owner = match field.field_ref {
                        DerivedFieldRef::NominalDerivedField(reference) =>
                            make_symbol_origin_ref(
                                nominal_field_ref_member(reference)),
                        DerivedFieldRef::VariantDerivedField(reference) =>
                            make_symbol_origin_ref(
                                variant_field_ref_member(reference))
                    }
                    scan_header_type(state, field.ty, field_owner)
                }
            },
            none => {}
        }
        match derived.enum_variants {
            some(variants) => {
                for variant in variants {
                    for field in variant.fields {
                        let field_owner = match field.field_ref {
                            DerivedFieldRef::NominalDerivedField(reference) =>
                                make_symbol_origin_ref(
                                    nominal_field_ref_member(reference)),
                            DerivedFieldRef::VariantDerivedField(reference) =>
                                make_symbol_origin_ref(
                                    variant_field_ref_member(reference))
                        }
                        scan_header_type(state, field.ty, field_owner)
                    }
                }
            },
            none => {}
        }
        for method in derived.methods {
            let effects = match method.signature {
                Type::FnType { effects, .. } => effects,
                _ => panic(
                    "typed effect freeze: derived signature is not callable")
            }
            scan_header_type(state, method.signature,
                executable_origin(method.executable_ref))
            register_callable_effect(state, method.executable_ref, effects)
        }
    }
}

pub fn freeze_typed_effect_formals(
    program: HProgram, env: TypeEnv, module_order: Int
) -> TypedEffectFreezeResult {
    if module_order < 0 {
        panic("typed effect freeze: invalid module order")
    }
    let state = TypedEffectFreezeState {
        env: env, facts: [], callables: [], visited_nominals: [],
        header_tails: [], schema_use_tails: [], scope_owners: []
    }
    scan_decls(state, program.decls)
    scan_derived(state, program.derived_impls)
    if module_order == 0 {
        for fact in builtin_method_contract_facts(env) {
            let executable = make_named_executable_ref(intrinsic_ref_symbol(
                builtin_method_contract_intrinsic(fact)))
            let reference = executable_origin(executable)
            let scheme = builtin_method_contract_scheme(fact).ty
            scan_header_type(state, scheme, reference)
            match scheme {
                Type::FnType { effects, .. } => register_callable_effect(
                    state, executable, effects),
                _ => panic(
                    "typed effect freeze: builtin contract is not callable")
            }
        }
    }
    TypedEffectFreezeResult {
        formals: state.facts.map(fn(fact) { fact }),
        callables: state.callables.map(fn(fact) { fact })
    }
}
