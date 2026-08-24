// Sole 0.1 Typed-HIR -> CoreProgram assembler.
//
// Every identity/type/evidence/binder fact is supplied by the frozen checker
// products in deterministic traversal order.  This pass never resolves a
// spelling/span and never lets HProgram escape after CoreProgram construction.

use ast::{Pattern, LiteralValue}
use types::{Type, EffectRow, effects_equal, types_equal}
use ir_identity::{
    OriginRef, SlotRef, PathRef,
    RegisteredNominalRef, VariantRef,
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
    FlowScope, FlowScopeRef, FlowTypeNode,
    flow_type_node_reference, flow_type_ref_index
}
use core_expr::{
    CoreTypeGraph, CoreTypeRef, CoreEffectSet,
    CoreCallableContract, CoreImplMetadata,
    CoreSlot, CoreBody, CoreBlock, CoreStmt, CoreExpr, CoreLiteral,
    CorePlaceRef,
    CorePattern, CorePatternField, CoreFieldRef,
    CoreHandlerEntry, CoreMatchArm,
    CoreConstructorRef, CoreCalleeRef, CoreEvidenceRef,
    CoreCapture, CorePrimitiveOp,
    make_core_effect_set,
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
    make_core_body,
    core_expr_result, core_expr_type, core_expr_effects, core_expr_origin,
    core_block_origin,
    core_block_statements, core_block_tail, core_block_scope,
    core_body_reference, core_body_origin,
    core_constructor_variant,
    core_place_is_slot, core_place_slot,
    core_place_base, core_place_field, core_place_evaluated_index,
    core_field_ref_same,
    core_type_graph_count, core_type_graph_nodes, make_core_type_graph,
    copy_core_callables, copy_core_impl_metadata,
    core_callable_reference, core_impl_owner
}
use core_hir::{
    CoreProgram, CoreBodyEntry,
    make_core_body_entry, make_core_program,
    core_body_entry_reference
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
use delegate_plan::{DelegateTypedPlan}
use delegate_elaborate::{elaborate_delegate_to_core}

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
        callee: CoreCalleeRef,
        evidence: List<CoreEvidenceRef>,
        literals: List<CoreStringLiteralFact>
    }
}
pub struct CoreExprAdapter { value: CoreExprAdapterValue }

pub struct CoreStringLiteralFact {
    value: Str,
    slot: SlotRef,
    ty: CoreTypeRef,
    origin: OriginRef
}
pub fn make_core_string_literal_fact(
    value: Str, slot: SlotRef, ty: CoreTypeRef, origin: OriginRef
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
    CoreExprAdapter { value: CoreExprAdapterValue::PlainAdapter }
}
pub fn core_expr_read_adapter(source: SlotRef) -> CoreExprAdapter {
    CoreExprAdapter { value: CoreExprAdapterValue::ReadAdapter(source) }
}
pub fn core_expr_direct_callable_adapter(
    executable: ExecutableRef
) -> CoreExprAdapter {
    CoreExprAdapter { value:
        CoreExprAdapterValue::DirectCallableAdapter(executable) }
}
pub fn core_expr_primitive_adapter(operation: CorePrimitiveOp) -> CoreExprAdapter {
    CoreExprAdapter { value: CoreExprAdapterValue::PrimitiveAdapter(operation) }
}
pub fn core_expr_call_adapter(
    callee: CoreCalleeRef, evidence: List<CoreEvidenceRef>
) -> CoreExprAdapter {
    CoreExprAdapter { value: CoreExprAdapterValue::CallAdapter {
        callee: callee, evidence: copy_evidence(evidence) } }
}
pub fn core_expr_method_adapter(
    callee: CoreCalleeRef, method: MethodCallRef,
    receiver: SlotRef,
    evidence: List<CoreEvidenceRef>
) -> CoreExprAdapter {
    CoreExprAdapter { value: CoreExprAdapterValue::MethodAdapter {
        callee: callee, method: method, receiver: receiver,
        evidence: copy_evidence(evidence) } }
}
pub fn core_expr_project_adapter(
    field: CoreFieldRef, partial: Bool
) -> CoreExprAdapter {
    CoreExprAdapter { value: CoreExprAdapterValue::ProjectAdapter {
        field: field, partial: partial } }
}
pub fn core_expr_construct_adapter(
    constructor: CoreConstructorRef, fields: List<CoreFieldRef>
) -> CoreExprAdapter {
    CoreExprAdapter { value: CoreExprAdapterValue::ConstructAdapter {
        constructor: constructor, fields: copy_fields(fields) } }
}
pub fn core_expr_effect_adapter(
    operation: EffectOperationRef, evidence: List<CoreEvidenceRef>
) -> CoreExprAdapter {
    CoreExprAdapter { value: CoreExprAdapterValue::EffectAdapter {
        operation: operation, evidence: copy_evidence(evidence) } }
}
pub fn core_expr_system_adapter(host: SystemHostCallableRef) -> CoreExprAdapter {
    CoreExprAdapter { value: CoreExprAdapterValue::SystemAdapter(host) }
}
pub fn core_expr_dict_adapter(
    constructor: ExecutableRef, evidence: List<CoreEvidenceRef>
) -> CoreExprAdapter {
    CoreExprAdapter { value: CoreExprAdapterValue::DictAdapter {
        constructor: constructor, evidence: copy_evidence(evidence) } }
}
pub fn core_expr_lambda_adapter(
    executable: ExecutableRef, manifest: BinderManifest,
    captures: List<CoreCapture>
) -> CoreExprAdapter {
    CoreExprAdapter { value: CoreExprAdapterValue::LambdaAdapter {
        executable: executable, manifest: manifest,
        captures: copy_captures(captures) } }
}
pub fn core_expr_handle_adapter(
    handlers: List<CoreHandlerEntry>
) -> CoreExprAdapter {
    CoreExprAdapter { value: CoreExprAdapterValue::HandleAdapter {
        handlers: handlers.map(fn(value) { value }) } }
}
pub fn core_expr_string_interp_adapter(
    callee: CoreCalleeRef, evidence: List<CoreEvidenceRef>,
    literals: List<CoreStringLiteralFact>
) -> CoreExprAdapter {
    CoreExprAdapter { value: CoreExprAdapterValue::StringInterpAdapter {
        callee: callee, evidence: copy_evidence(evidence),
        literals: literals.map(fn(value) { value }) } }
}

pub struct CoreExprFact {
    source_type: Type,
    source_effects: EffectRow,
    result: SlotRef,
    ty: CoreTypeRef,
    effects: CoreEffectSet,
    origin: OriginRef,
    adapter: CoreExprAdapter
}
pub fn make_core_expr_fact(
    source_type: Type, source_effects: EffectRow,
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, adapter: CoreExprAdapter
) -> CoreExprFact {
    CoreExprFact { source_type: source_type, source_effects: source_effects,
        result: result, ty: ty, effects: effects,
        origin: origin, adapter: adapter }
}

pub struct CoreDestructureBinding {
    base: SlotRef, field: CoreFieldRef,
    target: SlotRef, ty: CoreTypeRef, origin: OriginRef
}
pub fn make_core_destructure_binding(
    base: SlotRef, field: CoreFieldRef,
    target: SlotRef, ty: CoreTypeRef, origin: OriginRef
) -> CoreDestructureBinding {
    CoreDestructureBinding {
        base: base, field: field, target: target, ty: ty, origin: origin
    }
}

pub struct CoreForInPlan {
    iterator_slot: SlotRef, iterator_type: CoreTypeRef,
    iter_callee: CoreCalleeRef, iter_method: MethodCallRef,
    iter_effects: CoreEffectSet, iter_evidence: List<CoreEvidenceRef>,
    iter_origin: OriginRef,
    condition_slot: SlotRef, condition_type: CoreTypeRef,
    has_next_callee: CoreCalleeRef, has_next_method: MethodCallRef,
    has_next_effects: CoreEffectSet, has_next_evidence: List<CoreEvidenceRef>,
    has_next_origin: OriginRef,
    item_slot: SlotRef, item_type: CoreTypeRef,
    next_callee: CoreCalleeRef, next_method: MethodCallRef,
    next_effects: CoreEffectSet, next_evidence: List<CoreEvidenceRef>,
    next_origin: OriginRef,
    binding_slot: SlotRef,
    destructure: List<CoreDestructureBinding>
}
pub fn make_core_for_in_plan(
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
    result_slot: SlotRef, result_type: CoreTypeRef,
    scrutinee_type: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef
}
pub fn make_core_if_let_plan(
    result_slot: SlotRef, result_type: CoreTypeRef,
    scrutinee_type: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef
) -> CoreIfLetPlan {
    CoreIfLetPlan { result_slot: result_slot, result_type: result_type,
        scrutinee_type: scrutinee_type, effects: effects, origin: origin }
}

pub struct CoreStmtFact {
    origin: OriginRef,
    target: CorePlaceRef?,
    for_in: CoreForInPlan?,
    destructure: List<CoreDestructureBinding>?,
    if_let: CoreIfLetPlan?
}
pub fn make_core_stmt_fact(
    origin: OriginRef, target: CorePlaceRef?
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
    ty: CoreTypeRef,
    value: CorePatternAdapterValue
}
pub fn core_pattern_wildcard_fact(ty: CoreTypeRef) -> CorePatternFact {
    CorePatternFact { ty: ty, value: CorePatternAdapterValue::PatternWildcard }
}
pub fn core_pattern_binding_fact(
    ty: CoreTypeRef, slot: SlotRef
) -> CorePatternFact {
    CorePatternFact { ty: ty,
        value: CorePatternAdapterValue::PatternBinding(slot) }
}
pub fn core_pattern_literal_fact(ty: CoreTypeRef) -> CorePatternFact {
    CorePatternFact { ty: ty, value: CorePatternAdapterValue::PatternLiteral }
}
pub fn core_pattern_tuple_fact(ty: CoreTypeRef) -> CorePatternFact {
    CorePatternFact { ty: ty, value: CorePatternAdapterValue::PatternTuple }
}
pub fn core_pattern_struct_fact(
    ty: CoreTypeRef, owner: RegisteredNominalRef,
    fields: List<CoreFieldRef>
) -> CorePatternFact {
    CorePatternFact { ty: ty, value: CorePatternAdapterValue::PatternStruct {
        owner: owner, fields: copy_fields(fields) } }
}
pub fn core_pattern_variant_fact(
    ty: CoreTypeRef, variant: VariantRef,
    fields: List<CoreFieldRef>
) -> CorePatternFact {
    CorePatternFact { ty: ty, value: CorePatternAdapterValue::PatternVariant {
        variant: variant, fields: copy_fields(fields) } }
}
pub fn core_pattern_or_fact(ty: CoreTypeRef) -> CorePatternFact {
    CorePatternFact { ty: ty, value: CorePatternAdapterValue::PatternOr }
}

pub struct CoreSourceBodyInput {
    source: HExpr,
    executable: ExecutableRef, origin: OriginRef, body_anchor: PathRef,
    manifest: BinderManifest, scopes: List<FlowScope>, slots: List<CoreSlot>,
    parameter_slots: List<SlotRef>, result_type: CoreTypeRef,
    expr_facts: List<CoreExprFact>, stmt_facts: List<CoreStmtFact>,
    block_facts: List<CoreBlockFact>, pattern_facts: List<CorePatternFact>
}
fn copy_scopes(values: List<FlowScope>) -> List<FlowScope> {
    let mut result: List<FlowScope> = []
    for value in values { result.push(value) }
    result
}
fn copy_slots(values: List<CoreSlot>) -> List<CoreSlot> {
    let mut result: List<CoreSlot> = []
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
    slots: List<CoreSlot>, parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef, expr_facts: List<CoreExprFact>,
    stmt_facts: List<CoreStmtFact>, block_facts: List<CoreBlockFact>,
    pattern_facts: List<CorePatternFact>
) -> CoreSourceBodyInput {
    CoreSourceBodyInput {
        source: source,
        executable: executable, origin: origin, body_anchor: body_anchor,
        manifest: manifest, scopes: copy_scopes(scopes),
        slots: copy_slots(slots),
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
pub struct CoreGeneratedPlan { value: CoreGeneratedPlanValue }
pub fn core_generated_trait_default(value: CoreOrdinaryBodyPlan) -> CoreGeneratedPlan {
    CoreGeneratedPlan { value: CoreGeneratedPlanValue::GeneratedTraitDefault(value) }
}
pub fn core_generated_default_specialization(value: CoreOrdinaryBodyPlan) -> CoreGeneratedPlan {
    CoreGeneratedPlan { value: CoreGeneratedPlanValue::GeneratedDefaultSpecialization(value) }
}
pub fn core_generated_derived_eq(value: CoreOrdinaryBodyPlan) -> CoreGeneratedPlan {
    CoreGeneratedPlan { value: CoreGeneratedPlanValue::GeneratedDerivedEq(value) }
}
pub fn core_generated_derived_ne(value: CoreOrdinaryBodyPlan) -> CoreGeneratedPlan {
    CoreGeneratedPlan { value: CoreGeneratedPlanValue::GeneratedDerivedNe(value) }
}
pub fn core_generated_derived_hash(value: CoreOrdinaryBodyPlan) -> CoreGeneratedPlan {
    CoreGeneratedPlan { value: CoreGeneratedPlanValue::GeneratedDerivedHash(value) }
}
pub fn core_generated_struct_clone(value: CoreStructClonePlan) -> CoreGeneratedPlan {
    CoreGeneratedPlan { value: CoreGeneratedPlanValue::GeneratedStructClone(value) }
}
pub fn core_generated_enum_clone(value: CoreEnumClonePlan) -> CoreGeneratedPlan {
    CoreGeneratedPlan { value: CoreGeneratedPlanValue::GeneratedEnumClone(value) }
}
pub fn core_generated_derived_ord(value: CoreOrdinaryBodyPlan) -> CoreGeneratedPlan {
    CoreGeneratedPlan { value: CoreGeneratedPlanValue::GeneratedDerivedOrd(value) }
}
pub fn core_generated_derived_debug(value: CoreOrdinaryBodyPlan) -> CoreGeneratedPlan {
    CoreGeneratedPlan { value: CoreGeneratedPlanValue::GeneratedDerivedDebug(value) }
}
pub fn core_generated_derived_json(value: CoreOrdinaryBodyPlan) -> CoreGeneratedPlan {
    CoreGeneratedPlan { value: CoreGeneratedPlanValue::GeneratedDerivedJson(value) }
}

pub struct CoreAssemblyRecorder {
    module_key: Str,
    module_order: Int,
    type_nodes: List<FlowTypeNode>,
    callables: List<CoreCallableContract>,
    impls: List<CoreImplMetadata>,
    inventory_entries: List<ExecutableEntry>,
    manifests: List<BinderManifest>,
    source_bodies: List<CoreSourceBodyInput>,
    generated: List<CoreGeneratedPlan>,
    delegates: List<DelegateTypedPlan>,
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
        type_nodes: [], callables: [], impls: [], inventory_entries: [],
        manifests: [], source_bodies: [], generated: [], delegates: [],
        frozen: false
    }
}

fn require_recorder_open(value: CoreAssemblyRecorder) {
    if value.frozen { panic("Core assembly: recorder is frozen") }
}

pub fn record_core_type_node(
    mut recorder: CoreAssemblyRecorder, node: FlowTypeNode
) {
    require_recorder_open(recorder)
    let index = flow_type_ref_index(flow_type_node_reference(node))
    if recorder.type_nodes.len() > 0 && index <= flow_type_ref_index(
            flow_type_node_reference(recorder.type_nodes.last().unwrap())) {
        panic("Core assembly: type nodes are not globally ordered")
    }
    recorder.type_nodes.push(node)
}

pub fn record_core_callable(
    mut recorder: CoreAssemblyRecorder, value: CoreCallableContract
) {
    require_recorder_open(recorder)
    for existing in recorder.callables {
        if executable_ref_same(
                core_callable_reference(existing),
                core_callable_reference(value)) {
            panic("Core assembly: callable was recorded twice")
        }
    }
    recorder.callables.push(value)
}

pub fn record_core_impl(
    mut recorder: CoreAssemblyRecorder, value: CoreImplMetadata
) {
    require_recorder_open(recorder)
    for existing in recorder.impls {
        if impl_owner_ref_same(
                core_impl_owner(existing), core_impl_owner(value)) {
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
    recorder.generated.push(value)
}

pub fn record_core_delegate(
    mut recorder: CoreAssemblyRecorder, value: DelegateTypedPlan
) {
    require_recorder_open(recorder)
    recorder.delegates.push(value)
}

pub struct FrozenCoreAssemblyFacts {
    module_key: Str,
    module_order: Int,
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
        let (_metadata, bodies) = elaborate_delegate_to_core(delegate)
        for body in bodies { result.push(core_body_reference(body)) }
    }
    result
}

pub fn freeze_core_assembly_facts(
    mut recorder: CoreAssemblyRecorder
) -> FrozenCoreAssemblyFacts {
    require_recorder_open(recorder)
    recorder.frozen = true
    if recorder.inventory_entries.len() != recorder.callables.len() ||
       recorder.manifests.len() != recorder.callables.len() {
        panic("Core assembly: executable/callable/manifest census differs")
    }
    let body_refs = recorded_body_refs(recorder)
    let mut index = 0
    while index < recorder.inventory_entries.len() {
        let entry = recorder.inventory_entries.get(index).unwrap()
        let reference = executable_entry_reference(entry)
        if !executable_ref_same(
                reference,
                core_callable_reference(recorder.callables.get(index).unwrap())) ||
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
        type_nodes: recorder.type_nodes.map(fn(value) { value }),
        callables: copy_core_callables(recorder.callables),
        impls: copy_core_impl_metadata(recorder.impls),
        inventory_entries: recorder.inventory_entries.map(fn(value) { value }),
        manifests: recorder.manifests.map(fn(value) { value }),
        source_bodies: recorder.source_bodies.map(fn(value) { value }),
        generated: recorder.generated.map(fn(value) { value }),
        delegates: recorder.delegates.map(fn(value) { value })
    }
}

struct BodyCursor {
    input: CoreSourceBodyInput,
    expr_index: Int, stmt_index: Int, block_index: Int, pattern_index: Int
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
fn next_expr_fact(mut cursor: BodyCursor, expr: HExpr) -> CoreExprFact {
    let fact = match cursor.input.expr_facts.get(cursor.expr_index) {
        some(value) => value,
        none => panic("Core assembly: expression fact census is short")
    }
    cursor.expr_index = cursor.expr_index + 1
    if !types_equal(hexpr_type(expr), fact.source_type) ||
       !effect_rows_same(hexpr_effects(expr), fact.source_effects) {
        panic("Core assembly: HIR expression type/effect fact drifted")
    }
    fact
}
fn next_stmt_fact(mut cursor: BodyCursor) -> CoreStmtFact {
    let fact = cursor.input.stmt_facts.get(cursor.stmt_index).unwrap_or_else(fn() {
        panic("Core assembly: statement fact census is short")
    })
    cursor.stmt_index = cursor.stmt_index + 1
    fact
}
fn next_block_fact(mut cursor: BodyCursor) -> CoreBlockFact {
    let fact = cursor.input.block_facts.get(cursor.block_index).unwrap_or_else(fn() {
        panic("Core assembly: block fact census is short")
    })
    cursor.block_index = cursor.block_index + 1
    fact
}
fn next_pattern_fact(mut cursor: BodyCursor) -> CorePatternFact {
    let fact = cursor.input.pattern_facts.get(cursor.pattern_index).unwrap_or_else(fn() {
        panic("Core assembly: pattern fact census is short")
    })
    cursor.pattern_index = cursor.pattern_index + 1
    fact
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
            panic("Core assembly: legacy resource Clone crossed Core")
    }
}

fn lower_sequence_construct(
    mut cursor: BodyCursor, fact: CoreExprFact, values: List<HExpr>
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
    source: SlotRef, values: List<CoreDestructureBinding>
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
    plan: CoreForInPlan, origin: OriginRef
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
    plan: CoreIfLetPlan, origin: OriginRef
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
        input.manifest, input.scopes, input.slots,
        input.parameter_slots, input.result_type, block)
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

fn assemble_frozen_core_facts(
    facts: List<FrozenCoreAssemblyFacts>
) -> CoreProgram {
    if facts.len() == 0 { panic("Core assembly: project has no frozen facts") }
    let mut type_nodes: List<FlowTypeNode> = []
    let mut callables: List<CoreCallableContract> = []
    let mut impls: List<CoreImplMetadata> = []
    let mut inventory_entries: List<ExecutableEntry> = []
    let mut manifests: List<BinderManifest> = []
    let mut source_bodies: List<CoreSourceBodyInput> = []
    let mut generated_plans: List<CoreGeneratedPlan> = []
    let mut delegates: List<DelegateTypedPlan> = []
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
        for node in fact.type_nodes { type_nodes.push(node) }
        for callable in fact.callables { callables.push(callable) }
        for item in fact.impls { impls.push(item) }
        for entry in fact.inventory_entries { inventory_entries.push(entry) }
        for manifest in fact.manifests { manifests.push(manifest) }
        for body in fact.source_bodies { source_bodies.push(body) }
        for generated in fact.generated { generated_plans.push(generated) }
        for delegate in fact.delegates { delegates.push(delegate) }
        fact_index = fact_index + 1
    }
    let type_graph = make_core_type_graph(type_nodes)
    let inventory = make_executable_inventory(inventory_entries)
    let mut body_pool: List<CoreBodyEntry> = []
    for source in source_bodies {
        let hir = source.source
        body_pool.push(assemble_source_body(
            source, hir, type_graph))
    }
    for generated in generated_plans {
        body_pool.push(entry_for_body(
            materialize_generated(generated), inventory))
    }
    let mut all_impls = copy_core_impl_metadata(impls)
    for delegate in delegates {
        let (metadata, bodies) = elaborate_delegate_to_core(delegate)
        all_impls.push(metadata)
        for body in bodies {
            body_pool.push(entry_for_body(body, inventory))
        }
    }
    let ordered = order_entries_by_inventory(body_pool, inventory)
    make_core_program(
        type_graph, callables, all_impls, ordered,
        inventory, manifests)
}

pub fn assemble_single_core(facts: FrozenCoreAssemblyFacts) -> CoreProgram {
    if facts.module_order != 0 {
        panic("Core assembly: single module order is not zero")
    }
    assemble_frozen_core_facts([facts])
}

pub fn assemble_project_core(
    facts_in_topological_order: List<FrozenCoreAssemblyFacts>
) -> CoreProgram {
    assemble_frozen_core_facts(facts_in_topological_order)
}
