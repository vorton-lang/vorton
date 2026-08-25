// Sole post-semantic-lowering HIR -> CoreHIR assembly boundary.
//
// The recorder owns only module-local type construction.  Source Type -> fact
// relations are passed as an immutable checker snapshot; expression, binder,
// callable, impl and executable facts are derived once from canonical HIR.

use ast::{Pattern, LiteralValue, BinOp, UnaryOp, span_zero}
use types::{Type, Effect, EffectRow, types_equal}
use env::{
    TypeEnv, registered_trait_contract_methods,
    registered_trait_contract_dict_obligations,
    registered_trait_method_mutabilities
}
use builtins::{
    BuiltinMethodContractFact, builtin_method_contract_facts,
    builtin_method_contract_intrinsic, builtin_method_contract_scheme
}
use precore_lower::{close_hir_surface}
use core_type_source::{
    CoreTypeSourceFact, CoreHandledEvidenceTypeSource,
    core_type_source_type, core_type_source_fact,
    core_handled_evidence_source_requirement,
    core_handled_evidence_source_aggregate_fact,
    core_handled_evidence_type_source_same
}
use ir_identity::{
    SymbolRef, PathRef, PathOwnerRef, PathRole, SlotRef, CalleeRef,
    NominalFieldRef,
    ModuleBodyRef, make_module_body_ref,
    OriginRef, ImplOwnerRef, ImplMethodRef,
    RegisteredNominalRef, VariantRef, HandledEffectRef,
    handled_effect_ref_same,
    path_owner_for_symbol, path_ref_owner, path_ref_normalized_child_path,
    path_role_child, path_role_parameter, path_role_declaration,
    path_role_capture, path_role_handler, path_role_synthetic,
    make_path_ref, make_path_origin_ref, make_symbol_origin_ref,
    make_source_slot_ref, slot_domain_lexical, slot_ref_synthetic_path,
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
    variant_ref_member, variant_ref_same,
    nominal_field_ref_same,
    variant_field_ref_same,
    slot_ref_same, slot_ref_source_def_id
}
use ir_inventory::{
    ExecutableRef, ExecutableEntry, ExecutableInventory, ExecutableParentRef,
    ExecutableKind,
    BinderKind, BinderEntry, binder_kind_tag,
    make_named_executable_ref, make_anonymous_executable_ref,
    executable_ref_is_named, executable_ref_named_symbol,
    executable_ref_anonymous_path, executable_ref_same,
    executable_ref_origin_module_key,
    make_module_body_parent, make_executable_parent,
    make_executable_entry, make_executable_inventory,
    executable_entry_reference, executable_entry_contract,
    executable_contract_mode, executable_contract_mode_same,
    executable_contract_mode_concrete_body,
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
    binder_kind_match_pattern, binder_kind_catch_pattern,
    binder_kind_lambda_param, binder_kind_handler_param,
    binder_kind_handler_resume, binder_kind_lambda_capture,
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
    effect_operation_ref_effect
}
use hir::{
    HProgram, HDecl, HExpr, HStmt, HParam, HMatchArm, HEffectHandler,
    HLambdaCapture,
    HPatternBinding, HProjectionRef, HPatternPlan, HPatternFieldPlan,
    HNominalStructFieldInit, HStructFieldInit, HFieldAccessKind,
    HAssocType, HTraitMethod, DictRef, MethodCallRef,
    HDelegateTypedPlan, HDelegateMethodPlan,
    HDefaultSpecializationPlan, HExactCallPlan,
    DerivedImpl, DerivedMethod, DerivedField, DerivedVariant,
    DerivedFieldRef, FieldAction, DerivedTextPlan, DerivedTextPiece,
    DerivedTextSequence,
    TypeKind,
    hexpr_type, hexpr_effects,
    method_call_ref_is_intrinsic, method_call_ref_is_concrete,
    method_call_ref_is_bound,
    method_call_ref_intrinsic, method_call_ref_impl,
    method_call_ref_bound, method_call_ref_bound_evidence,
    method_call_ref_receiver_mutable, method_call_ref_signature,
    method_call_ref_callee_identity,
    h_projection_kind, h_projection_nominal, h_projection_variant,
    h_projection_structural, h_projection_tuple_index,
    h_projection_intrinsic,
    h_pattern_kind, h_pattern_plan_binding, h_pattern_plan_children,
    h_pattern_plan_fields, h_pattern_plan_struct_owner,
    h_pattern_plan_variant, h_pattern_field_projection,
    h_pattern_field_pattern,
    h_operator_is_tuple, h_operator_method_ref,
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
    h_exact_call_callee, h_exact_call_method,
    h_exact_call_evidence, h_exact_call_handled_evidence,
    derived_semantic_kind_tag, DERIVED_HASH_SEED,
    validate_hir_binder_def_ids
}
use flow_ir::{
    FlowTypeNode, FlowTypeRef, FlowTypeKind,
    FlowFieldIdentity, FlowNominalFieldFact,
    FlowGenericParamFact, FlowTypeSemanticSeed,
    FlowDropContract, FlowForeignContract,
    FlowResourceDependencyEdge,
    FlowSemanticRole, FlowCallContract, FlowCallableMode,
    make_flow_type_ref, flow_type_kind_tag,
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
    make_flow_nominal_field_fact,
    flow_type_seed_shareable,
    make_flow_call_contract, make_module_flow_call_contract,
    flow_semantic_role_read, flow_semantic_role_mutate,
    make_fresh_flow_value_origin, flow_own_storage, flow_borrow_storage,
    flow_callable_mode_concrete_body, flow_callable_mode_contract_only,
    flow_callable_mode_same, flow_type_ref_index, flow_type_node_reference,
    flow_type_node_intern_ready, flow_type_node_intern_key_same,
    flow_type_node_contract_same, remap_flow_type_node
}
use core_expr::{
    CoreTypeRef, CoreTypeFactRef, CoreTypeFactAllocator, CoreTypeGraph,
    CoreEffectSet, CoreEffectAtom,
    CoreCallableContract, CoreImplMetadata, CoreAssocBinding,
    CoreBody, CoreBinder, CoreBlock, CoreStmt, CoreExpr, CorePlaceRef,
    CorePattern, CorePatternField, CoreFieldRef, CoreFieldValue,
    CoreConstructorRef, CoreCalleeRef, CoreEvidenceRef,
    CoreHandledEvidenceBinding, CoreHandledEvidenceUse,
    CoreHandledEvidenceCapture,
    CoreMatchArm, CoreHandlerOperation, CoreHandlerInstallation,
    new_core_type_fact_allocator, reserve_core_type_fact_ref,
    core_type_fact_module_key, core_type_fact_ordinal,
    core_type_fact_same, core_type_fact_local_ref,
    make_core_type_ref, make_module_core_type_graph, make_core_type_graph,
    make_core_effect_set, make_core_fail_effect, make_core_mut_effect,
    make_core_unsafe_effect, make_core_handled_effect,
    make_core_system_effect,
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
    make_core_capture, make_core_lambda_expr, make_core_block_expr, make_core_if_expr,
    make_core_match_expr, make_core_try_catch_expr, make_core_handle_expr,
    make_core_slot_place, make_core_project_place, make_core_index_place,
    make_core_nominal_field, make_core_variant_field,
    make_core_tuple_field, make_core_record_field,
    make_core_struct_constructor, make_core_variant_constructor,
    make_core_tuple_constructor, make_core_field_value,
    make_core_local_evidence, make_core_callable_evidence,
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
    remap_core_body_types, core_body_effect_sets,
    core_effect_set_atoms, core_effect_set_same,
    core_body_reference, core_body_origin,
    core_binder_reference, core_type_ref_index,
    core_handler_operation_ref
}
use core_hir::{
    CoreProgram, CoreBodyEntry, make_core_body_entry, make_core_program,
    core_body_entry_reference, core_body_entry_body,
    core_body_entry_origin, core_body_entry_anchor
}
use delegate_plan::{
    DelegateMethodPlan, DelegateEvidenceBinding,
    make_delegate_method_body_plan, make_delegate_method_plan,
    make_delegate_assoc_binding, make_delegate_evidence_binding,
    make_delegate_plan_input, validate_delegate_plan,
    delegate_plan_outcome_is_valid, delegate_plan_outcome_plan
}
use delegate_elaborate::{elaborate_delegate_to_core}
use core_elaborate::{
    make_core_ordinary_body_plan, elaborate_core_default_specialization,
    core_elaborated_body
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

pub struct CoreNominalFieldSpec {
    identity: FlowFieldIdentity,
    ty: CoreTypeFactRef
}
pub fn make_core_nominal_field_spec(
    identity: FlowFieldIdentity, ty: CoreTypeFactRef
) -> CoreNominalFieldSpec { CoreNominalFieldSpec { identity: identity, ty: ty } }

enum CoreTypeSpecValue {
    Atomic(FlowTypeKind),
    Parameter(FlowGenericParamFact),
    Nominal {
        kind: FlowTypeKind, nominal: SymbolRef,
        arguments: List<CoreTypeFactRef>, fields: List<CoreNominalFieldSpec>,
        seed: FlowTypeSemanticSeed, drop_contract: FlowDropContract?,
        resource_parameters: List<FlowGenericParamFact>,
        resource_edges: List<FlowResourceDependencyEdge>
    },
    Extern { nominal: SymbolRef, arguments: List<CoreTypeFactRef>,
             contract: FlowForeignContract,
             resource_edges: List<FlowResourceDependencyEdge> },
    Tuple { elements: List<CoreTypeFactRef>, seed: FlowTypeSemanticSeed,
            drop_contract: FlowDropContract?,
            resource_parameters: List<FlowGenericParamFact>,
            resource_edges: List<FlowResourceDependencyEdge> },
    Record { fields: List<CoreNominalFieldSpec>, seed: FlowTypeSemanticSeed,
             drop_contract: FlowDropContract?,
             resource_parameters: List<FlowGenericParamFact>,
             resource_edges: List<FlowResourceDependencyEdge> },
    Callable { parameters: List<CoreTypeFactRef>, result: CoreTypeFactRef },
    Ptr(CoreTypeFactRef)
}
struct CoreTypeSpec { value: CoreTypeSpecValue }

pub struct CoreAssemblyRecorder {
    module_key: Str, module_order: Int,
    allocator: CoreTypeFactAllocator,
    refs: List<CoreTypeFactRef>, specs: List<CoreTypeSpec?>,
    frozen: Bool
}
pub fn new_core_assembly_recorder(
    module_key: Str, module_order: Int
) -> CoreAssemblyRecorder {
    if module_key == "" || module_order < 0 {
        panic("Core assembly: invalid module identity/order")
    }
    CoreAssemblyRecorder { module_key: module_key, module_order: module_order,
        allocator: new_core_type_fact_allocator(module_key), refs: [],
        specs: [], frozen: false }
}
pub fn core_assembly_recorder_module_key(
    value: CoreAssemblyRecorder
) -> Str { value.module_key }
pub fn core_assembly_recorder_module_order(
    value: CoreAssemblyRecorder
) -> Int { value.module_order }
fn require_open(value: CoreAssemblyRecorder) {
    if value.frozen { panic("Core assembly: recorder is frozen") }
}
pub fn reserve_core_type_fact(
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
pub fn define_core_atomic_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef, k: FlowTypeKind
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Atomic(k) }) }
pub fn define_core_parameter_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef, p: FlowGenericParamFact
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Parameter(p) }) }
pub fn define_core_nominal_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef, kind: FlowTypeKind,
    nominal: SymbolRef, arguments: List<CoreTypeFactRef>,
    fields: List<CoreNominalFieldSpec>, seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?, params: List<FlowGenericParamFact>,
    edges: List<FlowResourceDependencyEdge>
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Nominal {
    kind: kind, nominal: nominal, arguments: arguments, fields: fields,
    seed: seed, drop_contract: drop_contract,
    resource_parameters: params, resource_edges: edges } }) }
pub fn define_core_extern_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef, nominal: SymbolRef,
    arguments: List<CoreTypeFactRef>, contract: FlowForeignContract,
    edges: List<FlowResourceDependencyEdge>
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Extern {
    nominal: nominal, arguments: arguments, contract: contract,
    resource_edges: edges } }) }
pub fn define_core_tuple_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef,
    elements: List<CoreTypeFactRef>, seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?, params: List<FlowGenericParamFact>,
    edges: List<FlowResourceDependencyEdge>
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Tuple {
    elements: elements, seed: seed, drop_contract: drop_contract,
    resource_parameters: params, resource_edges: edges } }) }
pub fn define_core_record_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef,
    fields: List<CoreNominalFieldSpec>, seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?, params: List<FlowGenericParamFact>,
    edges: List<FlowResourceDependencyEdge>
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Record {
    fields: fields, seed: seed, drop_contract: drop_contract,
    resource_parameters: params, resource_edges: edges } }) }
pub fn define_core_callable_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef,
    parameters: List<CoreTypeFactRef>, result: CoreTypeFactRef
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Callable {
    parameters: parameters, result: result } }) }
pub fn define_core_ptr_type_fact(
    mut r: CoreAssemblyRecorder, x: CoreTypeFactRef, pointee: CoreTypeFactRef
) { define_type(r, x, CoreTypeSpec { value: CoreTypeSpecValue::Ptr(pointee) }) }

fn local_flow_ref(value: CoreTypeFactRef, module_key: Str) -> FlowTypeRef {
    if core_type_fact_module_key(value) != module_key {
        panic("Core assembly: cross-module local type reference")
    }
    make_flow_type_ref(core_type_fact_ordinal(value))
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
            drop_contract, resource_parameters, resource_edges } => {
            let args = arguments.map(fn(v) { local_flow_ref(v, module_key) })
            let fs = fields.map(fn(f) { make_flow_nominal_field_fact(
                f.identity, local_flow_ref(f.ty, module_key)) })
            if flow_type_kind_tag(kind) == flow_type_kind_tag(flow_type_kind_struct()) {
                make_flow_struct_type_node(target, nominal, args, fs, seed,
                    drop_contract, resource_parameters, resource_edges)
            } else {
                make_flow_enum_type_node(target, nominal, args, fs, seed,
                    drop_contract, resource_parameters, resource_edges)
            }
        },
        CoreTypeSpecValue::Extern { nominal, arguments, contract, resource_edges } =>
            make_flow_extern_type_node(target, nominal,
                arguments.map(fn(v) { local_flow_ref(v, module_key) }),
                contract, resource_edges),
        CoreTypeSpecValue::Tuple { elements, seed, drop_contract,
            resource_parameters, resource_edges } => make_flow_tuple_type_node(
                target, elements.map(fn(v) { local_flow_ref(v, module_key) }),
                seed, drop_contract, resource_parameters, resource_edges),
        CoreTypeSpecValue::Record { fields, seed, drop_contract,
            resource_parameters, resource_edges } => make_flow_record_type_node(
                target, fields.map(fn(f) { make_flow_nominal_field_fact(
                    f.identity, local_flow_ref(f.ty, module_key)) }), seed,
                drop_contract, resource_parameters, resource_edges),
        CoreTypeSpecValue::Callable { parameters, result } =>
            make_flow_callable_type_node(target,
                parameters.map(fn(v) { local_flow_ref(v, module_key) }),
                local_flow_ref(result, module_key)),
        CoreTypeSpecValue::Ptr(pointee) =>
            make_flow_ptr_type_node(target, local_flow_ref(pointee, module_key))
    }
}

pub struct FrozenCoreAssemblyFacts {
    module_key: Str, module_order: Int,
    type_refs: List<CoreTypeFactRef>, type_nodes: List<FlowTypeNode>,
    type_sources: List<CoreTypeSourceFact>,
    handled_evidence_types: List<CoreHandledEvidenceTypeSource>,
    builtin_methods: List<BuiltinMethodContractFact>,
    program: HProgram
}
pub fn freeze_closed_core_assembly_facts(
    mut recorder: CoreAssemblyRecorder, closed_program: HProgram, env: TypeEnv,
    type_sources: List<CoreTypeSourceFact>,
    handled_evidence_types: List<CoreHandledEvidenceTypeSource>
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
        handled_evidence_types: handled_evidence_types,
        builtin_methods: if recorder.module_order == 0 {
            builtin_method_contract_facts(env)
        } else { [] },
        program: closed_program
    }
}
pub fn freeze_core_assembly_facts(
    recorder: CoreAssemblyRecorder, program: HProgram, env: TypeEnv,
    type_sources: List<CoreTypeSourceFact>,
    handled_evidence_types: List<CoreHandledEvidenceTypeSource>
) -> FrozenCoreAssemblyFacts {
    let closed = close_hir_surface(program, env)
    freeze_closed_core_assembly_facts(
        recorder, closed, env, type_sources, handled_evidence_types)
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
    effect_remap: CoreAssemblyEffectRemap
}
pub fn core_assembly_result_program(value: CoreAssemblyResult) -> CoreProgram { value.program }
pub fn core_assembly_result_type_remap(value: CoreAssemblyResult) -> CoreAssemblyTypeRemap { value.type_remap }
pub fn core_assembly_result_effect_remap(value: CoreAssemblyResult) -> CoreAssemblyEffectRemap { value.effect_remap }

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
    if row.tail.is_some() { panic("Core assembly: open effect row crossed Core") }
    let mut atoms: List<CoreEffectAtom> = []
    for atom in row.effects {
        atoms.push(match atom {
            Effect::FailEffect { error_type } =>
                make_core_fail_effect(type_fact_for(values, error_type, module_key)),
            Effect::MutEffect { state_type } =>
                make_core_mut_effect(type_fact_for(values, state_type, module_key)),
            Effect::UnsafeEffect => make_core_unsafe_effect(),
            Effect::CustomEffect { reference, .. } =>
                make_core_handled_effect(reference),
            Effect::SystemEffect { reference } =>
                make_core_system_effect(reference)
        })
    }
    make_core_effect_set(atoms)
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
    types: List<CoreTypeSourceFact>,
    handled_evidence_types: List<CoreHandledEvidenceTypeSource>,
    binders: List<CoreBinder>, captures: List<CaptureSlotMap>, next_origin: Int
}
fn fresh_origin(mut ctx: LowerCtx, label: Str) -> OriginRef {
    let mut path = executable_prefix(ctx.owner)
    path.push("core"); path.push(label); path.push(ctx.next_origin.to_str())
    ctx.next_origin = ctx.next_origin + 1
    make_path_origin_ref(make_path_ref(
        executable_owner(ctx.owner), path, path_role_child()))
}
fn source_slot(module_key: Str, def_id: Int) -> SlotRef {
    make_source_slot_ref(module_key, slot_domain_lexical(), def_id)
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
fn evidence(values: List<DictRef>) -> List<CoreEvidenceRef> {
    values.map(fn(value) { make_core_dict_evidence(value) })
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
                params.map(fn(t) { make_flow_type_ref(
                    core_type_ref_index(type_fact_for(
                        ctx.types, t, ctx.module_key))) }), roles,
                make_flow_type_ref(core_type_ref_index(type_fact_for(
                    ctx.types, return_type, ctx.module_key))),
                flow_semantic_role_read(), make_fresh_flow_value_origin())
        },
        _ => panic("Core assembly: call signature is not Fn")
    }
}
fn core_callee(ctx: LowerCtx, value: CalleeRef, signature: Type) -> CoreCalleeRef {
    let contract = call_contract(ctx, signature, false)
    if callee_ref_is_named(value) {
        make_core_direct_callee(
            make_named_executable_ref(callee_ref_named_symbol(value)), contract)
    } else if callee_ref_is_local(value) {
        make_core_local_callee(
            resolved_slot(ctx, callee_ref_local_slot(value)), contract)
    } else {
        make_core_dynamic_callee(callee_ref_dynamic_path(value), contract)
    }
}
fn core_field(value: HProjectionRef) -> CoreFieldRef {
    let kind = h_projection_kind(value)
    if kind == 0 { make_core_nominal_field(h_projection_nominal(value)) }
    else if kind == 1 { make_core_variant_field(h_projection_variant(value)) }
    else if kind == 2 { make_core_record_field(h_projection_structural(value)) }
    else if kind == 3 { make_core_tuple_field(h_projection_tuple_index(value)) }
    else { panic("Core assembly: intrinsic projection is not a value field") }
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
    let ty = type_fact_for(ctx.types, hexpr_type(value), ctx.module_key)
    let effects = core_effects(ctx.types, hexpr_effects(value), ctx.module_key)
    let origin = fresh_origin(ctx, "expr")
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
        HExpr::Ident { callee_identity: some(callee), ty: source_ty, .. } => {
            if !callee_ref_is_named(callee) {
                panic("Core assembly: non-local callable identity is not named")
            }
            match source_ty {
                Type::FnType { .. } => make_core_callable_value_expr(
                    ty, origin, make_named_executable_ref(
                        callee_ref_named_symbol(callee))),
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
                    make_core_method_call_expr(
                        ty, effects, origin,
                        core_callee(ctx, method_call_ref_callee_identity(method), signature),
                        method, lower_expr(ctx, left), [lower_expr(ctx, right)],
                        if method_call_ref_is_bound(method) {
                            [make_core_dict_evidence(
                                method_call_ref_bound_evidence(method))]
                        } else { [] }, [])
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
                        method, lower_expr(ctx, receiver),
                        args.map(fn(v) { lower_expr(ctx, v) }),
                        if method_call_ref_is_bound(method) {
                            [make_core_dict_evidence(
                                method_call_ref_bound_evidence(method))]
                        } else { evidence(resolved_dicts) },
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
                        evidence(resolved_dicts),
                        handled_evidence.map(fn(value) {
                            core_handled_use(ctx.handled_evidence_types, value)
                        }))
                }
            }
        },
        HExpr::FieldAccess { receiver, projection: some(p), .. } =>
            make_core_project_expr(ty, effects, origin,
                lower_expr(ctx, receiver), core_field(p), false),
        HExpr::FieldAccess { .. } =>
            panic("Core assembly: field access lacks exact projection"),
        HExpr::StructLit { owner_ref, fields, constructor: some(plan), spread, .. } => {
            if spread.is_some() || h_constructor_kind(plan) != 2 ||
               h_constructor_fields(plan).len() != fields.len() {
                panic("Core assembly: struct literal is not field-complete")
            }
            make_core_construct_expr(ty, effects, origin,
                make_core_struct_constructor(
                    owner_ref, fields.map(fn(field) { field.field_ref })),
                fields.map(fn(field) { make_core_field_value(
                    make_core_nominal_field(field.field_ref),
                    lower_expr(ctx, field.value)) }))
        },
        HExpr::NamedVariantConstruct {
            variant_ref, fields, constructor: some(plan), spread, ..
        } => {
            if spread.is_some() || h_constructor_kind(plan) != 0 {
                panic("Core assembly: variant literal is not payload-complete")
            }
            make_core_construct_expr(ty, effects, origin,
                make_core_variant_constructor(variant_ref,
                    h_constructor_executable(plan)),
                fields.map(fn(field) { make_core_field_value(
                    make_core_variant_field(field.field_ref),
                    lower_expr(ctx, field.value)) }))
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
        HExpr::Block { stmts, tail, .. } => make_core_block_expr(
            ty, effects, origin, lower_block(ctx, stmts, tail)),
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
            body, handlers, installed_evidence, ..
        } => make_core_handle_expr(
            ty, effects, origin, block_from_expr(ctx, body),
            lower_handler_installations(
                ctx, installed_evidence, handlers)),
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
        HExpr::UnsafeBlock { body, .. } => lower_expr(ctx, body),
        HExpr::ReturnExpr { value, .. } => make_core_block_expr(
            ty, effects, origin, make_core_block(
                [make_core_return_stmt(value.map(fn(v) { lower_expr(ctx, v) }), origin)],
                none, origin)),
        HExpr::StringInterp { .. } | HExpr::RangeExpr { .. } |
        HExpr::ListLit { .. } | HExpr::IndexExpr { .. } |
        HExpr::DictConstruct { .. } | HExpr::Clone { .. } |
        HExpr::Take { .. } => panic("Core assembly: surface/resource HExpr crossed PreCore")
    }
}

fn block_from_expr(ctx: LowerCtx, value: HExpr) -> CoreBlock {
    match value {
        HExpr::Block { stmts, tail, .. } => lower_block(ctx, stmts, tail),
        _ => make_core_block([], some(lower_expr(ctx, value)), fresh_origin(ctx, "block"))
    }
}

fn lower_arm(ctx: LowerCtx, value: HMatchArm, is_catch: Bool) -> CoreMatchArm {
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
        block_from_expr(ctx, value.body), fresh_origin(ctx, "arm"))
}

fn lower_handler_operation(
    ctx: LowerCtx, value: HEffectHandler
) -> CoreHandlerOperation {
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
        }), fresh_origin(ctx, "handler"))
}

fn lower_handler_installations(
    mut ctx: LowerCtx, installed: List<HandledEvidenceRef>,
    handlers: List<HEffectHandler>
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
            operations, fresh_origin(ctx, "installation")))
    }
    result
}

fn lower_place(ctx: LowerCtx, value: HExpr) -> CorePlaceRef {
    match value {
        HExpr::Ident { source_slot: some(slot), ty, .. } =>
            make_core_slot_place(ensure_binder(
                ctx, slot, ty, binder_kind_let(), false)),
        HExpr::FieldAccess { receiver, projection: some(p), ty, .. } =>
            make_core_project_place(lower_expr(ctx, receiver), core_field(p),
                type_fact_for(ctx.types, ty, ctx.module_key)),
        HExpr::IndexExpr { receiver, index, projection: some(p), ty, .. } => {
            if h_projection_kind(p) != 4 {
                panic("Core assembly: indexed place projection is not intrinsic")
            }
            make_core_index_place(lower_expr(ctx, receiver), lower_expr(ctx, index),
                h_projection_intrinsic(p),
                type_fact_for(ctx.types, ty, ctx.module_key))
        },
        _ => panic("Core assembly: assignment target is not exact place")
    }
}

fn lower_stmt(ctx: LowerCtx, value: HStmt) -> CoreStmt {
    let origin = fresh_origin(ctx, "stmt")
    match value {
        HStmt::Let { def_id: some(id), ty, init, .. } => {
            let slot = source_slot(ctx.module_key, id)
            let exact_slot = ensure_binder(
                ctx, slot, ty, binder_kind_let(), false)
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

fn lower_block(ctx: LowerCtx, stmts: List<HStmt>, tail: HExpr?) -> CoreBlock {
    make_core_block(stmts.map(fn(s) { lower_stmt(ctx, s) }),
        tail.map(fn(v) { lower_expr(ctx, v) }), fresh_origin(ctx, "block"))
}

struct ModuleAssembly {
    callables: List<CoreCallableContract>, impls: List<CoreImplMetadata>,
    entries: List<ExecutableEntry>, bodies: List<CoreBodyEntry>
}
fn empty_module_assembly() -> ModuleAssembly {
    ModuleAssembly { callables: [], impls: [], entries: [], bodies: [] }
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
fn callable_contract(
    facts: FrozenCoreAssemblyFacts, reference: ExecutableRef,
    params: List<HParam>, result: Type, mode: FlowCallableMode,
    handled_evidence: List<HandledEvidenceRef>
) -> CoreCallableContract {
    let parameter_types = params.map(fn(p) {
        type_fact_for(facts.type_sources, p.ty, facts.module_key)
    })
    let result_type = type_fact_for(facts.type_sources, result, facts.module_key)
    let slots: List<SlotRef> = if flow_callable_mode_same(
            mode, flow_callable_mode_concrete_body()) {
        params.map(fn(p) { source_slot(facts.module_key,
            match p.def_id { some(v) => v,
                none => panic("Core assembly: callable parameter lacks DefId") }) })
    } else { [] }
    make_core_callable_contract(reference, executable_origin(reference),
        parameter_types, slots, result_type, mode,
        make_module_flow_call_contract(facts.module_key,
            parameter_types.map(fn(t) { make_flow_type_ref(core_type_ref_index(t)) }),
            parameter_roles(params), make_flow_type_ref(core_type_ref_index(result_type)),
            flow_semantic_role_read(), make_fresh_flow_value_origin()),
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
        let (params, result) = match scheme.ty {
            Type::FnType { params, return_type, .. } =>
                (params, return_type),
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
            parameter_types, [], result_type,
            flow_callable_mode_contract_only(),
            make_module_flow_call_contract(
                facts.module_key,
                parameter_types.map(fn(ty) { make_flow_type_ref(
                    core_type_ref_index(ty)) }),
                read_roles(parameter_types.len()),
                make_flow_type_ref(core_type_ref_index(result_type)),
                flow_semantic_role_read(), make_fresh_flow_value_origin()),
            []))
        index = index + 1
    }
}

fn typed_callable_contract(
    facts: FrozenCoreAssemblyFacts, reference: ExecutableRef,
    parameter_types_in: List<Type>, parameter_slots: List<SlotRef>,
    parameter_mutabilities: List<Bool>, result: Type,
    mode: FlowCallableMode, handled: List<HandledEvidenceRef>
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
        reference, executable_origin(reference), parameter_types,
        if flow_callable_mode_same(mode, flow_callable_mode_concrete_body()) {
            parameter_slots
        } else { [] }, result_type, mode,
        make_module_flow_call_contract(
            facts.module_key,
            parameter_types.map(fn(ty) {
                make_flow_type_ref(core_type_ref_index(ty))
            }), roles, make_flow_type_ref(core_type_ref_index(result_type)),
            flow_semantic_role_read(), make_fresh_flow_value_origin()),
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
    let call_ctx = LowerCtx {
        module_key: facts.module_key, owner: reference,
        types: facts.type_sources,
        handled_evidence_types: facts.handled_evidence_types,
        binders: binders, captures: [], next_origin: 0
    }
    let callee = core_callee(
        call_ctx, h_exact_call_callee(forward), signature)
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
        make_core_dict_evidence(value)
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
                executable_origin(reference), callee, method,
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
    let body = core_elaborated_body(elaborate_core_default_specialization(
        make_core_ordinary_body_plan(
            reference, executable_origin(reference), binders,
            parameter_slots,
            type_fact_for(
                facts.type_sources,
                h_default_specialization_result_type(plan), facts.module_key),
            [], some(call), executable_origin(reference))))
    assembly.entries.push(make_executable_entry(
        reference, make_module_body_parent(module_body),
        executable_kind_default_specialization(),
        make_concrete_body_contract(body_anchor(reference))))
    assembly.callables.push(typed_callable_contract(
        facts, reference, parameter_types, parameter_slots,
        mutabilities, h_default_specialization_result_type(plan),
        flow_callable_mode_concrete_body(), handled))
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
    let (result, effects) = match signature {
        Type::FnType { return_type, effects, .. } => (return_type, effects),
        _ => panic("Core assembly: derived method is not callable")
    }
    let ctx = LowerCtx {
        module_key: facts.module_key, owner: owner,
        types: facts.type_sources,
        handled_evidence_types: facts.handled_evidence_types,
        binders: [], captures: [], next_origin: 0
    }
    make_core_derived_call_plan(
        core_callee(ctx, method_call_ref_callee_identity(method), signature),
        some(method),
        type_fact_for(facts.type_sources, result, facts.module_key),
        core_effects(facts.type_sources, effects, facts.module_key),
        evidence_values.map(fn(value) { make_core_dict_evidence(value) }),
        handled.map(fn(value) {
            core_handled_use(facts.handled_evidence_types, value)
        }), origin)
}

fn derived_call_plan_from_exact(
    facts: FrozenCoreAssemblyFacts, owner: ExecutableRef,
    exact: HExactCallPlan, signature: Type, origin: OriginRef
) -> CoreDerivedCallPlan {
    let (result, effects) = match signature {
        Type::FnType { return_type, effects, .. } => (return_type, effects),
        _ => panic("Core assembly: derived exact call is not callable")
    }
    let ctx = LowerCtx {
        module_key: facts.module_key, owner: owner,
        types: facts.type_sources,
        handled_evidence_types: facts.handled_evidence_types,
        binders: [], captures: [], next_origin: 0
    }
    make_core_derived_call_plan(
        core_callee(ctx, h_exact_call_callee(exact), signature),
        h_exact_call_method(exact),
        type_fact_for(facts.type_sources, result, facts.module_key),
        core_effects(facts.type_sources, effects, facts.module_key),
        h_exact_call_evidence(exact).map(fn(value) {
            make_core_dict_evidence(value)
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
                facts, method.executable_ref, value.plan,
                value.signature, origin),
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

fn exact_call_signature(
    exact: HExactCallPlan, fallback: Type?
) -> Type {
    match h_exact_call_method(exact) {
        some(method) => method_call_ref_signature(method),
        none => match fallback {
            some(value) => value,
            none => panic("Core assembly: direct exact call lacks signature")
        }
    }
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
    let builder_signature = text.builder_signature
    let builder_call = derived_call_plan_from_exact(
        facts, method.executable_ref, text.builder,
        builder_signature, origin)
    let builder_type = match builder_signature {
        Type::FnType { return_type, .. } => type_fact_for(
            facts.type_sources, return_type, facts.module_key),
        _ => panic("Core assembly: text builder is not callable")
    }
    let builder_binder = core_binder_from_entry(
        facts, text.builder_binder, builder_type)
    append_unique_core_binder(binders, builder_binder)
    let append_signature = exact_call_signature(text.append, none)
    let append_call = derived_call_plan_from_exact(
        facts, method.executable_ref, text.append,
        append_signature, origin)
    let unit_type = match append_signature {
        Type::FnType { return_type, .. } => type_fact_for(
            facts.type_sources, return_type, facts.module_key),
        _ => panic("Core assembly: text append is not callable")
    }
    let finish_call = derived_call_plan_from_exact(
        facts, method.executable_ref, text.finish,
        exact_call_signature(text.finish, none), origin)
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
        let (parameter_types, result_type, _) = match method.signature {
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
            mutabilities, result_type, flow_callable_mode_concrete_body(),
            method.handled_evidence_bindings))
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
        derived.owner_ref, methods, [], []))
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
            types: facts.type_sources,
            handled_evidence_types: facts.handled_evidence_types,
            binders: binders, captures: [], next_origin: 0
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
                make_core_dict_evidence(value)
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
            child_call,
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
            make_core_dict_evidence(dict_values.get(dict_index).unwrap())))
        dict_index = dict_index + 1
    }
    let child_owner = h_delegate_child_owner(plan)
    let outcome = validate_delegate_plan(make_delegate_plan_input(
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
        assoc, dict_bindings, false))
    if !delegate_plan_outcome_is_valid(outcome) {
        panic("Core assembly: exact delegate plan was rejected")
    }
    let (metadata, bodies) = elaborate_delegate_to_core(
        delegate_plan_outcome_plan(outcome))
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
            flow_callable_mode_concrete_body(),
            h_delegate_method_handled_bindings(method)))
        assembly.bodies.push(make_core_body_entry(
            reference, h_delegate_method_origin(method),
            body_anchor(reference), body))
        body_index = body_index + 1
    }
}
fn add_executable_body(
    facts: FrozenCoreAssemblyFacts, parent: ExecutableParentRef,
    reference: ExecutableRef, kind: ExecutableKind,
    params: List<HParam>, result_type: Type, body_expr: HExpr,
    handled_evidence: List<HandledEvidenceRef>,
    handled_captures: List<HandledEvidenceCapture>,
    capture_bindings: List<CaptureSlotMap>,
    mut assembly: ModuleAssembly
) {
    let anchor = body_anchor(reference)
    assembly.entries.push(make_executable_entry(
        reference, parent, kind, make_concrete_body_contract(anchor)))
    assembly.callables.push(callable_contract(
        facts, reference, params, result_type,
        flow_callable_mode_concrete_body(), handled_evidence))
    let mut ctx = LowerCtx { module_key: facts.module_key,
        owner: reference, types: facts.type_sources,
        handled_evidence_types: facts.handled_evidence_types,
        binders: [], captures: capture_bindings, next_origin: 0 }
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
    scan_nested_expr(facts, reference, body_expr, assembly)
}
fn add_contract_only(
    facts: FrozenCoreAssemblyFacts, parent: ExecutableParentRef,
    reference: ExecutableRef, kind: ExecutableKind,
    params: List<HParam>, result_type: Type,
    handled_evidence: List<HandledEvidenceRef>,
    mut assembly: ModuleAssembly
) {
    assembly.entries.push(make_executable_entry(
        reference, parent, kind, make_contract_only()))
    assembly.callables.push(callable_contract(
        facts, reference, params, result_type,
        flow_callable_mode_contract_only(), handled_evidence))
}

fn scan_nested_stmt(
    facts: FrozenCoreAssemblyFacts, parent: ExecutableRef,
    value: HStmt, mut assembly: ModuleAssembly
) {
    match value {
        HStmt::Let { init, .. } | HStmt::Var { init, .. } |
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
                return_type, body, handled_evidence_bindings,
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
                    hexpr_type(handler.body), handler.body,
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
        HExpr::MatchExpr { scrutinee, arms, .. } |
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
        HExpr::UnaryOp { operand, .. } |
        HExpr::FieldAccess { receiver: operand, .. } |
        HExpr::UnsafeBlock { body: operand, .. } =>
            scan_nested_expr(facts, parent, operand, assembly),
        HExpr::StructLit { fields, .. } => {
            for field in fields {
                scan_nested_expr(facts, parent, field.value, assembly)
            }
        },
        HExpr::NamedVariantConstruct { fields, .. } => {
            for field in fields {
                scan_nested_expr(facts, parent, field.value, assembly)
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
    if executable_ref_origin_module_key(reference) == "$prelude" {
        make_module_body_parent(make_module_body_ref(
            "$prelude", "prelude-physical-source"))
    } else { make_module_body_parent(module_body) }
}

fn assemble_decls(
    facts: FrozenCoreAssemblyFacts, module_body: ModuleBodyRef,
    decls: List<HDecl>, mut assembly: ModuleAssembly
) {
    for decl in decls {
        match decl {
            HDecl::Fn { executable_ref, impl_method_ref, params,
                return_type, handled_evidence_bindings, body, .. } =>
                add_executable_body(
                    facts, source_parent(module_body, executable_ref), executable_ref,
                    if impl_method_ref.is_some() { executable_kind_impl_method() }
                    else { executable_kind_fn() },
                    params, return_type, body, handled_evidence_bindings,
                    [], [], assembly),
            HDecl::Test { executable_ref, handled_evidence_bindings,
                          body, .. } => add_executable_body(
                facts, source_parent(module_body, executable_ref), executable_ref,
                executable_kind_test(), [], hexpr_type(body), body,
                handled_evidence_bindings, [], [], assembly),
            HDecl::Const { executable_ref, handled_evidence_bindings,
                           ty, init, .. } => add_executable_body(
                facts, source_parent(module_body, executable_ref), executable_ref,
                executable_kind_const_getter(), [], ty, init,
                handled_evidence_bindings, [], [], assembly),
            HDecl::ExternFn { executable_ref, params, return_type,
                              handled_evidence_bindings, .. } =>
                add_contract_only(facts, source_parent(module_body, executable_ref),
                    executable_ref, executable_kind_extern_fn(),
                    params, return_type, handled_evidence_bindings, assembly),
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
                            method.return_type, body,
                            method.handled_evidence_bindings,
                            [], [], assembly),
                        none => add_contract_only(
                            facts, source_parent(module_body, reference),
                            reference, executable_kind_bodyless_trait_member(),
                            method.params, method.return_type,
                            method.handled_evidence_bindings, assembly)
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
                            owner_ref, method_refs, bindings, []))
                    }
                }
            },
            HDecl::ModBlock { decls: nested, .. } =>
                assemble_decls(facts, module_body, nested, assembly),
            HDecl::Effect { ops, .. } => {
                for op in ops {
                    match op.operation_ref {
                        some(reference) => add_contract_only(
                            facts, source_parent(
                                module_body,
                                effect_operation_ref_callable(reference)),
                            effect_operation_ref_callable(reference),
                            executable_kind_bodyless_effect_operation(),
                            op.params, op.return_type,
                            [effect_operation_handled_binding(reference)],
                            assembly),
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
fn assemble_all(values: List<FrozenCoreAssemblyFacts>) -> CoreAssemblyResult {
    if values.len() == 0 { panic("Core assembly: project has no modules") }
    validate_fact_order(values)
    let project = intern_project_types(values)
    let mut callables: List<CoreCallableContract> = []
    let mut impls: List<CoreImplMetadata> = []
    let mut entries: List<ExecutableEntry> = []
    let mut bodies: List<CoreBodyEntry> = []
    let mut type_entries: List<CoreAssemblyTypeRemapEntry> = []
    let mut effect_entries: List<CoreAssemblyEffectRemapEntry> = []
    let mut module_index = 0
    while module_index < values.len() {
        let facts = values.get(module_index).unwrap()
        let mapping = project.mappings.get(module_index).unwrap()
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
    CoreAssemblyResult {
        program: make_core_program(project.graph, callables, impls, bodies,
            make_executable_inventory(entries)),
        type_remap: CoreAssemblyTypeRemap { entries: type_entries },
        effect_remap: CoreAssemblyEffectRemap { entries: effect_entries }
    }
}
pub fn assemble_single_core(facts: FrozenCoreAssemblyFacts) -> CoreAssemblyResult {
    if facts.module_order != 0 { panic("Core assembly: single module order differs") }
    assemble_all([facts])
}
pub fn assemble_project_core(
    facts_in_topological_order: List<FrozenCoreAssemblyFacts>
) -> CoreAssemblyResult { assemble_all(facts_in_topological_order) }
