// Sole post-semantic-lowering HIR -> CoreHIR assembly boundary.
//
// The recorder owns only module-local type construction.  Source Type -> fact
// relations are passed as an immutable checker snapshot; expression, binder,
// callable, impl and executable facts are derived once from canonical HIR.

use ast::{Span, Pattern, LiteralValue, BinOp, UnaryOp, span_zero}
use types::{Type, Effect, EffectRow, types_equal, EMPTY_ROW}
use env::{
    TypeEnv, TraitDef, AssocTypeDef,
    RegisteredTraitAssocContract,
    registered_trait_contract_owner,
    registered_trait_contract_methods,
    registered_trait_contract_assoc_items,
    registered_trait_contract_dict_obligations,
    registered_trait_assoc_member, registered_trait_assoc_type,
    registered_trait_assoc_default, registered_trait_assoc_bounds,
    registered_trait_method_mutabilities, apply_subst_map, find_impl
}
use builtins::{
    BuiltinMethodContractFact, builtin_method_contract_facts,
    builtin_method_contract_intrinsic, builtin_method_contract_scheme,
    builtin_method_contract_target_owner,
    builtin_method_contract_target_type_vars,
    builtin_method_contract_method_type_vars,
    builtin_method_contract_resource
}
use precore_lower::{close_hir_surface}
use core_type_source::{
    CoreTypeFactAllocator,
    CoreTypeGraph, make_module_core_type_graph, make_core_type_graph,
    CoreTypeSourceFact, CoreHandledEvidenceTypeSource,
    CoreHandledEvidenceOperationTypeSource,
    make_core_type_source_fact,
    make_core_handled_evidence_operation_type_source,
    make_core_handled_evidence_type_source,
    core_type_source_type, core_type_source_fact,
    core_handled_evidence_source_requirement,
    core_handled_evidence_source_aggregate_fact,
    core_handled_evidence_type_source_same,
    new_core_type_fact_allocator, reserve_core_type_fact_ref
}
use resource_model::{
    FlowTypeSemanticSeed,
    flow_type_seed_shareable, flow_type_seed_unique,
    FlowSemanticRole, FlowCallContract,
    make_flow_call_contract, make_module_flow_call_contract,
    flow_semantic_role_read, flow_semantic_role_mutate,
    flow_semantic_role_consume, flow_semantic_role_force,
    make_fresh_flow_value_origin, make_aliasing_flow_value_origin,
    flow_own_storage, flow_borrow_storage
}
use ir_identity::{
    CoreTypeRef, CoreTypeFactRef,
    core_type_fact_module_key, core_type_fact_ordinal,
    core_type_fact_same, core_type_fact_local_ref,
    make_core_type_ref, make_module_core_type_ref,
    core_type_ref_index,
    SymbolRef, PathRef, PathOwnerRef, PathRole, SlotRef, CalleeRef,
    NominalFieldRef,
    ModuleBodyRef, make_module_body_ref,
    OriginRef, ImplOwnerRef, ImplMethodRef,
    RegisteredNominalRef, VariantRef, HandledEffectRef,
    handled_effect_ref_same, make_symbol_ref, namespace_value,
    symbol_ref_origin_module_key,
    symbol_ref_same,
    origin_ref_same, origin_ref_is_symbol, origin_ref_symbol, origin_ref_path,
    path_owner_for_symbol, path_owner_for_module_body,
    path_ref_owner, path_ref_normalized_child_path, path_ref_role,
    path_role_same,
    path_owner_ref_is_symbol, path_owner_ref_symbol,
    path_owner_ref_module_body, module_body_ref_origin_module_key,
    path_role_child, path_role_parameter, path_role_declaration,
    path_role_capture, path_role_handler, path_role_synthetic,
    make_path_ref, make_path_origin_ref, make_symbol_origin_ref,
    make_source_slot_ref, slot_domain_lexical, slot_domain_dictionary,
    slot_ref_is_source, slot_ref_source_origin_module_key,
    slot_ref_synthetic_path,
    make_synthetic_slot_ref,
    callee_ref_is_named, callee_ref_named_symbol,
    callee_ref_is_local, callee_ref_local_slot,
    callee_ref_dynamic_path,
    impl_owner_ref_same, impl_owner_ref_provider, impl_method_ref_same,
    impl_method_ref_owner,
    impl_method_ref_member,
    impl_method_ref_callable_slot_index,
    intrinsic_ref_symbol, trait_method_ref_member,
    intrinsic_ref_same,
    BUILTIN_METHOD_SITE_COUNT,
    registered_nominal_ref_symbol,
    registered_trait_ref_symbol,
    impl_owner_ref_target,
    handled_effect_ref_symbol,
    variant_ref_member, variant_ref_same,
    variant_field_ref_variant, variant_field_ref_member,
    nominal_field_ref_member, impl_provider_ref_site,
    nominal_field_ref_same,
    variant_field_ref_same,
    slot_ref_same, slot_ref_source_def_id
}
use ir_inventory::{
    ExecutableRef, ExactDictRef,
    dict_ref_is_local, dict_ref_is_static,
    dict_ref_local, dict_ref_static,
    dict_ref_wrapped_base, dict_ref_wrapped_inner,
    make_exact_local_dict_ref, make_exact_static_dict_ref,
    make_exact_wrapped_dict_ref,
    ExecutableEntry, ExecutableInventory, ExecutableParentRef,
    ExecutableKind,
    BinderKind, BinderEntry, binder_kind_tag,
    make_named_executable_ref, make_anonymous_executable_ref,
    executable_ref_is_named, executable_ref_named_symbol,
    executable_ref_anonymous_path, executable_ref_same,
    executable_ref_origin_module_key, executable_ref_is_prelude,
    make_module_body_parent, make_executable_parent,
    make_executable_entry, make_executable_inventory,
    executable_entry_reference, executable_entry_contract,
    ExecutableContractMode,
    executable_contract_mode, executable_contract_mode_same,
    executable_contract_mode_concrete_body,
    executable_contract_mode_contract_only,
    make_concrete_body_contract, make_contract_only,
    executable_contract_body_path,
    executable_kind_fn, executable_kind_impl_method,
    executable_kind_trait_default, executable_kind_test,
    executable_kind_const_getter, executable_kind_lambda,
    executable_kind_handler, executable_kind_builtin_intrinsic,
    executable_kind_default_specialization,
    executable_kind_derived_impl,
    executable_kind_extern_fn, executable_kind_bodyless_effect_operation,
    executable_kind_bodyless_trait_member,
    binder_kind_source_param, binder_kind_let, binder_kind_var,
    binder_kind_dictionary_evidence_local,
    binder_kind_dictionary_evidence_param,
    binder_kind_match_pattern, binder_kind_catch_pattern,
    binder_kind_lambda_param, binder_kind_handler_param,
    binder_kind_handler_resume, binder_kind_lambda_capture,
    binder_kind_pre_anf,
    binder_kind_generated_synthetic_parameter,
    binder_kind_handled_evidence_local,
    binder_kind_handled_evidence_param,
    binder_entry_slot, binder_entry_kind, binder_entry_site,
    EffectOperationRef, SystemHostCallableRef, HandledEvidenceRef,
    HandledEvidenceCapture,
    make_semantic_evidence_binder, make_handled_evidence_ref,
    handled_evidence_requirement, handled_evidence_binding,
    handled_evidence_capture_target,
    effect_operation_ref_callable, effect_operation_ref_source_index,
    effect_operation_ref_effect,
    ExactMethodRef, make_exact_intrinsic_method_ref,
    make_exact_impl_method_ref, make_exact_trait_method_ref,
    CallableResourceContractFact, CallableResourceRoleFact,
    callable_resource_role_tag,
    callable_resource_contract_parameter_roles,
    callable_resource_contract_result_role,
    callable_resource_contract_result_alias_ordinals
}
use hir::{
    HProgram, HDecl, HExpr, HStmt, HParam, HTypeParam,
    HMatchArm, HEffectHandler,
    HLambdaCapture, HStringInterpPart,
    HPatternBinding, HProjectionRef, HPatternPlan, HPatternFieldPlan,
    HNominalStructFieldInit, HStructFieldInit, HFieldAccessKind,
    HAssocType, HTraitMethod, DictRef, MethodCallRef,
    HDelegateTypedPlan, HDelegateMethodPlan,
    HDefaultSpecializationPlan, HExactCallPlan, HOperatorPlan,
    DerivedImpl, DerivedMethod, DerivedField, DerivedVariant,
    DerivedFieldRef, FieldAction, DerivedTextPlan, DerivedTextPiece,
    DerivedTextSequence,
    TypeKind,
    hexpr_type, hexpr_effects, hexpr_span,
    method_call_ref_is_intrinsic, method_call_ref_is_concrete,
    method_call_ref_is_bound,
    method_call_ref_intrinsic, method_call_ref_impl,
    method_call_ref_bound, method_call_ref_bound_evidence,
    method_call_ref_receiver_mutable, method_call_ref_signature,
    method_call_ref_callee_identity,
    h_projection_kind, h_projection_nominal, h_projection_variant,
    h_projection_structural, h_projection_structural_name,
    h_projection_tuple_index,
    h_projection_intrinsic,
    h_pattern_kind, h_pattern_plan_binding, h_pattern_plan_children,
    h_pattern_plan_fields, h_pattern_plan_struct_owner,
    h_pattern_plan_variant, h_pattern_field_projection,
    h_pattern_field_pattern,
    h_operator_is_tuple, h_operator_method_ref, h_operator_elements,
    h_constructor_kind, h_constructor_executable,
    h_constructor_fields, h_constructor_tuple_arity,
    h_fail_operation_tag,
    h_delegate_contract, h_delegate_child_owner,
    h_delegate_child_provider, h_delegate_field_owner,
    h_delegate_field_provider, h_delegate_field_target,
    h_delegate_field, h_delegate_source_member_index,
    h_delegate_methods, h_delegate_assoc_bindings,
    h_delegate_dict_evidence,
    h_delegate_method_required, h_delegate_method_generated,
    h_delegate_method_executable, h_delegate_method_origin,
    h_delegate_method_child_call, h_delegate_method_child_callee,
    h_delegate_method_binders, h_delegate_method_parameter_types,
    h_delegate_method_result_type, h_delegate_method_effects,
    h_delegate_method_evidence, h_delegate_method_handled_bindings,
    h_delegate_method_handled_uses,
    h_delegate_assoc_member, h_delegate_assoc_type,
    h_default_specialization_owner,
    h_default_specialization_generated_method,
    h_default_specialization_generated_executable,
    h_default_specialization_parameter_types,
    h_default_specialization_parameter_mutabilities,
    h_default_specialization_binders,
    h_default_specialization_result_type,
    h_default_specialization_effects,
    h_default_specialization_forward_call,
    h_exact_call_callee, h_exact_call_signature, h_exact_call_method,
    h_exact_call_evidence, h_exact_call_handled_evidence,
    derived_semantic_kind_tag, DERIVED_HASH_SEED,
    validate_hir_binder_def_ids
}
use hir_exact::{dict_ref_exact}
use core_type_source::{
    FlowTypeNode, FlowTypeKind,
    FlowFieldIdentity, FlowNominalFieldFact,
    FlowGenericParamFact,
    FlowDropContract,
    flow_type_kind_tag,
    make_flow_generic_param_fact,
    flow_generic_param_index, flow_generic_param_arity,
    flow_generic_param_owner, flow_generic_param_bounds,
    flow_type_kind_int, flow_type_kind_float, flow_type_kind_str,
    flow_type_kind_bool, flow_type_kind_unit, flow_type_kind_never,
    flow_type_kind_struct, flow_type_kind_enum,
    make_flow_int_type_node, make_flow_float_type_node,
    make_flow_str_type_node, make_flow_bool_type_node,
    make_flow_unit_type_node, make_flow_never_type_node,
    make_flow_parameter_type_node, make_flow_struct_type_node,
    make_flow_enum_type_node, make_flow_extern_type_node,
    make_flow_tuple_type_node, make_flow_record_type_node,
    make_flow_callable_type_node, make_flow_ptr_type_node,
    make_flow_nominal_field_fact, make_flow_record_field_fact,
    make_flow_drop_contract,
    make_nominal_flow_field_identity,
    make_variant_flow_field_identity,
    make_path_flow_field_identity,
    flow_type_node_reference, flow_type_node_kind,
    flow_type_node_callable_effects,
    flow_type_kind_parameter,
    flow_type_node_nominal_fields,
    flow_nominal_field_identity, flow_nominal_field_type,
    flow_nominal_field_record_name,
    flow_field_identity_is_nominal, flow_field_identity_is_variant,
    flow_field_identity_nominal, flow_field_identity_variant,
    flow_field_identity_path,
    flow_type_node_intern_ready, flow_type_node_intern_key_same,
    flow_type_node_contract_same, remap_flow_type_node
}
use core_expr::{
    CoreCallableContract, CoreImplMetadata, CoreAssocBinding,
    CoreBody, CoreBinder, CoreBlock, CoreStmt, CoreExpr, CorePlaceRef,
    CorePattern, CorePatternField, CoreFieldRef, CoreFieldValue,
    CoreConstructorRef, CoreCalleeRef, CoreEvidenceRef,
    CoreHandledEvidenceBinding, CoreHandledEvidenceUse,
    CoreHandledEvidenceCapture,
    CoreMatchArm, CoreHandlerOperation, CoreHandlerInstallation,
    make_core_callable_contract, make_core_impl_metadata,
    make_core_assoc_binding, make_core_binder, make_core_body,
    make_core_block, make_core_bind_stmt, make_core_assign_stmt,
    make_core_expr_stmt, make_core_while_stmt, make_core_break_stmt,
    make_core_continue_stmt, make_core_return_stmt,
    make_core_literal_expr, make_core_int_literal, make_core_float_literal,
    make_core_str_literal, make_core_bool_literal, make_core_unit_literal,
    make_core_read_expr, make_core_callable_value_expr,
    make_core_primitive_op, make_core_primitive_expr, make_core_call_expr,
    make_core_method_call_expr, make_core_effect_call_expr,
    make_core_system_call_expr, make_core_fail_raise_expr,
    make_core_project_expr, make_core_construct_expr,
    make_core_move_update_expr,
    make_core_capture, make_core_lambda_expr, make_core_block_expr, make_core_if_expr,
    make_core_match_expr, make_core_try_catch_expr, make_core_handle_expr,
    make_core_slot_place, make_core_project_place,
    make_core_nominal_field, make_core_variant_field,
    make_core_tuple_field, make_core_record_field,
    make_core_struct_constructor, make_core_variant_constructor,
    make_core_tuple_constructor, make_core_field_value,
    make_core_dict_evidence, make_core_direct_callee,
    make_core_local_callee, make_core_dynamic_callee,
    make_core_handled_evidence_binding,
    make_core_handled_evidence_use,
    make_core_handled_evidence_capture,
    make_core_wildcard_pattern, make_core_binding_pattern,
    make_core_literal_pattern, make_core_tuple_pattern,
    make_core_struct_pattern, make_core_variant_pattern,
    make_core_pattern_field, make_core_match_arm,
    make_core_handler_operation, make_core_handler_installation,
    remap_core_callable_types, remap_core_impl_types,
    remap_core_body_types, remap_core_effect_contract_types,
    core_body_effect_sets,
    core_body_reference, core_body_origin, core_body_binders,
    core_body_origins,
    core_binder_reference, core_binder_type, core_binder_kind,
    core_field_ref_same,
    core_handler_operation_ref
}
use core_hir::{
    CoreProgram, CoreBodyEntry, make_core_body_entry, make_core_program,
    core_body_entry_reference, core_body_entry_body,
    core_body_entry_origin, core_body_entry_anchor
}
use effect_contract::{
    EffectParamRef, effect_param_owner, effect_param_ordinal,
    TypedEffectFormalFact, typed_effect_formal_raw_tail,
    typed_effect_formal_parameter,
    CoreEffectSet, CoreEffectAtom, CoreEffectContract,
    make_core_effect_set, make_core_effect_contract,
    make_explicit_core_effect_instantiation,
    core_effect_contract_exact, core_effect_contract_parameter,
    core_effect_set_atoms, core_effect_set_same,
    core_effect_atom_kind_tag, core_effect_atom_type,
    core_effect_atom_handled_ref, core_effect_atom_system_ref,
    core_effect_atom_type_arguments, core_effect_contract_same,
    make_core_fail_effect, make_core_mut_effect,
    make_core_unsafe_effect, make_core_handled_effect,
    make_core_system_effect
}
use typed_effect_freeze::{
    TypedCallableEffectFact, typed_callable_effect_reference,
    typed_callable_effect_row
}
use extern_manifest::{compiler_extern_ref_for_executable}
use delegate_plan::{
    DelegateMethodPlan, DelegateEvidenceBinding,
    make_delegate_method_body_plan, make_delegate_method_plan,
    make_delegate_assoc_binding, make_delegate_evidence_binding,
    make_delegate_plan_input, validate_delegate_plan
}
use delegate_elaborate::{elaborate_delegate_to_core}
use core_elaborate::{
    make_core_ordinary_body_plan, elaborate_core_default_specialization
}
use core_derive_lower::{
    CoreDerivedHeader, CoreDerivedValueRef, CoreDerivedCallPlan,
    CoreDerivedFieldPlan, CoreDerivedVariantPlan,
    CoreDerivedOrdVariantPlan, CoreDerivedCloneVariantPlan,
    CoreDerivedTextPatternField, CoreDerivedTextSequence,
    CoreDerivedTextRenderPlan,
    make_core_derived_header, make_core_derived_value_ref,
    make_core_derived_call_plan, make_core_derived_field_plan,
    make_core_derived_tuple_field_plan,
    make_core_derived_variant_plan,
    make_core_derived_struct_shape, make_core_derived_enum_shape,
    make_core_derived_eq_plan, elaborate_core_derived_eq_body,
    elaborate_core_derived_ne_body,
    make_core_derived_hash_plan, elaborate_core_derived_hash_body,
    make_core_derived_struct_ord_plan,
    make_core_derived_enum_ord_plan,
    make_core_derived_ord_variant_plan,
    elaborate_core_derived_ord_body,
    make_core_derived_struct_clone_plan,
    make_core_derived_enum_clone_plan,
    make_core_derived_clone_variant_plan,
    elaborate_core_derived_clone_body,
    make_core_derived_literal_text_piece,
    make_core_derived_rendered_text_piece,
    make_core_derived_text_render_leaf,
    make_core_derived_text_render_tuple,
    make_core_derived_text_render_literal_only,
    make_core_derived_text_sequence,
    make_core_derived_text_pattern_field,
    make_core_derived_text_variant_plan,
    make_core_derived_struct_text_plan,
    make_core_derived_enum_text_plan,
    make_core_derived_debug_plan, make_core_derived_json_plan,
    elaborate_core_derived_debug_body,
    elaborate_core_derived_json_body
}

// ============================================================
// Module-local type recorder
// ============================================================

struct CoreNominalFieldSpec {
    identity: FlowFieldIdentity,
    ty: CoreTypeFactRef,
    record_name: Str?
}
fn make_core_nominal_field_spec(
    identity: FlowFieldIdentity, ty: CoreTypeFactRef
) -> CoreNominalFieldSpec {
    CoreNominalFieldSpec { identity: identity, ty: ty, record_name: none }
}
fn make_core_record_field_spec(
    name: Str, identity: FlowFieldIdentity, ty: CoreTypeFactRef
) -> CoreNominalFieldSpec {
    if name == "" { panic("Core assembly: record field name is empty") }
    CoreNominalFieldSpec {
        identity: identity, ty: ty, record_name: some(name)
    }
}

enum CoreTypeSpecValue {
    Atomic(FlowTypeKind),
    Parameter(FlowGenericParamFact),
    Nominal {
        kind: FlowTypeKind, nominal: SymbolRef,
        arguments: List<CoreTypeFactRef>, fields: List<CoreNominalFieldSpec>,
        seed: FlowTypeSemanticSeed, drop_contract: FlowDropContract?,
        resource_storage_parameter_ordinals: List<Int>
    },
    Extern { nominal: SymbolRef, arguments: List<CoreTypeFactRef> },
    Tuple { elements: List<CoreTypeFactRef>, seed: FlowTypeSemanticSeed,
            drop_contract: FlowDropContract? },
    Record { fields: List<CoreNominalFieldSpec>, seed: FlowTypeSemanticSeed,
             drop_contract: FlowDropContract? },
    Callable { parameters: List<CoreTypeFactRef>, result: CoreTypeFactRef,
               effects: CoreEffectContract },
    Ptr(CoreTypeFactRef)
}
struct CoreTypeSpec { value: CoreTypeSpecValue }

struct CoreAssemblyRecorder {
    module_key: Str, module_order: Int,
    allocator: CoreTypeFactAllocator,
    refs: List<CoreTypeFactRef>, specs: List<CoreTypeSpec?>,
    frozen: Bool
}
fn new_core_assembly_recorder(
    module_key: Str, module_order: Int
) -> CoreAssemblyRecorder {
    if module_key == "" || module_order < 0 {
        panic("Core assembly: invalid module identity/order")
    }
    CoreAssemblyRecorder { module_key: module_key, module_order: module_order,
        allocator: new_core_type_fact_allocator(module_key), refs: [],
        specs: [], frozen: false }
}
fn core_assembly_recorder_module_key(
    value: CoreAssemblyRecorder
) -> Str { value.module_key }
fn core_assembly_recorder_module_order(
    value: CoreAssemblyRecorder
) -> Int { value.module_order }
fn require_open(value: CoreAssemblyRecorder) {
    if value.frozen { panic("Core assembly: recorder is frozen") }
}
fn reserve_core_type_fact(
    mut recorder: CoreAssemblyRecorder
) -> CoreTypeFactRef {
    require_open(recorder)
    let reference = reserve_core_type_fact_ref(recorder.allocator)
    if core_type_fact_ordinal(reference) != recorder.refs.len() {
        panic("Core assembly: type fact allocator order drifted")
    }
    recorder.refs.push(reference); recorder.specs.push(none); reference
}
fn require_local(recorder: CoreAssemblyRecorder, value: CoreTypeFactRef) {
    if core_type_fact_module_key(value) != recorder.module_key ||
       core_type_fact_ordinal(value) < 0 ||
       core_type_fact_ordinal(value) >= recorder.refs.len() {
        panic("Core assembly: type fact belongs to another recorder")
    }
}
fn define_type(
    mut recorder: CoreAssemblyRecorder, reference: CoreTypeFactRef,
    spec: CoreTypeSpec
) {
    require_open(recorder); require_local(recorder, reference)
    let ordinal = core_type_fact_ordinal(reference)
    if recorder.specs.get(ordinal).unwrap().is_some() {
        panic("Core assembly: type fact defined twice")
    }
    recorder.specs.set(ordinal, some(spec))
}
fn define_core_atomic_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef, k: FlowTypeKind
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Atomic(k) }) }
fn define_core_parameter_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef, p: FlowGenericParamFact
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Parameter(p) }) }
fn define_core_nominal_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef, kind: FlowTypeKind,
    nominal: SymbolRef, arguments: List<CoreTypeFactRef>,
    fields: List<CoreNominalFieldSpec>, seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?,
    resource_storage_parameter_ordinals: List<Int>
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Nominal {
    kind: kind, nominal: nominal, arguments: arguments, fields: fields,
    seed: seed, drop_contract: drop_contract,
    resource_storage_parameter_ordinals:
        resource_storage_parameter_ordinals } }) }
fn define_core_extern_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef, nominal: SymbolRef,
    arguments: List<CoreTypeFactRef>
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Extern {
    nominal: nominal, arguments: arguments } }) }
fn define_core_tuple_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef,
    elements: List<CoreTypeFactRef>, seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Tuple {
    elements: elements, seed: seed, drop_contract: drop_contract } }) }
fn define_core_record_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef,
    fields: List<CoreNominalFieldSpec>, seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Record {
    fields: fields, seed: seed, drop_contract: drop_contract } }) }
fn define_core_callable_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef,
    parameters: List<CoreTypeFactRef>, result: CoreTypeFactRef,
    effects: CoreEffectContract
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Callable {
    parameters: parameters, result: result, effects: effects } }) }
fn define_core_ptr_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef, pointee: CoreTypeFactRef
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Ptr(pointee) }) }

fn local_flow_ref(value: CoreTypeFactRef, module_key: Str) -> CoreTypeRef {
    if core_type_fact_module_key(value) != module_key {
        panic("Core assembly: cross-module local type reference")
    }
    make_core_type_ref(core_type_fact_ordinal(value))
}
fn materialize_type(
    spec: CoreTypeSpec, reference: CoreTypeFactRef, module_key: Str
) -> FlowTypeNode {
    let target = local_flow_ref(reference, module_key)
    match spec.value {
        CoreTypeSpecValue::Atomic(kind) => {
            let tag = flow_type_kind_tag(kind)
            if tag == flow_type_kind_tag(flow_type_kind_int()) { make_flow_int_type_node(target) }
            else if tag == flow_type_kind_tag(flow_type_kind_float()) { make_flow_float_type_node(target) }
            else if tag == flow_type_kind_tag(flow_type_kind_str()) { make_flow_str_type_node(target) }
            else if tag == flow_type_kind_tag(flow_type_kind_bool()) { make_flow_bool_type_node(target) }
            else if tag == flow_type_kind_tag(flow_type_kind_unit()) { make_flow_unit_type_node(target) }
            else if tag == flow_type_kind_tag(flow_type_kind_never()) { make_flow_never_type_node(target) }
            else { panic("Core assembly: invalid atomic type kind") }
        },
        CoreTypeSpecValue::Parameter(parameter) =>
            make_flow_parameter_type_node(target, parameter),
        CoreTypeSpecValue::Nominal { kind, nominal, arguments, fields, seed,
            drop_contract, resource_storage_parameter_ordinals } => {
            let args = arguments.map(fn(v) { local_flow_ref(v, module_key) })
            let fs = fields.map(fn(f) { make_flow_nominal_field_fact(
                f.identity, local_flow_ref(f.ty, module_key)) })
            if flow_type_kind_tag(kind) == flow_type_kind_tag(flow_type_kind_struct()) {
                make_flow_struct_type_node(target, nominal, args, fs, seed,
                    drop_contract, resource_storage_parameter_ordinals)
            } else {
                make_flow_enum_type_node(target, nominal, args, fs, seed,
                    drop_contract, resource_storage_parameter_ordinals)
            }
        },
        CoreTypeSpecValue::Extern { nominal, arguments } =>
            make_flow_extern_type_node(target, nominal,
                arguments.map(fn(v) { local_flow_ref(v, module_key) })),
        CoreTypeSpecValue::Tuple { elements, seed, drop_contract } =>
            make_flow_tuple_type_node(
                target, elements.map(fn(v) { local_flow_ref(v, module_key) }),
                seed, drop_contract),
        CoreTypeSpecValue::Record { fields, seed, drop_contract } =>
            make_flow_record_type_node(
                target, fields.map(fn(f) { make_flow_record_field_fact(
                    f.identity,
                    match f.record_name {
                        some(name) => name,
                        none => panic("Core assembly: record field name is absent")
                    }, local_flow_ref(f.ty, module_key)) }), seed,
                drop_contract),
        CoreTypeSpecValue::Callable { parameters, result, effects } =>
            make_flow_callable_type_node(target,
                parameters.map(fn(v) { local_flow_ref(v, module_key) }),
                local_flow_ref(result, module_key), effects),
        CoreTypeSpecValue::Ptr(pointee) =>
            make_flow_ptr_type_node(target, local_flow_ref(pointee, module_key))
    }
}

struct ProducerRecordedType {
    ty: Type,
    fact: CoreTypeFactRef
}

struct ClosedCoreProducer {
    recorder: CoreAssemblyRecorder,
    env: TypeEnv,
    module_key: Str,
    recorded_types: List<ProducerRecordedType>,
    parameter_facts: Map<Int, FlowGenericParamFact>,
    type_sources: List<CoreTypeSourceFact>,
    handled_sources: List<CoreHandledEvidenceTypeSource>,
    effect_parameters: List<TypedEffectFormalFact>
}

fn new_closed_core_producer(
    module_key: Str, module_order: Int, env: TypeEnv,
    effect_parameters: List<TypedEffectFormalFact>
) -> ClosedCoreProducer {
    ClosedCoreProducer {
        recorder: new_core_assembly_recorder(module_key, module_order),
        env: env, module_key: module_key, recorded_types: [],
        parameter_facts: map_new(),
        type_sources: [], handled_sources: [],
        effect_parameters: effect_parameters.map(fn(fact) { fact })
    }
}

fn producer_symbol_lists_same(
    left: List<SymbolRef>, right: List<SymbolRef>
) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        if !symbol_ref_same(
                left.get(index).unwrap(), right.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}

fn producer_int_lists_same(left: List<Int>, right: List<Int>) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        if left.get(index).unwrap() != right.get(index).unwrap() {
            return false
        }
        index = index + 1
    }
    true
}

fn producer_optional_types_same(left: Type?, right: Type?) -> Bool {
    match (left, right) {
        (some(a), some(b)) => types_equal(a, b),
        (none, none) => true,
        _ => false
    }
}

fn producer_assoc_formals_same(
    left: List<AssocTypeDef>, right: List<AssocTypeDef>
) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        let a = left.get(index).unwrap()
        let b = right.get(index).unwrap()
        if a.var_id != b.var_id ||
           !symbol_ref_same(a.member_ref, b.member_ref) ||
           !producer_optional_types_same(a.default_type, b.default_type) {
            return false
        }
        index = index + 1
    }
    true
}

fn producer_assoc_contracts_same(
    left: List<RegisteredTraitAssocContract>,
    right: List<RegisteredTraitAssocContract>
) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        let a = left.get(index).unwrap()
        let b = right.get(index).unwrap()
        if !symbol_ref_same(
                registered_trait_assoc_member(a),
                registered_trait_assoc_member(b)) ||
           !types_equal(
                registered_trait_assoc_type(a),
                registered_trait_assoc_type(b)) ||
           !producer_optional_types_same(
                registered_trait_assoc_default(a),
                registered_trait_assoc_default(b)) ||
           !producer_symbol_lists_same(
                registered_trait_assoc_bounds(a),
                registered_trait_assoc_bounds(b)) {
            return false
        }
        index = index + 1
    }
    true
}

fn producer_trait_formals_same(left: TraitDef, right: TraitDef) -> Bool {
    symbol_ref_same(
        registered_trait_ref_symbol(
            registered_trait_contract_owner(left.contract)),
        registered_trait_ref_symbol(
            registered_trait_contract_owner(right.contract))) &&
    left.self_type_var_id == right.self_type_var_id &&
    producer_int_lists_same(left.type_param_vars, right.type_param_vars) &&
    producer_assoc_formals_same(left.assoc_types, right.assoc_types) &&
    producer_assoc_contracts_same(
        registered_trait_contract_assoc_items(left.contract),
        registered_trait_contract_assoc_items(right.contract)) &&
    producer_symbol_lists_same(
        registered_trait_contract_dict_obligations(left.contract),
        registered_trait_contract_dict_obligations(right.contract))
}

fn producer_trait_for_owner(
    producer: ClosedCoreProducer, owner: SymbolRef
) -> TraitDef {
    let mut found: TraitDef? = none
    for entry in producer.env.trait_reg.traits.entries() {
        let candidate = entry.1
        if symbol_ref_same(
                registered_trait_ref_symbol(candidate.owner_ref), owner) {
            match found {
                some(existing) => if !producer_trait_formals_same(
                        existing, candidate) {
                    panic("Core producer: trait owner has conflicting payloads")
                },
                none => { found = some(candidate) }
            }
        }
    }
    match found {
        some(value) => value,
        none => panic("Core producer: exact trait owner is absent")
    }
}

fn producer_append_unique_symbol(
    mut values: List<SymbolRef>, value: SymbolRef
) {
    if !values.any(fn(existing) { symbol_ref_same(existing, value) }) {
        values.push(value)
    }
}

fn producer_register_parameter(
    mut producer: ClosedCoreProducer, type_var_id: Int,
    owner: SymbolRef, index: Int, arity: Int, bounds: List<SymbolRef>
) {
    let fact = make_flow_generic_param_fact(owner, index, arity, bounds)
    match producer.parameter_facts.get(type_var_id) {
        some(existing) => if
                flow_generic_param_index(existing) != index ||
                flow_generic_param_arity(existing) != arity ||
                !symbol_ref_same(flow_generic_param_owner(existing), owner) ||
                !producer_symbol_lists_same(
                    flow_generic_param_bounds(existing), bounds) {
            panic("Core producer: type parameter identity changed")
        },
        none => producer.parameter_facts.insert(type_var_id, fact)
    }
}

fn producer_recorded_type(
    producer: ClosedCoreProducer, ty: Type
) -> CoreTypeFactRef? {
    for relation in producer.recorded_types {
        if types_equal(relation.ty, ty) { return some(relation.fact) }
    }
    none
}

fn producer_flow_type_ref(value: CoreTypeFactRef) -> CoreTypeRef {
    make_core_type_ref(core_type_fact_ordinal(value))
}

fn producer_resource_param_same(
    left: FlowGenericParamFact, right: FlowGenericParamFact
) -> Bool {
    symbol_ref_same(
        flow_generic_param_owner(left), flow_generic_param_owner(right)) &&
        flow_generic_param_index(left) == flow_generic_param_index(right) &&
        flow_generic_param_arity(left) == flow_generic_param_arity(right)
}

fn producer_nominal_parameters(
    owner: SymbolRef, arity: Int
) -> List<FlowGenericParamFact> {
    let mut result: List<FlowGenericParamFact> = []
    for index in 0..arity {
        result.push(make_flow_generic_param_fact(
            owner, index, arity, []))
    }
    result
}

fn producer_nominal_drop_contract(
    producer: ClosedCoreProducer, name: Str
) -> FlowDropContract? {
    match find_impl(producer.env.trait_reg, name, "Drop") {
        some(owner) => match owner.method_refs.get("drop") {
            some(method) => some(make_flow_drop_contract(
                make_named_executable_ref(impl_method_ref_member(method)))),
            none => panic("Core producer: Drop owner lacks method")
        },
        none => none
    }
}

fn producer_direct_composite_seed(
    drop_contract: FlowDropContract?
) -> FlowTypeSemanticSeed {
    if drop_contract.is_some() { return flow_type_seed_unique() }
    flow_type_seed_shareable()
}

fn producer_effect_parameter_from_facts(
    producer: ClosedCoreProducer, owner: OriginRef, raw_tail: Int
) -> EffectParamRef {
    let mut found: EffectParamRef? = none
    for fact in producer.effect_parameters {
        if typed_effect_formal_raw_tail(fact) == raw_tail {
            let parameter = typed_effect_formal_parameter(fact)
            if !origin_ref_same(effect_param_owner(parameter), owner) {
                panic("Core producer: typed effect formal owner differs")
            }
            if found.is_some() {
                panic("Core producer: typed effect formal repeats")
            }
            found = some(parameter)
        }
    }
    match found {
        some(parameter) => parameter,
        none => panic("Core producer: effect tail lacks TypedHIR formal")
    }
}

fn producer_record_effect_contract(
    mut producer: ClosedCoreProducer, row: EffectRow,
    owner: OriginRef?
) -> CoreEffectContract {
    let mut atoms: List<CoreEffectAtom> = []
    for item in row.effects {
        match item {
            Effect::FailEffect { error_type } => atoms.push(
                make_core_fail_effect(producer_flow_type_ref(
                    producer_record_type(producer, error_type, owner)))),
            Effect::MutEffect { state_type } => atoms.push(
                make_core_mut_effect(producer_flow_type_ref(
                    producer_record_type(producer, state_type, owner)))),
            Effect::UnsafeEffect => atoms.push(make_core_unsafe_effect()),
            Effect::CustomEffect { reference, type_args, .. } => {
                atoms.push(make_core_handled_effect(
                    reference, type_args.map(fn(ty) {
                        producer_flow_type_ref(
                            producer_record_type(producer, ty, owner))
                    })))
                producer_ensure_handled_source(producer, reference)
            },
            Effect::SystemEffect { reference } =>
                atoms.push(make_core_system_effect(reference))
        }
    }
    let parameter = row.tail.map(fn(raw_tail) {
        producer_effect_parameter_from_facts(
            producer, match owner {
                some(value) => value,
                none => panic("Core producer: unowned effect tail")
            }, raw_tail)
    })
    make_core_effect_contract(make_core_effect_set(atoms), parameter)
}

fn producer_record_type(
    mut producer: ClosedCoreProducer, ty: Type,
    effect_owner: OriginRef?
) -> CoreTypeFactRef {
    match producer_recorded_type(producer, ty) {
        some(fact) => return fact, none => {}
    }
    let fact = reserve_core_type_fact(producer.recorder)
    producer.recorded_types.push(ProducerRecordedType { ty: ty, fact: fact })
    producer.type_sources.push(make_core_type_source_fact(ty, fact))
    match ty {
        Type::IntType => define_core_atomic_type_fact(
            producer.recorder, fact, flow_type_kind_int()),
        Type::FloatType => define_core_atomic_type_fact(
            producer.recorder, fact, flow_type_kind_float()),
        Type::StrType => define_core_atomic_type_fact(
            producer.recorder, fact, flow_type_kind_str()),
        Type::BoolType => define_core_atomic_type_fact(
            producer.recorder, fact, flow_type_kind_bool()),
        Type::UnitType => define_core_atomic_type_fact(
            producer.recorder, fact, flow_type_kind_unit()),
        Type::NeverType => define_core_atomic_type_fact(
            producer.recorder, fact, flow_type_kind_never()),
        Type::TypeVar { id, .. } => match producer.parameter_facts.get(id) {
            some(parameter) => define_core_parameter_type_fact(
                producer.recorder, fact, parameter),
            none => panic(
                "Core producer: unresolved type parameter ${id.to_str()} in module ${producer.module_key}")
        },
        Type::FnType { params, return_type, effects } => {
            let mut parameter_facts: List<CoreTypeFactRef> = []
            for parameter in params {
                parameter_facts.push(producer_record_type(
                    producer, parameter, effect_owner))
            }
            let result = producer_record_type(
                producer, return_type, effect_owner)
            let effect_contract = producer_record_effect_contract(
                producer, effects, effect_owner)
            define_core_callable_type_fact(
                producer.recorder, fact, parameter_facts, result,
                effect_contract)
        },
        Type::StructType { name, type_params } => {
            let def = producer.env.types.structs.get(name).unwrap_or_else(fn() {
                panic("Core producer: struct registry owner is absent")
            })
            let nominal = registered_nominal_ref_symbol(def.owner_ref)
            if def.type_param_vars.len() != type_params.len() {
                panic("Core producer: struct application arity differs")
            }
            let mut arguments: List<CoreTypeFactRef> = []
            let mut type_map: Map<Int, Type> = map_new()
            let mut index = 0
            for argument in type_params {
                arguments.push(producer_record_type(
                    producer, argument, effect_owner))
                match def.type_param_vars.get(index) {
                    some(id) => type_map.insert(id, argument), none => {}
                }
                index = index + 1
            }
            if def.is_extern {
                define_core_extern_type_fact(
                    producer.recorder, fact,
                    nominal, arguments)
            } else {
                let mut fields: List<CoreNominalFieldSpec> = []
                for field in def.fields {
                    let field_type = apply_subst_map(type_map, field.ty)
                    let field_fact = producer_record_type(
                        producer, field_type, some(make_symbol_origin_ref(
                            nominal_field_ref_member(field.field_ref))))
                    fields.push(make_core_nominal_field_spec(
                        make_nominal_flow_field_identity(field.field_ref),
                        field_fact))
                }
                let drop_contract = producer_nominal_drop_contract(producer, name)
                define_core_nominal_type_fact(
                    producer.recorder, fact, flow_type_kind_struct(),
                    nominal, arguments,
                    fields, producer_direct_composite_seed(drop_contract),
                    drop_contract,
                    def.resource_storage_parameter_ordinals)
            }
        },
        Type::EnumType { name, type_params } => {
            let def = producer.env.types.enums.get(name).unwrap_or_else(fn() {
                panic("Core producer: enum registry owner is absent")
            })
            let nominal = registered_nominal_ref_symbol(def.owner_ref)
            if def.type_param_vars.len() != type_params.len() {
                panic("Core producer: enum application arity differs")
            }
            let mut arguments: List<CoreTypeFactRef> = []
            let mut type_map: Map<Int, Type> = map_new()
            let mut index = 0
            for argument in type_params {
                arguments.push(producer_record_type(
                    producer, argument, effect_owner))
                match def.type_param_vars.get(index) {
                    some(id) => type_map.insert(id, argument), none => {}
                }
                index = index + 1
            }
            let mut fields: List<CoreNominalFieldSpec> = []
            let mut variant_index = 0
            for variant in def.variants {
                let field_refs = def.variant_field_refs.get(variant_index).unwrap()
                let mut field_index = 0
                for field_ty in variant.fields {
                    let resolved = apply_subst_map(type_map, field_ty)
                    let field_fact = producer_record_type(
                        producer, resolved, some(make_symbol_origin_ref(
                            variant_field_ref_member(
                                field_refs.get(field_index).unwrap()))))
                    fields.push(make_core_nominal_field_spec(
                        make_variant_flow_field_identity(
                            field_refs.get(field_index).unwrap()), field_fact))
                    field_index = field_index + 1
                }
                variant_index = variant_index + 1
            }
            let drop_contract = producer_nominal_drop_contract(producer, name)
            define_core_nominal_type_fact(
                producer.recorder, fact, flow_type_kind_enum(),
                nominal, arguments,
                fields, producer_direct_composite_seed(drop_contract),
                drop_contract, [])
        },
        Type::TupleType { elements } => {
            let mut element_facts: List<CoreTypeFactRef> = []
            for element in elements {
                element_facts.push(producer_record_type(
                    producer, element, effect_owner))
            }
            define_core_tuple_type_fact(
                producer.recorder, fact, element_facts,
                flow_type_seed_shareable(), none)
        },
        Type::RecordType { fields, tail, .. } => {
            let owner = path_owner_for_module_body(make_module_body_ref(
                producer.module_key, "module-body"))
            let mut field_specs: List<CoreNominalFieldSpec> = []
            let mut index = 0
            for field in fields {
                let field_fact = producer_record_type(
                    producer, field.ty, effect_owner)
                field_specs.push(make_core_record_field_spec(
                    field.name,
                    make_path_flow_field_identity(make_path_ref(
                        owner, ["record:${core_type_fact_ordinal(fact)}",
                                "field:${index}:${field.name}"],
                        path_role_synthetic())),
                    field_fact))
                index = index + 1
            }
            define_core_record_type_fact(
                producer.recorder, fact, field_specs,
                // An open record is a required-fields logical contract, not
                // its caller's complete physical shape.  Conservatively make
                // owning use single-transfer so a hidden unique field can
                // never be RC-cloned inside the callee.
                if tail.is_some() { flow_type_seed_unique() }
                else { flow_type_seed_shareable() }, none)
        },
        Type::PtrType { pointee } => define_core_ptr_type_fact(
            producer.recorder, fact,
            producer_record_type(producer, pointee, effect_owner)),
        Type::AnyType | Type::GenericType { .. } |
        Type::EffectRowType { .. } | Type::ErrorType =>
            panic("Core producer: non-canonical type crossed closure")
    }
    fact
}

fn producer_ensure_handled_source(
    mut producer: ClosedCoreProducer, requirement: HandledEffectRef
) {
    for existing in producer.handled_sources {
        if handled_effect_ref_same(
                core_handled_evidence_source_requirement(existing),
                requirement) { return }
    }
    let mut found = none
    for entry in producer.env.types.effects.entries() {
        let def = entry.1
        match def.handled_ref {
            some(reference) => if handled_effect_ref_same(
                    reference, requirement) {
                if found.is_some() {
                    panic("Core producer: handled effect owner repeats")
                }
                found = some(def)
            },
            none => {}
        }
    }
    let def = match found {
        some(value) => value,
        none => panic("Core producer: handled effect owner is absent")
    }
    let aggregate = reserve_core_type_fact(producer.recorder)
    let effect_symbol = handled_effect_ref_symbol(requirement)
    let mut operations: List<CoreHandledEvidenceOperationTypeSource> = []
    let mut fields: List<CoreNominalFieldSpec> = []
    let mut index = 0
    for op in def.ops {
        let operation = match op.operation_ref {
            some(value) => value,
            none => panic("Core producer: handled operation lacks identity")
        }
        let signature = producer_record_type(producer, Type::FnType {
            params: op.params, return_type: op.return_type, effects: EMPTY_ROW
        }, some(executable_origin(effect_operation_ref_callable(operation))))
        operations.push(make_core_handled_evidence_operation_type_source(
            operation, signature))
        fields.push(make_core_record_field_spec(
            "handled-evidence-op:${index}",
            make_path_flow_field_identity(make_path_ref(
                path_owner_for_symbol(effect_symbol),
                ["handled-evidence-op:${index}"], path_role_child())),
            signature))
        index = index + 1
    }
    define_core_record_type_fact(
        producer.recorder, aggregate, fields,
        flow_type_seed_shareable(), none)
    producer.handled_sources.push(make_core_handled_evidence_type_source(
        requirement, aggregate, operations))
}

fn producer_register_h_type_params(
    mut producer: ClosedCoreProducer, owner: SymbolRef,
    values: List<HTypeParam>
) {
    let mut index = 0
    for value in values {
        producer_register_parameter(
            producer, value.type_var_id, owner, index, values.len(),
            value.bound_refs)
        index = index + 1
    }
}

fn producer_nominal_definition_raw_parameters(
    producer: ClosedCoreProducer, owner: SymbolRef, is_struct: Bool
) -> List<Int> {
    let mut found: List<Int>? = none
    if is_struct {
        for entry in producer.env.types.structs.entries() {
            if symbol_ref_same(
                    registered_nominal_ref_symbol(entry.1.owner_ref), owner) {
                match found {
                    some(existing) => if !producer_int_lists_same(
                            existing, entry.1.type_param_vars) {
                        panic("Core producer: local struct formal aliases differ")
                    },
                    none => { found = some(entry.1.type_param_vars) }
                }
            }
        }
    } else {
        for entry in producer.env.types.enums.entries() {
            if symbol_ref_same(
                    registered_nominal_ref_symbol(entry.1.owner_ref), owner) {
                match found {
                    some(existing) => if !producer_int_lists_same(
                            existing, entry.1.type_param_vars) {
                        panic("Core producer: local enum formal aliases differ")
                    },
                    none => { found = some(entry.1.type_param_vars) }
                }
            }
        }
    }
    match found {
        some(values) => values,
        none => panic("Core producer: local nominal definition is absent")
    }
}

fn producer_register_nominal_decl_parameters(
    mut producer: ClosedCoreProducer, owner: SymbolRef,
    source: List<HTypeParam>, is_struct: Bool
) {
    producer_register_h_type_params(producer, owner, source)
    let raw_formals = producer_nominal_definition_raw_parameters(
        producer, owner, is_struct)
    if raw_formals.len() != source.len() {
        panic("Core producer: local nominal formal arity differs")
    }
    let exact = producer_nominal_parameters(owner, raw_formals.len())
    let mut index = 0
    while index < raw_formals.len() {
        let raw_formal = raw_formals.get(index).unwrap()
        let parameter = exact.get(index).unwrap()
        match producer.parameter_facts.get(raw_formal) {
            some(existing) => if !producer_resource_param_same(
                    existing, parameter) {
                panic("Core producer: local nominal formal identity differs")
            },
            none => producer_register_parameter(
                producer, raw_formal, owner, index,
                raw_formals.len(), [])
        }
        index = index + 1
    }
}

fn producer_register_trait_parameters(
    mut producer: ClosedCoreProducer, owner: SymbolRef,
    source: List<HTypeParam>, assoc_values: List<HAssocType>
) {
    let def = producer_trait_for_owner(producer, owner)
    if !symbol_ref_same(
            registered_trait_ref_symbol(def.owner_ref), owner) ||
       !symbol_ref_same(
            registered_trait_ref_symbol(
                registered_trait_contract_owner(def.contract)), owner) ||
       def.type_params.len() != source.len() ||
       def.type_param_vars.len() != source.len() ||
       def.assoc_types.len() != assoc_values.len() {
        panic("Core producer: trait formal census differs")
    }
    let contract_assoc = registered_trait_contract_assoc_items(def.contract)
    if contract_assoc.len() != assoc_values.len() {
        panic("Core producer: trait assoc contract census differs")
    }
    let total_arity = source.len() + 1 + assoc_values.len()
    let mut index = 0
    while index < source.len() {
        let value = source.get(index).unwrap()
        if value.type_var_id != def.type_param_vars.get(index).unwrap() {
            panic("Core producer: trait source parameter order differs")
        }
        producer_register_parameter(
            producer, value.type_var_id, owner,
            index, total_arity, value.bound_refs)
        index = index + 1
    }

    if def.self_type_var_id < 0 {
        panic("Core producer: trait Self parameter is invalid")
    }
    let mut self_bounds: List<SymbolRef> = []
    producer_append_unique_symbol(self_bounds, owner)
    for obligation in registered_trait_contract_dict_obligations(def.contract) {
        producer_append_unique_symbol(self_bounds, obligation)
    }
    producer_register_parameter(
        producer, def.self_type_var_id, owner,
        source.len(), total_arity, self_bounds)

    let mut assoc_index = 0
    while assoc_index < assoc_values.len() {
        let hir_assoc = assoc_values.get(assoc_index).unwrap()
        let def_assoc = def.assoc_types.get(assoc_index).unwrap()
        let exact_assoc = contract_assoc.get(assoc_index).unwrap()
        let contract_type_var_id = match registered_trait_assoc_type(exact_assoc) {
            Type::TypeVar { id, .. } => id,
            _ => panic("Core producer: trait assoc contract is not abstract")
        }
        if def_assoc.var_id < 0 || def_assoc.var_id != contract_type_var_id ||
           !symbol_ref_same(hir_assoc.member_ref, def_assoc.member_ref) ||
           !symbol_ref_same(
                def_assoc.member_ref,
                registered_trait_assoc_member(exact_assoc)) ||
           !producer_optional_types_same(
                hir_assoc.concrete, def_assoc.default_type) ||
           !producer_optional_types_same(
                def_assoc.default_type,
                registered_trait_assoc_default(exact_assoc)) {
            panic("Core producer: trait assoc formal differs")
        }
        producer_register_parameter(
            producer, def_assoc.var_id, owner,
            source.len() + 1 + assoc_index, total_arity,
            registered_trait_assoc_bounds(exact_assoc))
        assoc_index = assoc_index + 1
    }
}

fn producer_register_decl_parameters(
    mut producer: ClosedCoreProducer, decls: List<HDecl>
) {
    for decl in decls {
        match decl {
            HDecl::Fn { executable_ref, type_params, .. } |
            HDecl::ExternFn { executable_ref, type_params, .. } => {
                if !executable_ref_is_named(executable_ref) {
                    panic("Core producer: named declaration has anonymous owner")
                }
                producer_register_h_type_params(
                    producer, executable_ref_named_symbol(executable_ref),
                    type_params)
            },
            HDecl::Struct { owner_ref, type_params, .. } =>
                producer_register_nominal_decl_parameters(
                    producer, registered_nominal_ref_symbol(owner_ref),
                    type_params, true),
            HDecl::Enum { owner_ref, type_params, .. } =>
                producer_register_nominal_decl_parameters(
                    producer, registered_nominal_ref_symbol(owner_ref),
                    type_params, false),
            HDecl::Effect { owner_ref, type_params, .. } => match owner_ref {
                some(owner) => producer_register_h_type_params(
                    producer, owner, type_params),
                none => if type_params.len() != 0 {
                    panic("Core producer: builtin effect has type parameters")
                }
            },
            HDecl::Trait {
                owner_ref, type_params, methods, assoc_types, ..
            } => {
                producer_register_trait_parameters(
                    producer, registered_trait_ref_symbol(owner_ref),
                    type_params, assoc_types)
                for method in methods {
                    if !executable_ref_is_named(method.executable_ref) {
                        panic("Core producer: trait method owner is anonymous")
                    }
                }
            },
            HDecl::Impl { owner_ref, type_params, methods, .. } => {
                producer_register_h_type_params(
                    producer, impl_owner_ref_target(owner_ref), type_params)
                producer_register_decl_parameters(producer, methods)
            },
            HDecl::ModBlock { decls: nested, .. } =>
                producer_register_decl_parameters(producer, nested),
            _ => {}
        }
    }
}

fn producer_register_environment_effect_parameters(
    mut producer: ClosedCoreProducer
) {
    for entry in producer.env.types.effects.entries() {
        let def = entry.1
        match def.owner_ref {
            some(owner) => {
                let mut index = 0
                while index < def.type_param_vars.len() {
                    let id = def.type_param_vars.get(index).unwrap()
                    if !producer.parameter_facts.contains_key(id) {
                        producer_register_parameter(
                            producer, id, owner, index,
                            def.type_param_vars.len(), [])
                    }
                    index = index + 1
                }
            },
            none => {}
        }
    }
}

fn producer_record_row(
    mut producer: ClosedCoreProducer, owner: ExecutableRef,
    row: EffectRow
) {
    let _ = producer_record_effect_contract(
        producer, row, some(executable_origin(owner)))
}

fn producer_record_param(
    mut producer: ClosedCoreProducer, owner: ExecutableRef, param: HParam
) {
    let _ = producer_record_type(
        producer, param.ty, some(executable_origin(owner)))
}

fn producer_record_match_arm(
    mut producer: ClosedCoreProducer, owner: ExecutableRef, arm: HMatchArm
) {
    for binding in arm.bindings {
        let _ = producer_record_type(
            producer, binding.ty, some(executable_origin(owner)))
    }
    match arm.guard {
        some(guard) => producer_record_expr(producer, owner, guard), none => {}
    }
    producer_record_expr(producer, owner, arm.body)
}

fn producer_record_handler(
    mut producer: ClosedCoreProducer, handler: HEffectHandler
) {
    for param in handler.params {
        producer_record_param(producer, handler.executable_ref, param)
    }
    match handler.resume_binding {
        some(binding) => {
            let _ = producer_record_type(
                producer, binding.ty,
                some(executable_origin(handler.executable_ref)))
        },
        none => {}
    }
    for capture in handler.captures {
        match capture.value {
            some(value) => producer_record_expr(
                producer, handler.executable_ref, value),
            none => {}
        }
    }
    producer_record_expr(producer, handler.executable_ref, handler.body)
}

fn producer_record_stmt(
    mut producer: ClosedCoreProducer, owner: ExecutableRef, stmt: HStmt
) {
    match stmt {
        HStmt::Let { ty, init, .. } | HStmt::Var { ty, init, .. } => {
            let _ = producer_record_type(
                producer, ty, some(executable_origin(owner)))
            producer_record_expr(producer, owner, init)
        },
        HStmt::Assign { target, value, .. } => {
            producer_record_expr(producer, owner, target)
            producer_record_expr(producer, owner, value)
        },
        HStmt::ExprStmt { expr, .. } =>
            producer_record_expr(producer, owner, expr),
        HStmt::Return { value, .. } => match value {
            some(expr) => producer_record_expr(producer, owner, expr), none => {}
        },
        HStmt::While { condition, body, .. } => {
            producer_record_expr(producer, owner, condition)
            producer_record_expr(producer, owner, body)
        },
        HStmt::ForIn { iterable, body, .. } => {
            producer_record_expr(producer, owner, iterable)
            producer_record_expr(producer, owner, body)
        },
        HStmt::LetDestructure { bindings, init, .. } => {
            for binding in bindings {
                let _ = producer_record_type(
                    producer, binding.ty, some(executable_origin(owner)))
            }
            producer_record_expr(producer, owner, init)
        },
        HStmt::IfLet { bindings, expr, then_block, else_block, .. } => {
            for binding in bindings {
                let _ = producer_record_type(
                    producer, binding.ty, some(executable_origin(owner)))
            }
            producer_record_expr(producer, owner, expr)
            producer_record_expr(producer, owner, then_block)
            match else_block {
                some(value) => producer_record_expr(producer, owner, value),
                none => {}
            }
        },
        HStmt::Drop { ty, place_target, .. } => {
            let _ = producer_record_type(
                producer, ty, some(executable_origin(owner)))
            match place_target {
                some(value) => producer_record_expr(producer, owner, value),
                none => {}
            }
        },
        HStmt::Break { .. } | HStmt::Continue { .. } => {}
    }
}

fn producer_record_dictionary(
    mut producer: ClosedCoreProducer, owner: ExecutableRef,
    value: ExactDictRef
) {
    if dict_ref_is_local(value) {
        let _ = producer_record_type(
            producer, Type::TupleType { elements: [] },
            some(executable_origin(owner)))
    } else if !dict_ref_is_static(value) {
        for inner in dict_ref_wrapped_inner(value) {
            producer_record_dictionary(producer, owner, inner)
        }
    }
}

fn producer_record_physical_dictionary(
    mut producer: ClosedCoreProducer, owner: ExecutableRef, value: DictRef
) {
    producer_record_dictionary(producer, owner, dict_ref_exact(value))
}

fn producer_record_method_dictionary(
    mut producer: ClosedCoreProducer, owner: ExecutableRef,
    value: MethodCallRef
) {
    if method_call_ref_is_bound(value) {
        producer_record_physical_dictionary(
            producer, owner, method_call_ref_bound_evidence(value))
    }
}

fn producer_record_operator_dictionaries(
    mut producer: ClosedCoreProducer, owner: ExecutableRef,
    value: HOperatorPlan
) {
    if h_operator_is_tuple(value) {
        for child in h_operator_elements(value) {
            producer_record_operator_dictionaries(producer, owner, child)
        }
    } else {
        producer_record_method_dictionary(
            producer, owner, h_operator_method_ref(value))
    }
}

fn producer_record_expr(
    mut producer: ClosedCoreProducer, owner: ExecutableRef, expr: HExpr
) {
    let type_owner = match expr {
        HExpr::Lambda { executable_ref, .. } => executable_origin(executable_ref),
        HExpr::FieldAccess { projection: some(projection), .. } => {
            let kind = h_projection_kind(projection)
            if kind == 0 {
                make_symbol_origin_ref(nominal_field_ref_member(
                    h_projection_nominal(projection)))
            } else if kind == 1 {
                make_symbol_origin_ref(variant_field_ref_member(
                    h_projection_variant(projection)))
            } else { executable_origin(owner) }
        },
        _ => executable_origin(owner)
    }
    let _ = producer_record_type(
        producer, hexpr_type(expr), some(type_owner))
    producer_record_row(producer, owner, hexpr_effects(expr))
    match expr {
        HExpr::IntLit { .. } | HExpr::FloatLit { .. } |
        HExpr::StrLit { .. } | HExpr::BoolLit { .. } => {},
        HExpr::Ident { dict_closure_dicts, .. } => match dict_closure_dicts {
            some(values) => {
                for value in values {
                    producer_record_physical_dictionary(producer, owner, value)
                }
            },
            none => {}
        },
        HExpr::BinOp { left, right, eq_plan, ord_plan, .. } => {
            producer_record_expr(producer, owner, left)
            producer_record_expr(producer, owner, right)
            match eq_plan {
                some(plan) => producer_record_operator_dictionaries(
                    producer, owner, plan), none => {}
            }
            match ord_plan {
                some(plan) => producer_record_operator_dictionaries(
                    producer, owner, plan), none => {}
            }
        },
        HExpr::UnaryOp { operand, .. } | HExpr::Clone { inner: operand, .. } =>
            producer_record_expr(producer, owner, operand),
        HExpr::Call {
            callee, args, type_args, resolved_dicts, method_ref, ..
        } => {
            producer_record_expr(producer, owner, callee)
            for argument in args { producer_record_expr(producer, owner, argument) }
            for ty in type_args {
                let _ = producer_record_type(
                    producer, ty, some(executable_origin(owner)))
            }
            for value in resolved_dicts {
                producer_record_physical_dictionary(producer, owner, value)
            }
            match method_ref {
                some(method) => producer_record_method_dictionary(
                    producer, owner, method), none => {}
            }
        },
        HExpr::FieldAccess { receiver, .. } =>
            producer_record_expr(producer, owner, receiver),
        HExpr::StructLit { type_args, fields, spread, .. } => {
            for ty in type_args {
                let _ = producer_record_type(
                    producer, ty, some(executable_origin(owner)))
            }
            for field in fields {
                producer_record_expr(producer, owner, field.value)
            }
            match spread {
                some(value) => producer_record_expr(producer, owner, value),
                none => {}
            }
        },
        HExpr::NamedVariantConstruct { fields, spread, .. } => {
            for field in fields {
                producer_record_expr(producer, owner, field.value)
            }
            match spread {
                some(value) => producer_record_expr(producer, owner, value),
                none => {}
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            producer_record_expr(producer, owner, scrutinee)
            for arm in arms { producer_record_match_arm(producer, owner, arm) }
        },
        HExpr::Block { stmts, tail, .. } => {
            for stmt in stmts { producer_record_stmt(producer, owner, stmt) }
            match tail {
                some(value) => producer_record_expr(producer, owner, value),
                none => {}
            }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            producer_record_expr(producer, owner, condition)
            producer_record_expr(producer, owner, then_branch)
            match else_branch {
                some(value) => producer_record_expr(producer, owner, value),
                none => {}
            }
        },
        HExpr::StringInterp { parts, .. } => {
            for part in parts {
                match part {
                    HStringInterpPart::Expression(value) =>
                        producer_record_expr(producer, owner, value),
                    _ => {}
                }
            }
        },
        HExpr::TryCatch { body, arms, .. } => {
            producer_record_expr(producer, owner, body)
            for arm in arms { producer_record_match_arm(producer, owner, arm) }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            producer_record_expr(producer, owner, body)
            for handler in handlers { producer_record_handler(producer, handler) }
        },
        HExpr::Lambda { executable_ref, params, return_type, body,
                        captures, .. } => {
            for param in params {
                producer_record_param(producer, executable_ref, param)
            }
            let _ = producer_record_type(
                producer, return_type, some(executable_origin(executable_ref)))
            for capture in captures {
                match capture.value {
                    some(value) => producer_record_expr(
                        producer, executable_ref, value),
                    none => {}
                }
            }
            producer_record_expr(producer, executable_ref, body)
        },
        HExpr::EffectOp { args, .. } => {
            for argument in args {
                producer_record_expr(producer, owner, argument)
            }
        },
        HExpr::ListLit { elements, .. } | HExpr::TupleLit { elements, .. } => {
            for element in elements {
                producer_record_expr(producer, owner, element)
            }
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            producer_record_expr(producer, owner, receiver)
            producer_record_expr(producer, owner, index)
        },
        HExpr::DictConstruct { .. } => {},
        HExpr::Take { source, .. } =>
            producer_record_expr(producer, owner, source),
        HExpr::ReturnExpr { value, .. } => match value {
            some(result) => producer_record_expr(producer, owner, result),
            none => {}
        },
        HExpr::UnsafeBlock { body, .. } =>
            producer_record_expr(producer, owner, body)
    }
}

fn producer_record_callable(
    mut producer: ClosedCoreProducer, owner: ExecutableRef,
    params: List<HParam>, result: Type, effects: EffectRow,
    body: HExpr?
) {
    let signature = Type::FnType {
        params: params.map(fn(param) { param.ty }),
        return_type: result, effects: effects
    }
    let _ = producer_record_type(
        producer, signature, some(executable_origin(owner)))
    for param in params { producer_record_param(producer, owner, param) }
    producer_record_row(producer, owner, effects)
    match body {
        some(value) => producer_record_expr(producer, owner, value), none => {}
    }
}

fn producer_record_decls(
    mut producer: ClosedCoreProducer, decls: List<HDecl>
) {
    for decl in decls {
        match decl {
            HDecl::Fn { executable_ref, params, return_type, effects,
                        body, .. } => producer_record_callable(
                producer, executable_ref, params, return_type, effects,
                some(body)),
            HDecl::Struct { fields, .. } => {
                for field in fields {
                    let _ = producer_record_type(
                        producer, field.ty, some(make_symbol_origin_ref(
                            nominal_field_ref_member(field.field_ref))))
                }
            },
            HDecl::Enum { variants, .. } => {
                for variant in variants {
                    if variant.fields.len() != variant.field_refs.len() {
                        panic("Core producer: enum field identity census differs")
                    }
                    let mut field_index = 0
                    while field_index < variant.fields.len() {
                        let _ = producer_record_type(
                            producer,
                            variant.fields.get(field_index).unwrap(),
                            some(make_symbol_origin_ref(
                                variant_field_ref_member(
                                    variant.field_refs.get(
                                        field_index).unwrap()))))
                        field_index = field_index + 1
                    }
                }
            },
            HDecl::Impl { target_ty, owner_ref, methods, assoc_types,
                          default_specializations, delegate_plan, .. } => {
                let provider_origin = make_path_origin_ref(
                    impl_provider_ref_site(impl_owner_ref_provider(owner_ref)))
                let _ = producer_record_type(
                    producer, target_ty, some(provider_origin))
                for assoc in assoc_types {
                    match assoc.concrete {
                        some(ty) => { let _ = producer_record_type(
                            producer, ty, some(make_symbol_origin_ref(
                                assoc.member_ref))) },
                        none => {}
                    }
                }
                producer_record_decls(producer, methods)
                for plan in default_specializations {
                    let owner = h_default_specialization_generated_executable(plan)
                    let params = h_default_specialization_parameter_types(plan)
                    let result = h_default_specialization_result_type(plan)
                    let effects = h_default_specialization_effects(plan)
                    let _ = producer_record_type(producer, Type::FnType {
                        params: params, return_type: result, effects: effects
                    }, some(executable_origin(owner)))
                }
                match delegate_plan {
                    some(plan) => {
                        for method in h_delegate_methods(plan) {
                            let owner = h_delegate_method_executable(method)
                            let params = h_delegate_method_parameter_types(method)
                            let result = h_delegate_method_result_type(method)
                            let effects = h_delegate_method_effects(method)
                            let _ = producer_record_type(producer, Type::FnType {
                                params: params, return_type: result,
                                effects: effects
                            }, some(executable_origin(owner)))
                        }
                    },
                    none => {}
                }
            },
            HDecl::Effect { handled_ref, type_params, ops, .. } => {
                let effect_type_args = type_params.map(fn(parameter) {
                    Type::TypeVar {
                        id: parameter.type_var_id,
                        name: some(parameter.source.name)
                    }
                })
                match handled_ref {
                    some(reference) => producer_ensure_handled_source(
                        producer, reference), none => {}
                }
                for op in ops {
                    match op.operation_ref {
                        some(operation) => producer_record_callable(
                            producer, effect_operation_ref_callable(operation),
                            op.params, op.return_type,
                            EffectRow { effects: [Effect::CustomEffect {
                                reference: effect_operation_ref_effect(operation),
                                name: op.name, type_args: effect_type_args
                            }], tail: none }, none),
                        none => panic("Core producer: effect op identity is absent")
                    }
                }
            },
            HDecl::Test { executable_ref, body, .. } =>
                producer_record_callable(
                    producer, executable_ref, [], hexpr_type(body),
                    hexpr_effects(body), some(body)),
            HDecl::Trait { methods, .. } => {
                for method in methods {
                    producer_record_callable(
                        producer, method.executable_ref, method.params,
                        method.return_type, method.effects, method.body)
                }
            },
            HDecl::ExternFn { executable_ref, params, return_type, effects,
                              .. } => producer_record_callable(
                producer, executable_ref, params, return_type, effects, none),
            // Type aliases are fully expanded by type checking. The declaration
            // has no executable, Core type identity, or reachable fact of its
            // own; only expanded use-site Types enter this census.
            HDecl::TypeAlias { .. } => {},
            HDecl::Const { executable_ref, ty, init, .. } => {
                let _ = producer_record_type(
                    producer, ty, some(executable_origin(executable_ref)))
                producer_record_callable(
                    producer, executable_ref, [], ty, hexpr_effects(init),
                    some(init))
            },
            HDecl::ModBlock { decls: nested, .. } =>
                producer_record_decls(producer, nested),
            HDecl::ExternType { .. } => {}
        }
    }
}

fn producer_record_derived(
    mut producer: ClosedCoreProducer, values: List<DerivedImpl>
) {
    for derived in values {
        let parameter_owner = impl_owner_ref_target(derived.owner_ref)
        if !symbol_ref_same(
                parameter_owner,
                registered_nominal_ref_symbol(derived.target_owner)) {
            panic("Core producer: derived parameter owner differs from target")
        }
        producer_register_h_type_params(
            producer, parameter_owner, derived.type_params)
        let derived_origin = make_path_origin_ref(impl_provider_ref_site(
            impl_owner_ref_provider(derived.owner_ref)))
        let _ = producer_record_type(
            producer, derived.target_type, some(derived_origin))
        match derived.struct_fields {
            some(fields) => {
                for field in fields {
                    let field_origin = match field.field_ref {
                        DerivedFieldRef::NominalDerivedField(reference) =>
                            make_symbol_origin_ref(
                                nominal_field_ref_member(reference)),
                        DerivedFieldRef::VariantDerivedField(reference) =>
                            make_symbol_origin_ref(
                                variant_field_ref_member(reference))
                    }
                    let _ = producer_record_type(
                        producer, field.ty, some(field_origin))
                }
            },
            none => {}
        }
        match derived.enum_variants {
            some(variants) => {
                for variant in variants {
                    for field in variant.fields {
                        let field_origin = match field.field_ref {
                            DerivedFieldRef::NominalDerivedField(reference) =>
                                make_symbol_origin_ref(
                                    nominal_field_ref_member(reference)),
                            DerivedFieldRef::VariantDerivedField(reference) =>
                                make_symbol_origin_ref(
                                    variant_field_ref_member(reference))
                        }
                        let _ = producer_record_type(
                            producer, field.ty, some(field_origin))
                    }
                }
            },
            none => {}
        }
        for method in derived.methods {
            let _ = producer_record_type(
                producer, method.signature,
                some(executable_origin(method.executable_ref)))
        }
    }
}

fn producer_record_builtin_methods(mut producer: ClosedCoreProducer) {
    if core_assembly_recorder_module_order(producer.recorder) != 0 { return }
    for fact in builtin_method_contract_facts(producer.env) {
        let scheme = builtin_method_contract_scheme(fact)
        let intrinsic_symbol = intrinsic_ref_symbol(
            builtin_method_contract_intrinsic(fact))
        let target_vars = builtin_method_contract_target_type_vars(fact)
        for index in 0..target_vars.len() {
            producer_register_parameter(
                producer, target_vars.get(index).unwrap(),
                builtin_method_contract_target_owner(fact),
                index, target_vars.len(), [])
        }
        let method_vars = builtin_method_contract_method_type_vars(fact)
        for index in 0..method_vars.len() {
            producer_register_parameter(
                producer, method_vars.get(index).unwrap(), intrinsic_symbol,
                index, method_vars.len(), [])
        }
        let reference = make_named_executable_ref(intrinsic_symbol)
        let _ = producer_record_type(
            producer, scheme.ty, some(executable_origin(reference)))
    }
}

fn validate_producer_bijection(producer: ClosedCoreProducer) {
    if producer.recorder.refs.len() == 0 {
        panic("Core producer: closed program produced no reachable types")
    }
    for relation in producer.type_sources {
        let mut matches = 0
        for recorded in producer.recorded_types {
            if types_equal(core_type_source_type(relation), recorded.ty) &&
               core_type_fact_same(core_type_source_fact(relation), recorded.fact) {
                matches = matches + 1
            }
        }
        if matches != 1 {
            panic("Core producer: type source is not exact/unique")
        }
    }
    for recorded in producer.recorded_types {
        let mut matches = 0
        for relation in producer.type_sources {
            if types_equal(recorded.ty, core_type_source_type(relation)) &&
               core_type_fact_same(recorded.fact, core_type_source_fact(relation)) {
                matches = matches + 1
            }
        }
        if matches != 1 {
            panic("Core producer: recorded type is not reachable/unique")
        }
    }
    let mut ordinal = 0
    while ordinal < producer.recorder.refs.len() {
        let reference = producer.recorder.refs.get(ordinal).unwrap()
        let mut reachable = 0
        for relation in producer.type_sources {
            if core_type_fact_same(reference, core_type_source_fact(relation)) {
                reachable = reachable + 1
            }
        }
        for handled in producer.handled_sources {
            if core_type_fact_same(
                    reference,
                    core_handled_evidence_source_aggregate_fact(handled)) {
                reachable = reachable + 1
            }
        }
        if reachable != 1 || producer.recorder.specs.get(ordinal).unwrap().is_none() {
            panic("Core producer: recorder fact is partial or unreachable")
        }
        ordinal = ordinal + 1
    }
}

fn add_diagnostic_owner_seed(
    mut seed: CoreDiagnosticSeed, owner: ExecutableRef,
    module_key: Str, span: Span
) {
    require_diagnostic_span(span)
    for existing in seed.owners {
        if executable_ref_same(existing.owner, owner) {
            if existing.module_key != module_key ||
               !diagnostic_span_same(existing.span, span) {
                panic("Core diagnostic projection: owner source drifts")
            }
            return
        }
    }
    seed.owners.push(CoreDiagnosticOwnerSeed {
        owner: owner, module_key: module_key, span: span
    })
}

fn add_diagnostic_slot_seed(
    mut seed: CoreDiagnosticSeed, slot: SlotRef, module_key: Str,
    span: Span, label: Str
) {
    require_diagnostic_span(span)
    if label == "" { panic("Core diagnostic projection: source label is empty") }
    for existing in seed.slots {
        if slot_ref_same(existing.slot, slot) {
            if existing.module_key != module_key || existing.display_label != label ||
               !diagnostic_span_same(existing.span, span) {
                panic("Core diagnostic projection: source slot drifts")
            }
            return
        }
    }
    seed.slots.push(CoreDiagnosticSlotFact {
        slot: slot, module_key: module_key, span: span, display_label: label
    })
}

fn seed_diagnostic_params(
    mut seed: CoreDiagnosticSeed, module_key: Str,
    params: List<HParam>, span: Span
) {
    for param in params {
        match param.def_id {
            some(id) => add_diagnostic_slot_seed(
                seed, source_slot(module_key, id), module_key, span, param.name),
            none => panic("Core diagnostic projection: parameter lacks DefId")
        }
    }
}

fn seed_diagnostic_stmt(
    mut seed: CoreDiagnosticSeed, module_key: Str,
    owner_span: Span, value: HStmt
) {
    match value {
        HStmt::Let { name, name_span, def_id: some(id), init, .. } |
        HStmt::Var { name, name_span, def_id: some(id), init, .. } => {
            add_diagnostic_slot_seed(
                seed, source_slot(module_key, id), module_key, name_span, name)
            seed_diagnostic_expr(seed, module_key, owner_span, init)
        },
        HStmt::Assign { target, value, .. } => {
            seed_diagnostic_expr(seed, module_key, owner_span, target)
            seed_diagnostic_expr(seed, module_key, owner_span, value)
        },
        HStmt::ExprStmt { expr, .. } =>
            seed_diagnostic_expr(seed, module_key, owner_span, expr),
        HStmt::Return { value, .. } => match value {
            some(expr) => seed_diagnostic_expr(
                seed, module_key, owner_span, expr), none => {}
        },
        HStmt::While { condition, body, .. } => {
            seed_diagnostic_expr(seed, module_key, owner_span, condition)
            seed_diagnostic_expr(seed, module_key, owner_span, body)
        },
        HStmt::Break { .. } | HStmt::Continue { .. } => {},
        _ => panic("Core diagnostic projection: surface statement survived")
    }
}

fn seed_diagnostic_arm(
    mut seed: CoreDiagnosticSeed, module_key: Str,
    owner_span: Span, value: HMatchArm
) {
    for binding in value.bindings {
        add_diagnostic_slot_seed(
            seed, binding.slot, module_key, value.span, binding.name)
    }
    match value.guard {
        some(guard) => seed_diagnostic_expr(
            seed, module_key, owner_span, guard), none => {}
    }
    seed_diagnostic_expr(seed, module_key, owner_span, value.body)
}

fn seed_diagnostic_expr(
    mut seed: CoreDiagnosticSeed, module_key: Str,
    owner_span: Span, value: HExpr
) {
    match value {
        HExpr::Call { callee, args, .. } => {
            seed_diagnostic_expr(seed, module_key, owner_span, callee)
            for arg in args { seed_diagnostic_expr(seed, module_key, owner_span, arg) }
        },
        HExpr::BinOp { left, right, .. } => {
            seed_diagnostic_expr(seed, module_key, owner_span, left)
            seed_diagnostic_expr(seed, module_key, owner_span, right)
        },
        HExpr::UnaryOp { operand, .. } |
        HExpr::FieldAccess { receiver: operand, .. } |
        HExpr::UnsafeBlock { body: operand, .. } =>
            seed_diagnostic_expr(seed, module_key, owner_span, operand),
        HExpr::StructLit { fields, spread, .. } => {
            for field in fields {
                seed_diagnostic_expr(seed, module_key, owner_span, field.value)
            }
            match spread {
                some(value) => seed_diagnostic_expr(
                    seed, module_key, owner_span, value), none => {}
            }
        },
        HExpr::NamedVariantConstruct { fields, spread, .. } => {
            for field in fields {
                seed_diagnostic_expr(seed, module_key, owner_span, field.value)
            }
            match spread {
                some(value) => seed_diagnostic_expr(
                    seed, module_key, owner_span, value), none => {}
            }
        },
        HExpr::TupleLit { elements, .. } => {
            for element in elements {
                seed_diagnostic_expr(seed, module_key, owner_span, element)
            }
        },
        HExpr::Block { stmts, tail, .. } => {
            for stmt in stmts { seed_diagnostic_stmt(
                seed, module_key, owner_span, stmt) }
            match tail {
                some(expr) => seed_diagnostic_expr(
                    seed, module_key, owner_span, expr), none => {}
            }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            seed_diagnostic_expr(seed, module_key, owner_span, condition)
            seed_diagnostic_expr(seed, module_key, owner_span, then_branch)
            match else_branch {
                some(expr) => seed_diagnostic_expr(
                    seed, module_key, owner_span, expr), none => {}
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } |
        HExpr::TryCatch { body: scrutinee, arms, .. } => {
            seed_diagnostic_expr(seed, module_key, owner_span, scrutinee)
            for arm in arms { seed_diagnostic_arm(
                seed, module_key, owner_span, arm) }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            seed_diagnostic_expr(seed, module_key, owner_span, body)
            for handler in handlers {
                let span = hexpr_span(handler.body)
                add_diagnostic_owner_seed(
                    seed, handler.executable_ref, module_key, span)
                seed_diagnostic_params(seed, module_key, handler.params, span)
                match handler.resume_binding {
                    some(binding) => add_diagnostic_slot_seed(
                        seed, source_slot(module_key, binding.def_id),
                        module_key, span, binding.name),
                    none => {}
                }
                seed_diagnostic_expr(
                    seed, module_key, span, handler.body)
            }
        },
        HExpr::Lambda { executable_ref, params, body, span, .. } => {
            add_diagnostic_owner_seed(seed, executable_ref, module_key, span)
            seed_diagnostic_params(seed, module_key, params, span)
            seed_diagnostic_expr(seed, module_key, span, body)
        },
        HExpr::EffectOp { args, .. } => {
            for arg in args { seed_diagnostic_expr(
                seed, module_key, owner_span, arg) }
        },
        HExpr::ReturnExpr { value, .. } => match value {
            some(expr) => seed_diagnostic_expr(
                seed, module_key, owner_span, expr), none => {}
        },
        HExpr::IntLit { .. } | HExpr::FloatLit { .. } |
        HExpr::StrLit { .. } | HExpr::BoolLit { .. } |
        HExpr::Ident { .. } => {},
        _ => panic("Core diagnostic projection: surface expression survived")
    }
}

fn seed_diagnostic_decls(
    mut seed: CoreDiagnosticSeed, module_key: Str, values: List<HDecl>
) {
    for value in values {
        match value {
            HDecl::Fn { executable_ref, params, body, span, .. } => {
                add_diagnostic_owner_seed(seed, executable_ref, module_key, span)
                seed_diagnostic_params(seed, module_key, params, span)
                seed_diagnostic_expr(seed, module_key, span, body)
            },
            HDecl::Test { executable_ref, body, span, .. } |
            HDecl::Const { executable_ref, init: body, span, .. } => {
                add_diagnostic_owner_seed(seed, executable_ref, module_key, span)
                seed_diagnostic_expr(seed, module_key, span, body)
            },
            HDecl::ExternFn { executable_ref, span, .. } => {
                add_diagnostic_owner_seed(seed, executable_ref, module_key, span)
            },
            HDecl::Trait { methods, span, .. } => {
                for method in methods {
                    add_diagnostic_owner_seed(
                        seed, method.executable_ref, module_key, span)
                    seed_diagnostic_params(seed, module_key, method.params, span)
                    match method.body {
                        some(body) => seed_diagnostic_expr(
                            seed, module_key, span, body), none => {}
                    }
                }
            },
            HDecl::Impl {
                methods, default_specializations, delegate_plan, span, ..
            } => {
                seed_diagnostic_decls(seed, module_key, methods)
                for specialization in default_specializations {
                    add_diagnostic_owner_seed(
                        seed,
                        h_default_specialization_generated_executable(
                            specialization), module_key, span)
                }
                match delegate_plan {
                    some(plan) => {
                        for method in h_delegate_methods(plan) {
                            add_diagnostic_owner_seed(
                                seed, h_delegate_method_executable(method),
                                module_key, span)
                        }
                    },
                    none => {}
                }
            },
            HDecl::ModBlock { decls, .. } =>
                seed_diagnostic_decls(seed, module_key, decls),
            _ => {}
        }
    }
}

fn diagnostic_nominal_span(
    values: List<HDecl>, target: SymbolRef
) -> Span? {
    let mut found: Span? = none
    for value in values {
        match value {
            HDecl::Struct { owner_ref, span, .. } |
            HDecl::Enum { owner_ref, span, .. } => if symbol_ref_same(
                    registered_nominal_ref_symbol(owner_ref), target) {
                if found.is_some() {
                    panic("Core diagnostic projection: nominal source repeats")
                }
                found = some(span)
            },
            HDecl::ModBlock { decls, .. } => match diagnostic_nominal_span(
                    decls, target) {
                some(span) => {
                    if found.is_some() {
                        panic("Core diagnostic projection: nominal source repeats")
                    }
                    found = some(span)
                },
                none => {}
            },
            _ => {}
        }
    }
    found
}

fn seed_diagnostic_derived(
    mut seed: CoreDiagnosticSeed, module_key: Str,
    decls: List<HDecl>, values: List<DerivedImpl>
) {
    for value in values {
        let span = match diagnostic_nominal_span(
                decls, registered_nominal_ref_symbol(value.target_owner)) {
            some(found) => found,
            none => panic("Core diagnostic projection: derived source is absent")
        }
        for method in value.methods {
            add_diagnostic_owner_seed(
                seed, method.executable_ref, module_key, span)
        }
    }
}

struct CoreDiagnosticOwnerSeed {
    owner: ExecutableRef, module_key: Str, span: Span
}
struct CoreDiagnosticSlotFact {
    slot: SlotRef, module_key: Str, span: Span, display_label: Str
}
struct CoreDiagnosticOriginFact {
    origin: OriginRef, owner: ExecutableRef, module_key: Str, span: Span
}
struct CoreDiagnosticSeed {
    owners: List<CoreDiagnosticOwnerSeed>,
    slots: List<CoreDiagnosticSlotFact>
}

pub struct CoreDiagnosticProjection {
    origins: List<CoreDiagnosticOriginFact>,
    slots: List<CoreDiagnosticSlotFact>
}

pub struct CoreDiagnosticLocation {
    module_key: Str, span: Span
}
pub fn core_diagnostic_location_module_key(
    value: CoreDiagnosticLocation
) -> Str { value.module_key }
pub fn core_diagnostic_location_span(
    value: CoreDiagnosticLocation
) -> Span { value.span }

fn diagnostic_span_same(left: Span, right: Span) -> Bool {
    left.file == right.file &&
        left.start.line == right.start.line &&
        left.start.column == right.start.column &&
        left.start.offset == right.start.offset &&
        left.end.line == right.end.line &&
        left.end.column == right.end.column &&
        left.end.offset == right.end.offset
}
fn require_diagnostic_span(value: Span) {
    if value.file == "" || value.file == "<unknown>" ||
       value.start.line < 0 || value.end.line < value.start.line {
        panic("Core diagnostic projection: source span is not exact")
    }
}

pub fn validate_core_diagnostic_projection(value: CoreDiagnosticProjection) {
    let mut origin_index = 0
    while origin_index < value.origins.len() {
        let left = value.origins.get(origin_index).unwrap()
        require_diagnostic_span(left.span)
        let mut right = origin_index + 1
        while right < value.origins.len() {
            if origin_ref_same(
                    left.origin, value.origins.get(right).unwrap().origin) {
                panic("Core diagnostic projection: origin repeats")
            }
            right = right + 1
        }
        origin_index = origin_index + 1
    }
    let mut slot_index = 0
    while slot_index < value.slots.len() {
        let left = value.slots.get(slot_index).unwrap()
        require_diagnostic_span(left.span)
        if left.display_label == "" {
            panic("Core diagnostic projection: slot label is empty")
        }
        let mut right = slot_index + 1
        while right < value.slots.len() {
            if slot_ref_same(left.slot, value.slots.get(right).unwrap().slot) {
                panic("Core diagnostic projection: slot repeats")
            }
            right = right + 1
        }
        slot_index = slot_index + 1
    }
}

pub fn core_diagnostic_projection_origin_location(
    value: CoreDiagnosticProjection, owner: ExecutableRef,
    origin: OriginRef
) -> CoreDiagnosticLocation {
    let mut found: CoreDiagnosticOriginFact? = none
    for fact in value.origins {
        if origin_ref_same(fact.origin, origin) {
            if found.is_some() || !executable_ref_same(fact.owner, owner) {
                panic("Core diagnostic projection: origin owner/uniqueness differs")
            }
            found = some(fact)
        }
    }
    match found {
        some(fact) => CoreDiagnosticLocation {
            module_key: fact.module_key, span: fact.span
        },
        none => panic("Core diagnostic projection: origin is absent")
    }
}

pub fn core_diagnostic_projection_slot_display_label(
    value: CoreDiagnosticProjection, slot: SlotRef,
    expected_module_key: Str
) -> Str {
    if expected_module_key == "" {
        panic("Core diagnostic projection: expected module is empty")
    }
    let mut found: Str? = none
    for fact in value.slots {
        if slot_ref_same(fact.slot, slot) {
            if found.is_some() {
                panic("Core diagnostic projection: slot is duplicated")
            }
            let slot_module = if slot_ref_is_source(slot) {
                slot_ref_source_origin_module_key(slot)
            } else {
                let path_owner = path_ref_owner(slot_ref_synthetic_path(slot))
                if path_owner_ref_is_symbol(path_owner) {
                    symbol_ref_origin_module_key(
                        path_owner_ref_symbol(path_owner))
                } else {
                    module_body_ref_origin_module_key(
                        path_owner_ref_module_body(path_owner))
                }
            }
            if fact.module_key != expected_module_key ||
               fact.module_key != slot_module {
                panic("Core diagnostic projection: slot crosses module")
            }
            found = some(fact.display_label)
        }
    }
    match found {
        some(label) => label,
        none => panic("Core diagnostic projection: slot is absent")
    }
}

pub struct FrozenCoreAssemblyFacts {
    module_key: Str, module_order: Int,
    type_refs: List<CoreTypeFactRef>, type_nodes: List<FlowTypeNode>,
    type_sources: List<CoreTypeSourceFact>,
    effect_parameters: List<TypedEffectFormalFact>,
    callable_effect_rows: List<TypedCallableEffectFact>,
    project_callable_effects: List<ProjectCallableEffectSource>,
    project_type_mapping: List<Int>,
    handled_evidence_types: List<CoreHandledEvidenceTypeSource>,
    builtin_methods: List<BuiltinMethodContractFact>,
    diagnostic_seed: CoreDiagnosticSeed,
    program: HProgram
}
struct ProjectCallableEffectSource {
    reference: ExecutableRef,
    contract: CoreEffectContract
}

pub fn produce_closed_core_assembly_facts(
    module_key: Str, module_order: Int,
    closed_program: HProgram, env: TypeEnv,
    effect_parameters: List<TypedEffectFormalFact>,
    callable_effect_rows: List<TypedCallableEffectFact>
) -> FrozenCoreAssemblyFacts {
    let producer = new_closed_core_producer(
        module_key, module_order, env, effect_parameters)
    producer_register_decl_parameters(producer, closed_program.decls)
    producer_register_environment_effect_parameters(producer)
    producer_record_decls(producer, closed_program.decls)
    producer_record_derived(producer, closed_program.derived_impls)
    producer_record_builtin_methods(producer)
    validate_producer_bijection(producer)
    let diagnostic_seed = CoreDiagnosticSeed { owners: [], slots: [] }
    seed_diagnostic_decls(
        diagnostic_seed, module_key, closed_program.decls)
    seed_diagnostic_derived(
        diagnostic_seed, module_key,
        closed_program.decls, closed_program.derived_impls)
    freeze_closed_core_assembly_facts(
        producer.recorder, closed_program, env,
        producer.type_sources, producer.handled_sources,
        producer.effect_parameters, callable_effect_rows,
        diagnostic_seed)
}

pub fn frozen_core_assembly_program(
    value: FrozenCoreAssemblyFacts
) -> HProgram { value.program }
pub fn frozen_core_assembly_type_sources(
    value: FrozenCoreAssemblyFacts
) -> List<CoreTypeSourceFact> {
    value.type_sources.map(fn(item) { item })
}
pub fn frozen_core_assembly_handled_sources(
    value: FrozenCoreAssemblyFacts
) -> List<CoreHandledEvidenceTypeSource> {
    value.handled_evidence_types.map(fn(item) { item })
}
pub fn mutate_core_unowned_effect_tail(
    value: FrozenCoreAssemblyFacts
) {
    let mut retained: List<TypedEffectFormalFact> = []
    let mut removed = false
    for source in value.effect_parameters {
        if !removed {
            removed = true
        } else {
            retained.push(source)
        }
    }
    if !removed {
        panic("Core mutation: no effect-parameter relation to remove")
    }
    let mutated = FrozenCoreAssemblyFacts {
        module_key: value.module_key, module_order: value.module_order,
        type_refs: value.type_refs, type_nodes: value.type_nodes,
        type_sources: value.type_sources, effect_parameters: retained,
        callable_effect_rows: value.callable_effect_rows,
        project_callable_effects: [], project_type_mapping: [],
        handled_evidence_types: value.handled_evidence_types,
        diagnostic_seed: value.diagnostic_seed,
        builtin_methods: value.builtin_methods, program: value.program
    }
    let _ = assemble_single_core(mutated)
    panic("Core mutation: unowned effect tail survived Core assembly")
}
fn freeze_closed_core_assembly_facts(
    mut recorder: CoreAssemblyRecorder, closed_program: HProgram, env: TypeEnv,
    type_sources: List<CoreTypeSourceFact>,
    handled_evidence_types: List<CoreHandledEvidenceTypeSource>,
    effect_parameters: List<TypedEffectFormalFact>,
    callable_effect_rows: List<TypedCallableEffectFact>,
    diagnostic_seed: CoreDiagnosticSeed
) -> FrozenCoreAssemblyFacts {
    validate_hir_binder_def_ids(closed_program)
    require_open(recorder); recorder.frozen = true
    if recorder.refs.len() == 0 || recorder.refs.len() != recorder.specs.len() {
        panic("Core assembly: type recorder is empty/partial")
    }
    let mut nodes: List<FlowTypeNode> = []
    let mut index = 0
    while index < recorder.refs.len() {
        nodes.push(materialize_type(
            recorder.specs.get(index).unwrap().unwrap(),
            recorder.refs.get(index).unwrap(), recorder.module_key))
        index = index + 1
    }
    for relation in type_sources {
        if core_type_fact_module_key(core_type_source_fact(relation)) != recorder.module_key {
            panic("Core assembly: type source crosses module")
        }
    }
    let mut effect_parameter_index = 0
    while effect_parameter_index < effect_parameters.len() {
        let source = effect_parameters.get(
            effect_parameter_index).unwrap()
        let source_parameter = typed_effect_formal_parameter(source)
        let mut expected_ordinal = 0
        let mut prior = 0
        while prior < effect_parameter_index {
            let earlier = effect_parameters.get(prior).unwrap()
            if origin_ref_same(
                    effect_param_owner(
                        typed_effect_formal_parameter(earlier)),
                    effect_param_owner(source_parameter)) {
                expected_ordinal = expected_ordinal + 1
            }
            prior = prior + 1
        }
        if effect_param_ordinal(source_parameter) != expected_ordinal {
            panic("Core assembly: effect formal order is not stable")
        }
        effect_parameter_index = effect_parameter_index + 1
    }
    let mut evidence_index = 0
    while evidence_index < handled_evidence_types.len() {
        let source = handled_evidence_types.get(evidence_index).unwrap()
        let aggregate = core_handled_evidence_source_aggregate_fact(source)
        if core_type_fact_module_key(aggregate) != recorder.module_key ||
           core_type_fact_ordinal(aggregate) < 0 ||
           core_type_fact_ordinal(aggregate) >= recorder.refs.len() {
            panic("Core assembly: handled evidence type is outside recorder")
        }
        let mut right = evidence_index + 1
        while right < handled_evidence_types.len() {
            let other = handled_evidence_types.get(right).unwrap()
            if core_handled_evidence_type_source_same(source, other) ||
               handled_effect_ref_same(
                    core_handled_evidence_source_requirement(source),
                    core_handled_evidence_source_requirement(other)) {
                panic("Core assembly: handled evidence type repeats")
            }
            right = right + 1
        }
        evidence_index = evidence_index + 1
    }
    FrozenCoreAssemblyFacts {
        module_key: recorder.module_key, module_order: recorder.module_order,
        type_refs: recorder.refs, type_nodes: nodes,
        type_sources: type_sources,
        effect_parameters: effect_parameters,
        callable_effect_rows: callable_effect_rows,
        project_callable_effects: [], project_type_mapping: [],
        handled_evidence_types: handled_evidence_types,
        diagnostic_seed: diagnostic_seed,
        builtin_methods: if recorder.module_order == 0 {
            builtin_method_contract_facts(env)
        } else { [] },
        program: closed_program
    }
}
// ============================================================
// Assembly result/remap API used by LegacyProjection
// ============================================================

pub struct CoreAssemblyTypeRemapEntry {
    source: CoreTypeFactRef, target: CoreTypeRef
}
pub struct CoreAssemblyTypeRemap { entries: List<CoreAssemblyTypeRemapEntry> }
pub fn core_assembly_remap_type(
    value: CoreAssemblyTypeRemap, source: CoreTypeFactRef
) -> CoreTypeRef {
    let mut found: CoreTypeRef? = none
    for entry in value.entries {
        if core_type_fact_same(entry.source, source) { found = some(entry.target) }
    }
    match found { some(v) => v,
        none => panic("Core assembly: type fact lacks project remap") }
}
pub struct CoreAssemblyEffectRemapEntry {
    module_key: Str, source: CoreEffectSet, target: CoreEffectSet
}
pub struct CoreAssemblyEffectRemap { entries: List<CoreAssemblyEffectRemapEntry> }
pub fn core_assembly_remap_effect(
    value: CoreAssemblyEffectRemap, module_key: Str, source: CoreEffectSet
) -> CoreEffectSet {
    for entry in value.entries {
        if entry.module_key == module_key && core_effect_set_same(entry.source, source) {
            return make_core_effect_set(core_effect_set_atoms(entry.target))
        }
    }
    panic("Core assembly: effect set lacks project remap")
}
pub struct CoreEffectSetFact { value: CoreEffectSet }
pub fn core_effect_set_fact_local_set(value: CoreEffectSetFact) -> CoreEffectSet {
    make_core_effect_set(core_effect_set_atoms(value.value))
}
pub fn make_core_effect_set_fact_from_row(
    type_sources: List<CoreTypeSourceFact>, row: EffectRow, module_key: Str
) -> CoreEffectSetFact {
    CoreEffectSetFact {
        value: core_effects(type_sources, row, module_key)
    }
}
pub struct CoreAssemblyResult {
    program: CoreProgram, type_remap: CoreAssemblyTypeRemap,
    effect_remap: CoreAssemblyEffectRemap,
    diagnostic_projection: CoreDiagnosticProjection
}
pub fn core_assembly_result_program(value: CoreAssemblyResult) -> CoreProgram { value.program }
pub fn core_assembly_result_type_remap(value: CoreAssemblyResult) -> CoreAssemblyTypeRemap { value.type_remap }
pub fn core_assembly_result_effect_remap(value: CoreAssemblyResult) -> CoreAssemblyEffectRemap { value.effect_remap }
pub fn core_assembly_result_diagnostic_projection(
    value: CoreAssemblyResult
) -> CoreDiagnosticProjection {
    CoreDiagnosticProjection {
        origins: value.diagnostic_projection.origins.map(fn(item) { item }),
        slots: value.diagnostic_projection.slots.map(fn(item) { item })
    }
}

// ============================================================
// Canonical HIR -> structured Core bodies
// ============================================================

fn type_fact_for(
    values: List<CoreTypeSourceFact>, ty: Type, module_key: Str
) -> CoreTypeRef {
    let mut found: CoreTypeFactRef? = none
    for value in values {
        if types_equal(core_type_source_type(value), ty) {
            if found.is_some() && !core_type_fact_same(
                    found.unwrap(), core_type_source_fact(value)) {
                panic("Core assembly: one Type maps to multiple facts")
            }
            found = some(core_type_source_fact(value))
        }
    }
    let result = match found { some(v) => v,
        none => panic("Core assembly: canonical HIR type lacks exact fact") }
    if core_type_fact_module_key(result) != module_key {
        panic("Core assembly: HIR type fact crosses module")
    }
    core_type_fact_local_ref(result)
}

fn handled_evidence_type_for(
    values: List<CoreHandledEvidenceTypeSource>, requirement: HandledEffectRef
) -> CoreTypeRef {
    let mut found: CoreTypeFactRef? = none
    for source in values {
        if handled_effect_ref_same(
                core_handled_evidence_source_requirement(source),
                requirement) {
            if found.is_some() {
                panic("Core assembly: handled evidence has two aggregate types")
            }
            found = some(core_handled_evidence_source_aggregate_fact(source))
        }
    }
    match found {
        some(value) => core_type_fact_local_ref(value),
        none => panic("Core assembly: handled evidence aggregate type is absent")
    }
}
fn core_handled_binding(
    types: List<CoreHandledEvidenceTypeSource>, value: HandledEvidenceRef
) -> CoreHandledEvidenceBinding {
    make_core_handled_evidence_binding(
        value, handled_evidence_type_for(
            types, handled_evidence_requirement(value)))
}
fn core_handled_use(
    types: List<CoreHandledEvidenceTypeSource>, value: HandledEvidenceRef
) -> CoreHandledEvidenceUse {
    make_core_handled_evidence_use(
        value, handled_evidence_type_for(
            types, handled_evidence_requirement(value)))
}
fn core_handled_capture(
    types: List<CoreHandledEvidenceTypeSource>,
    value: HandledEvidenceCapture
) -> CoreHandledEvidenceCapture {
    let target = handled_evidence_capture_target(value)
    make_core_handled_evidence_capture(
        value, handled_evidence_type_for(
            types, handled_evidence_requirement(target)))
}
fn effect_operation_handled_binding(
    operation: EffectOperationRef
) -> HandledEvidenceRef {
    let executable = effect_operation_ref_callable(operation)
    let mut path = executable_prefix(executable)
    path.push("handled-operation-evidence:0")
    let site = make_path_ref(
        executable_owner(executable), path, path_role_parameter())
    make_handled_evidence_ref(
        effect_operation_ref_effect(operation),
        make_semantic_evidence_binder(
            make_synthetic_slot_ref(site), executable,
            binder_kind_handled_evidence_param(), site),
        executable, 0)
}

fn core_effects(
    values: List<CoreTypeSourceFact>, row: EffectRow, module_key: Str
) -> CoreEffectSet {
    let mut atoms: List<CoreEffectAtom> = []
    for atom in row.effects {
        atoms.push(match atom {
            Effect::FailEffect { error_type } =>
                make_core_fail_effect(type_fact_for(values, error_type, module_key)),
            Effect::MutEffect { state_type } =>
                make_core_mut_effect(type_fact_for(values, state_type, module_key)),
            Effect::UnsafeEffect => make_core_unsafe_effect(),
            Effect::CustomEffect { reference, type_args, .. } =>
                make_core_handled_effect(reference, type_args.map(fn(ty) {
                    type_fact_for(values, ty, module_key)
                })),
            Effect::SystemEffect { reference } =>
                make_core_system_effect(reference)
        })
    }
    make_core_effect_set(atoms)
}

fn effect_parameter_from_sources(
    sources: List<TypedEffectFormalFact>, raw_tail: Int
) -> EffectParamRef {
    let mut found: EffectParamRef? = none
    for source in sources {
        if typed_effect_formal_raw_tail(source) == raw_tail {
            if found.is_some() {
                panic("Core assembly: raw effect tail maps twice")
            }
            let parameter = typed_effect_formal_parameter(source)
            found = some(parameter)
        }
    }
    match found {
        some(parameter) => parameter,
        none => panic("Core assembly: unowned raw effect tail crossed Core")
    }
}

fn core_effect_contract_from_row(
    values: List<CoreTypeSourceFact>, row: EffectRow, module_key: Str,
    effect_parameters: List<TypedEffectFormalFact>, owner: OriginRef?
) -> CoreEffectContract {
    let parameter = row.tail.map(fn(raw_tail) {
        effect_parameter_from_sources(effect_parameters, raw_tail)
    })
    match (parameter, owner) {
        (some(formal), some(expected_owner)) => if !origin_ref_same(
                effect_param_owner(formal), expected_owner) {
            panic("Core assembly: callable effect formal owner differs")
        },
        _ => {}
    }
    make_core_effect_contract(
        core_effects(values, row, module_key),
        parameter)
}

fn executable_owner(value: ExecutableRef) -> PathOwnerRef {
    if executable_ref_is_named(value) {
        path_owner_for_symbol(executable_ref_named_symbol(value))
    } else { path_ref_owner(executable_ref_anonymous_path(value)) }
}
fn executable_prefix(value: ExecutableRef) -> List<Str> {
    if executable_ref_is_named(value) { [] }
    else { path_ref_normalized_child_path(executable_ref_anonymous_path(value)) }
}
fn body_anchor(value: ExecutableRef) -> PathRef {
    let mut path = executable_prefix(value); path.push("core-body")
    make_path_ref(executable_owner(value), path, path_role_child())
}
fn executable_origin(value: ExecutableRef) -> OriginRef {
    if executable_ref_is_named(value) {
        make_symbol_origin_ref(executable_ref_named_symbol(value))
    } else { make_path_origin_ref(executable_ref_anonymous_path(value)) }
}

struct CaptureSlotMap { source: SlotRef, target: SlotRef }

fn capture_slot_maps(values: List<HLambdaCapture>) -> List<CaptureSlotMap> {
    values.map(fn(value) {
        CaptureSlotMap { source: value.source, target: value.target }
    })
}

struct LowerCtx {
    module_key: Str, owner: ExecutableRef,
    effect_parameters: List<TypedEffectFormalFact>,
    project_callable_effects: List<ProjectCallableEffectSource>,
    project_type_mapping: List<Int>,
    types: List<CoreTypeSourceFact>,
    type_nodes: List<FlowTypeNode>,
    handled_evidence_types: List<CoreHandledEvidenceTypeSource>,
    binders: List<CoreBinder>, captures: List<CaptureSlotMap>, next_origin: Int,
    diagnostic_origins: List<CoreDiagnosticOriginFact>
}
fn fresh_origin(mut ctx: LowerCtx, label: Str, span: Span) -> OriginRef {
    require_diagnostic_span(span)
    let mut path = executable_prefix(ctx.owner)
    path.push("core"); path.push(label); path.push(ctx.next_origin.to_str())
    ctx.next_origin = ctx.next_origin + 1
    let origin = make_path_origin_ref(make_path_ref(
        executable_owner(ctx.owner), path, path_role_child()))
    ctx.diagnostic_origins.push(CoreDiagnosticOriginFact {
        origin: origin, owner: ctx.owner,
        module_key: ctx.module_key, span: span
    })
    origin
}

fn hstmt_source_span(value: HStmt) -> Span {
    match value {
        HStmt::Let { span, .. } => span,
        HStmt::Var { span, .. } => span,
        HStmt::Assign { span, .. } => span,
        HStmt::ExprStmt { span, .. } => span,
        HStmt::Return { span, .. } => span,
        HStmt::While { span, .. } => span,
        HStmt::Break { span } => span,
        HStmt::Continue { span } => span,
        _ => panic("Core diagnostic projection: surface statement survived")
    }
}
fn source_slot(module_key: Str, def_id: Int) -> SlotRef {
    make_source_slot_ref(module_key,
        if def_id < 0 { slot_domain_dictionary() }
        else { slot_domain_lexical() }, def_id)
}
fn binder_role(kind: BinderKind) -> PathRole {
    let tag = binder_kind_tag(kind)
    if tag == binder_kind_tag(binder_kind_source_param()) ||
       tag == binder_kind_tag(binder_kind_lambda_param()) {
        path_role_parameter()
    } else if tag == binder_kind_tag(binder_kind_lambda_capture()) {
        path_role_capture()
    } else if tag == binder_kind_tag(binder_kind_handler_param()) ||
              tag == binder_kind_tag(binder_kind_handler_resume()) {
        path_role_handler()
    } else { path_role_declaration() }
}
fn captured_slot(ctx: LowerCtx, slot: SlotRef) -> SlotRef? {
    for capture in ctx.captures {
        if slot_ref_same(capture.source, slot) ||
           slot_ref_same(capture.target, slot) {
            return some(capture.target)
        }
    }
    none
}
fn resolved_slot(ctx: LowerCtx, slot: SlotRef) -> SlotRef {
    match captured_slot(ctx, slot) { some(value) => value, none => slot }
}
fn ensure_binder(
    mut ctx: LowerCtx, slot: SlotRef, ty: Type,
    kind: BinderKind, is_mutable: Bool
) -> SlotRef {
    let resolved = resolved_slot(ctx, slot)
    for value in ctx.binders {
        if slot_ref_same(core_binder_reference(value), resolved) {
            return resolved
        }
    }
    let capture = captured_slot(ctx, slot)
    let exact_kind = if capture.is_some() {
        binder_kind_lambda_capture()
    } else { kind }
    let site = match capture {
        some(target) => slot_ref_synthetic_path(target),
        none => {
            let mut path = executable_prefix(ctx.owner)
            path.push("binder"); path.push(slot_ref_source_def_id(slot).to_str())
            make_path_ref(executable_owner(ctx.owner), path, binder_role(exact_kind))
        }
    }
    ctx.binders.push(make_core_binder(
        resolved, type_fact_for(ctx.types, ty, ctx.module_key), exact_kind, site,
        flow_own_storage(), is_mutable))
    resolved
}
fn activate_handled_evidence_binder(
    mut ctx: LowerCtx, value: HandledEvidenceRef
) {
    let binding = handled_evidence_binding(value)
    let slot = binder_entry_slot(binding)
    for existing in ctx.binders {
        if slot_ref_same(core_binder_reference(existing), slot) { return }
    }
    let kind = binder_entry_kind(binding)
    let storage = if binder_kind_tag(kind) ==
            binder_kind_tag(binder_kind_handled_evidence_local()) {
        flow_own_storage()
    } else { flow_borrow_storage() }
    ctx.binders.push(make_core_binder(
        slot,
        handled_evidence_type_for(
            ctx.handled_evidence_types,
            handled_evidence_requirement(value)),
        kind, binder_entry_site(binding), storage, false))
}
fn param_slot(ctx: LowerCtx, param: HParam, kind: BinderKind) -> SlotRef {
    let id = match param.def_id { some(v) => v,
        none => panic("Core assembly: parameter lacks DefId") }
    let slot = source_slot(ctx.module_key, id)
    ensure_binder(ctx, slot, param.ty, kind, param.is_mutable)
}
fn remap_dictionary_evidence(
    mut ctx: LowerCtx, value: ExactDictRef
) -> ExactDictRef {
    if dict_ref_is_local(value) {
        let slot = resolved_slot(ctx, dict_ref_local(value))
        let mut present = false
        for binder in ctx.binders {
            if slot_ref_same(core_binder_reference(binder), slot) { present = true }
        }
        if !present {
            let kind = if slot_ref_is_source(slot) {
                binder_kind_dictionary_evidence_local()
            } else if path_role_same(
                    path_ref_role(slot_ref_synthetic_path(slot)),
                    path_role_capture()) {
                binder_kind_lambda_capture()
            } else {
                binder_kind_dictionary_evidence_param()
            }
            let site = if slot_ref_is_source(slot) {
                let mut path = executable_prefix(ctx.owner)
                path.push("dictionary-binder")
                path.push(slot_ref_source_def_id(slot).to_str())
                make_path_ref(executable_owner(ctx.owner), path, binder_role(kind))
            } else { slot_ref_synthetic_path(slot) }
            ctx.binders.push(make_core_binder(
                slot, type_fact_for(
                    ctx.types, Type::TupleType { elements: [] }, ctx.module_key),
                kind, site, flow_borrow_storage(), false))
        }
        make_exact_local_dict_ref(slot)
    } else if dict_ref_is_static(value) {
        make_exact_static_dict_ref(dict_ref_static(value))
    } else {
        make_exact_wrapped_dict_ref(
            dict_ref_wrapped_base(value),
            dict_ref_wrapped_inner(value).map(fn(inner) {
                remap_dictionary_evidence(ctx, inner)
            }))
    }
}
fn evidence(ctx: LowerCtx, values: List<DictRef>) -> List<CoreEvidenceRef> {
    values.map(fn(value) { make_core_dict_evidence(
        remap_dictionary_evidence(ctx, dict_ref_exact(value))) })
}
fn exact_method_ref(value: MethodCallRef) -> ExactMethodRef {
    if method_call_ref_is_intrinsic(value) {
        make_exact_intrinsic_method_ref(method_call_ref_intrinsic(value))
    } else if method_call_ref_is_concrete(value) {
        make_exact_impl_method_ref(method_call_ref_impl(value))
    } else if method_call_ref_is_bound(value) {
        make_exact_trait_method_ref(method_call_ref_bound(value))
    } else {
        panic("Core assembly: method selection is not exact")
    }
}
fn call_contract(
    ctx: LowerCtx, signature: Type, receiver_mutable: Bool
) -> FlowCallContract {
    match signature {
        Type::FnType { params, return_type, .. } => {
            let mut roles: List<FlowSemanticRole> = []
            let mut index = 0
            for _ in params {
                roles.push(if index == 0 && receiver_mutable {
                    flow_semantic_role_mutate()
                } else { flow_semantic_role_read() })
                index = index + 1
            }
            make_module_flow_call_contract(
                ctx.module_key,
                params.map(fn(t) { make_core_type_ref(
                    core_type_ref_index(type_fact_for(
                        ctx.types, t, ctx.module_key))) }), roles,
                make_core_type_ref(core_type_ref_index(type_fact_for(
                    ctx.types, return_type, ctx.module_key))),
                flow_semantic_role_read(), make_fresh_flow_value_origin())
        },
        _ => panic("Core assembly: call signature is not Fn")
    }
}
fn callable_effect_source(
    ctx: LowerCtx, reference: ExecutableRef
) -> CoreEffectContract? {
    let mut found: CoreEffectContract? = none
    for source in ctx.project_callable_effects {
        if executable_ref_same(source.reference, reference) {
            if found.is_some() {
                panic("Core assembly: callable has two effect sources")
            }
            found = some(project_effect_contract_to_module(
                source.contract, ctx.project_type_mapping, ctx.module_key))
        }
    }
    found
}
fn local_callable_effect_source(
    ctx: LowerCtx, slot: SlotRef
) -> CoreEffectContract {
    let exact_slot = resolved_slot(ctx, slot)
    let mut found: CoreTypeRef? = none
    for binder in ctx.binders {
        if slot_ref_same(core_binder_reference(binder), exact_slot) {
            if found.is_some() {
                panic("Core assembly: local callable binder repeats")
            }
            found = some(core_binder_type(binder))
        }
    }
    let callable_type = match found {
        some(value) => value,
        none => panic("Core assembly: local callable lacks frozen binder type")
    }
    match ctx.type_nodes.get(core_type_ref_index(callable_type)) {
        some(node) => flow_type_node_callable_effects(node),
        none => panic("Core assembly: local callable type node is absent")
    }
}
fn core_callee(ctx: LowerCtx, value: CalleeRef, signature: Type) -> CoreCalleeRef {
    let contract = call_contract(ctx, signature, false)
    let actual_row = match signature {
        Type::FnType { effects, .. } => effects,
        _ => panic("Core assembly: callee signature is not callable")
    }
    let actual_effects = core_effect_contract_from_row(
        ctx.types, actual_row, ctx.module_key, ctx.effect_parameters,
        none)
    if callee_ref_is_named(value) {
        let executable = make_named_executable_ref(callee_ref_named_symbol(value))
        let source_effects = match callable_effect_source(ctx, executable) {
            some(contract) => contract,
            none => panic("Core assembly: exact callable effect source is absent")
        }
        make_core_direct_callee(
            executable, contract,
            make_explicit_core_effect_instantiation(
                source_effects, actual_effects, actual_effects))
    } else if callee_ref_is_local(value) {
        let source_effects = local_callable_effect_source(
            ctx, callee_ref_local_slot(value))
        make_core_local_callee(
            resolved_slot(ctx, callee_ref_local_slot(value)), contract,
            make_explicit_core_effect_instantiation(
                source_effects, actual_effects, actual_effects))
    } else {
        let executable = make_anonymous_executable_ref(
            callee_ref_dynamic_path(value))
        let source_effects = match callable_effect_source(ctx, executable) {
            some(contract) => contract,
            none => panic(
                "Core assembly: dynamic callable effect source is absent")
        }
        make_core_dynamic_callee(
            callee_ref_dynamic_path(value), contract,
            make_explicit_core_effect_instantiation(
                source_effects, actual_effects, actual_effects))
    }
}
fn core_field(value: HProjectionRef) -> CoreFieldRef {
    let kind = h_projection_kind(value)
    if kind == 0 { make_core_nominal_field(h_projection_nominal(value)) }
    else if kind == 1 { make_core_variant_field(h_projection_variant(value)) }
    else if kind == 2 {
        panic("Core assembly: structural projection needs typed record contract")
    }
    else if kind == 3 { make_core_tuple_field(h_projection_tuple_index(value)) }
    else { panic("Core assembly: intrinsic projection is not a value field") }
}

struct LowerUpdateInput {
    field: CoreFieldRef,
    value: HExpr
}

fn lower_type_node(ctx: LowerCtx, ty: CoreTypeRef) -> FlowTypeNode {
    match ctx.type_nodes.get(core_type_ref_index(ty)) {
        some(node) => node,
        none => panic("Core assembly: aggregate type node is absent")
    }
}

fn lower_access_field(
    ctx: LowerCtx, projection: HProjectionRef, receiver: HExpr
) -> CoreFieldRef {
    if h_projection_kind(projection) != 2 { return core_field(projection) }
    let receiver_type = type_fact_for(
        ctx.types, hexpr_type(receiver), ctx.module_key)
    let name = h_projection_structural_name(projection)
    let mut found: CoreFieldRef? = none
    for fact in flow_type_node_nominal_fields(
            lower_type_node(ctx, receiver_type)) {
        let identity = flow_nominal_field_identity(fact)
        if !flow_field_identity_is_nominal(identity) &&
           !flow_field_identity_is_variant(identity) &&
           flow_nominal_field_record_name(fact) == name {
            if found.is_some() {
                panic("Core assembly: record contract repeats a field name")
            }
            found = some(make_core_record_field(
                flow_field_identity_path(identity), name))
        }
    }
    match found {
        some(field) => field,
        none => panic("Core assembly: record projection is absent from contract")
    }
}

fn lower_struct_update_schema(
    ctx: LowerCtx, ty: CoreTypeRef
) -> List<FlowNominalFieldFact> {
    flow_type_node_nominal_fields(lower_type_node(ctx, ty)).filter(fn(fact) {
        flow_field_identity_is_nominal(flow_nominal_field_identity(fact))
    })
}

fn lower_variant_update_schema(
    ctx: LowerCtx, ty: CoreTypeRef, variant: VariantRef
) -> List<FlowNominalFieldFact> {
    flow_type_node_nominal_fields(lower_type_node(ctx, ty)).filter(fn(fact) {
        let identity = flow_nominal_field_identity(fact)
        flow_field_identity_is_variant(identity) &&
            variant_ref_same(
                variant_field_ref_variant(
                    flow_field_identity_variant(identity)), variant)
    })
}

fn lower_update_core_field(fact: FlowNominalFieldFact) -> CoreFieldRef {
    let identity = flow_nominal_field_identity(fact)
    if flow_field_identity_is_nominal(identity) {
        make_core_nominal_field(flow_field_identity_nominal(identity))
    } else if flow_field_identity_is_variant(identity) {
        make_core_variant_field(flow_field_identity_variant(identity))
    } else {
        panic("Core assembly: named update schema has structural field")
    }
}

fn lower_update_has_input(
    values: List<LowerUpdateInput>, field: CoreFieldRef
) -> Bool {
    values.any(fn(value) { core_field_ref_same(value.field, field) })
}

fn lower_named_update(
    mut ctx: LowerCtx, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, spread: HExpr,
    inputs: List<LowerUpdateInput>, schema: List<FlowNominalFieldFact>,
    constructor: CoreConstructorRef
) -> CoreExpr {
    for input in inputs {
        if !schema.any(fn(fact) {
                core_field_ref_same(
                    input.field, lower_update_core_field(fact))
            }) {
            panic("Core assembly: update field is absent from nominal schema")
        }
    }

    let base = lower_expr(ctx, spread)
    let mut overrides: List<CoreFieldValue> = []
    for input in inputs {
        overrides.push(make_core_field_value(
            input.field, lower_expr(ctx, input.value)))
    }
    make_core_move_update_expr(
        ty, effects, origin, base, constructor,
        schema.map(fn(fact) { lower_update_core_field(fact) }), overrides)
}

fn primitive_tag(op: BinOp) -> Int {
    match op {
        BinOp::Add => 0, BinOp::Sub => 1, BinOp::Mul => 2,
        BinOp::Div => 3, BinOp::Mod => 4,
        BinOp::Lt => 7, BinOp::Lte => 8,
        BinOp::Gt => 9, BinOp::Gte => 10,
        _ => panic("Core assembly: trait BinOp was not elaborated")
    }
}

fn lower_pattern(ctx: LowerCtx, ast: Pattern, plan: HPatternPlan) -> CorePattern {
    let kind = h_pattern_kind(plan)
    if kind == 0 { return make_core_wildcard_pattern(type_fact_for(
        ctx.types, Type::UnitType, ctx.module_key)) }
    if kind == 1 {
        let binding = h_pattern_plan_binding(plan)
        let slot = ensure_binder(ctx, binding.slot, binding.ty,
            binder_kind_match_pattern(), false)
        return make_core_binding_pattern(
            type_fact_for(ctx.types, binding.ty, ctx.module_key), slot)
    }
    if kind == 2 {
        let literal = match ast { Pattern::Literal { value, .. } => value,
            _ => panic("Core assembly: literal pattern/plan drifted") }
        let core = match literal {
            LiteralValue::IntVal(v) => make_core_int_literal(v),
            LiteralValue::FloatVal(v) => make_core_float_literal(v),
            LiteralValue::StrVal(v) => make_core_str_literal(v),
            LiteralValue::BoolVal(v) => make_core_bool_literal(v)
        }
        return make_core_literal_pattern(
            type_fact_for(ctx.types, Type::UnitType, ctx.module_key), core)
    }
    if kind == 3 {
        let children = h_pattern_plan_children(plan)
        let ast_children = match ast { Pattern::TuplePattern { elements, .. } => elements,
            _ => panic("Core assembly: tuple pattern/plan drifted") }
        let mut result: List<CorePattern> = []
        let mut index = 0
        while index < children.len() {
            result.push(lower_pattern(ctx, ast_children.get(index).unwrap(),
                children.get(index).unwrap()))
            index = index + 1
        }
        return make_core_tuple_pattern(type_fact_for(
            ctx.types, Type::UnitType, ctx.module_key), result)
    }
    let fields = h_pattern_plan_fields(plan).map(fn(field) {
        make_core_pattern_field(core_field(h_pattern_field_projection(field)),
            lower_pattern(ctx, Pattern::Wildcard { span: span_zero() },
                h_pattern_field_pattern(field)))
    })
    if kind == 4 { make_core_struct_pattern(type_fact_for(
        ctx.types, Type::UnitType, ctx.module_key),
        h_pattern_plan_struct_owner(plan), fields) }
    else if kind == 5 { make_core_variant_pattern(type_fact_for(
        ctx.types, Type::UnitType, ctx.module_key),
        h_pattern_plan_variant(plan), fields) }
    else { panic("Core assembly: OrPattern crossed PreCore") }
}

fn lower_expr(mut ctx: LowerCtx, value: HExpr) -> CoreExpr {
    match value {
        // Unsafe is a checked surface boundary, not a Core semantic node.
        // Elide it before allocating an OriginRef so the diagnostic projection
        // remains exactly bijective with the emitted Core tree.
        HExpr::UnsafeBlock { body, .. } => return lower_expr(ctx, body),
        _ => {}
    }
    let source_span = hexpr_span(value)
    let ty = type_fact_for(ctx.types, hexpr_type(value), ctx.module_key)
    let effects = core_effect_contract_exact(core_effect_contract_from_row(
        ctx.types, hexpr_effects(value), ctx.module_key,
        ctx.effect_parameters, some(executable_origin(ctx.owner))))
    let origin = fresh_origin(ctx, "expr", source_span)
    match value {
        HExpr::IntLit { value, .. } =>
            make_core_literal_expr(ty, origin, make_core_int_literal(value)),
        HExpr::FloatLit { value, .. } =>
            make_core_literal_expr(ty, origin, make_core_float_literal(value)),
        HExpr::StrLit { value, .. } =>
            make_core_literal_expr(ty, origin, make_core_str_literal(value)),
        HExpr::BoolLit { value, .. } =>
            make_core_literal_expr(ty, origin, make_core_bool_literal(value)),
        HExpr::Ident { source_slot: some(slot), .. } => {
            let exact_slot = ensure_binder(
                ctx, slot, hexpr_type(value), binder_kind_let(), false)
            make_core_read_expr(ty, effects, origin, exact_slot)
        },
        HExpr::Ident {
            callee_identity: some(callee), dict_closure_dicts,
            ty: source_ty, ..
        } => {
            if !callee_ref_is_named(callee) {
                panic("Core assembly: non-local callable identity is not named")
            }
            match source_ty {
                Type::FnType { .. } => make_core_callable_value_expr(
                    ty, origin, make_named_executable_ref(
                        callee_ref_named_symbol(callee)),
                    match dict_closure_dicts {
                        some(values) => evidence(ctx, values), none => []
                    }),
                _ => panic("Core assembly: non-callable exact Ident was not elaborated")
            }
        },
        HExpr::Ident { .. } => panic("Core assembly: Ident lacks exact identity"),
        HExpr::UnaryOp { op, operand, .. } => make_core_primitive_expr(
            ty, effects, origin,
            make_core_primitive_op(match op { UnaryOp::Neg => 5, UnaryOp::Not => 6 }),
            [lower_expr(ctx, operand)]),
        HExpr::BinOp { op, left, right, eq_plan, ord_plan, .. } => {
            let plan = match op {
                BinOp::Eq | BinOp::Neq => eq_plan,
                BinOp::Lt | BinOp::Lte | BinOp::Gt | BinOp::Gte => ord_plan,
                _ => none
            }
            match plan {
                some(exact) => {
                    if h_operator_is_tuple(exact) {
                        panic("Core assembly: tuple operator plan needs Core elaboration")
                    }
                    let method = h_operator_method_ref(exact)
                    let signature = method_call_ref_signature(method)
                    let method_evidence: List<CoreEvidenceRef> =
                        if method_call_ref_is_bound(method) {
                        [make_core_dict_evidence(remap_dictionary_evidence(
                            ctx, dict_ref_exact(
                                method_call_ref_bound_evidence(method))))]
                    } else { [] }
                    let lowered_left = lower_expr(ctx, left)
                    let lowered_right = lower_expr(ctx, right)
                    match op {
                        BinOp::Lt | BinOp::Lte | BinOp::Gt | BinOp::Gte => {
                            // Ord.cmp returns Int.  Preserve that exact method
                            // authority, then apply the source relation to zero
                            // as an existing Core primitive; never pretend the
                            // callable itself returns Bool.
                            let int_type = type_fact_for(
                                ctx.types, Type::IntType, ctx.module_key)
                            let comparison = make_core_method_call_expr(
                                int_type, effects,
                                fresh_origin(ctx, "ordering-cmp", source_span),
                                core_callee(
                                    ctx,
                                    method_call_ref_callee_identity(method),
                                    signature),
                                exact_method_ref(method), lowered_left,
                                [lowered_right], method_evidence, [])
                            let zero = make_core_literal_expr(
                                int_type,
                                fresh_origin(ctx, "ordering-zero", source_span),
                                make_core_int_literal(0))
                            make_core_primitive_expr(
                                ty, effects, origin,
                                make_core_primitive_op(primitive_tag(op)),
                                [comparison, zero])
                        },
                        _ => make_core_method_call_expr(
                            ty, effects, origin,
                            core_callee(
                                ctx, method_call_ref_callee_identity(method),
                                signature),
                            exact_method_ref(method), lowered_left,
                            [lowered_right], method_evidence, [])
                    }
                },
                none => make_core_primitive_expr(
                    ty, effects, origin, make_core_primitive_op(primitive_tag(op)),
                    [lower_expr(ctx, left), lower_expr(ctx, right)])
            }
        },
        HExpr::Call {
            callee, args, resolved_dicts, handled_evidence, callee_ref,
            method_ref, system_host, ..
        } => match system_host {
            some(host) => {
                if handled_evidence.len() != 0 {
                    panic("Core assembly: system call carries handled evidence")
                }
                make_core_system_call_expr(
                    ty, effects, origin, host,
                    args.map(fn(v) { lower_expr(ctx, v) }))
            },
            none => match method_ref {
                some(method) => {
                    let receiver = match callee {
                        HExpr::FieldAccess { receiver, .. } => receiver,
                        _ => panic("Core assembly: method call lacks receiver")
                    }
                    make_core_method_call_expr(
                        ty, effects, origin,
                        core_callee(ctx, method_call_ref_callee_identity(method),
                            method_call_ref_signature(method)),
                        exact_method_ref(method), lower_expr(ctx, receiver),
                        args.map(fn(v) { lower_expr(ctx, v) }),
                        if method_call_ref_is_bound(method) {
                            [make_core_dict_evidence(remap_dictionary_evidence(
                                ctx, dict_ref_exact(
                                    method_call_ref_bound_evidence(method))))]
                        } else { evidence(ctx, resolved_dicts) },
                        handled_evidence.map(fn(value) {
                            core_handled_use(ctx.handled_evidence_types, value)
                        }))
                },
                none => {
                    let exact = match callee_ref { some(v) => v,
                        none => panic("Core assembly: Call lacks CalleeRef") }
                    make_core_call_expr(
                        ty, effects, origin,
                        core_callee(ctx, exact, hexpr_type(callee)),
                        args.map(fn(v) { lower_expr(ctx, v) }),
                        evidence(ctx, resolved_dicts),
                        handled_evidence.map(fn(value) {
                            core_handled_use(ctx.handled_evidence_types, value)
                        }))
                }
            }
        },
        HExpr::FieldAccess { receiver, projection: some(p), .. } => {
            let field = lower_access_field(ctx, p, receiver)
            make_core_project_expr(ty, effects, origin,
                lower_expr(ctx, receiver), field, false)
        },
        HExpr::FieldAccess { .. } =>
            panic("Core assembly: field access lacks exact projection"),
        HExpr::StructLit { owner_ref, fields, constructor: some(plan), spread, .. } => {
            if h_constructor_kind(plan) != 2 ||
               h_constructor_fields(plan).len() != fields.len() {
                panic("Core assembly: struct literal is not field-complete")
            }
            match spread {
                some(base) => {
                    let schema = lower_struct_update_schema(ctx, ty)
                    let constructor = make_core_struct_constructor(
                        owner_ref, schema.map(fn(fact) {
                            flow_field_identity_nominal(
                                flow_nominal_field_identity(fact))
                        }))
                    let mut inputs: List<LowerUpdateInput> = []
                    for field in fields {
                        inputs.push(LowerUpdateInput {
                            field: make_core_nominal_field(field.field_ref),
                            value: field.value
                        })
                    }
                    lower_named_update(
                        ctx, ty, effects, origin, base, inputs,
                        schema, constructor)
                },
                none => make_core_construct_expr(ty, effects, origin,
                    make_core_struct_constructor(
                        owner_ref, fields.map(fn(field) { field.field_ref })),
                    fields.map(fn(field) { make_core_field_value(
                        make_core_nominal_field(field.field_ref),
                        lower_expr(ctx, field.value)) }))
            }
        },
        HExpr::NamedVariantConstruct {
            variant_ref, fields, constructor: some(plan), spread, ..
        } => {
            if h_constructor_kind(plan) != 0 {
                panic("Core assembly: variant literal is not payload-complete")
            }
            let constructor = make_core_variant_constructor(
                variant_ref, h_constructor_executable(plan))
            match spread {
                some(base) => {
                    let schema = lower_variant_update_schema(
                        ctx, ty, variant_ref)
                    let mut inputs: List<LowerUpdateInput> = []
                    for field in fields {
                        inputs.push(LowerUpdateInput {
                            field: make_core_variant_field(field.field_ref),
                            value: field.value
                        })
                    }
                    lower_named_update(
                        ctx, ty, effects, origin, base, inputs,
                        schema, constructor)
                },
                none => make_core_construct_expr(ty, effects, origin,
                    constructor,
                    fields.map(fn(field) { make_core_field_value(
                        make_core_variant_field(field.field_ref),
                        lower_expr(ctx, field.value)) }))
            }
        },
        HExpr::StructLit { .. } | HExpr::NamedVariantConstruct { .. } =>
            panic("Core assembly: nominal constructor carrier is partial"),
        HExpr::TupleLit { elements, constructor: some(plan), .. } => {
            if h_constructor_kind(plan) != 1 ||
               h_constructor_tuple_arity(plan) != elements.len() {
                panic("Core assembly: tuple constructor contract differs")
            }
            let mut index = 0
            make_core_construct_expr(ty, effects, origin,
                make_core_tuple_constructor(elements.len()),
                elements.map(fn(item) {
                    let result = make_core_field_value(
                        make_core_tuple_field(index), lower_expr(ctx, item))
                    index = index + 1; result
                }))
        },
        HExpr::TupleLit { .. } =>
            panic("Core assembly: tuple constructor carrier is partial"),
        HExpr::Block { stmts, tail, span } => make_core_block_expr(
            ty, effects, origin, lower_block(ctx, stmts, tail, span)),
        HExpr::IfExpr { condition, then_branch, else_branch, .. } =>
            make_core_if_expr(ty, effects, origin,
                lower_expr(ctx, condition), block_from_expr(ctx, then_branch),
                block_from_expr(ctx, match else_branch { some(v) => v,
                    none => panic("Core assembly: If lacks else after PreCore") })),
        HExpr::MatchExpr { scrutinee, arms, .. } => make_core_match_expr(
            ty, effects, origin, lower_expr(ctx, scrutinee),
            arms.map(fn(arm) { lower_arm(ctx, arm, false) })),
        HExpr::TryCatch { body, arms, .. } => {
            let error = match arms.get(0) {
                some(arm) => match arm.bindings.get(0) {
                    some(binding) => binding.slot,
                    none => panic("Core assembly: catch lacks error binder")
                },
                none => panic("Core assembly: catch has no arms")
            }
            make_core_try_catch_expr(ty, effects, origin,
                block_from_expr(ctx, body), error,
                arms.map(fn(arm) { lower_arm(ctx, arm, true) }))
        },
        HExpr::HandleExpr {
            body, handlers, installed_evidence, span
        } => make_core_handle_expr(
            ty, effects, origin, block_from_expr(ctx, body),
            lower_handler_installations(
                ctx, installed_evidence, handlers, span)),
        HExpr::Lambda {
            executable_ref, captures, evidence_captures, ..
        } => make_core_lambda_expr(
            ty, effects, origin, executable_ref,
            captures.map(fn(c) {
                make_core_capture(resolved_slot(ctx, c.source), c.target)
            }), evidence_captures.map(fn(value) {
                core_handled_capture(ctx.handled_evidence_types, value)
            })),
        HExpr::EffectOp {
            operation_ref: some(op), handled_evidence, args, ..
        } =>
            make_core_effect_call_expr(ty, effects, origin, op,
                args.map(fn(v) { lower_expr(ctx, v) }), [],
                handled_evidence.map(fn(value) {
                    core_handled_use(ctx.handled_evidence_types, value)
                })),
        HExpr::EffectOp {
            fail_ref: some(fail_ref), handled_evidence, args, ..
        } => {
            let _ = h_fail_operation_tag(fail_ref)
            if handled_evidence.len() != 0 {
                panic("Core assembly: fail.raise carries handled evidence")
            }
            if args.len() != 1 { panic("Core assembly: fail.raise arity differs") }
            make_core_fail_raise_expr(
                ty, effects, origin, lower_expr(ctx, args.get(0).unwrap()))
        },
        HExpr::EffectOp { .. } =>
            panic("Core assembly: effect operation carrier is ambiguous"),
        HExpr::UnsafeBlock { .. } =>
            panic("Core assembly: UnsafeBlock was not elided before lowering"),
        HExpr::ReturnExpr { value, .. } => make_core_block_expr(
            ty, effects, origin, make_core_block(
                [make_core_return_stmt(value.map(fn(v) { lower_expr(ctx, v) }), origin)],
                none, origin)),
        HExpr::StringInterp { .. } | HExpr::ListLit { .. } |
        HExpr::IndexExpr { .. } |
        HExpr::DictConstruct { .. } | HExpr::Clone { .. } |
        HExpr::Take { .. } => panic("Core assembly: surface/resource HExpr crossed PreCore")
    }
}

fn block_from_expr(ctx: LowerCtx, value: HExpr) -> CoreBlock {
    let span = hexpr_span(value)
    match value {
        HExpr::Block { stmts, tail, .. } => lower_block(ctx, stmts, tail, span),
        _ => make_core_block([], some(lower_expr(ctx, value)),
            fresh_origin(ctx, "block", span))
    }
}

fn lower_arm(ctx: LowerCtx, value: HMatchArm, is_catch: Bool) -> CoreMatchArm {
    let span = value.span
    let plan = match value.pattern_plan { some(v) => v,
        none => panic("Core assembly: match arm lacks exact pattern") }
    for binding in value.bindings {
        let _ = ensure_binder(ctx, binding.slot, binding.ty,
            if is_catch { binder_kind_catch_pattern() }
            else { binder_kind_match_pattern() }, false)
    }
    let expected = match value.bindings.get(0) {
        some(binding) => binding.ty,
        none => Type::UnitType
    }
    make_core_match_arm(
        lower_pattern(ctx, value.pattern, plan),
        value.guard.map(fn(v) { lower_expr(ctx, v) }),
        block_from_expr(ctx, value.body), fresh_origin(ctx, "arm", span))
}

fn lower_handler_operation(
    ctx: LowerCtx, value: HEffectHandler
) -> CoreHandlerOperation {
    let source_span = hexpr_span(value.body)
    let operation = match value.operation_ref { some(v) => v,
        none => panic("Core assembly: dedicated fail handler crossed Handle") }
    let mut params: List<SlotRef> = []
    for param in value.params {
        let id = match param.def_id { some(v) => v,
            none => panic("Core assembly: handler parameter lacks DefId") }
        // Handler parameters belong exclusively to the child executable.  The
        // enclosing Handle expression carries only their exact interface refs.
        params.push(source_slot(ctx.module_key, id))
    }
    let resume = value.resume_binding.map(fn(binding) { binding.slot })
    make_core_handler_operation(
        operation, value.executable_ref, params, resume,
        value.captures.map(fn(capture) {
            make_core_capture(
                resolved_slot(ctx, capture.source), capture.target)
        }),
        value.evidence_captures.map(fn(capture) {
            core_handled_capture(ctx.handled_evidence_types, capture)
        }), fresh_origin(ctx, "handler", source_span))
}

fn lower_handler_installations(
    mut ctx: LowerCtx, installed: List<HandledEvidenceRef>,
    handlers: List<HEffectHandler>, source_span: Span
) -> List<CoreHandlerInstallation> {
    let mut result: List<CoreHandlerInstallation> = []
    for evidence_ref in installed {
        activate_handled_evidence_binder(ctx, evidence_ref)
        let requirement = handled_evidence_requirement(evidence_ref)
        let mut operations: List<CoreHandlerOperation> = []
        for handler in handlers {
            match handler.handled_ref {
                some(reference) => if handled_effect_ref_same(
                        reference, requirement) {
                    operations.push(lower_handler_operation(ctx, handler))
                },
                none => panic(
                    "Core assembly: dedicated fail handler crossed Handle")
            }
        }
        operations.sort_by(fn(left, right) {
            effect_operation_ref_source_index(
                core_handler_operation_ref(left)) -
                effect_operation_ref_source_index(
                    core_handler_operation_ref(right))
        })
        result.push(make_core_handler_installation(
            core_handled_binding(ctx.handled_evidence_types, evidence_ref),
            operations, fresh_origin(ctx, "installation", source_span)))
    }
    result
}

fn lower_place(ctx: LowerCtx, value: HExpr) -> CorePlaceRef {
    match value {
        HExpr::Ident { source_slot: some(slot), ty, .. } =>
            make_core_slot_place(ensure_binder(
                ctx, slot, ty, binder_kind_let(), false)),
        HExpr::FieldAccess { receiver, projection: some(p), ty, .. } => {
            let field = lower_access_field(ctx, p, receiver)
            make_core_project_place(lower_expr(ctx, receiver), field,
                type_fact_for(ctx.types, ty, ctx.module_key))
        },
        _ => panic("Core assembly: assignment target is not exact place")
    }
}

fn lower_stmt(ctx: LowerCtx, value: HStmt) -> CoreStmt {
    let origin = fresh_origin(ctx, "stmt", hstmt_source_span(value))
    match value {
        HStmt::Let { def_id: some(id), ty, init, .. } => {
            let slot = source_slot(ctx.module_key, id)
            let exact_slot = ensure_binder(
                ctx, slot, ty,
                if id < 0 { binder_kind_dictionary_evidence_local() }
                else { binder_kind_let() }, false)
            make_core_bind_stmt(
                exact_slot, lower_expr(ctx, init), false, origin)
        },
        HStmt::Var { def_id: some(id), ty, init, .. } => {
            let slot = source_slot(ctx.module_key, id)
            let exact_slot = ensure_binder(
                ctx, slot, ty, binder_kind_var(), true)
            make_core_bind_stmt(
                exact_slot, lower_expr(ctx, init), true, origin)
        },
        HStmt::Assign { target, value, .. } =>
            make_core_assign_stmt(lower_place(ctx, target), lower_expr(ctx, value), origin),
        HStmt::ExprStmt { expr, .. } => make_core_expr_stmt(lower_expr(ctx, expr), origin),
        HStmt::Return { value, .. } =>
            make_core_return_stmt(value.map(fn(v) { lower_expr(ctx, v) }), origin),
        HStmt::While { condition, body, .. } =>
            make_core_while_stmt(lower_expr(ctx, condition), block_from_expr(ctx, body), origin),
        HStmt::Break { .. } => make_core_break_stmt(origin),
        HStmt::Continue { .. } => make_core_continue_stmt(origin),
        HStmt::ForIn { .. } | HStmt::LetDestructure { .. } |
        HStmt::IfLet { .. } | HStmt::Drop { .. } =>
            panic("Core assembly: surface/resource HStmt crossed PreCore"),
        _ => panic("Core assembly: binding lacks DefId")
    }
}

fn lower_block(
    ctx: LowerCtx, stmts: List<HStmt>, tail: HExpr?, source_span: Span
) -> CoreBlock {
    make_core_block(stmts.map(fn(s) { lower_stmt(ctx, s) }),
        tail.map(fn(v) { lower_expr(ctx, v) }),
        fresh_origin(ctx, "block", source_span))
}

struct ModuleAssembly {
    callables: List<CoreCallableContract>, impls: List<CoreImplMetadata>,
    entries: List<ExecutableEntry>, bodies: List<CoreBodyEntry>,
    diagnostic_origins: List<CoreDiagnosticOriginFact>
}
fn empty_module_assembly() -> ModuleAssembly {
    ModuleAssembly {
        callables: [], impls: [], entries: [], bodies: [],
        diagnostic_origins: []
    }
}

fn append_lowered_diagnostic_origins(
    mut assembly: ModuleAssembly, values: List<CoreDiagnosticOriginFact>
) {
    for value in values {
        append_project_diagnostic_origin(assembly.diagnostic_origins, value)
    }
}

fn append_generated_body_diagnostic_origins(
    facts: FrozenCoreAssemblyFacts, reference: ExecutableRef,
    body: CoreBody, mut assembly: ModuleAssembly
) {
    let source = diagnostic_owner_for(
        facts.diagnostic_seed.owners, reference)
    for origin in core_body_origins(body) {
        append_project_diagnostic_origin(
            assembly.diagnostic_origins, CoreDiagnosticOriginFact {
                origin: origin, owner: reference,
                module_key: source.module_key, span: source.span
            })
    }
}

fn append_body_owner_diagnostic_origin(
    facts: FrozenCoreAssemblyFacts, reference: ExecutableRef,
    mut assembly: ModuleAssembly
) {
    let source = diagnostic_owner_for(
        facts.diagnostic_seed.owners, reference)
    append_project_diagnostic_origin(
        assembly.diagnostic_origins, CoreDiagnosticOriginFact {
            origin: executable_origin(reference), owner: reference,
            module_key: source.module_key, span: source.span
        })
}
fn parameter_roles(params: List<HParam>) -> List<FlowSemanticRole> {
    params.map(fn(p) { if p.is_mutable { flow_semantic_role_mutate() }
        else { flow_semantic_role_read() } })
}
fn read_roles(count: Int) -> List<FlowSemanticRole> {
    let mut result: List<FlowSemanticRole> = []
    for _ in 0..count { result.push(flow_semantic_role_read()) }
    result
}

fn flow_role_from_resource_fact(
    value: CallableResourceRoleFact
) -> FlowSemanticRole {
    let tag = callable_resource_role_tag(value)
    if tag == 0 { return flow_semantic_role_read() }
    if tag == 1 { return flow_semantic_role_mutate() }
    if tag == 2 { return flow_semantic_role_consume() }
    if tag == 3 { return flow_semantic_role_force() }
    panic("Core assembly: callable resource role is invalid")
}

fn flow_contract_from_resource_fact(
    module_key: Str, parameter_types: List<CoreTypeRef>,
    result_type: CoreTypeRef, resource: CallableResourceContractFact
) -> FlowCallContract {
    let roles = callable_resource_contract_parameter_roles(resource)
    if roles.len() != parameter_types.len() {
        panic("Core assembly: callable resource contract arity differs")
    }
    let aliases = callable_resource_contract_result_alias_ordinals(resource)
    make_module_flow_call_contract(
        module_key,
        parameter_types.map(fn(ty) {
            make_core_type_ref(core_type_ref_index(ty))
        }),
        roles.map(fn(role) { flow_role_from_resource_fact(role) }),
        make_core_type_ref(core_type_ref_index(result_type)),
        flow_role_from_resource_fact(
            callable_resource_contract_result_role(resource)),
        if aliases.len() == 0 { make_fresh_flow_value_origin() }
        else { make_aliasing_flow_value_origin(aliases) })
}
fn callable_contract(
    facts: FrozenCoreAssemblyFacts, reference: ExecutableRef,
    params: List<HParam>, result: Type, effects: EffectRow,
    mode: ExecutableContractMode,
    handled_evidence: List<HandledEvidenceRef>
) -> CoreCallableContract {
    let parameter_types = params.map(fn(p) {
        type_fact_for(facts.type_sources, p.ty, facts.module_key)
    })
    let result_type = type_fact_for(facts.type_sources, result, facts.module_key)
    let slots: List<SlotRef> = if executable_contract_mode_same(
            mode, executable_contract_mode_concrete_body()) {
        params.map(fn(p) { source_slot(facts.module_key,
            match p.def_id { some(v) => v,
                none => panic("Core assembly: callable parameter lacks DefId") }) })
    } else { [] }
    make_core_callable_contract(reference, executable_origin(reference),
        slots, mode,
        make_module_flow_call_contract(facts.module_key,
            parameter_types.map(fn(t) { make_core_type_ref(core_type_ref_index(t)) }),
            parameter_roles(params), make_core_type_ref(core_type_ref_index(result_type)),
            flow_semantic_role_read(), make_fresh_flow_value_origin()),
        core_effect_contract_from_row(
            facts.type_sources, effects, facts.module_key,
            facts.effect_parameters, some(executable_origin(reference))),
        handled_evidence.map(fn(value) {
            core_handled_binding(facts.handled_evidence_types, value)
        }))
}
fn add_builtin_method_contracts(
    facts: FrozenCoreAssemblyFacts, mut assembly: ModuleAssembly
) {
    if facts.module_order != 0 {
        if facts.builtin_methods.len() != 0 {
            panic("Core assembly: non-root module carries builtin contracts")
        }
        return
    }
    if facts.builtin_methods.len() != BUILTIN_METHOD_SITE_COUNT {
        panic("Core assembly: builtin method contract census differs")
    }
    let parent = make_module_body_parent(make_module_body_ref(
        "$builtin", "builtin-methods"))
    let mut index = 0
    while index < facts.builtin_methods.len() {
        let fact = facts.builtin_methods.get(index).unwrap()
        let intrinsic = builtin_method_contract_intrinsic(fact)
        let mut prior = 0
        while prior < index {
            if intrinsic_ref_same(
                    intrinsic,
                    builtin_method_contract_intrinsic(
                        facts.builtin_methods.get(prior).unwrap())) {
                panic("Core assembly: builtin method contract repeats")
            }
            prior = prior + 1
        }
        let scheme = builtin_method_contract_scheme(fact)
        let (params, result, effects) = match scheme.ty {
            Type::FnType { params, return_type, effects } =>
                (params, return_type, effects),
            _ => panic("Core assembly: builtin method scheme is not callable")
        }
        let parameter_types = params.map(fn(ty) {
            type_fact_for(facts.type_sources, ty, facts.module_key)
        })
        let result_type = type_fact_for(
            facts.type_sources, result, facts.module_key)
        let reference = make_named_executable_ref(
            intrinsic_ref_symbol(intrinsic))
        assembly.entries.push(make_executable_entry(
            reference, parent, executable_kind_builtin_intrinsic(),
            make_contract_only()))
        assembly.callables.push(make_core_callable_contract(
            reference,
            make_symbol_origin_ref(intrinsic_ref_symbol(intrinsic)),
            [], executable_contract_mode_contract_only(),
            flow_contract_from_resource_fact(
                facts.module_key, parameter_types, result_type,
                builtin_method_contract_resource(fact)),
            core_effect_contract_from_row(
                facts.type_sources, effects, facts.module_key,
                facts.effect_parameters, some(executable_origin(reference))),
            []))
        index = index + 1
    }
}

fn typed_callable_contract(
    facts: FrozenCoreAssemblyFacts, reference: ExecutableRef,
    parameter_types_in: List<Type>, parameter_slots: List<SlotRef>,
    parameter_mutabilities: List<Bool>, result: Type,
    effects: EffectRow, mode: ExecutableContractMode,
    handled: List<HandledEvidenceRef>
) -> CoreCallableContract {
    if parameter_types_in.len() != parameter_mutabilities.len() {
        panic("Core assembly: typed callable mutability arity differs")
    }
    let parameter_types = parameter_types_in.map(fn(ty) {
        type_fact_for(facts.type_sources, ty, facts.module_key)
    })
    let result_type = type_fact_for(
        facts.type_sources, result, facts.module_key)
    let mut roles: List<FlowSemanticRole> = []
    for mutable in parameter_mutabilities {
        roles.push(if mutable {
            flow_semantic_role_mutate()
        } else { flow_semantic_role_read() })
    }
    make_core_callable_contract(
        reference, executable_origin(reference),
        if executable_contract_mode_same(
                mode, executable_contract_mode_concrete_body()) {
            parameter_slots
        } else { [] }, mode,
        make_module_flow_call_contract(
            facts.module_key,
            parameter_types.map(fn(ty) {
                make_core_type_ref(core_type_ref_index(ty))
            }), roles, make_core_type_ref(core_type_ref_index(result_type)),
            flow_semantic_role_read(), make_fresh_flow_value_origin()),
        core_effect_contract_from_row(
            facts.type_sources, effects, facts.module_key,
            facts.effect_parameters, some(executable_origin(reference))),
        handled.map(fn(value) {
            core_handled_binding(facts.handled_evidence_types, value)
        }))
}

fn core_parameter_binders(
    facts: FrozenCoreAssemblyFacts, entries: List<BinderEntry>,
    types: List<Type>, mutabilities: List<Bool>
) -> List<CoreBinder> {
    if entries.len() != types.len() || entries.len() != mutabilities.len() {
        panic("Core assembly: generated parameter fact census differs")
    }
    let mut result: List<CoreBinder> = []
    let mut index = 0
    while index < entries.len() {
        let entry = entries.get(index).unwrap()
        result.push(make_core_binder(
            binder_entry_slot(entry),
            type_fact_for(
                facts.type_sources, types.get(index).unwrap(),
                facts.module_key),
            binder_entry_kind(entry), binder_entry_site(entry),
            flow_own_storage(), mutabilities.get(index).unwrap()))
        index = index + 1
    }
    result
}

fn append_handled_core_binders(
    facts: FrozenCoreAssemblyFacts, values: List<HandledEvidenceRef>,
    mut binders: List<CoreBinder>
) {
    for value in values {
        let binding = handled_evidence_binding(value)
        binders.push(make_core_binder(
            binder_entry_slot(binding),
            handled_evidence_type_for(
                facts.handled_evidence_types,
                handled_evidence_requirement(value)),
            binder_entry_kind(binding), binder_entry_site(binding),
            flow_borrow_storage(), false))
    }
}

fn delegate_field_type_in_decls(
    values: List<HDecl>, field: NominalFieldRef
) -> Type? {
    for value in values {
        match value {
            HDecl::Struct { fields, .. } => {
                for candidate in fields {
                    if nominal_field_ref_same(candidate.field_ref, field) {
                        return some(candidate.ty)
                    }
                }
            },
            HDecl::ModBlock { decls, .. } => match
                    delegate_field_type_in_decls(decls, field) {
                some(found) => return some(found), none => {}
            },
            _ => {}
        }
    }
    none
}

fn tail_types(values: List<Type>) -> List<Type> {
    let mut result: List<Type> = []
    let mut index = 1
    while index < values.len() {
        result.push(values.get(index).unwrap()); index = index + 1
    }
    result
}
fn tail_slots(values: List<SlotRef>) -> List<SlotRef> {
    let mut result: List<SlotRef> = []
    let mut index = 1
    while index < values.len() {
        result.push(values.get(index).unwrap()); index = index + 1
    }
    result
}
fn tail_core_exprs(values: List<CoreExpr>) -> List<CoreExpr> {
    let mut result: List<CoreExpr> = []
    let mut index = 1
    while index < values.len() {
        result.push(values.get(index).unwrap()); index = index + 1
    }
    result
}

fn append_default_specialization(
    facts: FrozenCoreAssemblyFacts, module_body: ModuleBodyRef,
    plan: HDefaultSpecializationPlan, mut assembly: ModuleAssembly
) -> ImplMethodRef {
    let reference = h_default_specialization_generated_executable(plan)
    let generated_method = h_default_specialization_generated_method(plan)
    if !impl_owner_ref_same(
            h_default_specialization_owner(plan),
            impl_method_ref_owner(generated_method)) {
        panic("Core assembly: default specialization owner differs")
    }
    let parameter_types = h_default_specialization_parameter_types(plan)
    let entries = h_default_specialization_binders(plan)
    let parameter_slots = entries.map(fn(entry) { binder_entry_slot(entry) })
    let forward = h_default_specialization_forward_call(plan)
    let handled = h_exact_call_handled_evidence(forward)
    let mutabilities = h_default_specialization_parameter_mutabilities(plan)
    let mut binders = core_parameter_binders(
        facts, entries, parameter_types, mutabilities)
    append_handled_core_binders(facts, handled, binders)
    let signature = Type::FnType {
        params: parameter_types,
        return_type: h_default_specialization_result_type(plan),
        effects: h_default_specialization_effects(plan)
    }
    let forward_signature = h_exact_call_signature(forward)
    if !types_equal(signature, forward_signature) {
        panic("Core assembly: default forward signature differs")
    }
    let call_ctx = LowerCtx {
        module_key: facts.module_key, owner: reference,
        effect_parameters: facts.effect_parameters,
        project_callable_effects: facts.project_callable_effects,
        project_type_mapping: facts.project_type_mapping,
        types: facts.type_sources, type_nodes: facts.type_nodes,
        handled_evidence_types: facts.handled_evidence_types,
        binders: binders, captures: [], next_origin: 0,
        diagnostic_origins: []
    }
    let callee = core_callee(
        call_ctx, h_exact_call_callee(forward), forward_signature)
    let arguments = parameter_slots.map(fn(slot) {
        let mut found: CoreTypeRef? = none
        for binder in binders {
            if slot_ref_same(core_binder_reference(binder), slot) {
                found = some(core_binder_type(binder))
            }
        }
        make_core_read_expr(
            match found {
                some(value) => value,
                none => panic("Core assembly: default parameter binder absent")
            }, make_core_effect_set([]), executable_origin(reference), slot)
    })
    let evidence = h_exact_call_evidence(forward).map(fn(value) {
        make_core_dict_evidence(dict_ref_exact(value))
    })
    let handled_uses = handled.map(fn(value) {
        core_handled_use(facts.handled_evidence_types, value)
    })
    let call = match h_exact_call_method(forward) {
        some(method) => {
            if arguments.len() == 0 {
                panic("Core assembly: default method call lacks receiver")
            }
            make_core_method_call_expr(
                type_fact_for(
                    facts.type_sources,
                    h_default_specialization_result_type(plan),
                    facts.module_key),
                core_effects(
                    facts.type_sources,
                    h_default_specialization_effects(plan), facts.module_key),
                executable_origin(reference), callee, exact_method_ref(method),
                arguments.get(0).unwrap(), tail_core_exprs(arguments),
                evidence, handled_uses)
        },
        none => make_core_call_expr(
            type_fact_for(
                facts.type_sources,
                h_default_specialization_result_type(plan), facts.module_key),
            core_effects(
                facts.type_sources,
                h_default_specialization_effects(plan), facts.module_key),
            executable_origin(reference), callee, arguments,
            evidence, handled_uses)
    }
    let body = elaborate_core_default_specialization(
        make_core_ordinary_body_plan(
            reference, executable_origin(reference), binders,
            parameter_slots,
            type_fact_for(
                facts.type_sources,
                h_default_specialization_result_type(plan), facts.module_key),
            [], some(call), executable_origin(reference)))
    assembly.entries.push(make_executable_entry(
        reference, make_module_body_parent(module_body),
        executable_kind_default_specialization(),
        make_concrete_body_contract(body_anchor(reference))))
    assembly.callables.push(typed_callable_contract(
        facts, reference, parameter_types, parameter_slots,
        mutabilities, h_default_specialization_result_type(plan),
        h_default_specialization_effects(plan),
        executable_contract_mode_concrete_body(), handled))
    append_generated_body_diagnostic_origins(
        facts, reference, body, assembly)
    assembly.bodies.push(make_core_body_entry(
        reference, executable_origin(reference), body_anchor(reference), body))
    generated_method
}

fn derived_core_field(value: DerivedFieldRef) -> CoreFieldRef {
    match value {
        DerivedFieldRef::NominalDerivedField(field) =>
            make_core_nominal_field(field),
        DerivedFieldRef::VariantDerivedField(field) =>
            make_core_variant_field(field)
    }
}

fn derived_call_plan_from_method(
    facts: FrozenCoreAssemblyFacts, owner: ExecutableRef,
    method: MethodCallRef, evidence_values: List<DictRef>,
    handled: List<HandledEvidenceRef>, origin: OriginRef
) -> CoreDerivedCallPlan {
    let signature = method_call_ref_signature(method)
    let (parameters, result, effects) = match signature {
        Type::FnType { params, return_type, effects } =>
            (params, return_type, effects),
        _ => panic("Core assembly: derived method is not callable")
    }
    let ctx = LowerCtx {
        module_key: facts.module_key, owner: owner,
        effect_parameters: facts.effect_parameters,
        project_callable_effects: facts.project_callable_effects,
        project_type_mapping: facts.project_type_mapping,
        types: facts.type_sources, type_nodes: facts.type_nodes,
        handled_evidence_types: facts.handled_evidence_types,
        binders: [], captures: [], next_origin: 0,
        diagnostic_origins: []
    }
    make_core_derived_call_plan(
        core_callee(ctx, method_call_ref_callee_identity(method), signature),
        some(exact_method_ref(method)),
        type_fact_for(facts.type_sources, result, facts.module_key),
        core_effect_contract_exact(core_effect_contract_from_row(
            facts.type_sources, effects, facts.module_key,
            ctx.effect_parameters, none)),
        evidence_values.map(fn(value) {
            make_core_dict_evidence(dict_ref_exact(value))
        }),
        handled.map(fn(value) {
            core_handled_use(facts.handled_evidence_types, value)
        }), origin)
}

fn derived_call_plan_from_exact(
    facts: FrozenCoreAssemblyFacts, owner: ExecutableRef,
    exact: HExactCallPlan, origin: OriginRef
) -> CoreDerivedCallPlan {
    let signature = h_exact_call_signature(exact)
    let (parameters, result, effects) = match signature {
        Type::FnType { params, return_type, effects } =>
            (params, return_type, effects),
        _ => panic("Core assembly: derived exact call is not callable")
    }
    let ctx = LowerCtx {
        module_key: facts.module_key, owner: owner,
        effect_parameters: facts.effect_parameters,
        project_callable_effects: facts.project_callable_effects,
        project_type_mapping: facts.project_type_mapping,
        types: facts.type_sources, type_nodes: facts.type_nodes,
        handled_evidence_types: facts.handled_evidence_types,
        binders: [], captures: [], next_origin: 0,
        diagnostic_origins: []
    }
    make_core_derived_call_plan(
        core_callee(ctx, h_exact_call_callee(exact), signature),
        h_exact_call_method(exact).map(fn(value) { exact_method_ref(value) }),
        type_fact_for(facts.type_sources, result, facts.module_key),
        core_effect_contract_exact(core_effect_contract_from_row(
            facts.type_sources, effects, facts.module_key,
            ctx.effect_parameters, none)),
        h_exact_call_evidence(exact).map(fn(value) {
            make_core_dict_evidence(dict_ref_exact(value))
        }),
        h_exact_call_handled_evidence(exact).map(fn(value) {
            core_handled_use(facts.handled_evidence_types, value)
        }), origin)
}

struct DerivedValuePath {
    root: SlotRef, root_type: CoreTypeRef,
    projections: List<CoreFieldRef>, projection_types: List<CoreTypeRef>,
    ty: CoreTypeRef, origin: OriginRef
}
fn core_derived_value(value: DerivedValuePath) -> CoreDerivedValueRef {
    make_core_derived_value_ref(
        value.root, value.root_type, value.projections,
        value.projection_types, value.ty, value.origin)
}
fn extend_derived_value(
    value: DerivedValuePath, field: CoreFieldRef,
    ty: CoreTypeRef, origin: OriginRef
) -> DerivedValuePath {
    let mut projections = value.projections.map(fn(item) { item })
    let mut types = value.projection_types.map(fn(item) { item })
    projections.push(field); types.push(ty)
    DerivedValuePath {
        root: value.root, root_type: value.root_type,
        projections: projections, projection_types: types,
        ty: ty, origin: origin
    }
}

fn append_unique_core_binder(
    mut values: List<CoreBinder>, value: CoreBinder
) {
    for existing in values {
        if slot_ref_same(
                core_binder_reference(existing),
                core_binder_reference(value)) {
            return
        }
    }
    values.push(value)
}

fn derived_generated_result_slot(
    facts: FrozenCoreAssemblyFacts, owner: ExecutableRef,
    ty: CoreTypeRef, path: List<Str>, mut binders: List<CoreBinder>
) -> SlotRef {
    let site = make_path_ref(
        executable_owner(owner), path, path_role_parameter())
    let slot = make_synthetic_slot_ref(site)
    append_unique_core_binder(binders, make_core_binder(
        slot, ty, binder_kind_generated_synthetic_parameter(), site,
        flow_own_storage(), false))
    slot
}

fn core_binder_from_entry(
    facts: FrozenCoreAssemblyFacts, entry: BinderEntry, ty: CoreTypeRef
) -> CoreBinder {
    let _ = facts
    make_core_binder(
        binder_entry_slot(entry), ty, binder_entry_kind(entry),
        binder_entry_site(entry), flow_own_storage(), false)
}

fn build_derived_field_plan(
    facts: FrozenCoreAssemblyFacts, owner: ExecutableRef,
    field: CoreFieldRef, field_type: CoreTypeRef,
    action: FieldAction,
    left: DerivedValuePath, right: DerivedValuePath?,
    handled: List<HandledEvidenceRef>, semantic_tag: Int,
    exact_ord_binder: BinderEntry?, path: List<Str>,
    mut binders: List<CoreBinder>
) -> CoreDerivedFieldPlan {
    match action {
        FieldAction::Call { method_ref, base_dict, extra_dicts } => {
            let mut evidence_values = [base_dict]
            for value in extra_dicts { evidence_values.push(value) }
            let operation = derived_call_plan_from_method(
                facts, owner, method_ref, evidence_values, handled,
                left.origin)
            let result_slot = if semantic_tag == 4 {
                let result_type = match method_call_ref_signature(method_ref) {
                    Type::FnType { return_type, .. } => type_fact_for(
                        facts.type_sources, return_type, facts.module_key),
                    _ => panic("Core assembly: Ord action is not callable")
                }
                match exact_ord_binder {
                    some(entry) => {
                        append_unique_core_binder(
                            binders, core_binder_from_entry(
                                facts, entry, result_type))
                        some(binder_entry_slot(entry))
                    },
                    none => some(derived_generated_result_slot(
                        facts, owner, result_type, path, binders))
                }
            } else { none }
            make_core_derived_field_plan(
                field, field_type, core_derived_value(left),
                right.map(fn(value) { core_derived_value(value) }),
                operation, result_slot)
        },
        FieldAction::Tuple {
            element_types, element_projections, element_actions
        } => {
            if element_types.len() != element_projections.len() ||
               element_types.len() != element_actions.len() {
                panic("Core assembly: derived tuple action census differs")
            }
            let mut fields: List<CoreFieldRef> = []
            let mut types: List<CoreTypeRef> = []
            let mut children: List<CoreDerivedFieldPlan> = []
            let mut index = 0
            while index < element_types.len() {
                let child_field = core_field(
                    element_projections.get(index).unwrap())
                let child_type = type_fact_for(
                    facts.type_sources,
                    element_types.get(index).unwrap(), facts.module_key)
                let mut child_path = path.map(fn(item) { item })
                child_path.push("tuple:${index.to_str()}")
                children.push(build_derived_field_plan(
                    facts, owner, child_field, child_type,
                    element_actions.get(index).unwrap(),
                    extend_derived_value(
                        left, child_field, child_type, left.origin),
                    right.map(fn(value) { extend_derived_value(
                        value, child_field, child_type, value.origin) }),
                    handled, semantic_tag, none, child_path, binders))
                fields.push(child_field); types.push(child_type)
                index = index + 1
            }
            make_core_derived_tuple_field_plan(
                field, field_type, core_derived_value(left),
                right.map(fn(value) { core_derived_value(value) }),
                if semantic_tag == 3 {
                    some(make_core_tuple_constructor(fields.len()))
                } else { none },
                fields, types, children,
                make_core_effect_set([]), left.origin)
        },
        FieldAction::FnLiteral =>
            panic("Core assembly: FnLiteral crossed non-text derive"),
        _ => panic("Core assembly: unresolved derived field action")
    }
}

fn derived_pattern_slot(
    owner: ExecutableRef, ty: CoreTypeRef,
    variant_index: Int, field_index: Int, side: Str,
    mut binders: List<CoreBinder>
) -> SlotRef {
    let site = make_path_ref(
        executable_owner(owner),
        ["derived-pattern:${variant_index}:${field_index}:${side}"],
        path_role_parameter())
    let slot = make_synthetic_slot_ref(site)
    append_unique_core_binder(binders, make_core_binder(
        slot, ty, binder_kind_generated_synthetic_parameter(), site,
        flow_borrow_storage(), false))
    slot
}

fn derived_method_header_parts(
    facts: FrozenCoreAssemblyFacts, method: DerivedMethod
) -> (List<Type>, Type, EffectRow, List<CoreBinder>, List<SlotRef>) {
    let (params, result, effects) = match method.signature {
        Type::FnType { params, return_type, effects } =>
            (params, return_type, effects),
        _ => panic("Core assembly: derived method is not callable")
    }
    let mutabilities = params.map(fn(_) { false })
    let mut binders = core_parameter_binders(
        facts, method.binders, params, mutabilities)
    append_handled_core_binders(
        facts, method.handled_evidence_bindings, binders)
    let slots = method.binders.map(fn(entry) { binder_entry_slot(entry) })
    (params, result, effects, binders, slots)
}

fn derived_struct_fields(
    facts: FrozenCoreAssemblyFacts, method: DerivedMethod,
    source: List<DerivedField>, target_type: CoreTypeRef,
    self_slot: SlotRef, other_slot: SlotRef?, semantic_tag: Int,
    mut binders: List<CoreBinder>
) -> List<CoreDerivedFieldPlan> {
    let mut result: List<CoreDerivedFieldPlan> = []
    let mut index = 0
    for field in source {
        let reference = derived_core_field(field.field_ref)
        let field_type = type_fact_for(
            facts.type_sources, field.ty, facts.module_key)
        let left = DerivedValuePath {
            root: self_slot, root_type: target_type,
            projections: [reference], projection_types: [field_type],
            ty: field_type, origin: executable_origin(method.executable_ref)
        }
        let right = other_slot.map(fn(slot) { DerivedValuePath {
            root: slot, root_type: target_type,
            projections: [reference], projection_types: [field_type],
            ty: field_type, origin: executable_origin(method.executable_ref)
        } })
        result.push(build_derived_field_plan(
            facts, method.executable_ref, reference, field_type,
            field.action, left, right,
            method.handled_evidence_bindings, semantic_tag,
            field.ord_result_binder,
            ["derived-field:${index}"], binders))
        index = index + 1
    }
    result
}

fn derived_enum_plans(
    facts: FrozenCoreAssemblyFacts, method: DerivedMethod,
    variants: List<DerivedVariant>, target_type: CoreTypeRef,
    other_slot: SlotRef?, semantic_tag: Int,
    mut binders: List<CoreBinder>
) -> (List<CoreDerivedVariantPlan>,
      List<CoreDerivedOrdVariantPlan>,
      List<CoreDerivedCloneVariantPlan>) {
    let mut common: List<CoreDerivedVariantPlan> = []
    let mut ord: List<CoreDerivedOrdVariantPlan> = []
    let mut clone: List<CoreDerivedCloneVariantPlan> = []
    let mut variant_index = 0
    for variant in variants {
        let mut left_slots: List<SlotRef> = []
        let mut right_slots: List<SlotRef> = []
        let mut fields: List<CoreDerivedFieldPlan> = []
        let mut field_index = 0
        for field in variant.fields {
            let reference = derived_core_field(field.field_ref)
            let field_type = type_fact_for(
                facts.type_sources, field.ty, facts.module_key)
            let left_slot = derived_pattern_slot(
                method.executable_ref, field_type, variant_index,
                field_index, "left", binders)
            left_slots.push(left_slot)
            let right_path = other_slot.map(fn(_) {
                let slot = derived_pattern_slot(
                    method.executable_ref, field_type, variant_index,
                    field_index, "right", binders)
                right_slots.push(slot)
                DerivedValuePath {
                    root: slot, root_type: field_type,
                    projections: [], projection_types: [], ty: field_type,
                    origin: executable_origin(method.executable_ref)
                }
            })
            fields.push(build_derived_field_plan(
                facts, method.executable_ref, reference, field_type,
                field.action,
                DerivedValuePath {
                    root: left_slot, root_type: field_type,
                    projections: [], projection_types: [], ty: field_type,
                    origin: executable_origin(method.executable_ref)
                }, right_path, method.handled_evidence_bindings,
                semantic_tag, field.ord_result_binder,
                ["derived-variant:${variant_index}:${field_index}"], binders))
            field_index = field_index + 1
        }
        let common_variant = make_core_derived_variant_plan(
            variant.variant_ref, left_slots, right_slots, fields,
            variant.discriminator, executable_origin(method.executable_ref))
        common.push(common_variant)
        if semantic_tag == 4 {
            ord.push(make_core_derived_ord_variant_plan(
                common_variant, fields))
        }
        if semantic_tag == 3 {
            clone.push(make_core_derived_clone_variant_plan(
                variant.variant_ref,
                make_core_variant_constructor(
                    variant.variant_ref,
                    make_named_executable_ref(
                        variant_ref_member(variant.variant_ref))),
                left_slots, fields, executable_origin(method.executable_ref)))
        }
        variant_index = variant_index + 1
    }
    (common, ord, clone)
}

fn elaborate_derived_non_text(
    facts: FrozenCoreAssemblyFacts, derived: DerivedImpl,
    method: DerivedMethod
) -> CoreBody {
    let semantic_tag = derived_semantic_kind_tag(method.semantic_kind)
    let (params, result_type_source, result_effects, binder_values, slots) =
        derived_method_header_parts(facts, method)
    let mut binders = binder_values
    if slots.len() == 0 {
        panic("Core assembly: derived method lacks self")
    }
    let target_type = type_fact_for(
        facts.type_sources, derived.target_type, facts.module_key)
    let other = if semantic_tag == 0 || semantic_tag == 1 || semantic_tag == 4 {
        match slots.get(1) {
            some(value) => some(value),
            none => panic("Core assembly: binary derived method lacks other")
        }
    } else { none }
    let result_type = type_fact_for(
        facts.type_sources, result_type_source, facts.module_key)
    let origin = executable_origin(method.executable_ref)
    let mut struct_fields: List<CoreDerivedFieldPlan> = []
    let mut common_variants: List<CoreDerivedVariantPlan> = []
    let mut ord_variants: List<CoreDerivedOrdVariantPlan> = []
    let mut clone_variants: List<CoreDerivedCloneVariantPlan> = []
    match derived.type_kind {
        TypeKind::StructKind => {
            let fields = match derived.struct_fields {
                some(value) => value,
                none => panic("Core assembly: derived struct fields are absent")
            }
            struct_fields = derived_struct_fields(
                facts, method, fields, target_type,
                slots.get(0).unwrap(), other,
                semantic_tag, binders)
        },
        TypeKind::EnumKind => {
            let variants = match derived.enum_variants {
                some(value) => value,
                none => panic("Core assembly: derived enum variants are absent")
            }
            let built = derived_enum_plans(
                facts, method, variants, target_type, other,
                semantic_tag, binders)
            let (common_built, ord_built, clone_built) = built
            common_variants = common_built
            ord_variants = ord_built
            clone_variants = clone_built
        }
    }
    let header = make_core_derived_header(
        method.executable_ref, origin, binders, slots, result_type,
        slots.get(0).unwrap(), other, origin,
        core_effects(facts.type_sources, result_effects, facts.module_key))
    if semantic_tag == 0 || semantic_tag == 1 {
        let shape = match derived.type_kind {
            TypeKind::StructKind => make_core_derived_struct_shape(
                derived.target_owner, target_type, struct_fields),
            TypeKind::EnumKind => make_core_derived_enum_shape(
                derived.target_owner, target_type, common_variants)
        }
        let plan = make_core_derived_eq_plan(
            header, shape,
            type_fact_for(facts.type_sources, Type::BoolType, facts.module_key))
        return if semantic_tag == 0 {
            elaborate_core_derived_eq_body(plan)
        } else { elaborate_core_derived_ne_body(plan) }
    }
    if semantic_tag == 2 {
        let mix = match derived.hash_mix {
            some(value) => derived_call_plan_from_exact(
                facts, method.executable_ref, value.plan, origin),
            none => panic("Core assembly: derived Hash mix is absent")
        }
        let shape = match derived.type_kind {
            TypeKind::StructKind => make_core_derived_struct_shape(
                derived.target_owner, target_type, struct_fields),
            TypeKind::EnumKind => make_core_derived_enum_shape(
                derived.target_owner, target_type, common_variants)
        }
        return elaborate_core_derived_hash_body(make_core_derived_hash_plan(
            header, shape,
            type_fact_for(facts.type_sources, Type::IntType, facts.module_key),
            DERIVED_HASH_SEED, mix))
    }
    if semantic_tag == 3 {
        return elaborate_core_derived_clone_body(match derived.type_kind {
            TypeKind::StructKind => {
                let mut nominal_fields: List<NominalFieldRef> = []
                for field in derived.struct_fields.unwrap() {
                    match field.field_ref {
                        DerivedFieldRef::NominalDerivedField(reference) =>
                            nominal_fields.push(reference),
                        _ => panic("Core assembly: struct derive field domain differs")
                    }
                }
                make_core_derived_struct_clone_plan(
                    header, derived.target_owner, target_type,
                    make_core_struct_constructor(
                        derived.target_owner, nominal_fields), struct_fields)
            },
            TypeKind::EnumKind => make_core_derived_enum_clone_plan(
                header, derived.target_owner, target_type, clone_variants)
        })
    }
    if semantic_tag == 4 {
        let int_type = type_fact_for(
            facts.type_sources, Type::IntType, facts.module_key)
        let bool_type = type_fact_for(
            facts.type_sources, Type::BoolType, facts.module_key)
        return elaborate_core_derived_ord_body(match derived.type_kind {
            TypeKind::StructKind => make_core_derived_struct_ord_plan(
                header, derived.target_owner, target_type,
                int_type, bool_type, struct_fields),
            TypeKind::EnumKind => make_core_derived_enum_ord_plan(
                header, derived.target_owner, target_type,
                int_type, bool_type, ord_variants)
        })
    }
    panic("Core assembly: text derive reached non-text elaborator")
}

fn derived_field_ref_same(left: DerivedFieldRef, right: DerivedFieldRef) -> Bool {
    match (left, right) {
        (DerivedFieldRef::NominalDerivedField(a),
         DerivedFieldRef::NominalDerivedField(b)) =>
            nominal_field_ref_same(a, b),
        (DerivedFieldRef::VariantDerivedField(a),
         DerivedFieldRef::VariantDerivedField(b)) =>
            variant_field_ref_same(a, b),
        _ => false
    }
}

fn find_derived_field(
    values: List<DerivedField>, reference: DerivedFieldRef
) -> DerivedField {
    let mut found: DerivedField? = none
    for value in values {
        if derived_field_ref_same(value.field_ref, reference) {
            if found.is_some() {
                panic("Core assembly: derived text field repeats")
            }
            found = some(value)
        }
    }
    match found {
        some(value) => value,
        none => panic("Core assembly: derived text field is absent")
    }
}

fn text_render_plan(
    facts: FrozenCoreAssemblyFacts, method: DerivedMethod,
    field: CoreFieldRef, field_type: CoreTypeRef,
    value: DerivedValuePath, action: FieldAction,
    append: CoreDerivedCallPlan, string_type: CoreTypeRef,
    semantic_tag: Int, origin: OriginRef
) -> CoreDerivedTextRenderPlan {
    match action {
        FieldAction::Call { method_ref, base_dict, extra_dicts } => {
            let mut evidence = [base_dict]
            for value in extra_dicts { evidence.push(value) }
            make_core_derived_text_render_leaf(
                field, field_type, core_derived_value(value),
                derived_call_plan_from_method(
                    facts, method.executable_ref, method_ref, evidence,
                    method.handled_evidence_bindings, origin))
        },
        FieldAction::Tuple {
            element_types, element_projections, element_actions
        } => {
            if element_types.len() != element_projections.len() ||
               element_types.len() != element_actions.len() {
                panic("Core assembly: text tuple action census differs")
            }
            let open = if semantic_tag == 6 { "[" } else { "(" }
            let close = if semantic_tag == 6 { "]" } else { ")" }
            let separator = if semantic_tag == 6 { "," } else { ", " }
            let mut fields: List<CoreFieldRef> = []
            let mut types: List<CoreTypeRef> = []
            let mut pieces = [make_core_derived_literal_text_piece(
                open, string_type, append)]
            let mut index = 0
            while index < element_types.len() {
                if index > 0 {
                    pieces.push(make_core_derived_literal_text_piece(
                        separator, string_type, append))
                }
                let element_field = core_field(
                    element_projections.get(index).unwrap())
                let element_type = type_fact_for(
                    facts.type_sources,
                    element_types.get(index).unwrap(), facts.module_key)
                let child_value = extend_derived_value(
                    value, element_field, element_type, origin)
                match element_actions.get(index).unwrap() {
                    FieldAction::FnLiteral => pieces.push(
                        make_core_derived_rendered_text_piece(
                            make_core_derived_text_render_literal_only(
                                element_field, element_type,
                                [make_core_derived_literal_text_piece(
                                    "<fn>", string_type, append)]), none)),
                    child_action => pieces.push(
                        make_core_derived_rendered_text_piece(
                            text_render_plan(
                                facts, method, element_field, element_type,
                                child_value, child_action,
                                append, string_type, semantic_tag, origin),
                            match child_action {
                                FieldAction::Tuple { .. } => none,
                                _ => some(append)
                            }))
                }
                fields.push(element_field); types.push(element_type)
                index = index + 1
            }
            pieces.push(make_core_derived_literal_text_piece(
                close, string_type, append))
            make_core_derived_text_render_tuple(
                field, field_type, core_derived_value(value),
                fields, types, pieces)
        },
        _ => panic("Core assembly: rendered text field lacks exact call")
    }
}

fn text_sequence_plan(
    facts: FrozenCoreAssemblyFacts, method: DerivedMethod,
    sequence: DerivedTextSequence,
    fields: List<DerivedField>, self_slot: SlotRef,
    target_type: CoreTypeRef,
    enum_slots: List<(DerivedFieldRef, SlotRef)>,
    append: CoreDerivedCallPlan, string_type: CoreTypeRef,
    origin: OriginRef
) -> CoreDerivedTextSequence {
    let mut pieces = []
    for piece in sequence.pieces {
        match piece {
            DerivedTextPiece::DerivedLiteralText(value) =>
                pieces.push(make_core_derived_literal_text_piece(
                    value, string_type, append)),
            DerivedTextPiece::DerivedFieldLiteralText {
                field: reference, value
            } => {
                let field = find_derived_field(fields, reference)
                let field_type = type_fact_for(
                    facts.type_sources, field.ty, facts.module_key)
                pieces.push(make_core_derived_rendered_text_piece(
                    make_core_derived_text_render_literal_only(
                        derived_core_field(reference), field_type,
                        [make_core_derived_literal_text_piece(
                            value, string_type, append)]),
                    none))
            },
            DerivedTextPiece::DerivedFieldText(reference) => {
                let field = find_derived_field(fields, reference)
                let field_type = type_fact_for(
                    facts.type_sources, field.ty, facts.module_key)
                let render = text_render_plan(
                    facts, method,
                    derived_core_field(reference), field_type,
                    match enum_slots.len() == 0 {
                        true => DerivedValuePath {
                            root: self_slot, root_type: target_type,
                            projections: [derived_core_field(reference)],
                            projection_types: [field_type], ty: field_type,
                            origin: origin
                        },
                        false => {
                            let mut slot: SlotRef? = none
                            for entry in enum_slots {
                                if derived_field_ref_same(entry.0, reference) {
                                    slot = some(entry.1)
                                }
                            }
                            DerivedValuePath {
                                root: slot.unwrap(), root_type: field_type,
                                projections: [], projection_types: [],
                                ty: field_type, origin: origin
                            }
                        }
                    },
                    field.action, append, string_type,
                    derived_semantic_kind_tag(method.semantic_kind), origin)
                pieces.push(make_core_derived_rendered_text_piece(
                    render, match field.action {
                        FieldAction::Tuple { .. } => none,
                        _ => some(append)
                    }))
            }
        }
    }
    make_core_derived_text_sequence(pieces)
}

fn elaborate_derived_text(
    facts: FrozenCoreAssemblyFacts, derived: DerivedImpl,
    method: DerivedMethod
) -> CoreBody {
    let text = match derived.text_plan {
        some(value) => value,
        none => panic("Core assembly: derived text plan is absent")
    }
    let (_, result_source, effects, binder_values, slots) =
        derived_method_header_parts(facts, method)
    let mut binders = binder_values
    if slots.len() == 0 {
        panic("Core assembly: derived text method lacks self")
    }
    let target_type = type_fact_for(
        facts.type_sources, derived.target_type, facts.module_key)
    let string_type = type_fact_for(
        facts.type_sources, result_source, facts.module_key)
    let origin = executable_origin(method.executable_ref)
    let builder_signature = h_exact_call_signature(text.builder)
    let builder_call = derived_call_plan_from_exact(
        facts, method.executable_ref, text.builder, origin)
    let builder_type = match builder_signature {
        Type::FnType { return_type, .. } => type_fact_for(
            facts.type_sources, return_type, facts.module_key),
        _ => panic("Core assembly: text builder is not callable")
    }
    let builder_binder = core_binder_from_entry(
        facts, text.builder_binder, builder_type)
    append_unique_core_binder(binders, builder_binder)
    let append_signature = h_exact_call_signature(text.append)
    let append_call = derived_call_plan_from_exact(
        facts, method.executable_ref, text.append, origin)
    let unit_type = match append_signature {
        Type::FnType { return_type, .. } => type_fact_for(
            facts.type_sources, return_type, facts.module_key),
        _ => panic("Core assembly: text append is not callable")
    }
    let finish_call = derived_call_plan_from_exact(
        facts, method.executable_ref, text.finish, origin)
    let header = make_core_derived_header(
        method.executable_ref, origin, binders, slots, string_type,
        slots.get(0).unwrap(), none, origin,
        core_effects(facts.type_sources, effects, facts.module_key))
    let plan = match derived.type_kind {
        TypeKind::StructKind => {
            let fields = match derived.struct_fields {
                some(value) => value,
                none => panic("Core assembly: text struct fields are absent")
            }
            make_core_derived_struct_text_plan(
                header, derived.target_owner, target_type,
                string_type, unit_type, binder_entry_slot(text.builder_binder),
                builder_type, builder_call, finish_call,
                text_sequence_plan(
                    facts, method,
                    match text.struct_sequence {
                        some(value) => value,
                        none => panic(
                            "Core assembly: struct text sequence is absent")
                    }, fields, slots.get(0).unwrap(), target_type,
                    [], append_call, string_type, origin))
        },
        TypeKind::EnumKind => {
            let variants = match derived.enum_variants {
                some(value) => value,
                none => panic("Core assembly: text enum variants are absent")
            }
            let text_variants = match text.variants {
                some(value) => value,
                none => panic("Core assembly: enum text plan is absent")
            }
            if variants.len() != text_variants.len() {
                panic("Core assembly: enum text variant census differs")
            }
            let mut built = []
            let mut index = 0
            while index < variants.len() {
                let variant = variants.get(index).unwrap()
                let text_variant = text_variants.get(index).unwrap()
                if !variant_ref_same(
                        variant.variant_ref, text_variant.variant_ref) {
                    panic("Core assembly: enum text variant order differs")
                }
                let mut pattern_fields: List<CoreDerivedTextPatternField> = []
                let mut field_slots: List<(DerivedFieldRef, SlotRef)> = []
                let mut field_index = 0
                for field in variant.fields {
                    let reference = derived_core_field(field.field_ref)
                    let field_type = type_fact_for(
                        facts.type_sources, field.ty, facts.module_key)
                    let rendered = match field.action {
                        FieldAction::FnLiteral => false,
                        _ => true
                    }
                    let slot = if rendered {
                        some(derived_pattern_slot(
                            method.executable_ref, field_type,
                            index, field_index, "text", binders))
                    } else { none }
                    match slot {
                        some(value) => field_slots.push((field.field_ref, value)),
                        none => {}
                    }
                    pattern_fields.push(make_core_derived_text_pattern_field(
                        reference, field_type, slot, rendered))
                    field_index = field_index + 1
                }
                built.push(make_core_derived_text_variant_plan(
                    variant.variant_ref, pattern_fields,
                    text_sequence_plan(
                        facts, method, text_variant.sequence,
                        variant.fields, slots.get(0).unwrap(), target_type,
                        field_slots, append_call, string_type, origin),
                    origin))
                index = index + 1
            }
            let enum_header = make_core_derived_header(
                method.executable_ref, origin, binders, slots, string_type,
                slots.get(0).unwrap(), none, origin,
                core_effects(
                    facts.type_sources, effects, facts.module_key))
            make_core_derived_enum_text_plan(
                enum_header, derived.target_owner, target_type,
                string_type, unit_type, binder_entry_slot(text.builder_binder),
                builder_type, builder_call, finish_call, built)
        }
    }
    if derived_semantic_kind_tag(method.semantic_kind) == 5 {
        elaborate_core_derived_debug_body(make_core_derived_debug_plan(plan))
    } else {
        elaborate_core_derived_json_body(make_core_derived_json_plan(plan))
    }
}

fn append_derived_impl(
    facts: FrozenCoreAssemblyFacts, module_body: ModuleBodyRef,
    derived: DerivedImpl, mut assembly: ModuleAssembly
) {
    let mut methods: List<ImplMethodRef> = []
    for method in derived.methods {
        let tag = derived_semantic_kind_tag(method.semantic_kind)
        let body = if tag == 5 || tag == 6 {
            elaborate_derived_text(facts, derived, method)
        } else { elaborate_derived_non_text(facts, derived, method) }
        let (parameter_types, result_type, effects) = match method.signature {
            Type::FnType { params, return_type, effects } =>
                (params, return_type, effects),
            _ => panic("Core assembly: derived signature is not callable")
        }
        let parameter_slots = method.binders.map(fn(entry) {
            binder_entry_slot(entry)
        })
        let mutabilities = parameter_types.map(fn(_) { false })
        assembly.entries.push(make_executable_entry(
            method.executable_ref, make_module_body_parent(module_body),
            executable_kind_derived_impl(),
            make_concrete_body_contract(body_anchor(method.executable_ref))))
        assembly.callables.push(typed_callable_contract(
            facts, method.executable_ref, parameter_types, parameter_slots,
            mutabilities, result_type, effects,
            executable_contract_mode_concrete_body(),
            method.handled_evidence_bindings))
        append_generated_body_diagnostic_origins(
            facts, method.executable_ref, body, assembly)
        assembly.bodies.push(make_core_body_entry(
            method.executable_ref, executable_origin(method.executable_ref),
            body_anchor(method.executable_ref), body))
        methods.push(method.method_ref)
    }
    methods.sort_by(fn(left, right) {
        impl_method_ref_callable_slot_index(left) -
            impl_method_ref_callable_slot_index(right)
    })
    assembly.impls.push(make_core_impl_metadata(
        derived.owner_ref, methods, []))
}

fn append_derived_impls(
    facts: FrozenCoreAssemblyFacts, module_body: ModuleBodyRef,
    values: List<DerivedImpl>, mut assembly: ModuleAssembly
) {
    for value in values {
        append_derived_impl(facts, module_body, value, assembly)
    }
}

fn append_delegate_impl(
    facts: FrozenCoreAssemblyFacts, module_body: ModuleBodyRef,
    plan: HDelegateTypedPlan, mut assembly: ModuleAssembly
) {
    let contract = h_delegate_contract(plan)
    let contract_methods = registered_trait_contract_methods(contract)
    let methods = h_delegate_methods(plan)
    if methods.len() == 0 || methods.len() != contract_methods.len() {
        panic("Core assembly: delegate method contract census differs")
    }
    let field_type_source = match delegate_field_type_in_decls(
            facts.program.decls, h_delegate_field(plan)) {
        some(value) => value,
        none => panic("Core assembly: delegate field exact type is absent")
    }
    let field_type = type_fact_for(
        facts.type_sources, field_type_source, facts.module_key)
    let mut method_plans: List<DelegateMethodPlan> = []
    let mut method_index = 0
    while method_index < methods.len() {
        let method = methods.get(method_index).unwrap()
        let parameter_types = h_delegate_method_parameter_types(method)
        if parameter_types.len() == 0 {
            panic("Core assembly: delegate method lacks self")
        }
        let mutabilities = registered_trait_method_mutabilities(
            contract_methods.get(method_index).unwrap())
        let entries = h_delegate_method_binders(method)
        let parameter_slots = entries.map(fn(entry) {
            binder_entry_slot(entry)
        })
        let handled_bindings = h_delegate_method_handled_bindings(method)
        let mut binders = core_parameter_binders(
            facts, entries, parameter_types, mutabilities)
        append_handled_core_binders(facts, handled_bindings, binders)
        let reference = h_delegate_method_executable(method)
        let origin = h_delegate_method_origin(method)
        let child_call = h_delegate_method_child_call(method)
        let callee_ctx = LowerCtx {
            module_key: facts.module_key, owner: reference,
            effect_parameters: facts.effect_parameters,
            project_callable_effects: facts.project_callable_effects,
            project_type_mapping: facts.project_type_mapping,
            types: facts.type_sources, type_nodes: facts.type_nodes,
            handled_evidence_types: facts.handled_evidence_types,
            binders: binders, captures: [], next_origin: 0,
            diagnostic_origins: []
        }
        let handled_uses = h_delegate_method_handled_uses(method)
        let body_plan = make_delegate_method_body_plan(
            binders, parameter_slots,
            type_fact_for(
                facts.type_sources, parameter_types.get(0).unwrap(),
                facts.module_key),
            field_type,
            type_fact_for(
                facts.type_sources, h_delegate_method_result_type(method),
                facts.module_key),
            parameter_slots.get(0).unwrap(), tail_slots(parameter_slots),
            core_effects(
                facts.type_sources, h_delegate_method_effects(method),
                facts.module_key),
            h_delegate_method_evidence(method).map(fn(value) {
                make_core_dict_evidence(dict_ref_exact(value))
            }),
            handled_bindings.map(fn(value) {
                core_handled_binding(facts.handled_evidence_types, value)
            }),
            handled_uses.map(fn(value) {
                core_handled_use(facts.handled_evidence_types, value)
            }), origin)
        method_plans.push(make_delegate_method_plan(
            h_delegate_method_required(method),
            h_delegate_method_generated(method), reference, origin,
            exact_method_ref(child_call),
            core_callee(
                callee_ctx, h_delegate_method_child_callee(method),
                method_call_ref_signature(child_call)),
            tail_types(parameter_types).map(fn(ty) {
                type_fact_for(facts.type_sources, ty, facts.module_key)
            }),
            type_fact_for(
                facts.type_sources, h_delegate_method_result_type(method),
                facts.module_key), body_plan))
        method_index = method_index + 1
    }
    let assoc = h_delegate_assoc_bindings(plan).map(fn(value) {
        make_delegate_assoc_binding(
            h_delegate_assoc_member(value),
            type_fact_for(
                facts.type_sources, h_delegate_assoc_type(value),
                facts.module_key))
    })
    let requirements = registered_trait_contract_dict_obligations(contract)
    let dict_values = h_delegate_dict_evidence(plan)
    if requirements.len() != dict_values.len() {
        panic("Core assembly: delegate dictionary census differs")
    }
    let mut dict_bindings: List<DelegateEvidenceBinding> = []
    let mut dict_index = 0
    while dict_index < requirements.len() {
        dict_bindings.push(make_delegate_evidence_binding(
            requirements.get(dict_index).unwrap(),
            make_core_dict_evidence(dict_ref_exact(
                dict_values.get(dict_index).unwrap()))))
        dict_index = dict_index + 1
    }
    let child_owner = h_delegate_child_owner(plan)
    let typed_plan = validate_delegate_plan(make_delegate_plan_input(
        child_owner, impl_owner_ref_provider(child_owner),
        h_delegate_child_provider(plan), h_delegate_source_member_index(plan),
        h_delegate_field_owner(plan), h_delegate_field_provider(plan),
        h_delegate_field_target(plan),
        make_module_core_type_graph(facts.module_key, facts.type_nodes),
        h_delegate_field(plan),
        type_fact_for(
            facts.type_sources,
            h_delegate_method_parameter_types(methods.get(0).unwrap()).get(0).unwrap(),
            facts.module_key), field_type, contract, method_plans,
        assoc, dict_bindings))
    let (metadata, bodies) = elaborate_delegate_to_core(typed_plan)
    assembly.impls.push(metadata)
    let mut body_index = 0
    while body_index < bodies.len() {
        let method = methods.get(body_index).unwrap()
        let body = bodies.get(body_index).unwrap()
        let reference = h_delegate_method_executable(method)
        let parameter_types = h_delegate_method_parameter_types(method)
        let mutabilities = registered_trait_method_mutabilities(
            contract_methods.get(body_index).unwrap())
        let parameter_slots = h_delegate_method_binders(method).map(fn(entry) {
            binder_entry_slot(entry)
        })
        assembly.entries.push(make_executable_entry(
            reference, make_module_body_parent(module_body),
            executable_kind_impl_method(),
            make_concrete_body_contract(body_anchor(reference))))
        assembly.callables.push(typed_callable_contract(
            facts, reference, parameter_types, parameter_slots,
            mutabilities, h_delegate_method_result_type(method),
            h_delegate_method_effects(method),
            executable_contract_mode_concrete_body(),
            h_delegate_method_handled_bindings(method)))
        append_generated_body_diagnostic_origins(
            facts, reference, body, assembly)
        assembly.bodies.push(make_core_body_entry(
            reference, h_delegate_method_origin(method),
            body_anchor(reference), body))
        body_index = body_index + 1
    }
}
fn add_executable_body(
    facts: FrozenCoreAssemblyFacts, parent: ExecutableParentRef,
    reference: ExecutableRef, kind: ExecutableKind,
    params: List<HParam>, result_type: Type, effects: EffectRow,
    body_expr: HExpr,
    handled_evidence: List<HandledEvidenceRef>,
    handled_captures: List<HandledEvidenceCapture>,
    capture_bindings: List<CaptureSlotMap>,
    mut assembly: ModuleAssembly
) {
    let anchor = body_anchor(reference)
    assembly.entries.push(make_executable_entry(
        reference, parent, kind, make_concrete_body_contract(anchor)))
    assembly.callables.push(callable_contract(
        facts, reference, params, result_type, effects,
        executable_contract_mode_concrete_body(), handled_evidence))
    let mut ctx = LowerCtx { module_key: facts.module_key,
        owner: reference,
        effect_parameters: facts.effect_parameters,
        project_callable_effects: facts.project_callable_effects,
        project_type_mapping: facts.project_type_mapping,
        types: facts.type_sources, type_nodes: facts.type_nodes,
        handled_evidence_types: facts.handled_evidence_types,
        binders: [], captures: capture_bindings, next_origin: 0,
        diagnostic_origins: [] }
    for value in handled_evidence {
        activate_handled_evidence_binder(ctx, value)
    }
    for capture in handled_captures {
        activate_handled_evidence_binder(
            ctx, handled_evidence_capture_target(capture))
    }
    let mut parameter_slots: List<SlotRef> = []
    for param in params {
        parameter_slots.push(param_slot(ctx, param, binder_kind_source_param()))
    }
    let block = block_from_expr(ctx, body_expr)
    let body = make_core_body(reference, executable_origin(reference),
        ctx.binders, parameter_slots,
        type_fact_for(facts.type_sources, result_type, facts.module_key), block)
    assembly.bodies.push(make_core_body_entry(
        reference, executable_origin(reference), anchor, body))
    append_body_owner_diagnostic_origin(facts, reference, assembly)
    append_lowered_diagnostic_origins(assembly, ctx.diagnostic_origins)
    scan_nested_expr(facts, reference, body_expr, assembly)
}
fn add_contract_only(
    facts: FrozenCoreAssemblyFacts, parent: ExecutableParentRef,
    reference: ExecutableRef, kind: ExecutableKind,
    params: List<HParam>, result_type: Type, effects: EffectRow,
    handled_evidence: List<HandledEvidenceRef>,
    resource_contract: CallableResourceContractFact?,
    mut assembly: ModuleAssembly
) {
    assembly.entries.push(make_executable_entry(
        reference, parent, kind, make_contract_only()))
    assembly.callables.push(match resource_contract {
        some(resource) => {
            let parameter_types = params.map(fn(param) {
                type_fact_for(
                    facts.type_sources, param.ty, facts.module_key)
            })
            let result = type_fact_for(
                facts.type_sources, result_type, facts.module_key)
            make_core_callable_contract(
                reference, executable_origin(reference),
                [], executable_contract_mode_contract_only(),
                flow_contract_from_resource_fact(
                    facts.module_key, parameter_types, result, resource),
                core_effect_contract_from_row(
                    facts.type_sources, effects, facts.module_key,
                    facts.effect_parameters,
                    some(executable_origin(reference))),
                handled_evidence.map(fn(value) {
                    core_handled_binding(
                        facts.handled_evidence_types, value)
                }))
        },
        none => callable_contract(
            facts, reference, params, result_type, effects,
            executable_contract_mode_contract_only(), handled_evidence)
    })
}

fn scan_nested_stmt(
    facts: FrozenCoreAssemblyFacts, parent: ExecutableRef,
    value: HStmt, mut assembly: ModuleAssembly
) {
    match value {
        HStmt::Let { init, .. } =>
            scan_nested_expr(facts, parent, init, assembly),
        HStmt::Var { init, .. } =>
            scan_nested_expr(facts, parent, init, assembly),
        HStmt::ExprStmt { expr: init, .. } =>
            scan_nested_expr(facts, parent, init, assembly),
        HStmt::Assign { target, value, .. } => {
            scan_nested_expr(facts, parent, target, assembly)
            scan_nested_expr(facts, parent, value, assembly)
        },
        HStmt::Return { value, .. } => match value {
            some(expr) => scan_nested_expr(facts, parent, expr, assembly),
            none => {}
        },
        HStmt::While { condition, body, .. } => {
            scan_nested_expr(facts, parent, condition, assembly)
            scan_nested_expr(facts, parent, body, assembly)
        },
        _ => {}
    }
}
fn scan_nested_expr(
    facts: FrozenCoreAssemblyFacts, parent: ExecutableRef,
    value: HExpr, mut assembly: ModuleAssembly
) {
    match value {
        HExpr::Lambda { executable_ref, params, return_type, body,
                        captures, handled_evidence_bindings,
                        evidence_captures, .. } => {
            add_executable_body(facts, make_executable_parent(parent),
                executable_ref, executable_kind_lambda(), params,
                return_type, hexpr_effects(body), body,
                handled_evidence_bindings,
                evidence_captures, capture_slot_maps(captures), assembly)
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            scan_nested_expr(facts, parent, body, assembly)
            for handler in handlers {
                let mut params = handler.params
                match handler.resume_binding {
                    some(binding) => params.push(HParam {
                        name: binding.name, ty: binding.ty,
                        def_id: some(binding.def_id), is_mutable: false
                    }),
                    none => {}
                }
                add_executable_body(facts, make_executable_parent(parent),
                    handler.executable_ref, executable_kind_handler(), params,
                    hexpr_type(handler.body), hexpr_effects(handler.body),
                    handler.body,
                    handler.handled_evidence_bindings,
                    handler.evidence_captures,
                    capture_slot_maps(handler.captures), assembly)
            }
        },
        HExpr::Block { stmts, tail, .. } => {
            for stmt in stmts { scan_nested_stmt(facts, parent, stmt, assembly) }
            match tail { some(expr) => scan_nested_expr(
                facts, parent, expr, assembly), none => {} }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            scan_nested_expr(facts, parent, condition, assembly)
            scan_nested_expr(facts, parent, then_branch, assembly)
            match else_branch { some(expr) => scan_nested_expr(
                facts, parent, expr, assembly), none => {} }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            scan_nested_expr(facts, parent, scrutinee, assembly)
            for arm in arms {
                match arm.guard { some(expr) => scan_nested_expr(
                    facts, parent, expr, assembly), none => {} }
                scan_nested_expr(facts, parent, arm.body, assembly)
            }
        },
        HExpr::TryCatch { body: scrutinee, arms, .. } => {
            scan_nested_expr(facts, parent, scrutinee, assembly)
            for arm in arms {
                match arm.guard { some(expr) => scan_nested_expr(
                    facts, parent, expr, assembly), none => {} }
                scan_nested_expr(facts, parent, arm.body, assembly)
            }
        },
        HExpr::Call { callee, args, .. } => {
            scan_nested_expr(facts, parent, callee, assembly)
            for arg in args { scan_nested_expr(facts, parent, arg, assembly) }
        },
        HExpr::BinOp { left, right, .. } => {
            scan_nested_expr(facts, parent, left, assembly)
            scan_nested_expr(facts, parent, right, assembly)
        },
        HExpr::UnaryOp { operand, .. } =>
            scan_nested_expr(facts, parent, operand, assembly),
        HExpr::FieldAccess { receiver: operand, .. } =>
            scan_nested_expr(facts, parent, operand, assembly),
        HExpr::UnsafeBlock { body: operand, .. } =>
            scan_nested_expr(facts, parent, operand, assembly),
        HExpr::StructLit { fields, spread, .. } => {
            for field in fields {
                scan_nested_expr(facts, parent, field.value, assembly)
            }
            match spread {
                some(value) => scan_nested_expr(
                    facts, parent, value, assembly), none => {}
            }
        },
        HExpr::NamedVariantConstruct { fields, spread, .. } => {
            for field in fields {
                scan_nested_expr(facts, parent, field.value, assembly)
            }
            match spread {
                some(value) => scan_nested_expr(
                    facts, parent, value, assembly), none => {}
            }
        },
        HExpr::TupleLit { elements, .. } => {
            for item in elements {
                scan_nested_expr(facts, parent, item, assembly)
            }
        },
        HExpr::EffectOp { args, .. } => {
            for arg in args {
                scan_nested_expr(facts, parent, arg, assembly)
            }
        },
        HExpr::ReturnExpr { value, .. } => match value {
            some(expr) => scan_nested_expr(facts, parent, expr, assembly),
            none => {}
        },
        _ => {}
    }
}

fn source_parent(
    module_body: ModuleBodyRef, reference: ExecutableRef
) -> ExecutableParentRef {
    if compiler_extern_ref_for_executable(reference).is_some() {
        return make_module_body_parent(make_module_body_ref(
            "$builtin", "compiler-externs"))
    }
    if executable_ref_is_prelude(reference) {
        make_module_body_parent(make_module_body_ref(
            symbol_ref_origin_module_key(
                executable_ref_named_symbol(reference)),
            "prelude-physical-source"))
    } else { make_module_body_parent(module_body) }
}

fn validate_prelude_source_parent_canary() {
    let symbol = make_symbol_ref(
        "$prelude$::core-parent-canary", namespace_value(),
        "core_parent_canary", "frame:0|item:0")
    let reference = make_named_executable_ref(symbol)
    let parent = source_parent(
        make_module_body_ref("$single$::canary", "module-body"), reference)
    let _ = make_executable_entry(
        reference, parent, executable_kind_fn(), make_contract_only())
}

fn assemble_decls(
    facts: FrozenCoreAssemblyFacts, module_body: ModuleBodyRef,
    decls: List<HDecl>, mut assembly: ModuleAssembly
) {
    for decl in decls {
        match decl {
            HDecl::Fn { executable_ref, impl_method_ref, params,
                return_type, effects,
                handled_evidence_bindings, body, .. } =>
                add_executable_body(
                    facts, source_parent(module_body, executable_ref), executable_ref,
                    if impl_method_ref.is_some() { executable_kind_impl_method() }
                    else { executable_kind_fn() },
                    params, return_type, effects, body,
                    handled_evidence_bindings,
                    [], [], assembly),
            HDecl::Test { executable_ref, handled_evidence_bindings,
                          body, .. } => add_executable_body(
                facts, source_parent(module_body, executable_ref), executable_ref,
                executable_kind_test(), [], hexpr_type(body),
                hexpr_effects(body), body,
                handled_evidence_bindings, [], [], assembly),
            HDecl::Const { executable_ref, handled_evidence_bindings,
                           ty, init, .. } => add_executable_body(
                facts, source_parent(module_body, executable_ref), executable_ref,
                executable_kind_const_getter(), [], ty, hexpr_effects(init), init,
                handled_evidence_bindings, [], [], assembly),
            HDecl::ExternFn { executable_ref, params, return_type, effects,
                              resource_contract,
                              handled_evidence_bindings, .. } =>
                add_contract_only(facts, source_parent(module_body, executable_ref),
                    executable_ref, executable_kind_extern_fn(),
                    params, return_type, effects, handled_evidence_bindings,
                    some(resource_contract), assembly),
            HDecl::Trait { methods, .. } => {
                for method in methods {
                    let reference = method.executable_ref
                    if method.has_default != method.body.is_some() {
                        panic("Core assembly: trait default/body relation differs")
                    }
                    match method.body {
                        some(body) => add_executable_body(
                            facts, source_parent(module_body, reference), reference,
                            executable_kind_trait_default(), method.params,
                            method.return_type, method.effects, body,
                            method.handled_evidence_bindings,
                            [], [], assembly),
                        none => add_contract_only(
                            facts, source_parent(module_body, reference),
                            reference, executable_kind_bodyless_trait_member(),
                            method.params, method.return_type, method.effects,
                            method.handled_evidence_bindings, none, assembly)
                    }
                }
            },
            HDecl::Impl {
                owner_ref, delegate_plan, default_specializations,
                methods, assoc_types, ..
            } => {
                match delegate_plan {
                    some(plan) => {
                        if default_specializations.len() != 0 {
                            panic("Core assembly: delegate carries defaults")
                        }
                        append_delegate_impl(
                            facts, module_body, plan, assembly)
                    },
                    none => {
                        assemble_decls(facts, module_body, methods, assembly)
                        let mut method_refs: List<ImplMethodRef> = []
                        for method in methods {
                            match method {
                                HDecl::Fn {
                                    impl_method_ref: some(v), ..
                                } => method_refs.push(v),
                                _ => {}
                            }
                        }
                        for specialization in default_specializations {
                            method_refs.push(append_default_specialization(
                                facts, module_body, specialization, assembly))
                        }
                        method_refs.sort_by(fn(left, right) {
                            impl_method_ref_callable_slot_index(left) -
                                impl_method_ref_callable_slot_index(right)
                        })
                        let bindings = assoc_types.filter(fn(a) {
                            a.concrete.is_some()
                        }).map(fn(a) {
                            make_core_assoc_binding(a.member_ref,
                                type_fact_for(
                                    facts.type_sources,
                                    a.concrete.unwrap(), facts.module_key))
                        })
                        assembly.impls.push(make_core_impl_metadata(
                            owner_ref, method_refs, bindings))
                    }
                }
            },
            HDecl::ModBlock { decls: nested, .. } =>
                assemble_decls(facts, module_body, nested, assembly),
            HDecl::Effect { name, type_params, ops, .. } => {
                let effect_type_args = type_params.map(fn(parameter) {
                    Type::TypeVar {
                        id: parameter.type_var_id,
                        name: some(parameter.source.name)
                    }
                })
                for op in ops {
                    match op.operation_ref {
                        some(reference) => add_contract_only(
                            facts, source_parent(
                                module_body,
                                effect_operation_ref_callable(reference)),
                            effect_operation_ref_callable(reference),
                            executable_kind_bodyless_effect_operation(),
                            op.params, op.return_type,
                            EffectRow { effects: [Effect::CustomEffect {
                                reference: effect_operation_ref_effect(reference),
                                name: name, type_args: effect_type_args
                            }], tail: none },
                            [effect_operation_handled_binding(reference)],
                            none, assembly),
                        none => panic("Core assembly: effect op lacks exact reference")
                    }
                }
            },
            _ => {}
        }
    }
}

struct TypePrototype { module_index: Int, local_index: Int }
struct ProjectTypes { graph: CoreTypeGraph, mappings: List<List<Int>> }
fn unresolved(count: Int) -> List<Int?> {
    let mut result: List<Int?> = []
    for _ in 0..count { result.push(none) }
    result
}
fn close_mapping(values: List<Int?>) -> List<Int> {
    values.map(fn(value) { match value { some(v) => v,
        none => panic("Core assembly: unresolved project type") } })
}
fn validate_fact_order(values: List<FrozenCoreAssemblyFacts>) {
    let mut index = 0
    while index < values.len() {
        if values.get(index).unwrap().module_order != index {
            panic("Core assembly: module facts are not topologically ordered")
        }
        let mut prior = 0
        while prior < index {
            if values.get(prior).unwrap().module_key ==
                    values.get(index).unwrap().module_key {
                panic("Core assembly: duplicate module key")
            }
            prior = prior + 1
        }
        index = index + 1
    }
}
fn intern_project_types(values: List<FrozenCoreAssemblyFacts>) -> ProjectTypes {
    let mut mappings: List<List<Int?>> = []
    let mut total = 0
    for value in values {
        mappings.push(unresolved(value.type_nodes.len()))
        total = total + value.type_nodes.len()
    }
    let mut prototypes: List<TypePrototype> = []
    let mut resolved = 0
    while resolved < total {
        let mut progress = false
        let mut module_index = 0
        while module_index < values.len() {
            let facts = values.get(module_index).unwrap()
            let mut mapping = mappings.get(module_index).unwrap()
            let mut local_index = 0
            while local_index < facts.type_nodes.len() {
                if mapping.get(local_index).unwrap().is_none() {
                    let node = facts.type_nodes.get(local_index).unwrap()
                    if flow_type_node_intern_ready(node, mapping) {
                        let mut chosen: Int? = none
                        let mut candidate = 0
                        while candidate < prototypes.len() {
                            let p = prototypes.get(candidate).unwrap()
                            let other = values.get(p.module_index).unwrap()
                            if flow_type_node_intern_key_same(
                                    node, mapping,
                                    other.type_nodes.get(p.local_index).unwrap(),
                                    mappings.get(p.module_index).unwrap()) {
                                chosen = some(candidate)
                                candidate = prototypes.len()
                            } else { candidate = candidate + 1 }
                        }
                        let project_index = match chosen {
                            some(v) => v,
                            none => { let v = prototypes.len();
                                prototypes.push(TypePrototype {
                                    module_index: module_index,
                                    local_index: local_index }); v }
                        }
                        mapping.set(local_index, some(project_index))
                        mappings.set(module_index, mapping)
                        resolved = resolved + 1; progress = true
                    }
                }
                local_index = local_index + 1
            }
            module_index = module_index + 1
        }
        if !progress { panic("Core assembly: type interning dependency cycle") }
    }
    let closed = mappings.map(fn(value) { close_mapping(value) })
    let mut nodes: List<FlowTypeNode> = []
    let mut project_index = 0
    while project_index < prototypes.len() {
        let p = prototypes.get(project_index).unwrap()
        let facts = values.get(p.module_index).unwrap()
        nodes.push(remap_flow_type_node(
            facts.type_nodes.get(p.local_index).unwrap(), project_index,
            closed.get(p.module_index).unwrap()))
        project_index = project_index + 1
    }
    let mut module_index = 0
    while module_index < values.len() {
        let facts = values.get(module_index).unwrap()
        let mapping = closed.get(module_index).unwrap()
        let mut local_index = 0
        while local_index < facts.type_nodes.len() {
            let target = mapping.get(local_index).unwrap()
            if !flow_type_node_contract_same(
                    remap_flow_type_node(
                        facts.type_nodes.get(local_index).unwrap(), target, mapping),
                    nodes.get(target).unwrap()) {
                panic("Core assembly: shared type key has different contract")
            }
            local_index = local_index + 1
        }
        module_index = module_index + 1
    }
    ProjectTypes { graph: make_core_type_graph(nodes), mappings: closed }
}

fn close_project_callable_effect_sources(
    values: List<FrozenCoreAssemblyFacts>, mappings: List<List<Int>>
) -> List<ProjectCallableEffectSource> {
    let mut result: List<ProjectCallableEffectSource> = []
    let mut module_index = 0
    while module_index < values.len() {
        let facts = values.get(module_index).unwrap()
        let mapping = mappings.get(module_index).unwrap()
        for source in facts.callable_effect_rows {
            let reference = typed_callable_effect_reference(source)
            let local = core_effect_contract_from_row(
                facts.type_sources, typed_callable_effect_row(source),
                facts.module_key,
                facts.effect_parameters,
                some(executable_origin(reference)))
            let global = remap_core_effect_contract_types(
                local, mapping, facts.module_key)
            let mut matched = false
            for existing in result {
                if executable_ref_same(existing.reference, reference) {
                    if !core_effect_contract_same(existing.contract, global) {
                        panic("Core assembly: project callable effect source drifted")
                    }
                    matched = true
                }
            }
            if !matched {
                result.push(ProjectCallableEffectSource {
                    reference: reference, contract: global
                })
            }
        }
        module_index = module_index + 1
    }
    result
}

fn local_type_for_project_index(
    mapping: List<Int>, project_index: Int, module_key: Str
) -> CoreTypeRef {
    let mut found: Int? = none
    let mut local_index = 0
    while local_index < mapping.len() {
        if mapping.get(local_index).unwrap() == project_index {
            if found.is_none() { found = some(local_index) }
        }
        local_index = local_index + 1
    }
    match found {
        some(index) => make_module_core_type_ref(module_key, index),
        none => panic(
            "Core assembly: project callable effect type is absent in caller")
    }
}

fn project_effect_contract_to_module(
    value: CoreEffectContract, mapping: List<Int>, module_key: Str
) -> CoreEffectContract {
    let mut atoms: List<CoreEffectAtom> = []
    for atom in core_effect_set_atoms(core_effect_contract_exact(value)) {
        let kind = core_effect_atom_kind_tag(atom)
        if kind == 0 {
            atoms.push(make_core_fail_effect(local_type_for_project_index(
                mapping, core_type_ref_index(core_effect_atom_type(atom)),
                module_key)))
        } else if kind == 1 {
            atoms.push(make_core_mut_effect(local_type_for_project_index(
                mapping, core_type_ref_index(core_effect_atom_type(atom)),
                module_key)))
        } else if kind == 2 {
            atoms.push(make_core_unsafe_effect())
        } else if kind == 3 {
            atoms.push(make_core_handled_effect(
                core_effect_atom_handled_ref(atom),
                core_effect_atom_type_arguments(atom).map(fn(ty) {
                    local_type_for_project_index(
                        mapping, core_type_ref_index(ty), module_key)
                })))
        } else if kind == 4 {
            atoms.push(make_core_system_effect(
                core_effect_atom_system_ref(atom)))
        } else {
            panic("Core assembly: project effect atom kind is invalid")
        }
    }
    make_core_effect_contract(
        make_core_effect_set(atoms),
        core_effect_contract_parameter(value))
}

fn with_project_effect_sources(
    facts: FrozenCoreAssemblyFacts,
    sources: List<ProjectCallableEffectSource>, mapping: List<Int>
) -> FrozenCoreAssemblyFacts {
    FrozenCoreAssemblyFacts {
        module_key: facts.module_key, module_order: facts.module_order,
        type_refs: facts.type_refs, type_nodes: facts.type_nodes,
        type_sources: facts.type_sources,
        effect_parameters: facts.effect_parameters,
        callable_effect_rows: facts.callable_effect_rows,
        project_callable_effects: sources.map(fn(item) { item }),
        project_type_mapping: mapping.map(fn(item) { item }),
        handled_evidence_types: facts.handled_evidence_types,
        diagnostic_seed: facts.diagnostic_seed,
        builtin_methods: facts.builtin_methods, program: facts.program
    }
}

fn push_effect_remap(
    mut entries: List<CoreAssemblyEffectRemapEntry>, module_key: Str,
    source: CoreEffectSet, target: CoreEffectSet
) {
    for entry in entries {
        if entry.module_key == module_key &&
           core_effect_set_same(entry.source, source) {
            if !core_effect_set_same(entry.target, target) {
                panic("Core assembly: one local effect set has two project remaps")
            }
            return
        }
    }
    entries.push(CoreAssemblyEffectRemapEntry {
        module_key: module_key, source: source, target: target
    })
}

fn append_project_diagnostic_owner(
    mut values: List<CoreDiagnosticOwnerSeed>,
    value: CoreDiagnosticOwnerSeed
) {
    for existing in values {
        if executable_ref_same(existing.owner, value.owner) {
            if existing.module_key != value.module_key ||
               !diagnostic_span_same(existing.span, value.span) {
                panic("Core diagnostic projection: project owner drifts")
            }
            return
        }
    }
    values.push(value)
}

fn diagnostic_owner_for(
    values: List<CoreDiagnosticOwnerSeed>, owner: ExecutableRef
) -> CoreDiagnosticOwnerSeed {
    let mut found: CoreDiagnosticOwnerSeed? = none
    for value in values {
        if executable_ref_same(value.owner, owner) {
            if found.is_some() {
                panic("Core diagnostic projection: owner is duplicated")
            }
            found = some(value)
        }
    }
    match found {
        some(value) => value,
        none => panic("Core diagnostic projection: body owner source is absent")
    }
}

fn append_project_diagnostic_slot(
    mut values: List<CoreDiagnosticSlotFact>, value: CoreDiagnosticSlotFact
) {
    for existing in values {
        if slot_ref_same(existing.slot, value.slot) {
            if existing.module_key != value.module_key ||
               existing.display_label != value.display_label ||
               !diagnostic_span_same(existing.span, value.span) {
                panic("Core diagnostic projection: project slot drifts")
            }
            return
        }
    }
    values.push(value)
}

fn append_project_diagnostic_origin(
    mut values: List<CoreDiagnosticOriginFact>,
    value: CoreDiagnosticOriginFact
) {
    for existing in values {
        if origin_ref_same(existing.origin, value.origin) {
            if !executable_ref_same(existing.owner, value.owner) ||
               existing.module_key != value.module_key ||
               !diagnostic_span_same(existing.span, value.span) {
                panic("Core diagnostic projection: project origin drifts")
            }
            return
        }
    }
    values.push(value)
}

fn build_core_diagnostic_projection(
    facts: List<FrozenCoreAssemblyFacts>, bodies: List<CoreBodyEntry>,
    lowered_origins: List<CoreDiagnosticOriginFact>
) -> CoreDiagnosticProjection {
    let mut owners: List<CoreDiagnosticOwnerSeed> = []
    let mut slots: List<CoreDiagnosticSlotFact> = []
    for module in facts {
        for owner in module.diagnostic_seed.owners {
            append_project_diagnostic_owner(owners, owner)
        }
        for slot in module.diagnostic_seed.slots {
            append_project_diagnostic_slot(slots, slot)
        }
    }
    let mut origins: List<CoreDiagnosticOriginFact> = []
    for value in lowered_origins {
        append_project_diagnostic_origin(origins, value)
    }
    for entry in bodies {
        let owner = core_body_entry_reference(entry)
        let source = diagnostic_owner_for(owners, owner)
        let body = core_body_entry_body(entry)
        for origin in core_body_origins(body) {
            let mut matches = 0
            for fact in origins {
                if origin_ref_same(fact.origin, origin) {
                    if !executable_ref_same(fact.owner, owner) ||
                       fact.module_key != source.module_key {
                        panic("Core diagnostic projection: origin crosses owner/module")
                    }
                    matches = matches + 1
                }
            }
            if matches != 1 {
                panic("Core diagnostic projection: body origin source is not exact")
            }
        }
        for binder in core_body_binders(body) {
            let slot = core_binder_reference(binder)
            let mut present = false
            for existing in slots {
                if slot_ref_same(existing.slot, slot) { present = true }
            }
            if !present {
                if slot_ref_is_source(slot) {
                    panic("Core diagnostic projection: source binder seed is absent")
                }
                append_project_diagnostic_slot(slots, CoreDiagnosticSlotFact {
                    slot: slot, module_key: source.module_key,
                    span: source.span,
                    display_label: "compiler binding ${binder_kind_tag(
                        core_binder_kind(binder)).to_str()}"
                })
            }
        }
    }
    for fact in origins {
        let mut reachable = 0
        for entry in bodies {
            if executable_ref_same(
                    core_body_entry_reference(entry), fact.owner) {
                let mut present = false
                for origin in core_body_origins(core_body_entry_body(entry)) {
                    if origin_ref_same(origin, fact.origin) {
                        present = true
                    }
                }
                if present { reachable = reachable + 1 }
            }
        }
        if reachable != 1 {
            panic("Core diagnostic projection: origin source is unreachable")
        }
    }
    let result = CoreDiagnosticProjection { origins: origins, slots: slots }
    validate_core_diagnostic_projection(result)
    result
}

fn assemble_all(values: List<FrozenCoreAssemblyFacts>) -> CoreAssemblyResult {
    if values.len() == 0 { panic("Core assembly: project has no modules") }
    validate_prelude_source_parent_canary()
    validate_fact_order(values)
    let project = intern_project_types(values)
    let project_effect_sources = close_project_callable_effect_sources(
        values, project.mappings)
    let mut callables: List<CoreCallableContract> = []
    let mut impls: List<CoreImplMetadata> = []
    let mut entries: List<ExecutableEntry> = []
    let mut bodies: List<CoreBodyEntry> = []
    let mut diagnostic_origins: List<CoreDiagnosticOriginFact> = []
    let mut type_entries: List<CoreAssemblyTypeRemapEntry> = []
    let mut effect_entries: List<CoreAssemblyEffectRemapEntry> = []
    let mut module_index = 0
    while module_index < values.len() {
        let frozen_facts = values.get(module_index).unwrap()
        let mapping = project.mappings.get(module_index).unwrap()
        let facts = with_project_effect_sources(
            frozen_facts, project_effect_sources, mapping)
        let module_body = make_module_body_ref(facts.module_key, "module-body")
        let assembly = empty_module_assembly()
        add_builtin_method_contracts(facts, assembly)
        assemble_decls(facts, module_body, facts.program.decls, assembly)
        append_derived_impls(
            facts, module_body, facts.program.derived_impls, assembly)
        for value in assembly.callables {
            callables.push(remap_core_callable_types(
                value, mapping, facts.module_key))
        }
        for value in assembly.impls {
            impls.push(remap_core_impl_types(value, mapping, facts.module_key))
        }
        for value in assembly.entries { entries.push(value) }
        for value in assembly.diagnostic_origins {
            append_project_diagnostic_origin(diagnostic_origins, value)
        }
        for entry in assembly.bodies {
            let local = core_body_entry_body(entry)
            let global = remap_core_body_types(local, mapping, facts.module_key)
            let local_effects = core_body_effect_sets(local)
            let global_effects = core_body_effect_sets(global)
            let mut effect_index = 0
            while effect_index < local_effects.len() {
                push_effect_remap(
                    effect_entries, facts.module_key,
                    local_effects.get(effect_index).unwrap(),
                    global_effects.get(effect_index).unwrap())
                effect_index = effect_index + 1
            }
            bodies.push(make_core_body_entry(
                core_body_entry_reference(entry), core_body_entry_origin(entry),
                core_body_entry_anchor(entry), global))
        }
        let mut local_index = 0
        while local_index < facts.type_refs.len() {
            type_entries.push(CoreAssemblyTypeRemapEntry {
                source: facts.type_refs.get(local_index).unwrap(),
                target: make_core_type_ref(mapping.get(local_index).unwrap())
            })
            local_index = local_index + 1
        }
        module_index = module_index + 1
    }
    let diagnostic_projection = build_core_diagnostic_projection(
        values, bodies, diagnostic_origins)
    let program = make_core_program(project.graph, callables, impls, bodies,
        make_executable_inventory(entries))
    CoreAssemblyResult {
        program: program,
        type_remap: CoreAssemblyTypeRemap { entries: type_entries },
        effect_remap: CoreAssemblyEffectRemap { entries: effect_entries },
        diagnostic_projection: diagnostic_projection
    }
}
pub fn assemble_single_core(facts: FrozenCoreAssemblyFacts) -> CoreAssemblyResult {
    if facts.module_order != 0 { panic("Core assembly: single module order differs") }
    assemble_all([facts])
}
pub fn assemble_project_core(
    facts_in_topological_order: List<FrozenCoreAssemblyFacts>
) -> CoreAssemblyResult { assemble_all(facts_in_topological_order) }
