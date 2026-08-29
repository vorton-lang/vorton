// Mechanical verified Core/Flow/RcIR -> legacy HIR bridge for the 0.1 C
// cutover.  This module never invokes Core->Flow lowering or ResourcePlanner.
// It accepts only the opaque result that retains the exact three verified
// stages and relates every Rc site to the sole lowerer's Core node map.

use ir_identity::{
    CoreTypeRef,
    OriginRef, SlotRef, CalleeRef, ImplOwnerRef, ImplMethodRef,
    RegisteredNominalRef, VariantRef,
    SymbolRef, PathRef,
    origin_ref_same, slot_ref_same, slot_ref_is_source,
    slot_ref_synthetic_path,
    symbol_ref_canonical_payload, symbol_ref_same,
    handled_effect_ref_symbol,
    registered_nominal_ref_display_name, registered_nominal_ref_symbol,
    nominal_field_ref_owner,
    nominal_field_ref_name, nominal_field_ref_index,
    variant_ref_owner, variant_ref_member,
    variant_ref_same,
    variant_field_ref_member, variant_field_ref_index,
    impl_owner_ref_provider, impl_owner_ref_target,
    impl_method_ref_member, impl_method_ref_name,
    impl_owner_ref_same, impl_method_ref_same,
    trait_method_ref_name, intrinsic_ref_symbol,
    make_named_callee_ref,
    path_ref_normalized_child_path,
    module_body_ref_origin_module_key
}
use ir_inventory::{
    ExecutableRef, ExecutableKind, ExactMethodRef,
    executable_ref_same, executable_ref_is_named,
    make_named_executable_ref,
    executable_ref_named_symbol, executable_ref_anonymous_path,
    executable_kind_same, executable_kind_fn,
    executable_kind_impl_method, executable_kind_trait_default,
    executable_kind_test,
    executable_kind_const_getter, executable_kind_lambda,
    executable_kind_handler, executable_kind_default_specialization,
    executable_kind_derived_impl,
    executable_kind_dict_helper,
    EffectCtxRef, EffectCtxParentCapture,
    effect_ctx_parent_capture_source, effect_ctx_parent_capture_target,
    effect_operation_ref_effect, effect_operation_ref_member,
    system_host_callable_executable,
    exact_method_ref_is_intrinsic, exact_method_ref_is_impl,
    exact_method_ref_is_trait, exact_method_ref_intrinsic,
    exact_method_ref_impl, exact_method_ref_trait
}
use resource_model::{
    flow_call_contract_parameter_types,
    flow_call_contract_parameter_roles,
    flow_call_contract_result_type,
    flow_semantic_role_tag, flow_semantic_role_mutate
}
use core_type_source::{core_type_graph_count}
use ast::{
    Span, Pattern, LiteralValue, BinOp, UnaryOp,
    TypeParam, TypeBound, NamedPatternField, span_zero
}
use types::{Type, Effect, EffectRow, EMPTY_ROW, types_equal}
use hir::{
    HProgram, HDecl, HExpr, HStmt, HParam, HMatchArm, HPatternBinding,
    HEffectHandler, HLambdaCapture, HAssocType, HEnumVariant, HTypeParam,
    HEffectOp, HTraitMethod, TraitBound, HPatternPlan, HProjectionRef,
    h_fail_raise_ref,
    h_nominal_projection, h_variant_projection,
    h_structural_projection, h_tuple_projection,
    make_h_pattern_field_plan,
    h_pattern_wildcard, h_pattern_binding, h_pattern_literal,
    h_pattern_tuple, h_pattern_struct, h_pattern_variant,
    make_h_variant_constructor_plan, make_h_tuple_constructor_plan,
    make_h_record_constructor_plan,
    HFieldAccessKind, HNominalStructFieldInit, HStructFieldInit,
    HResourceSite,
    DictRef, MethodCallRef,
    make_intrinsic_method_call_ref, make_concrete_method_call_ref,
    make_bound_method_call_ref,
    synthetic_def_id, SYNTHETIC_ANF_DEF_ID_BASE,
    validate_hir_binder_def_ids,
    make_h_instruction_resource_site, make_h_terminator_resource_site,
    h_resource_reason_take, h_resource_reason_drop,
    h_resource_reason_cleanup, h_resource_reason_drop_projected_old
}
use flow_ir::{
    FlowProgram, FlowBody, FlowInstruction, FlowSemanticStepRef,
    FlowProjectionContract,
    make_flow_instruction_step_ref, make_flow_terminator_step_ref,
    flow_semantic_step_same, flow_semantic_step_is_instruction,
    flow_semantic_step_instruction, flow_semantic_step_terminator,
    flow_instruction_ref_owner, flow_instruction_ref_same,
    flow_instruction_ref_block_ordinal,
    flow_instruction_ref_ordinal,
    flow_block_ref_owner, flow_block_ref_ordinal,
    flow_program_bodies, flow_program_topology_fingerprint,
    flow_topology_fingerprint_canonical,
    flow_body_reference, flow_body_slots, flow_body_blocks,
    flow_block_instructions,
    flow_instruction_reference, flow_instruction_kind_tag,
    flow_assign_rhs_temp, flow_assign_target,
    flow_move_place_source, flow_move_place_target,
    flow_place_is_slot, flow_place_slot, flow_place_base,
    flow_place_projection,
    flow_projection_contract_same,
    flow_projection_contract_result_type,
    flow_project_contract, flow_project_base, flow_project_result,
    flow_initialize_operation, flow_initialize_inputs, flow_initialize_target,
    flow_operation_contract_kind_tag, flow_operation_contract_variant,
    flow_fail_raise_sink,
    flow_slot_reference, flow_slot_type
}
use core_hir::{
    CoreProgram, CoreBodyEntry,
    core_program_bodies, core_program_type_graph, core_program_callables,
    core_program_impls,
    core_body_entry_reference, core_body_entry_body
}
use core_expr::{
    CoreBody, CoreBinder, CoreBlock, CoreStmt, CoreExpr, CoreMatchArm,
    CorePattern, CorePatternField, CoreFieldRef, CoreFieldValue,
    CoreCalleeRef, CoreEvidenceRef, CoreConstructorRef, CorePlaceRef,
    CoreImplMetadata, CoreCallableContract,
    CoreEffectCtxTokenRef, CoreEffectCtxLayout,
    CoreCallableEffectCtx, CoreEffectCtxArgument, CoreEffectCtxLookup,
    CoreHandlerOperation, CoreHandlerInstallation,
    core_callable_reference, core_callable_effect_ctx,
    core_callable_effect_ctx_reference, core_callable_effect_ctx_layout,
    core_body_reference, core_body_origin, core_body_block,
    core_body_binders,
    core_binder_reference, core_binder_type,
    core_block_statements, core_block_tail,
    core_stmt_kind_tag, core_stmt_origin, core_stmt_value,
    core_stmt_target,
    core_stmt_bind_is_mutable,
    core_stmt_while_condition, core_stmt_while_body,
    core_stmt_return_value,
    core_stmt_destructure_scrutinee, core_stmt_destructure_pattern,
    core_expr_kind_tag, core_expr_origin,
    core_expr_type, core_expr_effects,
    core_expr_literal, core_literal_kind_tag, core_literal_int,
    core_literal_float, core_literal_str, core_literal_bool,
    core_expr_read_source, core_expr_callable_executable,
    core_expr_primitive_operation, core_primitive_op_tag,
    core_expr_primitive_operands,
    core_expr_call_callee, core_expr_call_arguments,
    core_expr_call_evidence, core_expr_call_effect_ctx_argument,
    core_expr_effect_ctx_lookup,
    core_expr_method_ref,
    core_expr_method_receiver, core_expr_effect_operation,
    core_expr_system_host, core_expr_fail_payload,
    core_expr_project_base, core_expr_project_field,
    core_expr_constructor, core_expr_constructor_fields,
    core_expr_move_update_base, core_expr_move_update_constructor,
    core_expr_move_update_schema, core_expr_move_update_overrides,
    core_expr_lambda_executable, core_expr_lambda_captures,
    core_capture_source, core_capture_target,
    core_expr_block, core_expr_then_block, core_expr_else_block,
    core_expr_condition, core_expr_scrutinee,
    core_expr_match_arms, core_expr_try_body, core_expr_handle_body,
    core_expr_error_slot, core_expr_effect_ctx_install,
    core_match_arm_pattern, core_match_arm_guard, core_match_arm_body,
    core_pattern_kind_tag, core_pattern_type, core_pattern_binding,
    core_pattern_literal, core_pattern_elements, core_pattern_fields,
    core_pattern_struct_owner, core_pattern_variant,
    core_pattern_field_ref, core_pattern_field_pattern,
    core_field_ref_kind_tag, core_field_ref_nominal,
    core_field_ref_variant, core_field_ref_tuple_index,
    core_field_ref_record_path, core_field_ref_record_name,
    core_field_ref_same,
    make_core_tuple_field,
    core_field_value_field, core_field_value_expr,
    core_place_is_slot, core_place_slot, core_place_base,
    core_place_field,
    core_place_value_type,
    core_constructor_kind_tag, core_constructor_struct_owner,
    core_constructor_variant,
    core_callee_ref, core_callee_kind_tag, core_callee_direct,
    core_callee_local, core_callee_dynamic, core_callee_contract,
    core_callee_effect_instantiation,
    core_evidence_dict,
    core_handler_installation_token,
    core_handler_installation_operations,
    core_handler_operation_ref, core_handler_operation_executable,
    core_handler_operation_parameter_slots,
    core_handler_operation_resume_slot,
    core_handler_operation_captures,
    core_handler_operation_parent_ctx,
    core_effect_ctx_install_parent, core_effect_ctx_install_child,
    core_effect_ctx_install_entries,
    core_effect_ctx_token_instance,
    core_effect_ctx_layout_entries, core_effect_ctx_layout_formal,
    core_effect_ctx_argument_kind_tag, core_effect_ctx_argument_context,
    core_effect_ctx_argument_target_layout,
    core_effect_ctx_lookup_context, core_effect_ctx_lookup_token,
    core_impl_owner, core_impl_methods, core_impl_assoc_bindings,
    core_assoc_binding_member
}
use effect_contract::{
    CoreEffectSet, TypedHandledEffectInstance,
    TypedEffectCtxLayout, TypedCallableEffectCtx,
    TypedEffectCtxSource, TypedEffectCtxLookup,
    make_typed_handled_effect_instance,
    make_typed_effect_ctx_layout, make_typed_callable_effect_ctx,
    make_empty_effect_ctx_source, make_borrowed_effect_ctx_source,
    make_typed_effect_ctx_lookup, make_typed_effect_ctx_install,
    core_effect_atom_handled_ref, core_effect_atom_type_arguments,
    core_effect_instantiation_result, core_effect_contract_exact
}
use flow_lower::{
    CoreFlowNodeRef, CoreFlowStepMap, CoreFlowStepRelation, CoreFlowStepRole,
    core_flow_step_map_node_count, core_flow_step_map_nodes,
    core_flow_step_map_relations,
    core_flow_step_node, core_flow_step, core_flow_step_role,
    core_flow_step_role_ordinal,
    core_flow_step_role_is_expr_primary,
    core_flow_step_role_is_stmt_assign,
    core_flow_step_role_is_control_dispatch,
    core_flow_step_role_is_branch_merge,
    core_flow_step_role_is_control_exit,
    core_flow_step_role_is_body_return,
    core_flow_node_owner, core_flow_node_ordinal,
    core_flow_node_kind_tag, core_flow_node_origin,
    core_flow_node_anchor_slot
}
use rc_ir::{
    RcProgram, RcBody, RcBlock, RcStep, RcEdge, RcOperation,
    rc_program_bodies, rc_body_reference, rc_body_blocks,
    rc_block_source_ref, rc_block_steps, rc_block_before_terminator,
    rc_block_edges, rc_step_instruction, rc_step_before, rc_step_after,
    rc_edge_successor_ordinal, rc_edge_cleanup,
    rc_operation_site,
    rc_operation_kind, rc_operation_source, rc_operation_target,
    rc_operation_place_projection,
    rc_op_kind_same, rc_op_kind_clone, rc_op_kind_take,
    rc_op_kind_drop, rc_op_kind_cleanup, rc_op_kind_drop_old_place,
    rc_semantic_site_is_instruction, rc_semantic_site_instruction,
    rc_semantic_site_block, rc_semantic_site_successor_ordinal,
    rc_semantic_site_operand_ordinal, rc_semantic_site_placement,
    rc_site_placement_tag
}
use legacy_projection::{
    LegacyProjectionTable, LegacyTypeProjection, LegacyEffectProjection,
    LegacyBinderProjection, LegacyCallableProjection,
    LegacyTypeParameterProjection, LegacyTraitBoundProjection,
    LegacyImplProjection, LegacyAssocBindingProjection,
    LegacyEffectCtxToken,
    make_legacy_binder_projection,
    legacy_projection_core_type_count,
    legacy_projection_type_for, legacy_projection_effect_for,
    legacy_projection_binder_for, legacy_projection_callable_for,
    legacy_projection_impl_for, legacy_projection_dictionary,
    legacy_projection_executable_physical_identity,
    legacy_projection_effect_ctx_tokens,
    legacy_effect_ctx_token_ordinal, legacy_effect_ctx_token_instance,
    legacy_type_projection_type, legacy_effect_projection_row,
    legacy_binder_projection_name, legacy_binder_projection_def_id,
    legacy_binder_projection_type, legacy_binder_projection_is_mutable,
    legacy_callable_reference, legacy_callable_kind,
    legacy_callable_type_parameters, legacy_callable_bounds,
    legacy_callable_parameters, legacy_callable_result_type,
    legacy_callable_effects, legacy_callable_is_public,
    legacy_callable_module,
    legacy_type_parameter_name, legacy_type_parameter_var_id,
    legacy_type_parameter_bounds,
    legacy_trait_bound_parameter_index, legacy_trait_bound_trait,
    legacy_impl_owner, legacy_impl_target_type, legacy_impl_trait,
    legacy_impl_target_nominal,
    legacy_impl_type_parameters, legacy_impl_assoc_bindings,
    legacy_impl_methods, legacy_impl_container, legacy_impl_module,
    legacy_container_is_module,
    legacy_assoc_binding_member, legacy_assoc_binding_type
}
use resource_planner::{
    VerifiedResourceProgram,
    verified_resource_program_flow_fingerprint,
    verified_resource_program_rc_ir
}
use ownership_pipeline::{
    VerifiedOwnershipProgram,
    verified_ownership_program_core,
    verified_ownership_program_flow,
    verified_ownership_program_resources,
    verified_ownership_program_step_map
}

const BRIDGE_RC_BEFORE_INSTRUCTION: Int = 0
const BRIDGE_RC_AFTER_INSTRUCTION: Int = 1
const BRIDGE_RC_BEFORE_TERMINATOR: Int = 2
const BRIDGE_RC_EDGE_CLEANUP: Int = 3

pub struct BridgeRcEvent {
    ordinal: Int,
    node: CoreFlowNodeRef,
    step: FlowSemanticStepRef,
    role: CoreFlowStepRole,
    placement: Int,
    operand_ordinal: Int,
    successor_ordinal: Int?,
    operation: RcOperation
}
pub fn bridge_rc_event_ordinal(value: BridgeRcEvent) -> Int { value.ordinal }

pub fn bridge_rc_event_node(value: BridgeRcEvent) -> CoreFlowNodeRef {
    value.node
}
pub fn bridge_rc_event_step(value: BridgeRcEvent) -> FlowSemanticStepRef {
    value.step
}
pub fn bridge_rc_event_role(value: BridgeRcEvent) -> CoreFlowStepRole {
    value.role
}
pub fn bridge_rc_event_placement(value: BridgeRcEvent) -> Int {
    value.placement
}
pub fn bridge_rc_event_operand_ordinal(value: BridgeRcEvent) -> Int {
    value.operand_ordinal
}
pub fn bridge_rc_event_successor_ordinal(value: BridgeRcEvent) -> Int? {
    value.successor_ordinal
}
pub fn bridge_rc_event_operation(value: BridgeRcEvent) -> RcOperation {
    value.operation
}

struct VerifiedBridgeStages {
    core: CoreProgram,
    flow: FlowProgram,
    resources: VerifiedResourceProgram,
    rc: RcProgram,
    step_map: CoreFlowStepMap,
    events: List<BridgeRcEvent>
}

struct HirBridgeCtx {
    shell: HProgram,
    stages: VerifiedBridgeStages,
    projection: LegacyProjectionTable,
    next_node_ordinal: Int,
    consumed_bodies: List<ExecutableRef>,
    consumed_events: List<Int>
}

fn consume_event(mut ctx: HirBridgeCtx, value: BridgeRcEvent) {
    if ctx.consumed_events.contains(value.ordinal) {
        panic("RcHIR bridge: verified resource event serialized twice")
    }
    ctx.consumed_events.push(value.ordinal)
}

fn nominal_owner_in_decls_opt(
    decls: List<HDecl>, symbol: SymbolRef
) -> RegisteredNominalRef? {
    let mut found: RegisteredNominalRef? = none
    for decl in decls {
        match decl {
            HDecl::Struct { owner_ref, .. } => if symbol_ref_same(
                registered_nominal_ref_symbol(owner_ref), symbol) {
                if found.is_some() {
                    panic("RcHIR bridge: nominal shell owner repeats")
                }
                found = some(owner_ref)
            },
            HDecl::Enum { owner_ref, .. } => if symbol_ref_same(
                registered_nominal_ref_symbol(owner_ref), symbol) {
                if found.is_some() {
                    panic("RcHIR bridge: nominal shell owner repeats")
                }
                found = some(owner_ref)
            },
            HDecl::ModBlock { decls: nested, .. } => {
                let nested_owner = nominal_owner_in_decls_opt(nested, symbol)
                match nested_owner {
                    some(owner) => {
                        if found.is_some() {
                            panic("RcHIR bridge: nominal shell owner repeats")
                        }
                        found = some(owner)
                    },
                    none => {}
                }
            },
            _ => {}
        }
    }
    found
}
fn nominal_owner_in_decls(
    decls: List<HDecl>, symbol: SymbolRef
) -> RegisteredNominalRef {
    match nominal_owner_in_decls_opt(decls, symbol) {
        some(value) => value,
        none => panic("RcHIR bridge: exact nominal shell owner is absent")
    }
}

fn legacy_type_for(
    projection: LegacyProjectionTable, core_type: CoreTypeRef
) -> Type {
    legacy_type_projection_type(
        legacy_projection_type_for(projection, core_type))
}
fn typed_effect_ctx_instance(
    projection: LegacyProjectionTable, token: CoreEffectCtxTokenRef
) -> TypedHandledEffectInstance {
    let atom = core_effect_ctx_token_instance(token)
    make_typed_handled_effect_instance(
        core_effect_atom_handled_ref(atom),
        core_effect_atom_type_arguments(atom).map(fn(ty) {
            legacy_type_for(projection, ty)
        }))
}
fn typed_effect_ctx_layout(
    projection: LegacyProjectionTable,
    value: CoreEffectCtxLayout
) -> TypedEffectCtxLayout {
    make_typed_effect_ctx_layout(
        core_effect_ctx_layout_entries(value).map(fn(token) {
            typed_effect_ctx_instance(projection, token)
        }), core_effect_ctx_layout_formal(value))
}
fn typed_callable_effect_ctx(
    projection: LegacyProjectionTable,
    value: CoreCallableEffectCtx
) -> TypedCallableEffectCtx {
    make_typed_callable_effect_ctx(
        core_callable_effect_ctx_reference(value),
        typed_effect_ctx_layout(
            projection, core_callable_effect_ctx_layout(value)))
}
fn typed_effect_ctx_source(
    value: CoreEffectCtxArgument
) -> TypedEffectCtxSource {
    if core_effect_ctx_argument_kind_tag(value) == 0 {
        make_empty_effect_ctx_source()
    } else {
        make_borrowed_effect_ctx_source(
            core_effect_ctx_argument_context(value))
    }
}
fn typed_effect_ctx_lookup(
    projection: LegacyProjectionTable,
    value: CoreEffectCtxLookup
) -> TypedEffectCtxLookup {
    make_typed_effect_ctx_lookup(
        core_effect_ctx_lookup_context(value),
        typed_effect_ctx_instance(
            projection, core_effect_ctx_lookup_token(value)))
}

fn legacy_effects_for(
    projection: LegacyProjectionTable,
    core_effects: CoreEffectSet
) -> EffectRow {
    validate_legacy_effect_row(legacy_effect_projection_row(
        legacy_projection_effect_for(projection, core_effects)))
}
fn validate_legacy_effect_row(row: EffectRow) -> EffectRow {
    if row.tail.is_some() {
        panic("RcHIR bridge: open effect row crossed Core closure")
    }
    row
}

fn projected_binder_for(
    projection: LegacyProjectionTable, slot: SlotRef
) -> LegacyBinderProjection {
    legacy_projection_binder_for(projection, slot)
}

fn flow_admin_slot_ordinal(flow: FlowProgram, target: SlotRef) -> Int? {
    if slot_ref_is_source(target) { return none }
    let path = path_ref_normalized_child_path(slot_ref_synthetic_path(target))
    let mut is_flow_admin = false
    for component in path {
        if component == "$flow" { is_flow_admin = true }
    }
    if !is_flow_admin { return none }
    let mut ordinal = 0
    for body in flow_program_bodies(flow) {
        for slot in flow_body_slots(body) {
            if slot_ref_same(flow_slot_reference(slot), target) {
                return some(ordinal)
            }
            ordinal = ordinal + 1
        }
    }
    panic("RcHIR bridge: Flow admin slot is absent from frozen FlowIR")
}

fn bridge_binder_for(
    ctx: HirBridgeCtx, slot: SlotRef
) -> LegacyBinderProjection {
    match flow_admin_slot_ordinal(ctx.stages.flow, slot) {
        some(ordinal) => {
            let mut flow_type: CoreTypeRef? = none
            for body in flow_program_bodies(ctx.stages.flow) {
                for candidate in flow_body_slots(body) {
                    if slot_ref_same(flow_slot_reference(candidate), slot) {
                        flow_type = some(flow_slot_type(candidate))
                    }
                }
            }
            let core_type = match flow_type {
                some(value) => value,
                none => panic("RcHIR bridge: Flow admin slot type is absent")
            }
            make_legacy_binder_projection(
                slot, "__flow_${ordinal}",
                synthetic_def_id(SYNTHETIC_ANF_DEF_ID_BASE, ordinal + 1),
                core_type, legacy_type_for(ctx.projection, core_type), false)
        },
        none => projected_binder_for(ctx.projection, slot)
    }
}

fn projected_binder_ident(
    projection: LegacyProjectionTable, slot: SlotRef
) -> HExpr {
    let binder = projected_binder_for(projection, slot)
    HExpr::Ident {
        name: legacy_binder_projection_name(binder),
        resolved_name: none,
        def_id: some(legacy_binder_projection_def_id(binder)),
        source_slot: if slot_ref_is_source(slot) { some(slot) } else { none },
        callee_identity: none,
        dict_closure_dicts: none,
        callable_instantiation: none,
        ty: legacy_binder_projection_type(binder),
        effects: EMPTY_ROW,
        span: span_zero()
    }
}

fn bridge_binder_ident(ctx: HirBridgeCtx, slot: SlotRef) -> HExpr {
    let binder = bridge_binder_for(ctx, slot)
    HExpr::Ident {
        name: legacy_binder_projection_name(binder), resolved_name: none,
        def_id: some(legacy_binder_projection_def_id(binder)),
        source_slot: if slot_ref_is_source(slot) { some(slot) } else { none },
        callee_identity: none, dict_closure_dicts: none,
        callable_instantiation: none,
        ty: legacy_binder_projection_type(binder),
        effects: EMPTY_ROW, span: span_zero()
    }
}

fn executable_identity(
    projection: LegacyProjectionTable, value: ExecutableRef
) -> Str {
    legacy_projection_executable_physical_identity(projection, value)
}

fn executable_ident(
    projection: LegacyProjectionTable, executable: ExecutableRef,
    ty: Type
) -> HExpr {
    let _ = legacy_projection_callable_for(projection, executable)
    let identity = executable_identity(projection, executable)
    HExpr::Ident {
        name: identity, resolved_name: some(identity), def_id: none,
        source_slot: none,
        callee_identity: if executable_ref_is_named(executable) {
            some(make_named_callee_ref(executable_ref_named_symbol(executable)))
        } else { none },
        dict_closure_dicts: none, callable_instantiation: none,
        ty: ty, effects: EMPTY_ROW,
        span: span_zero()
    }
}

fn evidence_dict(
    projection: LegacyProjectionTable, value: CoreEvidenceRef
) -> DictRef {
    legacy_projection_dictionary(projection, core_evidence_dict(value))
}

fn legacy_type_params(
    values: List<LegacyTypeParameterProjection>
) -> List<HTypeParam> {
    values.map(fn(value) {
        let bound_refs = legacy_type_parameter_bounds(value)
        HTypeParam {
            source: TypeParam {
                name: legacy_type_parameter_name(value),
                bounds: bound_refs.map(fn(bound) {
                TypeBound {
                    trait_name: symbol_ref_canonical_payload(bound),
                    type_args: [], assoc_constraints: [], span: span_zero()
                }
            }),
                span: span_zero()
            },
            type_var_id: legacy_type_parameter_var_id(value),
            bound_refs: bound_refs
        }
    })
}

fn legacy_trait_bounds(
    callable: LegacyCallableProjection
) -> List<TraitBound> {
    let parameters = legacy_callable_type_parameters(callable)
    let mut result: List<TraitBound> = []
    let mut ordinal = 0
    for bound in legacy_callable_bounds(callable) {
        let index = legacy_trait_bound_parameter_index(bound)
        let parameter = parameters.get(index).unwrap_or_else(fn() {
            panic("RcHIR bridge: callable trait-bound parameter is absent")
        })
        result.push(TraitBound {
            type_param: legacy_type_parameter_name(parameter),
            type_var_id: legacy_type_parameter_var_id(parameter),
            trait_name: symbol_ref_canonical_payload(
                legacy_trait_bound_trait(bound)),
            trait_ref: legacy_trait_bound_trait(bound),
            dict_ordinal: ordinal
        })
        ordinal = ordinal + 1
    }
    result
}

fn legacy_params(callable: LegacyCallableProjection) -> List<HParam> {
    legacy_callable_parameters(callable).map(fn(value) {
        HParam {
            name: legacy_binder_projection_name(value),
            ty: legacy_binder_projection_type(value),
            def_id: some(legacy_binder_projection_def_id(value)),
            is_mutable: legacy_binder_projection_is_mutable(value)
        }
    })
}

fn callable_fn_type(callable: LegacyCallableProjection) -> Type {
    Type::FnType {
        params: legacy_callable_parameters(callable).map(fn(parameter) {
            legacy_binder_projection_type(parameter)
        }),
        return_type: legacy_callable_result_type(callable),
        effects: validate_legacy_effect_row(legacy_callable_effects(callable))
    }
}

fn h_resource_site_for_step(step: FlowSemanticStepRef) -> HResourceSite {
    if flow_semantic_step_is_instruction(step) {
        let instruction = flow_semantic_step_instruction(step)
        make_h_instruction_resource_site(
            flow_instruction_ref_owner(instruction),
            flow_instruction_ref_block_ordinal(instruction),
            flow_instruction_ref_ordinal(instruction))
    } else {
        let block = flow_semantic_step_terminator(step)
        make_h_terminator_resource_site(
            flow_block_ref_owner(block), flow_block_ref_ordinal(block))
    }
}

fn events_for_node(
    stages: VerifiedBridgeStages, node_ordinal: Int,
    placement: Int
) -> List<BridgeRcEvent> {
    let mut result: List<BridgeRcEvent> = []
    for event in stages.events {
        if core_flow_node_ordinal(event.node) == node_ordinal &&
           event.placement == placement {
            result.push(event)
        }
    }
    result
}

const BRIDGE_ROLE_EXPR_PRIMARY: Int = 0
const BRIDGE_ROLE_STMT_ASSIGN: Int = 1
const BRIDGE_ROLE_CONTROL_DISPATCH: Int = 2
const BRIDGE_ROLE_BRANCH_MERGE: Int = 3
const BRIDGE_ROLE_CONTROL_EXIT: Int = 4
const BRIDGE_ROLE_BODY_RETURN: Int = 5

fn role_matches(
    value: CoreFlowStepRole, selector: Int, ordinal: Int
) -> Bool {
    let kind_matches = if selector == BRIDGE_ROLE_EXPR_PRIMARY {
        core_flow_step_role_is_expr_primary(value)
    } else if selector == BRIDGE_ROLE_STMT_ASSIGN {
        core_flow_step_role_is_stmt_assign(value)
    } else if selector == BRIDGE_ROLE_CONTROL_DISPATCH {
        core_flow_step_role_is_control_dispatch(value)
    } else if selector == BRIDGE_ROLE_BRANCH_MERGE {
        core_flow_step_role_is_branch_merge(value)
    } else if selector == BRIDGE_ROLE_CONTROL_EXIT {
        core_flow_step_role_is_control_exit(value)
    } else if selector == BRIDGE_ROLE_BODY_RETURN {
        core_flow_step_role_is_body_return(value)
    } else {
        panic("RcHIR bridge: unknown Core/Flow role selector")
    }
    kind_matches && core_flow_step_role_ordinal(value) == ordinal
}

fn events_for_node_role(
    stages: VerifiedBridgeStages, node_ordinal: Int,
    placement: Int, selector: Int, role_ordinal: Int
) -> List<BridgeRcEvent> {
    events_for_node(stages, node_ordinal, placement).filter(fn(event) {
        role_matches(event.role, selector, role_ordinal)
    })
}

fn wrap_resource_operand(
    ctx: HirBridgeCtx, node_ordinal: Int,
    operand_ordinal: Int, slot: SlotRef,
    selector: Int, role_ordinal: Int
) -> HExpr {
    let mut result = bridge_binder_ident(ctx, slot)
    let mut transfer_count = 0
    for event in events_for_node_role(
            ctx.stages, node_ordinal, BRIDGE_RC_BEFORE_INSTRUCTION,
            selector, role_ordinal) {
        if event.operand_ordinal == operand_ordinal {
            let operation = event.operation
            let kind = rc_operation_kind(operation)
            if (rc_op_kind_same(kind, rc_op_kind_clone()) ||
                rc_op_kind_same(kind, rc_op_kind_take())) &&
               slot_ref_same(rc_operation_source(operation), slot) {
                transfer_count = transfer_count + 1
                consume_event(ctx, event)
                let binder = bridge_binder_for(ctx, slot)
                if rc_op_kind_same(kind, rc_op_kind_clone()) {
                    result = HExpr::Clone {
                        inner: result,
                        ty: legacy_binder_projection_type(binder),
                        effects: EMPTY_ROW, span: span_zero()
                    }
                } else {
                    result = HExpr::Take {
                        source: result, source_slot: slot,
                        saved_slot: rc_operation_target(operation),
                        site: h_resource_site_for_step(event.step),
                        ty: legacy_binder_projection_type(binder),
                        effects: EMPTY_ROW, span: span_zero()
                    }
                }
            }
        }
    }
    if transfer_count > 1 {
        panic("RcHIR bridge: operand has multiple transfer operations")
    }
    result
}

fn wrap_exact_place_take(
    mut ctx: HirBridgeCtx, node_ordinal: Int,
    source_slot: SlotRef, target_slot: SlotRef, source: HExpr,
    expected_projection: FlowProjectionContract?, required: Bool,
    selector: Int, role_ordinal: Int
) -> HExpr {
    let mut found: BridgeRcEvent? = none
    for event in events_for_node_role(
            ctx.stages, node_ordinal, BRIDGE_RC_BEFORE_INSTRUCTION,
            selector, role_ordinal) {
        let operation = event.operation
        if event.operand_ordinal == 0 &&
           rc_op_kind_same(rc_operation_kind(operation), rc_op_kind_take()) {
            let target_same = match rc_operation_target(operation) {
                some(value) => slot_ref_same(value, target_slot),
                none => false
            }
            if found.is_some() ||
               !slot_ref_same(rc_operation_source(operation), source_slot) ||
               !target_same {
                panic("RcHIR bridge: exact place Take relation drifted")
            }
            match (rc_operation_place_projection(operation), expected_projection) {
                (some(actual), some(expected)) => if
                        !flow_projection_contract_same(actual, expected) {
                    panic("RcHIR bridge: exact place Take projection drifted")
                },
                (none, none) => {},
                _ => panic("RcHIR bridge: exact place Take projection shape differs")
            }
            found = some(event)
        }
    }
    match found {
        some(event) => {
            consume_event(ctx, event)
            let binder = bridge_binder_for(ctx, target_slot)
            HExpr::Take {
                source: source, source_slot: source_slot,
                saved_slot: some(target_slot),
                site: h_resource_site_for_step(event.step),
                ty: legacy_binder_projection_type(binder),
                effects: EMPTY_ROW, span: span_zero()
            }
        },
        none => if required {
            panic("RcHIR bridge: exact place Take is absent")
        } else { source }
    }
}

fn drop_statement(
    ctx: HirBridgeCtx, event: BridgeRcEvent,
    place_target: HExpr?
) -> HStmt {
    let operation = event.operation
    let slot = rc_operation_source(operation)
    let binder = bridge_binder_for(ctx, slot)
    let kind = rc_operation_kind(operation)
    let reason = if rc_op_kind_same(kind, rc_op_kind_cleanup()) {
        if place_target.is_some() {
            panic("RcHIR bridge: Cleanup cannot target a place")
        }
        h_resource_reason_cleanup()
    } else if rc_op_kind_same(kind, rc_op_kind_drop()) {
        if place_target.is_some() {
            panic("RcHIR bridge: slot Drop cannot target a place")
        }
        h_resource_reason_drop()
    } else if rc_op_kind_same(kind, rc_op_kind_drop_old_place()) {
        if place_target.is_none() ||
           rc_operation_place_projection(operation).is_none() {
            panic("RcHIR bridge: DropOldPlace lacks exact projection")
        }
        h_resource_reason_drop_projected_old()
    } else {
        panic("RcHIR bridge: non-drop operation used as Drop statement")
    }
    HStmt::Drop {
        name: legacy_binder_projection_name(binder),
        def_id: legacy_binder_projection_def_id(binder),
        slot: slot, place_target: place_target,
        site: h_resource_site_for_step(event.step),
        reason: reason, ty: legacy_binder_projection_type(binder),
        span: span_zero()
    }
}

fn before_drop_statements(
    ctx: HirBridgeCtx, node_ordinal: Int, place_target: HExpr?,
    selector: Int, role_ordinal: Int
) -> List<HStmt> {
    let mut result: List<HStmt> = []
    for event in events_for_node_role(
            ctx.stages, node_ordinal, BRIDGE_RC_BEFORE_INSTRUCTION,
            selector, role_ordinal) {
        let kind = rc_operation_kind(event.operation)
        if rc_op_kind_same(kind, rc_op_kind_drop()) ||
           rc_op_kind_same(kind, rc_op_kind_cleanup()) ||
           rc_op_kind_same(kind, rc_op_kind_drop_old_place()) {
            consume_event(ctx, event)
            result.push(drop_statement(ctx, event, place_target))
        }
    }
    result
}

fn after_resource_statements(
    ctx: HirBridgeCtx, node_ordinal: Int,
    selector: Int, role_ordinal: Int
) -> List<HStmt> {
    let mut result: List<HStmt> = []
    for event in events_for_node_role(
            ctx.stages, node_ordinal, BRIDGE_RC_AFTER_INSTRUCTION,
            selector, role_ordinal) {
        let operation = event.operation
        let kind = rc_operation_kind(operation)
        if rc_op_kind_same(kind, rc_op_kind_clone()) {
            consume_event(ctx, event)
            let slot = rc_operation_source(operation)
            let binder = bridge_binder_for(ctx, slot)
            result.push(HStmt::ExprStmt {
                expr: HExpr::Clone {
                    inner: bridge_binder_ident(ctx, slot),
                    ty: legacy_binder_projection_type(binder),
                    effects: EMPTY_ROW, span: span_zero()
                },
                span: span_zero()
            })
        } else {
            panic("RcHIR bridge: unsupported post-instruction resource op")
        }
    }
    result
}

fn wrap_terminator_operand(
    ctx: HirBridgeCtx, node_ordinal: Int,
    operand_ordinal: Int, slot: SlotRef,
    selector: Int, role_ordinal: Int
) -> HExpr {
    let mut result = bridge_binder_ident(ctx, slot)
    let mut transfer_count = 0
    for event in events_for_node_role(
            ctx.stages, node_ordinal, BRIDGE_RC_BEFORE_TERMINATOR,
            selector, role_ordinal) {
        if event.operand_ordinal == operand_ordinal {
            let operation = event.operation
            let kind = rc_operation_kind(operation)
            if (rc_op_kind_same(kind, rc_op_kind_clone()) ||
                rc_op_kind_same(kind, rc_op_kind_take())) &&
               slot_ref_same(rc_operation_source(operation), slot) {
                transfer_count = transfer_count + 1
                consume_event(ctx, event)
                let binder = bridge_binder_for(ctx, slot)
                if rc_op_kind_same(kind, rc_op_kind_clone()) {
                    result = HExpr::Clone {
                        inner: result,
                        ty: legacy_binder_projection_type(binder),
                        effects: EMPTY_ROW, span: span_zero()
                    }
                } else {
                    result = HExpr::Take {
                        source: result, source_slot: slot,
                        saved_slot: rc_operation_target(operation),
                        site: h_resource_site_for_step(event.step),
                        ty: legacy_binder_projection_type(binder),
                        effects: EMPTY_ROW, span: span_zero()
                    }
                }
            }
        }
    }
    if transfer_count > 1 {
        panic("RcHIR bridge: terminator operand has multiple transfers")
    }
    result
}

fn before_terminator_drops(
    ctx: HirBridgeCtx, node_ordinal: Int,
    selector: Int, role_ordinal: Int
) -> List<HStmt> {
    let mut result: List<HStmt> = []
    for event in events_for_node_role(
            ctx.stages, node_ordinal, BRIDGE_RC_BEFORE_TERMINATOR,
            selector, role_ordinal) {
        let kind = rc_operation_kind(event.operation)
        if rc_op_kind_same(kind, rc_op_kind_drop()) ||
           rc_op_kind_same(kind, rc_op_kind_cleanup()) {
            consume_event(ctx, event)
            result.push(drop_statement(ctx, event, none))
        }
    }
    result
}

fn edge_cleanup_statements(
    ctx: HirBridgeCtx, node_ordinal: Int,
    selector: Int, role_ordinal: Int,
    successor_ordinal: Int
) -> List<HStmt> {
    let mut result: List<HStmt> = []
    for event in events_for_node_role(
            ctx.stages, node_ordinal, BRIDGE_RC_EDGE_CLEANUP,
            selector, role_ordinal) {
        if event.successor_ordinal == some(successor_ordinal) {
            if !rc_op_kind_same(
                    rc_operation_kind(event.operation), rc_op_kind_cleanup()) {
                panic("RcHIR bridge: edge carries non-cleanup operation")
            }
            consume_event(ctx, event)
            result.push(drop_statement(ctx, event, none))
        }
    }
    result
}

struct SerializedExpr {
    node_ordinal: Int,
    prefix: List<HStmt>,
    value: HExpr,
    after: List<HStmt>
}

struct SerializedOperand {
    prefix: List<HStmt>,
    value: HExpr
}
struct SerializedReference {
    prefix: List<HStmt>, value: HExpr, slot: SlotRef
}
struct SerializedUpdateOverride {
    field: CoreFieldRef,
    reference: SerializedReference
}
fn simple_operand(value: HExpr) -> SerializedOperand {
    SerializedOperand { prefix: [], value: value }
}

fn bridge_let_for_slot(
    ctx: HirBridgeCtx, slot: SlotRef, init: HExpr
) -> HStmt {
    let binder = bridge_binder_for(ctx, slot)
    HStmt::Let {
        name: legacy_binder_projection_name(binder),
        name_span: span_zero(),
        def_id: some(legacy_binder_projection_def_id(binder)),
        ty: legacy_binder_projection_type(binder),
        init: init, span: span_zero()
    }
}

fn serialize_nested_operand(
    mut ctx: HirBridgeCtx, owner: ExecutableRef, expr: CoreExpr,
    parent_node: Int, operand_ordinal: Int,
    selector: Int, role_ordinal: Int
) -> SerializedOperand {
    let serialized = serialize_core_expr(ctx, owner, expr)
    let slot = node_anchor(ctx, serialized.node_ordinal)
    let binder = bridge_binder_for(ctx, slot)
    let mut prefix = serialized.prefix
    prefix.push(HStmt::Let {
        name: legacy_binder_projection_name(binder),
        name_span: span_zero(),
        def_id: some(legacy_binder_projection_def_id(binder)),
        ty: legacy_binder_projection_type(binder),
        init: serialized.value, span: span_zero()
    })
    append_all(prefix, serialized.after)
    SerializedOperand {
        prefix: prefix,
        value: wrap_resource_operand(
            ctx, parent_node, operand_ordinal, slot, selector, role_ordinal)
    }
}

fn serialize_terminator_operand(
    mut ctx: HirBridgeCtx, owner: ExecutableRef, expr: CoreExpr,
    parent_node: Int, operand_ordinal: Int,
    selector: Int, role_ordinal: Int
) -> SerializedOperand {
    let child = serialize_child_reference(ctx, owner, expr)
    SerializedOperand {
        prefix: child.prefix,
        value: wrap_terminator_operand(
            ctx, parent_node, operand_ordinal, child.slot,
            selector, role_ordinal)
    }
}

fn enter_materialize_node(
    mut ctx: HirBridgeCtx, owner: ExecutableRef,
    kind_tag: Int, origin: OriginRef
) -> Int {
    let ordinal = ctx.next_node_ordinal
    let mut found = 0
    for node in core_flow_step_map_nodes(ctx.stages.step_map) {
        if core_flow_node_ordinal(node) == ordinal {
            found = found + 1
            if !executable_ref_same(core_flow_node_owner(node), owner) ||
               core_flow_node_kind_tag(node) != kind_tag ||
               !origin_ref_same(core_flow_node_origin(node), origin) {
                panic("RcHIR bridge: materialization Core node drifted")
            }
        }
    }
    if found != 1 { panic("RcHIR bridge: Core node ordinal is not unique") }
    ctx.next_node_ordinal = ctx.next_node_ordinal + 1
    ordinal
}

fn node_anchor(ctx: HirBridgeCtx, ordinal: Int) -> SlotRef {
    for node in core_flow_step_map_nodes(ctx.stages.step_map) {
        if core_flow_node_ordinal(node) == ordinal {
            return match core_flow_node_anchor_slot(node) {
                some(slot) => slot,
                none => panic("RcHIR bridge: Core expression has no Flow anchor")
            }
        }
    }
    panic("RcHIR bridge: Core node anchor is absent")
}

fn fail_instruction_for_node(
    ctx: HirBridgeCtx, ordinal: Int
) -> FlowInstruction {
    let mut found: FlowInstruction? = none
    for body in flow_program_bodies(ctx.stages.flow) {
        for block in flow_body_blocks(body) {
            for instruction in flow_block_instructions(block) {
                if flow_instruction_kind_tag(instruction) == 11 {
                    let step = make_flow_instruction_step_ref(
                        flow_instruction_reference(instruction))
                    for relation in core_flow_step_map_relations(
                            ctx.stages.step_map) {
                        if flow_semantic_step_same(
                                core_flow_step(relation), step) &&
                           core_flow_node_ordinal(
                                core_flow_step_node(relation)) == ordinal {
                            if found.is_some() {
                                panic("RcHIR bridge: FailRaise step repeats")
                            }
                            found = some(instruction)
                        }
                    }
                }
            }
        }
    }
    match found {
        some(value) => value,
        none => panic("RcHIR bridge: CoreFailRaise has no Flow instruction")
    }
}

fn instruction_for_node_role(
    ctx: HirBridgeCtx, ordinal: Int,
    selector: Int, role_ordinal: Int, expected_kind: Int
) -> FlowInstruction {
    let mut target_step: FlowSemanticStepRef? = none
    for relation in core_flow_step_map_relations(ctx.stages.step_map) {
        if core_flow_node_ordinal(core_flow_step_node(relation)) == ordinal &&
           role_matches(core_flow_step_role(relation), selector, role_ordinal) {
            if target_step.is_some() {
                panic("RcHIR bridge: Core node role has multiple Flow steps")
            }
            target_step = some(core_flow_step(relation))
        }
    }
    let step = match target_step {
        some(value) => value,
        none => panic("RcHIR bridge: Core node role lacks Flow step")
    }
    if !flow_semantic_step_is_instruction(step) {
        panic("RcHIR bridge: Core expression role is not an instruction")
    }
    let reference = flow_semantic_step_instruction(step)
    let mut found: FlowInstruction? = none
    for body in flow_program_bodies(ctx.stages.flow) {
        for block in flow_body_blocks(body) {
            for instruction in flow_block_instructions(block) {
                if flow_instruction_ref_same(
                        flow_instruction_reference(instruction), reference) {
                    if found.is_some() {
                        panic("RcHIR bridge: Flow instruction repeats")
                    }
                    found = some(instruction)
                }
            }
        }
    }
    let instruction = match found {
        some(value) => value,
        none => panic("RcHIR bridge: Core node Flow instruction is absent")
    }
    if flow_instruction_kind_tag(instruction) != expected_kind {
        panic("RcHIR bridge: Core node Flow instruction kind differs")
    }
    instruction
}

fn validate_flow_variant_initialize(
    instruction: FlowInstruction, variant: VariantRef
) {
    let operation = flow_initialize_operation(instruction)
    if flow_operation_contract_kind_tag(operation) != 6 ||
       !variant_ref_same(
            flow_operation_contract_variant(operation), variant) {
        panic("RcHIR bridge: Flow/Core variant construct identity differs")
    }
}

fn primitive_bin_op(tag: Int) -> BinOp {
    if tag == 0 { return BinOp::Add }
    if tag == 1 { return BinOp::Sub }
    if tag == 2 { return BinOp::Mul }
    if tag == 3 { return BinOp::Div }
    if tag == 4 { return BinOp::Mod }
    if tag == 7 { return BinOp::Lt }
    if tag == 8 { return BinOp::Lte }
    if tag == 9 { return BinOp::Gt }
    if tag == 10 { return BinOp::Gte }
    panic("RcHIR bridge: primitive is not binary")
}

fn callee_expr(
    ctx: HirBridgeCtx, callee: CoreCalleeRef, ty: Type
) -> HExpr {
    let kind = core_callee_kind_tag(callee)
    if kind == 0 {
        executable_ident(ctx.projection, core_callee_direct(callee), ty)
    } else if kind == 1 {
        projected_binder_ident(ctx.projection, core_callee_local(callee))
    } else if kind == 2 {
        let path = path_ref_normalized_child_path(core_callee_dynamic(callee))
        if path.len() == 0 {
            panic("RcHIR bridge: dynamic callee path is empty")
        }
        let identity = path.join("$")
        HExpr::Ident {
            name: identity, resolved_name: some(identity), def_id: none,
            source_slot: none, callee_identity: none,
            dict_closure_dicts: none, callable_instantiation: none,
            ty: ty, effects: EMPTY_ROW,
            span: span_zero()
        }
    } else {
        panic("RcHIR bridge: unknown Core callee kind")
    }
}

fn method_name(projection: LegacyProjectionTable, value: ExactMethodRef) -> Str {
    if exact_method_ref_is_intrinsic(value) {
        symbol_ref_canonical_payload(intrinsic_ref_symbol(
            exact_method_ref_intrinsic(value)))
    } else if exact_method_ref_is_impl(value) {
        executable_identity(projection, make_named_executable_ref(
            impl_method_ref_member(exact_method_ref_impl(value))))
    } else if exact_method_ref_is_trait(value) {
        trait_method_ref_name(exact_method_ref_trait(value))
    } else {
        panic("RcHIR bridge: unknown exact method identity")
    }
}

fn legacy_method_ref(
    ctx: HirBridgeCtx, method: ExactMethodRef, callee: CoreCalleeRef,
    evidence: List<DictRef>
) -> MethodCallRef {
    let contract = core_callee_contract(callee)
    let parameter_types = flow_call_contract_parameter_types(contract).map(
        fn(value) {
            legacy_type_for(ctx.projection, value)
        })
    let result_type = legacy_type_for(
        ctx.projection, flow_call_contract_result_type(contract))
    let effects = legacy_effects_for(
        ctx.projection, core_effect_contract_exact(
            core_effect_instantiation_result(
                core_callee_effect_instantiation(callee))))
    let signature = Type::FnType {
        params: parameter_types, return_type: result_type, effects: effects
    }
    let roles = flow_call_contract_parameter_roles(contract)
    let receiver_mutable = roles.len() > 0 &&
        flow_semantic_role_tag(roles.get(0).unwrap()) ==
            flow_semantic_role_tag(flow_semantic_role_mutate())
    if exact_method_ref_is_intrinsic(method) {
        make_intrinsic_method_call_ref(
            exact_method_ref_intrinsic(method), signature)
    } else if exact_method_ref_is_impl(method) {
        make_concrete_method_call_ref(
            exact_method_ref_impl(method), signature, receiver_mutable)
    } else if exact_method_ref_is_trait(method) {
        let bound = match evidence.get(0) {
            some(value) => value,
            none => panic("RcHIR bridge: bound method lacks exact evidence")
        }
        make_bound_method_call_ref(
            exact_method_ref_trait(method), bound, signature,
            receiver_mutable)
    } else {
        panic("RcHIR bridge: unknown exact method identity")
    }
}

fn field_name(value: CoreFieldRef) -> Str {
    let kind = core_field_ref_kind_tag(value)
    if kind == 0 {
        nominal_field_ref_name(core_field_ref_nominal(value))
    } else if kind == 1 {
        core_field_ref_tuple_index(value).to_str()
    } else if kind == 2 {
        core_field_ref_record_name(value)
    } else if kind == 3 {
        symbol_ref_canonical_payload(variant_field_ref_member(
            core_field_ref_variant(value)))
    } else {
        panic("RcHIR bridge: unknown Core field kind")
    }
}

fn hir_projection(value: CoreFieldRef) -> HProjectionRef {
    let kind = core_field_ref_kind_tag(value)
    if kind == 0 {
        h_nominal_projection(core_field_ref_nominal(value))
    } else if kind == 1 {
        h_tuple_projection(core_field_ref_tuple_index(value))
    } else if kind == 2 {
        h_structural_projection(
            core_field_ref_record_path(value), field_name(value))
    } else if kind == 3 {
        h_variant_projection(core_field_ref_variant(value))
    } else {
        panic("RcHIR bridge: unknown Core projection kind")
    }
}

fn projected_field_access(
    ctx: HirBridgeCtx, base: HExpr, field: CoreFieldRef,
    ty: Type, effects: EffectRow
) -> HExpr {
    let kind = core_field_ref_kind_tag(field)
    let access_kind = if kind == 0 {
        let reference = core_field_ref_nominal(field)
        HFieldAccessKind::NominalField {
            owner_ref: nominal_owner_in_decls(
                ctx.shell.decls, nominal_field_ref_owner(reference)),
            field_ref: reference,
            field_index: nominal_field_ref_index(reference)
        }
    } else if kind == 1 {
        HFieldAccessKind::TupleField
    } else {
        HFieldAccessKind::RecordField
    }
    HExpr::FieldAccess {
        receiver: base, field: field_name(field), access_kind: access_kind,
        projection: some(hir_projection(field)),
        ty: ty, effects: effects, span: span_zero()
    }
}

fn simple_core_expr(
    ctx: HirBridgeCtx, owner: ExecutableRef,
    expr: CoreExpr, node_ordinal: Int
) -> SerializedOperand {
    let kind = core_expr_kind_tag(expr)
    let ty = legacy_type_for(ctx.projection, core_expr_type(expr))
    let effects = legacy_effects_for(ctx.projection, core_expr_effects(expr))
    if kind == 0 {
        let literal = core_expr_literal(expr)
        let literal_kind = core_literal_kind_tag(literal)
        if literal_kind == 0 {
            return simple_operand(HExpr::IntLit {
                value: core_literal_int(literal),
                ty: ty, effects: effects, span: span_zero() })
        }
        if literal_kind == 1 {
            return simple_operand(HExpr::FloatLit {
                value: core_literal_float(literal),
                ty: ty, effects: effects, span: span_zero() })
        }
        if literal_kind == 2 {
            return simple_operand(HExpr::StrLit {
                value: core_literal_str(literal),
                ty: ty, effects: effects, span: span_zero() })
        }
        if literal_kind == 3 {
            return simple_operand(HExpr::BoolLit {
                value: core_literal_bool(literal),
                ty: ty, effects: effects, span: span_zero() })
        }
        return simple_operand(HExpr::TupleLit {
            elements: [], constructor: some(make_h_tuple_constructor_plan(0)),
            ty: ty, effects: effects, span: span_zero()
        })
    }
    if kind == 1 {
        return simple_operand(wrap_resource_operand(
            ctx, node_ordinal, 0, core_expr_read_source(expr),
            BRIDGE_ROLE_EXPR_PRIMARY, 0))
    }
    if kind == 2 {
        let operation = core_primitive_op_tag(
            core_expr_primitive_operation(expr))
        let operands = core_expr_primitive_operands(expr)
        if operation == 5 || operation == 6 {
            if operands.len() != 1 {
                panic("RcHIR bridge: unary primitive arity differs")
            }
            let operand = serialize_nested_operand(
                ctx, owner, operands.get(0).unwrap(), node_ordinal, 0,
                BRIDGE_ROLE_EXPR_PRIMARY, 0)
            return SerializedOperand {
                prefix: operand.prefix,
                value: HExpr::UnaryOp {
                op: if operation == 5 { UnaryOp::Neg } else { UnaryOp::Not },
                operand: operand.value,
                ty: ty, effects: effects, span: span_zero()
            } }
        }
        if operands.len() != 2 {
            panic("RcHIR bridge: binary primitive arity differs")
        }
        let left = serialize_nested_operand(
            ctx, owner, operands.get(0).unwrap(), node_ordinal, 0,
            BRIDGE_ROLE_EXPR_PRIMARY, 0)
        let right = serialize_nested_operand(
            ctx, owner, operands.get(1).unwrap(), node_ordinal, 1,
            BRIDGE_ROLE_EXPR_PRIMARY, 0)
        let mut prefix = left.prefix
        append_all(prefix, right.prefix)
        return SerializedOperand { prefix: prefix, value: HExpr::BinOp {
            op: primitive_bin_op(operation),
            left: left.value, right: right.value,
            eq_dispatch: none, ord_dispatch: none,
            eq_plan: none, ord_plan: none,
            ty: ty, effects: effects, span: span_zero()
        } }
    }
    if kind == 3 || kind == 4 {
        let callee = core_expr_call_callee(expr)
        let evidence = core_expr_call_evidence(expr).map(fn(value) {
            evidence_dict(ctx.projection, value)
        })
        let mut operand_index = 0
        let mut prefix: List<HStmt> = []
        let call_callee = if kind == 4 {
            let method = core_expr_method_ref(expr)
            let receiver = core_expr_method_receiver(expr)
            let serialized_receiver = serialize_nested_operand(
                ctx, owner, receiver, node_ordinal, 0,
                BRIDGE_ROLE_EXPR_PRIMARY, 0)
            append_all(prefix, serialized_receiver.prefix)
            operand_index = 1
            let mut method_params = [legacy_type_for(
                ctx.projection, core_expr_type(receiver))]
            for argument in core_expr_call_arguments(expr) {
                method_params.push(legacy_type_for(
                    ctx.projection, core_expr_type(argument)))
            }
            HExpr::FieldAccess {
                receiver: serialized_receiver.value,
                field: method_name(ctx.projection, method),
                access_kind: HFieldAccessKind::Method,
                projection: none,
                ty: Type::FnType {
                    params: method_params, return_type: ty, effects: effects
                },
                effects: EMPTY_ROW, span: span_zero()
            }
        } else {
            let callee_type = if core_callee_kind_tag(callee) == 0 {
                callable_fn_type(legacy_projection_callable_for(
                    ctx.projection, core_callee_direct(callee)))
            } else {
                Type::FnType {
                    params: core_expr_call_arguments(expr).map(fn(argument) {
                        legacy_type_for(
                            ctx.projection, core_expr_type(argument))
                    }),
                    return_type: ty, effects: effects
                }
            }
            callee_expr(ctx, callee, callee_type)
        }
        let args = core_expr_call_arguments(expr).map(fn(argument) {
            let serialized = serialize_nested_operand(
                ctx, owner, argument, node_ordinal, operand_index,
                BRIDGE_ROLE_EXPR_PRIMARY, 0)
            append_all(prefix, serialized.prefix)
            operand_index = operand_index + 1
            serialized.value
        })
        let source_method = if kind == 4 {
            some(legacy_method_ref(
                ctx, core_expr_method_ref(expr), callee, evidence))
        } else {
            let absent: MethodCallRef? = none
            absent
        }
        return SerializedOperand { prefix: prefix, value: HExpr::Call {
            callee: call_callee, args: args, type_args: [],
            effect_instantiation: none,
            resolved_dicts: evidence,
            effect_ctx: typed_effect_ctx_source(
                core_expr_call_effect_ctx_argument(expr)),
            callee_ref: if kind == 3 {
                some(core_callee_ref(callee))
            } else { none },
            method_ref: source_method,
            system_host: none,
            ty: ty, effects: effects, span: span_zero()
        } }
    }
    if kind == 5 {
        let operation = core_expr_effect_operation(expr)
        let arguments = core_expr_call_arguments(expr)
        let mut index = 0
        let mut prefix: List<HStmt> = []
        let args = arguments.map(fn(argument) {
            let serialized = serialize_nested_operand(
                ctx, owner, argument, node_ordinal, index,
                BRIDGE_ROLE_EXPR_PRIMARY, 0)
            append_all(prefix, serialized.prefix)
            index = index + 1
            serialized.value
        })
        return SerializedOperand { prefix: prefix, value: HExpr::EffectOp {
            effect_name: symbol_ref_canonical_payload(
                handled_effect_ref_symbol(effect_operation_ref_effect(operation))),
            op_name: symbol_ref_canonical_payload(
                effect_operation_ref_member(operation)),
            operation_ref: some(operation),
            fail_ref: none,
            effect_ctx_lookup: some(typed_effect_ctx_lookup(
                ctx.projection, core_expr_effect_ctx_lookup(expr))),
            args: args,
            ty: ty, effects: effects, span: span_zero()
        } }
    }
    if kind == 6 {
        let executable = system_host_callable_executable(
            core_expr_system_host(expr))
        let callable = legacy_projection_callable_for(ctx.projection, executable)
        let mut index = 0
        let mut prefix: List<HStmt> = []
        let args = core_expr_call_arguments(expr).map(fn(argument) {
            let serialized = serialize_nested_operand(
                ctx, owner, argument, node_ordinal, index,
                BRIDGE_ROLE_EXPR_PRIMARY, 0)
            append_all(prefix, serialized.prefix)
            index = index + 1
            serialized.value
        })
        return SerializedOperand { prefix: prefix, value: HExpr::Call {
            callee: executable_ident(
                ctx.projection, executable, callable_fn_type(callable)),
            args: args,
            type_args: [], effect_instantiation: none,
            resolved_dicts: [],
            effect_ctx: make_empty_effect_ctx_source(),
            callee_ref: some(make_named_callee_ref(
                executable_ref_named_symbol(executable))), method_ref: none,
            system_host: some(core_expr_system_host(expr)),
            ty: ty, effects: effects, span: span_zero()
        } }
    }
    if kind == 9 {
        let base = serialize_nested_operand(
            ctx, owner, core_expr_project_base(expr), node_ordinal, 0,
            BRIDGE_ROLE_EXPR_PRIMARY, 0)
        return SerializedOperand {
            prefix: base.prefix,
            value: projected_field_access(
                ctx, base.value, core_expr_project_field(expr), ty, effects)
        }
    }
    if kind == 10 {
        let constructor = core_expr_constructor(expr)
        let fields = core_expr_constructor_fields(expr)
        let constructor_kind = core_constructor_kind_tag(constructor)
        let mut index = 0
        let mut prefix: List<HStmt> = []
        if constructor_kind == 0 {
            let owner_ref = core_constructor_struct_owner(constructor)
            let values = fields.map(fn(field) {
                let serialized = serialize_nested_operand(
                    ctx, owner, core_field_value_expr(field), node_ordinal,
                    index, BRIDGE_ROLE_EXPR_PRIMARY, 0)
                append_all(prefix, serialized.prefix)
                let reference = core_field_ref_nominal(
                    core_field_value_field(field))
                index = index + 1
                HNominalStructFieldInit {
                    name: nominal_field_ref_name(reference),
                    field_ref: reference,
                    field_index: nominal_field_ref_index(reference),
                    value: serialized.value
                }
            })
            return SerializedOperand { prefix: prefix, value: HExpr::StructLit {
                name: registered_nominal_ref_display_name(owner_ref),
                owner_ref: owner_ref, type_args: [],
                fields: values,
                spread: none,
                constructor: some(make_h_record_constructor_plan(
                    fields.map(fn(field) {
                        hir_projection(core_field_value_field(field))
                    }))),
                ty: ty, effects: effects, span: span_zero()
            } }
        }
        if constructor_kind == 1 {
            let variant = core_constructor_variant(constructor)
            validate_flow_variant_initialize(instruction_for_node_role(
                ctx, node_ordinal, BRIDGE_ROLE_EXPR_PRIMARY, 0, 0), variant)
            let variant_shell = match enum_variant_in_decls_opt(
                    ctx.shell.decls, variant) {
                some(found) => found,
                none => panic("RcHIR bridge: exact variant shell is absent")
            }
            if variant_shell.fields.len() != fields.len() {
                panic("RcHIR bridge: variant constructor field census differs")
            }
            let values = fields.map(fn(field) {
                let serialized = serialize_nested_operand(
                    ctx, owner, core_field_value_expr(field), node_ordinal,
                    index, BRIDGE_ROLE_EXPR_PRIMARY, 0)
                append_all(prefix, serialized.prefix)
                let reference = core_field_ref_variant(
                    core_field_value_field(field))
                let result = HStructFieldInit {
                    name: match variant_shell.field_names {
                        some(names) => names.get(index).unwrap_or_else(fn() {
                            panic("RcHIR bridge: variant field name is absent")
                        }),
                        none => index.to_str()
                    },
                    field_ref: reference, value: serialized.value
                }
                index = index + 1
                result
            })
            return SerializedOperand { prefix: prefix,
                value: HExpr::NamedVariantConstruct {
                enum_name: registered_nominal_ref_display_name(
                    variant_ref_owner(variant)),
                variant_name: variant_shell.name,
                variant_ref: variant,
                fields: values,
                spread: none,
                constructor: some(make_h_variant_constructor_plan(
                    fields.map(fn(field) {
                        hir_projection(core_field_value_field(field))
                    }))),
                ty: ty, effects: effects, span: span_zero()
            } }
        }
        if constructor_kind == 2 {
            let values = fields.map(fn(field) {
                    let serialized = serialize_nested_operand(
                        ctx, owner, core_field_value_expr(field), node_ordinal,
                        index, BRIDGE_ROLE_EXPR_PRIMARY, 0)
                    append_all(prefix, serialized.prefix)
                    index = index + 1
                    serialized.value
                })
            return SerializedOperand { prefix: prefix, value: HExpr::TupleLit {
                elements: values,
                constructor: some(make_h_tuple_constructor_plan(fields.len())),
                ty: ty, effects: effects, span: span_zero()
            } }
        }
        panic("RcHIR bridge: 0.1 has no structural record literal")
    }
    if kind == 11 {
        let executable = core_expr_lambda_executable(expr)
        let callable = legacy_projection_callable_for(ctx.projection, executable)
        let mut capture_ordinal = 0
        let captures = core_expr_lambda_captures(expr).map(fn(capture) {
            let source = core_capture_source(capture)
            let mut site: HResourceSite? = none
            for event in events_for_node_role(
                    ctx.stages, node_ordinal,
                    BRIDGE_RC_BEFORE_INSTRUCTION,
                    BRIDGE_ROLE_EXPR_PRIMARY, 0) {
                if event.operand_ordinal == capture_ordinal &&
                   slot_ref_same(rc_operation_source(event.operation), source) &&
                   (rc_op_kind_same(
                        rc_operation_kind(event.operation), rc_op_kind_clone()) ||
                    rc_op_kind_same(
                        rc_operation_kind(event.operation), rc_op_kind_take())) {
                    site = some(h_resource_site_for_step(event.step))
                }
            }
            let result = HLambdaCapture {
                source: source, target: core_capture_target(capture),
                value: some(wrap_resource_operand(
                    ctx, node_ordinal, capture_ordinal, source,
                    BRIDGE_ROLE_EXPR_PRIMARY, 0)),
                resource_site: site
            }
            capture_ordinal = capture_ordinal + 1
            result
        })
        return simple_operand(HExpr::Lambda {
            executable_ref: executable,
            params: legacy_params(callable), captures: captures,
            effect_ctx: typed_callable_effect_ctx(
                ctx.projection,
                core_callable_effect_ctx_for(
                    ctx.stages.core, executable)),
            return_type: legacy_callable_result_type(callable),
            body: serialize_callable_body(ctx, executable),
            ty: ty, effects: effects, span: span_zero()
        })
    }
    if kind == 17 {
        let executable = core_expr_callable_executable(expr)
        return simple_operand(executable_ident(
            ctx.projection, executable,
            legacy_type_for(ctx.projection, core_expr_type(expr))))
    }
    panic("RcHIR bridge: structured Core expression used simple serializer")
}

fn serialize_core_expr(
    mut ctx: HirBridgeCtx, owner: ExecutableRef, expr: CoreExpr
) -> SerializedExpr {
    let kind = core_expr_kind_tag(expr)
    let node_ordinal = enter_materialize_node(
        ctx, owner, kind, core_expr_origin(expr))
    if kind == 18 {
        let payload = serialize_nested_operand(
            ctx, owner, core_expr_fail_payload(expr), node_ordinal, 0,
            BRIDGE_ROLE_EXPR_PRIMARY, 0)
        let sink = flow_fail_raise_sink(
            fail_instruction_for_node(ctx, node_ordinal))
        let sink_binder = bridge_binder_for(ctx, sink)
        let mut prefix = payload.prefix
        prefix.push(HStmt::Let {
            name: legacy_binder_projection_name(sink_binder),
            name_span: span_zero(),
            def_id: some(legacy_binder_projection_def_id(sink_binder)),
            ty: legacy_binder_projection_type(sink_binder),
            init: payload.value, span: span_zero()
        })
        append_all(prefix, before_drop_statements(
            ctx, node_ordinal, none, BRIDGE_ROLE_EXPR_PRIMARY, 0))
        append_all(prefix, before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0))
        return SerializedExpr {
            node_ordinal: node_ordinal, prefix: prefix,
            value: HExpr::EffectOp {
                effect_name: "fail", op_name: "raise",
                operation_ref: none, fail_ref: some(h_fail_raise_ref()),
                effect_ctx_lookup: none,
                args: [bridge_binder_ident(ctx, sink)],
                ty: legacy_type_for(ctx.projection, core_expr_type(expr)),
                effects: legacy_effects_for(
                    ctx.projection, core_expr_effects(expr)),
                span: span_zero()
            },
            after: []
        }
    }
    if kind <= 11 || kind == 17 {
        let simple = simple_core_expr(ctx, owner, expr, node_ordinal)
        let mut prefix = simple.prefix
        append_all(prefix, before_drop_statements(
            ctx, node_ordinal, none, BRIDGE_ROLE_EXPR_PRIMARY, 0))
        SerializedExpr {
            node_ordinal: node_ordinal,
            prefix: prefix, value: simple.value,
            after: after_resource_statements(
                ctx, node_ordinal, BRIDGE_ROLE_EXPR_PRIMARY, 0)
        }
    } else {
        serialize_structured_core_expr(ctx, owner, expr, node_ordinal)
    }
}

fn materialize_expr_slot(
    mut ctx: HirBridgeCtx, owner: ExecutableRef, expr: CoreExpr
) -> List<HStmt> {
    let serialized = serialize_core_expr(ctx, owner, expr)
    let slot = node_anchor(ctx, serialized.node_ordinal)
    let binder = bridge_binder_for(ctx, slot)
    let mut result = serialized.prefix
    let initialize = if legacy_binder_projection_is_mutable(binder) {
        HStmt::Var {
            name: legacy_binder_projection_name(binder),
            name_span: span_zero(),
            def_id: some(legacy_binder_projection_def_id(binder)),
            ty: legacy_binder_projection_type(binder),
            init: serialized.value, span: span_zero()
        }
    } else {
        HStmt::Let {
            name: legacy_binder_projection_name(binder),
            name_span: span_zero(),
            def_id: some(legacy_binder_projection_def_id(binder)),
            ty: legacy_binder_projection_type(binder),
            init: serialized.value, span: span_zero()
        }
    }
    result.push(initialize)
    for statement in serialized.after { result.push(statement) }
    result
}

fn serialize_child_reference(
    mut ctx: HirBridgeCtx, owner: ExecutableRef, expr: CoreExpr
) -> SerializedReference {
    let serialized = serialize_core_expr(ctx, owner, expr)
    let slot = node_anchor(ctx, serialized.node_ordinal)
    let binder = bridge_binder_for(ctx, slot)
    let mut prefix = serialized.prefix
    prefix.push(HStmt::Let {
        name: legacy_binder_projection_name(binder),
        name_span: span_zero(),
        def_id: some(legacy_binder_projection_def_id(binder)),
        ty: legacy_binder_projection_type(binder),
        init: serialized.value, span: span_zero()
    })
    append_all(prefix, serialized.after)
    SerializedReference {
        prefix: prefix, value: bridge_binder_ident(ctx, slot), slot: slot
    }
}

fn serialize_move_update_source(
    mut ctx: HirBridgeCtx, owner: ExecutableRef, expr: CoreExpr
) -> SerializedReference {
    let kind = core_expr_kind_tag(expr)
    if kind == 1 {
        let _ = enter_materialize_node(
            ctx, owner, kind, core_expr_origin(expr))
        let slot = core_expr_read_source(expr)
        return SerializedReference {
            prefix: [], value: bridge_binder_ident(ctx, slot), slot: slot
        }
    }
    if kind == 9 && core_expr_kind_tag(core_expr_project_base(expr)) == 1 {
        let _ = enter_materialize_node(
            ctx, owner, kind, core_expr_origin(expr))
        let receiver = serialize_move_update_source(
            ctx, owner, core_expr_project_base(expr))
        return SerializedReference {
            prefix: receiver.prefix,
            value: projected_field_access(
                ctx, receiver.value, core_expr_project_field(expr),
                legacy_type_for(ctx.projection, core_expr_type(expr)),
                legacy_effects_for(ctx.projection, core_expr_effects(expr))),
            slot: receiver.slot
        }
    }
    serialize_child_reference(ctx, owner, expr)
}

fn assignment_target(
    mut ctx: HirBridgeCtx, owner: ExecutableRef, value: CorePlaceRef
) -> SerializedOperand {
    if core_place_is_slot(value) {
        return simple_operand(projected_binder_ident(
            ctx.projection, core_place_slot(value)))
    }
    let base = serialize_child_reference(ctx, owner, core_place_base(value))
    let mut prefix = base.prefix
    let ty = legacy_type_for(ctx.projection, core_place_value_type(value))
    let projected = projected_field_access(
        ctx, base.value, core_place_field(value), ty, EMPTY_ROW)
    SerializedOperand { prefix: prefix, value: projected }
}

fn append_all(mut target: List<HStmt>, values: List<HStmt>) {
    for value in values { target.push(value) }
}

fn serialized_expr_block(
    mut ctx: HirBridgeCtx, owner: ExecutableRef,
    expr: CoreExpr, parent_node: Int,
    selector: Int, role_ordinal: Int,
    suffix: List<HStmt>
) -> HExpr {
    let serialized = serialize_core_expr(ctx, owner, expr)
    let slot = node_anchor(ctx, serialized.node_ordinal)
    let mut statements = serialized.prefix
    let binder = bridge_binder_for(ctx, slot)
    statements.push(HStmt::Let {
        name: legacy_binder_projection_name(binder),
        name_span: span_zero(),
        def_id: some(legacy_binder_projection_def_id(binder)),
        ty: legacy_binder_projection_type(binder),
        init: serialized.value, span: span_zero()
    })
    append_all(statements, serialized.after)
    append_all(statements, suffix)
    HExpr::Block {
        stmts: statements, tail: some(wrap_terminator_operand(
            ctx, parent_node, 0, slot, selector, role_ordinal)),
        ty: legacy_binder_projection_type(binder),
        effects: legacy_effects_for(ctx.projection, core_expr_effects(expr)),
        span: span_zero()
    }
}

fn serialize_destructure_statement(
    mut ctx: HirBridgeCtx, owner: ExecutableRef,
    statement: CoreStmt, node_ordinal: Int
) -> List<HStmt> {
    let source = serialize_child_reference(
        ctx, owner, core_stmt_destructure_scrutinee(statement))
    let pattern = core_stmt_destructure_pattern(statement)
    if core_pattern_kind_tag(pattern) != 3 {
        panic("RcHIR bridge: destructure pattern is not tuple")
    }
    let mut result = source.prefix
    let mut dispatch_ordinal = 0
    let mut field_index = 0
    for element in core_pattern_elements(pattern) {
        let kind = core_pattern_kind_tag(element)
        if kind == 1 {
            let target = core_pattern_binding(element)
            let project = instruction_for_node_role(
                ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH,
                dispatch_ordinal, 7)
            if !slot_ref_same(flow_project_base(project), source.slot) ||
               !slot_ref_same(flow_project_result(project), target) {
                panic("RcHIR bridge: destructure projection relation differs")
            }
            let contract = flow_project_contract(project)
            let binder = bridge_binder_for(ctx, target)
            let projected = projected_field_access(
                ctx, source.value, make_core_tuple_field(field_index),
                legacy_binder_projection_type(binder), EMPTY_ROW)
            append_all(result, before_drop_statements(
                ctx, node_ordinal, none,
                BRIDGE_ROLE_CONTROL_DISPATCH, dispatch_ordinal))
            result.push(bridge_let_for_slot(
                ctx, target, wrap_exact_place_take(
                    ctx, node_ordinal, source.slot, target, projected,
                    some(contract), false,
                    BRIDGE_ROLE_CONTROL_DISPATCH, dispatch_ordinal)))
            append_all(result, after_resource_statements(
                ctx, node_ordinal,
                BRIDGE_ROLE_CONTROL_DISPATCH, dispatch_ordinal))
            dispatch_ordinal = dispatch_ordinal + 1
        } else if kind != 0 {
            panic("RcHIR bridge: destructure element is not binding/wildcard")
        }
        field_index = field_index + 1
    }
    result
}

fn serialize_core_statement(
    mut ctx: HirBridgeCtx, owner: ExecutableRef, statement: CoreStmt
) -> List<HStmt> {
    let kind = core_stmt_kind_tag(statement)
    let node_ordinal = enter_materialize_node(
        ctx, owner, kind, core_stmt_origin(statement))
    if kind == 0 {
        let target_slot = core_place_slot(core_stmt_target(statement))
        let target = projected_binder_for(ctx.projection, target_slot)
        let serialized = serialize_core_expr(
            ctx, owner, core_stmt_value(statement))
        let rhs_slot = node_anchor(ctx, serialized.node_ordinal)
        let rhs_binder = bridge_binder_for(ctx, rhs_slot)
        let mut result = serialized.prefix
        result.push(HStmt::Let {
            name: legacy_binder_projection_name(rhs_binder),
            name_span: span_zero(),
            def_id: some(legacy_binder_projection_def_id(rhs_binder)),
            ty: legacy_binder_projection_type(rhs_binder),
            init: serialized.value, span: span_zero()
        })
        append_all(result, serialized.after)
        append_all(result, before_drop_statements(
            ctx, node_ordinal, none, BRIDGE_ROLE_STMT_ASSIGN, 0))
        let init = wrap_resource_operand(
            ctx, node_ordinal, 0, rhs_slot,
            BRIDGE_ROLE_STMT_ASSIGN, 0)
        result.push(if core_stmt_bind_is_mutable(statement) {
            HStmt::Var {
                name: legacy_binder_projection_name(target),
                name_span: span_zero(),
                def_id: some(legacy_binder_projection_def_id(target)),
                ty: legacy_binder_projection_type(target),
                init: init, span: span_zero()
            }
        } else {
            HStmt::Let {
                name: legacy_binder_projection_name(target),
                name_span: span_zero(),
                def_id: some(legacy_binder_projection_def_id(target)),
                ty: legacy_binder_projection_type(target),
                init: init, span: span_zero()
            }
        })
        append_all(result, after_resource_statements(
            ctx, node_ordinal, BRIDGE_ROLE_STMT_ASSIGN, 0))
        return result
    }
    if kind == 2 {
        return materialize_expr_slot(ctx, owner, core_stmt_value(statement))
    }
    if kind == 1 {
        let target = assignment_target(
            ctx, owner, core_stmt_target(statement))
        let serialized = serialize_core_expr(
            ctx, owner, core_stmt_value(statement))
        let rhs_slot = node_anchor(ctx, serialized.node_ordinal)
        let rhs_binder = bridge_binder_for(ctx, rhs_slot)
        let mut result = target.prefix
        append_all(result, serialized.prefix)
        result.push(HStmt::Let {
            name: legacy_binder_projection_name(rhs_binder),
            name_span: span_zero(),
            def_id: some(legacy_binder_projection_def_id(rhs_binder)),
            ty: legacy_binder_projection_type(rhs_binder),
            init: serialized.value, span: span_zero()
        })
        append_all(result, serialized.after)
        let drop_place = if core_place_is_slot(core_stmt_target(statement)) {
            none
        } else {
            some(target.value)
        }
        append_all(result, before_drop_statements(
            ctx, node_ordinal, drop_place,
            BRIDGE_ROLE_STMT_ASSIGN, 0))
        result.push(HStmt::Assign {
            target: target.value,
            value: wrap_resource_operand(
                ctx, node_ordinal, 0, rhs_slot,
                BRIDGE_ROLE_STMT_ASSIGN, 0),
            span: span_zero()
        })
        append_all(result, after_resource_statements(
            ctx, node_ordinal, BRIDGE_ROLE_STMT_ASSIGN, 0))
        return result
    }
    if kind == 3 {
        let condition = core_stmt_while_condition(statement)
        let condition_expr = serialized_expr_block(
            ctx, owner, condition, node_ordinal,
            BRIDGE_ROLE_CONTROL_DISPATCH, 1,
            before_terminator_drops(
                ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 1))
        let mut body_prefix = edge_cleanup_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 1, 0)
        let body = serialize_core_block(
            ctx, owner, core_stmt_while_body(statement),
            Type::UnitType, EMPTY_ROW,
            none, 0, body_prefix,
            edge_cleanup_statements(
                ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0, 0))
        let mut result = before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0)
        append_all(result, edge_cleanup_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0, 0))
        result.push(HStmt::While {
            condition: condition_expr, body: body, span: span_zero()
        })
        append_all(result, edge_cleanup_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 1, 1))
        return result
    }
    if kind == 4 || kind == 5 {
        let mut result = before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0)
        append_all(result, edge_cleanup_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0, 0))
        result.push(if kind == 4 {
            HStmt::Break { span: span_zero() }
        } else {
            HStmt::Continue { span: span_zero() }
        })
        return result
    }
    if kind == 6 {
        let returned = core_stmt_return_value(statement)
        let mut result: List<HStmt> = []
        let mut returned_slot: SlotRef? = none
        match returned {
            some(expr) => {
                let serialized = serialize_core_expr(ctx, owner, expr)
                let slot = node_anchor(ctx, serialized.node_ordinal)
                let binder = bridge_binder_for(ctx, slot)
                append_all(result, serialized.prefix)
                result.push(HStmt::Let {
                    name: legacy_binder_projection_name(binder),
                    name_span: span_zero(),
                    def_id: some(legacy_binder_projection_def_id(binder)),
                    ty: legacy_binder_projection_type(binder),
                    init: serialized.value, span: span_zero()
                })
                append_all(result, serialized.after)
                returned_slot = some(slot)
            },
            none => {}
        }
        append_all(result, before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0))
        append_all(result, edge_cleanup_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0, 0))
        result.push(HStmt::Return {
            value: match returned_slot {
                some(slot) => some(wrap_terminator_operand(
                    ctx, node_ordinal, 0, slot,
                    BRIDGE_ROLE_CONTROL_EXIT, 0)),
                none => none
            },
            span: span_zero()
        })
        return result
    }
    if kind == 7 {
        return serialize_destructure_statement(
            ctx, owner, statement, node_ordinal)
    }
    panic("RcHIR bridge: unknown Core statement kind")
}

fn serialize_core_block(
    mut ctx: HirBridgeCtx, owner: ExecutableRef, block: CoreBlock,
    result_type: Type, effects: EffectRow,
    merge_node: Int?, merge_ordinal: Int,
    prefix: List<HStmt>, suffix: List<HStmt>
) -> HExpr {
    let mut statements = prefix
    for statement in core_block_statements(block) {
        append_all(statements, serialize_core_statement(ctx, owner, statement))
    }
    let mut tail: HExpr? = none
    match core_block_tail(block) {
        some(expr) => {
            let serialized = serialize_core_expr(ctx, owner, expr)
            let slot = node_anchor(ctx, serialized.node_ordinal)
            let binder = bridge_binder_for(ctx, slot)
            append_all(statements, serialized.prefix)
            statements.push(HStmt::Let {
                name: legacy_binder_projection_name(binder),
                name_span: span_zero(),
                def_id: some(legacy_binder_projection_def_id(binder)),
                ty: legacy_binder_projection_type(binder),
                init: serialized.value, span: span_zero()
            })
            append_all(statements, serialized.after)
            tail = some(match merge_node {
                some(node) => wrap_resource_operand(
                    ctx, node, 0, slot,
                    BRIDGE_ROLE_BRANCH_MERGE, merge_ordinal),
                none => bridge_binder_ident(ctx, slot)
            })
        },
        none => {}
    }
    append_all(statements, suffix)
    HExpr::Block {
        stmts: statements, tail: tail,
        ty: result_type, effects: effects, span: span_zero()
    }
}

fn consume_body(mut ctx: HirBridgeCtx, reference: ExecutableRef) {
    for existing in ctx.consumed_bodies {
        if executable_ref_same(existing, reference) {
            panic("RcHIR bridge: executable body serialized twice")
        }
    }
    ctx.consumed_bodies.push(reference)
}

fn body_node_ordinal(
    step_map: CoreFlowStepMap, body: CoreBody
) -> Int {
    let mut found: Int? = none
    for node in core_flow_step_map_nodes(step_map) {
        if executable_ref_same(
                core_flow_node_owner(node), core_body_reference(body)) &&
           core_flow_node_kind_tag(node) == 0 &&
           core_flow_node_anchor_slot(node).is_none() &&
           origin_ref_same(
                core_flow_node_origin(node), core_body_origin(body)) {
            if found.is_some() {
                panic("RcHIR bridge: Core body node repeats")
            }
            found = some(core_flow_node_ordinal(node))
        }
    }
    match found {
        some(value) => value,
        none => panic("RcHIR bridge: Core body node is absent")
    }
}

fn serialize_callable_body(
    mut ctx: HirBridgeCtx, reference: ExecutableRef
) -> HExpr {
    let entry = core_body_for(
        core_program_bodies(ctx.stages.core), reference)
    consume_body(ctx, reference)
    let body = core_body_entry_body(entry)
    let callable = legacy_projection_callable_for(ctx.projection, reference)
    let saved_node_ordinal = ctx.next_node_ordinal
    ctx.next_node_ordinal = body_node_ordinal(ctx.stages.step_map, body)
    let node_ordinal = enter_materialize_node(
        ctx, reference, 0, core_body_origin(body))
    let block = core_body_block(body)
    let mut statements: List<HStmt> = []
    for statement in core_block_statements(block) {
        append_all(statements, serialize_core_statement(ctx, reference, statement))
    }
    let mut tail: HExpr? = none
    match core_block_tail(block) {
        some(expr) => {
            let serialized = serialize_core_expr(ctx, reference, expr)
            let slot = node_anchor(ctx, serialized.node_ordinal)
            let binder = bridge_binder_for(ctx, slot)
            append_all(statements, serialized.prefix)
            statements.push(HStmt::Let {
                name: legacy_binder_projection_name(binder),
                name_span: span_zero(),
                def_id: some(legacy_binder_projection_def_id(binder)),
                ty: legacy_binder_projection_type(binder),
                init: serialized.value, span: span_zero()
            })
            append_all(statements, serialized.after)
            append_all(statements, before_terminator_drops(
                ctx, node_ordinal, BRIDGE_ROLE_BODY_RETURN, 0))
            append_all(statements, edge_cleanup_statements(
                ctx, node_ordinal, BRIDGE_ROLE_BODY_RETURN, 0, 0))
            tail = some(wrap_terminator_operand(
                ctx, node_ordinal, 0, slot,
                BRIDGE_ROLE_BODY_RETURN, 0))
        },
        none => {
            append_all(statements, before_terminator_drops(
                ctx, node_ordinal, BRIDGE_ROLE_BODY_RETURN, 0))
            append_all(statements, edge_cleanup_statements(
                ctx, node_ordinal, BRIDGE_ROLE_BODY_RETURN, 0, 0))
        }
    }
    let result = HExpr::Block {
        stmts: statements, tail: tail,
        ty: legacy_callable_result_type(callable),
        effects: validate_legacy_effect_row(
            legacy_callable_effects(callable)), span: span_zero()
    }
    ctx.next_node_ordinal = saved_node_ordinal
    result
}

fn serialize_handler(
    mut ctx: HirBridgeCtx, handler: CoreHandlerOperation,
    token: CoreEffectCtxTokenRef,
    node_ordinal: Int, dispatch_ordinal: Int
) -> HEffectHandler {
    let operation = core_handler_operation_ref(handler)
    let callable = legacy_projection_callable_for(
        ctx.projection, core_handler_operation_executable(handler))
    let all_parameters = legacy_params(callable)
    let parameter_slots = core_handler_operation_parameter_slots(handler)
    let resume_count = if core_handler_operation_resume_slot(handler).is_some() {
        1
    } else { 0 }
    if all_parameters.len() != parameter_slots.len() + resume_count {
        panic("RcHIR bridge: handler parameter projection differs")
    }
    let mut parameters: List<HParam> = []
    let mut parameter_index = 0
    while parameter_index < parameter_slots.len() {
        parameters.push(all_parameters.get(parameter_index).unwrap())
        parameter_index = parameter_index + 1
    }
    let mut capture_ordinal = 0
    let captures = core_handler_operation_captures(handler).map(fn(capture) {
        let source = core_capture_source(capture)
        let mut site: HResourceSite? = none
        for event in events_for_node_role(
                ctx.stages, node_ordinal,
                BRIDGE_RC_BEFORE_INSTRUCTION,
                BRIDGE_ROLE_CONTROL_DISPATCH, dispatch_ordinal) {
            if event.operand_ordinal == capture_ordinal &&
               slot_ref_same(rc_operation_source(event.operation), source) &&
               (rc_op_kind_same(
                    rc_operation_kind(event.operation), rc_op_kind_clone()) ||
                rc_op_kind_same(
                    rc_operation_kind(event.operation), rc_op_kind_take())) {
                site = some(h_resource_site_for_step(event.step))
            }
        }
        let result = HLambdaCapture {
            source: source, target: core_capture_target(capture),
            value: some(wrap_resource_operand(
                ctx, node_ordinal, capture_ordinal, source,
                BRIDGE_ROLE_CONTROL_DISPATCH, dispatch_ordinal)),
            resource_site: site
        }
        capture_ordinal = capture_ordinal + 1
        result
    })
    HEffectHandler {
        handled_instance: some(typed_effect_ctx_instance(
            ctx.projection, token)),
        operation_ref: some(operation),
        fail_ref: none,
        executable_ref: core_handler_operation_executable(handler),
        captures: captures,
        effect_ctx: typed_callable_effect_ctx(
            ctx.projection, core_callable_effect_ctx_for(
                ctx.stages.core,
                core_handler_operation_executable(handler))),
        parent_ctx: core_handler_operation_parent_ctx(handler),
        effect_name: symbol_ref_canonical_payload(
            handled_effect_ref_symbol(effect_operation_ref_effect(operation))),
        op_name: symbol_ref_canonical_payload(
            effect_operation_ref_member(operation)),
        params: parameters,
        resume_binding: match core_handler_operation_resume_slot(handler) {
            some(slot) => {
                let binder = projected_binder_for(ctx.projection, slot)
                some(HPatternBinding {
                    name: legacy_binder_projection_name(binder),
                    def_id: legacy_binder_projection_def_id(binder),
                    slot: slot,
                    ty: legacy_binder_projection_type(binder)
                })
            },
            none => none
        },
        body: serialize_callable_body(
            ctx, core_handler_operation_executable(handler))
    }
}

fn serialize_trait_method(
    mut ctx: HirBridgeCtx, value: HTraitMethod
) -> HTraitMethod {
    let body = if value.has_default {
        some(serialize_callable_body(ctx, value.executable_ref))
    } else { none }
    HTraitMethod {
        name: value.name, method_ref: value.method_ref,
        params: value.params, return_type: value.return_type,
        effects: validate_legacy_effect_row(value.effects),
        has_default: value.has_default,
        executable_ref: value.executable_ref,
        effect_ctx: typed_callable_effect_ctx(
            ctx.projection, core_callable_effect_ctx_for(
                ctx.stages.core, value.executable_ref)),
        body: body
    }
}

fn serialize_effect_op(
    mut ctx: HirBridgeCtx, value: HEffectOp
) -> HEffectOp {
    let _ = ctx
    HEffectOp {
        name: value.name, operation_ref: value.operation_ref,
        params: value.params, return_type: value.return_type
    }
}

fn core_impl_for(
    values: List<CoreImplMetadata>, owner: ImplOwnerRef
) -> CoreImplMetadata {
    let mut found: CoreImplMetadata? = none
    for value in values {
        if impl_owner_ref_same(core_impl_owner(value), owner) {
            if found.is_some() {
                panic("RcHIR bridge: Core impl owner repeats")
            }
            found = some(value)
        }
    }
    match found {
        some(value) => value,
        none => panic("RcHIR bridge: shell impl has no CoreImplMetadata")
    }
}

fn core_has_body(core: CoreProgram, reference: ExecutableRef) -> Bool {
    for entry in core_program_bodies(core) {
        if executable_ref_same(core_body_entry_reference(entry), reference) {
            return true
        }
    }
    false
}

fn exact_core_callable(
    core: CoreProgram, reference: ExecutableRef
) -> CoreCallableContract {
    let mut found: CoreCallableContract? = none
    for callable in core_program_callables(core) {
        if executable_ref_same(core_callable_reference(callable), reference) {
            if found.is_some() {
                panic("RcHIR bridge: duplicate Core callable")
            }
            found = some(callable)
        }
    }
    match found {
        some(value) => value,
        none => panic("RcHIR bridge: exact Core callable is absent")
    }
}

fn core_callable_effect_ctx_for(
    core: CoreProgram, reference: ExecutableRef
) -> CoreCallableEffectCtx {
    match core_callable_effect_ctx(exact_core_callable(core, reference)) {
        some(value) => value,
        none => panic("RcHIR bridge: Ring callable lacks EffectCtx")
    }
}

fn generated_method_decl(
    mut ctx: HirBridgeCtx, method: ImplMethodRef
) -> HDecl {
    let executable = make_named_executable_ref(impl_method_ref_member(method))
    let callable = legacy_projection_callable_for(ctx.projection, executable)
    HDecl::Fn {
        name: executable_identity(ctx.projection, executable), def_id: none,
        executable_ref: executable, impl_method_ref: some(method),
        type_params: legacy_type_params(
            legacy_callable_type_parameters(callable)),
        params: legacy_params(callable),
        return_type: legacy_callable_result_type(callable),
        effects: validate_legacy_effect_row(
            legacy_callable_effects(callable)),
        effect_ctx: typed_callable_effect_ctx(
            ctx.projection, core_callable_effect_ctx_for(
                ctx.stages.core, executable)),
        body: serialize_callable_body(ctx, executable),
        is_pub: legacy_callable_is_public(callable),
        trait_bounds: legacy_trait_bounds(callable), span: span_zero()
    }
}

fn generated_standalone_decl(
    mut ctx: HirBridgeCtx, reference: ExecutableRef
) -> HDecl {
    let callable = legacy_projection_callable_for(ctx.projection, reference)
    HDecl::Fn {
        name: executable_identity(ctx.projection, reference), def_id: none,
        executable_ref: reference, impl_method_ref: none,
        type_params: legacy_type_params(
            legacy_callable_type_parameters(callable)),
        params: legacy_params(callable),
        return_type: legacy_callable_result_type(callable),
        effects: validate_legacy_effect_row(
            legacy_callable_effects(callable)),
        effect_ctx: typed_callable_effect_ctx(
            ctx.projection, core_callable_effect_ctx_for(
                ctx.stages.core, reference)),
        body: serialize_callable_body(ctx, reference),
        is_pub: legacy_callable_is_public(callable),
        trait_bounds: legacy_trait_bounds(callable), span: span_zero()
    }
}

fn legacy_impl_assoc_types(
    value: LegacyImplProjection
) -> List<HAssocType> {
    legacy_impl_assoc_bindings(value).map(fn(binding) {
        HAssocType {
            name: symbol_ref_canonical_payload(
                legacy_assoc_binding_member(binding)),
            member_ref: legacy_assoc_binding_member(binding),
            bounds: [], concrete: some(legacy_assoc_binding_type(binding))
        }
    })
}

fn generated_impl_decl(
    mut ctx: HirBridgeCtx, metadata: CoreImplMetadata
) -> HDecl {
    let owner = core_impl_owner(metadata)
    let projection = legacy_projection_impl_for(ctx.projection, owner)
    let exact_target = impl_owner_ref_target(owner)
    if !symbol_ref_same(
            legacy_impl_target_nominal(projection), exact_target) {
        panic("RcHIR bridge: generated impl target identity differs")
    }
    let mut methods: List<HDecl> = []
    for method in core_impl_methods(metadata) {
        let executable = make_named_executable_ref(impl_method_ref_member(method))
        if core_has_body(ctx.stages.core, executable) {
            methods.push(generated_method_decl(ctx, method))
        }
    }
    HDecl::Impl {
        target_type: symbol_ref_canonical_payload(exact_target),
        target_ty: legacy_impl_target_type(projection),
        owner_ref: owner, provider_ref: impl_owner_ref_provider(owner),
        trait_ref: legacy_impl_trait(projection),
        delegate_plan: none,
        default_specializations: [],
        type_params: legacy_type_params(
            legacy_impl_type_parameters(projection)),
        trait_name: match legacy_impl_trait(projection) {
            some(reference) => some(symbol_ref_canonical_payload(reference)),
            none => none
        },
        methods: methods,
        assoc_types: legacy_impl_assoc_types(projection),
        span: span_zero()
    }
}

fn decls_have_impl_owner(values: List<HDecl>, owner: ImplOwnerRef) -> Bool {
    for value in values {
        match value {
            HDecl::Impl { owner_ref, .. } => if
                impl_owner_ref_same(owner_ref, owner) { return true },
            HDecl::ModBlock { decls, .. } => if
                decls_have_impl_owner(decls, owner) { return true },
            _ => {}
        }
    }
    false
}

fn serialize_shell_decl(mut ctx: HirBridgeCtx, value: HDecl) -> HDecl {
    match value {
        HDecl::Fn {
            name, def_id, executable_ref, impl_method_ref,
            type_params, params, return_type, effects,
            is_pub, trait_bounds, span, ..
        } => HDecl::Fn {
            name: match impl_method_ref {
                some(method) => executable_identity(
                    ctx.projection, make_named_executable_ref(
                        impl_method_ref_member(method))),
                none => name
            }, def_id: def_id,
            executable_ref: executable_ref,
            impl_method_ref: impl_method_ref,
            type_params: type_params, params: params,
            return_type: return_type,
            effects: validate_legacy_effect_row(effects),
            effect_ctx: typed_callable_effect_ctx(
                ctx.projection, core_callable_effect_ctx_for(
                    ctx.stages.core, executable_ref)),
            body: serialize_callable_body(ctx, executable_ref),
            is_pub: is_pub, trait_bounds: trait_bounds, span: span
        },
        HDecl::Test { description, executable_ref, span, .. } => HDecl::Test {
            description: description, executable_ref: executable_ref,
            effect_ctx: typed_callable_effect_ctx(
                ctx.projection, core_callable_effect_ctx_for(
                    ctx.stages.core, executable_ref)),
            body: serialize_callable_body(ctx, executable_ref), span: span
        },
        HDecl::Const {
            name, def_id, executable_ref, ty, is_pub, span, ..
        } => HDecl::Const {
            name: name, def_id: def_id, executable_ref: executable_ref,
            effect_ctx: typed_callable_effect_ctx(
                ctx.projection, core_callable_effect_ctx_for(
                    ctx.stages.core, executable_ref)),
            ty: ty, init: serialize_callable_body(ctx, executable_ref),
            is_pub: is_pub, span: span
        },
        HDecl::Impl {
            target_type, target_ty, owner_ref, provider_ref, trait_ref,
            delegate_plan: ignored_delegate_plan,
            default_specializations: ignored_default_specializations,
            type_params, trait_name, methods, assoc_types, span
        } => {
            let _ = ignored_delegate_plan
            let _ = ignored_default_specializations
            let metadata = core_impl_for(
                core_program_impls(ctx.stages.core), owner_ref)
            let mut serialized: List<HDecl> = []
            for method in core_impl_methods(metadata) {
                let mut source: HDecl? = none
                for candidate in methods {
                    match candidate {
                        HDecl::Fn {
                            impl_method_ref: some(reference), ..
                        } => if impl_method_ref_same(reference, method) {
                            if source.is_some() {
                                panic("RcHIR bridge: impl method shell repeats")
                            }
                            source = some(candidate)
                        },
                        _ => {}
                    }
                }
                match source {
                    some(candidate) => serialized.push(
                        serialize_shell_decl(ctx, candidate)),
                    none => {
                        if !core_has_body(
                                ctx.stages.core,
                                make_named_executable_ref(
                                    impl_method_ref_member(method))) {
                            panic("RcHIR bridge: impl method body is absent")
                        }
                        serialized.push(generated_method_decl(ctx, method))
                    }
                }
            }
            HDecl::Impl {
                target_type: target_type, target_ty: target_ty,
                owner_ref: owner_ref,
                provider_ref: provider_ref, trait_ref: trait_ref,
                delegate_plan: none,
                default_specializations: [],
                type_params: type_params, trait_name: trait_name,
                methods: serialized, assoc_types: assoc_types, span: span
            }
        },
        HDecl::Trait {
            name, owner_ref, type_params, methods,
            supertraits, assoc_types, is_pub, span
        } => HDecl::Trait {
            name: name, owner_ref: owner_ref, type_params: type_params,
            methods: methods.map(fn(method) {
                serialize_trait_method(ctx, method)
            }),
            supertraits: supertraits, assoc_types: assoc_types,
            is_pub: is_pub, span: span
        },
        HDecl::Effect {
            name, owner_ref, handled_ref, type_params,
            ops, is_pub, span
        } => HDecl::Effect {
            name: name, owner_ref: owner_ref, handled_ref: handled_ref,
            type_params: type_params,
            ops: ops.map(fn(op) { serialize_effect_op(ctx, op) }),
            is_pub: is_pub, span: span
        },
        HDecl::ModBlock { name, decls, is_pub, span } => HDecl::ModBlock {
            name: name, decls: decls.map(fn(decl) {
                serialize_shell_decl(ctx, decl)
            }), is_pub: is_pub, span: span
        },
        HDecl::ExternFn {
            name, abi_name, def_id, executable_ref,
            type_params, params, return_type, effects,
            resource_contract, trait_bounds, is_pub, span, ..
        } => HDecl::ExternFn {
            name: name, abi_name: abi_name, def_id: def_id,
            executable_ref: executable_ref, type_params: type_params,
            params: params, return_type: return_type,
            effects: validate_legacy_effect_row(effects),
            resource_contract: resource_contract,
            trait_bounds: trait_bounds,
            is_pub: is_pub, span: span
        },
        HDecl::Struct { .. } | HDecl::Enum { .. } |
        HDecl::ExternType { .. } |
        HDecl::TypeAlias { .. } => value
    }
}

fn body_was_consumed(values: List<ExecutableRef>, reference: ExecutableRef) -> Bool {
    for value in values {
        if executable_ref_same(value, reference) { return true }
    }
    false
}

fn validate_projection_against_core(
    core: CoreProgram, projection: LegacyProjectionTable
) {
    if legacy_projection_core_type_count(projection) !=
       core_type_graph_count(core_program_type_graph(core)) {
        panic("RcHIR bridge: projection/Core type census differs")
    }
    for callable in core_program_callables(core) {
        let projected = legacy_projection_callable_for(
            projection, core_callable_reference(callable))
        if !executable_ref_same(
                legacy_callable_reference(projected),
                core_callable_reference(callable)) {
            panic("RcHIR bridge: projection callable identity differs")
        }
    }
    for metadata in core_program_impls(core) {
        let projected = legacy_projection_impl_for(
            projection, core_impl_owner(metadata))
        if !impl_owner_ref_same(
                legacy_impl_owner(projected), core_impl_owner(metadata)) {
            panic("RcHIR bridge: projection impl identity differs")
        }
    }
    for entry in core_program_bodies(core) {
        let body = core_body_entry_body(entry)
        for binder_value in core_body_binders(body) {
            let binder = legacy_projection_binder_for(
                projection, core_binder_reference(binder_value))
            if !types_equal(
                    legacy_binder_projection_type(binder),
                    legacy_type_for(
                        projection, core_binder_type(binder_value))) {
                panic("RcHIR bridge: projection binder type differs")
            }
        }
    }
}

pub struct VerifiedProjectHirShell {
    module_key: Str,
    shell: HProgram
}
pub fn make_verified_project_hir_shell(
    module_key: Str, shell: HProgram
) -> VerifiedProjectHirShell {
    if module_key == "" || module_key == "$builtin" {
        panic("RcHIR bridge: invalid project shell module key")
    }
    VerifiedProjectHirShell { module_key: module_key, shell: shell }
}
pub fn verified_project_hir_shell_module_key(
    value: VerifiedProjectHirShell
) -> Str { value.module_key }
pub fn verified_project_hir_shell_program(
    value: VerifiedProjectHirShell
) -> HProgram { value.shell }

pub struct MaterializedProjectHir {
    module_key: Str,
    program: HProgram
}
pub fn materialized_project_hir_module_key(
    value: MaterializedProjectHir
) -> Str { value.module_key }
pub fn materialized_project_hir_program(
    value: MaterializedProjectHir
) -> HProgram { value.program }

pub struct MaterializedProjectHirResult {
    modules: List<MaterializedProjectHir>,
    effect_ctx_tokens: List<LegacyEffectCtxToken>
}
pub fn materialized_project_hir_modules(
    value: MaterializedProjectHirResult
) -> List<MaterializedProjectHir> {
    value.modules.map(fn(item) { item })
}
pub fn materialized_project_hir_effect_ctx_tokens(
    value: MaterializedProjectHirResult
) -> List<LegacyEffectCtxToken> {
    value.effect_ctx_tokens.map(fn(item) { item })
}

struct ProjectHirDraft {
    module_key: Str,
    shell: HProgram,
    decls: List<HDecl>
}

fn project_draft_index(values: List<ProjectHirDraft>, module_key: Str) -> Int {
    let mut found: Int? = none
    let mut index = 0
    for value in values {
        if value.module_key == module_key {
            if found.is_some() {
                panic("RcHIR bridge: project shell module repeats")
            }
            found = some(index)
        }
        index = index + 1
    }
    match found {
        some(value) => value,
        none => panic("RcHIR bridge: generated executable module has no shell")
    }
}

pub fn materialize_verified_project_hir(
    shells_in_topological_order: List<VerifiedProjectHirShell>,
    prelude_physical_owner_module_key: Str,
    verified: VerifiedOwnershipProgram,
    projection: LegacyProjectionTable
) -> MaterializedProjectHirResult {
    if shells_in_topological_order.len() == 0 {
        panic("RcHIR bridge: project has no module shells")
    }
    let stages = validate_and_index_stages(verified)
    validate_projection_against_core(stages.core, projection)
    let mut combined_decls: List<HDecl> = []
    let mut shell_index = 0
    while shell_index < shells_in_topological_order.len() {
        let shell = shells_in_topological_order.get(shell_index).unwrap()
        if (shell_index == 0) !=
               (shell.module_key == prelude_physical_owner_module_key) {
            panic("RcHIR bridge: prelude physical owner/order differs")
        }
        let mut prior = 0
        while prior < shell_index {
            if shells_in_topological_order.get(prior).unwrap().module_key ==
                    shell.module_key {
                panic("RcHIR bridge: project shell order repeats a module")
            }
            prior = prior + 1
        }
        for decl in shell.shell.decls { combined_decls.push(decl) }
        shell_index = shell_index + 1
    }
    let lookup_shell = HProgram {
        decls: combined_decls, derived_impls: [], boxed_vars: set_new(),
        static_dicts: [], extern_type_names: set_new(), drop_types: set_new()
    }
    let mut ctx = HirBridgeCtx {
        shell: lookup_shell, stages: stages, projection: projection,
        next_node_ordinal: 0, consumed_bodies: [], consumed_events: []
    }
    let mut drafts: List<ProjectHirDraft> = []
    for shell in shells_in_topological_order {
        drafts.push(ProjectHirDraft {
            module_key: shell.module_key, shell: shell.shell,
            decls: shell.shell.decls.map(fn(decl) {
                serialize_shell_decl(ctx, decl)
            })
        })
    }
    for metadata in core_program_impls(stages.core) {
        let owner = core_impl_owner(metadata)
        let projected = legacy_projection_impl_for(projection, owner)
        let module_key = module_body_ref_origin_module_key(
            legacy_impl_module(projected))
        let draft_index = project_draft_index(drafts, module_key)
        let mut draft = drafts.get(draft_index).unwrap()
        if !decls_have_impl_owner(draft.decls, owner) {
            if !legacy_container_is_module(legacy_impl_container(projected)) {
                panic("RcHIR bridge: generated nested impl has no shell container")
            }
            let mut has_body = false
            for method in core_impl_methods(metadata) {
                if core_has_body(stages.core, make_named_executable_ref(
                        impl_method_ref_member(method))) {
                    has_body = true
                }
            }
            if has_body || legacy_impl_assoc_bindings(projected).len() != 0 {
                draft.decls.push(generated_impl_decl(ctx, metadata))
                drafts.set(draft_index, draft)
            }
        }
    }
    for entry in core_program_bodies(stages.core) {
        let reference = core_body_entry_reference(entry)
        if !body_was_consumed(ctx.consumed_bodies, reference) {
            let callable = legacy_projection_callable_for(projection, reference)
            let kind = legacy_callable_kind(callable)
            if executable_kind_same(kind, executable_kind_dict_helper()) {
                let module_key = module_body_ref_origin_module_key(
                    legacy_callable_module(callable))
                let draft_index = project_draft_index(drafts, module_key)
                let mut draft = drafts.get(draft_index).unwrap()
                draft.decls.push(generated_standalone_decl(ctx, reference))
                drafts.set(draft_index, draft)
                continue
            }
            if executable_kind_same(kind, executable_kind_lambda()) ||
               executable_kind_same(kind, executable_kind_handler()) ||
               executable_kind_same(kind, executable_kind_impl_method()) ||
               executable_kind_same(kind, executable_kind_default_specialization()) ||
               executable_kind_same(kind, executable_kind_derived_impl()) ||
               executable_kind_same(kind, executable_kind_trait_default()) {
                panic("RcHIR bridge: nested/generated body was not materialized")
            }
            panic("RcHIR bridge: source executable shell is absent")
        }
    }
    if ctx.consumed_bodies.len() != core_program_bodies(stages.core).len() ||
       ctx.consumed_events.len() != stages.events.len() {
        panic("RcHIR bridge: executable/Core node materialization is not total")
    }
    let mut result: List<MaterializedProjectHir> = []
    for draft in drafts {
        let program = HProgram {
            decls: draft.decls, derived_impls: [],
            boxed_vars: draft.shell.boxed_vars,
            static_dicts: draft.shell.static_dicts,
            extern_type_names: draft.shell.extern_type_names,
            drop_types: draft.shell.drop_types
        }
        validate_hir_binder_def_ids(program)
        result.push(MaterializedProjectHir {
            module_key: draft.module_key, program: program
        })
    }
    MaterializedProjectHirResult {
        modules: result,
        effect_ctx_tokens: legacy_projection_effect_ctx_tokens(projection)
    }
}

pub struct MaterializedVerifiedHir {
    program: HProgram,
    effect_ctx_tokens: List<LegacyEffectCtxToken>
}
pub fn materialized_verified_hir_program(
    value: MaterializedVerifiedHir
) -> HProgram { value.program }
pub fn materialized_verified_hir_effect_ctx_tokens(
    value: MaterializedVerifiedHir
) -> List<LegacyEffectCtxToken> {
    value.effect_ctx_tokens.map(fn(item) { item })
}

pub fn materialize_verified_hir(
    module_key: Str, shell: HProgram, verified: VerifiedOwnershipProgram,
    projection: LegacyProjectionTable
) -> MaterializedVerifiedHir {
    let result = materialize_verified_project_hir(
        [make_verified_project_hir_shell(module_key, shell)], module_key,
        verified, projection)
    match result.modules.get(0) {
        some(value) => MaterializedVerifiedHir {
            program: value.program,
            effect_ctx_tokens: result.effect_ctx_tokens.map(fn(item) { item })
        },
        none => panic("RcHIR bridge: single project materialization is empty")
    }
}

fn enum_variant_in_decls_opt(
    decls: List<HDecl>, variant: VariantRef
) -> HEnumVariant? {
    let mut found: HEnumVariant? = none
    for decl in decls {
        match decl {
            HDecl::Enum { variants, .. } => {
                for candidate in variants {
                    if variant_ref_same(candidate.variant_ref, variant) {
                        if found.is_some() {
                            panic("RcHIR bridge: exact enum variant shell repeats")
                        }
                        found = some(candidate)
                    }
                }
            },
            HDecl::ModBlock { decls: nested, .. } => match
                    enum_variant_in_decls_opt(nested, variant) {
                some(candidate) => {
                    if found.is_some() {
                        panic("RcHIR bridge: exact enum variant shell repeats")
                    }
                    found = some(candidate)
                },
                none => {}
            },
            _ => {}
        }
    }
    found
}

fn core_pattern_bindings(
    projection: LegacyProjectionTable, value: CorePattern,
    mut result: List<HPatternBinding>
) {
    let kind = core_pattern_kind_tag(value)
    if kind == 1 {
        let slot = core_pattern_binding(value)
        let binder = projected_binder_for(projection, slot)
        result.push(HPatternBinding {
            name: legacy_binder_projection_name(binder),
            def_id: legacy_binder_projection_def_id(binder),
            slot: slot,
            ty: legacy_binder_projection_type(binder)
        })
    } else if kind == 3 {
        for element in core_pattern_elements(value) {
            core_pattern_bindings(projection, element, result)
        }
    } else if kind == 4 || kind == 5 {
        for field in core_pattern_fields(value) {
            core_pattern_bindings(
                projection, core_pattern_field_pattern(field), result)
        }
    }
}

fn serialize_pattern(
    ctx: HirBridgeCtx, value: CorePattern
) -> Pattern {
    let kind = core_pattern_kind_tag(value)
    if kind == 0 { return Pattern::Wildcard { span: span_zero() } }
    if kind == 1 {
        return Pattern::Binding {
            name: legacy_binder_projection_name(
                projected_binder_for(
                    ctx.projection, core_pattern_binding(value))),
            span: span_zero()
        }
    }
    if kind == 2 {
        let literal = core_pattern_literal(value)
        let literal_kind = core_literal_kind_tag(literal)
        if literal_kind == 4 {
            return Pattern::Constructor {
                name: "Unit", qualifier: none, fields: [], span: span_zero()
            }
        }
        return Pattern::Literal {
            value: if literal_kind == 0 {
                LiteralValue::IntVal(core_literal_int(literal))
            } else if literal_kind == 1 {
                LiteralValue::FloatVal(core_literal_float(literal))
            } else if literal_kind == 2 {
                LiteralValue::StrVal(core_literal_str(literal))
            } else {
                LiteralValue::BoolVal(core_literal_bool(literal))
            },
            span: span_zero()
        }
    }
    if kind == 3 {
        return Pattern::TuplePattern {
            elements: core_pattern_elements(value).map(fn(element) {
                serialize_pattern(ctx, element)
            }),
            span: span_zero()
        }
    }
    if kind == 4 {
        let owner = core_pattern_struct_owner(value)
        return Pattern::NamedConstructor {
            name: registered_nominal_ref_display_name(owner),
            qualifier: none,
            fields: core_pattern_fields(value).map(fn(field) {
                NamedPatternField {
                    name: field_name(core_pattern_field_ref(field)),
                    pattern: serialize_pattern(
                        ctx, core_pattern_field_pattern(field)),
                    span: span_zero()
                }
            }),
            rest: false, span: span_zero()
        }
    }
    if kind == 5 {
        let variant = core_pattern_variant(value)
        let shell = match enum_variant_in_decls_opt(ctx.shell.decls, variant) {
            some(found) => found,
            none => panic("RcHIR bridge: exact variant shell is absent")
        }
        let fields = core_pattern_fields(value)
        let name = shell.name
        match shell.field_names {
            some(names) => {
                if names.len() != fields.len() {
                    panic("RcHIR bridge: named variant pattern arity differs")
                }
                let mut index = 0
                return Pattern::NamedConstructor {
                    name: name, qualifier: none,
                    fields: fields.map(fn(field) {
                        let result = NamedPatternField {
                            name: names.get(index).unwrap(),
                            pattern: serialize_pattern(
                                ctx, core_pattern_field_pattern(field)),
                            span: span_zero()
                        }
                        index = index + 1
                        result
                    }),
                    rest: false, span: span_zero()
                }
            },
            none => return Pattern::Constructor {
                name: name, qualifier: none,
                fields: fields.map(fn(field) {
                    serialize_pattern(ctx, core_pattern_field_pattern(field))
                }),
                span: span_zero()
            }
        }
    }
    panic("RcHIR bridge: unknown Core pattern kind")
}

fn serialize_pattern_plan(
    projection: LegacyProjectionTable, value: CorePattern
) -> HPatternPlan {
    let kind = core_pattern_kind_tag(value)
    if kind == 0 { return h_pattern_wildcard() }
    if kind == 1 {
        let slot = core_pattern_binding(value)
        let binder = projected_binder_for(projection, slot)
        return h_pattern_binding(HPatternBinding {
            name: legacy_binder_projection_name(binder),
            def_id: legacy_binder_projection_def_id(binder),
            slot: slot, ty: legacy_binder_projection_type(binder)
        })
    }
    if kind == 2 { return h_pattern_literal() }
    if kind == 3 {
        return h_pattern_tuple(core_pattern_elements(value).map(fn(child) {
            serialize_pattern_plan(projection, child)
        }))
    }
    let fields = core_pattern_fields(value).map(fn(field) {
        make_h_pattern_field_plan(
            hir_projection(core_pattern_field_ref(field)),
            serialize_pattern_plan(
                projection, core_pattern_field_pattern(field)))
    })
    if kind == 4 {
        h_pattern_struct(core_pattern_struct_owner(value), fields)
    } else if kind == 5 {
        h_pattern_variant(core_pattern_variant(value), fields)
    } else {
        panic("RcHIR bridge: Core OrPattern crossed 0.1 closure")
    }
}

fn require_no_edge_cleanup(
    ctx: HirBridgeCtx, node: Int,
    selector: Int, role_ordinal: Int, successor: Int,
    detail: Str
) {
    if edge_cleanup_statements(
            ctx, node, selector, role_ordinal, successor).len() != 0 {
        panic("RcHIR bridge: unrepresentable cleanup on ${detail}")
    }
}

fn serialize_guard_expr(
    mut ctx: HirBridgeCtx, owner: ExecutableRef,
    guard: CoreExpr, parent_node: Int, dispatch_ordinal: Int
) -> HExpr {
    let serialized = serialize_core_expr(ctx, owner, guard)
    let slot = node_anchor(ctx, serialized.node_ordinal)
    let binder = bridge_binder_for(ctx, slot)
    let mut statements = serialized.prefix
    statements.push(HStmt::Let {
        name: legacy_binder_projection_name(binder),
        name_span: span_zero(),
        def_id: some(legacy_binder_projection_def_id(binder)),
        ty: legacy_binder_projection_type(binder),
        init: serialized.value, span: span_zero()
    })
    append_all(statements, serialized.after)
    append_all(statements, before_terminator_drops(
        ctx, parent_node, BRIDGE_ROLE_CONTROL_DISPATCH,
        dispatch_ordinal))
    require_no_edge_cleanup(
        ctx, parent_node, BRIDGE_ROLE_CONTROL_DISPATCH,
        dispatch_ordinal, 1, "guard-false edge")
    HExpr::Block {
        stmts: statements,
        tail: some(wrap_terminator_operand(
            ctx, parent_node, 0, slot,
            BRIDGE_ROLE_CONTROL_DISPATCH, dispatch_ordinal)),
        ty: legacy_binder_projection_type(binder),
        effects: legacy_effects_for(ctx.projection, core_expr_effects(guard)),
        span: span_zero()
    }
}

fn serialize_match_arm(
    mut ctx: HirBridgeCtx, owner: ExecutableRef,
    arm: CoreMatchArm, parent_node: Int,
    arm_ordinal: Int, dispatch_ordinal: Int,
    result_type: Type, effects: EffectRow,
    entry_prefix: List<HStmt>
) -> HMatchArm {
    let pattern = core_match_arm_pattern(arm)
    let guard = match core_match_arm_guard(arm) {
        some(value) => some(serialize_guard_expr(
            ctx, owner, value, parent_node, dispatch_ordinal + 1)),
        none => none
    }
    let mut prefix = entry_prefix
    append_all(prefix, edge_cleanup_statements(
        ctx, parent_node, BRIDGE_ROLE_CONTROL_DISPATCH,
        dispatch_ordinal, 0))
    if guard.is_some() {
        append_all(prefix, edge_cleanup_statements(
            ctx, parent_node, BRIDGE_ROLE_CONTROL_DISPATCH,
            dispatch_ordinal + 1, 0))
    }
    require_no_edge_cleanup(
        ctx, parent_node, BRIDGE_ROLE_CONTROL_DISPATCH,
        dispatch_ordinal, 1, "pattern-unmatched edge")
    if dispatch_ordinal != 0 && before_terminator_drops(
            ctx, parent_node, BRIDGE_ROLE_CONTROL_DISPATCH,
            dispatch_ordinal).len() != 0 {
        panic("RcHIR bridge: later pattern test has resource drops")
    }
    let mut suffix = before_terminator_drops(
        ctx, parent_node, BRIDGE_ROLE_CONTROL_EXIT, arm_ordinal)
    append_all(suffix, edge_cleanup_statements(
        ctx, parent_node, BRIDGE_ROLE_CONTROL_EXIT, arm_ordinal, 0))
    HMatchArm {
        pattern: serialize_pattern(ctx, pattern),
        pattern_plan: some(serialize_pattern_plan(ctx.projection, pattern)),
        bindings: {
            let mut values: List<HPatternBinding> = []
            core_pattern_bindings(ctx.projection, pattern, values)
            values
        },
        guard: guard,
        body: serialize_core_block(
            ctx, owner, core_match_arm_body(arm),
            result_type, effects, some(parent_node), arm_ordinal,
            prefix, suffix),
        span: span_zero()
    }
}

fn serialize_move_update_expr(
    mut ctx: HirBridgeCtx, owner: ExecutableRef,
    expr: CoreExpr, node_ordinal: Int,
    ty: Type, effects: EffectRow
) -> SerializedExpr {
    let base = serialize_move_update_source(
        ctx, owner, core_expr_move_update_base(expr))
    let mut prefix = base.prefix
    let mut overrides: List<SerializedUpdateOverride> = []
    for field in core_expr_move_update_overrides(expr) {
        let reference = serialize_child_reference(
            ctx, owner, core_field_value_expr(field))
        append_all(prefix, reference.prefix)
        overrides.push(SerializedUpdateOverride {
            field: core_field_value_field(field), reference: reference
        })
    }

    let move_instruction = instruction_for_node_role(
        ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0, 12)
    let move_source = flow_move_place_source(move_instruction)
    let committed_slot = flow_move_place_target(move_instruction)
    if !flow_place_is_slot(move_source) {
        panic("RcHIR bridge: projected move spread crossed diagnostics")
    }
    let source_slot = if flow_place_is_slot(move_source) {
        flow_place_slot(move_source)
    } else { flow_place_base(move_source) }
    if !slot_ref_same(source_slot, base.slot) {
        panic("RcHIR bridge: MoveUpdate base/MovePlace slot differs")
    }
    let committed_value = wrap_exact_place_take(
        ctx, node_ordinal, source_slot, committed_slot, base.value,
        none, true,
        BRIDGE_ROLE_CONTROL_DISPATCH, 0)
    prefix.push(bridge_let_for_slot(ctx, committed_slot, committed_value))

    let committed_ident = bridge_binder_ident(ctx, committed_slot)
    let schema = core_expr_move_update_schema(expr)
    let mut field_slots: List<SlotRef> = []
    let mut role_ordinal = 1
    for field in schema {
        let mut override_value: SerializedReference? = none
        for candidate in overrides {
            if core_field_ref_same(candidate.field, field) {
                if override_value.is_some() {
                    panic("RcHIR bridge: MoveUpdate override repeats")
                }
                override_value = some(candidate.reference)
            }
        }
        let field_type = match override_value {
            some(value) => legacy_binder_projection_type(
                bridge_binder_for(ctx, value.slot)),
            none => legacy_type_for(
                ctx.projection,
                flow_projection_contract_result_type(
                    flow_project_contract(instruction_for_node_role(
                        ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH,
                        role_ordinal, 7))))
        }
        let place = projected_field_access(
            ctx, committed_ident, field, field_type, EMPTY_ROW)
        match override_value {
            some(value) => {
                let assign = instruction_for_node_role(
                    ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH,
                    role_ordinal, 5)
                if !slot_ref_same(flow_assign_rhs_temp(assign), value.slot) ||
                   flow_place_is_slot(flow_assign_target(assign)) ||
                   !slot_ref_same(
                        flow_place_base(flow_assign_target(assign)), committed_slot) {
                    panic("RcHIR bridge: MoveUpdate Assign relation differs")
                }
                append_all(prefix, before_drop_statements(
                    ctx, node_ordinal, some(place),
                    BRIDGE_ROLE_CONTROL_DISPATCH, role_ordinal))
                prefix.push(HStmt::Assign {
                    target: place,
                    value: wrap_resource_operand(
                        ctx, node_ordinal, 0, value.slot,
                        BRIDGE_ROLE_CONTROL_DISPATCH, role_ordinal),
                    span: span_zero()
                })
                append_all(prefix, after_resource_statements(
                    ctx, node_ordinal,
                    BRIDGE_ROLE_CONTROL_DISPATCH, role_ordinal))
                role_ordinal = role_ordinal + 1
            },
            none => {}
        }

        let project = instruction_for_node_role(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH,
            role_ordinal, 7)
        if !slot_ref_same(flow_project_base(project), committed_slot) {
            panic("RcHIR bridge: MoveUpdate Project base differs")
        }
        let field_slot = flow_project_result(project)
        let projected = projected_field_access(
            ctx, committed_ident, field,
            legacy_binder_projection_type(bridge_binder_for(ctx, field_slot)),
            EMPTY_ROW)
        let moved = wrap_exact_place_take(
            ctx, node_ordinal, committed_slot, field_slot, projected,
            some(flow_project_contract(project)), false,
            BRIDGE_ROLE_CONTROL_DISPATCH, role_ordinal)
        prefix.push(bridge_let_for_slot(ctx, field_slot, moved))
        append_all(prefix, after_resource_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, role_ordinal))
        field_slots.push(field_slot)
        role_ordinal = role_ordinal + 1
    }

    let initialize = instruction_for_node_role(
        ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH,
        role_ordinal, 0)
    let inputs = flow_initialize_inputs(initialize)
    if inputs.len() != field_slots.len() ||
       !slot_ref_same(flow_initialize_target(initialize), node_anchor(ctx, node_ordinal)) {
        panic("RcHIR bridge: MoveUpdate Initialize census differs")
    }
    let mut values: List<HExpr> = []
    let mut index = 0
    while index < field_slots.len() {
        if !slot_ref_same(
                inputs.get(index).unwrap(), field_slots.get(index).unwrap()) {
            panic("RcHIR bridge: MoveUpdate Initialize order differs")
        }
        values.push(wrap_resource_operand(
            ctx, node_ordinal, index, field_slots.get(index).unwrap(),
            BRIDGE_ROLE_CONTROL_DISPATCH, role_ordinal))
        index = index + 1
    }

    let constructor = core_expr_move_update_constructor(expr)
    let constructor_kind = core_constructor_kind_tag(constructor)
    let value = if constructor_kind == 0 {
        let owner_ref = core_constructor_struct_owner(constructor)
        let mut field_index = 0
        let fields = schema.map(fn(field) {
            let reference = core_field_ref_nominal(field)
            let result = HNominalStructFieldInit {
                name: nominal_field_ref_name(reference),
                field_ref: reference,
                field_index: nominal_field_ref_index(reference),
                value: values.get(field_index).unwrap()
            }
            field_index = field_index + 1
            result
        })
        HExpr::StructLit {
            name: registered_nominal_ref_display_name(owner_ref),
            owner_ref: owner_ref, type_args: [], fields: fields,
            spread: none,
            constructor: some(make_h_record_constructor_plan(
                schema.map(fn(field) { hir_projection(field) }))),
            ty: ty, effects: effects, span: span_zero()
        }
    } else if constructor_kind == 1 {
        let variant = core_constructor_variant(constructor)
        validate_flow_variant_initialize(initialize, variant)
        let variant_shell = match enum_variant_in_decls_opt(
                ctx.shell.decls, variant) {
            some(value) => value,
            none => panic("RcHIR bridge: MoveUpdate variant shell is absent")
        }
        let mut field_index = 0
        let fields = schema.map(fn(field) {
            let result = HStructFieldInit {
                name: match variant_shell.field_names {
                    some(names) => names.get(field_index).unwrap(),
                    none => field_index.to_str()
                },
                field_ref: core_field_ref_variant(field),
                value: values.get(field_index).unwrap()
            }
            field_index = field_index + 1
            result
        })
        HExpr::NamedVariantConstruct {
            enum_name: registered_nominal_ref_display_name(
                variant_ref_owner(variant)),
            variant_name: variant_shell.name, variant_ref: variant,
            fields: fields, spread: none,
            constructor: some(make_h_variant_constructor_plan(
                schema.map(fn(field) { hir_projection(field) }))),
            ty: ty, effects: effects, span: span_zero()
        }
    } else {
        panic("RcHIR bridge: MoveUpdate constructor is not nominal")
    }
    append_all(prefix, before_drop_statements(
        ctx, node_ordinal, none,
        BRIDGE_ROLE_CONTROL_DISPATCH, role_ordinal))
    SerializedExpr {
        node_ordinal: node_ordinal, prefix: prefix, value: value,
        after: after_resource_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, role_ordinal)
    }
}

fn serialize_structured_core_expr(
    mut ctx: HirBridgeCtx, owner: ExecutableRef,
    expr: CoreExpr, node_ordinal: Int
) -> SerializedExpr {
    let kind = core_expr_kind_tag(expr)
    let ty = legacy_type_for(ctx.projection, core_expr_type(expr))
    let effects = legacy_effects_for(ctx.projection, core_expr_effects(expr))
    if kind == 19 {
        return serialize_move_update_expr(
            ctx, owner, expr, node_ordinal, ty, effects)
    }
    if kind == 12 {
        let mut prefix = before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0)
        append_all(prefix, edge_cleanup_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0, 0))
        let mut suffix = before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0)
        append_all(suffix, edge_cleanup_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0, 0))
        return SerializedExpr {
            node_ordinal: node_ordinal, prefix: prefix,
            value: serialize_core_block(
                ctx, owner, core_expr_block(expr), ty, effects,
                some(node_ordinal), 0, [], suffix),
            after: []
        }
    }
    if kind == 13 {
        let condition = serialize_terminator_operand(
            ctx, owner, core_expr_condition(expr), node_ordinal, 0,
            BRIDGE_ROLE_CONTROL_DISPATCH, 0)
        let mut prefix = condition.prefix
        append_all(prefix, before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0)
        )
        let mut then_suffix = before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0)
        append_all(then_suffix, edge_cleanup_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0, 0))
        let mut else_suffix = before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 1)
        append_all(else_suffix, edge_cleanup_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 1, 0))
        return SerializedExpr {
            node_ordinal: node_ordinal, prefix: prefix,
            value: HExpr::IfExpr {
                condition: condition.value,
                then_branch: serialize_core_block(
                    ctx, owner, core_expr_then_block(expr), ty, effects,
                    some(node_ordinal), 0,
                    edge_cleanup_statements(
                        ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0, 0),
                    then_suffix),
                else_branch: some(serialize_core_block(
                    ctx, owner, core_expr_else_block(expr), ty, effects,
                    some(node_ordinal), 1,
                    edge_cleanup_statements(
                        ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0, 1),
                    else_suffix)),
                ty: ty, effects: effects, span: span_zero()
            },
            after: []
        }
    }
    if kind == 14 {
        let scrutinee = serialize_terminator_operand(
            ctx, owner, core_expr_scrutinee(expr), node_ordinal, 0,
            BRIDGE_ROLE_CONTROL_DISPATCH, 0)
        let arms = core_expr_match_arms(expr)
        let mut serialized_arms: List<HMatchArm> = []
        let mut index = 0
        for arm in arms {
            serialized_arms.push(serialize_match_arm(
                ctx, owner, arm, node_ordinal, index, index * 2,
                ty, effects, []))
            index = index + 1
        }
        let mut prefix = scrutinee.prefix
        append_all(prefix, before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0)
        )
        require_no_edge_cleanup(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT,
            arms.len(), 0, "final unmatched edge")
        return SerializedExpr {
            node_ordinal: node_ordinal, prefix: prefix,
            value: HExpr::MatchExpr {
                scrutinee: scrutinee.value,
                arms: serialized_arms,
                ty: ty, effects: effects, span: span_zero()
            },
            after: []
        }
    }
    if kind == 15 {
        let mut prefix = before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0)
        let mut protected_suffix = before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0)
        append_all(protected_suffix, edge_cleanup_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0, 0))
        let protected = serialize_core_block(
            ctx, owner, core_expr_try_body(expr), ty, effects,
            some(node_ordinal), 0,
            edge_cleanup_statements(
                ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0, 0),
            protected_suffix)
        let arms = core_expr_match_arms(expr)
        if arms.len() == 0 {
            panic("RcHIR bridge: TryCatch has no exact catch arms")
        }
        let caught_entry_cleanup = edge_cleanup_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0, 1)
        let mut serialized_arms: List<HMatchArm> = []
        let mut index = 0
        for arm in arms {
            serialized_arms.push(serialize_match_arm(
                ctx, owner, arm, node_ordinal,
                index + 1, 1 + index * 2, ty, effects,
                caught_entry_cleanup))
            index = index + 1
        }
        return SerializedExpr {
            node_ordinal: node_ordinal, prefix: prefix,
            value: HExpr::TryCatch {
                body: protected, arms: serialized_arms,
                ty: ty, effects: effects, span: span_zero()
            },
            after: []
        }
    }
    if kind == 16 {
        let mut prefix = before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0)
        let mut suffix = before_terminator_drops(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0)
        append_all(suffix, edge_cleanup_statements(
            ctx, node_ordinal, BRIDGE_ROLE_CONTROL_EXIT, 0, 0))
        let mut handlers: List<HEffectHandler> = []
        let mut dispatch_ordinal = 1
        let core_install = core_expr_effect_ctx_install(expr)
        let typed_install = core_install.map(fn(installation) {
            let mut instances: List<TypedHandledEffectInstance> = []
            for entry in core_effect_ctx_install_entries(installation) {
                let token = core_handler_installation_token(entry)
                instances.push(typed_effect_ctx_instance(
                    ctx.projection, token))
                for operation in core_handler_installation_operations(entry) {
                    handlers.push(serialize_handler(
                        ctx, operation, token,
                        node_ordinal, dispatch_ordinal))
                    dispatch_ordinal = dispatch_ordinal + 1
                }
            }
            // Flow lowering emits one owned overlay Initialize after all
            // ordered handler closures.
            dispatch_ordinal = dispatch_ordinal + 1
            make_typed_effect_ctx_install(
                core_effect_ctx_install_parent(installation),
                core_effect_ctx_install_child(installation), instances)
        })
        return SerializedExpr {
            node_ordinal: node_ordinal, prefix: prefix,
            value: HExpr::HandleExpr {
                body: serialize_core_block(
                    ctx, owner, core_expr_handle_body(expr), ty, effects,
                    some(node_ordinal), 0,
                    edge_cleanup_statements(
                        ctx, node_ordinal, BRIDGE_ROLE_CONTROL_DISPATCH, 0, 0),
                    suffix),
                handlers: handlers,
                effect_ctx_install: typed_install,
                ty: ty, effects: effects, span: span_zero()
            },
            after: []
        }
    }
    panic("RcHIR bridge: unknown structured Core expression")
}

struct CoreNodeCursor {
    next_ordinal: Int,
    step_map: CoreFlowStepMap
}

fn optional_slots_same(left: SlotRef?, right: SlotRef?) -> Bool {
    match (left, right) {
        (some(a), some(b)) => slot_ref_same(a, b),
        (none, none) => true,
        _ => false
    }
}

fn enter_verified_core_node(
    mut cursor: CoreNodeCursor, owner: ExecutableRef,
    kind_tag: Int, origin: OriginRef
) {
    let ordinal = cursor.next_ordinal
    for relation in core_flow_step_map_relations(cursor.step_map) {
        let node = core_flow_step_node(relation)
        if core_flow_node_ordinal(node) == ordinal {
            if !executable_ref_same(core_flow_node_owner(node), owner) ||
               core_flow_node_kind_tag(node) != kind_tag ||
               !origin_ref_same(core_flow_node_origin(node), origin) {
                panic("RcHIR bridge: canonical Core node relation drifted")
            }
        }
    }
    cursor.next_ordinal = cursor.next_ordinal + 1
}

fn validate_core_expr_nodes(
    mut cursor: CoreNodeCursor, owner: ExecutableRef, expr: CoreExpr
) {
    let kind = core_expr_kind_tag(expr)
    enter_verified_core_node(
        cursor, owner, kind, core_expr_origin(expr))
    if kind == 2 {
        for operand in core_expr_primitive_operands(expr) {
            validate_core_expr_nodes(cursor, owner, operand)
        }
    } else if kind == 3 || kind == 5 || kind == 6 {
        for argument in core_expr_call_arguments(expr) {
            validate_core_expr_nodes(cursor, owner, argument)
        }
    } else if kind == 4 {
        validate_core_expr_nodes(cursor, owner, core_expr_method_receiver(expr))
        for argument in core_expr_call_arguments(expr) {
            validate_core_expr_nodes(cursor, owner, argument)
        }
    } else if kind == 9 {
        validate_core_expr_nodes(cursor, owner, core_expr_project_base(expr))
    } else if kind == 10 {
        for field in core_expr_constructor_fields(expr) {
            validate_core_expr_nodes(cursor, owner, core_field_value_expr(field))
        }
    } else if kind == 19 {
        validate_core_expr_nodes(cursor, owner, core_expr_move_update_base(expr))
        for field in core_expr_move_update_overrides(expr) {
            validate_core_expr_nodes(cursor, owner, core_field_value_expr(field))
        }
    } else if kind == 18 {
        validate_core_expr_nodes(cursor, owner, core_expr_fail_payload(expr))
    } else if kind == 12 {
        validate_core_block_nodes(cursor, owner, core_expr_block(expr))
    } else if kind == 13 {
        validate_core_expr_nodes(cursor, owner, core_expr_condition(expr))
        validate_core_block_nodes(cursor, owner, core_expr_then_block(expr))
        validate_core_block_nodes(cursor, owner, core_expr_else_block(expr))
    } else if kind == 14 {
        validate_core_expr_nodes(cursor, owner, core_expr_scrutinee(expr))
        for arm in core_expr_match_arms(expr) {
            validate_core_arm_nodes(cursor, owner, arm)
        }
    } else if kind == 15 {
        validate_core_block_nodes(cursor, owner, core_expr_try_body(expr))
        for arm in core_expr_match_arms(expr) {
            validate_core_arm_nodes(cursor, owner, arm)
        }
    } else if kind == 16 {
        validate_core_block_nodes(cursor, owner, core_expr_handle_body(expr))
    }
}

fn validate_core_arm_nodes(
    mut cursor: CoreNodeCursor, owner: ExecutableRef, arm: CoreMatchArm
) {
    match core_match_arm_guard(arm) {
        some(guard) => validate_core_expr_nodes(cursor, owner, guard),
        none => {}
    }
    validate_core_block_nodes(cursor, owner, core_match_arm_body(arm))
}

fn validate_core_stmt_nodes(
    mut cursor: CoreNodeCursor, owner: ExecutableRef, statement: CoreStmt
) {
    let kind = core_stmt_kind_tag(statement)
    enter_verified_core_node(
        cursor, owner, kind, core_stmt_origin(statement))
    if kind == 1 {
        let place = core_stmt_target(statement)
        if !core_place_is_slot(place) {
            validate_core_expr_nodes(cursor, owner, core_place_base(place))
        }
        validate_core_expr_nodes(cursor, owner, core_stmt_value(statement))
    } else if kind == 0 || kind == 2 {
        validate_core_expr_nodes(cursor, owner, core_stmt_value(statement))
    } else if kind == 3 {
        validate_core_expr_nodes(
            cursor, owner, core_stmt_while_condition(statement))
        validate_core_block_nodes(
            cursor, owner, core_stmt_while_body(statement))
    } else if kind == 6 {
        match core_stmt_return_value(statement) {
            some(expr) => validate_core_expr_nodes(cursor, owner, expr),
            none => {}
        }
    } else if kind == 7 {
        validate_core_expr_nodes(
            cursor, owner, core_stmt_destructure_scrutinee(statement))
    }
}

fn validate_core_block_nodes(
    mut cursor: CoreNodeCursor, owner: ExecutableRef, block: CoreBlock
) {
    for statement in core_block_statements(block) {
        validate_core_stmt_nodes(cursor, owner, statement)
    }
    match core_block_tail(block) {
        some(expr) => validate_core_expr_nodes(cursor, owner, expr),
        none => {}
    }
}

fn validate_core_body_nodes(
    mut cursor: CoreNodeCursor, body: CoreBody
) {
    let owner = core_body_reference(body)
    enter_verified_core_node(cursor, owner, 0, core_body_origin(body))
    validate_core_block_nodes(cursor, owner, core_body_block(body))
}

fn core_body_for(
    values: List<CoreBodyEntry>, reference: ExecutableRef
) -> CoreBodyEntry {
    let mut found: CoreBodyEntry? = none
    for value in values {
        if executable_ref_same(core_body_entry_reference(value), reference) {
            if found.is_some() {
                panic("RcHIR bridge: Core body identity repeats")
            }
            found = some(value)
        }
    }
    match found {
        some(value) => value,
        none => panic("RcHIR bridge: Rc body has no exact Core body")
    }
}

fn flow_body_for(
    values: List<FlowBody>, reference: ExecutableRef
) -> FlowBody {
    let mut found: FlowBody? = none
    for value in values {
        if executable_ref_same(flow_body_reference(value), reference) {
            if found.is_some() {
                panic("RcHIR bridge: Flow body identity repeats")
            }
            found = some(value)
        }
    }
    match found {
        some(value) => value,
        none => panic("RcHIR bridge: Rc body has no exact Flow body")
    }
}

fn relation_for_step(
    step_map: CoreFlowStepMap, step: FlowSemanticStepRef
) -> CoreFlowStepRelation {
    let mut found: CoreFlowStepRelation? = none
    for relation in core_flow_step_map_relations(step_map) {
        if flow_semantic_step_same(core_flow_step(relation), step) {
            if found.is_some() {
                panic("RcHIR bridge: Flow step has multiple Core relations")
            }
            found = some(relation)
        }
    }
    match found {
        some(value) => value,
        none => panic("RcHIR bridge: Rc site has no Core/Flow relation")
    }
}

fn append_instruction_events(
    step_map: CoreFlowStepMap, step: RcStep,
    mut events: List<BridgeRcEvent>
) {
    let semantic_step = make_flow_instruction_step_ref(rc_step_instruction(step))
    let relation = relation_for_step(step_map, semantic_step)
    for operation in rc_step_before(step) {
        let site = rc_operation_site(operation)
        if !rc_semantic_site_is_instruction(site) ||
           rc_site_placement_tag(rc_semantic_site_placement(site)) !=
                BRIDGE_RC_BEFORE_INSTRUCTION ||
           !flow_semantic_step_same(
                make_flow_instruction_step_ref(
                    rc_semantic_site_instruction(site)), semantic_step) {
            panic("RcHIR bridge: before-operation site drifted")
        }
        events.push(BridgeRcEvent {
            ordinal: events.len(),
            node: core_flow_step_node(relation), step: semantic_step,
            role: core_flow_step_role(relation),
            placement: BRIDGE_RC_BEFORE_INSTRUCTION,
            operand_ordinal: rc_semantic_site_operand_ordinal(site),
            successor_ordinal: none, operation: operation
        })
    }
    for operation in rc_step_after(step) {
        let site = rc_operation_site(operation)
        if !rc_semantic_site_is_instruction(site) ||
           rc_site_placement_tag(rc_semantic_site_placement(site)) !=
                BRIDGE_RC_AFTER_INSTRUCTION ||
           !flow_semantic_step_same(
                make_flow_instruction_step_ref(
                    rc_semantic_site_instruction(site)), semantic_step) {
            panic("RcHIR bridge: after-operation site drifted")
        }
        events.push(BridgeRcEvent {
            ordinal: events.len(),
            node: core_flow_step_node(relation), step: semantic_step,
            role: core_flow_step_role(relation),
            placement: BRIDGE_RC_AFTER_INSTRUCTION,
            operand_ordinal: rc_semantic_site_operand_ordinal(site),
            successor_ordinal: none, operation: operation
        })
    }
}

fn append_terminator_events(
    step_map: CoreFlowStepMap, block: RcBlock,
    mut events: List<BridgeRcEvent>
) {
    let semantic_step = make_flow_terminator_step_ref(rc_block_source_ref(block))
    let relation = relation_for_step(step_map, semantic_step)
    for operation in rc_block_before_terminator(block) {
        let site = rc_operation_site(operation)
        if rc_semantic_site_is_instruction(site) ||
           rc_site_placement_tag(rc_semantic_site_placement(site)) !=
                BRIDGE_RC_BEFORE_TERMINATOR ||
           !flow_semantic_step_same(
                make_flow_terminator_step_ref(
                    rc_semantic_site_block(site)), semantic_step) ||
           rc_semantic_site_successor_ordinal(site).is_some() {
            panic("RcHIR bridge: terminator operation site drifted")
        }
        events.push(BridgeRcEvent {
            ordinal: events.len(),
            node: core_flow_step_node(relation), step: semantic_step,
            role: core_flow_step_role(relation),
            placement: BRIDGE_RC_BEFORE_TERMINATOR,
            operand_ordinal: rc_semantic_site_operand_ordinal(site),
            successor_ordinal: none, operation: operation
        })
    }
    for edge in rc_block_edges(block) {
        for operation in rc_edge_cleanup(edge) {
            let site = rc_operation_site(operation)
            if rc_semantic_site_is_instruction(site) ||
               rc_site_placement_tag(rc_semantic_site_placement(site)) !=
                    BRIDGE_RC_EDGE_CLEANUP ||
               !flow_semantic_step_same(
                    make_flow_terminator_step_ref(
                        rc_semantic_site_block(site)), semantic_step) ||
               rc_semantic_site_successor_ordinal(site) !=
                    some(rc_edge_successor_ordinal(edge)) {
                panic("RcHIR bridge: edge cleanup site drifted")
            }
            events.push(BridgeRcEvent {
                ordinal: events.len(),
                node: core_flow_step_node(relation), step: semantic_step,
                role: core_flow_step_role(relation),
                placement: BRIDGE_RC_EDGE_CLEANUP,
                operand_ordinal: rc_semantic_site_operand_ordinal(site),
                successor_ordinal: some(rc_edge_successor_ordinal(edge)),
                operation: operation
            })
        }
    }
}

fn validate_and_index_stages(
    verified: VerifiedOwnershipProgram
) -> VerifiedBridgeStages {
    let core = verified_ownership_program_core(verified)
    let flow = verified_ownership_program_flow(verified)
    let resources = verified_ownership_program_resources(verified)
    let step_map = verified_ownership_program_step_map(verified)
    let rc = verified_resource_program_rc_ir(resources)
    let flow_fingerprint = flow_topology_fingerprint_canonical(
        flow_program_topology_fingerprint(flow))
    if verified_resource_program_flow_fingerprint(resources) !=
       flow_fingerprint {
        panic("RcHIR bridge: verified RcIR belongs to another FlowProgram")
    }
    let core_bodies = core_program_bodies(core)
    let flow_bodies = flow_program_bodies(flow)
    let rc_bodies = rc_program_bodies(rc)
    if core_bodies.len() != flow_bodies.len() ||
       core_bodies.len() != rc_bodies.len() {
        panic("RcHIR bridge: Core/Flow/Rc body census differs")
    }
    let mut node_cursor = CoreNodeCursor {
        next_ordinal: 0, step_map: step_map
    }
    for entry in core_bodies {
        validate_core_body_nodes(node_cursor, core_body_entry_body(entry))
    }
    if node_cursor.next_ordinal != core_flow_step_map_node_count(step_map) {
        panic("RcHIR bridge: canonical Core node census differs")
    }
    let mut events: List<BridgeRcEvent> = []
    let mut body_index = 0
    while body_index < rc_bodies.len() {
        let rc_body = rc_bodies.get(body_index).unwrap()
        let reference = rc_body_reference(rc_body)
        if !executable_ref_same(
                core_body_entry_reference(
                    core_bodies.get(body_index).unwrap()), reference) ||
           !executable_ref_same(
                flow_body_reference(
                    flow_bodies.get(body_index).unwrap()), reference) {
            panic("RcHIR bridge: Core/Flow/Rc body order differs")
        }
        let _ = core_body_for(core_bodies, reference)
        let _ = flow_body_for(flow_bodies, reference)
        for block in rc_body_blocks(rc_body) {
            for step in rc_block_steps(block) {
                append_instruction_events(step_map, step, events)
            }
            append_terminator_events(step_map, block, events)
        }
        body_index = body_index + 1
    }
    VerifiedBridgeStages {
        core: core, flow: flow, resources: resources, rc: rc,
        step_map: step_map, events: events
    }
}
