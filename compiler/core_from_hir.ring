// Sole 0.1 Typed-HIR -> CoreProgram assembler.
//
// Every identity/type/evidence/binder fact is supplied by the frozen checker
// products in deterministic traversal order.  This pass never resolves a
// spelling/span and never lets HProgram escape after CoreProgram construction.

use ast::{Pattern, LiteralValue}
use types::{Type, EffectRow, effects_equal, types_equal}
use ir_identity::{
    OriginRef, SlotRef, PathRef, SymbolRef,
    RegisteredNominalRef, VariantRef,
    HandledEffectRef, SystemEffectRef,
    ImplOwnerRef, ImplMethodRef,
    slot_ref_same, variant_ref_same, impl_owner_ref_same
}
use ir_inventory::{
    ExecutableRef, ExecutableEntry, ExecutableInventory, BinderManifest,
    EffectOperationRef, SystemHostCallableRef,
    effect_operation_ref_same,
    executable_ref_same, make_executable_inventory,
    executable_inventory_entries, executable_entry_reference,
    executable_entry_contract, executable_contract_mode,
    executable_contract_mode_same,
    executable_contract_mode_concrete_body,
    executable_contract_body_path,
    binder_manifest_owner
}
use hir::{
    HExpr, HStmt, HMatchArm,
    HStringInterpPart, HFieldAccessKind, MethodCallRef,
    hexpr_type, hexpr_effects, method_call_ref_same
}
use flow_ir::{
    FlowScope, FlowScopeRef, FlowTypeNode, FlowTypeRef,
    FlowSemanticRole, FlowValueOriginContract, FlowCallableMode,
    FlowCallContract,
    FlowTypeKind, FlowGenericParamFact, FlowTypeSemanticSeed,
    FlowDropContract, FlowForeignContract,
    FlowFieldIdentity, FlowNominalFieldFact,
    FlowResourceDependencyEdge, FlowResourceDependencyTarget,
    FlowInitialSlotState, FlowStorageClass, FlowStorageContract,
    flow_type_node_reference, flow_type_ref_index,
    flow_type_node_intern_ready, flow_type_node_intern_key_same,
    remap_flow_type_node, flow_type_node_contract_same,
    make_flow_type_ref, make_flow_call_contract,
    make_module_flow_call_contract,
    flow_type_kind_tag, flow_type_kind_int, flow_type_kind_float,
    flow_type_kind_str, flow_type_kind_bool, flow_type_kind_unit,
    flow_type_kind_never, flow_type_kind_struct, flow_type_kind_enum,
    make_flow_int_type_node, make_flow_float_type_node,
    make_flow_str_type_node, make_flow_bool_type_node,
    make_flow_unit_type_node, make_flow_never_type_node,
    make_flow_struct_type_node, make_flow_enum_type_node,
    make_flow_extern_type_node, make_flow_tuple_type_node,
    make_flow_record_type_node, make_flow_callable_type_node,
    make_flow_ptr_type_node, make_flow_parameter_type_node,
    make_flow_nominal_field_fact,
    make_flow_parent_parameter_dependency,
    make_flow_concrete_type_dependency,
    make_flow_resource_dependency_edge,
    make_flow_application_resource_dependency_edge
}
use core_expr::{
    CoreTypeGraph, CoreTypeRef, CoreTypeFactRef, CoreTypeFactAllocator,
    CoreEffectSet,
    CoreCallableContract, CoreImplMetadata,
    CoreObligationBinding,
    CoreSlot, CoreBody, CoreBlock, CoreStmt, CoreExpr, CoreLiteral,
    CorePlaceRef,
    CorePattern, CorePatternField, CoreFieldRef,
    CoreHandlerEntry, CoreMatchArm,
    CoreConstructorRef, CoreCalleeRef, CoreEvidenceRef,
    CoreCapture, CorePrimitiveOp,
    make_core_type_ref, new_core_type_fact_allocator,
    reserve_core_type_fact_ref,
    core_type_fact_module_key, core_type_fact_ordinal,
    core_type_fact_same, core_type_fact_local_ref,
    core_type_ref_module_key, make_core_effect_set, core_effect_set_atoms,
    make_core_callable_contract, make_core_assoc_binding,
    make_core_impl_metadata,
    make_core_fail_effect, make_core_mut_effect, make_core_unsafe_effect,
    make_core_handled_effect, make_core_system_effect,
    make_core_direct_callee, make_core_local_callee, make_core_dynamic_callee,
    make_core_literal_expr, make_core_int_literal,
    make_core_float_literal, make_core_str_literal,
    make_core_bool_literal, make_core_unit_literal,
    make_core_read_expr, make_core_primitive_expr,
    make_core_callable_value_expr,
    make_core_call_expr, make_core_method_call_expr,
    make_core_effect_call_expr, make_core_system_call_expr,
    make_core_dict_construct_expr, make_core_project_expr,
    make_core_construct_expr, make_core_lambda_expr,
    make_core_block_expr, make_core_if_expr, make_core_match_expr,
    make_core_try_catch_expr, make_core_handle_expr,
    make_core_initialize_stmt, make_core_assign_stmt,
    make_core_expr_stmt, make_core_while_stmt,
    make_core_break_stmt, make_core_continue_stmt,
    make_core_return_stmt,
    make_core_block, make_core_match_arm, make_core_handler_entry,
    make_core_wildcard_pattern, make_core_binding_pattern,
    make_core_literal_pattern, make_core_tuple_pattern,
    make_core_struct_pattern, make_core_variant_pattern,
    make_core_pattern_field, make_core_field_value,
    make_core_body, make_core_slot, make_core_slot_place,
    make_core_project_place,
    core_expr_result, core_expr_type, core_expr_effects, core_expr_origin,
    core_block_origin,
    core_block_statements, core_block_tail, core_block_scope,
    core_body_reference, core_body_origin, core_body_result_type,
    core_constructor_variant,
    core_place_is_slot, core_place_slot,
    core_place_base, core_place_field, core_place_evaluated_index,
    core_field_ref_same,
    core_type_graph_count, core_type_graph_nodes, make_core_type_graph,
    make_module_core_type_graph,
    copy_core_callables, copy_core_impl_metadata,
    core_callable_reference, core_impl_owner,
    remap_core_callable_types, remap_core_impl_types, remap_core_body_types,
    validate_core_body_type_domain, validate_core_impl_type_domain,
    core_effect_set_same, core_body_effect_sets
}
use core_hir::{
    CoreProgram, CoreBodyEntry,
    make_core_body_entry, make_core_program,
    core_body_entry_reference, core_body_entry_body,
    core_body_entry_origin, core_body_entry_anchor
}
use core_elaborate::{
    CoreElaboratedBody, CoreOrdinaryBodyPlan,
    CoreStructClonePlan, CoreEnumClonePlan,
    elaborate_core_trait_default,
    elaborate_core_default_specialization,
    elaborate_core_derived_eq, elaborate_core_derived_ne,
    elaborate_core_derived_hash, elaborate_core_struct_deep_clone,
    elaborate_core_enum_deep_clone,
    elaborate_core_derived_ord, elaborate_core_derived_debug,
    elaborate_core_derived_json,
    core_elaborated_body
}
use delegate_plan::{
    DelegateTypedPlan,
    delegate_typed_plan_outer_type, delegate_typed_plan_field_type,
    delegate_typed_plan_type_count
}
use delegate_elaborate::{elaborate_delegate_to_core}

fn require_type_fact_module(value: CoreTypeFactRef, module_key: Str) {
    if core_type_fact_module_key(value) != module_key {
        panic("Core assembly: type fact belongs to another module recorder")
    }
}
fn local_core_type_ref(value: CoreTypeFactRef, module_key: Str) -> CoreTypeRef {
    require_type_fact_module(value, module_key)
    core_type_fact_local_ref(value)
}
fn local_flow_type_ref(
    value: CoreTypeFactRef, module_key: Str
) -> FlowTypeRef {
    require_type_fact_module(value, module_key)
    make_flow_type_ref(core_type_fact_ordinal(value))
}

pub struct CoreNominalFieldSpec {
    identity: FlowFieldIdentity,
    ty: CoreTypeFactRef
}
pub fn make_core_nominal_field_spec(
    identity: FlowFieldIdentity, ty: CoreTypeFactRef
) -> CoreNominalFieldSpec {
    CoreNominalFieldSpec { identity: identity, ty: ty }
}

enum CoreResourceDependencyTargetSpecValue {
    ParentParameterTargetSpec(FlowGenericParamFact),
    ConcreteTypeTargetSpec(CoreTypeFactRef)
}
pub struct CoreResourceDependencyTargetSpec {
    value: CoreResourceDependencyTargetSpecValue
}
pub fn make_core_parent_parameter_target_spec(
    parameter: FlowGenericParamFact
) -> CoreResourceDependencyTargetSpec {
    CoreResourceDependencyTargetSpec {
        value: CoreResourceDependencyTargetSpecValue::ParentParameterTargetSpec(
            parameter)
    }
}
pub fn make_core_concrete_type_target_spec(
    ty: CoreTypeFactRef
) -> CoreResourceDependencyTargetSpec {
    CoreResourceDependencyTargetSpec {
        value: CoreResourceDependencyTargetSpecValue::ConcreteTypeTargetSpec(ty)
    }
}
pub struct CoreResourceDependencyEdgeSpec {
    is_application: Bool,
    child_ordinal: Int,
    child: CoreTypeFactRef,
    child_dependency_ordinal: Int,
    application_parameter: FlowGenericParamFact?,
    target: CoreResourceDependencyTargetSpec
}
pub fn make_core_resource_dependency_edge_spec(
    child_ordinal: Int, child: CoreTypeFactRef,
    child_dependency_ordinal: Int,
    target: CoreResourceDependencyTargetSpec
) -> CoreResourceDependencyEdgeSpec {
    CoreResourceDependencyEdgeSpec {
        is_application: false, child_ordinal: child_ordinal, child: child,
        child_dependency_ordinal: child_dependency_ordinal,
        application_parameter: none, target: target
    }
}
pub fn make_core_application_resource_dependency_edge_spec(
    argument_ordinal: Int, argument: CoreTypeFactRef,
    argument_dependency_ordinal: Int,
    owner_parameter: FlowGenericParamFact,
    target: CoreResourceDependencyTargetSpec
) -> CoreResourceDependencyEdgeSpec {
    CoreResourceDependencyEdgeSpec {
        is_application: true, child_ordinal: argument_ordinal,
        child: argument,
        child_dependency_ordinal: argument_dependency_ordinal,
        application_parameter: some(owner_parameter), target: target
    }
}

enum CoreTypeSpecValue {
    AtomicTypeSpec(FlowTypeKind),
    ParameterTypeSpec(FlowGenericParamFact),
    NominalTypeSpec {
        kind: FlowTypeKind, nominal: SymbolRef,
        arguments: List<CoreTypeFactRef>,
        fields: List<CoreNominalFieldSpec>,
        semantic_seed: FlowTypeSemanticSeed,
        drop_contract: FlowDropContract?,
        resource_parameters: List<FlowGenericParamFact>,
        resource_edges: List<CoreResourceDependencyEdgeSpec>
    },
    ExternTypeSpec {
        nominal: SymbolRef, arguments: List<CoreTypeFactRef>,
        contract: FlowForeignContract,
        resource_edges: List<CoreResourceDependencyEdgeSpec>
    },
    TupleTypeSpec {
        elements: List<CoreTypeFactRef>,
        semantic_seed: FlowTypeSemanticSeed,
        drop_contract: FlowDropContract?,
        resource_parameters: List<FlowGenericParamFact>,
        resource_edges: List<CoreResourceDependencyEdgeSpec>
    },
    RecordTypeSpec {
        fields: List<CoreNominalFieldSpec>,
        semantic_seed: FlowTypeSemanticSeed,
        drop_contract: FlowDropContract?,
        resource_parameters: List<FlowGenericParamFact>,
        resource_edges: List<CoreResourceDependencyEdgeSpec>
    },
    CallableTypeSpec {
        parameters: List<CoreTypeFactRef>, result: CoreTypeFactRef
    },
    PtrTypeSpec(CoreTypeFactRef)
}
struct CoreTypeSpec { value: CoreTypeSpecValue }

fn materialize_resource_target_spec(
    value: CoreResourceDependencyTargetSpec, module_key: Str
) -> FlowResourceDependencyTarget {
    match value.value {
        CoreResourceDependencyTargetSpecValue::ParentParameterTargetSpec(
            parameter) => make_flow_parent_parameter_dependency(parameter),
        CoreResourceDependencyTargetSpecValue::ConcreteTypeTargetSpec(ty) =>
            make_flow_concrete_type_dependency(
                local_flow_type_ref(ty, module_key))
    }
}
fn materialize_resource_edge_spec(
    value: CoreResourceDependencyEdgeSpec, module_key: Str
) -> FlowResourceDependencyEdge {
    let child = local_flow_type_ref(value.child, module_key)
    let target = materialize_resource_target_spec(value.target, module_key)
    if value.is_application {
        make_flow_application_resource_dependency_edge(
            value.child_ordinal, child, value.child_dependency_ordinal,
            value.application_parameter.unwrap(), target)
    } else {
        make_flow_resource_dependency_edge(
            value.child_ordinal, child, value.child_dependency_ordinal, target)
    }
}
fn materialize_type_spec(
    value: CoreTypeSpec, reference: CoreTypeFactRef,
    module_key: Str
) -> FlowTypeNode {
    require_type_fact_module(reference, module_key)
    let flow_ref = local_flow_type_ref(reference, module_key)
    match value.value {
        CoreTypeSpecValue::AtomicTypeSpec(kind) => {
            let tag = flow_type_kind_tag(kind)
            if tag == flow_type_kind_tag(flow_type_kind_int()) {
                make_flow_int_type_node(flow_ref)
            } else if tag == flow_type_kind_tag(flow_type_kind_float()) {
                make_flow_float_type_node(flow_ref)
            } else if tag == flow_type_kind_tag(flow_type_kind_str()) {
                make_flow_str_type_node(flow_ref)
            } else if tag == flow_type_kind_tag(flow_type_kind_bool()) {
                make_flow_bool_type_node(flow_ref)
            } else if tag == flow_type_kind_tag(flow_type_kind_unit()) {
                make_flow_unit_type_node(flow_ref)
            } else if tag == flow_type_kind_tag(flow_type_kind_never()) {
                make_flow_never_type_node(flow_ref)
            } else {
                panic("Core assembly: non-atomic kind used atomic type fact")
            }
        },
        CoreTypeSpecValue::ParameterTypeSpec(parameter) =>
            make_flow_parameter_type_node(flow_ref, parameter),
        CoreTypeSpecValue::NominalTypeSpec {
            kind, nominal, arguments, fields, semantic_seed,
            drop_contract, resource_parameters, resource_edges
        } => {
            let args = arguments.map(fn(ty) {
                local_flow_type_ref(ty, module_key)
            })
            let exact_fields = fields.map(fn(field) {
                make_flow_nominal_field_fact(
                    field.identity, local_flow_type_ref(field.ty, module_key))
            })
            let edges = resource_edges.map(fn(edge) {
                materialize_resource_edge_spec(edge, module_key)
            })
            let tag = flow_type_kind_tag(kind)
            if tag == flow_type_kind_tag(flow_type_kind_struct()) {
                make_flow_struct_type_node(
                    flow_ref, nominal, args, exact_fields, semantic_seed,
                    drop_contract, resource_parameters, edges)
            } else if tag == flow_type_kind_tag(flow_type_kind_enum()) {
                make_flow_enum_type_node(
                    flow_ref, nominal, args, exact_fields, semantic_seed,
                    drop_contract, resource_parameters, edges)
            } else {
                panic("Core assembly: nominal fact kind is not struct/enum")
            }
        },
        CoreTypeSpecValue::ExternTypeSpec {
            nominal, arguments, contract, resource_edges
        } => make_flow_extern_type_node(
            flow_ref, nominal,
            arguments.map(fn(ty) { local_flow_type_ref(ty, module_key) }),
            contract,
            resource_edges.map(fn(edge) {
                materialize_resource_edge_spec(edge, module_key)
            })),
        CoreTypeSpecValue::TupleTypeSpec {
            elements, semantic_seed, drop_contract,
            resource_parameters, resource_edges
        } => make_flow_tuple_type_node(
            flow_ref,
            elements.map(fn(ty) { local_flow_type_ref(ty, module_key) }),
            semantic_seed, drop_contract, resource_parameters,
            resource_edges.map(fn(edge) {
                materialize_resource_edge_spec(edge, module_key)
            })),
        CoreTypeSpecValue::RecordTypeSpec {
            fields, semantic_seed, drop_contract,
            resource_parameters, resource_edges
        } => make_flow_record_type_node(
            flow_ref,
            fields.map(fn(field) {
                make_flow_nominal_field_fact(
                    field.identity, local_flow_type_ref(field.ty, module_key))
            }),
            semantic_seed, drop_contract, resource_parameters,
            resource_edges.map(fn(edge) {
                materialize_resource_edge_spec(edge, module_key)
            })),
        CoreTypeSpecValue::CallableTypeSpec { parameters, result } =>
            make_flow_callable_type_node(
                flow_ref,
                parameters.map(fn(ty) {
                    local_flow_type_ref(ty, module_key)
                }),
                local_flow_type_ref(result, module_key)),
        CoreTypeSpecValue::PtrTypeSpec(pointee) =>
            make_flow_ptr_type_node(
                flow_ref, local_flow_type_ref(pointee, module_key))
    }
}

pub struct CoreCallContractFact {
    module_key: Str,
    parameter_types: List<CoreTypeFactRef>,
    parameter_roles: List<FlowSemanticRole>,
    result_type: CoreTypeFactRef,
    result_role: FlowSemanticRole,
    result_origin: FlowValueOriginContract
}
pub fn make_core_call_contract_fact(
    parameter_types: List<CoreTypeFactRef>,
    parameter_roles: List<FlowSemanticRole>,
    result_type: CoreTypeFactRef, result_role: FlowSemanticRole,
    result_origin: FlowValueOriginContract
) -> CoreCallContractFact {
    if parameter_types.len() != parameter_roles.len() {
        panic("Core assembly: call contract type/role arity differs")
    }
    let module_key = core_type_fact_module_key(result_type)
    require_type_fact_module(result_type, module_key)
    for ty in parameter_types { require_type_fact_module(ty, module_key) }
    CoreCallContractFact {
        module_key: module_key,
        parameter_types: parameter_types.map(fn(value) { value }),
        parameter_roles: parameter_roles.map(fn(value) { value }),
        result_type: result_type, result_role: result_role,
        result_origin: result_origin
    }
}
fn materialize_call_contract_fact(
    value: CoreCallContractFact, module_key: Str
) -> FlowCallContract {
    if value.module_key != module_key {
        panic("Core assembly: call contract belongs to another recorder")
    }
    make_module_flow_call_contract(
        module_key,
        value.parameter_types.map(fn(ty) {
            local_flow_type_ref(ty, module_key)
        }),
        value.parameter_roles,
        local_flow_type_ref(value.result_type, module_key),
        value.result_role, value.result_origin)
}
pub fn core_call_contract_fact_local_contract(
    value: CoreCallContractFact
) -> FlowCallContract {
    materialize_call_contract_fact(value, value.module_key)
}

enum CoreCalleeFactValue {
    DirectCalleeFact(ExecutableRef),
    LocalCalleeFact(SlotRef),
    DynamicCalleeFact(PathRef)
}
pub struct CoreCalleeFact {
    value: CoreCalleeFactValue,
    contract: CoreCallContractFact
}
pub fn make_core_direct_callee_fact(
    value: ExecutableRef, contract: CoreCallContractFact
) -> CoreCalleeFact {
    CoreCalleeFact { value: CoreCalleeFactValue::DirectCalleeFact(value),
        contract: contract }
}
pub fn make_core_local_callee_fact(
    value: SlotRef, contract: CoreCallContractFact
) -> CoreCalleeFact {
    CoreCalleeFact { value: CoreCalleeFactValue::LocalCalleeFact(value),
        contract: contract }
}
pub fn make_core_dynamic_callee_fact(
    value: PathRef, contract: CoreCallContractFact
) -> CoreCalleeFact {
    CoreCalleeFact { value: CoreCalleeFactValue::DynamicCalleeFact(value),
        contract: contract }
}
fn materialize_callee_fact(
    value: CoreCalleeFact, module_key: Str
) -> CoreCalleeRef {
    let contract = materialize_call_contract_fact(value.contract, module_key)
    match value.value {
        CoreCalleeFactValue::DirectCalleeFact(executable) =>
            make_core_direct_callee(executable, contract),
        CoreCalleeFactValue::LocalCalleeFact(slot) =>
            make_core_local_callee(slot, contract),
        CoreCalleeFactValue::DynamicCalleeFact(path) =>
            make_core_dynamic_callee(path, contract)
    }
}
pub fn core_callee_fact_local_ref(value: CoreCalleeFact) -> CoreCalleeRef {
    materialize_callee_fact(value, value.contract.module_key)
}

enum CoreEffectAtomFactValue {
    FailEffectFact(CoreTypeFactRef),
    MutEffectFact(CoreTypeFactRef),
    UnsafeEffectFact,
    HandledEffectFact(HandledEffectRef),
    SystemEffectFact(SystemEffectRef)
}
pub struct CoreEffectAtomFact { value: CoreEffectAtomFactValue }
pub fn core_fail_effect_fact(ty: CoreTypeFactRef) -> CoreEffectAtomFact {
    CoreEffectAtomFact { value: CoreEffectAtomFactValue::FailEffectFact(ty) }
}
pub fn core_mut_effect_fact(ty: CoreTypeFactRef) -> CoreEffectAtomFact {
    CoreEffectAtomFact { value: CoreEffectAtomFactValue::MutEffectFact(ty) }
}
pub fn core_unsafe_effect_fact() -> CoreEffectAtomFact {
    CoreEffectAtomFact { value: CoreEffectAtomFactValue::UnsafeEffectFact }
}
pub fn core_handled_effect_fact(
    effect_ref: HandledEffectRef
) -> CoreEffectAtomFact {
    CoreEffectAtomFact {
        value: CoreEffectAtomFactValue::HandledEffectFact(effect_ref) }
}
pub fn core_system_effect_fact(
    effect_ref: SystemEffectRef
) -> CoreEffectAtomFact {
    CoreEffectAtomFact {
        value: CoreEffectAtomFactValue::SystemEffectFact(effect_ref) }
}
pub struct CoreEffectSetFact {
    module_key: Str,
    atoms: List<CoreEffectAtomFact>
}
pub fn make_core_effect_set_fact(
    anchor: CoreTypeFactRef, atoms: List<CoreEffectAtomFact>
) -> CoreEffectSetFact {
    let module_key = core_type_fact_module_key(anchor)
    for atom in atoms {
        match atom.value {
            CoreEffectAtomFactValue::FailEffectFact(ty) |
            CoreEffectAtomFactValue::MutEffectFact(ty) =>
                require_type_fact_module(ty, module_key),
            _ => {}
        }
    }
    CoreEffectSetFact { module_key: module_key,
        atoms: atoms.map(fn(value) { value }) }
}
fn materialize_effect_set_fact(
    value: CoreEffectSetFact, module_key: Str
) -> CoreEffectSet {
    if value.module_key != module_key {
        panic("Core assembly: effect set belongs to another recorder")
    }
    make_core_effect_set(value.atoms.map(fn(atom) {
        match atom.value {
            CoreEffectAtomFactValue::FailEffectFact(ty) =>
                make_core_fail_effect(local_core_type_ref(ty, module_key)),
            CoreEffectAtomFactValue::MutEffectFact(ty) =>
                make_core_mut_effect(local_core_type_ref(ty, module_key)),
            CoreEffectAtomFactValue::UnsafeEffectFact => make_core_unsafe_effect(),
            CoreEffectAtomFactValue::HandledEffectFact(effect_ref) =>
                make_core_handled_effect(effect_ref),
            CoreEffectAtomFactValue::SystemEffectFact(effect_ref) =>
                make_core_system_effect(effect_ref)
        }
    }))
}
pub fn core_effect_set_fact_local_set(
    value: CoreEffectSetFact
) -> CoreEffectSet {
    materialize_effect_set_fact(value, value.module_key)
}

enum RecordedCoreExprAdapterValue {
    PlainAdapter,
    ReadAdapter(SlotRef),
    DirectCallableAdapter(ExecutableRef),
    PrimitiveAdapter(CorePrimitiveOp),
    CallAdapter { callee: CoreCalleeFact, evidence: List<CoreEvidenceRef> },
    MethodAdapter { callee: CoreCalleeFact, method: MethodCallRef,
                    receiver: SlotRef,
                    evidence: List<CoreEvidenceRef> },
    ProjectAdapter { field: CoreFieldRef, partial: Bool },
    ConstructAdapter { constructor: CoreConstructorRef,
                       fields: List<CoreFieldRef> },
    EffectAdapter { operation: EffectOperationRef,
                    evidence: List<CoreEvidenceRef> },
    SystemAdapter(SystemHostCallableRef),
    DictAdapter { constructor: ExecutableRef,
                  evidence: List<CoreEvidenceRef> },
    LambdaAdapter { executable: ExecutableRef, manifest: BinderManifest,
                    captures: List<CoreCapture> },
    HandleAdapter { handlers: List<CoreHandlerEntry> },
    StringInterpAdapter {
        callee: CoreCalleeFact,
        evidence: List<CoreEvidenceRef>,
        literals: List<CoreStringLiteralFact>
    }
}
pub struct CoreExprAdapter { value: RecordedCoreExprAdapterValue }

pub struct CoreStringLiteralFact {
    value: Str,
    slot: SlotRef,
    ty: CoreTypeFactRef,
    origin: OriginRef
}
pub fn make_core_string_literal_fact(
    value: Str, slot: SlotRef, ty: CoreTypeFactRef, origin: OriginRef
) -> CoreStringLiteralFact {
    CoreStringLiteralFact { value: value, slot: slot, ty: ty, origin: origin }
}

fn copy_evidence(values: List<CoreEvidenceRef>) -> List<CoreEvidenceRef> {
    let mut result: List<CoreEvidenceRef> = []
    for value in values { result.push(value) }
    result
}
fn copy_fields(values: List<CoreFieldRef>) -> List<CoreFieldRef> {
    let mut result: List<CoreFieldRef> = []
    for value in values { result.push(value) }
    result
}
fn copy_captures(values: List<CoreCapture>) -> List<CoreCapture> {
    let mut result: List<CoreCapture> = []
    for value in values { result.push(value) }
    result
}
pub fn core_expr_plain_adapter() -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::PlainAdapter }
}
pub fn core_expr_read_adapter(source: SlotRef) -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::ReadAdapter(source) }
}
pub fn core_expr_direct_callable_adapter(
    executable: ExecutableRef
) -> CoreExprAdapter {
    CoreExprAdapter { value:
        RecordedCoreExprAdapterValue::DirectCallableAdapter(executable) }
}
pub fn core_expr_primitive_adapter(operation: CorePrimitiveOp) -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::PrimitiveAdapter(operation) }
}
pub fn core_expr_call_adapter(
    callee: CoreCalleeFact, evidence: List<CoreEvidenceRef>
) -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::CallAdapter {
        callee: callee, evidence: copy_evidence(evidence) } }
}
pub fn core_expr_method_adapter(
    callee: CoreCalleeFact, method: MethodCallRef,
    receiver: SlotRef,
    evidence: List<CoreEvidenceRef>
) -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::MethodAdapter {
        callee: callee, method: method, receiver: receiver,
        evidence: copy_evidence(evidence) } }
}
pub fn core_expr_project_adapter(
    field: CoreFieldRef, partial: Bool
) -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::ProjectAdapter {
        field: field, partial: partial } }
}
pub fn core_expr_construct_adapter(
    constructor: CoreConstructorRef, fields: List<CoreFieldRef>
) -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::ConstructAdapter {
        constructor: constructor, fields: copy_fields(fields) } }
}
pub fn core_expr_effect_adapter(
    operation: EffectOperationRef, evidence: List<CoreEvidenceRef>
) -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::EffectAdapter {
        operation: operation, evidence: copy_evidence(evidence) } }
}
pub fn core_expr_system_adapter(host: SystemHostCallableRef) -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::SystemAdapter(host) }
}
pub fn core_expr_dict_adapter(
    constructor: ExecutableRef, evidence: List<CoreEvidenceRef>
) -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::DictAdapter {
        constructor: constructor, evidence: copy_evidence(evidence) } }
}
pub fn core_expr_lambda_adapter(
    executable: ExecutableRef, manifest: BinderManifest,
    captures: List<CoreCapture>
) -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::LambdaAdapter {
        executable: executable, manifest: manifest,
        captures: copy_captures(captures) } }
}
pub fn core_expr_handle_adapter(
    handlers: List<CoreHandlerEntry>
) -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::HandleAdapter {
        handlers: handlers.map(fn(value) { value }) } }
}
pub fn core_expr_string_interp_adapter(
    callee: CoreCalleeFact, evidence: List<CoreEvidenceRef>,
    literals: List<CoreStringLiteralFact>
) -> CoreExprAdapter {
    CoreExprAdapter { value: RecordedCoreExprAdapterValue::StringInterpAdapter {
        callee: callee, evidence: copy_evidence(evidence),
        literals: literals.map(fn(value) { value }) } }
}

pub struct CoreExprFact {
    source_type: Type,
    source_effects: EffectRow,
    result: SlotRef,
    ty: CoreTypeFactRef,
    effects: CoreEffectSetFact,
    origin: OriginRef,
    adapter: CoreExprAdapter
}
pub fn make_core_expr_fact(
    source_type: Type, source_effects: EffectRow,
    result: SlotRef, ty: CoreTypeFactRef, effects: CoreEffectSetFact,
    origin: OriginRef, adapter: CoreExprAdapter
) -> CoreExprFact {
    CoreExprFact { source_type: source_type, source_effects: source_effects,
        result: result, ty: ty, effects: effects,
        origin: origin, adapter: adapter }
}

pub struct CoreDestructureBinding {
    base: SlotRef, field: CoreFieldRef,
    target: SlotRef, ty: CoreTypeFactRef, origin: OriginRef
}
pub fn make_core_destructure_binding(
    base: SlotRef, field: CoreFieldRef,
    target: SlotRef, ty: CoreTypeFactRef, origin: OriginRef
) -> CoreDestructureBinding {
    CoreDestructureBinding {
        base: base, field: field, target: target, ty: ty, origin: origin
    }
}

pub struct CoreForInPlan {
    iterator_slot: SlotRef, iterator_type: CoreTypeFactRef,
    iter_callee: CoreCalleeFact, iter_method: MethodCallRef,
    iter_effects: CoreEffectSetFact, iter_evidence: List<CoreEvidenceRef>,
    iter_origin: OriginRef,
    condition_slot: SlotRef, condition_type: CoreTypeFactRef,
    has_next_callee: CoreCalleeFact, has_next_method: MethodCallRef,
    has_next_effects: CoreEffectSetFact,
    has_next_evidence: List<CoreEvidenceRef>,
    has_next_origin: OriginRef,
    item_slot: SlotRef, item_type: CoreTypeFactRef,
    next_callee: CoreCalleeFact, next_method: MethodCallRef,
    next_effects: CoreEffectSetFact, next_evidence: List<CoreEvidenceRef>,
    next_origin: OriginRef,
    binding_slot: SlotRef,
    destructure: List<CoreDestructureBinding>
}
pub fn make_core_for_in_plan(
    iterator_slot: SlotRef, iterator_type: CoreTypeFactRef,
    iter_callee: CoreCalleeFact, iter_method: MethodCallRef,
    iter_effects: CoreEffectSetFact, iter_evidence: List<CoreEvidenceRef>,
    iter_origin: OriginRef,
    condition_slot: SlotRef, condition_type: CoreTypeFactRef,
    has_next_callee: CoreCalleeFact, has_next_method: MethodCallRef,
    has_next_effects: CoreEffectSetFact,
    has_next_evidence: List<CoreEvidenceRef>, has_next_origin: OriginRef,
    item_slot: SlotRef, item_type: CoreTypeFactRef,
    next_callee: CoreCalleeFact, next_method: MethodCallRef,
    next_effects: CoreEffectSetFact, next_evidence: List<CoreEvidenceRef>,
    next_origin: OriginRef, binding_slot: SlotRef,
    destructure: List<CoreDestructureBinding>
) -> CoreForInPlan {
    CoreForInPlan {
        iterator_slot: iterator_slot, iterator_type: iterator_type,
        iter_callee: iter_callee, iter_method: iter_method,
        iter_effects: iter_effects, iter_evidence: copy_evidence(iter_evidence),
        iter_origin: iter_origin,
        condition_slot: condition_slot, condition_type: condition_type,
        has_next_callee: has_next_callee, has_next_method: has_next_method,
        has_next_effects: has_next_effects,
        has_next_evidence: copy_evidence(has_next_evidence),
        has_next_origin: has_next_origin,
        item_slot: item_slot, item_type: item_type,
        next_callee: next_callee, next_method: next_method,
        next_effects: next_effects, next_evidence: copy_evidence(next_evidence),
        next_origin: next_origin, binding_slot: binding_slot,
        destructure: destructure.map(fn(value) { value })
    }
}

pub struct CoreIfLetPlan {
    result_slot: SlotRef, result_type: CoreTypeFactRef,
    scrutinee_type: CoreTypeFactRef, effects: CoreEffectSetFact,
    origin: OriginRef
}
pub fn make_core_if_let_plan(
    result_slot: SlotRef, result_type: CoreTypeFactRef,
    scrutinee_type: CoreTypeFactRef, effects: CoreEffectSetFact,
    origin: OriginRef
) -> CoreIfLetPlan {
    CoreIfLetPlan { result_slot: result_slot, result_type: result_type,
        scrutinee_type: scrutinee_type, effects: effects, origin: origin }
}

enum CorePlaceFactValue {
    SlotPlaceFact(SlotRef),
    ProjectPlaceFact {
        base: SlotRef, field: CoreFieldRef?, evaluated_index: SlotRef?,
        value_type: CoreTypeFactRef
    }
}
pub struct CorePlaceFact { value: CorePlaceFactValue }
pub fn make_core_slot_place_fact(slot: SlotRef) -> CorePlaceFact {
    CorePlaceFact { value: CorePlaceFactValue::SlotPlaceFact(slot) }
}
pub fn make_core_project_place_fact(
    base: SlotRef, field: CoreFieldRef?, evaluated_index: SlotRef?,
    value_type: CoreTypeFactRef
) -> CorePlaceFact {
    if (field.is_some() && evaluated_index.is_some()) ||
       (field.is_none() && evaluated_index.is_none()) {
        panic("Core assembly: projected place must select field xor index")
    }
    CorePlaceFact { value: CorePlaceFactValue::ProjectPlaceFact {
        base: base, field: field, evaluated_index: evaluated_index,
        value_type: value_type
    } }
}
fn materialize_place_fact(
    value: CorePlaceFact, module_key: Str
) -> CorePlaceRef {
    match value.value {
        CorePlaceFactValue::SlotPlaceFact(slot) =>
            make_core_slot_place(slot),
        CorePlaceFactValue::ProjectPlaceFact {
            base, field, evaluated_index, value_type
        } => make_core_project_place(
            base, field, evaluated_index,
            local_core_type_ref(value_type, module_key))
    }
}

pub struct CoreStmtFact {
    origin: OriginRef,
    target: CorePlaceFact?,
    for_in: CoreForInPlan?,
    destructure: List<CoreDestructureBinding>?,
    if_let: CoreIfLetPlan?
}
pub fn make_core_stmt_fact(
    origin: OriginRef, target: CorePlaceFact?
) -> CoreStmtFact {
    CoreStmtFact { origin: origin, target: target,
        for_in: none, destructure: none, if_let: none }
}
pub fn make_core_for_in_stmt_fact(
    origin: OriginRef, plan: CoreForInPlan
) -> CoreStmtFact {
    CoreStmtFact { origin: origin, target: none,
        for_in: some(plan), destructure: none, if_let: none }
}
pub fn make_core_destructure_stmt_fact(
    origin: OriginRef, bindings: List<CoreDestructureBinding>
) -> CoreStmtFact {
    CoreStmtFact { origin: origin, target: none, for_in: none,
        destructure: some(bindings.map(fn(value) { value })), if_let: none }
}
pub fn make_core_if_let_stmt_fact(
    origin: OriginRef, plan: CoreIfLetPlan
) -> CoreStmtFact {
    CoreStmtFact { origin: origin, target: none,
        for_in: none, destructure: none, if_let: some(plan) }
}
pub struct CoreBlockFact { origin: OriginRef, scope: FlowScopeRef }
pub fn make_core_block_fact(
    origin: OriginRef, scope: FlowScopeRef
) -> CoreBlockFact { CoreBlockFact { origin: origin, scope: scope } }

enum CorePatternAdapterValue {
    PatternWildcard,
    PatternBinding(SlotRef),
    PatternLiteral,
    PatternTuple,
    PatternStruct { owner: RegisteredNominalRef,
                    fields: List<CoreFieldRef> },
    PatternVariant { variant: VariantRef,
                     fields: List<CoreFieldRef> },
    PatternOr
}
pub struct CorePatternFact {
    ty: CoreTypeFactRef,
    value: CorePatternAdapterValue
}
pub fn core_pattern_wildcard_fact(ty: CoreTypeFactRef) -> CorePatternFact {
    CorePatternFact { ty: ty, value: CorePatternAdapterValue::PatternWildcard }
}
pub fn core_pattern_binding_fact(
    ty: CoreTypeFactRef, slot: SlotRef
) -> CorePatternFact {
    CorePatternFact { ty: ty,
        value: CorePatternAdapterValue::PatternBinding(slot) }
}
pub fn core_pattern_literal_fact(ty: CoreTypeFactRef) -> CorePatternFact {
    CorePatternFact { ty: ty, value: CorePatternAdapterValue::PatternLiteral }
}
pub fn core_pattern_tuple_fact(ty: CoreTypeFactRef) -> CorePatternFact {
    CorePatternFact { ty: ty, value: CorePatternAdapterValue::PatternTuple }
}
pub fn core_pattern_struct_fact(
    ty: CoreTypeFactRef, owner: RegisteredNominalRef,
    fields: List<CoreFieldRef>
) -> CorePatternFact {
    CorePatternFact { ty: ty, value: CorePatternAdapterValue::PatternStruct {
        owner: owner, fields: copy_fields(fields) } }
}
pub fn core_pattern_variant_fact(
    ty: CoreTypeFactRef, variant: VariantRef,
    fields: List<CoreFieldRef>
) -> CorePatternFact {
    CorePatternFact { ty: ty, value: CorePatternAdapterValue::PatternVariant {
        variant: variant, fields: copy_fields(fields) } }
}
pub fn core_pattern_or_fact(ty: CoreTypeFactRef) -> CorePatternFact {
    CorePatternFact { ty: ty, value: CorePatternAdapterValue::PatternOr }
}

pub struct CoreSlotFact {
    reference: SlotRef,
    ty: CoreTypeFactRef,
    scope: FlowScopeRef,
    reverse_ordinal: Int,
    initial_state: FlowInitialSlotState,
    storage: FlowStorageClass,
    storage_contract: FlowStorageContract,
    parameter_ordinal: Int?
}
pub fn make_core_slot_fact(
    reference: SlotRef, ty: CoreTypeFactRef, scope: FlowScopeRef,
    reverse_ordinal: Int, initial_state: FlowInitialSlotState,
    storage: FlowStorageClass, storage_contract: FlowStorageContract,
    parameter_ordinal: Int?
) -> CoreSlotFact {
    CoreSlotFact {
        reference: reference, ty: ty, scope: scope,
        reverse_ordinal: reverse_ordinal, initial_state: initial_state,
        storage: storage, storage_contract: storage_contract,
        parameter_ordinal: parameter_ordinal
    }
}
fn materialize_slot_fact(
    value: CoreSlotFact, module_key: Str
) -> CoreSlot {
    make_core_slot(
        value.reference, local_core_type_ref(value.ty, module_key),
        value.scope, value.reverse_ordinal, value.initial_state,
        value.storage, value.storage_contract, value.parameter_ordinal)
}
pub fn core_slot_fact_local_slot(value: CoreSlotFact) -> CoreSlot {
    materialize_slot_fact(value, core_type_fact_module_key(value.ty))
}

pub struct CoreSourceBodyInput {
    module_key: Str,
    source: HExpr,
    executable: ExecutableRef, origin: OriginRef, body_anchor: PathRef,
    manifest: BinderManifest, scopes: List<FlowScope>, slots: List<CoreSlotFact>,
    parameter_slots: List<SlotRef>, result_type: CoreTypeFactRef,
    expr_facts: List<CoreExprFact>, stmt_facts: List<CoreStmtFact>,
    block_facts: List<CoreBlockFact>, pattern_facts: List<CorePatternFact>
}
fn copy_scopes(values: List<FlowScope>) -> List<FlowScope> {
    let mut result: List<FlowScope> = []
    for value in values { result.push(value) }
    result
}
fn copy_slot_facts(values: List<CoreSlotFact>) -> List<CoreSlotFact> {
    let mut result: List<CoreSlotFact> = []
    for value in values { result.push(value) }
    result
}
fn copy_slot_refs(values: List<SlotRef>) -> List<SlotRef> {
    let mut result: List<SlotRef> = []
    for value in values { result.push(value) }
    result
}
pub fn make_core_source_body_input(
    source: HExpr,
    executable: ExecutableRef, origin: OriginRef, body_anchor: PathRef,
    manifest: BinderManifest, scopes: List<FlowScope>,
    slots: List<CoreSlotFact>, parameter_slots: List<SlotRef>,
    result_type: CoreTypeFactRef, expr_facts: List<CoreExprFact>,
    stmt_facts: List<CoreStmtFact>, block_facts: List<CoreBlockFact>,
    pattern_facts: List<CorePatternFact>
) -> CoreSourceBodyInput {
    let module_key = core_type_fact_module_key(result_type)
    require_type_fact_module(result_type, module_key)
    for slot in slots { require_type_fact_module(slot.ty, module_key) }
    for fact in expr_facts {
        require_type_fact_module(fact.ty, module_key)
        let _ = materialize_effect_set_fact(fact.effects, module_key)
        let _ = materialize_expr_adapter(fact.adapter, module_key)
    }
    for fact in pattern_facts {
        require_type_fact_module(fact.ty, module_key)
    }
    for fact in stmt_facts {
        match fact.target {
            some(value) => { let _ = materialize_place_fact(value, module_key) },
            none => {}
        }
        match fact.for_in {
            some(value) => { let _ = materialize_for_in_plan(value, module_key) },
            none => {}
        }
        match fact.destructure {
            some(values) => {
                let _ = materialize_destructure_bindings(values, module_key)
            },
            none => {}
        }
        match fact.if_let {
            some(value) => { let _ = materialize_if_let_plan(value, module_key) },
            none => {}
        }
    }
    CoreSourceBodyInput {
        module_key: module_key,
        source: source,
        executable: executable, origin: origin, body_anchor: body_anchor,
        manifest: manifest, scopes: copy_scopes(scopes),
        slots: copy_slot_facts(slots),
        parameter_slots: copy_slot_refs(parameter_slots), result_type: result_type,
        expr_facts: expr_facts.map(fn(value) { value }),
        stmt_facts: stmt_facts.map(fn(value) { value }),
        block_facts: block_facts.map(fn(value) { value }),
        pattern_facts: pattern_facts.map(fn(value) { value })
    }
}

enum CoreGeneratedPlanValue {
    GeneratedTraitDefault(CoreOrdinaryBodyPlan),
    GeneratedDefaultSpecialization(CoreOrdinaryBodyPlan),
    GeneratedDerivedEq(CoreOrdinaryBodyPlan),
    GeneratedDerivedNe(CoreOrdinaryBodyPlan),
    GeneratedDerivedHash(CoreOrdinaryBodyPlan),
    GeneratedStructClone(CoreStructClonePlan),
    GeneratedEnumClone(CoreEnumClonePlan),
    GeneratedDerivedOrd(CoreOrdinaryBodyPlan),
    GeneratedDerivedDebug(CoreOrdinaryBodyPlan),
    GeneratedDerivedJson(CoreOrdinaryBodyPlan)
}
pub struct CoreGeneratedPlan {
    module_key: Str,
    value: CoreGeneratedPlanValue
}
fn bind_generated_plan(
    anchor: CoreTypeFactRef, value: CoreGeneratedPlanValue
) -> CoreGeneratedPlan {
    let result = CoreGeneratedPlan {
        module_key: core_type_fact_module_key(anchor), value: value
    }
    let body = materialize_generated(result)
    validate_core_body_type_domain(body, core_type_fact_module_key(anchor))
    result
}
pub fn core_generated_trait_default(
    anchor: CoreTypeFactRef, value: CoreOrdinaryBodyPlan
) -> CoreGeneratedPlan {
    bind_generated_plan(
        anchor, CoreGeneratedPlanValue::GeneratedTraitDefault(value))
}
pub fn core_generated_default_specialization(
    anchor: CoreTypeFactRef, value: CoreOrdinaryBodyPlan
) -> CoreGeneratedPlan {
    bind_generated_plan(
        anchor, CoreGeneratedPlanValue::GeneratedDefaultSpecialization(value))
}
pub fn core_generated_derived_eq(
    anchor: CoreTypeFactRef, value: CoreOrdinaryBodyPlan
) -> CoreGeneratedPlan {
    bind_generated_plan(anchor, CoreGeneratedPlanValue::GeneratedDerivedEq(value))
}
pub fn core_generated_derived_ne(
    anchor: CoreTypeFactRef, value: CoreOrdinaryBodyPlan
) -> CoreGeneratedPlan {
    bind_generated_plan(anchor, CoreGeneratedPlanValue::GeneratedDerivedNe(value))
}
pub fn core_generated_derived_hash(
    anchor: CoreTypeFactRef, value: CoreOrdinaryBodyPlan
) -> CoreGeneratedPlan {
    bind_generated_plan(anchor, CoreGeneratedPlanValue::GeneratedDerivedHash(value))
}
pub fn core_generated_struct_clone(
    anchor: CoreTypeFactRef, value: CoreStructClonePlan
) -> CoreGeneratedPlan {
    bind_generated_plan(anchor, CoreGeneratedPlanValue::GeneratedStructClone(value))
}
pub fn core_generated_enum_clone(
    anchor: CoreTypeFactRef, value: CoreEnumClonePlan
) -> CoreGeneratedPlan {
    bind_generated_plan(anchor, CoreGeneratedPlanValue::GeneratedEnumClone(value))
}
pub fn core_generated_derived_ord(
    anchor: CoreTypeFactRef, value: CoreOrdinaryBodyPlan
) -> CoreGeneratedPlan {
    bind_generated_plan(anchor, CoreGeneratedPlanValue::GeneratedDerivedOrd(value))
}
pub fn core_generated_derived_debug(
    anchor: CoreTypeFactRef, value: CoreOrdinaryBodyPlan
) -> CoreGeneratedPlan {
    bind_generated_plan(anchor, CoreGeneratedPlanValue::GeneratedDerivedDebug(value))
}
pub fn core_generated_derived_json(
    anchor: CoreTypeFactRef, value: CoreOrdinaryBodyPlan
) -> CoreGeneratedPlan {
    bind_generated_plan(anchor, CoreGeneratedPlanValue::GeneratedDerivedJson(value))
}

fn type_facts_same(left: CoreTypeFactRef, right: CoreTypeFactRef) -> Bool {
    core_type_fact_same(left, right)
}

pub struct CoreCallableFact {
    module_key: Str,
    reference: ExecutableRef,
    origin: OriginRef,
    parameter_types: List<CoreTypeFactRef>,
    parameter_slots: List<SlotRef>,
    result_type: CoreTypeFactRef,
    mode: FlowCallableMode,
    semantic_contract: CoreCallContractFact,
    evidence_requirements: List<SymbolRef>
}
pub fn make_core_callable_fact(
    reference: ExecutableRef, origin: OriginRef,
    parameter_types: List<CoreTypeFactRef>, parameter_slots: List<SlotRef>,
    result_type: CoreTypeFactRef, mode: FlowCallableMode,
    semantic_contract: CoreCallContractFact,
    evidence_requirements: List<SymbolRef>
) -> CoreCallableFact {
    let module_key = core_type_fact_module_key(result_type)
    if semantic_contract.module_key != module_key ||
       parameter_types.len() != semantic_contract.parameter_types.len() ||
       !type_facts_same(result_type, semantic_contract.result_type) {
        panic("Core assembly: callable fact signature contract differs")
    }
    let mut index = 0
    while index < parameter_types.len() {
        let ty = parameter_types.get(index).unwrap()
        require_type_fact_module(ty, module_key)
        if !type_facts_same(
                ty, semantic_contract.parameter_types.get(index).unwrap()) {
            panic("Core assembly: callable fact parameter contract differs")
        }
        index = index + 1
    }
    CoreCallableFact {
        module_key: module_key, reference: reference, origin: origin,
        parameter_types: parameter_types.map(fn(value) { value }),
        parameter_slots: parameter_slots.map(fn(value) { value }),
        result_type: result_type, mode: mode,
        semantic_contract: semantic_contract,
        evidence_requirements: evidence_requirements.map(fn(value) { value })
    }
}
fn core_callable_fact_reference(value: CoreCallableFact) -> ExecutableRef {
    value.reference
}
fn materialize_callable_fact(
    value: CoreCallableFact, module_key: Str
) -> CoreCallableContract {
    if value.module_key != module_key {
        panic("Core assembly: callable fact belongs to another recorder")
    }
    make_core_callable_contract(
        value.reference, value.origin,
        value.parameter_types.map(fn(ty) {
            local_core_type_ref(ty, module_key)
        }),
        value.parameter_slots,
        local_core_type_ref(value.result_type, module_key), value.mode,
        materialize_call_contract_fact(value.semantic_contract, module_key),
        value.evidence_requirements)
}

pub struct CoreAssocBindingFact {
    member: SymbolRef,
    ty: CoreTypeFactRef
}
pub fn make_core_assoc_binding_fact(
    member: SymbolRef, ty: CoreTypeFactRef
) -> CoreAssocBindingFact {
    CoreAssocBindingFact { member: member, ty: ty }
}
pub struct CoreImplFact {
    module_key: Str,
    owner: ImplOwnerRef,
    methods: List<ImplMethodRef>,
    assoc_bindings: List<CoreAssocBindingFact>,
    obligations: List<CoreObligationBinding>
}
pub fn make_core_impl_fact(
    anchor: CoreTypeFactRef, owner: ImplOwnerRef,
    methods: List<ImplMethodRef>,
    assoc_bindings: List<CoreAssocBindingFact>,
    obligations: List<CoreObligationBinding>
) -> CoreImplFact {
    for binding in assoc_bindings {
        require_type_fact_module(binding.ty, core_type_fact_module_key(anchor))
    }
    CoreImplFact {
        module_key: core_type_fact_module_key(anchor), owner: owner,
        methods: methods.map(fn(value) { value }),
        assoc_bindings: assoc_bindings.map(fn(value) { value }),
        obligations: obligations.map(fn(value) { value })
    }
}
fn core_impl_fact_owner(value: CoreImplFact) -> ImplOwnerRef { value.owner }
fn materialize_impl_fact(
    value: CoreImplFact, module_key: Str
) -> CoreImplMetadata {
    if value.module_key != module_key {
        panic("Core assembly: impl fact belongs to another recorder")
    }
    make_core_impl_metadata(
        value.owner, value.methods,
        value.assoc_bindings.map(fn(binding) {
            make_core_assoc_binding(
                binding.member, local_core_type_ref(binding.ty, module_key))
        }),
        value.obligations)
}

pub struct CoreDelegatePlanFact {
    module_key: Str,
    plan: DelegateTypedPlan
}
pub fn make_core_delegate_plan_fact(
    anchor: CoreTypeFactRef, plan: DelegateTypedPlan
) -> CoreDelegatePlanFact {
    if core_type_ref_module_key(delegate_typed_plan_outer_type(plan)) !=
            some(core_type_fact_module_key(anchor)) ||
       core_type_ref_module_key(delegate_typed_plan_field_type(plan)) !=
            some(core_type_fact_module_key(anchor)) {
        panic("Core assembly: delegate plan has an unowned type domain")
    }
    let (metadata, bodies) = elaborate_delegate_to_core(plan)
    validate_core_impl_type_domain(
        metadata, delegate_typed_plan_type_count(plan),
        core_type_fact_module_key(anchor))
    for body in bodies {
        validate_core_body_type_domain(
            body, core_type_fact_module_key(anchor))
    }
    CoreDelegatePlanFact {
        module_key: core_type_fact_module_key(anchor), plan: plan
    }
}

pub struct CoreAssemblyRecorder {
    module_key: Str,
    module_order: Int,
    type_allocator: CoreTypeFactAllocator,
    type_refs: List<CoreTypeFactRef>,
    type_specs: List<CoreTypeSpec?>,
    callables: List<CoreCallableFact>,
    impls: List<CoreImplFact>,
    inventory_entries: List<ExecutableEntry>,
    manifests: List<BinderManifest>,
    source_bodies: List<CoreSourceBodyInput>,
    generated: List<CoreGeneratedPlan>,
    delegates: List<CoreDelegatePlanFact>,
    frozen: Bool
}

pub fn new_core_assembly_recorder(
    module_key: Str, module_order: Int
) -> CoreAssemblyRecorder {
    if module_key == "" || module_order < 0 {
        panic("Core assembly: invalid exact module key/order")
    }
    CoreAssemblyRecorder {
        module_key: module_key, module_order: module_order,
        type_allocator: new_core_type_fact_allocator(module_key),
        type_refs: [], type_specs: [], callables: [], impls: [],
        inventory_entries: [],
        manifests: [], source_bodies: [], generated: [], delegates: [],
        frozen: false
    }
}

fn require_recorder_open(value: CoreAssemblyRecorder) {
    if value.frozen { panic("Core assembly: recorder is frozen") }
}

pub fn reserve_core_type_fact(
    mut recorder: CoreAssemblyRecorder
) -> CoreTypeFactRef {
    require_recorder_open(recorder)
    let mut allocator = recorder.type_allocator
    let reference = reserve_core_type_fact_ref(allocator)
    recorder.type_allocator = allocator
    if core_type_fact_ordinal(reference) != recorder.type_specs.len() {
        panic("Core assembly: type allocator/spec census differs")
    }
    recorder.type_refs.push(reference)
    recorder.type_specs.push(none)
    reference
}
fn require_reserved_type_fact(
    recorder: CoreAssemblyRecorder, reference: CoreTypeFactRef
) {
    require_type_fact_module(reference, recorder.module_key)
    let ordinal = core_type_fact_ordinal(reference)
    if ordinal < 0 || ordinal >= recorder.type_specs.len() {
        panic("Core assembly: type dependency was not reserved by this recorder")
    }
}
fn validate_resource_target_spec_owner(
    recorder: CoreAssemblyRecorder,
    value: CoreResourceDependencyTargetSpec
) {
    match value.value {
        CoreResourceDependencyTargetSpecValue::ConcreteTypeTargetSpec(ty) =>
            require_reserved_type_fact(recorder, ty),
        _ => {}
    }
}
fn validate_resource_edge_spec_owner(
    recorder: CoreAssemblyRecorder, value: CoreResourceDependencyEdgeSpec
) {
    require_reserved_type_fact(recorder, value.child)
    validate_resource_target_spec_owner(recorder, value.target)
}
fn validate_type_spec_owner(
    recorder: CoreAssemblyRecorder, value: CoreTypeSpec
) {
    match value.value {
        CoreTypeSpecValue::AtomicTypeSpec(_) |
        CoreTypeSpecValue::ParameterTypeSpec(_) => {},
        CoreTypeSpecValue::NominalTypeSpec {
            arguments, fields, resource_edges, ..
        } => {
            for ty in arguments { require_reserved_type_fact(recorder, ty) }
            for field in fields {
                require_reserved_type_fact(recorder, field.ty)
            }
            for edge in resource_edges {
                validate_resource_edge_spec_owner(recorder, edge)
            }
        },
        CoreTypeSpecValue::ExternTypeSpec {
            arguments, resource_edges, ..
        } => {
            for ty in arguments { require_reserved_type_fact(recorder, ty) }
            for edge in resource_edges {
                validate_resource_edge_spec_owner(recorder, edge)
            }
        },
        CoreTypeSpecValue::TupleTypeSpec {
            elements, resource_edges, ..
        } => {
            for ty in elements { require_reserved_type_fact(recorder, ty) }
            for edge in resource_edges {
                validate_resource_edge_spec_owner(recorder, edge)
            }
        },
        CoreTypeSpecValue::RecordTypeSpec {
            fields, resource_edges, ..
        } => {
            for field in fields {
                require_reserved_type_fact(recorder, field.ty)
            }
            for edge in resource_edges {
                validate_resource_edge_spec_owner(recorder, edge)
            }
        },
        CoreTypeSpecValue::CallableTypeSpec { parameters, result } => {
            for ty in parameters { require_reserved_type_fact(recorder, ty) }
            require_reserved_type_fact(recorder, result)
        },
        CoreTypeSpecValue::PtrTypeSpec(pointee) =>
            require_reserved_type_fact(recorder, pointee)
    }
}
fn define_core_type_fact(
    mut recorder: CoreAssemblyRecorder, reference: CoreTypeFactRef,
    spec: CoreTypeSpec
) {
    require_recorder_open(recorder)
    require_type_fact_module(reference, recorder.module_key)
    let ordinal = core_type_fact_ordinal(reference)
    if ordinal < 0 || ordinal >= recorder.type_specs.len() {
        panic("Core assembly: type fact was not reserved by this recorder")
    }
    if recorder.type_specs.get(ordinal).unwrap().is_some() {
        panic("Core assembly: type fact was defined twice")
    }
    validate_type_spec_owner(recorder, spec)
    // Materialization validates exact payload shape.  A reserved but
    // not-yet-defined recursive child is allowed here.
    let _ = materialize_type_spec(spec, reference, recorder.module_key)
    recorder.type_specs.set(ordinal, some(spec))
}
pub fn define_core_atomic_type_fact(
    mut recorder: CoreAssemblyRecorder, reference: CoreTypeFactRef,
    kind: FlowTypeKind
) {
    define_core_type_fact(
        recorder, reference,
        CoreTypeSpec { value: CoreTypeSpecValue::AtomicTypeSpec(kind) })
}
pub fn define_core_parameter_type_fact(
    mut recorder: CoreAssemblyRecorder, reference: CoreTypeFactRef,
    parameter: FlowGenericParamFact
) {
    define_core_type_fact(
        recorder, reference,
        CoreTypeSpec { value: CoreTypeSpecValue::ParameterTypeSpec(parameter) })
}
pub fn define_core_nominal_type_fact(
    mut recorder: CoreAssemblyRecorder, reference: CoreTypeFactRef,
    kind: FlowTypeKind, nominal: SymbolRef,
    arguments: List<CoreTypeFactRef>, fields: List<CoreNominalFieldSpec>,
    semantic_seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?,
    resource_parameters: List<FlowGenericParamFact>,
    resource_edges: List<CoreResourceDependencyEdgeSpec>
) {
    define_core_type_fact(recorder, reference, CoreTypeSpec {
        value: CoreTypeSpecValue::NominalTypeSpec {
            kind: kind, nominal: nominal,
            arguments: arguments.map(fn(value) { value }),
            fields: fields.map(fn(value) { value }),
            semantic_seed: semantic_seed, drop_contract: drop_contract,
            resource_parameters: resource_parameters.map(fn(value) { value }),
            resource_edges: resource_edges.map(fn(value) { value })
        }
    })
}
pub fn define_core_extern_type_fact(
    mut recorder: CoreAssemblyRecorder, reference: CoreTypeFactRef,
    nominal: SymbolRef, arguments: List<CoreTypeFactRef>,
    contract: FlowForeignContract,
    resource_edges: List<CoreResourceDependencyEdgeSpec>
) {
    define_core_type_fact(recorder, reference, CoreTypeSpec {
        value: CoreTypeSpecValue::ExternTypeSpec {
            nominal: nominal, arguments: arguments.map(fn(value) { value }),
            contract: contract,
            resource_edges: resource_edges.map(fn(value) { value })
        }
    })
}
pub fn define_core_tuple_type_fact(
    mut recorder: CoreAssemblyRecorder, reference: CoreTypeFactRef,
    elements: List<CoreTypeFactRef>, semantic_seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?,
    resource_parameters: List<FlowGenericParamFact>,
    resource_edges: List<CoreResourceDependencyEdgeSpec>
) {
    define_core_type_fact(recorder, reference, CoreTypeSpec {
        value: CoreTypeSpecValue::TupleTypeSpec {
            elements: elements.map(fn(value) { value }),
            semantic_seed: semantic_seed, drop_contract: drop_contract,
            resource_parameters: resource_parameters.map(fn(value) { value }),
            resource_edges: resource_edges.map(fn(value) { value })
        }
    })
}
pub fn define_core_record_type_fact(
    mut recorder: CoreAssemblyRecorder, reference: CoreTypeFactRef,
    fields: List<CoreNominalFieldSpec>,
    semantic_seed: FlowTypeSemanticSeed, drop_contract: FlowDropContract?,
    resource_parameters: List<FlowGenericParamFact>,
    resource_edges: List<CoreResourceDependencyEdgeSpec>
) {
    define_core_type_fact(recorder, reference, CoreTypeSpec {
        value: CoreTypeSpecValue::RecordTypeSpec {
            fields: fields.map(fn(value) { value }),
            semantic_seed: semantic_seed, drop_contract: drop_contract,
            resource_parameters: resource_parameters.map(fn(value) { value }),
            resource_edges: resource_edges.map(fn(value) { value })
        }
    })
}
pub fn define_core_callable_type_fact(
    mut recorder: CoreAssemblyRecorder, reference: CoreTypeFactRef,
    parameters: List<CoreTypeFactRef>, result: CoreTypeFactRef
) {
    define_core_type_fact(recorder, reference, CoreTypeSpec {
        value: CoreTypeSpecValue::CallableTypeSpec {
            parameters: parameters.map(fn(value) { value }), result: result
        }
    })
}
pub fn define_core_ptr_type_fact(
    mut recorder: CoreAssemblyRecorder, reference: CoreTypeFactRef,
    pointee: CoreTypeFactRef
) {
    define_core_type_fact(
        recorder, reference,
        CoreTypeSpec { value: CoreTypeSpecValue::PtrTypeSpec(pointee) })
}

pub fn record_core_callable(
    mut recorder: CoreAssemblyRecorder, value: CoreCallableFact
) {
    require_recorder_open(recorder)
    if value.module_key != recorder.module_key {
        panic("Core assembly: callable belongs to another module recorder")
    }
    for existing in recorder.callables {
        if executable_ref_same(
                core_callable_fact_reference(existing),
                core_callable_fact_reference(value)) {
            panic("Core assembly: callable was recorded twice")
        }
    }
    recorder.callables.push(value)
}

pub fn record_core_impl(
    mut recorder: CoreAssemblyRecorder, value: CoreImplFact
) {
    require_recorder_open(recorder)
    if value.module_key != recorder.module_key {
        panic("Core assembly: impl belongs to another module recorder")
    }
    for existing in recorder.impls {
        if impl_owner_ref_same(
                core_impl_fact_owner(existing), core_impl_fact_owner(value)) {
            panic("Core assembly: impl metadata was recorded twice")
        }
    }
    recorder.impls.push(value)
}

pub fn record_core_executable(
    mut recorder: CoreAssemblyRecorder, value: ExecutableEntry
) {
    require_recorder_open(recorder)
    for existing in recorder.inventory_entries {
        if executable_ref_same(
                executable_entry_reference(existing),
                executable_entry_reference(value)) {
            panic("Core assembly: executable was recorded twice")
        }
    }
    recorder.inventory_entries.push(value)
}

pub fn record_core_manifest(
    mut recorder: CoreAssemblyRecorder, value: BinderManifest
) {
    require_recorder_open(recorder)
    for existing in recorder.manifests {
        if executable_ref_same(
                binder_manifest_owner(existing), binder_manifest_owner(value)) {
            panic("Core assembly: binder manifest was recorded twice")
        }
    }
    recorder.manifests.push(value)
}

pub fn record_core_source_body(
    mut recorder: CoreAssemblyRecorder, value: CoreSourceBodyInput
) {
    require_recorder_open(recorder)
    if value.module_key != recorder.module_key {
        panic("Core assembly: source body belongs to another module recorder")
    }
    if !executable_ref_same(
            value.executable, binder_manifest_owner(value.manifest)) {
        panic("Core assembly: source body executable/manifest differs")
    }
    if value.scopes.len() == 0 || value.expr_facts.len() == 0 ||
       value.block_facts.len() == 0 {
        panic("Core assembly: source body frozen facts are incomplete")
    }
    for existing in recorder.source_bodies {
        if executable_ref_same(existing.executable, value.executable) {
            panic("Core assembly: source body was recorded twice")
        }
    }
    recorder.source_bodies.push(value)
}

pub fn record_core_generated(
    mut recorder: CoreAssemblyRecorder, value: CoreGeneratedPlan
) {
    require_recorder_open(recorder)
    if value.module_key != recorder.module_key {
        panic("Core assembly: generated plan belongs to another recorder")
    }
    recorder.generated.push(value)
}

pub fn record_core_delegate(
    mut recorder: CoreAssemblyRecorder, value: CoreDelegatePlanFact
) {
    require_recorder_open(recorder)
    if value.module_key != recorder.module_key {
        panic("Core assembly: delegate plan belongs to another recorder")
    }
    recorder.delegates.push(value)
}

pub struct FrozenCoreAssemblyFacts {
    module_key: Str,
    module_order: Int,
    type_refs: List<CoreTypeFactRef>,
    type_nodes: List<FlowTypeNode>,
    callables: List<CoreCallableContract>,
    impls: List<CoreImplMetadata>,
    inventory_entries: List<ExecutableEntry>,
    manifests: List<BinderManifest>,
    source_bodies: List<CoreSourceBodyInput>,
    generated: List<CoreGeneratedPlan>,
    delegates: List<DelegateTypedPlan>
}

fn recorded_body_refs(recorder: CoreAssemblyRecorder) -> List<ExecutableRef> {
    let mut result: List<ExecutableRef> = []
    for body in recorder.source_bodies { result.push(body.executable) }
    for generated in recorder.generated {
        result.push(core_body_reference(materialize_generated(generated)))
    }
    for delegate in recorder.delegates {
        let (_metadata, bodies) = elaborate_delegate_to_core(delegate.plan)
        for body in bodies { result.push(core_body_reference(body)) }
    }
    result
}

fn materialize_recorder_type_nodes(
    recorder: CoreAssemblyRecorder
) -> List<FlowTypeNode> {
    let mut result: List<FlowTypeNode> = []
    let mut ordinal = 0
    while ordinal < recorder.type_specs.len() {
        let spec = match recorder.type_specs.get(ordinal).unwrap() {
            some(value) => value,
            none => panic("Core assembly: reserved type fact was never defined")
        }
        let reference = recorder.type_refs.get(ordinal).unwrap_or_else(fn() {
            panic("Core assembly: reserved type reference census is short")
        })
        result.push(materialize_type_spec(
            spec, reference, recorder.module_key))
        ordinal = ordinal + 1
    }
    // This rejects unresolved refs, malformed recursion/resource edges, and
    // any duplicate/invalid local ordinal before the project interner runs.
    let _ = make_core_type_graph(result)
    result
}

pub fn snapshot_core_recorder_type_graph(
    recorder: CoreAssemblyRecorder
) -> CoreTypeGraph {
    require_recorder_open(recorder)
    make_module_core_type_graph(
        recorder.module_key, materialize_recorder_type_nodes(recorder))
}

pub fn freeze_core_assembly_facts(
    mut recorder: CoreAssemblyRecorder
) -> FrozenCoreAssemblyFacts {
    require_recorder_open(recorder)
    recorder.frozen = true
    let type_nodes = materialize_recorder_type_nodes(recorder)
    if recorder.inventory_entries.len() != recorder.callables.len() ||
       recorder.manifests.len() != recorder.callables.len() {
        panic("Core assembly: executable/callable/manifest census differs")
    }
    let callables = recorder.callables.map(fn(value) {
        materialize_callable_fact(value, recorder.module_key)
    })
    let impls = recorder.impls.map(fn(value) {
        materialize_impl_fact(value, recorder.module_key)
    })
    let body_refs = recorded_body_refs(recorder)
    let mut index = 0
    while index < recorder.inventory_entries.len() {
        let entry = recorder.inventory_entries.get(index).unwrap()
        let reference = executable_entry_reference(entry)
        if !executable_ref_same(
                reference,
                core_callable_reference(callables.get(index).unwrap())) ||
           !executable_ref_same(
                reference,
                binder_manifest_owner(recorder.manifests.get(index).unwrap())) {
            panic("Core assembly: executable/callable/manifest order differs")
        }
        let mut body_count = 0
        for body_ref in body_refs {
            if executable_ref_same(reference, body_ref) {
                body_count = body_count + 1
            }
        }
        let concrete = executable_contract_mode_same(
            executable_contract_mode(executable_entry_contract(entry)),
            executable_contract_mode_concrete_body())
        if (concrete && body_count != 1) || (!concrete && body_count != 0) {
            panic("Core assembly: executable/body bijection differs")
        }
        index = index + 1
    }
    for body_ref in body_refs {
        let mut registered = 0
        for entry in recorder.inventory_entries {
            if executable_ref_same(
                    executable_entry_reference(entry), body_ref) {
                registered = registered + 1
            }
        }
        if registered != 1 {
            panic("Core assembly: recorded body has no unique executable")
        }
    }
    FrozenCoreAssemblyFacts {
        module_key: recorder.module_key,
        module_order: recorder.module_order,
        type_refs: recorder.type_refs.map(fn(value) { value }),
        type_nodes: type_nodes.map(fn(value) { value }),
        callables: copy_core_callables(callables),
        impls: copy_core_impl_metadata(impls),
        inventory_entries: recorder.inventory_entries.map(fn(value) { value }),
        manifests: recorder.manifests.map(fn(value) { value }),
        source_bodies: recorder.source_bodies.map(fn(value) { value }),
        generated: recorder.generated.map(fn(value) { value }),
        delegates: recorder.delegates.map(fn(value) { value.plan })
    }
}

struct BodyCursor {
    input: CoreSourceBodyInput,
    expr_index: Int, stmt_index: Int, block_index: Int, pattern_index: Int
}

struct MaterializedCoreStringLiteralFact {
    value: Str, slot: SlotRef, ty: CoreTypeRef, origin: OriginRef
}
enum CoreExprAdapterValue {
    PlainAdapter,
    ReadAdapter(SlotRef),
    DirectCallableAdapter(ExecutableRef),
    PrimitiveAdapter(CorePrimitiveOp),
    CallAdapter { callee: CoreCalleeRef, evidence: List<CoreEvidenceRef> },
    MethodAdapter { callee: CoreCalleeRef, method: MethodCallRef,
                    receiver: SlotRef,
                    evidence: List<CoreEvidenceRef> },
    ProjectAdapter { field: CoreFieldRef, partial: Bool },
    ConstructAdapter { constructor: CoreConstructorRef,
                       fields: List<CoreFieldRef> },
    EffectAdapter { operation: EffectOperationRef,
                    evidence: List<CoreEvidenceRef> },
    SystemAdapter(SystemHostCallableRef),
    DictAdapter { constructor: ExecutableRef,
                  evidence: List<CoreEvidenceRef> },
    LambdaAdapter { executable: ExecutableRef, manifest: BinderManifest,
                    captures: List<CoreCapture> },
    HandleAdapter { handlers: List<CoreHandlerEntry> },
    StringInterpAdapter {
        callee: CoreCalleeRef, evidence: List<CoreEvidenceRef>,
        literals: List<MaterializedCoreStringLiteralFact>
    }
}
struct MaterializedCoreExprAdapter { value: CoreExprAdapterValue }
struct MaterializedCoreExprFact {
    source_type: Type, source_effects: EffectRow,
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, adapter: MaterializedCoreExprAdapter
}
fn materialize_expr_adapter(
    value: CoreExprAdapter, module_key: Str
) -> MaterializedCoreExprAdapter {
    let payload = match value.value {
        RecordedCoreExprAdapterValue::PlainAdapter =>
            CoreExprAdapterValue::PlainAdapter,
        RecordedCoreExprAdapterValue::ReadAdapter(slot) =>
            CoreExprAdapterValue::ReadAdapter(slot),
        RecordedCoreExprAdapterValue::DirectCallableAdapter(executable) =>
            CoreExprAdapterValue::DirectCallableAdapter(executable),
        RecordedCoreExprAdapterValue::PrimitiveAdapter(operation) =>
            CoreExprAdapterValue::PrimitiveAdapter(operation),
        RecordedCoreExprAdapterValue::CallAdapter { callee, evidence } =>
            CoreExprAdapterValue::CallAdapter {
                callee: materialize_callee_fact(callee, module_key),
                evidence: copy_evidence(evidence)
            },
        RecordedCoreExprAdapterValue::MethodAdapter {
            callee, method, receiver, evidence
        } => CoreExprAdapterValue::MethodAdapter {
            callee: materialize_callee_fact(callee, module_key),
            method: method, receiver: receiver, evidence: copy_evidence(evidence)
        },
        RecordedCoreExprAdapterValue::ProjectAdapter { field, partial } =>
            CoreExprAdapterValue::ProjectAdapter {
                field: field, partial: partial
            },
        RecordedCoreExprAdapterValue::ConstructAdapter { constructor, fields } =>
            CoreExprAdapterValue::ConstructAdapter {
                constructor: constructor, fields: copy_fields(fields)
            },
        RecordedCoreExprAdapterValue::EffectAdapter { operation, evidence } =>
            CoreExprAdapterValue::EffectAdapter {
                operation: operation, evidence: copy_evidence(evidence)
            },
        RecordedCoreExprAdapterValue::SystemAdapter(host) =>
            CoreExprAdapterValue::SystemAdapter(host),
        RecordedCoreExprAdapterValue::DictAdapter { constructor, evidence } =>
            CoreExprAdapterValue::DictAdapter {
                constructor: constructor, evidence: copy_evidence(evidence)
            },
        RecordedCoreExprAdapterValue::LambdaAdapter {
            executable, manifest, captures
        } => CoreExprAdapterValue::LambdaAdapter {
            executable: executable, manifest: manifest,
            captures: copy_captures(captures)
        },
        RecordedCoreExprAdapterValue::HandleAdapter { handlers } =>
            CoreExprAdapterValue::HandleAdapter {
                handlers: handlers.map(fn(item) { item })
            },
        RecordedCoreExprAdapterValue::StringInterpAdapter {
            callee, evidence, literals
        } => CoreExprAdapterValue::StringInterpAdapter {
            callee: materialize_callee_fact(callee, module_key),
            evidence: copy_evidence(evidence),
            literals: literals.map(fn(item) {
                MaterializedCoreStringLiteralFact {
                    value: item.value, slot: item.slot,
                    ty: local_core_type_ref(item.ty, module_key),
                    origin: item.origin
                }
            })
        }
    }
    MaterializedCoreExprAdapter { value: payload }
}

struct MaterializedCoreDestructureBinding {
    base: SlotRef, field: CoreFieldRef,
    target: SlotRef, ty: CoreTypeRef, origin: OriginRef
}
struct MaterializedCoreForInPlan {
    iterator_slot: SlotRef, iterator_type: CoreTypeRef,
    iter_callee: CoreCalleeRef, iter_method: MethodCallRef,
    iter_effects: CoreEffectSet, iter_evidence: List<CoreEvidenceRef>,
    iter_origin: OriginRef,
    condition_slot: SlotRef, condition_type: CoreTypeRef,
    has_next_callee: CoreCalleeRef, has_next_method: MethodCallRef,
    has_next_effects: CoreEffectSet,
    has_next_evidence: List<CoreEvidenceRef>, has_next_origin: OriginRef,
    item_slot: SlotRef, item_type: CoreTypeRef,
    next_callee: CoreCalleeRef, next_method: MethodCallRef,
    next_effects: CoreEffectSet, next_evidence: List<CoreEvidenceRef>,
    next_origin: OriginRef, binding_slot: SlotRef,
    destructure: List<MaterializedCoreDestructureBinding>
}
fn materialize_destructure_bindings(
    values: List<CoreDestructureBinding>, module_key: Str
) -> List<MaterializedCoreDestructureBinding> {
    values.map(fn(value) {
        MaterializedCoreDestructureBinding {
            base: value.base, field: value.field, target: value.target,
            ty: local_core_type_ref(value.ty, module_key), origin: value.origin
        }
    })
}
fn materialize_for_in_plan(
    value: CoreForInPlan, module_key: Str
) -> MaterializedCoreForInPlan {
    MaterializedCoreForInPlan {
        iterator_slot: value.iterator_slot,
        iterator_type: local_core_type_ref(value.iterator_type, module_key),
        iter_callee: materialize_callee_fact(value.iter_callee, module_key),
        iter_method: value.iter_method,
        iter_effects: materialize_effect_set_fact(
            value.iter_effects, module_key),
        iter_evidence: copy_evidence(value.iter_evidence),
        iter_origin: value.iter_origin,
        condition_slot: value.condition_slot,
        condition_type: local_core_type_ref(value.condition_type, module_key),
        has_next_callee: materialize_callee_fact(
            value.has_next_callee, module_key),
        has_next_method: value.has_next_method,
        has_next_effects: materialize_effect_set_fact(
            value.has_next_effects, module_key),
        has_next_evidence: copy_evidence(value.has_next_evidence),
        has_next_origin: value.has_next_origin,
        item_slot: value.item_slot,
        item_type: local_core_type_ref(value.item_type, module_key),
        next_callee: materialize_callee_fact(value.next_callee, module_key),
        next_method: value.next_method,
        next_effects: materialize_effect_set_fact(
            value.next_effects, module_key),
        next_evidence: copy_evidence(value.next_evidence),
        next_origin: value.next_origin, binding_slot: value.binding_slot,
        destructure: materialize_destructure_bindings(
            value.destructure, module_key)
    }
}
struct MaterializedCoreIfLetPlan {
    result_slot: SlotRef, result_type: CoreTypeRef,
    scrutinee_type: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef
}
fn materialize_if_let_plan(
    value: CoreIfLetPlan, module_key: Str
) -> MaterializedCoreIfLetPlan {
    MaterializedCoreIfLetPlan {
        result_slot: value.result_slot,
        result_type: local_core_type_ref(value.result_type, module_key),
        scrutinee_type: local_core_type_ref(value.scrutinee_type, module_key),
        effects: materialize_effect_set_fact(value.effects, module_key),
        origin: value.origin
    }
}
struct MaterializedCoreStmtFact {
    origin: OriginRef, target: CorePlaceRef?,
    for_in: MaterializedCoreForInPlan?,
    destructure: List<MaterializedCoreDestructureBinding>?,
    if_let: MaterializedCoreIfLetPlan?
}
struct MaterializedCorePatternFact {
    ty: CoreTypeRef, value: CorePatternAdapterValue
}
fn effect_rows_same(left: EffectRow, right: EffectRow) -> Bool {
    if left.tail != right.tail || left.effects.len() != right.effects.len() {
        return false
    }
    let mut index = 0
    while index < left.effects.len() {
        if !effects_equal(left.effects.get(index).unwrap(),
                          right.effects.get(index).unwrap()) { return false }
        index = index + 1
    }
    true
}
fn next_expr_fact(
    mut cursor: BodyCursor, expr: HExpr
) -> MaterializedCoreExprFact {
    let fact = match cursor.input.expr_facts.get(cursor.expr_index) {
        some(value) => value,
        none => panic("Core assembly: expression fact census is short")
    }
    cursor.expr_index = cursor.expr_index + 1
    if !types_equal(hexpr_type(expr), fact.source_type) ||
       !effect_rows_same(hexpr_effects(expr), fact.source_effects) {
        panic("Core assembly: HIR expression type/effect fact drifted")
    }
    MaterializedCoreExprFact {
        source_type: fact.source_type, source_effects: fact.source_effects,
        result: fact.result,
        ty: local_core_type_ref(fact.ty, cursor.input.module_key),
        effects: materialize_effect_set_fact(
            fact.effects, cursor.input.module_key),
        origin: fact.origin,
        adapter: materialize_expr_adapter(
            fact.adapter, cursor.input.module_key)
    }
}
fn next_stmt_fact(mut cursor: BodyCursor) -> MaterializedCoreStmtFact {
    let fact = cursor.input.stmt_facts.get(cursor.stmt_index).unwrap_or_else(fn() {
        panic("Core assembly: statement fact census is short")
    })
    cursor.stmt_index = cursor.stmt_index + 1
    MaterializedCoreStmtFact {
        origin: fact.origin,
        target: match fact.target {
            some(value) => some(materialize_place_fact(
                value, cursor.input.module_key)),
            none => none
        },
        for_in: match fact.for_in {
            some(value) => some(materialize_for_in_plan(
                value, cursor.input.module_key)),
            none => none
        },
        destructure: match fact.destructure {
            some(values) => some(materialize_destructure_bindings(
                values, cursor.input.module_key)),
            none => none
        },
        if_let: match fact.if_let {
            some(value) => some(materialize_if_let_plan(
                value, cursor.input.module_key)),
            none => none
        }
    }
}
fn next_block_fact(mut cursor: BodyCursor) -> CoreBlockFact {
    let fact = cursor.input.block_facts.get(cursor.block_index).unwrap_or_else(fn() {
        panic("Core assembly: block fact census is short")
    })
    cursor.block_index = cursor.block_index + 1
    fact
}
fn next_pattern_fact(mut cursor: BodyCursor) -> MaterializedCorePatternFact {
    let fact = cursor.input.pattern_facts.get(cursor.pattern_index).unwrap_or_else(fn() {
        panic("Core assembly: pattern fact census is short")
    })
    cursor.pattern_index = cursor.pattern_index + 1
    MaterializedCorePatternFact {
        ty: local_core_type_ref(fact.ty, cursor.input.module_key),
        value: fact.value
    }
}

fn lower_literal_pattern(value: LiteralValue) -> CoreLiteral {
    match value {
        LiteralValue::IntVal(item) => make_core_int_literal(item),
        LiteralValue::FloatVal(item) => make_core_float_literal(item),
        LiteralValue::StrVal(item) => make_core_str_literal(item),
        LiteralValue::BoolVal(item) => make_core_bool_literal(item)
    }
}

fn lower_pattern(mut cursor: BodyCursor, pattern: Pattern) -> CorePattern {
    let fact = next_pattern_fact(cursor)
    match pattern {
        Pattern::Wildcard { .. } => match fact.value {
            CorePatternAdapterValue::PatternWildcard =>
                make_core_wildcard_pattern(fact.ty),
            _ => panic("Core assembly: wildcard pattern fact differs")
        },
        Pattern::Binding { .. } => match fact.value {
            CorePatternAdapterValue::PatternBinding(slot) =>
                make_core_binding_pattern(fact.ty, slot),
            _ => panic("Core assembly: binding pattern fact differs")
        },
        Pattern::Literal { value, .. } => match fact.value {
            CorePatternAdapterValue::PatternLiteral =>
                make_core_literal_pattern(fact.ty, lower_literal_pattern(value)),
            _ => panic("Core assembly: literal pattern fact differs")
        },
        Pattern::TuplePattern { elements, .. } => match fact.value {
            CorePatternAdapterValue::PatternTuple =>
                make_core_tuple_pattern(fact.ty, elements.map(fn(item) {
                    lower_pattern(cursor, item)
                })),
            _ => panic("Core assembly: tuple pattern fact differs")
        },
        Pattern::Constructor { fields, .. } => match fact.value {
            CorePatternAdapterValue::PatternVariant {
                variant, fields: field_refs
            } => {
                if field_refs.len() != fields.len() {
                    panic("Core assembly: variant pattern field census differs")
                }
                let mut index = 0
                let lowered = fields.map(fn(item) {
                    let field = make_core_pattern_field(
                        field_refs.get(index).unwrap(),
                        lower_pattern(cursor, item))
                    index = index + 1
                    field
                })
                make_core_variant_pattern(fact.ty, variant, lowered)
            },
            _ => panic("Core assembly: constructor pattern lacks VariantRef")
        },
        Pattern::NamedConstructor { fields, rest, .. } => {
            if rest { panic("Core assembly: partial named pattern crossed Core") }
            match fact.value {
                CorePatternAdapterValue::PatternStruct {
                    owner, fields: field_refs
                } => {
                    if field_refs.len() != fields.len() {
                        panic("Core assembly: struct pattern field census differs")
                    }
                    let mut index = 0
                    let lowered = fields.map(fn(item) {
                        let field = make_core_pattern_field(
                            field_refs.get(index).unwrap(),
                            lower_pattern(cursor, item.pattern))
                        index = index + 1
                        field
                    })
                    make_core_struct_pattern(fact.ty, owner, lowered)
                },
                CorePatternAdapterValue::PatternVariant {
                    variant, fields: field_refs
                } => {
                    if field_refs.len() != fields.len() {
                        panic("Core assembly: named variant field census differs")
                    }
                    let mut index = 0
                    let lowered = fields.map(fn(item) {
                        let field = make_core_pattern_field(
                            field_refs.get(index).unwrap(),
                            lower_pattern(cursor, item.pattern))
                        index = index + 1
                        field
                    })
                    make_core_variant_pattern(fact.ty, variant, lowered)
                },
                _ => panic("Core assembly: named pattern exact owner is absent")
            }
        },
        Pattern::OrPattern { .. } =>
            panic("Core assembly: OrPattern crossed semantic elaboration closure")
    }
}

struct LoweredExpr { prefix: List<CoreStmt>, value: CoreExpr }
fn append_statements(mut target: List<CoreStmt>, values: List<CoreStmt>) {
    for value in values { target.push(value) }
}
fn materialize(mut prefix: List<CoreStmt>, value: LoweredExpr) -> SlotRef {
    append_statements(prefix, value.prefix)
    prefix.push(make_core_initialize_stmt(
        core_expr_result(value.value), value.value,
        core_expr_origin(value.value)))
    core_expr_result(value.value)
}

fn lower_expr(mut cursor: BodyCursor, expr: HExpr) -> LoweredExpr {
    let fact = next_expr_fact(cursor, expr)
    match expr {
        HExpr::IntLit { value, .. } => {
            match fact.adapter.value {
                CoreExprAdapterValue::PlainAdapter => {},
                _ => panic("Core assembly: Int literal adapter differs")
            }
            LoweredExpr { prefix: [], value: make_core_literal_expr(
                fact.result, fact.ty, fact.origin, make_core_int_literal(value)) }
        },
        HExpr::FloatLit { value, .. } => {
            match fact.adapter.value {
                CoreExprAdapterValue::PlainAdapter => {},
                _ => panic("Core assembly: Float literal adapter differs")
            }
            LoweredExpr { prefix: [], value: make_core_literal_expr(
                fact.result, fact.ty, fact.origin, make_core_float_literal(value)) }
        },
        HExpr::StrLit { value, .. } => {
            match fact.adapter.value {
                CoreExprAdapterValue::PlainAdapter => {},
                _ => panic("Core assembly: Str literal adapter differs")
            }
            LoweredExpr { prefix: [], value: make_core_literal_expr(
                fact.result, fact.ty, fact.origin, make_core_str_literal(value)) }
        },
        HExpr::BoolLit { value, .. } => {
            match fact.adapter.value {
                CoreExprAdapterValue::PlainAdapter => {},
                _ => panic("Core assembly: Bool literal adapter differs")
            }
            LoweredExpr { prefix: [], value: make_core_literal_expr(
                fact.result, fact.ty, fact.origin, make_core_bool_literal(value)) }
        },
        HExpr::Ident { .. } => match fact.adapter.value {
            CoreExprAdapterValue::ReadAdapter(source) => LoweredExpr {
                prefix: [], value: make_core_read_expr(
                    fact.result, fact.ty, fact.effects, fact.origin, source)
            },
            CoreExprAdapterValue::DirectCallableAdapter(executable) =>
                LoweredExpr { prefix: [], value: make_core_callable_value_expr(
                    fact.result, fact.ty, fact.origin, executable) },
            _ => panic("Core assembly: identifier has no exact SlotRef")
        },
        HExpr::BinOp { left, right, .. } => {
            let mut prefix: List<CoreStmt> = []
            let left_slot = materialize(prefix, lower_expr(cursor, left))
            let right_slot = materialize(prefix, lower_expr(cursor, right))
            let value = match fact.adapter.value {
                CoreExprAdapterValue::PrimitiveAdapter(operation) =>
                    make_core_primitive_expr(
                        fact.result, fact.ty, fact.effects, fact.origin,
                        operation, [left_slot, right_slot]),
                CoreExprAdapterValue::MethodAdapter {
                    callee, method, receiver, evidence
                } => {
                    if !slot_ref_same(receiver, left_slot) {
                        panic("Core assembly: binary method receiver differs")
                    }
                    make_core_method_call_expr(
                        fact.result, fact.ty, fact.effects, fact.origin,
                        callee, method, receiver, [right_slot], evidence)
                },
                _ => panic("Core assembly: binary semantic adapter is absent")
            }
            LoweredExpr { prefix: prefix, value: value }
        },
        HExpr::UnaryOp { operand, .. } => {
            let mut prefix: List<CoreStmt> = []
            let operand_slot = materialize(prefix, lower_expr(cursor, operand))
            let operation = match fact.adapter.value {
                CoreExprAdapterValue::PrimitiveAdapter(value) => value,
                _ => panic("Core assembly: unary primitive adapter is absent")
            }
            LoweredExpr { prefix: prefix, value: make_core_primitive_expr(
                fact.result, fact.ty, fact.effects, fact.origin,
                operation, [operand_slot]) }
        },
        HExpr::Call { callee, args, method_ref, .. } => {
            let mut prefix: List<CoreStmt> = []
            let mut arguments: List<SlotRef> = []
            let adapter = fact.adapter
            match adapter.value {
                CoreExprAdapterValue::MethodAdapter {
                    callee: exact_callee, method, receiver, evidence
                } => {
                    match method_ref {
                        some(source_method) => if !method_call_ref_same(
                                source_method, method) {
                            panic("Core assembly: MethodCallRef changed")
                        },
                        none => panic("Core assembly: method call lost MethodCallRef")
                    }
                    match callee {
                        HExpr::FieldAccess { receiver: source_receiver, .. } => {
                            let lowered_receiver = materialize(
                                prefix, lower_expr(cursor, source_receiver))
                            if !slot_ref_same(lowered_receiver, receiver) {
                                panic("Core assembly: method receiver slot differs")
                            }
                        },
                        _ => panic("Core assembly: method callee is not field access")
                    }
                    for arg in args {
                        arguments.push(materialize(prefix, lower_expr(cursor, arg)))
                    }
                    LoweredExpr { prefix: prefix, value: make_core_method_call_expr(
                        fact.result, fact.ty, fact.effects, fact.origin,
                        exact_callee, method, receiver, arguments, evidence) }
                },
                CoreExprAdapterValue::CallAdapter {
                    callee: exact_callee, evidence
                } => {
                    let _ = materialize(prefix, lower_expr(cursor, callee))
                    for arg in args {
                        arguments.push(materialize(prefix, lower_expr(cursor, arg)))
                    }
                    if method_ref.is_some() {
                        panic("Core assembly: method call used plain Call adapter")
                    }
                    LoweredExpr { prefix: prefix, value: make_core_call_expr(
                        fact.result, fact.ty, fact.effects, fact.origin,
                        exact_callee, arguments, evidence) }
                },
                CoreExprAdapterValue::SystemAdapter(host) => {
                    let _ = materialize(prefix, lower_expr(cursor, callee))
                    for arg in args {
                        arguments.push(materialize(prefix, lower_expr(cursor, arg)))
                    }
                    if method_ref.is_some() {
                        panic("Core assembly: system call carried MethodCallRef")
                    }
                    LoweredExpr { prefix: prefix, value: make_core_system_call_expr(
                        fact.result, fact.ty, fact.effects, fact.origin,
                        host, arguments) }
                },
                _ => panic("Core assembly: Call exact adapter is absent")
            }
        },
        HExpr::FieldAccess { receiver, access_kind, .. } => {
            let mut prefix: List<CoreStmt> = []
            let base = materialize(prefix, lower_expr(cursor, receiver))
            let (field, partial) = match fact.adapter.value {
                CoreExprAdapterValue::ProjectAdapter { field, partial } =>
                    (field, partial),
                _ => panic("Core assembly: field projection adapter is absent")
            }
            match access_kind {
                HFieldAccessKind::Method | HFieldAccessKind::ErrorRecovery =>
                    panic("Core assembly: unresolved field access crossed Core"),
                _ => {}
            }
            LoweredExpr { prefix: prefix, value: make_core_project_expr(
                fact.result, fact.ty, fact.effects, fact.origin,
                base, field, partial) }
        },
        HExpr::StructLit { fields, spread, .. } => {
            if spread.is_some() {
                panic("Core assembly: struct spread crossed semantic closure")
            }
            let (constructor, field_refs) = match fact.adapter.value {
                CoreExprAdapterValue::ConstructAdapter { constructor, fields } =>
                    (constructor, fields),
                _ => panic("Core assembly: struct constructor adapter is absent")
            }
            if fields.len() != field_refs.len() {
                panic("Core assembly: struct constructor field census differs")
            }
            let mut prefix: List<CoreStmt> = []
            let mut index = 0
            let values = fields.map(fn(field) {
                let slot = materialize(prefix, lower_expr(cursor, field.value))
                let result = make_core_field_value(
                    field_refs.get(index).unwrap(), slot)
                index = index + 1
                result
            })
            LoweredExpr { prefix: prefix, value: make_core_construct_expr(
                fact.result, fact.ty, fact.effects, fact.origin,
                constructor, values) }
        },
        HExpr::NamedVariantConstruct { fields, spread, variant_ref, .. } => {
            if spread.is_some() {
                panic("Core assembly: variant spread crossed semantic closure")
            }
            let (constructor, field_refs) = match fact.adapter.value {
                CoreExprAdapterValue::ConstructAdapter { constructor, fields } =>
                    (constructor, fields),
                _ => panic("Core assembly: variant constructor adapter is absent")
            }
            match core_constructor_variant(constructor) {
                exact_variant => if !variant_ref_same(
                        exact_variant, variant_ref) {
                    panic("Core assembly: variant constructor identity differs")
                }
            }
            if fields.len() != field_refs.len() {
                panic("Core assembly: variant field census differs")
            }
            let mut prefix: List<CoreStmt> = []
            let mut index = 0
            let values = fields.map(fn(field) {
                let slot = materialize(prefix, lower_expr(cursor, field.value))
                let result = make_core_field_value(
                    field_refs.get(index).unwrap(), slot)
                index = index + 1
                result
            })
            LoweredExpr { prefix: prefix, value: make_core_construct_expr(
                fact.result, fact.ty, fact.effects, fact.origin,
                constructor, values) }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            let mut prefix: List<CoreStmt> = []
            let scrutinee_slot = materialize(
                prefix, lower_expr(cursor, scrutinee))
            let mut lowered_arms: List<CoreMatchArm> = []
            for arm in arms {
                for lowered in lower_match_arm(cursor, arm) {
                    lowered_arms.push(lowered)
                }
            }
            match fact.adapter.value {
                CoreExprAdapterValue::PlainAdapter => {},
                _ => panic("Core assembly: Match carried semantic adapter")
            }
            LoweredExpr { prefix: prefix, value: make_core_match_expr(
                fact.result, fact.ty, fact.effects, fact.origin,
                scrutinee_slot, lowered_arms) }
        },
        HExpr::Block { stmts, tail, .. } => {
            match fact.adapter.value {
                CoreExprAdapterValue::PlainAdapter => {},
                _ => panic("Core assembly: Block carried semantic adapter")
            }
            let block = lower_block_parts(cursor, stmts, tail)
            LoweredExpr { prefix: [], value: make_core_block_expr(
                fact.result, fact.ty, fact.effects, fact.origin, block) }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            let mut prefix: List<CoreStmt> = []
            let condition_slot = materialize(
                prefix, lower_expr(cursor, condition))
            let then_block = lower_expr_block(cursor, then_branch)
            let else_block = match else_branch {
                some(value) => lower_expr_block(cursor, value),
                none => {
                    let block_fact = next_block_fact(cursor)
                    make_core_block([], none, block_fact.origin, block_fact.scope)
                }
            }
            match fact.adapter.value {
                CoreExprAdapterValue::PlainAdapter => {},
                _ => panic("Core assembly: If carried semantic adapter")
            }
            LoweredExpr { prefix: prefix, value: make_core_if_expr(
                fact.result, fact.ty, fact.effects, fact.origin,
                condition_slot, then_block, else_block) }
        },
        HExpr::TryCatch { body, arms, .. } => {
            let protected = lower_expr_block(cursor, body)
            let mut lowered_arms: List<CoreMatchArm> = []
            for arm in arms {
                for lowered in lower_match_arm(cursor, arm) {
                    lowered_arms.push(lowered)
                }
            }
            let error_slot = match fact.adapter.value {
                CoreExprAdapterValue::ReadAdapter(slot) => slot,
                _ => panic("Core assembly: catch error SlotRef is absent")
            }
            LoweredExpr { prefix: [], value: make_core_try_catch_expr(
                fact.result, fact.ty, fact.effects, fact.origin,
                protected, error_slot, lowered_arms) }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            let handled = lower_expr_block(cursor, body)
            let exact_handlers = match fact.adapter.value {
                CoreExprAdapterValue::HandleAdapter { handlers: values } => values,
                _ => panic("Core assembly: handler exact adapter is absent")
            }
            if handlers.len() != exact_handlers.len() {
                panic("Core assembly: handler census differs")
            }
            LoweredExpr { prefix: [], value: make_core_handle_expr(
                fact.result, fact.ty, fact.effects, fact.origin,
                handled, exact_handlers) }
        },
        HExpr::Lambda { .. } => match fact.adapter.value {
            CoreExprAdapterValue::LambdaAdapter {
                executable, manifest, captures
            } => LoweredExpr { prefix: [], value: make_core_lambda_expr(
                fact.result, fact.ty, fact.effects, fact.origin,
                executable, manifest, captures) },
            _ => panic("Core assembly: lambda exact executable is absent")
        },
        HExpr::EffectOp { operation_ref, args, .. } => {
            let (operation, evidence) = match fact.adapter.value {
                CoreExprAdapterValue::EffectAdapter { operation, evidence } =>
                    (operation, evidence),
                _ => panic("Core assembly: effect operation adapter is absent")
            }
            match operation_ref {
                some(source) => if !effect_operation_ref_same(source, operation) {
                    panic("Core assembly: EffectOperationRef changed")
                },
                none => panic("Core assembly: pending effect operation crossed Core")
            }
            let mut prefix: List<CoreStmt> = []
            let arguments = args.map(fn(arg) {
                materialize(prefix, lower_expr(cursor, arg))
            })
            LoweredExpr { prefix: prefix, value: make_core_effect_call_expr(
                fact.result, fact.ty, fact.effects, fact.origin,
                operation, arguments, evidence) }
        },
        HExpr::RangeExpr { start, end, .. } => {
            lower_sequence_construct(cursor, fact, [start, end])
        },
        HExpr::ListLit { elements, .. } |
        HExpr::TupleLit { elements, .. } =>
            lower_sequence_construct(cursor, fact, elements),
        HExpr::IndexExpr { receiver, index, .. } => {
            let mut prefix: List<CoreStmt> = []
            let receiver_slot = materialize(prefix, lower_expr(cursor, receiver))
            let index_slot = materialize(prefix, lower_expr(cursor, index))
            match fact.adapter.value {
                CoreExprAdapterValue::MethodAdapter {
                    callee, method, receiver: exact_receiver, evidence
                } => {
                    if !slot_ref_same(receiver_slot, exact_receiver) {
                        panic("Core assembly: index receiver differs")
                    }
                    LoweredExpr { prefix: prefix, value: make_core_method_call_expr(
                        fact.result, fact.ty, fact.effects, fact.origin,
                        callee, method, exact_receiver, [index_slot], evidence) }
                },
                CoreExprAdapterValue::CallAdapter { callee, evidence } =>
                    LoweredExpr { prefix: prefix, value: make_core_call_expr(
                        fact.result, fact.ty, fact.effects, fact.origin,
                        callee, [receiver_slot, index_slot], evidence) },
                _ => panic("Core assembly: index exact call adapter is absent")
            }
        },
        HExpr::DictConstruct { .. } => match fact.adapter.value {
            CoreExprAdapterValue::DictAdapter { constructor, evidence } =>
                LoweredExpr { prefix: [], value: make_core_dict_construct_expr(
                    fact.result, fact.ty, fact.effects, fact.origin,
                    constructor, evidence) },
            _ => panic("Core assembly: dictionary exact adapter is absent")
        },
        HExpr::UnsafeBlock { body, .. } => {
            match fact.adapter.value {
                CoreExprAdapterValue::PlainAdapter => {},
                _ => panic("Core assembly: unsafe block carried adapter")
            }
            let block = lower_expr_block(cursor, body)
            LoweredExpr { prefix: [], value: make_core_block_expr(
                fact.result, fact.ty, fact.effects, fact.origin, block) }
        },
        HExpr::ReturnExpr { value, .. } => {
            match fact.adapter.value {
                CoreExprAdapterValue::PlainAdapter => {},
                _ => panic("Core assembly: return expression carried adapter")
            }
            let block_fact = next_block_fact(cursor)
            let mut statements: List<CoreStmt> = []
            let returned = match value {
                some(item) => {
                    let lowered = lower_expr(cursor, item)
                    append_statements(statements, lowered.prefix)
                    some(lowered.value)
                },
                none => none
            }
            statements.push(make_core_return_stmt(returned, fact.origin))
            let block = make_core_block(
                statements, none, block_fact.origin, block_fact.scope)
            LoweredExpr { prefix: [], value: make_core_block_expr(
                fact.result, fact.ty, fact.effects, fact.origin, block) }
        },
        HExpr::StringInterp { parts, .. } => {
            let (callee, evidence, literals) = match fact.adapter.value {
                CoreExprAdapterValue::StringInterpAdapter {
                    callee, evidence, literals
                } => (callee, evidence, literals),
                _ => panic("Core assembly: interpolation exact call is absent")
            }
            let mut prefix: List<CoreStmt> = []
            let mut arguments: List<SlotRef> = []
            let mut literal_index = 0
            for part in parts {
                match part {
                    HStringInterpPart::Literal(value) => {
                        let literal = match literals.get(literal_index) {
                            some(item) => item,
                            none => panic(
                                "Core assembly: interpolation literal fact is short")
                        }
                        if literal.value != value {
                            panic("Core assembly: interpolation literal changed")
                        }
                        let expr = make_core_literal_expr(
                            literal.slot, literal.ty, literal.origin,
                            make_core_str_literal(value))
                        prefix.push(make_core_initialize_stmt(
                            literal.slot, expr, literal.origin))
                        arguments.push(literal.slot)
                        literal_index = literal_index + 1
                    },
                    HStringInterpPart::Expression(value) =>
                        arguments.push(materialize(
                            prefix, lower_expr(cursor, value)))
                }
            }
            if literal_index != literals.len() {
                panic("Core assembly: interpolation literal fact is long")
            }
            LoweredExpr { prefix: prefix, value: make_core_call_expr(
                fact.result, fact.ty, fact.effects, fact.origin,
                callee, arguments, evidence) }
        },
        HExpr::Clone { .. } =>
            panic("Core assembly: legacy resource Clone crossed Core"),
        HExpr::Take { .. } =>
            panic("Core assembly: resource Take crossed Core input")
    }
}

fn lower_sequence_construct(
    mut cursor: BodyCursor, fact: MaterializedCoreExprFact,
    values: List<HExpr>
) -> LoweredExpr {
    let (constructor, fields) = match fact.adapter.value {
        CoreExprAdapterValue::ConstructAdapter { constructor, fields } =>
            (constructor, fields),
        _ => panic("Core assembly: aggregate constructor adapter is absent")
    }
    if fields.len() != values.len() {
        panic("Core assembly: aggregate field census differs")
    }
    let mut prefix: List<CoreStmt> = []
    let mut index = 0
    let lowered_fields = values.map(fn(value) {
        let slot = materialize(prefix, lower_expr(cursor, value))
        let result = make_core_field_value(fields.get(index).unwrap(), slot)
        index = index + 1
        result
    })
    LoweredExpr { prefix: prefix, value: make_core_construct_expr(
        fact.result, fact.ty, fact.effects, fact.origin,
        constructor, lowered_fields) }
}

fn embed_prefix(mut cursor: BodyCursor, value: LoweredExpr) -> CoreExpr {
    if value.prefix.len() == 0 { return value.value }
    let block_fact = next_block_fact(cursor)
    let block = make_core_block(
        value.prefix, some(value.value), block_fact.origin, block_fact.scope)
    make_core_block_expr(
        core_expr_result(value.value), core_expr_type(value.value),
        core_expr_effects(value.value), core_expr_origin(value.value), block)
}

fn lower_expr_block(mut cursor: BodyCursor, expr: HExpr) -> CoreBlock {
    let block_fact = next_block_fact(cursor)
    let lowered = lower_expr(cursor, expr)
    make_core_block(
        lowered.prefix, some(lowered.value),
        block_fact.origin, block_fact.scope)
}

fn lower_match_arm(
    mut cursor: BodyCursor, arm: HMatchArm
) -> List<CoreMatchArm> {
    let mut patterns: List<CorePattern> = []
    match arm.pattern {
        Pattern::OrPattern { patterns: source_patterns, .. } => {
            let fact = next_pattern_fact(cursor)
            match fact.value {
                CorePatternAdapterValue::PatternOr => {},
                _ => panic("Core assembly: OrPattern fact differs")
            }
            for pattern in source_patterns {
                patterns.push(lower_pattern(cursor, pattern))
            }
        },
        other => patterns.push(lower_pattern(cursor, other))
    }
    let guard = match arm.guard {
        some(value) => some(embed_prefix(cursor, lower_expr(cursor, value))),
        none => none
    }
    let body = lower_expr_block(cursor, arm.body)
    let mut result: List<CoreMatchArm> = []
    for pattern in patterns {
        result.push(make_core_match_arm(
            pattern, guard, body, core_block_origin(body)))
    }
    result
}

fn lower_place_target(
    mut cursor: BodyCursor, target: HExpr, place: CorePlaceRef
) -> List<CoreStmt> {
    let fact = next_expr_fact(cursor, target)
    match target {
        HExpr::Ident { .. } => {
            let source = match fact.adapter.value {
                CoreExprAdapterValue::ReadAdapter(slot) => slot,
                _ => panic("Core assembly: assign identifier lacks exact slot")
            }
            if !core_place_is_slot(place) ||
               !slot_ref_same(core_place_slot(place), source) {
                panic("Core assembly: assign slot place differs")
            }
            []
        },
        HExpr::FieldAccess { receiver, .. } => {
            let field = match fact.adapter.value {
                CoreExprAdapterValue::ProjectAdapter { field, .. } => field,
                _ => panic("Core assembly: assign field lacks projection fact")
            }
            let mut prefix: List<CoreStmt> = []
            let base = materialize(prefix, lower_expr(cursor, receiver))
            if core_place_is_slot(place) ||
               !slot_ref_same(core_place_base(place), base) {
                panic("Core assembly: assign field base differs")
            }
            match core_place_field(place) {
                some(exact_field) => if !core_field_ref_same(
                        exact_field, field) {
                    panic("Core assembly: assign field identity differs")
                },
                none => panic("Core assembly: assign field place has no field")
            }
            prefix
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            match fact.adapter.value {
                CoreExprAdapterValue::MethodAdapter { .. } |
                CoreExprAdapterValue::CallAdapter { .. } => {},
                _ => panic("Core assembly: assign index lacks exact call fact")
            }
            let mut prefix: List<CoreStmt> = []
            let base = materialize(prefix, lower_expr(cursor, receiver))
            let evaluated_index = materialize(prefix, lower_expr(cursor, index))
            if core_place_is_slot(place) ||
               !slot_ref_same(core_place_base(place), base) {
                panic("Core assembly: assign index base differs")
            }
            match core_place_evaluated_index(place) {
                some(exact_index) => if !slot_ref_same(
                        exact_index, evaluated_index) {
                    panic("Core assembly: assign evaluated index differs")
                },
                none => panic("Core assembly: index place has no evaluated index")
            }
            prefix
        },
        _ => panic("Core assembly: unsupported assignment place crossed Core")
    }
}

fn lower_destructure_bindings(
    source: SlotRef, values: List<MaterializedCoreDestructureBinding>
) -> List<CoreStmt> {
    let mut result: List<CoreStmt> = []
    let mut available: List<SlotRef> = [source]
    for binding in values {
        let mut base_found = false
        for slot in available {
            if slot_ref_same(slot, binding.base) { base_found = true }
        }
        if !base_found {
            panic("Core assembly: destructure projection base is not available")
        }
        let projected = make_core_project_expr(
            binding.target, binding.ty, make_core_effect_set([]),
            binding.origin, binding.base, binding.field, false)
        result.push(make_core_initialize_stmt(
            binding.target, projected, binding.origin))
        available.push(binding.target)
    }
    result
}

fn lower_for_in_stmt(
    mut cursor: BodyCursor, iterable: HExpr, body: HExpr,
    plan: MaterializedCoreForInPlan, origin: OriginRef
) -> List<CoreStmt> {
    let iterable_lowered = lower_expr(cursor, iterable)
    let mut result = iterable_lowered.prefix
    let iterable_value = iterable_lowered.value
    result.push(make_core_initialize_stmt(
        core_expr_result(iterable_value), iterable_value, origin))
    let iter_expr = make_core_method_call_expr(
        plan.iterator_slot, plan.iterator_type,
        plan.iter_effects, plan.iter_origin,
        plan.iter_callee, plan.iter_method,
        core_expr_result(iterable_value), [], plan.iter_evidence)
    let iter_init = make_core_initialize_stmt(
        plan.iterator_slot, iter_expr, plan.iter_origin)
    let condition = make_core_method_call_expr(
        plan.condition_slot, plan.condition_type,
        plan.has_next_effects, plan.has_next_origin,
        plan.has_next_callee, plan.has_next_method,
        plan.iterator_slot, [], plan.has_next_evidence)
    let next_expr = make_core_method_call_expr(
        plan.item_slot, plan.item_type,
        plan.next_effects, plan.next_origin,
        plan.next_callee, plan.next_method,
        plan.iterator_slot, [], plan.next_evidence)
    let mut body_prefix: List<CoreStmt> = [
        make_core_initialize_stmt(plan.item_slot, next_expr, plan.next_origin)
    ]
    let binding_read = make_core_read_expr(
        plan.binding_slot, plan.item_type, make_core_effect_set([]),
        plan.next_origin, plan.item_slot)
    body_prefix.push(make_core_initialize_stmt(
        plan.binding_slot, binding_read, plan.next_origin))
    append_statements(body_prefix, lower_destructure_bindings(
        plan.binding_slot, plan.destructure))
    let lowered_body = lower_expr_block(cursor, body)
    append_statements(body_prefix, core_block_statements(lowered_body))
    let body_block = make_core_block(
        body_prefix, core_block_tail(lowered_body),
        core_block_origin(lowered_body), core_block_scope(lowered_body))
    result.push(iter_init)
    result.push(make_core_while_stmt(condition, body_block, origin))
    result
}

fn lower_if_let_stmt(
    mut cursor: BodyCursor, pattern: Pattern, expr: HExpr,
    then_block: HExpr, else_block: HExpr?,
    plan: MaterializedCoreIfLetPlan, origin: OriginRef
) -> List<CoreStmt> {
    let mut prefix: List<CoreStmt> = []
    let scrutinee = materialize(prefix, lower_expr(cursor, expr))
    let exact_pattern = lower_pattern(cursor, pattern)
    let then_body = lower_expr_block(cursor, then_block)
    let else_body = match else_block {
        some(value) => lower_expr_block(cursor, value),
        none => {
            let block_fact = next_block_fact(cursor)
            make_core_block([], none, block_fact.origin, block_fact.scope)
        }
    }
    let wildcard = make_core_wildcard_pattern(plan.scrutinee_type)
    let arms = [
        make_core_match_arm(
            exact_pattern, none, then_body, core_block_origin(then_body)),
        make_core_match_arm(
            wildcard, none, else_body, core_block_origin(else_body))
    ]
    let matched = make_core_match_expr(
        plan.result_slot, plan.result_type, plan.effects, plan.origin,
        scrutinee, arms)
    prefix.push(make_core_expr_stmt(matched, origin))
    prefix
}

fn lower_stmt(mut cursor: BodyCursor, stmt: HStmt) -> List<CoreStmt> {
    let fact = next_stmt_fact(cursor)
    match stmt {
        HStmt::Let { init, .. } | HStmt::Var { init, .. } => {
            let target = match fact.target {
                some(value) => if core_place_is_slot(value) {
                    core_place_slot(value)
                } else {
                    panic("Core assembly: binding target is projected place")
                },
                none => panic("Core assembly: binding target SlotRef is absent")
            }
            let lowered = lower_expr(cursor, init)
            if !slot_ref_same(core_expr_result(lowered.value), target) {
                panic("Core assembly: binding result/target slot differs")
            }
            let mut result = lowered.prefix
            result.push(make_core_initialize_stmt(target, lowered.value, fact.origin))
            result
        },
        HStmt::Assign { target, value, .. } => {
            let exact_target = match fact.target {
                some(item) => item,
                none => panic("Core assembly: assign target SlotRef is absent")
            }
            let mut result: List<CoreStmt> = []
            append_statements(result, lower_place_target(cursor, target, exact_target))
            let lowered = lower_expr(cursor, value)
            append_statements(result, lowered.prefix)
            result.push(make_core_assign_stmt(
                exact_target, lowered.value, fact.origin))
            result
        },
        HStmt::ExprStmt { expr, .. } => {
            let lowered = lower_expr(cursor, expr)
            let mut result = lowered.prefix
            result.push(make_core_expr_stmt(lowered.value, fact.origin))
            result
        },
        HStmt::Return { value, .. } => {
            let returned = match value {
                some(expr) => some(embed_prefix(cursor, lower_expr(cursor, expr))),
                none => none
            }
            [make_core_return_stmt(returned, fact.origin)]
        },
        HStmt::While { condition, body, .. } => {
            let condition = embed_prefix(cursor, lower_expr(cursor, condition))
            let body = lower_expr_block(cursor, body)
            [make_core_while_stmt(condition, body, fact.origin)]
        },
        HStmt::Break { .. } => [make_core_break_stmt(fact.origin)],
        HStmt::Continue { .. } => [make_core_continue_stmt(fact.origin)],
        HStmt::ForIn { iterable, body, .. } => match fact.for_in {
            some(plan) => lower_for_in_stmt(
                cursor, iterable, body, plan, fact.origin),
            none => panic("Core assembly: ForIn exact protocol plan is absent")
        },
        HStmt::LetDestructure { init, .. } => {
            let bindings = match fact.destructure {
                some(values) => values,
                none => panic("Core assembly: destructure exact plan is absent")
            }
            let lowered = lower_expr(cursor, init)
            let mut result = lowered.prefix
            result.push(make_core_initialize_stmt(
                core_expr_result(lowered.value), lowered.value, fact.origin))
            append_statements(result, lower_destructure_bindings(
                core_expr_result(lowered.value), bindings))
            result
        },
        HStmt::IfLet { pattern, expr, then_block, else_block, .. } => {
            let plan = match fact.if_let {
                some(value) => value,
                none => panic("Core assembly: IfLet exact plan is absent")
            }
            lower_if_let_stmt(
                cursor, pattern, expr, then_block, else_block,
                plan, fact.origin)
        },
        HStmt::Drop { .. } =>
            panic("Core assembly: legacy resource Drop crossed Core")
    }
}

fn lower_block_parts(
    mut cursor: BodyCursor, stmts: List<HStmt>, tail: HExpr?
) -> CoreBlock {
    let block_fact = next_block_fact(cursor)
    let mut statements: List<CoreStmt> = []
    for stmt in stmts {
        append_statements(statements, lower_stmt(cursor, stmt))
    }
    let tail_value = match tail {
        some(expr) => {
            let lowered = lower_expr(cursor, expr)
            append_statements(statements, lowered.prefix)
            some(lowered.value)
        },
        none => none
    }
    make_core_block(
        statements, tail_value, block_fact.origin, block_fact.scope)
}

fn assemble_source_body(
    input: CoreSourceBodyInput, source: HExpr,
    graph: CoreTypeGraph
) -> CoreBodyEntry {
    let mut cursor = BodyCursor {
        input: input, expr_index: 0, stmt_index: 0,
        block_index: 0, pattern_index: 0
    }
    let block = lower_expr_block(cursor, source)
    if cursor.expr_index != input.expr_facts.len() ||
       cursor.stmt_index != input.stmt_facts.len() ||
       cursor.block_index != input.block_facts.len() ||
       cursor.pattern_index != input.pattern_facts.len() {
        panic("Core assembly: body fact census has unconsumed entries")
    }
    let body = make_core_body(
        input.executable, input.origin, core_type_graph_count(graph),
        input.manifest, input.scopes,
        input.slots.map(fn(slot) {
            materialize_slot_fact(slot, input.module_key)
        }),
        input.parameter_slots,
        local_core_type_ref(input.result_type, input.module_key), block)
    make_core_body_entry(
        input.executable, input.origin, input.body_anchor, body)
}

fn materialize_generated(value: CoreGeneratedPlan) -> CoreBody {
    let elaborated = match value.value {
        CoreGeneratedPlanValue::GeneratedTraitDefault(plan) =>
            elaborate_core_trait_default(plan),
        CoreGeneratedPlanValue::GeneratedDefaultSpecialization(plan) =>
            elaborate_core_default_specialization(plan),
        CoreGeneratedPlanValue::GeneratedDerivedEq(plan) =>
            elaborate_core_derived_eq(plan),
        CoreGeneratedPlanValue::GeneratedDerivedNe(plan) =>
            elaborate_core_derived_ne(plan),
        CoreGeneratedPlanValue::GeneratedDerivedHash(plan) =>
            elaborate_core_derived_hash(plan),
        CoreGeneratedPlanValue::GeneratedStructClone(plan) =>
            elaborate_core_struct_deep_clone(plan),
        CoreGeneratedPlanValue::GeneratedEnumClone(plan) =>
            elaborate_core_enum_deep_clone(plan),
        CoreGeneratedPlanValue::GeneratedDerivedOrd(plan) =>
            elaborate_core_derived_ord(plan),
        CoreGeneratedPlanValue::GeneratedDerivedDebug(plan) =>
            elaborate_core_derived_debug(plan),
        CoreGeneratedPlanValue::GeneratedDerivedJson(plan) =>
            elaborate_core_derived_json(plan)
    }
    core_elaborated_body(elaborated)
}

fn body_anchor_for(
    inventory: ExecutableInventory, reference: ExecutableRef
) -> PathRef {
    let mut found: PathRef? = none
    for entry in executable_inventory_entries(inventory) {
        if executable_ref_same(executable_entry_reference(entry), reference) &&
           executable_contract_mode_same(
                executable_contract_mode(executable_entry_contract(entry)),
                executable_contract_mode_concrete_body()) {
            if found.is_some() {
                panic("Core assembly: executable inventory body repeats")
            }
            found = some(executable_contract_body_path(
                executable_entry_contract(entry)))
        }
    }
    match found {
        some(value) => value,
        none => panic("Core assembly: generated body has no inventory contract")
    }
}

fn entry_for_body(
    body: CoreBody, inventory: ExecutableInventory
) -> CoreBodyEntry {
    make_core_body_entry(
        core_body_reference(body), core_body_origin(body),
        body_anchor_for(inventory, core_body_reference(body)), body)
}

fn order_entries_by_inventory(
    pool: List<CoreBodyEntry>, inventory: ExecutableInventory
) -> List<CoreBodyEntry> {
    let mut result: List<CoreBodyEntry> = []
    for inventory_entry in executable_inventory_entries(inventory) {
        if executable_contract_mode_same(
                executable_contract_mode(
                    executable_entry_contract(inventory_entry)),
                executable_contract_mode_concrete_body()) {
            let target = executable_entry_reference(inventory_entry)
            let mut found: CoreBodyEntry? = none
            for entry in pool {
                if executable_ref_same(core_body_entry_reference(entry), target) {
                    if found.is_some() {
                        panic("Core assembly: body pool repeats executable")
                    }
                    found = some(entry)
                }
            }
            result.push(match found {
                some(value) => value,
                none => panic("Core assembly: concrete inventory body is missing")
            })
        }
    }
    if result.len() != pool.len() {
        panic("Core assembly: body pool contains non-inventory body")
    }
    result
}

struct CoreTypePrototype {
    module_index: Int,
    local_index: Int
}

struct ProjectTypeInterning {
    graph: CoreTypeGraph,
    module_mappings: List<List<Int>>
}

fn unresolved_type_mapping(count: Int) -> List<Int?> {
    let mut result: List<Int?> = []
    let mut index = 0
    while index < count {
        result.push(none)
        index = index + 1
    }
    result
}

fn close_type_mapping(values: List<Int?>) -> List<Int> {
    let mut result: List<Int> = []
    for value in values {
        result.push(match value {
            some(index) => index,
            none => panic("Core assembly: type interner left an unresolved fact")
        })
    }
    result
}

fn validate_project_fact_order(facts: List<FrozenCoreAssemblyFacts>) {
    let mut fact_index = 0
    while fact_index < facts.len() {
        let fact = facts.get(fact_index).unwrap()
        if fact.module_order != fact_index {
            panic("Core assembly: project facts are not in module order")
        }
        let mut prior_index = 0
        while prior_index < fact_index {
            if facts.get(prior_index).unwrap().module_key == fact.module_key {
                panic("Core assembly: project repeats an exact module key")
            }
            prior_index = prior_index + 1
        }
        fact_index = fact_index + 1
    }
}

// Deterministic finite worklist.  Atomic/parameter/exact-nominal keys are
// reservable without their recursive field edges; structural types wait until
// every child key is known.  A later full-contract comparison rejects two
// producers that claim the same exact nominal key with different payloads.
fn intern_project_types(
    facts: List<FrozenCoreAssemblyFacts>
) -> ProjectTypeInterning {
    let mut mappings: List<List<Int?>> = []
    let mut total = 0
    for fact in facts {
        mappings.push(unresolved_type_mapping(fact.type_nodes.len()))
        total = total + fact.type_nodes.len()
    }
    let mut prototypes: List<CoreTypePrototype> = []
    let mut resolved = 0
    while resolved < total {
        let mut progress = false
        let mut fact_index = 0
        while fact_index < facts.len() {
            let fact = facts.get(fact_index).unwrap()
            let mut mapping = mappings.get(fact_index).unwrap()
            let mut local_index = 0
            while local_index < fact.type_nodes.len() {
                if mapping.get(local_index).unwrap().is_none() {
                    let node = fact.type_nodes.get(local_index).unwrap()
                    if flow_type_node_intern_ready(node, mapping) {
                        let mut chosen: Int? = none
                        let mut prototype_index = 0
                        while prototype_index < prototypes.len() {
                            let prototype = prototypes.get(
                                prototype_index).unwrap()
                            let candidate_fact = facts.get(
                                prototype.module_index).unwrap()
                            let candidate_node = candidate_fact.type_nodes.get(
                                prototype.local_index).unwrap()
                            let candidate_mapping = mappings.get(
                                prototype.module_index).unwrap()
                            if flow_type_node_intern_key_same(
                                    node, mapping,
                                    candidate_node, candidate_mapping) {
                                chosen = some(prototype_index)
                                prototype_index = prototypes.len()
                            } else {
                                prototype_index = prototype_index + 1
                            }
                        }
                        let project_index = match chosen {
                            some(index) => index,
                            none => {
                                let index = prototypes.len()
                                prototypes.push(CoreTypePrototype {
                                    module_index: fact_index,
                                    local_index: local_index
                                })
                                index
                            }
                        }
                        mapping.set(local_index, some(project_index))
                        mappings.set(fact_index, mapping)
                        resolved = resolved + 1
                        progress = true
                    }
                }
                local_index = local_index + 1
            }
            fact_index = fact_index + 1
        }
        if !progress {
            panic("Core assembly: structural type interning dependency cycle")
        }
    }

    let mut closed_mappings: List<List<Int>> = []
    for mapping in mappings { closed_mappings.push(close_type_mapping(mapping)) }
    let mut project_nodes: List<FlowTypeNode> = []
    let mut project_index = 0
    while project_index < prototypes.len() {
        let prototype = prototypes.get(project_index).unwrap()
        let fact = facts.get(prototype.module_index).unwrap()
        let node = fact.type_nodes.get(prototype.local_index).unwrap()
        project_nodes.push(remap_flow_type_node(
            node, project_index,
            closed_mappings.get(prototype.module_index).unwrap()))
        project_index = project_index + 1
    }
    let mut fact_index = 0
    while fact_index < facts.len() {
        let fact = facts.get(fact_index).unwrap()
        let mapping = closed_mappings.get(fact_index).unwrap()
        let mut local_index = 0
        while local_index < fact.type_nodes.len() {
            let target = mapping.get(local_index).unwrap()
            let remapped = remap_flow_type_node(
                fact.type_nodes.get(local_index).unwrap(), target, mapping)
            if !flow_type_node_contract_same(
                    remapped, project_nodes.get(target).unwrap()) {
                panic("Core assembly: repeated type key has a different contract")
            }
            local_index = local_index + 1
        }
        fact_index = fact_index + 1
    }
    ProjectTypeInterning {
        graph: make_core_type_graph(project_nodes),
        module_mappings: closed_mappings
    }
}

pub struct CoreAssemblyTypeRemapEntry {
    source: CoreTypeFactRef,
    target: CoreTypeRef
}
pub fn core_assembly_type_remap_source(
    value: CoreAssemblyTypeRemapEntry
) -> CoreTypeFactRef { value.source }
pub fn core_assembly_type_remap_target(
    value: CoreAssemblyTypeRemapEntry
) -> CoreTypeRef { value.target }

pub struct CoreAssemblyTypeRemap {
    entries: List<CoreAssemblyTypeRemapEntry>
}
pub fn core_assembly_type_remap_entries(
    value: CoreAssemblyTypeRemap
) -> List<CoreAssemblyTypeRemapEntry> {
    value.entries.map(fn(entry) {
        CoreAssemblyTypeRemapEntry {
            source: entry.source, target: entry.target
        }
    })
}
pub fn core_assembly_remap_type(
    value: CoreAssemblyTypeRemap, source: CoreTypeFactRef
) -> CoreTypeRef {
    let mut found: CoreTypeRef? = none
    for entry in value.entries {
        if core_type_fact_same(entry.source, source) {
            if found.is_some() {
                panic("Core assembly: type remap source repeats")
            }
            found = some(entry.target)
        }
    }
    match found {
        some(target) => target,
        none => panic("Core assembly: type fact has no project remap")
    }
}

pub struct CoreAssemblyEffectRemapEntry {
    module_key: Str,
    source: CoreEffectSet,
    target: CoreEffectSet
}
pub fn core_assembly_effect_remap_module_key(
    value: CoreAssemblyEffectRemapEntry
) -> Str { value.module_key }
pub fn core_assembly_effect_remap_source(
    value: CoreAssemblyEffectRemapEntry
) -> CoreEffectSet {
    make_core_effect_set(core_effect_set_atoms(value.source))
}
pub fn core_assembly_effect_remap_target(
    value: CoreAssemblyEffectRemapEntry
) -> CoreEffectSet {
    make_core_effect_set(core_effect_set_atoms(value.target))
}
pub struct CoreAssemblyEffectRemap {
    entries: List<CoreAssemblyEffectRemapEntry>
}
pub fn core_assembly_effect_remap_entries(
    value: CoreAssemblyEffectRemap
) -> List<CoreAssemblyEffectRemapEntry> {
    value.entries.map(fn(entry) {
        CoreAssemblyEffectRemapEntry {
            module_key: entry.module_key,
            source: make_core_effect_set(core_effect_set_atoms(entry.source)),
            target: make_core_effect_set(core_effect_set_atoms(entry.target))
        }
    })
}
pub fn core_assembly_remap_effect(
    value: CoreAssemblyEffectRemap,
    module_key: Str, source: CoreEffectSet
) -> CoreEffectSet {
    let mut found: CoreEffectSet? = none
    for entry in value.entries {
        if entry.module_key == module_key &&
           core_effect_set_same(entry.source, source) {
            if found.is_some() {
                panic("Core assembly: effect remap source repeats")
            }
            found = some(entry.target)
        }
    }
    match found {
        some(target) => make_core_effect_set(core_effect_set_atoms(target)),
        none => panic("Core assembly: effect set has no project remap")
    }
}

pub struct CoreAssemblyResult {
    program: CoreProgram,
    type_remap: CoreAssemblyTypeRemap,
    effect_remap: CoreAssemblyEffectRemap
}
pub fn core_assembly_result_program(value: CoreAssemblyResult) -> CoreProgram {
    value.program
}
pub fn core_assembly_result_type_remap(
    value: CoreAssemblyResult
) -> CoreAssemblyTypeRemap { value.type_remap }
pub fn core_assembly_result_effect_remap(
    value: CoreAssemblyResult
) -> CoreAssemblyEffectRemap { value.effect_remap }

fn append_effect_remaps(
    module_key: Str, local: CoreBody, global: CoreBody,
    mut entries: List<CoreAssemblyEffectRemapEntry>
) {
    let local_effects = core_body_effect_sets(local)
    let global_effects = core_body_effect_sets(global)
    if local_effects.len() != global_effects.len() {
        panic("Core assembly: local/global effect traversal differs")
    }
    let mut index = 0
    while index < local_effects.len() {
        let source = local_effects.get(index).unwrap()
        let target = global_effects.get(index).unwrap()
        let mut existing: CoreEffectSet? = none
        for entry in entries {
            if entry.module_key == module_key &&
               core_effect_set_same(entry.source, source) {
                existing = some(entry.target)
            }
        }
        match existing {
            some(value) => if !core_effect_set_same(value, target) {
                panic("Core assembly: effect remap target differs")
            },
            none => entries.push(CoreAssemblyEffectRemapEntry {
                module_key: module_key,
                source: make_core_effect_set(core_effect_set_atoms(source)),
                target: make_core_effect_set(core_effect_set_atoms(target))
            })
        }
        index = index + 1
    }
}

fn assemble_frozen_core_facts(
    facts: List<FrozenCoreAssemblyFacts>
) -> CoreAssemblyResult {
    if facts.len() == 0 { panic("Core assembly: project has no frozen facts") }
    validate_project_fact_order(facts)
    let interning = intern_project_types(facts)
    let mut inventory_entries: List<ExecutableEntry> = []
    let mut manifests: List<BinderManifest> = []
    for fact in facts {
        for entry in fact.inventory_entries { inventory_entries.push(entry) }
        for manifest in fact.manifests { manifests.push(manifest) }
    }
    let inventory = make_executable_inventory(inventory_entries)
    let project_type_count = core_type_graph_count(interning.graph)
    let mut type_remap_entries: List<CoreAssemblyTypeRemapEntry> = []
    let mut type_fact_index = 0
    while type_fact_index < facts.len() {
        let fact = facts.get(type_fact_index).unwrap()
        let mapping = interning.module_mappings.get(type_fact_index).unwrap()
        if fact.type_refs.len() != mapping.len() {
            panic("Core assembly: type fact/remap census differs")
        }
        let mut local_index = 0
        while local_index < fact.type_refs.len() {
            if core_type_fact_ordinal(
                    fact.type_refs.get(local_index).unwrap()) != local_index {
                panic("Core assembly: type fact/remap order differs")
            }
            type_remap_entries.push(CoreAssemblyTypeRemapEntry {
                source: fact.type_refs.get(local_index).unwrap(),
                target: make_core_type_ref(mapping.get(local_index).unwrap())
            })
            local_index = local_index + 1
        }
        type_fact_index = type_fact_index + 1
    }
    let mut callables: List<CoreCallableContract> = []
    let mut all_impls: List<CoreImplMetadata> = []
    let mut body_pool: List<CoreBodyEntry> = []
    let mut effect_remap_entries: List<CoreAssemblyEffectRemapEntry> = []
    let mut fact_index = 0
    while fact_index < facts.len() {
        let fact = facts.get(fact_index).unwrap()
        let mapping = interning.module_mappings.get(fact_index).unwrap()
        let local_graph = make_module_core_type_graph(
            fact.module_key, fact.type_nodes)
        for callable in fact.callables {
            callables.push(remap_core_callable_types(
                callable, mapping, fact.module_key))
        }
        for item in fact.impls {
            all_impls.push(remap_core_impl_types(
                item, mapping, fact.module_key))
        }
        for source in fact.source_bodies {
            let hir = source.source
            let local_entry = assemble_source_body(source, hir, local_graph)
            let local_body = core_body_entry_body(local_entry)
            let global_body = remap_core_body_types(
                local_body, mapping, project_type_count, fact.module_key)
            append_effect_remaps(
                fact.module_key, local_body, global_body,
                effect_remap_entries)
            body_pool.push(make_core_body_entry(
                core_body_entry_reference(local_entry),
                core_body_entry_origin(local_entry),
                core_body_entry_anchor(local_entry),
                global_body))
        }
        for generated in fact.generated {
            let local_body = materialize_generated(generated)
            let global_body = remap_core_body_types(
                local_body, mapping, project_type_count, fact.module_key)
            append_effect_remaps(
                fact.module_key, local_body, global_body,
                effect_remap_entries)
            body_pool.push(entry_for_body(
                global_body, inventory))
        }
        for delegate in fact.delegates {
            let (metadata, bodies) = elaborate_delegate_to_core(delegate)
            all_impls.push(remap_core_impl_types(
                metadata, mapping, fact.module_key))
            for body in bodies {
                let global_body = remap_core_body_types(
                    body, mapping, project_type_count, fact.module_key)
                append_effect_remaps(
                    fact.module_key, body, global_body,
                    effect_remap_entries)
                body_pool.push(entry_for_body(
                    global_body, inventory))
            }
        }
        fact_index = fact_index + 1
    }
    let ordered = order_entries_by_inventory(body_pool, inventory)
    let program = make_core_program(
        interning.graph, callables, all_impls, ordered,
        inventory, manifests)
    CoreAssemblyResult {
        program: program,
        type_remap: CoreAssemblyTypeRemap { entries: type_remap_entries },
        effect_remap: CoreAssemblyEffectRemap { entries: effect_remap_entries }
    }
}

pub fn assemble_single_core(
    facts: FrozenCoreAssemblyFacts
) -> CoreAssemblyResult {
    if facts.module_order != 0 {
        panic("Core assembly: single module order is not zero")
    }
    assemble_frozen_core_facts([facts])
}

pub fn assemble_project_core(
    facts_in_topological_order: List<FrozenCoreAssemblyFacts>
) -> CoreAssemblyResult {
    assemble_frozen_core_facts(facts_in_topological_order)
}
