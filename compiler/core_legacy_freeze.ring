// Sole semantic freeze boundary for Core assembly and temporary legacy
// projection facts.  The HProgram is closed exactly once, then one internal
// traversal emits both immutable products.  Neither product exposes HProgram
// and no downstream consumer may replay resolver/type/effect selection.

use types::{Type, EffectRow, types_equal, effects_equal}
use env::{TypeEnv}
use hir::{
    HProgram, HDecl, HExpr, HStmt, HParam, HMatchArm, HEffectHandler,
    HTypeParam, TraitBound, HDefaultSpecializationPlan, HDelegateTypedPlan,
    DictRef, MethodCallRef, HOperatorPlan, FieldAction,
    method_call_ref_is_bound, method_call_ref_bound_evidence,
    h_operator_is_tuple, h_operator_elements, h_operator_method_ref,
    h_type_param_name,
    DerivedImpl, DerivedMethod, DerivedField, TypeKind,
    h_default_specialization_generated_method,
    h_default_specialization_generated_executable,
    h_default_specialization_parameter_types,
    h_default_specialization_parameter_mutabilities,
    h_default_specialization_binders,
    h_default_specialization_result_type,
    h_default_specialization_effects,
    h_default_specialization_forward_call, h_exact_call_evidence,
    h_exact_call_signature,
    h_delegate_methods, h_delegate_method_evidence,
    h_delegate_dict_evidence,
    derived_semantic_kind_tag,
    module_item_identity, hexpr_type, hexpr_effects
}
use hir_exact::{
    dict_ref_exact, dict_ref_physical_same,
    dict_ref_is_wrapped_physical, dict_ref_wrapped_physical_inner
}
use ir_identity::{
    CoreTypeFactRef, core_type_fact_same, core_type_fact_module_key,
    SymbolRef, ModuleBodyRef, SlotRef, OriginRef, ImplOwnerRef, ImplMethodRef,
    make_module_body_ref, make_source_slot_ref, slot_domain_lexical,
    make_synthetic_slot_ref, make_path_ref, path_role_parameter,
    path_owner_for_symbol, path_ref_owner, make_path_origin_ref,
    make_symbol_origin_ref, symbol_ref_same,
    path_ref_same,
    symbol_ref_origin_module_key, symbol_ref_canonical_payload,
    impl_method_ref_owner, impl_method_ref_member, impl_method_ref_name,
    impl_method_ref_callable_slot_index,
    impl_owner_ref_target, impl_owner_ref_trait,
    intrinsic_ref_symbol, slot_ref_same, slot_ref_is_source,
    slot_ref_stable_key,
    slot_ref_source_def_id
}
use ir_inventory::{
    ExecutableRef, ExecutableKind, EffectOperationRef, dict_ref_same,
    make_named_executable_ref,
    executable_ref_is_named, executable_ref_named_symbol,
    executable_ref_anonymous_path, executable_ref_same,
    executable_ref_origin_module_key,
    executable_kind_fn, executable_kind_impl_method,
    executable_kind_test, executable_kind_const_getter,
    executable_kind_extern_fn, executable_kind_trait_default,
    executable_kind_bodyless_trait_member,
    executable_kind_bodyless_effect_operation,
    executable_kind_lambda, executable_kind_handler,
    executable_kind_builtin_intrinsic,
    executable_kind_default_specialization,
    executable_kind_derived_impl,
    BinderEntry, make_source_binder_entry,
    binder_entry_slot, binder_entry_owner, binder_entry_kind,
    binder_entry_site, binder_kind_tag, binder_kind_match_pattern,
    effect_operation_ref_callable
}
use builtins::{
    builtin_method_contract_facts,
    builtin_method_contract_intrinsic, builtin_method_contract_scheme
}
use precore_lower::{close_hir_surface}
use typed_effect_freeze::{
    freeze_typed_effect_formals, typed_effect_freeze_formals,
    typed_effect_freeze_callables
}
use core_type_source::{
    CoreTypeSourceFact, CoreEffectCtxTypeSource,
    core_type_source_type, core_type_source_fact,
    core_effect_ctx_source_aggregate_fact
}
use effect_contract::{make_core_effect_set}
use core_from_hir::{
    FrozenCoreAssemblyFacts,
    produce_closed_core_assembly_facts,
    frozen_core_assembly_program,
    frozen_core_assembly_type_sources,
    frozen_core_assembly_effect_ctx_type,
    make_core_effect_set_fact_from_row
}
use legacy_projection::{
    LegacyProjectionFacts, LegacyEffectFactProjection,
    LegacyBinderFactProjection, LegacyCallableFactProjection,
    LegacyBuiltinCallableFactProjection, LegacyImplFactProjection,
    LegacyPreludeCallableFactProjection,
    LegacyAssocBindingFactProjection,
    LegacyExecutableShell, LegacyContainerRef,
    LegacyExecutablePhysicalIdentity,
    LegacyTypeParameterProjection, LegacyTraitBoundProjection,
    LegacyDictionaryProjection,
    make_legacy_effect_fact_projection,
    make_legacy_source_binder_slot,
    make_legacy_binder_fact_projection,
    make_legacy_callable_fact_projection,
    make_legacy_builtin_callable_fact_projection,
    make_legacy_prelude_callable_fact_projection,
    make_legacy_assoc_binding_fact_projection,
    make_legacy_projection_facts,
    make_legacy_executable_shell,
    make_legacy_prelude_executable_shell,
    make_legacy_executable_shell_map,
    make_legacy_executable_physical_identity,
    make_legacy_module_container, make_legacy_executable_container,
    make_legacy_type_parameter_projection,
    make_legacy_dictionary_projection,
    legacy_dictionary_projection_exact,
    legacy_dictionary_projection_physical,
    legacy_physical_semantic_module,
    make_legacy_trait_bound_projection,
    make_legacy_impl_fact_projection,
    make_legacy_physical_impl_fact_projection,
    make_legacy_internal_type_fact_projection,
    legacy_internal_effect_ctx_opaque,
    legacy_effect_fact_projection_row,
    legacy_binder_fact_slot, legacy_binder_fact_name,
    legacy_binder_fact_type, legacy_type_parameter_name,
    legacy_type_parameter_var_id
}

pub struct FrozenCoreAndLegacyFacts {
    core: FrozenCoreAssemblyFacts,
    legacy: LegacyProjectionFacts
}

pub fn frozen_core_and_legacy_core(
    value: FrozenCoreAndLegacyFacts
) -> FrozenCoreAssemblyFacts { value.core }

pub fn frozen_core_and_legacy_legacy(
    value: FrozenCoreAndLegacyFacts
) -> LegacyProjectionFacts { value.legacy }

fn exact_type_fact(
    values: List<CoreTypeSourceFact>, ty: Type, module_key: Str
) -> CoreTypeFactRef {
    let mut found: CoreTypeFactRef? = none
    for value in values {
        if types_equal(core_type_source_type(value), ty) {
            let reference = core_type_source_fact(value)
            if found.is_some() &&
               !core_type_fact_same(found.unwrap(), reference) {
                panic("Core/legacy freeze: one Type maps to two facts")
            }
            found = some(reference)
        }
    }
    match found {
        some(value) => {
            if core_type_fact_module_key(value) != module_key {
                panic("Core/legacy freeze: Type fact crosses module")
            }
            value
        },
        none => panic("Core/legacy freeze: exact Type fact is absent")
    }
}

struct LegacyFactBuilder {
    module_key: Str,
    physical_module_prefix: Str,
    owns_prelude: Bool,
    module_body: ModuleBodyRef,
    type_sources: List<CoreTypeSourceFact>,
    effects: List<LegacyEffectFactProjection>,
    binders: List<LegacyBinderFactProjection>,
    callables: List<LegacyCallableFactProjection>,
    prelude_callables: List<LegacyPreludeCallableFactProjection>,
    builtin_callables: List<LegacyBuiltinCallableFactProjection>,
    impls: List<LegacyImplFactProjection>,
    dictionaries: List<LegacyDictionaryProjection>,
    physical_identities: List<LegacyExecutablePhysicalIdentity>,
    shells: List<LegacyExecutableShell>
}

fn impl_uses_physical_owner(
    builder: LegacyFactBuilder, owner: ImplOwnerRef
) -> Bool {
    if !builder.owns_prelude { return false }
    let module_key = symbol_ref_origin_module_key(
        impl_owner_ref_target(owner))
    legacy_physical_semantic_module(module_key)
}

fn executable_uses_physical_owner(
    builder: LegacyFactBuilder, reference: ExecutableRef
) -> Bool {
    if !builder.owns_prelude { return false }
    let module_key = executable_ref_origin_module_key(reference)
    legacy_physical_semantic_module(module_key)
}

fn executable_origin(value: ExecutableRef) -> OriginRef {
    if executable_ref_is_named(value) {
        make_symbol_origin_ref(executable_ref_named_symbol(value))
    } else {
        make_path_origin_ref(executable_ref_anonymous_path(value))
    }
}

fn add_physical_identity(
    mut builder: LegacyFactBuilder, reference: ExecutableRef,
    method: ImplMethodRef?, source_name: Str?
) {
    let identity = match method {
        some(exact) => {
            if !executable_ref_is_named(reference) ||
               !symbol_ref_same(
                    executable_ref_named_symbol(reference),
                    impl_method_ref_member(exact)) {
                panic("Core/legacy freeze: impl method executable differs")
            }
            "${symbol_ref_canonical_payload(impl_owner_ref_target(
                impl_method_ref_owner(exact)))}_${impl_method_ref_name(exact)}"
        },
        none => if executable_ref_is_named(reference) {
        if executable_uses_physical_owner(builder, reference) &&
           source_name.is_some() {
            let name = source_name.unwrap()
            if builder.physical_module_prefix == "" { name }
            else { module_item_identity(
                builder.physical_module_prefix, name) }
        } else {
            symbol_ref_canonical_payload(
                executable_ref_named_symbol(reference))
        }
    } else {
        // Anonymous child paths are only unique together with their exact
        // PathOwnerRef.  Reusing the existing stable synthetic-slot key keeps
        // lambdas/handlers below different callables disjoint without adding
        // a second executable naming authority.
        slot_ref_stable_key(make_synthetic_slot_ref(
            executable_ref_anonymous_path(reference)))
        }
    }
    builder.physical_identities.push(
        make_legacy_executable_physical_identity(reference, identity))
}

fn add_effect_row(mut builder: LegacyFactBuilder, row: EffectRow) {
    for existing in builder.effects {
        let existing_row = legacy_effect_fact_projection_row(existing)
        let tails_same = match (existing_row.tail, row.tail) {
            (some(a), some(b)) => a == b,
            (none, none) => true,
            _ => false
        }
        if tails_same && existing_row.effects.len() == row.effects.len() &&
           existing_row.effects.all(fn(left) {
               row.effects.any(fn(right) { effects_equal(left, right) })
           }) {
            return
        }
    }
    builder.effects.push(make_legacy_effect_fact_projection(
        make_core_effect_set_fact_from_row(
            builder.type_sources, row, builder.module_key), row))
}

fn add_binder_fact(
    mut builder: LegacyFactBuilder, slot: SlotRef, name: Str,
    def_id: Int, ty: Type, is_mutable: Bool
) -> LegacyBinderFactProjection {
    for existing in builder.binders {
        if slot_ref_same(legacy_binder_fact_slot(existing), slot) {
            if legacy_binder_fact_name(existing) != name ||
               !types_equal(
                    legacy_binder_fact_type(existing), ty) {
                panic("Core/legacy freeze: binder projection differs")
            }
            return existing
        }
    }
    let result = make_legacy_binder_fact_projection(
        slot, name, def_id,
        exact_type_fact(builder.type_sources, ty, builder.module_key),
        ty, is_mutable)
    builder.binders.push(result)
    result
}

fn source_parameter_fact(
    mut builder: LegacyFactBuilder, owner: ExecutableRef, value: HParam
) -> LegacyBinderFactProjection {
    let def_id = match value.def_id {
        some(id) => id,
        none => panic("Core/legacy freeze: callable parameter lacks DefId")
    }
    if def_id < 0 {
        panic("Core/legacy freeze: callable parameter is synthetic")
    }
    add_binder_fact(
        builder,
        make_legacy_source_binder_slot(owner, def_id),
        value.name, def_id, value.ty, value.is_mutable)
}

fn callable_type_parameters(
    values: List<HTypeParam>, bounds: List<TraitBound>
) -> List<LegacyTypeParameterProjection> {
    let mut result: List<LegacyTypeParameterProjection> = []
    for value in values {
        result.push(make_legacy_type_parameter_projection(
            h_type_param_name(value),
            value.type_var_id, value.bound_refs))
    }
    let _ = bounds
    result
}

fn merge_callable_type_parameters(
    outer: List<HTypeParam>, inner: List<HTypeParam>
) -> List<HTypeParam> {
    let mut result: List<HTypeParam> = []
    for value in outer { result.push(value) }
    for value in inner {
        for existing in result {
            if existing.type_var_id == value.type_var_id {
                panic("Core/legacy freeze: callable type parameter repeats")
            }
        }
        result.push(value)
    }
    result
}

fn trait_bounds_from_type_parameters(
    values: List<HTypeParam>
) -> List<TraitBound> {
    let mut result: List<TraitBound> = []
    let mut ordinal = 0
    for value in values {
        for trait_ref in value.bound_refs {
            result.push(TraitBound {
                type_param: h_type_param_name(value),
                type_var_id: value.type_var_id,
                trait_name: symbol_ref_canonical_payload(trait_ref),
                trait_ref: trait_ref, dict_ordinal: ordinal
            })
            ordinal = ordinal + 1
        }
    }
    result
}

fn callable_trait_bounds(
    parameters: List<LegacyTypeParameterProjection>,
    bounds: List<TraitBound>
) -> List<LegacyTraitBoundProjection> {
    let mut result: List<LegacyTraitBoundProjection> = []
    for bound in bounds {
        let mut found: Int? = none
        let mut index = 0
        for parameter in parameters {
            if legacy_type_parameter_var_id(parameter) ==
                    bound.type_var_id {
                if found.is_some() {
                    panic("Core/legacy freeze: bound TypeVar repeats")
                }
                found = some(index)
            }
            index = index + 1
        }
        result.push(make_legacy_trait_bound_projection(
            match found {
                some(value) => value,
                none => panic("Core/legacy freeze: bound parameter is absent")
            }, bound.trait_ref))
    }
    result
}

fn add_callable_fact(
    mut builder: LegacyFactBuilder, reference: ExecutableRef,
    kind: ExecutableKind, container: LegacyContainerRef,
    type_params: List<HTypeParam>, trait_bounds: List<TraitBound>,
    params: List<HParam>, result_type: Type, effects: EffectRow,
    has_lexical_body: Bool, is_public: Bool,
    physical_method: ImplMethodRef?, physical_name: Str?
) {
    let type_parameters = callable_type_parameters(type_params, trait_bounds)
    let bounds = callable_trait_bounds(type_parameters, trait_bounds)
    let parameter_facts = if has_lexical_body {
        params.map(fn(param) {
            source_parameter_fact(builder, reference, param)
        })
    } else { [] }
    let origin = executable_origin(reference)
    if executable_uses_physical_owner(builder, reference) {
        if !builder.owns_prelude {
            panic("Core/legacy freeze: prelude callable escaped owner module")
        }
        builder.prelude_callables.push(
            make_legacy_prelude_callable_fact_projection(
                reference, origin, builder.module_body, container, kind,
                type_parameters, bounds, parameter_facts,
                exact_type_fact(
                    builder.type_sources, result_type, builder.module_key),
                result_type, effects, is_public))
        builder.shells.push(make_legacy_prelude_executable_shell(
            reference, origin, kind, builder.module_body, container))
    } else {
        builder.callables.push(make_legacy_callable_fact_projection(
            reference, origin, builder.module_body, container, kind,
            type_parameters, bounds, parameter_facts,
            exact_type_fact(
                builder.type_sources, result_type, builder.module_key),
            result_type, effects, is_public))
        builder.shells.push(make_legacy_executable_shell(
            reference, origin, kind, builder.module_body, container))
    }
    add_effect_row(builder, effects)
    add_physical_identity(
        builder, reference, physical_method, physical_name)
}

fn scan_stmt(
    mut builder: LegacyFactBuilder, owner: ExecutableRef, value: HStmt,
    type_params: List<HTypeParam>, trait_bounds: List<TraitBound>
) {
    match value {
        HStmt::Let { name, def_id: some(id), ty, init, .. } => {
            add_binder_fact(
                builder, make_legacy_source_binder_slot(owner, id),
                name, id, ty, false)
            scan_expr(builder, owner, init, type_params, trait_bounds)
        },
        HStmt::Var { name, def_id: some(id), ty, init, .. } => {
            if id < 0 {
                panic("Core/legacy freeze: mutable binder is synthetic")
            }
            add_binder_fact(
                builder, make_legacy_source_binder_slot(owner, id),
                name, id, ty, true)
            scan_expr(builder, owner, init, type_params, trait_bounds)
        },
        HStmt::Assign { target, value, .. } => {
            scan_expr(builder, owner, target, type_params, trait_bounds)
            scan_expr(builder, owner, value, type_params, trait_bounds)
        },
        HStmt::ExprStmt { expr, .. } =>
            scan_expr(builder, owner, expr, type_params, trait_bounds),
        HStmt::Return { value, .. } => match value {
            some(expr) => scan_expr(
                builder, owner, expr, type_params, trait_bounds), none => {}
        },
        HStmt::While { condition, body, .. } => {
            scan_expr(builder, owner, condition, type_params, trait_bounds)
            scan_expr(builder, owner, body, type_params, trait_bounds)
        },
        HStmt::LetDestructure { bindings, init, .. } => {
            for binding in bindings {
                if binding.name != "_" {
                    let slot = binding.slot.unwrap_or_else(fn() {
                        panic("Core/legacy freeze: destructure slot is absent")
                    })
                    let def_id = binding.def_id.unwrap_or_else(fn() {
                        panic("Core/legacy freeze: destructure DefId is absent")
                    })
                    add_binder_fact(
                        builder, slot, binding.name, def_id,
                        binding.ty, false)
                }
            }
            scan_expr(builder, owner, init, type_params, trait_bounds)
        },
        HStmt::Break { .. } | HStmt::Continue { .. } => {},
        _ => panic("Core/legacy freeze: surface/resource stmt crossed PreCore")
    }
}

fn add_match_binders(mut builder: LegacyFactBuilder, arm: HMatchArm) {
    for binding in arm.bindings {
        add_binder_fact(builder, binding.slot, binding.name,
            binding.def_id, binding.ty, false)
    }
}

fn add_dictionary_fact(mut builder: LegacyFactBuilder, value: DictRef) {
    for existing in builder.dictionaries {
        if dict_ref_same(
                legacy_dictionary_projection_exact(existing),
                dict_ref_exact(value)) {
            if !dict_ref_physical_same(
                    legacy_dictionary_projection_physical(existing), value) {
                panic("Core/legacy freeze: dictionary physical projection drifted")
            }
            return
        }
    }
    if dict_ref_is_wrapped_physical(value) {
        for inner in dict_ref_wrapped_physical_inner(value) {
            add_dictionary_fact(builder, inner)
        }
    }
    builder.dictionaries.push(make_legacy_dictionary_projection(value))
}

fn add_method_dictionary(
    mut builder: LegacyFactBuilder, value: MethodCallRef
) {
    if method_call_ref_is_bound(value) {
        add_dictionary_fact(builder, method_call_ref_bound_evidence(value))
    }
}

fn add_operator_dictionaries(
    mut builder: LegacyFactBuilder, value: HOperatorPlan
) {
    if h_operator_is_tuple(value) {
        for child in h_operator_elements(value) {
            add_operator_dictionaries(builder, child)
        }
    } else {
        add_method_dictionary(builder, h_operator_method_ref(value))
    }
}

fn add_derived_field_action_facts(
    mut builder: LegacyFactBuilder, value: FieldAction,
    ord_owner: ExecutableRef?, ord_binders: List<BinderEntry>,
    mut ord_cursor: List<Int>, mut ord_seen: List<BinderEntry>
) {
    match value {
        FieldAction::Call { base_dict, extra_dicts, .. } => {
            add_dictionary_fact(builder, base_dict)
            for item in extra_dicts { add_dictionary_fact(builder, item) }
            match ord_owner {
                some(owner) => {
                    let index = match ord_cursor.get(0) {
                        some(value) => value,
                        none => panic("Core/legacy freeze: Ord binder cursor is absent")
                    }
                    let entry = match ord_binders.get(index) {
                        some(value) => value,
                        none => panic("Core/legacy freeze: Ord Call leaf lacks binder")
                    }
                    if !executable_ref_same(
                            binder_entry_owner(entry), owner) ||
                       binder_kind_tag(binder_entry_kind(entry)) !=
                            binder_kind_tag(binder_kind_match_pattern()) {
                        panic("Core/legacy freeze: Ord binder owner/kind differs")
                    }
                    let slot = binder_entry_slot(entry)
                    let site = binder_entry_site(entry)
                    let _ = make_source_binder_entry(
                        slot, owner, binder_entry_kind(entry), site)
                    for existing in ord_seen {
                        if slot_ref_same(
                                binder_entry_slot(existing), slot) ||
                           path_ref_same(
                                binder_entry_site(existing), site) {
                            panic("Core/legacy freeze: Ord binder identity repeats")
                        }
                    }
                    ord_seen.push(entry)
                    let _ = add_binder_fact(
                        builder, slot, "__derived_ord",
                        slot_ref_source_def_id(slot), Type::IntType, false)
                    ord_cursor.set(0, index + 1)
                },
                none => {}
            }
        },
        FieldAction::Tuple { element_actions, .. } => {
            for child in element_actions {
                add_derived_field_action_facts(
                    builder, child, ord_owner, ord_binders,
                    ord_cursor, ord_seen)
            }
        },
        FieldAction::Identity | FieldAction::FloatIdentity |
        FieldAction::BoolIdentity | FieldAction::FnLiteral => {}
    }
}

fn add_delegate_dictionaries(
    mut builder: LegacyFactBuilder, value: HDelegateTypedPlan
) {
    for item in h_delegate_dict_evidence(value) {
        add_dictionary_fact(builder, item)
    }
    for method in h_delegate_methods(value) {
        for item in h_delegate_method_evidence(method) {
            add_dictionary_fact(builder, item)
        }
    }
}

fn scan_expr(
    mut builder: LegacyFactBuilder, owner: ExecutableRef, value: HExpr,
    type_params: List<HTypeParam>, trait_bounds: List<TraitBound>
) {
    add_effect_row(builder, hexpr_effects(value))
    match value {
        HExpr::Call {
            callee, args, resolved_dicts, method_ref, ..
        } => {
            scan_expr(builder, owner, callee, type_params, trait_bounds)
            for arg in args {
                scan_expr(builder, owner, arg, type_params, trait_bounds)
            }
            match method_ref {
                some(method) => {
                    if method_call_ref_is_bound(method) {
                        add_method_dictionary(builder, method)
                    } else {
                        for item in resolved_dicts {
                            add_dictionary_fact(builder, item)
                        }
                    }
                },
                none => {
                    for item in resolved_dicts {
                        add_dictionary_fact(builder, item)
                    }
                }
            }
        },
        HExpr::BinOp { left, right, eq_plan, ord_plan, .. } => {
            scan_expr(builder, owner, left, type_params, trait_bounds)
            scan_expr(builder, owner, right, type_params, trait_bounds)
            match eq_plan {
                some(plan) => add_operator_dictionaries(builder, plan), none => {}
            }
            match ord_plan {
                some(plan) => add_operator_dictionaries(builder, plan), none => {}
            }
        },
        HExpr::UnaryOp { operand, .. } =>
            scan_expr(builder, owner, operand, type_params, trait_bounds),
        HExpr::FieldAccess { receiver: operand, .. } =>
            scan_expr(builder, owner, operand, type_params, trait_bounds),
        HExpr::UnsafeBlock { body: operand, .. } =>
            scan_expr(builder, owner, operand, type_params, trait_bounds),
        HExpr::StructLit { fields, .. } => {
            for field in fields {
                scan_expr(
                    builder, owner, field.value, type_params, trait_bounds)
            }
        },
        HExpr::NamedVariantConstruct { fields, .. } => {
            for field in fields {
                scan_expr(
                    builder, owner, field.value, type_params, trait_bounds)
            }
        },
        HExpr::TupleLit { elements, .. } => {
            for element in elements {
                scan_expr(
                    builder, owner, element, type_params, trait_bounds)
            }
        },
        HExpr::Block { stmts, tail, .. } => {
            for stmt in stmts {
                scan_stmt(
                    builder, owner, stmt, type_params, trait_bounds)
            }
            match tail {
                some(expr) => scan_expr(
                    builder, owner, expr, type_params, trait_bounds),
                none => {}
            }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            scan_expr(builder, owner, condition, type_params, trait_bounds)
            scan_expr(builder, owner, then_branch, type_params, trait_bounds)
            match else_branch {
                some(expr) => scan_expr(
                    builder, owner, expr, type_params, trait_bounds),
                none => {}
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            scan_expr(builder, owner, scrutinee, type_params, trait_bounds)
            for arm in arms {
                add_match_binders(builder, arm)
                match arm.guard {
                    some(expr) => scan_expr(
                        builder, owner, expr, type_params, trait_bounds),
                    none => {}
                }
                scan_expr(
                    builder, owner, arm.body, type_params, trait_bounds)
            }
        },
        HExpr::TryCatch { body: scrutinee, arms, .. } => {
            scan_expr(builder, owner, scrutinee, type_params, trait_bounds)
            for arm in arms {
                add_match_binders(builder, arm)
                match arm.guard {
                    some(expr) => scan_expr(
                        builder, owner, expr, type_params, trait_bounds),
                    none => {}
                }
                scan_expr(
                    builder, owner, arm.body, type_params, trait_bounds)
            }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            scan_expr(builder, owner, body, type_params, trait_bounds)
            for handler in handlers {
                let mut params = handler.params
                match handler.resume_binding {
                    some(binding) => params.push(HParam {
                        name: binding.name, ty: binding.ty,
                        def_id: some(binding.def_id), is_mutable: false
                    }),
                    none => {}
                }
                add_callable_fact(
                    builder, handler.executable_ref, executable_kind_handler(),
                    make_legacy_executable_container(owner),
                    type_params, trait_bounds, params,
                    hexpr_type(handler.body), hexpr_effects(handler.body),
                    true, false, none, none)
                scan_expr(
                    builder, handler.executable_ref, handler.body,
                    type_params, trait_bounds)
            }
        },
        HExpr::Lambda {
            executable_ref, params, return_type, body, ..
        } => {
            add_callable_fact(
                builder, executable_ref, executable_kind_lambda(),
                make_legacy_executable_container(owner),
                type_params, trait_bounds, params,
                return_type, hexpr_effects(body), true, false, none, none)
            scan_expr(
                builder, executable_ref, body, type_params, trait_bounds)
        },
        HExpr::EffectOp { args, .. } => {
            for arg in args {
                scan_expr(builder, owner, arg, type_params, trait_bounds)
            }
        },
        HExpr::ReturnExpr { value, .. } => match value {
            some(expr) => scan_expr(
                builder, owner, expr, type_params, trait_bounds),
            none => {}
        },
        HExpr::Ident { dict_closure_dicts, .. } => match dict_closure_dicts {
            some(values) => {
                for item in values { add_dictionary_fact(builder, item) }
            },
            none => {}
        },
        HExpr::IntLit { .. } | HExpr::FloatLit { .. } |
        HExpr::StrLit { .. } | HExpr::BoolLit { .. } => {},
        _ => panic("Core/legacy freeze: surface/resource expr crossed PreCore")
    }
}

fn impl_method_refs(values: List<HDecl>) -> List<ImplMethodRef> {
    let mut result: List<ImplMethodRef> = []
    for value in values {
        match value {
            HDecl::Fn { impl_method_ref: some(reference), .. } =>
                result.push(reference),
            _ => {}
        }
    }
    result
}

const LEGACY_GENERATED_DEF_ID_BASE: Int = 0 - 8500000000

fn add_generated_callable_fact(
    mut builder: LegacyFactBuilder, reference: ExecutableRef,
    method: ImplMethodRef,
    kind: ExecutableKind, type_params: List<HTypeParam>,
    trait_bounds: List<TraitBound>, entries: List<BinderEntry>,
    parameter_types: List<Type>, parameter_mutabilities: List<Bool>,
    result_type: Type, effects: EffectRow
) {
    if entries.len() != parameter_types.len() ||
       entries.len() != parameter_mutabilities.len() {
        panic("Core/legacy freeze: generated parameter census differs")
    }
    let mut parameters: List<LegacyBinderFactProjection> = []
    let mut index = 0
    while index < entries.len() {
        let slot = binder_entry_slot(entries.get(index).unwrap())
        let def_id = if slot_ref_is_source(slot) {
            slot_ref_source_def_id(slot)
        } else {
            LEGACY_GENERATED_DEF_ID_BASE - builder.binders.len()
        }
        parameters.push(add_binder_fact(
            builder, slot, "__generated_p${index}", def_id,
            parameter_types.get(index).unwrap(),
            parameter_mutabilities.get(index).unwrap()))
        index = index + 1
    }
    let origin = executable_origin(reference)
    let container = make_legacy_module_container(builder.module_body)
    let type_parameters = callable_type_parameters(type_params, trait_bounds)
    let bounds = callable_trait_bounds(type_parameters, trait_bounds)
    let result_fact = exact_type_fact(
        builder.type_sources, result_type, builder.module_key)
    if executable_uses_physical_owner(builder, reference) {
        builder.prelude_callables.push(
            make_legacy_prelude_callable_fact_projection(
                reference, origin, builder.module_body, container, kind,
                type_parameters, bounds, parameters, result_fact,
                result_type, effects, false))
        builder.shells.push(make_legacy_prelude_executable_shell(
            reference, origin, kind, builder.module_body, container))
    } else {
        builder.callables.push(make_legacy_callable_fact_projection(
            reference, origin, builder.module_body, container, kind,
            type_parameters, bounds, parameters, result_fact,
            result_type, effects, false))
        builder.shells.push(make_legacy_executable_shell(
            reference, origin, kind, builder.module_body, container))
    }
    add_effect_row(builder, effects)
    add_physical_identity(builder, reference, some(method), none)
}

fn add_default_specialization_facts(
    mut builder: LegacyFactBuilder,
    values: List<HDefaultSpecializationPlan>,
    mut methods: List<ImplMethodRef>, type_params: List<HTypeParam>
) {
    for value in values {
        let method = h_default_specialization_generated_method(value)
        add_generated_callable_fact(
            builder,
            h_default_specialization_generated_executable(value),
            method,
            executable_kind_default_specialization(),
            type_params, trait_bounds_from_type_parameters(type_params),
            h_default_specialization_binders(value),
            h_default_specialization_parameter_types(value),
            h_default_specialization_parameter_mutabilities(value),
            h_default_specialization_result_type(value),
            h_default_specialization_effects(value))
        methods.push(method)
        let exact = h_default_specialization_forward_call(value)
        for item in h_exact_call_evidence(exact) {
            add_dictionary_fact(builder, item)
        }
    }
}

fn add_derived_field_binders(
    mut builder: LegacyFactBuilder, fields: List<DerivedField>,
    ord_owner: ExecutableRef?, mut ord_seen: List<BinderEntry>
) {
    for field in fields {
        let mut cursor: List<Int> = [0]
        add_derived_field_action_facts(
            builder, field.action, ord_owner, field.ord_result_binders,
            cursor, ord_seen)
        let consumed = match cursor.get(0) {
            some(value) => value,
            none => panic("Core/legacy freeze: Ord binder cursor is absent")
        }
        if consumed != field.ord_result_binders.len() {
            panic("Core/legacy freeze: Ord binder/Call-leaf census differs")
        }
    }
}

fn derived_ord_executable(value: DerivedImpl) -> ExecutableRef? {
    if derived_semantic_kind_tag(value.semantic_kind) != 4 {
        return none
    }
    let mut found: ExecutableRef? = none
    for method in value.methods {
        if derived_semantic_kind_tag(method.semantic_kind) == 4 {
            if found.is_some() {
                panic("Core/legacy freeze: derived Ord cmp repeats")
            }
            found = some(method.executable_ref)
        }
    }
    match found {
        some(owner) => some(owner),
        none => panic("Core/legacy freeze: derived Ord cmp is absent")
    }
}

fn add_derived_impl_facts(
    mut builder: LegacyFactBuilder, values: List<DerivedImpl>
) {
    let module_container = make_legacy_module_container(builder.module_body)
    for derived in values {
        let ord_owner = derived_ord_executable(derived)
        let mut ord_seen: List<BinderEntry> = []
        let mut method_refs: List<ImplMethodRef> = []
        for method in derived.methods {
            let (params, result, effects) = match method.signature {
                Type::FnType { params, return_type, effects } =>
                    (params, return_type, effects),
                _ => panic("Core/legacy freeze: derived method is not callable")
            }
            add_generated_callable_fact(
                builder, method.executable_ref, method.method_ref,
                executable_kind_derived_impl(),
                derived.type_params, derived.bounds,
                method.binders, params, params.map(fn(_) { false }),
                result, effects)
            method_refs.push(method.method_ref)
        }
        match derived.struct_fields {
            some(fields) => add_derived_field_binders(
                builder, fields, ord_owner, ord_seen),
            none => {}
        }
        match derived.enum_variants {
            some(variants) => {
                for variant in variants {
                    add_derived_field_binders(
                        builder, variant.fields, ord_owner, ord_seen)
                }
            },
            none => {}
        }
        match derived.text_plan {
            some(text) => {
                let builder_type = match h_exact_call_signature(text.builder) {
                    Type::FnType { return_type, .. } => return_type,
                    _ => panic("Core/legacy freeze: text builder is not callable")
                }
                let slot = binder_entry_slot(text.builder_binder)
                if slot_ref_is_source(slot) {
                    add_binder_fact(
                        builder, slot, "__derived_text_builder",
                        slot_ref_source_def_id(slot), builder_type, false)
                }
            },
            none => {}
        }
        method_refs.sort_by(fn(left, right) {
            impl_method_ref_callable_slot_index(left) -
                impl_method_ref_callable_slot_index(right)
        })
        let target_fact = exact_type_fact(
            builder.type_sources, derived.target_type, builder.module_key)
        let projection = if impl_uses_physical_owner(
                builder, derived.owner_ref) {
            make_legacy_physical_impl_fact_projection(
                derived.owner_ref, target_fact, derived.target_type,
                impl_owner_ref_target(derived.owner_ref),
                some(derived.trait_ref),
                callable_type_parameters(
                    derived.type_params, derived.bounds),
                [], method_refs, builder.module_body, module_container)
        } else {
            make_legacy_impl_fact_projection(
                derived.owner_ref, target_fact, derived.target_type,
                impl_owner_ref_target(derived.owner_ref),
                some(derived.trait_ref),
                callable_type_parameters(
                    derived.type_params, derived.bounds),
                [], method_refs, builder.module_body, module_container)
        }
        builder.impls.push(projection)
    }
}

fn scan_decls(
    mut builder: LegacyFactBuilder, values: List<HDecl>,
    inherited_type_params: List<HTypeParam>
) {
    let module_container = make_legacy_module_container(builder.module_body)
    for value in values {
        match value {
            HDecl::Fn {
                name, executable_ref, impl_method_ref, type_params, params,
                return_type, effects, body, is_pub, trait_bounds, ..
            } => {
                let callable_type_params = merge_callable_type_parameters(
                    inherited_type_params, type_params)
                add_callable_fact(
                    builder, executable_ref,
                    if impl_method_ref.is_some() {
                        executable_kind_impl_method()
                    } else { executable_kind_fn() },
                    module_container,
                    callable_type_params,
                    trait_bounds, params,
                    return_type, effects, true, is_pub,
                    impl_method_ref, some(name))
                scan_expr(
                    builder, executable_ref, body,
                    callable_type_params, trait_bounds)
            },
            HDecl::Test { description, executable_ref, body, .. } => {
                add_callable_fact(
                    builder, executable_ref, executable_kind_test(),
                    module_container, [], [], [], hexpr_type(body),
                    hexpr_effects(body), true, false, none, some(description))
                scan_expr(builder, executable_ref, body, [], [])
            },
            HDecl::Const { name, executable_ref, ty, init, .. } => {
                add_callable_fact(
                    builder, executable_ref,
                    executable_kind_const_getter(), module_container,
                    [], [], [], ty, hexpr_effects(init), true, false,
                    none, some(name))
                scan_expr(builder, executable_ref, init, [], [])
            },
            HDecl::ExternFn {
                name, executable_ref, type_params, params, return_type, effects,
                trait_bounds, is_pub, ..
            } => add_callable_fact(
                builder, executable_ref, executable_kind_extern_fn(),
                module_container, type_params, trait_bounds, params,
                return_type, effects, false, is_pub, none, some(name)),
            HDecl::Trait { name, type_params, methods, .. } => {
                let callable_type_params = merge_callable_type_parameters(
                    inherited_type_params, type_params)
                for method in methods {
                    add_callable_fact(
                        builder, method.executable_ref,
                        if method.body.is_some() {
                            executable_kind_trait_default()
                        } else { executable_kind_bodyless_trait_member() },
                        module_container, callable_type_params, [], method.params,
                        method.return_type, method.effects,
                        method.body.is_some(), false,
                        none, some("__${name}_${method.name}"))
                    match method.body {
                        some(body) => scan_expr(
                            builder, method.executable_ref, body,
                            callable_type_params, []),
                        none => {}
                    }
                }
            },
            HDecl::Effect { name, type_params, ops, .. } => {
                let callable_type_params = merge_callable_type_parameters(
                    inherited_type_params, type_params)
                for op in ops {
                    match op.operation_ref {
                        some(reference) => add_callable_fact(
                            builder, effect_operation_ref_callable(reference),
                            executable_kind_bodyless_effect_operation(),
                            module_container, callable_type_params, [], op.params,
                            op.return_type,
                            EffectRow { effects: [], tail: none }, false, false,
                            none, some("__${name}_${op.name}")),
                        none => {}
                    }
                }
            },
            HDecl::Impl {
                target_ty, owner_ref, trait_ref, type_params,
                delegate_plan, methods, default_specializations,
                assoc_types, ..
            } => {
                match delegate_plan {
                    some(plan) => add_delegate_dictionaries(builder, plan),
                    none => {}
                }
                let impl_type_params = merge_callable_type_parameters(
                    inherited_type_params, type_params)
                scan_decls(builder, methods, impl_type_params)
                let mut method_refs = impl_method_refs(methods)
                add_default_specialization_facts(
                    builder, default_specializations, method_refs,
                    impl_type_params)
                method_refs.sort_by(fn(left, right) {
                    impl_method_ref_callable_slot_index(left) -
                        impl_method_ref_callable_slot_index(right)
                })
                let assoc = assoc_types.filter(fn(value) {
                    value.concrete.is_some()
                }).map(fn(value) {
                    let ty = value.concrete.unwrap()
                    make_legacy_assoc_binding_fact_projection(
                        value.member_ref,
                        exact_type_fact(
                            builder.type_sources, ty, builder.module_key), ty)
                })
                let target_fact = exact_type_fact(
                    builder.type_sources, target_ty, builder.module_key)
                let projection = if impl_uses_physical_owner(
                        builder, owner_ref) {
                    make_legacy_physical_impl_fact_projection(
                        owner_ref, target_fact, target_ty,
                        impl_owner_ref_target(owner_ref), trait_ref,
                        callable_type_parameters(impl_type_params, []), assoc,
                        method_refs, builder.module_body, module_container)
                } else {
                    make_legacy_impl_fact_projection(
                        owner_ref, target_fact, target_ty,
                        impl_owner_ref_target(owner_ref), trait_ref,
                        callable_type_parameters(impl_type_params, []), assoc,
                        method_refs, builder.module_body, module_container)
                }
                builder.impls.push(projection)
            },
            HDecl::ModBlock { decls, .. } => scan_decls(builder, decls, []),
            HDecl::Struct { .. } | HDecl::Enum { .. } |
            HDecl::ExternType { .. } | HDecl::TypeAlias { .. } => {}
        }
    }
}

const LEGACY_BUILTIN_PARAM_DEF_ID_BASE: Int = 0 - 8000000000

fn add_builtin_facts(mut builder: LegacyFactBuilder, env: TypeEnv) {
    let mut global_param_ordinal = 0
    for fact in builtin_method_contract_facts(env) {
        let intrinsic = builtin_method_contract_intrinsic(fact)
        let scheme = builtin_method_contract_scheme(fact)
        let (params, result, effects) = match scheme.ty {
            Type::FnType { params, return_type, effects } =>
                (params, return_type, effects),
            _ => panic("Core/legacy freeze: builtin scheme is not callable")
        }
        let executable = make_named_executable_ref(
            intrinsic_ref_symbol(intrinsic))
        let owner = path_owner_for_symbol(intrinsic_ref_symbol(intrinsic))
        let mut parameter_facts: List<LegacyBinderFactProjection> = []
        let mut index = 0
        for ty in params {
            let site = make_path_ref(
                owner, ["legacy-builtin-param", index.to_str()],
                path_role_parameter())
            parameter_facts.push(add_binder_fact(
                builder, make_synthetic_slot_ref(site),
                "__builtin_p${index}",
                LEGACY_BUILTIN_PARAM_DEF_ID_BASE - global_param_ordinal,
                ty, false))
            index = index + 1
            global_param_ordinal = global_param_ordinal + 1
        }
        builder.builtin_callables.push(
            make_legacy_builtin_callable_fact_projection(
                intrinsic, parameter_facts,
                exact_type_fact(
                    builder.type_sources, result, builder.module_key),
                result, effects))
        add_physical_identity(builder, executable, none, none)
    }
}

// Implemented as the only HIR traversal. Keeping this helper private prevents
// checker or bridge callers from assembling partial fact lists.
fn freeze_legacy_semantic_facts(
    module_key: Str, module_order: Int, closed: HProgram,
    env: TypeEnv, type_sources: List<CoreTypeSourceFact>,
    effect_ctx_type: CoreEffectCtxTypeSource,
    prelude_physical_owner_module_key: Str,
    physical_module_prefix: Str
) -> LegacyProjectionFacts {
    if (module_order == 0) !=
           (module_key == prelude_physical_owner_module_key) {
        panic("Core/legacy freeze: prelude physical owner/order differs")
    }
    let module_body = make_module_body_ref(module_key, "module-body")
    let builder = LegacyFactBuilder {
        module_key: module_key,
        physical_module_prefix: physical_module_prefix,
        owns_prelude: module_key == prelude_physical_owner_module_key,
        module_body: module_body,
        type_sources: type_sources, effects: [], binders: [],
        callables: [], prelude_callables: [], builtin_callables: [],
        impls: [], dictionaries: [], physical_identities: [], shells: []
    }
    scan_decls(builder, closed.decls, [])
    add_derived_impl_facts(builder, closed.derived_impls)
    if module_order == 0 { add_builtin_facts(builder, env) }
    let mut internal_types = [make_legacy_internal_type_fact_projection(
        core_effect_ctx_source_aggregate_fact(effect_ctx_type),
        legacy_internal_effect_ctx_opaque())]
    make_legacy_projection_facts(
        module_key, module_order,
        type_sources.len() + internal_types.len(), type_sources,
        internal_types, builder.effects, builder.binders, builder.callables,
        builder.prelude_callables, builder.builtin_callables, builder.impls,
        builder.dictionaries,
        builder.physical_identities,
        make_legacy_executable_shell_map(builder.shells))
}

pub fn freeze_core_and_legacy_facts(
    module_key: Str, module_order: Int,
    program: HProgram, env: TypeEnv,
    prelude_physical_owner_module_key: Str,
    physical_module_prefix: Str
) -> FrozenCoreAndLegacyFacts {
    let closed = close_hir_surface(program, env)
    let effect_freeze = freeze_typed_effect_formals(env)
    let core = produce_closed_core_assembly_facts(
        module_key, module_order, closed, env,
        typed_effect_freeze_formals(effect_freeze),
        typed_effect_freeze_callables(effect_freeze))
    let sealed_program = frozen_core_assembly_program(core)
    let type_sources = frozen_core_assembly_type_sources(core)
    let effect_ctx_type = frozen_core_assembly_effect_ctx_type(core)
    let legacy = freeze_legacy_semantic_facts(
        module_key, module_order, sealed_program, env, type_sources,
        effect_ctx_type,
        prelude_physical_owner_module_key,
        physical_module_prefix)
    FrozenCoreAndLegacyFacts { core: core, legacy: legacy }
}
