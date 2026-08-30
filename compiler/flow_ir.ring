// FlowIR: the first ownership-neutral, fixed-topology compiler IR.
//
// Every public value has a private representation.  Construction accepts only
// exact typed references already selected by CoreHIR.  This module never reads
// HProgram/HExpr, resolves a spelling, generates a semantic executable, inserts
// a resource operation, or chooses an ABI/layout.  `make_flow_program` is the
// single freeze barrier: after it returns, the ordered type/callable/body/slot/
// block topology is immutable and can be consumed mechanically by the resource
// planner.

use ir_identity::{
    CoreTypeRef, make_core_type_ref,
    core_type_ref_index, core_type_ref_same,
    SymbolRef, PathRef, PathOwnerRef, SlotRef, ImplOwnerRef,
    NominalFieldRef, VariantRef, VariantFieldRef,
    HandledEffectRef, SystemEffectRef,
    handled_effect_ref_same, handled_effect_ref_symbol,
    system_effect_ref_same, system_effect_ref_tag,
    symbol_ref_same, symbol_ref_origin_module_key,
    symbol_ref_namespace_kind, symbol_ref_canonical_payload,
    symbol_ref_declaration_site_path,
    namespace_kind_tag, namespace_kind_same, namespace_nominal,
    namespace_trait,
    path_ref_same, path_ref_owner, path_ref_normalized_child_path,
    path_ref_role, path_role_tag,
    path_owner_ref_is_symbol, path_owner_ref_symbol,
    path_owner_ref_module_body,
    module_body_ref_origin_module_key,
    module_body_ref_declaration_site_path,
    slot_ref_same, slot_ref_is_source,
    slot_ref_source_origin_module_key, slot_ref_source_domain,
    slot_ref_source_def_id, slot_ref_synthetic_path,
    slot_domain_tag, slot_domain_dictionary, slot_domain_same,
    nominal_field_ref_same, nominal_field_ref_owner,
    nominal_field_ref_member, nominal_field_ref_index,
    variant_field_ref_same, variant_field_ref_variant,
    variant_field_ref_member, variant_field_ref_index,
    variant_ref_owner, variant_ref_same,
    variant_ref_member, variant_ref_source_index,
    builtin_option_none_variant_ref,
    registered_nominal_ref_symbol,
    impl_owner_ref_target, impl_owner_ref_provider, impl_owner_ref_trait,
    impl_provider_ref_site, impl_provider_ref_kind, impl_provider_kind_tag,
    OriginRef, origin_ref_is_symbol, origin_ref_symbol, origin_ref_path,
    origin_ref_same
}
use ir_inventory::{
    ExecutableRef, ExactDictRef,
    dict_ref_is_local, dict_ref_is_static, dict_ref_is_wrapped,
    dict_ref_local, dict_ref_static,
    dict_ref_wrapped_base, dict_ref_wrapped_inner,
    executable_ref_same, executable_ref_is_named,
    executable_ref_named_symbol, executable_ref_anonymous_path,
    executable_ref_origin_module_key,
    EffectOperationRef, effect_operation_ref_member,
    effect_operation_ref_callable,
    effect_operation_ref_same, effect_operation_ref_effect,
    effect_operation_ref_source_index,
    EffectCtxRef, EffectCtxParentCapture,
    effect_ctx_slot, effect_ctx_contract_owner, effect_ctx_ref_same,
    effect_ctx_parent_capture_source, effect_ctx_parent_capture_target,
    ExecutableContractMode, executable_contract_mode_same,
    executable_contract_mode_concrete_body,
    executable_contract_mode_contract_only,
    BinderManifest, BinderEntry,
    binder_manifest_owner, binder_manifest_entries,
    binder_entry_slot, binder_entry_kind, binder_kind_tag,
    binder_kind_scope_result, make_binder_manifest
}
use core_expr::{
    CoreEffectCtxTokenRef, CoreEffectCtxLayout, CoreCallableEffectCtx,
    CoreEffectCtxArgument, CoreEffectCtxLookup,
    core_effect_ctx_token_instance, core_effect_ctx_token_same,
    core_effect_ctx_layout_entries, core_effect_ctx_layout_formal,
    core_effect_ctx_layout_same,
    core_callable_effect_ctx_reference, core_callable_effect_ctx_layout,
    core_callable_effect_ctx_type,
    core_effect_ctx_argument_kind_tag, core_effect_ctx_argument_context,
    core_effect_ctx_argument_source_layout,
    core_effect_ctx_argument_target_layout,
    core_effect_ctx_argument_receipt,
    core_effect_ctx_lookup_context, core_effect_ctx_lookup_layout,
    core_effect_ctx_lookup_token
}
use effect_contract::{
    EffectParamRef,
    effect_param_owner, effect_param_ref_same,
    effect_param_ordinal,
    CoreEffectAtom, CoreEffectContract, CoreEffectSubstitution,
    CoreEffectInstantiation,
    make_core_fail_effect, make_core_mut_effect, make_core_unsafe_effect,
    make_core_handled_effect, make_core_system_effect,
    core_effect_atom_kind_tag, core_effect_atom_type,
    core_effect_atom_handled_ref, core_effect_atom_type_arguments,
    core_effect_atom_system_ref, core_effect_atom_same,
    make_core_effect_set, core_effect_set_atoms,
    make_core_effect_contract, core_effect_contract_exact,
    core_effect_contract_parameter, core_effect_contract_same,
    copy_core_effect_contract,
    make_core_effect_substitution, core_effect_substitution_parameter,
    core_effect_substitution_replacement,
    make_core_effect_instantiation,
    make_explicit_core_effect_instantiation,
    core_effect_instantiation_source,
    core_effect_instantiation_substitutions,
    core_effect_instantiation_result,
}
use core_type_source::{
    FlowTypeNode, FlowFieldIdentity, FlowNominalFieldFact,
    FlowTypeSubstitution, copy_flow_type_substitutions,
    flow_type_substitution_parameter,
    flow_type_substitution_replacement,
    flow_generic_param_owner, flow_generic_param_index,
    flow_generic_param_arity, flow_generic_param_bounds,
    flow_generic_param_fact_same,
    flow_type_node_generic_param, flow_type_node_children,
    flow_type_actual_satisfies_substituted_formal,
    flow_effect_actual_satisfies_substituted_formal,
    core_effect_instantiation_projects_substitutions,
    FLOW_TYPE_INT, FLOW_TYPE_FLOAT, FLOW_TYPE_STR, FLOW_TYPE_BOOL,
    FLOW_TYPE_UNIT, FLOW_TYPE_NEVER, FLOW_TYPE_STRUCT, FLOW_TYPE_ENUM,
    FLOW_TYPE_TUPLE, FLOW_TYPE_RECORD, FLOW_TYPE_CALLABLE,
    FLOW_TYPE_PTR, FLOW_TYPE_PARAMETER, FLOW_TYPE_EXTERN,
    flow_type_kind_tag, flow_type_kind_callable, flow_type_kind_same,
    flow_field_identity_is_nominal, flow_field_identity_nominal,
    flow_field_identity_is_variant, flow_field_identity_variant,
    flow_field_identity_path, flow_field_identity_same,
    make_nominal_flow_field_identity, make_variant_flow_field_identity,
    flow_type_actual_satisfies_formal,
    validate_flow_type_graph_nodes, copy_flow_type_graph_nodes
}
use resource_model::{
    FlowTypeSemanticSeed,
    flow_type_seed_scalar, flow_type_seed_ptr,
    flow_type_seed_unique, flow_type_seed_shareable,
    flow_type_seed_extern, flow_type_seed_parametric,
    flow_type_semantic_seed_tag,
    FlowSemanticRole, flow_semantic_role_read,
    flow_semantic_role_mutate, flow_semantic_role_consume,
    flow_semantic_role_force, flow_semantic_role_tag,
    copy_semantic_roles,
    FlowValueOriginContract, make_fresh_flow_value_origin,
    make_aliasing_flow_value_origin, flow_value_origin_is_fresh,
    flow_value_origin_alias_ordinals, copy_value_origin,
    value_origin_same, validate_value_origin_arity,
    FlowCallContract, make_flow_call_contract,
    make_module_flow_call_contract, flow_call_contract_module_key,
    flow_call_contract_parameter_types,
    flow_call_contract_parameter_roles,
    flow_call_contract_result_role, flow_call_contract_result_type,
    flow_call_contract_result_origin, flow_call_contract_same,
    copy_call_contract,
    FlowStorageContract, flow_own_storage, flow_borrow_storage,
    flow_storage_contract_tag
}

// ============================================================
// Finite, exact type graph
// ============================================================

enum FlowEffectCtxUseValue {
    ForeignLeafEffectCtxUse,
    ArgumentEffectCtxUse(CoreEffectCtxArgument),
    LookupEffectCtxUse(CoreEffectCtxLookup)
}
pub struct FlowEffectCtxUse { value: FlowEffectCtxUseValue }
pub fn make_foreign_leaf_flow_effect_ctx_use() -> FlowEffectCtxUse {
    FlowEffectCtxUse { value: FlowEffectCtxUseValue::ForeignLeafEffectCtxUse }
}
pub fn make_argument_flow_effect_ctx_use(
    argument: CoreEffectCtxArgument
) -> FlowEffectCtxUse {
    FlowEffectCtxUse {
        value: FlowEffectCtxUseValue::ArgumentEffectCtxUse(argument)
    }
}
pub fn make_lookup_flow_effect_ctx_use(
    lookup: CoreEffectCtxLookup
) -> FlowEffectCtxUse {
    FlowEffectCtxUse {
        value: FlowEffectCtxUseValue::LookupEffectCtxUse(lookup)
    }
}
pub fn flow_effect_ctx_use_kind_tag(value: FlowEffectCtxUse) -> Int {
    match value.value {
        FlowEffectCtxUseValue::ForeignLeafEffectCtxUse => 0,
        FlowEffectCtxUseValue::ArgumentEffectCtxUse(_) => 1,
        FlowEffectCtxUseValue::LookupEffectCtxUse(_) => 2
    }
}
pub fn flow_effect_ctx_use_argument(
    value: FlowEffectCtxUse
) -> CoreEffectCtxArgument {
    match value.value {
        FlowEffectCtxUseValue::ArgumentEffectCtxUse(argument) => argument,
        _ => panic("FlowIR: EffectCtx use is not an argument")
    }
}
pub fn flow_effect_ctx_use_lookup(
    value: FlowEffectCtxUse
) -> CoreEffectCtxLookup {
    match value.value {
        FlowEffectCtxUseValue::LookupEffectCtxUse(lookup) => lookup,
        _ => panic("FlowIR: EffectCtx use is not a lookup")
    }
}
pub fn flow_effect_ctx_use_borrowed_slot(
    value: FlowEffectCtxUse
) -> SlotRef? {
    match value.value {
        FlowEffectCtxUseValue::ForeignLeafEffectCtxUse => none,
        FlowEffectCtxUseValue::ArgumentEffectCtxUse(argument) =>
            if core_effect_ctx_argument_kind_tag(argument) == 0 { none }
            else { some(effect_ctx_slot(
                core_effect_ctx_argument_context(argument))) },
        FlowEffectCtxUseValue::LookupEffectCtxUse(lookup) =>
            some(effect_ctx_slot(core_effect_ctx_lookup_context(lookup)))
    }
}

pub struct FlowCallable {
    reference: ExecutableRef,
    origin: OriginRef,
    header_type: CoreTypeRef,
    type_formals: List<CoreTypeRef>,
    effect_formals: List<EffectParamRef>,
    parameter_slots: List<SlotRef>,
    mode: ExecutableContractMode,
    semantic_contract: FlowCallContract,
    effects: CoreEffectContract,
    effect_ctx: CoreCallableEffectCtx?
}

pub fn make_flow_callable(
    reference: ExecutableRef, origin: OriginRef,
    header_type: CoreTypeRef, type_formals: List<CoreTypeRef>,
    effect_formals: List<EffectParamRef>,
    parameter_slots: List<SlotRef>, mode: ExecutableContractMode,
    semantic_contract: FlowCallContract,
    effects: CoreEffectContract,
    effect_ctx: CoreCallableEffectCtx?
) -> FlowCallable {
    if core_type_ref_index(header_type) < 0 {
        panic("FlowIR: callable header type is invalid")
    }
    let mut formal_index = 0
    while formal_index < type_formals.len() {
        let formal = type_formals.get(formal_index).unwrap()
        if core_type_ref_index(formal) < 0 {
            panic("FlowIR: callable type formal is invalid")
        }
        let mut right = formal_index + 1
        while right < type_formals.len() {
            if core_type_ref_same(formal, type_formals.get(right).unwrap()) {
                panic("FlowIR: callable repeats a type formal")
            }
            right = right + 1
        }
        formal_index = formal_index + 1
    }
    let mut effect_index = 0
    while effect_index < effect_formals.len() {
        let formal = effect_formals.get(effect_index).unwrap()
        if !origin_ref_same(effect_param_owner(formal), origin) ||
           effect_param_ordinal(formal) != effect_index {
            panic("FlowIR: callable effect formal owner/order differs")
        }
        effect_index = effect_index + 1
    }
    let concrete = executable_contract_mode_same(
        mode, executable_contract_mode_concrete_body())
    if (concrete && parameter_slots.len() !=
            flow_call_contract_parameter_types(semantic_contract).len()) ||
       (!concrete && parameter_slots.len() != 0) {
        panic("FlowIR: callable parameter slot relation is not total")
    }
    let mut left_index = 0
    while left_index < parameter_slots.len() {
        let mut right_index = left_index + 1
        while right_index < parameter_slots.len() {
            if slot_ref_same(
                    parameter_slots.get(left_index).unwrap(),
                    parameter_slots.get(right_index).unwrap()) {
                panic("FlowIR: callable repeats a parameter slot")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    FlowCallable {
        reference: reference, origin: origin,
        header_type: header_type,
        type_formals: type_formals.map(fn(value) { value }),
        effect_formals: effect_formals.map(fn(value) { value }),
        parameter_slots: copy_slot_refs(parameter_slots),
        mode: mode,
        semantic_contract: copy_call_contract(semantic_contract),
        effects: copy_core_effect_contract(effects),
        effect_ctx: effect_ctx
    }
}

pub fn flow_callable_reference(value: FlowCallable) -> ExecutableRef { value.reference }
pub fn flow_callable_origin(value: FlowCallable) -> OriginRef { value.origin }
pub fn flow_callable_parameter_types(value: FlowCallable) -> List<CoreTypeRef> {
    flow_call_contract_parameter_types(value.semantic_contract)
}
pub fn flow_callable_parameter_slots(value: FlowCallable) -> List<SlotRef> {
    copy_slot_refs(value.parameter_slots)
}
pub fn flow_callable_result_type(value: FlowCallable) -> CoreTypeRef {
    flow_call_contract_result_type(value.semantic_contract)
}
pub fn flow_callable_mode(
    value: FlowCallable
) -> ExecutableContractMode { value.mode }
pub fn flow_callable_parameter_role_lower_bounds(
    value: FlowCallable
) -> List<FlowSemanticRole> {
    flow_call_contract_parameter_roles(value.semantic_contract)
}
pub fn flow_callable_semantic_contract(value: FlowCallable) -> FlowCallContract {
    copy_call_contract(value.semantic_contract)
}
pub fn flow_callable_effect_contract(
    value: FlowCallable
) -> CoreEffectContract { copy_core_effect_contract(value.effects) }
pub fn flow_callable_effect_ctx(
    value: FlowCallable
) -> CoreCallableEffectCtx? { value.effect_ctx }

// ============================================================
// Body-local frozen identities, scopes, and slots
// ============================================================

pub struct FlowScopeRef {
    owner: ExecutableRef,
    ordinal: Int
}

pub fn make_flow_scope_ref(
    owner: ExecutableRef, ordinal: Int
) -> FlowScopeRef {
    if ordinal < 0 { panic("FlowIR: negative scope ordinal") }
    FlowScopeRef { owner: owner, ordinal: ordinal }
}

pub fn flow_scope_ref_owner(value: FlowScopeRef) -> ExecutableRef { value.owner }
pub fn flow_scope_ref_ordinal(value: FlowScopeRef) -> Int { value.ordinal }
pub fn flow_scope_ref_same(left: FlowScopeRef, right: FlowScopeRef) -> Bool {
    executable_ref_same(left.owner, right.owner) && left.ordinal == right.ordinal
}

pub struct FlowScope {
    reference: FlowScopeRef,
    parent: FlowScopeRef?
}

pub fn make_flow_root_scope(reference: FlowScopeRef) -> FlowScope {
    if reference.ordinal != 0 {
        panic("FlowIR: root scope does not have ordinal zero")
    }
    FlowScope { reference: reference, parent: none }
}

pub fn make_flow_child_scope(
    reference: FlowScopeRef, parent: FlowScopeRef
) -> FlowScope {
    if !executable_ref_same(reference.owner, parent.owner) ||
       reference.ordinal <= parent.ordinal {
        panic("FlowIR: child scope owner/order is invalid")
    }
    FlowScope { reference: reference, parent: some(parent) }
}

pub fn flow_scope_reference(value: FlowScope) -> FlowScopeRef { value.reference }
pub fn flow_scope_has_parent(value: FlowScope) -> Bool { value.parent.is_some() }
pub fn flow_scope_parent(value: FlowScope) -> FlowScopeRef {
    match value.parent {
        some(parent) => parent,
        none => panic("FlowIR: root scope has no parent")
    }
}

fn copy_scopes(values: List<FlowScope>) -> List<FlowScope> {
    let mut result: List<FlowScope> = []
    for value in values {
        result.push(FlowScope {
            reference: value.reference, parent: value.parent
        })
    }
    result
}

const FLOW_SLOT_EMPTY: Int = 0
const FLOW_SLOT_LIVE: Int = 1

pub struct FlowInitialSlotState { tag: Int }

fn flow_initial_slot_state_from_tag(tag: Int) -> FlowInitialSlotState {
    if tag < FLOW_SLOT_EMPTY || tag > FLOW_SLOT_LIVE {
        panic("FlowIR: invalid initial slot state")
    }
    FlowInitialSlotState { tag: tag }
}

pub fn flow_initial_slot_empty() -> FlowInitialSlotState {
    flow_initial_slot_state_from_tag(FLOW_SLOT_EMPTY)
}
pub fn flow_initial_slot_live() -> FlowInitialSlotState {
    flow_initial_slot_state_from_tag(FLOW_SLOT_LIVE)
}
pub fn flow_initial_slot_state_tag(value: FlowInitialSlotState) -> Int {
    flow_initial_slot_state_from_tag(value.tag).tag
}

const FLOW_STORAGE_PARAMETER: Int = 0
const FLOW_STORAGE_LOCAL: Int = 1
const FLOW_STORAGE_TEMP: Int = 2
const FLOW_STORAGE_RESULT: Int = 3
const FLOW_STORAGE_CAPTURE: Int = 4
const FLOW_STORAGE_CONTEXT: Int = 5

pub struct FlowStorageClass { tag: Int }

fn flow_storage_class_from_tag(tag: Int) -> FlowStorageClass {
    if tag < FLOW_STORAGE_PARAMETER || tag > FLOW_STORAGE_CONTEXT {
        panic("FlowIR: invalid storage class")
    }
    FlowStorageClass { tag: tag }
}

pub fn flow_storage_parameter() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_PARAMETER)
}
pub fn flow_storage_local() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_LOCAL)
}
pub fn flow_storage_temp() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_TEMP)
}
pub fn flow_storage_result() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_RESULT)
}
pub fn flow_storage_capture() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_CAPTURE)
}
pub fn flow_storage_context() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_CONTEXT)
}
pub fn flow_storage_class_tag(value: FlowStorageClass) -> Int {
    flow_storage_class_from_tag(value.tag).tag
}
pub fn flow_storage_class_same(
    left: FlowStorageClass, right: FlowStorageClass
) -> Bool { left.tag == right.tag }

pub struct FlowSlot {
    reference: SlotRef,
    ty: CoreTypeRef,
    scope: FlowScopeRef,
    reverse_ordinal: Int,
    initial_state: FlowInitialSlotState,
    storage: FlowStorageClass,
    storage_contract: FlowStorageContract,
    parameter_ordinal: Int?
}

pub fn make_flow_slot(
    reference: SlotRef, ty: CoreTypeRef, scope: FlowScopeRef,
    reverse_ordinal: Int, initial_state: FlowInitialSlotState,
    storage: FlowStorageClass, storage_contract: FlowStorageContract,
    parameter_ordinal: Int?
) -> FlowSlot {
    if reverse_ordinal < 0 {
        panic("FlowIR: negative reverse lexical slot ordinal")
    }
    if flow_storage_class_same(storage, flow_storage_parameter()) {
        match parameter_ordinal {
            some(ordinal) => if ordinal < 0 {
                panic("FlowIR: negative parameter ordinal")
            },
            none => panic("FlowIR: parameter storage lacks exact ordinal")
        }
    } else if parameter_ordinal.is_some() {
        panic("FlowIR: non-parameter storage carries parameter ordinal")
    }
    FlowSlot {
        reference: reference, ty: ty, scope: scope,
        reverse_ordinal: reverse_ordinal,
        initial_state: flow_initial_slot_state_from_tag(initial_state.tag),
        storage: flow_storage_class_from_tag(storage.tag),
        storage_contract: storage_contract,
        parameter_ordinal: parameter_ordinal
    }
}

pub fn flow_slot_reference(value: FlowSlot) -> SlotRef { value.reference }
pub fn flow_slot_type(value: FlowSlot) -> CoreTypeRef { value.ty }
pub fn flow_slot_scope(value: FlowSlot) -> FlowScopeRef { value.scope }
pub fn flow_slot_reverse_ordinal(value: FlowSlot) -> Int { value.reverse_ordinal }
pub fn flow_slot_initial_state(value: FlowSlot) -> FlowInitialSlotState {
    value.initial_state
}
pub fn flow_slot_storage(value: FlowSlot) -> FlowStorageClass { value.storage }
pub fn flow_slot_storage_contract(value: FlowSlot) -> FlowStorageContract {
    value.storage_contract
}
pub fn flow_slot_parameter_ordinal(value: FlowSlot) -> Int {
    match value.parameter_ordinal {
        some(ordinal) => ordinal,
        none => panic("FlowIR: non-parameter slot has no parameter ordinal")
    }
}

fn copy_flow_slots(values: List<FlowSlot>) -> List<FlowSlot> {
    let mut result: List<FlowSlot> = []
    for value in values {
        result.push(FlowSlot {
            reference: value.reference, ty: value.ty, scope: value.scope,
            reverse_ordinal: value.reverse_ordinal,
            initial_state: value.initial_state, storage: value.storage,
            storage_contract: value.storage_contract,
            parameter_ordinal: value.parameter_ordinal
        })
    }
    result
}

pub struct FlowBlockRef {
    owner: ExecutableRef,
    ordinal: Int
}

pub fn make_flow_block_ref(
    owner: ExecutableRef, ordinal: Int
) -> FlowBlockRef {
    if ordinal < 0 { panic("FlowIR: negative block ordinal") }
    FlowBlockRef { owner: owner, ordinal: ordinal }
}

pub fn flow_block_ref_owner(value: FlowBlockRef) -> ExecutableRef { value.owner }
pub fn flow_block_ref_ordinal(value: FlowBlockRef) -> Int { value.ordinal }
pub fn flow_block_ref_same(left: FlowBlockRef, right: FlowBlockRef) -> Bool {
    executable_ref_same(left.owner, right.owner) && left.ordinal == right.ordinal
}

pub struct FlowInstructionRef {
    owner: ExecutableRef,
    block_ordinal: Int,
    instruction_ordinal: Int
}

pub fn make_flow_instruction_ref(
    owner: ExecutableRef, block_ordinal: Int, instruction_ordinal: Int
) -> FlowInstructionRef {
    if block_ordinal < 0 || instruction_ordinal < 0 {
        panic("FlowIR: negative instruction site ordinal")
    }
    FlowInstructionRef {
        owner: owner, block_ordinal: block_ordinal,
        instruction_ordinal: instruction_ordinal
    }
}

pub fn flow_instruction_ref_owner(value: FlowInstructionRef) -> ExecutableRef {
    value.owner
}
pub fn flow_instruction_ref_block_ordinal(value: FlowInstructionRef) -> Int {
    value.block_ordinal
}
pub fn flow_instruction_ref_ordinal(value: FlowInstructionRef) -> Int {
    value.instruction_ordinal
}
pub fn flow_instruction_ref_same(
    left: FlowInstructionRef, right: FlowInstructionRef
) -> Bool {
    executable_ref_same(left.owner, right.owner) &&
        left.block_ordinal == right.block_ordinal &&
        left.instruction_ordinal == right.instruction_ordinal
}

// ============================================================
// Exact call target and ownership-neutral instructions
// ============================================================

enum FlowCallTargetValue {
    DirectTargetValue(ExecutableRef),
    LocalTargetValue(SlotRef),
    DynamicTargetValue(PathRef)
}

pub struct FlowCallTarget {
    value: FlowCallTargetValue,
    contract: FlowCallContract,
    type_substitutions: List<FlowTypeSubstitution>,
    effect_substitutions: List<CoreEffectSubstitution>,
    effects: CoreEffectInstantiation
}

pub fn make_direct_flow_call_target(
    target: ExecutableRef, contract: FlowCallContract,
    type_substitutions: List<FlowTypeSubstitution>,
    effect_substitutions: List<CoreEffectSubstitution>,
    effects: CoreEffectInstantiation
) -> FlowCallTarget {
    FlowCallTarget {
        value: FlowCallTargetValue::DirectTargetValue(target),
        contract: copy_call_contract(contract),
        type_substitutions: copy_flow_type_substitutions(type_substitutions),
        effect_substitutions: effect_substitutions.map(fn(item) {
            make_core_effect_substitution(
                core_effect_substitution_parameter(item),
                core_effect_substitution_replacement(item))
        }),
        effects: effects
    }
}

pub fn make_local_flow_call_target(
    target: SlotRef, contract: FlowCallContract,
    effects: CoreEffectInstantiation
) -> FlowCallTarget {
    FlowCallTarget {
        value: FlowCallTargetValue::LocalTargetValue(target),
        contract: copy_call_contract(contract), type_substitutions: [],
        effect_substitutions: [],
        effects: effects
    }
}

pub fn make_dynamic_flow_call_target(
    target: PathRef, contract: FlowCallContract,
    effects: CoreEffectInstantiation
) -> FlowCallTarget {
    FlowCallTarget {
        value: FlowCallTargetValue::DynamicTargetValue(target),
        contract: copy_call_contract(contract), type_substitutions: [],
        effect_substitutions: [],
        effects: effects
    }
}

pub fn flow_call_target_is_direct(value: FlowCallTarget) -> Bool {
    match value.value {
        FlowCallTargetValue::DirectTargetValue(_) => true,
        _ => false
    }
}
pub fn flow_call_target_is_local(value: FlowCallTarget) -> Bool {
    match value.value {
        FlowCallTargetValue::LocalTargetValue(_) => true,
        _ => false
    }
}
pub fn flow_call_target_direct(value: FlowCallTarget) -> ExecutableRef {
    match value.value {
        FlowCallTargetValue::DirectTargetValue(target) => target,
        _ => panic("FlowIR: non-direct call target has no ExecutableRef")
    }
}
pub fn flow_call_target_local(value: FlowCallTarget) -> SlotRef {
    match value.value {
        FlowCallTargetValue::LocalTargetValue(target) => target,
        _ => panic("FlowIR: non-local call target has no SlotRef")
    }
}
pub fn flow_call_target_dynamic(value: FlowCallTarget) -> PathRef {
    match value.value {
        FlowCallTargetValue::DynamicTargetValue(target) => target,
        _ => panic("FlowIR: non-dynamic call target has no PathRef")
    }
}
pub fn flow_call_target_contract(value: FlowCallTarget) -> FlowCallContract {
    copy_call_contract(value.contract)
}
pub fn flow_call_target_type_substitutions(
    value: FlowCallTarget
) -> List<FlowTypeSubstitution> {
    copy_flow_type_substitutions(value.type_substitutions)
}
pub fn flow_call_target_effect_substitutions(
    value: FlowCallTarget
) -> List<CoreEffectSubstitution> {
    value.effect_substitutions.map(fn(item) {
        make_core_effect_substitution(
            core_effect_substitution_parameter(item),
            core_effect_substitution_replacement(item))
    })
}
pub fn flow_call_target_effect_instantiation(
    value: FlowCallTarget
) -> CoreEffectInstantiation {
    make_core_effect_instantiation(
        core_effect_instantiation_source(value.effects),
        core_effect_instantiation_substitutions(value.effects),
        core_effect_instantiation_result(value.effects))
}
fn flow_call_target_same(
    left: FlowCallTarget, right: FlowCallTarget
) -> Bool {
    let left_source = core_effect_instantiation_source(left.effects)
    let right_source = core_effect_instantiation_source(right.effects)
    let left_result = core_effect_instantiation_result(left.effects)
    let right_result = core_effect_instantiation_result(right.effects)
    let left_substitutions = core_effect_instantiation_substitutions(left.effects)
    let right_substitutions = core_effect_instantiation_substitutions(right.effects)
    if !flow_call_contract_same(left.contract, right.contract) ||
       !core_effect_contract_same(left_source, right_source) ||
       !core_effect_contract_same(left_result, right_result) ||
       left_substitutions.len() != right_substitutions.len() ||
       left.type_substitutions.len() != right.type_substitutions.len() {
        return false
    }
    let mut substitution_index = 0
    while substitution_index < left.type_substitutions.len() {
        let a = left.type_substitutions.get(substitution_index).unwrap()
        let b = right.type_substitutions.get(substitution_index).unwrap()
        let ap = flow_type_substitution_parameter(a)
        let bp = flow_type_substitution_parameter(b)
        if !symbol_ref_same(
                flow_generic_param_owner(ap), flow_generic_param_owner(bp)) ||
           flow_generic_param_index(ap) != flow_generic_param_index(bp) ||
           flow_generic_param_arity(ap) != flow_generic_param_arity(bp) ||
           !core_type_ref_same(
                flow_type_substitution_replacement(a),
                flow_type_substitution_replacement(b)) {
            return false
        }
        substitution_index = substitution_index + 1
    }
    substitution_index = 0
    while substitution_index < left_substitutions.len() {
        let a = left_substitutions.get(substitution_index).unwrap()
        let b = right_substitutions.get(substitution_index).unwrap()
        if !effect_param_ref_same(
                core_effect_substitution_parameter(a),
                core_effect_substitution_parameter(b)) ||
           !core_effect_contract_same(
                core_effect_substitution_replacement(a),
                core_effect_substitution_replacement(b)) {
            return false
        }
        substitution_index = substitution_index + 1
    }
    match (left.value, right.value) {
        (FlowCallTargetValue::DirectTargetValue(a),
         FlowCallTargetValue::DirectTargetValue(b)) => executable_ref_same(a, b),
        (FlowCallTargetValue::LocalTargetValue(a),
         FlowCallTargetValue::LocalTargetValue(b)) => slot_ref_same(a, b),
        (FlowCallTargetValue::DynamicTargetValue(a),
         FlowCallTargetValue::DynamicTargetValue(b)) => path_ref_same(a, b),
        _ => false
    }
}

fn copy_call_target(value: FlowCallTarget) -> FlowCallTarget {
    FlowCallTarget {
        value: value.value, contract: copy_call_contract(value.contract),
        type_substitutions:
            copy_flow_type_substitutions(value.type_substitutions),
        effect_substitutions: value.effect_substitutions.map(fn(item) {
            make_core_effect_substitution(
                core_effect_substitution_parameter(item),
                core_effect_substitution_replacement(item))
        }),
        effects: make_core_effect_instantiation(
            core_effect_instantiation_source(value.effects),
            core_effect_instantiation_substitutions(value.effects),
            core_effect_instantiation_result(value.effects))
    }
}

enum FlowEvidenceRefValue {
    FlowDictEvidenceValue(ExactDictRef)
}
pub struct FlowEvidenceRef { value: FlowEvidenceRefValue }
pub fn make_flow_dict_evidence(value: ExactDictRef) -> FlowEvidenceRef {
    FlowEvidenceRef { value: FlowEvidenceRefValue::FlowDictEvidenceValue(value) }
}
pub fn flow_evidence_dict(value: FlowEvidenceRef) -> ExactDictRef {
    match value.value {
        FlowEvidenceRefValue::FlowDictEvidenceValue(dict) => dict,
        _ => panic("FlowIR: non-dict evidence has no DictRef")
    }
}
fn copy_flow_evidence(values: List<FlowEvidenceRef>) -> List<FlowEvidenceRef> {
    let mut result: List<FlowEvidenceRef> = []
    for value in values { result.push(value) }
    result
}

const FLOW_PRIMITIVE_ADD: Int = 0
const FLOW_PRIMITIVE_SUB: Int = 1
const FLOW_PRIMITIVE_MUL: Int = 2
const FLOW_PRIMITIVE_DIV: Int = 3
const FLOW_PRIMITIVE_MOD: Int = 4
const FLOW_PRIMITIVE_NEGATE: Int = 5
const FLOW_PRIMITIVE_NOT: Int = 6
const FLOW_PRIMITIVE_LT: Int = 7
const FLOW_PRIMITIVE_LE: Int = 8
const FLOW_PRIMITIVE_GT: Int = 9
const FLOW_PRIMITIVE_GE: Int = 10

pub struct FlowPrimitiveOp { tag: Int }

fn flow_primitive_op_from_tag(tag: Int) -> FlowPrimitiveOp {
    if tag < FLOW_PRIMITIVE_ADD || tag > FLOW_PRIMITIVE_GE {
        panic("FlowIR: invalid 0.1 primitive operation")
    }
    FlowPrimitiveOp { tag: tag }
}
pub fn flow_primitive_add() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_ADD) }
pub fn flow_primitive_sub() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_SUB) }
pub fn flow_primitive_mul() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_MUL) }
pub fn flow_primitive_div() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_DIV) }
pub fn flow_primitive_mod() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_MOD) }
pub fn flow_primitive_negate() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_NEGATE) }
pub fn flow_primitive_not() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_NOT) }
pub fn flow_primitive_lt() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_LT) }
pub fn flow_primitive_le() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_LE) }
pub fn flow_primitive_gt() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_GT) }
pub fn flow_primitive_ge() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_GE) }
pub fn flow_primitive_op_tag(value: FlowPrimitiveOp) -> Int {
    flow_primitive_op_from_tag(value.tag).tag
}

enum FlowOperationValue {
    IntLiteralOperationValue(Int),
    FloatLiteralOperationValue(Float),
    StrLiteralOperationValue(Str),
    BoolLiteralOperationValue(Bool),
    UnitLiteralOperationValue,
    PrimitiveOperationValue(FlowPrimitiveOp),
    VariantConstructOperationValue(VariantRef),
    EffectCtxOverlayOperationValue {
        parent: EffectCtxRef,
        child: EffectCtxRef,
        entries: List<CoreEffectCtxTokenRef>
    },
    TupleAggregateOperationValue(Int),
    RecordAggregateOperationValue(Int),
    ClosureOperationValue {
        executable: ExecutableRef, capture_targets: List<SlotRef>
    },
    CallableValueOperationValue {
        executable: ExecutableRef,
        evidence: List<FlowEvidenceRef>,
        type_substitutions: List<FlowTypeSubstitution>,
        effect_substitutions: List<CoreEffectSubstitution>,
        effects: CoreEffectInstantiation
    },
    DictConstructOperationValue {
        dictionary: ExactDictRef,
        result: SlotRef
    }
}

enum FlowAggregateInputValue {
    NominalAggregateInputValue(NominalFieldRef),
    VariantAggregateInputValue(VariantFieldRef),
    TupleAggregateInputValue(Int),
    StructuralAggregateInputValue(PathRef)
}

pub struct FlowAggregateInputRef { value: FlowAggregateInputValue }
pub fn make_nominal_flow_aggregate_input(
    field: NominalFieldRef
) -> FlowAggregateInputRef {
    FlowAggregateInputRef {
        value: FlowAggregateInputValue::NominalAggregateInputValue(field)
    }
}
pub fn make_variant_flow_aggregate_input(
    field: VariantFieldRef
) -> FlowAggregateInputRef {
    FlowAggregateInputRef {
        value: FlowAggregateInputValue::VariantAggregateInputValue(field)
    }
}
pub fn make_tuple_flow_aggregate_input(index: Int) -> FlowAggregateInputRef {
    if index < 0 { panic("FlowIR: negative aggregate tuple index") }
    FlowAggregateInputRef {
        value: FlowAggregateInputValue::TupleAggregateInputValue(index)
    }
}
pub fn make_structural_flow_aggregate_input(
    path: PathRef
) -> FlowAggregateInputRef {
    FlowAggregateInputRef {
        value: FlowAggregateInputValue::StructuralAggregateInputValue(path)
    }
}
pub fn flow_aggregate_input_kind_tag(value: FlowAggregateInputRef) -> Int {
    match value.value {
        FlowAggregateInputValue::NominalAggregateInputValue(_) => 0,
        FlowAggregateInputValue::VariantAggregateInputValue(_) => 1,
        FlowAggregateInputValue::TupleAggregateInputValue(_) => 2,
        FlowAggregateInputValue::StructuralAggregateInputValue(_) => 3
    }
}
pub fn flow_aggregate_input_nominal(
    value: FlowAggregateInputRef
) -> NominalFieldRef {
    match value.value {
        FlowAggregateInputValue::NominalAggregateInputValue(field) => field,
        _ => panic("FlowIR: aggregate input is not nominal")
    }
}
pub fn flow_aggregate_input_variant(
    value: FlowAggregateInputRef
) -> VariantFieldRef {
    match value.value {
        FlowAggregateInputValue::VariantAggregateInputValue(field) => field,
        _ => panic("FlowIR: aggregate input is not variant")
    }
}
pub fn flow_aggregate_input_tuple_index(value: FlowAggregateInputRef) -> Int {
    match value.value {
        FlowAggregateInputValue::TupleAggregateInputValue(index) => index,
        _ => panic("FlowIR: aggregate input is not tuple")
    }
}
pub fn flow_aggregate_input_structural_path(
    value: FlowAggregateInputRef
) -> PathRef {
    match value.value {
        FlowAggregateInputValue::StructuralAggregateInputValue(path) => path,
        _ => panic("FlowIR: aggregate input is not structural")
    }
}
fn copy_flow_aggregate_input(value: FlowAggregateInputRef) -> FlowAggregateInputRef {
    match value.value {
        FlowAggregateInputValue::NominalAggregateInputValue(field) =>
            make_nominal_flow_aggregate_input(field),
        FlowAggregateInputValue::VariantAggregateInputValue(field) =>
            make_variant_flow_aggregate_input(field),
        FlowAggregateInputValue::TupleAggregateInputValue(index) =>
            make_tuple_flow_aggregate_input(index),
        FlowAggregateInputValue::StructuralAggregateInputValue(path) =>
            make_structural_flow_aggregate_input(path)
    }
}

fn empty_aggregate_inputs(arity: Int) -> List<FlowAggregateInputRef?> {
    let mut result: List<FlowAggregateInputRef?> = []
    for _ in 0..arity { result.push(none) }
    result
}

pub struct FlowOperationContract {
    value: FlowOperationValue,
    input_types: List<CoreTypeRef>,
    input_roles: List<FlowSemanticRole>,
    input_locations: List<FlowAggregateInputRef?>,
    target_type: CoreTypeRef,
    target_role: FlowSemanticRole,
    target_origin: FlowValueOriginContract
}

fn make_flow_operation_contract(
    value: FlowOperationValue, input_types: List<CoreTypeRef>,
    input_roles: List<FlowSemanticRole>,
    input_locations: List<FlowAggregateInputRef?>,
    target_type: CoreTypeRef,
    target_role: FlowSemanticRole,
    target_origin: FlowValueOriginContract
) -> FlowOperationContract {
    if input_types.len() != input_roles.len() ||
       input_types.len() != input_locations.len() {
        panic("FlowIR: operation input type/role arity differs")
    }
    for role in input_roles { let _ = flow_semantic_role_tag(role) }
    let _ = flow_semantic_role_tag(target_role)
    validate_value_origin_arity(target_origin, input_types.len())
    FlowOperationContract {
        value: value, input_types: input_types.map(fn(item) { item }),
        input_roles: copy_semantic_roles(input_roles),
        input_locations: input_locations.map(fn(location) {
            location.map(fn(value) { copy_flow_aggregate_input(value) })
        }),
        target_type: target_type, target_role: target_role,
        target_origin: copy_value_origin(target_origin)
    }
}

pub fn make_flow_int_literal_contract(
    value: Int, target_type: CoreTypeRef
) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::IntLiteralOperationValue(value), [], [], [],
        target_type, flow_semantic_role_read(), make_fresh_flow_value_origin())
}
pub fn make_flow_float_literal_contract(
    value: Float, target_type: CoreTypeRef
) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::FloatLiteralOperationValue(value), [], [], [],
        target_type, flow_semantic_role_read(), make_fresh_flow_value_origin())
}
pub fn make_flow_str_literal_contract(
    value: Str, target_type: CoreTypeRef
) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::StrLiteralOperationValue(value), [], [], [],
        target_type, flow_semantic_role_read(), make_fresh_flow_value_origin())
}
pub fn make_flow_bool_literal_contract(
    value: Bool, target_type: CoreTypeRef
) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::BoolLiteralOperationValue(value), [], [], [],
        target_type, flow_semantic_role_read(), make_fresh_flow_value_origin())
}
pub fn make_flow_unit_literal_contract(
    target_type: CoreTypeRef
) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::UnitLiteralOperationValue, [], [], [],
        target_type, flow_semantic_role_read(), make_fresh_flow_value_origin())
}
pub fn make_flow_primitive_contract(
    operation: FlowPrimitiveOp, input_types: List<CoreTypeRef>,
    input_roles: List<FlowSemanticRole>, target_type: CoreTypeRef,
    target_role: FlowSemanticRole, target_origin: FlowValueOriginContract
) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::PrimitiveOperationValue(
            flow_primitive_op_from_tag(operation.tag)),
        input_types, input_roles, empty_aggregate_inputs(input_types.len()),
        target_type, target_role, target_origin)
}
pub fn make_flow_variant_construct_contract(
    variant: VariantRef, input_types: List<CoreTypeRef>,
    input_locations: List<FlowAggregateInputRef?>,
    target_type: CoreTypeRef
) -> FlowOperationContract {
    let mut input_roles: List<FlowSemanticRole> = []
    for _index in 0..input_types.len() {
        input_roles.push(flow_semantic_role_consume())
    }
    make_flow_operation_contract(
        FlowOperationValue::VariantConstructOperationValue(variant),
        input_types, input_roles, input_locations,
        target_type, flow_semantic_role_read(),
        make_fresh_flow_value_origin())
}
pub fn make_flow_effect_ctx_overlay_contract(
    parent: EffectCtxRef, child: EffectCtxRef,
    entries: List<CoreEffectCtxTokenRef>,
    input_types: List<CoreTypeRef>, input_roles: List<FlowSemanticRole>,
    target_type: CoreTypeRef
) -> FlowOperationContract {
    if effect_ctx_ref_same(parent, child) || entries.len() == 0 ||
       input_types.len() == 0 || input_types.len() != input_roles.len() {
        panic("FlowIR: invalid EffectCtx overlay contract")
    }
    make_flow_operation_contract(
        FlowOperationValue::EffectCtxOverlayOperationValue {
            parent: parent, child: child,
            entries: entries.map(fn(value) { value })
        }, input_types, input_roles,
        empty_aggregate_inputs(input_types.len()), target_type,
        flow_semantic_role_read(), make_fresh_flow_value_origin())
}
pub fn make_flow_tuple_aggregate_contract(
    arity: Int, input_types: List<CoreTypeRef>,
    input_roles: List<FlowSemanticRole>, target_type: CoreTypeRef
) -> FlowOperationContract {
    if arity < 0 || arity != input_types.len() {
        panic("FlowIR: tuple aggregate arity differs")
    }
    let mut locations: List<FlowAggregateInputRef?> = []
    for index in 0..arity {
        locations.push(some(make_tuple_flow_aggregate_input(index)))
    }
    make_flow_operation_contract(
        FlowOperationValue::TupleAggregateOperationValue(arity),
        input_types, input_roles, locations, target_type,
        flow_semantic_role_read(), make_fresh_flow_value_origin())
}
pub fn make_flow_record_aggregate_contract(
    arity: Int, input_types: List<CoreTypeRef>,
    input_roles: List<FlowSemanticRole>,
    input_locations: List<FlowAggregateInputRef?>,
    target_type: CoreTypeRef
) -> FlowOperationContract {
    if arity < 0 || arity != input_types.len() {
        panic("FlowIR: record aggregate arity differs")
    }
    make_flow_operation_contract(
        FlowOperationValue::RecordAggregateOperationValue(arity),
        input_types, input_roles, input_locations, target_type,
        flow_semantic_role_read(), make_fresh_flow_value_origin())
}
pub fn make_flow_closure_contract(
    executable: ExecutableRef, input_types: List<CoreTypeRef>,
    input_roles: List<FlowSemanticRole>,
    capture_targets: List<SlotRef>, target_type: CoreTypeRef
) -> FlowOperationContract {
    if capture_targets.len() != input_types.len() {
        panic("FlowIR: closure capture source/target arity differs")
    }
    let mut left_index = 0
    while left_index < capture_targets.len() {
        let mut right_index = left_index + 1
        while right_index < capture_targets.len() {
            if slot_ref_same(
                    capture_targets.get(left_index).unwrap(),
                    capture_targets.get(right_index).unwrap()) {
                panic("FlowIR: closure repeats a capture target")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    make_flow_operation_contract(
        FlowOperationValue::ClosureOperationValue {
            executable: executable,
            capture_targets: copy_slot_refs(capture_targets)
        },
        input_types, input_roles, empty_aggregate_inputs(input_types.len()),
        target_type,
        flow_semantic_role_read(), make_fresh_flow_value_origin())
}
pub fn make_flow_callable_value_contract(
    executable: ExecutableRef, target_type: CoreTypeRef,
    evidence: List<FlowEvidenceRef>,
    type_substitutions: List<FlowTypeSubstitution>,
    effect_substitutions: List<CoreEffectSubstitution>,
    effects: CoreEffectInstantiation
) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::CallableValueOperationValue {
            executable: executable, evidence: copy_flow_evidence(evidence),
            type_substitutions:
                copy_flow_type_substitutions(type_substitutions),
            effect_substitutions: effect_substitutions.map(fn(item) {
                make_core_effect_substitution(
                    core_effect_substitution_parameter(item),
                    core_effect_substitution_replacement(item))
            }),
            effects: make_core_effect_instantiation(
                core_effect_instantiation_source(effects),
                core_effect_instantiation_substitutions(effects),
                core_effect_instantiation_result(effects))
        },
        [], [], [], target_type, flow_semantic_role_read(),
        make_fresh_flow_value_origin())
}

fn exact_dictionary_contains_local(value: ExactDictRef) -> Bool {
    if dict_ref_is_local(value) { return true }
    if dict_ref_is_static(value) { return false }
    for inner in dict_ref_wrapped_inner(value) {
        if exact_dictionary_contains_local(inner) { return true }
    }
    false
}

pub fn make_flow_dict_construct_contract(
    dictionary: ExactDictRef, result: SlotRef,
    input_types: List<CoreTypeRef>, target_type: CoreTypeRef
) -> FlowOperationContract {
    if !dict_ref_is_wrapped(dictionary) || !slot_ref_is_source(result) ||
       !slot_domain_same(
            slot_ref_source_domain(result), slot_domain_dictionary()) {
        panic("FlowIR: dictionary construct exact identity is invalid")
    }
    let mut local_count = 0
    for inner in dict_ref_wrapped_inner(dictionary) {
        if dict_ref_is_local(inner) {
            if slot_ref_same(dict_ref_local(inner), result) {
                panic("FlowIR: dictionary construct aliases its result")
            }
            local_count = local_count + 1
        } else if exact_dictionary_contains_local(inner) {
            panic("FlowIR: dictionary construct has an unflattened dynamic child")
        }
    }
    if local_count == 0 || local_count != input_types.len() {
        panic("FlowIR: dictionary construct dynamic evidence arity differs")
    }
    let mut roles: List<FlowSemanticRole> = []
    let mut role_index = 0
    while role_index < input_types.len() {
        roles.push(flow_semantic_role_read())
        role_index = role_index + 1
    }
    make_flow_operation_contract(
        FlowOperationValue::DictConstructOperationValue {
            dictionary: dictionary, result: result
        }, input_types, roles, empty_aggregate_inputs(input_types.len()),
        target_type, flow_semantic_role_read(), make_fresh_flow_value_origin())
}

pub fn flow_operation_contract_kind_tag(value: FlowOperationContract) -> Int {
    match value.value {
        FlowOperationValue::IntLiteralOperationValue(_) => 0,
        FlowOperationValue::FloatLiteralOperationValue(_) => 1,
        FlowOperationValue::StrLiteralOperationValue(_) => 2,
        FlowOperationValue::BoolLiteralOperationValue(_) => 3,
        FlowOperationValue::UnitLiteralOperationValue => 4,
        FlowOperationValue::PrimitiveOperationValue(_) => 5,
        FlowOperationValue::VariantConstructOperationValue(_) => 6,
        FlowOperationValue::TupleAggregateOperationValue(_) => 9,
        FlowOperationValue::RecordAggregateOperationValue(_) => 10,
        FlowOperationValue::ClosureOperationValue { .. } => 11,
        FlowOperationValue::CallableValueOperationValue { .. } => 12,
        FlowOperationValue::EffectCtxOverlayOperationValue { .. } => 13,
        FlowOperationValue::DictConstructOperationValue { .. } => 14
    }
}
pub fn flow_operation_contract_input_roles(
    value: FlowOperationContract
) -> List<FlowSemanticRole> { copy_semantic_roles(value.input_roles) }
pub fn flow_operation_contract_input_types(
    value: FlowOperationContract
) -> List<CoreTypeRef> { value.input_types.map(fn(item) { item }) }
pub fn flow_operation_contract_input_locations(
    value: FlowOperationContract
) -> List<FlowAggregateInputRef?> {
    value.input_locations.map(fn(location) {
        location.map(fn(item) { copy_flow_aggregate_input(item) })
    })
}
pub fn flow_operation_contract_target_type(
    value: FlowOperationContract
) -> CoreTypeRef { value.target_type }
pub fn flow_operation_contract_target_role(
    value: FlowOperationContract
) -> FlowSemanticRole { value.target_role }
pub fn flow_operation_contract_target_origin(
    value: FlowOperationContract
) -> FlowValueOriginContract { copy_value_origin(value.target_origin) }
pub fn flow_operation_contract_primitive(
    value: FlowOperationContract
) -> FlowPrimitiveOp {
    match value.value {
        FlowOperationValue::PrimitiveOperationValue(operation) => operation,
        _ => panic("FlowIR: operation is not primitive")
    }
}
pub fn flow_operation_contract_variant(
    value: FlowOperationContract
) -> VariantRef {
    match value.value {
        FlowOperationValue::VariantConstructOperationValue(variant) => variant,
        _ => panic("FlowIR: operation is not a variant construct")
    }
}
pub fn flow_operation_contract_effect_ctx_parent(
    value: FlowOperationContract
) -> EffectCtxRef {
    match value.value {
        FlowOperationValue::EffectCtxOverlayOperationValue { parent, .. } =>
            parent,
        _ => panic("FlowIR: operation is not an EffectCtx overlay")
    }
}
pub fn flow_operation_contract_effect_ctx_child(
    value: FlowOperationContract
) -> EffectCtxRef {
    match value.value {
        FlowOperationValue::EffectCtxOverlayOperationValue { child, .. } =>
            child,
        _ => panic("FlowIR: operation is not an EffectCtx overlay")
    }
}
pub fn flow_operation_contract_effect_ctx_entries(
    value: FlowOperationContract
) -> List<CoreEffectCtxTokenRef> {
    match value.value {
        FlowOperationValue::EffectCtxOverlayOperationValue { entries, .. } =>
            entries.map(fn(item) { item }),
        _ => panic("FlowIR: operation is not an EffectCtx overlay")
    }
}
pub fn flow_operation_contract_closure_executable(
    value: FlowOperationContract
) -> ExecutableRef {
    match value.value {
        FlowOperationValue::ClosureOperationValue { executable, .. } =>
            executable,
        _ => panic("FlowIR: operation is not a closure")
    }
}
pub fn flow_operation_contract_callable_executable(
    value: FlowOperationContract
) -> ExecutableRef {
    match value.value {
        FlowOperationValue::CallableValueOperationValue { executable, .. } =>
            executable,
        _ => panic("FlowIR: operation is not a callable value")
    }
}
pub fn flow_operation_contract_callable_evidence(
    value: FlowOperationContract
) -> List<FlowEvidenceRef> {
    match value.value {
        FlowOperationValue::CallableValueOperationValue { evidence, .. } =>
            copy_flow_evidence(evidence),
        _ => panic("FlowIR: operation is not a callable value")
    }
}
pub fn flow_operation_contract_dict_construct_dictionary(
    value: FlowOperationContract
) -> ExactDictRef {
    match value.value {
        FlowOperationValue::DictConstructOperationValue { dictionary, .. } =>
            dictionary,
        _ => panic("FlowIR: operation is not DictConstruct")
    }
}
pub fn flow_operation_contract_dict_construct_result(
    value: FlowOperationContract
) -> SlotRef {
    match value.value {
        FlowOperationValue::DictConstructOperationValue { result, .. } => result,
        _ => panic("FlowIR: operation is not DictConstruct")
    }
}
pub fn flow_operation_contract_capture_targets(
    value: FlowOperationContract
) -> List<SlotRef> {
    match value.value {
        FlowOperationValue::ClosureOperationValue { capture_targets, .. } =>
            copy_slot_refs(capture_targets),
        _ => panic("FlowIR: operation is not a closure")
    }
}
pub fn flow_operation_contract_int_literal(value: FlowOperationContract) -> Int {
    match value.value {
        FlowOperationValue::IntLiteralOperationValue(literal) => literal,
        _ => panic("FlowIR: operation is not an Int literal")
    }
}
pub fn flow_operation_contract_float_literal(
    value: FlowOperationContract
) -> Float {
    match value.value {
        FlowOperationValue::FloatLiteralOperationValue(literal) => literal,
        _ => panic("FlowIR: operation is not a Float literal")
    }
}
pub fn flow_operation_contract_str_literal(value: FlowOperationContract) -> Str {
    match value.value {
        FlowOperationValue::StrLiteralOperationValue(literal) => literal,
        _ => panic("FlowIR: operation is not a Str literal")
    }
}
pub fn flow_operation_contract_bool_literal(
    value: FlowOperationContract
) -> Bool {
    match value.value {
        FlowOperationValue::BoolLiteralOperationValue(literal) => literal,
        _ => panic("FlowIR: operation is not a Bool literal")
    }
}

fn copy_operation_contract(value: FlowOperationContract) -> FlowOperationContract {
    make_flow_operation_contract(
        value.value, value.input_types, value.input_roles,
        value.input_locations,
        value.target_type, value.target_role, value.target_origin)
}

enum FlowProjectionContractValue {
    NominalProjectionValue(NominalFieldRef),
    VariantProjectionValue(VariantFieldRef),
    TupleProjectionValue(Int),
    StructuralProjectionValue(PathRef)
}

pub struct FlowProjectionContract {
    value: FlowProjectionContractValue,
    base_type: CoreTypeRef,
    result_type: CoreTypeRef,
    base_role: FlowSemanticRole,
    partial: Bool
}

pub fn make_nominal_flow_projection_contract(
    field: NominalFieldRef, base_type: CoreTypeRef,
    result_type: CoreTypeRef, base_role: FlowSemanticRole, partial: Bool
) -> FlowProjectionContract {
    let _ = flow_semantic_role_tag(base_role)
    FlowProjectionContract {
        value: FlowProjectionContractValue::NominalProjectionValue(field),
        base_type: base_type, result_type: result_type,
        base_role: base_role, partial: partial
    }
}
pub fn make_structural_flow_projection_contract(
    projection: PathRef, base_type: CoreTypeRef,
    result_type: CoreTypeRef, base_role: FlowSemanticRole, partial: Bool
) -> FlowProjectionContract {
    let _ = flow_semantic_role_tag(base_role)
    FlowProjectionContract {
        value: FlowProjectionContractValue::StructuralProjectionValue(projection),
        base_type: base_type, result_type: result_type,
        base_role: base_role, partial: partial
    }
}
pub fn make_variant_flow_projection_contract(
    field: VariantFieldRef, base_type: CoreTypeRef,
    result_type: CoreTypeRef, base_role: FlowSemanticRole, partial: Bool
) -> FlowProjectionContract {
    let _ = flow_semantic_role_tag(base_role)
    FlowProjectionContract {
        value: FlowProjectionContractValue::VariantProjectionValue(field),
        base_type: base_type, result_type: result_type,
        base_role: base_role, partial: partial
    }
}
pub fn make_tuple_flow_projection_contract(
    index: Int, base_type: CoreTypeRef,
    result_type: CoreTypeRef, base_role: FlowSemanticRole, partial: Bool
) -> FlowProjectionContract {
    if index < 0 { panic("FlowIR: negative tuple projection index") }
    let _ = flow_semantic_role_tag(base_role)
    FlowProjectionContract {
        value: FlowProjectionContractValue::TupleProjectionValue(index),
        base_type: base_type, result_type: result_type,
        base_role: base_role, partial: partial
    }
}
pub fn flow_projection_contract_kind_tag(value: FlowProjectionContract) -> Int {
    match value.value {
        FlowProjectionContractValue::NominalProjectionValue(_) => 0,
        FlowProjectionContractValue::StructuralProjectionValue(_) => 1,
        FlowProjectionContractValue::VariantProjectionValue(_) => 3,
        FlowProjectionContractValue::TupleProjectionValue(_) => 4
    }
}
pub fn flow_projection_contract_base_type(
    value: FlowProjectionContract
) -> CoreTypeRef { value.base_type }
pub fn flow_projection_contract_result_type(
    value: FlowProjectionContract
) -> CoreTypeRef { value.result_type }
pub fn flow_projection_contract_base_role(
    value: FlowProjectionContract
) -> FlowSemanticRole { value.base_role }
pub fn flow_projection_contract_is_partial(
    value: FlowProjectionContract
) -> Bool { value.partial }
pub fn flow_projection_contract_nominal_field(
    value: FlowProjectionContract
) -> NominalFieldRef {
    match value.value {
        FlowProjectionContractValue::NominalProjectionValue(field) => field,
        _ => panic("FlowIR: projection is not nominal")
    }
}
pub fn flow_projection_contract_structural_path(
    value: FlowProjectionContract
) -> PathRef {
    match value.value {
        FlowProjectionContractValue::StructuralProjectionValue(path) => path,
        _ => panic("FlowIR: projection is not structural")
    }
}
pub fn flow_projection_contract_variant_field(
    value: FlowProjectionContract
) -> VariantFieldRef {
    match value.value {
        FlowProjectionContractValue::VariantProjectionValue(field) => field,
        _ => panic("FlowIR: projection is not variant payload")
    }
}
pub fn flow_projection_contract_tuple_index(value: FlowProjectionContract) -> Int {
    match value.value {
        FlowProjectionContractValue::TupleProjectionValue(index) => index,
        _ => panic("FlowIR: projection is not tuple")
    }
}
fn copy_projection_contract(
    value: FlowProjectionContract
) -> FlowProjectionContract {
    FlowProjectionContract {
        value: value.value, base_type: value.base_type,
        result_type: value.result_type, base_role: value.base_role,
        partial: value.partial
    }
}

pub fn copy_flow_projection_contract(
    value: FlowProjectionContract
) -> FlowProjectionContract { copy_projection_contract(value) }

pub fn flow_projection_contract_same(
    left: FlowProjectionContract, right: FlowProjectionContract
) -> Bool {
    if flow_projection_contract_kind_tag(left) !=
           flow_projection_contract_kind_tag(right) ||
       !core_type_ref_same(left.base_type, right.base_type) ||
       !core_type_ref_same(left.result_type, right.result_type) ||
       flow_semantic_role_tag(left.base_role) !=
           flow_semantic_role_tag(right.base_role) ||
       left.partial != right.partial {
        return false
    }
    let kind = flow_projection_contract_kind_tag(left)
    if kind == 0 {
        return nominal_field_ref_same(
            flow_projection_contract_nominal_field(left),
            flow_projection_contract_nominal_field(right))
    }
    if kind == 1 {
        return path_ref_same(
            flow_projection_contract_structural_path(left),
            flow_projection_contract_structural_path(right))
    }
    if kind == 2 { return true }
    if kind == 3 {
        return variant_field_ref_same(
            flow_projection_contract_variant_field(left),
            flow_projection_contract_variant_field(right))
    }
    flow_projection_contract_tuple_index(left) ==
        flow_projection_contract_tuple_index(right)
}

enum FlowPlaceRefValue {
    FlowSlotPlaceValue(SlotRef),
    FlowProjectPlaceValue {
        base: SlotRef,
        projection: FlowProjectionContract,
        value_type: CoreTypeRef
    }
}
pub struct FlowPlaceRef { value: FlowPlaceRefValue }
pub fn make_flow_slot_place(slot: SlotRef) -> FlowPlaceRef {
    FlowPlaceRef { value: FlowPlaceRefValue::FlowSlotPlaceValue(slot) }
}
pub fn make_flow_project_place(
    base: SlotRef, projection: FlowProjectionContract,
    value_type: CoreTypeRef
) -> FlowPlaceRef {
    FlowPlaceRef { value: FlowPlaceRefValue::FlowProjectPlaceValue {
        base: base, projection: copy_projection_contract(projection),
        value_type: value_type
    } }
}
pub fn flow_place_is_slot(value: FlowPlaceRef) -> Bool {
    match value.value {
        FlowPlaceRefValue::FlowSlotPlaceValue(_) => true,
        FlowPlaceRefValue::FlowProjectPlaceValue { .. } => false
    }
}
pub fn flow_place_slot(value: FlowPlaceRef) -> SlotRef {
    match value.value {
        FlowPlaceRefValue::FlowSlotPlaceValue(slot) => slot,
        _ => panic("FlowIR: projected place has no direct slot")
    }
}
pub fn flow_place_base(value: FlowPlaceRef) -> SlotRef {
    match value.value {
        FlowPlaceRefValue::FlowProjectPlaceValue { base, .. } => base,
        _ => panic("FlowIR: slot place has no base")
    }
}
pub fn flow_place_projection(value: FlowPlaceRef) -> FlowProjectionContract {
    match value.value {
        FlowPlaceRefValue::FlowProjectPlaceValue { projection, .. } => projection,
        _ => panic("FlowIR: slot place has no projection")
    }
}
pub fn flow_place_value_type(value: FlowPlaceRef) -> CoreTypeRef {
    match value.value {
        FlowPlaceRefValue::FlowProjectPlaceValue { value_type, .. } => value_type,
        _ => panic("FlowIR: slot place type comes from slot table")
    }
}
fn copy_flow_place(value: FlowPlaceRef) -> FlowPlaceRef {
    match value.value {
        FlowPlaceRefValue::FlowSlotPlaceValue(slot) => make_flow_slot_place(slot),
        FlowPlaceRefValue::FlowProjectPlaceValue {
            base, projection, value_type
        } => make_flow_project_place(base, projection, value_type)
    }
}

enum FlowInstructionValue {
    InitializeValue {
        operation: FlowOperationContract,
        inputs: List<SlotRef>, target: SlotRef
    },
    ReadValue { source: SlotRef, target: SlotRef },
    MutateValue {
        target: SlotRef, value: SlotRef,
        target_role: FlowSemanticRole, value_role: FlowSemanticRole
    },
    ConsumeValue { source: SlotRef },
    DiscardValue { source: SlotRef },
    FailRaiseValue { payload: SlotRef, sink: SlotRef },
    AssignValue { rhs_temp: SlotRef, target: FlowPlaceRef },
    MovePlaceValue { source: FlowPlaceRef, target: SlotRef },
    CallValue {
        target: FlowCallTarget, arguments: List<SlotRef>,
        evidence: List<FlowEvidenceRef>,
        effect_ctx: FlowEffectCtxUse,
        result: SlotRef?
    },
    ProjectValue {
        contract: FlowProjectionContract,
        base: SlotRef, result: SlotRef
    },
    CaptureValue {
        capture: PathRef, source: SlotRef, target: SlotRef,
        source_role: FlowSemanticRole, target_role: FlowSemanticRole
    },
    ScopeEnterValue { scope: FlowScopeRef },
    ScopeExitValue { scope: FlowScopeRef }
}

pub struct FlowInstruction {
    reference: FlowInstructionRef,
    origin: OriginRef,
    value: FlowInstructionValue
}

fn copy_slot_refs(values: List<SlotRef>) -> List<SlotRef> {
    let mut result: List<SlotRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_flow_initialize(
    reference: FlowInstructionRef, origin: OriginRef,
    operation: FlowOperationContract, inputs: List<SlotRef>, target: SlotRef
) -> FlowInstruction {
    if operation.input_roles.len() != inputs.len() {
        panic("FlowIR: Initialize input semantic roles are not total")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::InitializeValue {
            operation: copy_operation_contract(operation),
            inputs: copy_slot_refs(inputs), target: target
        }
    }
}

pub fn make_flow_read(
    reference: FlowInstructionRef, origin: OriginRef,
    source: SlotRef, target: SlotRef
) -> FlowInstruction {
    if slot_ref_same(source, target) {
        panic("FlowIR: Read source and target are identical")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ReadValue {
            source: source, target: target
        }
    }
}

pub fn make_flow_mutate(
    reference: FlowInstructionRef, origin: OriginRef,
    target: SlotRef, value: SlotRef,
    target_role: FlowSemanticRole, value_role: FlowSemanticRole
) -> FlowInstruction {
    let _ = flow_semantic_role_tag(target_role)
    let _ = flow_semantic_role_tag(value_role)
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::MutateValue {
            target: target, value: value,
            target_role: target_role, value_role: value_role
        }
    }
}

pub fn make_flow_consume(
    reference: FlowInstructionRef, origin: OriginRef, source: SlotRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ConsumeValue { source: source }
    }
}

pub fn make_flow_discard(
    reference: FlowInstructionRef, origin: OriginRef, source: SlotRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::DiscardValue { source: source }
    }
}
pub fn make_flow_fail_raise(
    reference: FlowInstructionRef, origin: OriginRef,
    payload: SlotRef, sink: SlotRef
) -> FlowInstruction {
    if slot_ref_same(payload, sink) {
        panic("FlowIR: FailRaise payload aliases sink")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::FailRaiseValue {
            payload: payload, sink: sink
        }
    }
}

pub fn make_flow_assign(
    reference: FlowInstructionRef, origin: OriginRef,
    rhs_temp: SlotRef, target: FlowPlaceRef
) -> FlowInstruction {
    if flow_place_is_slot(target) &&
       slot_ref_same(rhs_temp, flow_place_slot(target)) {
        panic("FlowIR: Assign RHS temp aliases target")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::AssignValue {
            rhs_temp: rhs_temp, target: copy_flow_place(target)
        }
    }
}

pub fn make_flow_move_place(
    reference: FlowInstructionRef, origin: OriginRef,
    source: FlowPlaceRef, target: SlotRef
) -> FlowInstruction {
    if flow_place_is_slot(source) &&
       slot_ref_same(flow_place_slot(source), target) {
        panic("FlowIR: MovePlace source and target alias")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::MovePlaceValue {
            source: copy_flow_place(source), target: target
        }
    }
}

pub fn make_flow_call(
    reference: FlowInstructionRef, origin: OriginRef,
    target: FlowCallTarget, arguments: List<SlotRef>,
    evidence: List<FlowEvidenceRef>,
    effect_ctx: FlowEffectCtxUse, result: SlotRef?
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::CallValue {
            target: copy_call_target(target),
            arguments: copy_slot_refs(arguments),
            evidence: copy_flow_evidence(evidence),
            effect_ctx: effect_ctx,
            result: result
        }
    }
}

pub fn make_flow_project(
    reference: FlowInstructionRef, origin: OriginRef,
    contract: FlowProjectionContract, base: SlotRef, result: SlotRef
) -> FlowInstruction {
    if slot_ref_same(base, result) {
        panic("FlowIR: projection aliases its base slot")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ProjectValue {
            contract: copy_projection_contract(contract),
            base: base, result: result
        }
    }
}

pub fn make_flow_capture(
    reference: FlowInstructionRef, origin: OriginRef,
    capture: PathRef, source: SlotRef, target: SlotRef,
    source_role: FlowSemanticRole, target_role: FlowSemanticRole
) -> FlowInstruction {
    if slot_ref_same(source, target) {
        panic("FlowIR: capture source aliases target")
    }
    let _ = flow_semantic_role_tag(source_role)
    let _ = flow_semantic_role_tag(target_role)
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::CaptureValue {
            capture: capture, source: source, target: target,
            source_role: source_role, target_role: target_role
        }
    }
}

pub fn make_flow_scope_enter(
    reference: FlowInstructionRef, origin: OriginRef, scope: FlowScopeRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ScopeEnterValue { scope: scope }
    }
}

pub fn make_flow_scope_exit(
    reference: FlowInstructionRef, origin: OriginRef, scope: FlowScopeRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ScopeExitValue { scope: scope }
    }
}

pub fn flow_instruction_reference(
    value: FlowInstruction
) -> FlowInstructionRef { value.reference }
pub fn flow_instruction_origin(value: FlowInstruction) -> OriginRef { value.origin }

pub fn flow_instruction_kind_tag(value: FlowInstruction) -> Int {
    match value.value {
        FlowInstructionValue::InitializeValue { .. } => 0,
        FlowInstructionValue::ReadValue { .. } => 1,
        FlowInstructionValue::MutateValue { .. } => 2,
        FlowInstructionValue::ConsumeValue { .. } => 3,
        FlowInstructionValue::DiscardValue { .. } => 4,
        FlowInstructionValue::AssignValue { .. } => 5,
        FlowInstructionValue::CallValue { .. } => 6,
        FlowInstructionValue::ProjectValue { .. } => 7,
        FlowInstructionValue::CaptureValue { .. } => 8,
        FlowInstructionValue::ScopeEnterValue { .. } => 9,
        FlowInstructionValue::ScopeExitValue { .. } => 10,
        FlowInstructionValue::FailRaiseValue { .. } => 11,
        FlowInstructionValue::MovePlaceValue { .. } => 12
    }
}

pub fn flow_initialize_operation(value: FlowInstruction) -> FlowOperationContract {
    match value.value {
        FlowInstructionValue::InitializeValue { operation, .. } =>
            copy_operation_contract(operation),
        _ => panic("FlowIR: instruction is not Initialize")
    }
}
pub fn flow_initialize_inputs(value: FlowInstruction) -> List<SlotRef> {
    match value.value {
        FlowInstructionValue::InitializeValue { inputs, .. } =>
            copy_slot_refs(inputs),
        _ => panic("FlowIR: instruction is not Initialize")
    }
}
pub fn flow_initialize_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::InitializeValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Initialize")
    }
}
pub fn flow_read_source(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ReadValue { source, .. } => source,
        _ => panic("FlowIR: instruction is not Read")
    }
}
pub fn flow_read_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ReadValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Read")
    }
}
pub fn flow_mutate_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::MutateValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Mutate")
    }
}
pub fn flow_mutate_value(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::MutateValue { value: input, .. } => input,
        _ => panic("FlowIR: instruction is not Mutate")
    }
}
pub fn flow_mutate_target_role(value: FlowInstruction) -> FlowSemanticRole {
    match value.value {
        FlowInstructionValue::MutateValue { target_role, .. } => target_role,
        _ => panic("FlowIR: instruction is not Mutate")
    }
}
pub fn flow_mutate_value_role(value: FlowInstruction) -> FlowSemanticRole {
    match value.value {
        FlowInstructionValue::MutateValue { value_role, .. } => value_role,
        _ => panic("FlowIR: instruction is not Mutate")
    }
}
pub fn flow_consume_source(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ConsumeValue { source } => source,
        _ => panic("FlowIR: instruction is not Consume")
    }
}
pub fn flow_discard_source(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::DiscardValue { source } => source,
        _ => panic("FlowIR: instruction is not Discard")
    }
}
pub fn flow_fail_raise_payload(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::FailRaiseValue { payload, .. } => payload,
        _ => panic("FlowIR: instruction is not FailRaise")
    }
}
pub fn flow_fail_raise_sink(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::FailRaiseValue { sink, .. } => sink,
        _ => panic("FlowIR: instruction is not FailRaise")
    }
}
pub fn flow_assign_rhs_temp(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::AssignValue { rhs_temp, .. } => rhs_temp,
        _ => panic("FlowIR: instruction is not Assign")
    }
}
pub fn flow_assign_target(value: FlowInstruction) -> FlowPlaceRef {
    match value.value {
        FlowInstructionValue::AssignValue { target, .. } =>
            copy_flow_place(target),
        _ => panic("FlowIR: instruction is not Assign")
    }
}
pub fn flow_move_place_source(value: FlowInstruction) -> FlowPlaceRef {
    match value.value {
        FlowInstructionValue::MovePlaceValue { source, .. } =>
            copy_flow_place(source),
        _ => panic("FlowIR: instruction is not MovePlace")
    }
}
pub fn flow_move_place_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::MovePlaceValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not MovePlace")
    }
}
pub fn flow_call_target(value: FlowInstruction) -> FlowCallTarget {
    match value.value {
        FlowInstructionValue::CallValue { target, .. } => copy_call_target(target),
        _ => panic("FlowIR: instruction is not Call")
    }
}
pub fn flow_call_arguments(value: FlowInstruction) -> List<SlotRef> {
    match value.value {
        FlowInstructionValue::CallValue { arguments, .. } =>
            copy_slot_refs(arguments),
        _ => panic("FlowIR: instruction is not Call")
    }
}
pub fn flow_call_result(value: FlowInstruction) -> SlotRef? {
    match value.value {
        FlowInstructionValue::CallValue { result, .. } => result,
        _ => panic("FlowIR: instruction is not Call")
    }
}
pub fn flow_call_evidence(value: FlowInstruction) -> List<FlowEvidenceRef> {
    match value.value {
        FlowInstructionValue::CallValue { evidence, .. } =>
            copy_flow_evidence(evidence),
        _ => panic("FlowIR: instruction is not Call")
    }
}
pub fn flow_call_effect_ctx(
    value: FlowInstruction
) -> FlowEffectCtxUse {
    match value.value {
        FlowInstructionValue::CallValue { effect_ctx, .. } => effect_ctx,
        _ => panic("FlowIR: instruction is not Call")
    }
}
pub fn flow_project_contract(value: FlowInstruction) -> FlowProjectionContract {
    match value.value {
        FlowInstructionValue::ProjectValue { contract, .. } =>
            copy_projection_contract(contract),
        _ => panic("FlowIR: instruction is not Project")
    }
}
pub fn flow_project_base(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ProjectValue { base, .. } => base,
        _ => panic("FlowIR: instruction is not Project")
    }
}
pub fn flow_project_result(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ProjectValue { result, .. } => result,
        _ => panic("FlowIR: instruction is not Project")
    }
}
pub fn flow_project_is_partial(value: FlowInstruction) -> Bool {
    match value.value {
        FlowInstructionValue::ProjectValue { contract, .. } => contract.partial,
        _ => panic("FlowIR: instruction is not Project")
    }
}
pub fn flow_capture_path(value: FlowInstruction) -> PathRef {
    match value.value {
        FlowInstructionValue::CaptureValue { capture, .. } => capture,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_capture_source(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::CaptureValue { source, .. } => source,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_capture_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::CaptureValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_capture_source_role(value: FlowInstruction) -> FlowSemanticRole {
    match value.value {
        FlowInstructionValue::CaptureValue { source_role, .. } => source_role,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_capture_target_role(value: FlowInstruction) -> FlowSemanticRole {
    match value.value {
        FlowInstructionValue::CaptureValue { target_role, .. } => target_role,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_scope_instruction_scope(value: FlowInstruction) -> FlowScopeRef {
    match value.value {
        FlowInstructionValue::ScopeEnterValue { scope } => scope,
        FlowInstructionValue::ScopeExitValue { scope } => scope,
        _ => panic("FlowIR: instruction is not a scope operation")
    }
}

enum FlowSemanticStepRefValue {
    InstructionStepValue(FlowInstructionRef),
    TerminatorStepValue(FlowBlockRef)
}

pub struct FlowSemanticStepRef { value: FlowSemanticStepRefValue }

pub fn make_flow_instruction_step_ref(
    value: FlowInstructionRef
) -> FlowSemanticStepRef {
    FlowSemanticStepRef {
        value: FlowSemanticStepRefValue::InstructionStepValue(value)
    }
}
pub fn make_flow_terminator_step_ref(
    value: FlowBlockRef
) -> FlowSemanticStepRef {
    FlowSemanticStepRef {
        value: FlowSemanticStepRefValue::TerminatorStepValue(value)
    }
}
pub fn flow_semantic_step_is_instruction(value: FlowSemanticStepRef) -> Bool {
    match value.value {
        FlowSemanticStepRefValue::InstructionStepValue(_) => true,
        FlowSemanticStepRefValue::TerminatorStepValue(_) => false
    }
}
pub fn flow_semantic_step_instruction(
    value: FlowSemanticStepRef
) -> FlowInstructionRef {
    match value.value {
        FlowSemanticStepRefValue::InstructionStepValue(reference) => reference,
        _ => panic("FlowIR: semantic step is not an instruction")
    }
}
pub fn flow_semantic_step_terminator(
    value: FlowSemanticStepRef
) -> FlowBlockRef {
    match value.value {
        FlowSemanticStepRefValue::TerminatorStepValue(reference) => reference,
        _ => panic("FlowIR: semantic step is not a terminator")
    }
}
pub fn flow_semantic_step_owner(value: FlowSemanticStepRef) -> ExecutableRef {
    match value.value {
        FlowSemanticStepRefValue::InstructionStepValue(reference) =>
            reference.owner,
        FlowSemanticStepRefValue::TerminatorStepValue(reference) =>
            reference.owner
    }
}
pub fn flow_semantic_step_same(
    left: FlowSemanticStepRef, right: FlowSemanticStepRef
) -> Bool {
    match (left.value, right.value) {
        (FlowSemanticStepRefValue::InstructionStepValue(a),
         FlowSemanticStepRefValue::InstructionStepValue(b)) =>
            flow_instruction_ref_same(a, b),
        (FlowSemanticStepRefValue::TerminatorStepValue(a),
         FlowSemanticStepRefValue::TerminatorStepValue(b)) =>
            flow_block_ref_same(a, b),
        _ => false
    }
}

pub struct FlowOperandRef {
    step: FlowSemanticStepRef,
    ordinal: Int,
    slot: SlotRef,
    role: FlowSemanticRole
}
pub fn flow_operand_step(value: FlowOperandRef) -> FlowSemanticStepRef {
    value.step
}
pub fn flow_operand_ordinal(value: FlowOperandRef) -> Int { value.ordinal }
pub fn flow_operand_slot(value: FlowOperandRef) -> SlotRef { value.slot }
pub fn flow_operand_role(value: FlowOperandRef) -> FlowSemanticRole { value.role }

pub struct FlowResultRef {
    step: FlowSemanticStepRef,
    ordinal: Int,
    slot: SlotRef,
    origin: FlowValueOriginContract
}
pub fn flow_result_step(value: FlowResultRef) -> FlowSemanticStepRef { value.step }
pub fn flow_result_ordinal(value: FlowResultRef) -> Int { value.ordinal }
pub fn flow_result_slot(value: FlowResultRef) -> SlotRef { value.slot }
pub fn flow_result_origin(value: FlowResultRef) -> FlowValueOriginContract {
    copy_value_origin(value.origin)
}

fn make_instruction_operand(
    instruction: FlowInstruction, ordinal: Int,
    slot: SlotRef, role: FlowSemanticRole
) -> FlowOperandRef {
    FlowOperandRef {
        step: make_flow_instruction_step_ref(instruction.reference),
        ordinal: ordinal, slot: slot, role: role
    }
}
fn make_instruction_result(
    instruction: FlowInstruction, ordinal: Int,
    slot: SlotRef, origin: FlowValueOriginContract
) -> FlowResultRef {
    FlowResultRef {
        step: make_flow_instruction_step_ref(instruction.reference),
        ordinal: ordinal, slot: slot, origin: copy_value_origin(origin)
    }
}

pub fn flow_instruction_operands(value: FlowInstruction) -> List<FlowOperandRef> {
    let mut result: List<FlowOperandRef> = []
    match value.value {
        FlowInstructionValue::InitializeValue { operation, inputs, .. } => {
            let mut index = 0
            while index < inputs.len() {
                result.push(make_instruction_operand(
                    value, index, inputs.get(index).unwrap(),
                    operation.input_roles.get(index).unwrap()))
                index = index + 1
            }
        },
        FlowInstructionValue::ReadValue { source, .. } =>
            result.push(make_instruction_operand(
                value, 0, source, flow_semantic_role_read())),
        FlowInstructionValue::MutateValue {
            target, value: input, target_role, value_role
        } => {
            result.push(make_instruction_operand(value, 0, target, target_role))
            result.push(make_instruction_operand(value, 1, input, value_role))
        },
        FlowInstructionValue::ConsumeValue { source } =>
            result.push(make_instruction_operand(
                value, 0, source, flow_semantic_role_consume())),
        FlowInstructionValue::DiscardValue { source } =>
            result.push(make_instruction_operand(
                value, 0, source, flow_semantic_role_consume())),
        FlowInstructionValue::FailRaiseValue { payload, .. } =>
            result.push(make_instruction_operand(
                value, 0, payload, flow_semantic_role_consume())),
        FlowInstructionValue::AssignValue { rhs_temp, target } => {
            result.push(make_instruction_operand(
                value, 0, rhs_temp, flow_semantic_role_consume()))
            if flow_place_is_slot(target) {
                result.push(make_instruction_operand(
                    value, 1, flow_place_slot(target),
                    flow_semantic_role_mutate()))
            } else {
                result.push(make_instruction_operand(
                    value, 1, flow_place_base(target),
                    flow_semantic_role_mutate()))
            }
        },
        FlowInstructionValue::MovePlaceValue { source, .. } =>
            result.push(make_instruction_operand(
                value, 0,
                if flow_place_is_slot(source) { flow_place_slot(source) }
                else { flow_place_base(source) },
                flow_semantic_role_consume())),
        FlowInstructionValue::CallValue {
            target, arguments, effect_ctx, ..
        } => {
            let roles = flow_call_contract_parameter_roles(target.contract)
            let mut index = 0
            while index < arguments.len() {
                result.push(make_instruction_operand(
                    value, index, arguments.get(index).unwrap(),
                    roles.get(index).unwrap()))
                index = index + 1
            }
            match flow_effect_ctx_use_borrowed_slot(effect_ctx) {
                some(context) => {
                result.push(make_instruction_operand(
                    value, index, context,
                    flow_semantic_role_read()))
                index = index + 1
                },
                none => {}
            }
        },
        FlowInstructionValue::ProjectValue { contract, base, .. } =>
            result.push(make_instruction_operand(
                value, 0, base, contract.base_role)),
        FlowInstructionValue::CaptureValue {
            source, source_role, ..
        } => result.push(make_instruction_operand(
            value, 0, source, source_role)),
        FlowInstructionValue::ScopeEnterValue { .. } |
        FlowInstructionValue::ScopeExitValue { .. } => {}
    }
    result
}

pub fn flow_instruction_results(value: FlowInstruction) -> List<FlowResultRef> {
    match value.value {
        FlowInstructionValue::InitializeValue { operation, target, .. } =>
            [make_instruction_result(
                value, 0, target, operation.target_origin)],
        FlowInstructionValue::ReadValue { target, .. } =>
            [make_instruction_result(
                value, 0, target, make_aliasing_flow_value_origin([0]))],
        FlowInstructionValue::MutateValue { target, .. } =>
            [make_instruction_result(
                value, 0, target, make_aliasing_flow_value_origin([0]))],
        FlowInstructionValue::AssignValue { target, .. } =>
            if flow_place_is_slot(target) {
                [make_instruction_result(
                    value, 0, flow_place_slot(target),
                    make_aliasing_flow_value_origin([0]))]
            } else { [] },
        FlowInstructionValue::MovePlaceValue { target, .. } =>
            [make_instruction_result(
                value, 0, target, make_aliasing_flow_value_origin([0]))],
        FlowInstructionValue::CallValue { target, result, .. } => match result {
            some(slot) => [make_instruction_result(
                value, 0, slot,
                flow_call_contract_result_origin(target.contract))],
            none => []
        },
        FlowInstructionValue::ProjectValue { result, .. } =>
            [make_instruction_result(
                value, 0, result, make_aliasing_flow_value_origin([0]))],
        FlowInstructionValue::CaptureValue { target: result, .. } =>
            [make_instruction_result(
                value, 0, result, make_aliasing_flow_value_origin([0]))],
        _ => []
    }
}

enum FlowCallableLocationValue {
    FlowCallableSlotLocationValue(SlotRef),
    FlowCallableProjectionLocationValue {
        base: SlotRef,
        projection: FlowProjectionContract
    }
}
pub struct FlowCallableLocation { value: FlowCallableLocationValue }
pub fn make_flow_callable_slot_location(
    slot: SlotRef
) -> FlowCallableLocation {
    FlowCallableLocation {
        value: FlowCallableLocationValue::FlowCallableSlotLocationValue(slot)
    }
}
pub fn make_flow_callable_projection_location(
    base: SlotRef, projection: FlowProjectionContract
) -> FlowCallableLocation {
    FlowCallableLocation {
        value: FlowCallableLocationValue::FlowCallableProjectionLocationValue {
            base: base, projection: copy_projection_contract(projection)
        }
    }
}
pub fn flow_callable_location_is_slot(value: FlowCallableLocation) -> Bool {
    match value.value {
        FlowCallableLocationValue::FlowCallableSlotLocationValue(_) => true,
        FlowCallableLocationValue::FlowCallableProjectionLocationValue { .. } =>
            false
    }
}
pub fn flow_callable_location_slot(value: FlowCallableLocation) -> SlotRef {
    match value.value {
        FlowCallableLocationValue::FlowCallableSlotLocationValue(slot) => slot,
        _ => panic("FlowIR: callable projection location has no direct slot")
    }
}
pub fn flow_callable_location_base(value: FlowCallableLocation) -> SlotRef {
    match value.value {
        FlowCallableLocationValue::FlowCallableProjectionLocationValue {
            base, ..
        } => base,
        _ => panic("FlowIR: callable slot location has no projection base")
    }
}
pub fn flow_callable_location_projection(
    value: FlowCallableLocation
) -> FlowProjectionContract {
    match value.value {
        FlowCallableLocationValue::FlowCallableProjectionLocationValue {
            projection, ..
        } => copy_projection_contract(projection),
        _ => panic("FlowIR: callable slot location has no projection")
    }
}
pub fn flow_callable_location_same(
    left: FlowCallableLocation, right: FlowCallableLocation
) -> Bool {
    match (left.value, right.value) {
        (FlowCallableLocationValue::FlowCallableSlotLocationValue(a),
         FlowCallableLocationValue::FlowCallableSlotLocationValue(b)) =>
            slot_ref_same(a, b),
        (FlowCallableLocationValue::FlowCallableProjectionLocationValue {
            base: a_base, projection: a_projection
         },
         FlowCallableLocationValue::FlowCallableProjectionLocationValue {
            base: b_base, projection: b_projection
         }) => slot_ref_same(a_base, b_base) &&
            flow_projection_contract_same(a_projection, b_projection),
        _ => false
    }
}
fn copy_flow_callable_location(value: FlowCallableLocation) -> FlowCallableLocation {
    if flow_callable_location_is_slot(value) {
        make_flow_callable_slot_location(flow_callable_location_slot(value))
    } else {
        make_flow_callable_projection_location(
            flow_callable_location_base(value),
            flow_callable_location_projection(value))
    }
}

enum FlowCallableValueOriginValue {
    FlowDirectExecutableOrigin(ExecutableRef),
    FlowFromLocationsOrigin(List<FlowCallableLocation>),
    FlowFromCallOrigin {
        target: FlowCallTarget,
        arguments: List<SlotRef>
    }
}
pub struct FlowCallableValueOrigin { value: FlowCallableValueOriginValue }
pub fn make_flow_direct_callable_origin(
    executable: ExecutableRef
) -> FlowCallableValueOrigin {
    FlowCallableValueOrigin {
        value: FlowCallableValueOriginValue::FlowDirectExecutableOrigin(executable)
    }
}
pub fn make_flow_slots_callable_origin(
    sources: List<SlotRef>
) -> FlowCallableValueOrigin {
    make_flow_locations_callable_origin(sources.map(fn(source) {
        make_flow_callable_slot_location(source)
    }))
}
pub fn make_flow_locations_callable_origin(
    sources: List<FlowCallableLocation>
) -> FlowCallableValueOrigin {
    if sources.len() == 0 {
        panic("FlowIR: callable slot provenance is empty")
    }
    FlowCallableValueOrigin {
        value: FlowCallableValueOriginValue::FlowFromLocationsOrigin(
            sources.map(fn(source) { copy_flow_callable_location(source) }))
    }
}
pub fn make_flow_call_callable_origin(
    target: FlowCallTarget, arguments: List<SlotRef>
) -> FlowCallableValueOrigin {
    FlowCallableValueOrigin {
        value: FlowCallableValueOriginValue::FlowFromCallOrigin {
            target: copy_call_target(target),
            arguments: copy_slot_refs(arguments)
        }
    }
}
pub fn flow_callable_origin_is_direct(value: FlowCallableValueOrigin) -> Bool {
    match value.value {
        FlowCallableValueOriginValue::FlowDirectExecutableOrigin(_) => true,
        _ => false
    }
}
pub fn flow_callable_origin_is_call(value: FlowCallableValueOrigin) -> Bool {
    match value.value {
        FlowCallableValueOriginValue::FlowFromCallOrigin { .. } => true,
        _ => false
    }
}
pub fn flow_callable_origin_direct(
    value: FlowCallableValueOrigin
) -> ExecutableRef {
    match value.value {
        FlowCallableValueOriginValue::FlowDirectExecutableOrigin(executable) =>
            executable,
        _ => panic("FlowIR: callable provenance is not direct")
    }
}
pub fn flow_callable_origin_slots(
    value: FlowCallableValueOrigin
) -> List<SlotRef> {
    match value.value {
        FlowCallableValueOriginValue::FlowFromLocationsOrigin(sources) =>
            sources.map(fn(source) {
                if !flow_callable_location_is_slot(source) {
                    panic("FlowIR: projected callable origin is not a slot")
                }
                flow_callable_location_slot(source)
            }),
        _ => panic("FlowIR: callable provenance is not from slots")
    }
}
pub fn flow_callable_origin_locations(
    value: FlowCallableValueOrigin
) -> List<FlowCallableLocation> {
    match value.value {
        FlowCallableValueOriginValue::FlowFromLocationsOrigin(sources) =>
            sources.map(fn(source) { copy_flow_callable_location(source) }),
        _ => panic("FlowIR: callable provenance is not from locations")
    }
}
pub fn flow_callable_origin_call_target(
    value: FlowCallableValueOrigin
) -> FlowCallTarget {
    match value.value {
        FlowCallableValueOriginValue::FlowFromCallOrigin { target, .. } =>
            copy_call_target(target),
        _ => panic("FlowIR: callable provenance is not from a call")
    }
}
pub fn flow_callable_origin_call_arguments(
    value: FlowCallableValueOrigin
) -> List<SlotRef> {
    match value.value {
        FlowCallableValueOriginValue::FlowFromCallOrigin { arguments, .. } =>
            copy_slot_refs(arguments),
        _ => panic("FlowIR: callable provenance is not from a call")
    }
}

pub struct FlowCallableProvenanceFact {
    step: FlowSemanticStepRef,
    target: FlowCallableLocation,
    origin: FlowCallableValueOrigin
}
pub fn make_flow_callable_provenance_fact(
    step: FlowSemanticStepRef, target: FlowCallableLocation,
    origin: FlowCallableValueOrigin
) -> FlowCallableProvenanceFact {
    FlowCallableProvenanceFact {
        step: step, target: copy_flow_callable_location(target), origin: origin
    }
}
pub fn flow_callable_provenance_step(
    value: FlowCallableProvenanceFact
) -> FlowSemanticStepRef { value.step }
pub fn flow_callable_provenance_target(
    value: FlowCallableProvenanceFact
) -> FlowCallableLocation { copy_flow_callable_location(value.target) }
pub fn flow_callable_provenance_origin(
    value: FlowCallableProvenanceFact
) -> FlowCallableValueOrigin { value.origin }

// ============================================================
// Fixed control topology
// ============================================================

enum FlowPatternLiteralValue {
    PatternIntValue(Int), PatternFloatValue(Float),
    PatternStrValue(Str), PatternBoolValue(Bool), PatternUnitValue
}
pub struct FlowPatternLiteral { value: FlowPatternLiteralValue }
pub fn make_flow_pattern_int(value: Int) -> FlowPatternLiteral {
    FlowPatternLiteral { value: FlowPatternLiteralValue::PatternIntValue(value) }
}
pub fn make_flow_pattern_float(value: Float) -> FlowPatternLiteral {
    FlowPatternLiteral { value: FlowPatternLiteralValue::PatternFloatValue(value) }
}
pub fn make_flow_pattern_str(value: Str) -> FlowPatternLiteral {
    FlowPatternLiteral { value: FlowPatternLiteralValue::PatternStrValue(value) }
}
pub fn make_flow_pattern_bool(value: Bool) -> FlowPatternLiteral {
    FlowPatternLiteral { value: FlowPatternLiteralValue::PatternBoolValue(value) }
}
pub fn make_flow_pattern_unit() -> FlowPatternLiteral {
    FlowPatternLiteral { value: FlowPatternLiteralValue::PatternUnitValue }
}
pub fn flow_pattern_literal_kind_tag(value: FlowPatternLiteral) -> Int {
    match value.value {
        FlowPatternLiteralValue::PatternIntValue(_) => 0,
        FlowPatternLiteralValue::PatternFloatValue(_) => 1,
        FlowPatternLiteralValue::PatternStrValue(_) => 2,
        FlowPatternLiteralValue::PatternBoolValue(_) => 3,
        FlowPatternLiteralValue::PatternUnitValue => 4
    }
}

enum FlowPatternContractValue {
    FlowWildcardPattern,
    FlowBindingPattern(SlotRef),
    FlowLiteralPattern(FlowPatternLiteral),
    FlowTuplePattern(List<FlowPatternContract>),
    FlowStructPattern { owner: SymbolRef, fields: List<FlowPatternField> },
    FlowVariantPattern { variant: VariantRef,
                         fields: List<FlowPatternField> }
}
pub struct FlowPatternContract {
    ty: CoreTypeRef,
    value: FlowPatternContractValue
}
pub struct FlowPatternField {
    field: FlowFieldIdentity,
    pattern: FlowPatternContract
}
fn copy_flow_patterns(values: List<FlowPatternContract>) -> List<FlowPatternContract> {
    let mut result: List<FlowPatternContract> = []
    for value in values { result.push(value) }
    result
}
fn copy_flow_pattern_fields(values: List<FlowPatternField>) -> List<FlowPatternField> {
    let mut result: List<FlowPatternField> = []
    for value in values { result.push(value) }
    result
}
pub fn make_flow_wildcard_pattern(ty: CoreTypeRef) -> FlowPatternContract {
    FlowPatternContract { ty: ty, value: FlowPatternContractValue::FlowWildcardPattern }
}
pub fn make_flow_binding_pattern(
    ty: CoreTypeRef, slot: SlotRef
) -> FlowPatternContract {
    FlowPatternContract { ty: ty,
        value: FlowPatternContractValue::FlowBindingPattern(slot) }
}
pub fn make_flow_literal_pattern(
    ty: CoreTypeRef, literal: FlowPatternLiteral
) -> FlowPatternContract {
    FlowPatternContract { ty: ty,
        value: FlowPatternContractValue::FlowLiteralPattern(literal) }
}
pub fn make_flow_tuple_pattern(
    ty: CoreTypeRef, elements: List<FlowPatternContract>
) -> FlowPatternContract {
    FlowPatternContract { ty: ty,
        value: FlowPatternContractValue::FlowTuplePattern(
            copy_flow_patterns(elements)) }
}
pub fn make_flow_pattern_field(
    field: FlowFieldIdentity, pattern: FlowPatternContract
) -> FlowPatternField { FlowPatternField { field: field, pattern: pattern } }
pub fn make_flow_struct_pattern(
    ty: CoreTypeRef, owner: SymbolRef,
    field_values: List<FlowPatternField>
) -> FlowPatternContract {
    FlowPatternContract { ty: ty,
        value: FlowPatternContractValue::FlowStructPattern {
            owner: owner, fields: copy_flow_pattern_fields(field_values) } }
}
pub fn make_flow_variant_pattern(
    ty: CoreTypeRef, variant: VariantRef,
    field_values: List<FlowPatternField>
) -> FlowPatternContract {
    FlowPatternContract { ty: ty,
        value: FlowPatternContractValue::FlowVariantPattern {
            variant: variant, fields: copy_flow_pattern_fields(field_values) } }
}
pub fn flow_pattern_type(value: FlowPatternContract) -> CoreTypeRef { value.ty }
pub fn flow_pattern_kind_tag(value: FlowPatternContract) -> Int {
    match value.value {
        FlowPatternContractValue::FlowWildcardPattern => 0,
        FlowPatternContractValue::FlowBindingPattern(_) => 1,
        FlowPatternContractValue::FlowLiteralPattern(_) => 2,
        FlowPatternContractValue::FlowTuplePattern(_) => 3,
        FlowPatternContractValue::FlowStructPattern { .. } => 4,
        FlowPatternContractValue::FlowVariantPattern { .. } => 5
    }
}
pub struct FlowSuccessor {
    target: FlowBlockRef,
    exited_scopes: List<FlowScopeRef>,
    entered_scopes: List<FlowScopeRef>
}

fn copy_scope_refs(values: List<FlowScopeRef>) -> List<FlowScopeRef> {
    let mut result: List<FlowScopeRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_flow_successor(
    target: FlowBlockRef, exited_scopes: List<FlowScopeRef>,
    entered_scopes: List<FlowScopeRef>
) -> FlowSuccessor {
    let mut left_index = 0
    while left_index < exited_scopes.len() {
        let left = exited_scopes.get(left_index).unwrap()
        if !executable_ref_same(left.owner, target.owner) {
            panic("FlowIR: successor exits a cross-body scope")
        }
        let mut right_index = left_index + 1
        while right_index < exited_scopes.len() {
            if flow_scope_ref_same(
                    left, exited_scopes.get(right_index).unwrap()) {
                panic("FlowIR: successor repeats an exited scope")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    for scope in entered_scopes {
        if !executable_ref_same(scope.owner, target.owner) {
            panic("FlowIR: successor enters a cross-body scope")
        }
    }
    FlowSuccessor {
        target: target, exited_scopes: copy_scope_refs(exited_scopes),
        entered_scopes: copy_scope_refs(entered_scopes)
    }
}

pub fn flow_successor_target(value: FlowSuccessor) -> FlowBlockRef {
    value.target
}
pub fn flow_successor_exited_scopes(
    value: FlowSuccessor
) -> List<FlowScopeRef> { copy_scope_refs(value.exited_scopes) }
pub fn flow_successor_entered_scopes(
    value: FlowSuccessor
) -> List<FlowScopeRef> { copy_scope_refs(value.entered_scopes) }

pub struct FlowHandlerBinding {
    operation: EffectOperationRef,
    handler: ExecutableRef,
    closure: SlotRef
}
pub fn make_flow_handler_binding(
    operation: EffectOperationRef, handler: ExecutableRef, closure: SlotRef
) -> FlowHandlerBinding {
    FlowHandlerBinding {
        operation: operation, handler: handler, closure: closure
    }
}
pub fn flow_handler_binding_operation(
    value: FlowHandlerBinding
) -> EffectOperationRef { value.operation }
pub fn flow_handler_binding_handler(value: FlowHandlerBinding) -> ExecutableRef {
    value.handler
}
pub fn flow_handler_binding_closure(value: FlowHandlerBinding) -> SlotRef {
    value.closure
}
fn copy_handler_bindings(values: List<FlowHandlerBinding>) -> List<FlowHandlerBinding> {
    let mut result: List<FlowHandlerBinding> = []
    for value in values {
        result.push(make_flow_handler_binding(
            value.operation, value.handler, value.closure))
    }
    result
}

pub struct FlowEffectCtxEntry {
    token: CoreEffectCtxTokenRef,
    handlers: List<FlowHandlerBinding>
}
pub fn make_flow_effect_ctx_entry(
    token: CoreEffectCtxTokenRef,
    handlers: List<FlowHandlerBinding>
) -> FlowEffectCtxEntry {
    if handlers.len() == 0 {
        panic("FlowIR: handled installation has no handlers")
    }
    let requirement = core_effect_atom_handled_ref(
        core_effect_ctx_token_instance(token))
    let mut index = 0
    while index < handlers.len() {
        let handler = handlers.get(index).unwrap()
        if !handled_effect_ref_same(
                effect_operation_ref_effect(handler.operation), requirement) ||
           effect_operation_ref_source_index(handler.operation) != index {
            panic("FlowIR: handled installation operation order differs")
        }
        index = index + 1
    }
    FlowEffectCtxEntry {
        token: token, handlers: copy_handler_bindings(handlers)
    }
}
pub fn flow_effect_ctx_entry_token(
    value: FlowEffectCtxEntry
) -> CoreEffectCtxTokenRef { value.token }
pub fn flow_effect_ctx_entry_handlers(
    value: FlowEffectCtxEntry
) -> List<FlowHandlerBinding> { copy_handler_bindings(value.handlers) }
fn copy_effect_ctx_entries(
    values: List<FlowEffectCtxEntry>
) -> List<FlowEffectCtxEntry> {
    values.map(fn(value) {
        make_flow_effect_ctx_entry(value.token, value.handlers)
    })
}

pub struct FlowEffectCtxInstall {
    parent: EffectCtxRef,
    child: EffectCtxRef,
    entries: List<FlowEffectCtxEntry>
}
pub fn make_flow_effect_ctx_install(
    parent: EffectCtxRef, child: EffectCtxRef,
    entries: List<FlowEffectCtxEntry>
) -> FlowEffectCtxInstall {
    if effect_ctx_ref_same(parent, child) || entries.len() == 0 {
        panic("FlowIR: invalid EffectCtx install")
    }
    FlowEffectCtxInstall {
        parent: parent, child: child,
        entries: copy_effect_ctx_entries(entries)
    }
}
pub fn flow_effect_ctx_install_parent(
    value: FlowEffectCtxInstall
) -> EffectCtxRef { value.parent }
pub fn flow_effect_ctx_install_child(
    value: FlowEffectCtxInstall
) -> EffectCtxRef { value.child }
pub fn flow_effect_ctx_install_entries(
    value: FlowEffectCtxInstall
) -> List<FlowEffectCtxEntry> { copy_effect_ctx_entries(value.entries) }

enum FlowTerminatorValue {
    GotoValue(FlowSuccessor),
    BranchValue {
        condition: SlotRef,
        when_true: FlowSuccessor,
        when_false: FlowSuccessor
    },
    LoopValue {
        condition: SlotRef,
        body: FlowSuccessor,
        exit: FlowSuccessor
    },
    ReturnValue { value: SlotRef?, exited_scopes: List<FlowScopeRef> },
    BreakValue(FlowSuccessor),
    ContinueValue(FlowSuccessor),
    HandlerValue {
        operation: SlotRef,
        handled: FlowSuccessor,
        unhandled: FlowSuccessor
    },
    PatternValue {
        scrutinee: SlotRef,
        pattern: FlowPatternContract,
        matched: FlowSuccessor,
        unmatched: FlowSuccessor
    },
    RaiseValue { error: SlotRef, caught: FlowSuccessor },
    HandleInstallValue {
        body: FlowSuccessor,
        installation: FlowEffectCtxInstall
    },
    UnreachableValue { exited_scopes: List<FlowScopeRef> },
    DivergeValue { exited_scopes: List<FlowScopeRef> }
}

pub struct FlowTerminator {
    origin: OriginRef,
    value: FlowTerminatorValue
}

pub fn make_flow_goto(
    origin: OriginRef, successor: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::GotoValue(successor)
    }
}

pub fn make_flow_branch(
    origin: OriginRef, condition: SlotRef,
    when_true: FlowSuccessor, when_false: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::BranchValue {
            condition: condition, when_true: when_true, when_false: when_false
        }
    }
}

pub fn make_flow_loop(
    origin: OriginRef, condition: SlotRef,
    body: FlowSuccessor, exit: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::LoopValue {
            condition: condition, body: body, exit: exit
        }
    }
}

pub fn make_flow_return(
    origin: OriginRef, value: SlotRef?, exited_scopes: List<FlowScopeRef>
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::ReturnValue {
            value: value, exited_scopes: copy_scope_refs(exited_scopes)
        }
    }
}

pub fn make_flow_break(
    origin: OriginRef, successor: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::BreakValue(successor)
    }
}

pub fn make_flow_continue(
    origin: OriginRef, successor: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::ContinueValue(successor)
    }
}

pub fn make_flow_handler(
    origin: OriginRef, operation: SlotRef,
    handled: FlowSuccessor, unhandled: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::HandlerValue {
            operation: operation, handled: handled, unhandled: unhandled
        }
    }
}
pub fn make_flow_pattern_branch(
    origin: OriginRef, scrutinee: SlotRef,
    pattern: FlowPatternContract,
    matched: FlowSuccessor, unmatched: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator { origin: origin,
        value: FlowTerminatorValue::PatternValue {
            scrutinee: scrutinee, pattern: pattern,
            matched: matched, unmatched: unmatched } }
}
pub fn flow_pattern_branch_scrutinee(value: FlowTerminator) -> SlotRef {
    match value.value {
        FlowTerminatorValue::PatternValue { scrutinee, .. } => scrutinee,
        _ => panic("FlowIR: terminator is not PatternBranch")
    }
}
pub fn flow_branch_condition(value: FlowTerminator) -> SlotRef {
    match value.value {
        FlowTerminatorValue::BranchValue { condition, .. } => condition,
        _ => panic("FlowIR: terminator is not Branch")
    }
}
pub fn make_flow_raise(
    origin: OriginRef, error: SlotRef, caught: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator { origin: origin,
        value: FlowTerminatorValue::RaiseValue {
            error: error, caught: copy_successor(caught) } }
}
pub fn flow_raise_error(value: FlowTerminator) -> SlotRef {
    match value.value {
        FlowTerminatorValue::RaiseValue { error, .. } => error,
        _ => panic("FlowIR: terminator is not Raise")
    }
}
pub fn flow_raise_caught(value: FlowTerminator) -> FlowSuccessor {
    match value.value {
        FlowTerminatorValue::RaiseValue { caught, .. } => copy_successor(caught),
        _ => panic("FlowIR: terminator is not Raise")
    }
}
pub fn make_flow_handle_install(
    origin: OriginRef, body: FlowSuccessor,
    installation: FlowEffectCtxInstall
) -> FlowTerminator {
    FlowTerminator { origin: origin,
        value: FlowTerminatorValue::HandleInstallValue {
            body: body, installation: installation } }
}
pub fn flow_handle_effect_ctx_install(
    value: FlowTerminator
) -> FlowEffectCtxInstall {
    match value.value {
        FlowTerminatorValue::HandleInstallValue { installation, .. } =>
            make_flow_effect_ctx_install(
                installation.parent, installation.child,
                installation.entries),
        _ => panic("FlowIR: terminator is not HandleInstall")
    }
}

pub fn make_flow_unreachable(
    origin: OriginRef, exited_scopes: List<FlowScopeRef>
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::UnreachableValue {
            exited_scopes: copy_scope_refs(exited_scopes)
        }
    }
}

pub fn make_flow_diverge(
    origin: OriginRef, exited_scopes: List<FlowScopeRef>
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::DivergeValue {
            exited_scopes: copy_scope_refs(exited_scopes)
        }
    }
}

pub fn flow_terminator_origin(value: FlowTerminator) -> OriginRef {
    value.origin
}

pub fn flow_terminator_kind_tag(value: FlowTerminator) -> Int {
    match value.value {
        FlowTerminatorValue::GotoValue(_) => 0,
        FlowTerminatorValue::BranchValue { .. } => 1,
        FlowTerminatorValue::LoopValue { .. } => 2,
        FlowTerminatorValue::ReturnValue { .. } => 3,
        FlowTerminatorValue::BreakValue(_) => 4,
        FlowTerminatorValue::ContinueValue(_) => 5,
        FlowTerminatorValue::HandlerValue { .. } => 7,
        FlowTerminatorValue::UnreachableValue { .. } => 8,
        FlowTerminatorValue::DivergeValue { .. } => 9,
        FlowTerminatorValue::PatternValue { .. } => 10,
        FlowTerminatorValue::RaiseValue { .. } => 11,
        FlowTerminatorValue::HandleInstallValue { .. } => 12
    }
}

fn terminator_successors(value: FlowTerminator) -> List<FlowSuccessor> {
    match value.value {
        FlowTerminatorValue::GotoValue(edge) => [edge],
        FlowTerminatorValue::BranchValue { when_true, when_false, .. } =>
            [when_true, when_false],
        FlowTerminatorValue::LoopValue { body, exit, .. } => [body, exit],
        FlowTerminatorValue::BreakValue(edge) => [edge],
        FlowTerminatorValue::ContinueValue(edge) => [edge],
        FlowTerminatorValue::HandlerValue { handled, unhandled, .. } =>
            [handled, unhandled],
        FlowTerminatorValue::PatternValue { matched, unmatched, .. } =>
            [matched, unmatched],
        FlowTerminatorValue::RaiseValue { caught, .. } => [caught],
        FlowTerminatorValue::HandleInstallValue { body, .. } => [body],
        FlowTerminatorValue::ReturnValue { .. } |
        FlowTerminatorValue::UnreachableValue { .. } |
        FlowTerminatorValue::DivergeValue { .. } => []
    }
}

pub fn flow_terminator_successors(
    value: FlowTerminator
) -> List<FlowSuccessor> {
    let mut result: List<FlowSuccessor> = []
    for edge in terminator_successors(value) {
        result.push(FlowSuccessor {
            target: edge.target,
            exited_scopes: copy_scope_refs(edge.exited_scopes),
            entered_scopes: copy_scope_refs(edge.entered_scopes)
        })
    }
    result
}

pub fn flow_terminator_read_slots(value: FlowTerminator) -> List<SlotRef> {
    match value.value {
        FlowTerminatorValue::BranchValue { condition, .. } => [condition],
        FlowTerminatorValue::LoopValue { condition, .. } => [condition],
        FlowTerminatorValue::ReturnValue { value: returned, .. } =>
            match returned { some(slot) => [slot], none => [] },
        FlowTerminatorValue::HandlerValue { operation, .. } => [operation],
        FlowTerminatorValue::PatternValue { scrutinee, .. } => [scrutinee],
        FlowTerminatorValue::RaiseValue { error, .. } => [error],
        FlowTerminatorValue::HandleInstallValue { installation, .. } =>
            [effect_ctx_slot(installation.child)],
        _ => []
    }
}

pub fn flow_terminator_terminal_exited_scopes(
    value: FlowTerminator
) -> List<FlowScopeRef> {
    match terminator_terminal_exited_scopes(value) {
        some(scopes) => scopes,
        none => panic("FlowIR: non-terminal terminator has no terminal exits")
    }
}

fn copy_successor(value: FlowSuccessor) -> FlowSuccessor {
    FlowSuccessor {
        target: value.target,
        exited_scopes: copy_scope_refs(value.exited_scopes),
        entered_scopes: copy_scope_refs(value.entered_scopes)
    }
}

fn copy_terminator(value: FlowTerminator) -> FlowTerminator {
    match value.value {
        FlowTerminatorValue::GotoValue(edge) =>
            make_flow_goto(value.origin, copy_successor(edge)),
        FlowTerminatorValue::BranchValue {
            condition, when_true, when_false
        } => make_flow_branch(
            value.origin, condition,
            copy_successor(when_true), copy_successor(when_false)),
        FlowTerminatorValue::LoopValue { condition, body, exit } =>
            make_flow_loop(
                value.origin, condition,
                copy_successor(body), copy_successor(exit)),
        FlowTerminatorValue::ReturnValue { value: returned, exited_scopes } =>
            make_flow_return(value.origin, returned, exited_scopes),
        FlowTerminatorValue::BreakValue(edge) =>
            make_flow_break(value.origin, copy_successor(edge)),
        FlowTerminatorValue::ContinueValue(edge) =>
            make_flow_continue(value.origin, copy_successor(edge)),
        FlowTerminatorValue::HandlerValue {
            operation, handled, unhandled
        } => make_flow_handler(
            value.origin, operation,
            copy_successor(handled), copy_successor(unhandled)),
        FlowTerminatorValue::PatternValue {
            scrutinee, pattern, matched, unmatched
        } => make_flow_pattern_branch(
            value.origin, scrutinee, pattern,
            copy_successor(matched), copy_successor(unmatched)),
        FlowTerminatorValue::RaiseValue { error, caught } =>
            make_flow_raise(value.origin, error, copy_successor(caught)),
        FlowTerminatorValue::HandleInstallValue { body, installation } =>
            make_flow_handle_install(
                value.origin, copy_successor(body), installation),
        FlowTerminatorValue::UnreachableValue { exited_scopes } =>
            make_flow_unreachable(value.origin, exited_scopes),
        FlowTerminatorValue::DivergeValue { exited_scopes } =>
            make_flow_diverge(value.origin, exited_scopes)
    }
}

fn terminator_terminal_exited_scopes(
    value: FlowTerminator
) -> List<FlowScopeRef>? {
    match value.value {
        FlowTerminatorValue::ReturnValue { exited_scopes, .. } =>
            some(copy_scope_refs(exited_scopes)),
        FlowTerminatorValue::UnreachableValue { exited_scopes } =>
            some(copy_scope_refs(exited_scopes)),
        FlowTerminatorValue::DivergeValue { exited_scopes } =>
            some(copy_scope_refs(exited_scopes)),
        _ => none
    }
}

pub struct FlowBlock {
    reference: FlowBlockRef,
    origin: OriginRef,
    scope: FlowScopeRef,
    instructions: List<FlowInstruction>,
    terminator: FlowTerminator
}

fn copy_instructions(values: List<FlowInstruction>) -> List<FlowInstruction> {
    let mut result: List<FlowInstruction> = []
    for value in values {
        result.push(match value.value {
            FlowInstructionValue::InitializeValue {
                operation, inputs, target
            } => make_flow_initialize(
                value.reference, value.origin, operation, inputs, target),
            FlowInstructionValue::ReadValue { source, target } =>
                make_flow_read(value.reference, value.origin, source, target),
            FlowInstructionValue::MutateValue {
                target, value: input, target_role, value_role
            } => make_flow_mutate(
                value.reference, value.origin, target, input,
                target_role, value_role),
            FlowInstructionValue::ConsumeValue { source } =>
                make_flow_consume(value.reference, value.origin, source),
            FlowInstructionValue::DiscardValue { source } =>
                make_flow_discard(value.reference, value.origin, source),
            FlowInstructionValue::FailRaiseValue { payload, sink } =>
                make_flow_fail_raise(
                    value.reference, value.origin, payload, sink),
            FlowInstructionValue::AssignValue { rhs_temp, target } =>
                make_flow_assign(
                    value.reference, value.origin, rhs_temp, target),
            FlowInstructionValue::MovePlaceValue { source, target } =>
                make_flow_move_place(
                    value.reference, value.origin, source, target),
            FlowInstructionValue::CallValue {
                target, arguments, evidence, effect_ctx, result
            } =>
                make_flow_call(
                    value.reference, value.origin, target, arguments,
                    evidence, effect_ctx, result),
            FlowInstructionValue::ProjectValue {
                contract, base, result: projected
            } => make_flow_project(
                value.reference, value.origin, contract,
                base, projected),
            FlowInstructionValue::CaptureValue {
                capture, source, target, source_role, target_role
            } => make_flow_capture(
                value.reference, value.origin, capture, source, target,
                source_role, target_role),
            FlowInstructionValue::ScopeEnterValue { scope } =>
                make_flow_scope_enter(value.reference, value.origin, scope),
            FlowInstructionValue::ScopeExitValue { scope } =>
                make_flow_scope_exit(value.reference, value.origin, scope)
        })
    }
    result
}

pub fn make_flow_block(
    reference: FlowBlockRef, origin: OriginRef, scope: FlowScopeRef,
    instructions: List<FlowInstruction>, terminator: FlowTerminator
) -> FlowBlock {
    if !executable_ref_same(reference.owner, scope.owner) {
        panic("FlowIR: block scope crosses executable owner")
    }
    let mut ordinal = 0
    for instruction in instructions {
        let site = instruction.reference
        if !executable_ref_same(site.owner, reference.owner) ||
           site.block_ordinal != reference.ordinal ||
           site.instruction_ordinal != ordinal {
            panic("FlowIR: instruction order/site is not stable")
        }
        ordinal = ordinal + 1
    }
    FlowBlock {
        reference: reference, origin: origin, scope: scope,
        instructions: copy_instructions(instructions),
        terminator: copy_terminator(terminator)
    }
}

pub fn flow_block_reference(value: FlowBlock) -> FlowBlockRef { value.reference }
pub fn flow_block_origin(value: FlowBlock) -> OriginRef { value.origin }
pub fn flow_block_scope(value: FlowBlock) -> FlowScopeRef { value.scope }
pub fn flow_block_instructions(value: FlowBlock) -> List<FlowInstruction> {
    copy_instructions(value.instructions)
}
pub fn flow_block_terminator(value: FlowBlock) -> FlowTerminator {
    copy_terminator(value.terminator)
}
pub fn flow_block_successors(value: FlowBlock) -> List<FlowSuccessor> {
    flow_terminator_successors(value.terminator)
}

pub fn flow_block_terminator_operands(value: FlowBlock) -> List<FlowOperandRef> {
    let step = make_flow_terminator_step_ref(value.reference)
    match value.terminator.value {
        FlowTerminatorValue::BranchValue { condition, .. } => [FlowOperandRef {
            step: step, ordinal: 0, slot: condition,
            role: flow_semantic_role_read()
        }],
        FlowTerminatorValue::LoopValue { condition, .. } => [FlowOperandRef {
            step: step, ordinal: 0, slot: condition,
            role: flow_semantic_role_read()
        }],
        FlowTerminatorValue::ReturnValue { value: returned, .. } =>
            match returned {
                some(slot) => [FlowOperandRef {
                    step: step, ordinal: 0, slot: slot,
                    role: flow_semantic_role_consume()
                }],
                none => []
            },
        FlowTerminatorValue::RaiseValue { error, .. } => [FlowOperandRef {
            step: step, ordinal: 0, slot: error,
            role: flow_semantic_role_read()
        }],
        FlowTerminatorValue::HandlerValue { operation, .. } => [FlowOperandRef {
            step: step, ordinal: 0, slot: operation,
            role: flow_semantic_role_read()
        }],
        FlowTerminatorValue::PatternValue { scrutinee, .. } => [FlowOperandRef {
            step: step, ordinal: 0, slot: scrutinee,
            role: flow_semantic_role_read()
        }],
        FlowTerminatorValue::HandleInstallValue { installation, .. } =>
            [FlowOperandRef {
                step: step, ordinal: 0,
                slot: effect_ctx_slot(installation.child),
                role: flow_semantic_role_read()
            }],
        _ => []
    }
}

fn copy_blocks(values: List<FlowBlock>) -> List<FlowBlock> {
    let mut result: List<FlowBlock> = []
    for value in values {
        result.push(FlowBlock {
            reference: value.reference, origin: value.origin,
            scope: value.scope,
            instructions: copy_instructions(value.instructions),
            terminator: copy_terminator(value.terminator)
        })
    }
    result
}

pub struct FlowBody {
    reference: ExecutableRef,
    origin: OriginRef,
    manifest: BinderManifest,
    scopes: List<FlowScope>,
    slots: List<FlowSlot>,
    entry: FlowBlockRef,
    blocks: List<FlowBlock>
}

fn copy_binder_manifest(value: BinderManifest) -> BinderManifest {
    make_binder_manifest(
        binder_manifest_owner(value), binder_manifest_entries(value))
}

pub fn make_flow_body(
    reference: ExecutableRef, origin: OriginRef,
    manifest: BinderManifest, scopes: List<FlowScope>,
    slots: List<FlowSlot>, entry: FlowBlockRef,
    blocks: List<FlowBlock>
) -> FlowBody {
    if !executable_ref_same(reference, binder_manifest_owner(manifest)) ||
       !executable_ref_same(reference, entry.owner) {
        panic("FlowIR: body identity/manifest/entry differs")
    }
    FlowBody {
        reference: reference, origin: origin,
        manifest: copy_binder_manifest(manifest),
        scopes: copy_scopes(scopes), slots: copy_flow_slots(slots),
        entry: entry, blocks: copy_blocks(blocks)
    }
}

pub fn flow_body_reference(value: FlowBody) -> ExecutableRef { value.reference }
pub fn flow_body_origin(value: FlowBody) -> OriginRef { value.origin }
pub fn flow_body_manifest(value: FlowBody) -> BinderManifest {
    copy_binder_manifest(value.manifest)
}
pub fn flow_body_scopes(value: FlowBody) -> List<FlowScope> {
    copy_scopes(value.scopes)
}
pub fn flow_body_slots(value: FlowBody) -> List<FlowSlot> {
    copy_flow_slots(value.slots)
}
pub fn flow_body_entry(value: FlowBody) -> FlowBlockRef { value.entry }
pub fn flow_body_blocks(value: FlowBody) -> List<FlowBlock> {
    copy_blocks(value.blocks)
}

fn copy_bodies(values: List<FlowBody>) -> List<FlowBody> {
    let mut result: List<FlowBody> = []
    for value in values {
        result.push(FlowBody {
            reference: value.reference, origin: value.origin,
            manifest: copy_binder_manifest(value.manifest),
            scopes: copy_scopes(value.scopes),
            slots: copy_flow_slots(value.slots), entry: value.entry,
            blocks: copy_blocks(value.blocks)
        })
    }
    result
}

// ============================================================
// Freeze validation
// ============================================================

fn path_owner_module_key(value: PathOwnerRef) -> Str {
    if path_owner_ref_is_symbol(value) {
        symbol_ref_origin_module_key(path_owner_ref_symbol(value))
    } else {
        module_body_ref_origin_module_key(path_owner_ref_module_body(value))
    }
}

fn path_ref_module_key(value: PathRef) -> Str {
    path_owner_module_key(path_ref_owner(value))
}

fn origin_ref_module_key(value: OriginRef) -> Str {
    if origin_ref_is_symbol(value) {
        symbol_ref_origin_module_key(origin_ref_symbol(value))
    } else {
        path_ref_module_key(origin_ref_path(value))
    }
}

fn validate_origin_for_executable(
    origin: OriginRef, owner: ExecutableRef
) {
    if origin_ref_module_key(origin) != executable_ref_origin_module_key(owner) {
        panic("FlowIR: origin crosses executable module identity")
    }
}

fn type_ref_exists(values: List<FlowTypeNode>, target: CoreTypeRef) -> Bool {
    core_type_ref_index(target) >= 0 &&
        core_type_ref_index(target) < values.len()
}

fn callable_index(
    values: List<FlowCallable>, target: ExecutableRef
) -> Int? {
    let mut index = 0
    for value in values {
        if executable_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}

fn callable_for_ref(
    values: List<FlowCallable>, target: ExecutableRef
) -> FlowCallable {
    match callable_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("FlowIR: exact callable reference is absent")
    }
}

fn validate_callables(
    values: List<FlowCallable>, type_nodes: List<FlowTypeNode>
) {
    let mut left_index = 0
    while left_index < values.len() {
        let left = values.get(left_index).unwrap()
        validate_origin_for_executable(left.origin, left.reference)
        let parameter_types = flow_call_contract_parameter_types(
            left.semantic_contract)
        let parameter_roles = flow_call_contract_parameter_roles(
            left.semantic_contract)
        let result_type = flow_call_contract_result_type(left.semantic_contract)
        if !type_ref_exists(type_nodes, left.header_type) {
            panic("FlowIR: callable header type is absent")
        }
        let header = type_nodes.get(
            core_type_ref_index(left.header_type)).unwrap()
        if !flow_type_kind_same(header.kind, flow_type_kind_callable()) ||
           header.parameter_count != parameter_types.len() ||
           header.children.len() != parameter_types.len() + 1 {
            panic("FlowIR: callable header shape differs")
        }
        let mut header_index = 0
        while header_index < parameter_types.len() {
            if !core_type_ref_same(
                    header.children.get(header_index).unwrap(),
                    parameter_types.get(header_index).unwrap()) {
                panic("FlowIR: callable header parameter differs")
            }
            header_index = header_index + 1
        }
        if !core_type_ref_same(
                header.children.get(parameter_types.len()).unwrap(),
                result_type) ||
           !core_effect_contract_same(
                header.callable_effects.unwrap(), left.effects) {
            panic("FlowIR: callable header result/effects differ")
        }
        let owner = if left.type_formals.len() == 0 {
            none
        } else if executable_ref_is_named(left.reference) {
            some(executable_ref_named_symbol(left.reference))
        } else {
            panic("FlowIR: anonymous callable declares type formals")
        }
        let mut formal_index = 0
        while formal_index < left.type_formals.len() {
            let formal_ref = left.type_formals.get(formal_index).unwrap()
            if !type_ref_exists(type_nodes, formal_ref) {
                panic("FlowIR: callable type formal is absent")
            }
            let formal_node = type_nodes.get(
                core_type_ref_index(formal_ref)).unwrap()
            if flow_type_kind_tag(formal_node.kind) != FLOW_TYPE_PARAMETER {
                panic("FlowIR: callable type formal is not a parameter node")
            }
            let fact = flow_type_node_generic_param(formal_node)
            if !symbol_ref_same(
                    flow_generic_param_owner(fact), owner.unwrap()) ||
               flow_generic_param_index(fact) != formal_index ||
               flow_generic_param_arity(fact) != left.type_formals.len() {
                panic("FlowIR: callable type formal owner/order/arity differs")
            }
            let _ = flow_generic_param_bounds(fact)
            formal_index = formal_index + 1
        }
        let mut effect_formal_index = 0
        while effect_formal_index < left.effect_formals.len() {
            let formal = left.effect_formals.get(effect_formal_index).unwrap()
            if !origin_ref_same(effect_param_owner(formal), left.origin) ||
               effect_param_ordinal(formal) != effect_formal_index {
                panic("FlowIR: callable effect formal owner/order differs")
            }
            effect_formal_index = effect_formal_index + 1
        }
        if !type_ref_exists(type_nodes, result_type) {
            panic("FlowIR: callable result type is absent")
        }
        for atom in core_effect_set_atoms(
                core_effect_contract_exact(left.effects)) {
            let effect_kind = core_effect_atom_kind_tag(atom)
            if effect_kind == 0 || effect_kind == 1 {
                if !type_ref_exists(type_nodes, core_effect_atom_type(atom)) {
                    panic("FlowIR: callable fail effect type is absent")
                }
            } else if effect_kind == 3 {
                for ty in core_effect_atom_type_arguments(atom) {
                    if !type_ref_exists(type_nodes, ty) {
                        panic("FlowIR: callable handled argument is absent")
                    }
                }
            }
        }
        if parameter_types.len() != parameter_roles.len() {
            panic("FlowIR: callable role vector is not total")
        }
        let concrete = executable_contract_mode_same(
            left.mode, executable_contract_mode_concrete_body())
        if (concrete &&
            left.parameter_slots.len() !=
                parameter_types.len()) ||
           (!concrete && left.parameter_slots.len() != 0) {
            panic("FlowIR: callable parameter slot relation drifted")
        }
        let mut parameter_left = 0
        while parameter_left < left.parameter_slots.len() {
            let mut parameter_right = parameter_left + 1
            while parameter_right < left.parameter_slots.len() {
                if slot_ref_same(
                        left.parameter_slots.get(parameter_left).unwrap(),
                        left.parameter_slots.get(parameter_right).unwrap()) {
                    panic("FlowIR: callable parameter slots are not unique")
                }
                parameter_right = parameter_right + 1
            }
            parameter_left = parameter_left + 1
        }
        for ty in parameter_types {
            if !type_ref_exists(type_nodes, ty) {
                panic("FlowIR: callable parameter type is absent")
            }
        }
        for role in parameter_roles {
            let _ = flow_semantic_role_tag(role)
        }
        let _ = flow_semantic_role_tag(
            flow_call_contract_result_role(left.semantic_contract))
        match left.effect_ctx {
            some(context) => {
                if !type_ref_exists(
                        type_nodes, core_callable_effect_ctx_type(context)) ||
                   !executable_ref_same(
                        effect_ctx_contract_owner(
                            core_callable_effect_ctx_reference(context)),
                        left.reference) {
                    panic("FlowIR: callable EffectCtx type/owner differs")
                }
            },
            none => {}
        }
        let mut right_index = left_index + 1
        while right_index < values.len() {
            if executable_ref_same(
                    left.reference, values.get(right_index).unwrap().reference) {
                panic("FlowIR: duplicate callable reference")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
}

fn scope_index(values: List<FlowScope>, target: FlowScopeRef) -> Int? {
    let mut index = 0
    for value in values {
        if flow_scope_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}

fn scope_for_ref(values: List<FlowScope>, target: FlowScopeRef) -> FlowScope {
    match scope_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("FlowIR: scope reference is absent")
    }
}

fn validate_scopes(owner: ExecutableRef, values: List<FlowScope>) {
    if values.len() == 0 { panic("FlowIR: body has no root scope") }
    let mut ordinal = 0
    for value in values {
        if !executable_ref_same(value.reference.owner, owner) ||
           value.reference.ordinal != ordinal {
            panic("FlowIR: scope order/owner is not frozen")
        }
        if ordinal == 0 {
            if value.parent.is_some() {
                panic("FlowIR: root scope has a parent")
            }
        } else {
            let parent = match value.parent {
                some(parent) => parent,
                none => panic("FlowIR: non-root scope has no parent")
            }
            if !executable_ref_same(parent.owner, owner) ||
               parent.ordinal < 0 || parent.ordinal >= ordinal {
                panic("FlowIR: scope parent is not an earlier local scope")
            }
        }
        ordinal = ordinal + 1
    }
}

fn slot_index(values: List<FlowSlot>, target: SlotRef) -> Int? {
    let mut index = 0
    for value in values {
        if slot_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}

fn slot_for_ref(values: List<FlowSlot>, target: SlotRef) -> FlowSlot {
    match slot_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("FlowIR: instruction references an undeclared slot")
    }
}

fn validate_dictionary_evidence(value: ExactDictRef, body: FlowBody) {
    if dict_ref_is_local(value) {
        let _ = slot_for_ref(body.slots, dict_ref_local(value))
    } else if !dict_ref_is_static(value) {
        for inner in dict_ref_wrapped_inner(value) {
            validate_dictionary_evidence(inner, body)
        }
    }
}

fn validate_dict_construct_initialize(
    operation: FlowOperationContract, inputs: List<SlotRef>, target: SlotRef,
    body: FlowBody, type_nodes: List<FlowTypeNode>
) {
    let dictionary = flow_operation_contract_dict_construct_dictionary(operation)
    let result = flow_operation_contract_dict_construct_result(operation)
    validate_dictionary_evidence(dictionary, body)
    let result_slot = slot_for_ref(body.slots, result)
    if !slot_ref_same(result, target) ||
       flow_storage_contract_tag(result_slot.storage_contract) !=
            flow_storage_contract_tag(flow_own_storage()) {
        panic("FlowIR: dictionary construct result storage differs")
    }
    let target_node = type_node_for(type_nodes, operation.target_type)
    if flow_type_kind_tag(target_node.kind) != FLOW_TYPE_TUPLE ||
       flow_type_node_children(target_node).len() != 0 {
        panic("FlowIR: dictionary construct is not the 0.1 dictionary type")
    }
    let mut input_index = 0
    for inner in dict_ref_wrapped_inner(dictionary) {
        if dict_ref_is_local(inner) {
            if input_index >= inputs.len() ||
               !slot_ref_same(
                    dict_ref_local(inner), inputs.get(input_index).unwrap()) {
                panic("FlowIR: dictionary construct operand order differs")
            }
            input_index = input_index + 1
        } else if exact_dictionary_contains_local(inner) {
            panic("FlowIR: dictionary construct has an unflattened dynamic child")
        }
    }
    if input_index != inputs.len() {
        panic("FlowIR: dictionary construct operand census differs")
    }
    for role in operation.input_roles {
        if flow_semantic_role_tag(role) !=
                flow_semantic_role_tag(flow_semantic_role_read()) {
            panic("FlowIR: dictionary construct evidence is not borrowed")
        }
    }
}

fn dynamic_call_slot_for_path(
    values: List<FlowSlot>, target: PathRef
) -> FlowSlot {
    let mut found: FlowSlot? = none
    for slot in values {
        if !slot_ref_is_source(slot.reference) &&
           path_ref_same(slot_ref_synthetic_path(slot.reference), target) {
            if found.is_some() {
                panic("FlowIR: dynamic callable path maps to multiple slots")
            }
            found = some(slot)
        }
    }
    match found {
        some(value) => value,
        none => panic("FlowIR: dynamic callable path has no exact slot")
    }
}

fn validate_slots(
    body: FlowBody, type_nodes: List<FlowTypeNode>
) {
    let binders = binder_manifest_entries(body.manifest)
    if binders.len() != body.slots.len() {
        panic("FlowIR: binder manifest/slot census differs")
    }
    let mut index = 0
    while index < body.slots.len() {
        let slot = body.slots.get(index).unwrap()
        let binder = binders.get(index).unwrap()
        if !slot_ref_same(slot.reference, binder_entry_slot(binder)) {
            panic("FlowIR: slot order differs from binder manifest")
        }
        if !type_ref_exists(type_nodes, slot.ty) {
            panic("FlowIR: slot type is absent")
        }
        if !executable_ref_same(slot.scope.owner, body.reference) ||
           scope_index(body.scopes, slot.scope).is_none() {
            panic("FlowIR: slot scope is absent or cross-body")
        }
        let _ = flow_initial_slot_state_from_tag(slot.initial_state.tag)
        let _ = flow_storage_class_from_tag(slot.storage.tag)
        let _ = flow_storage_contract_tag(slot.storage_contract)
        if flow_storage_class_same(slot.storage, flow_storage_parameter()) {
            match slot.parameter_ordinal {
                some(parameter_ordinal) => {
                    if parameter_ordinal < 0 ||
                       slot.initial_state.tag != FLOW_SLOT_LIVE {
                        panic("FlowIR: parameter slot ordinal/state is invalid")
                    }
                },
                none => panic("FlowIR: parameter slot has no ordinal")
            }
        } else if slot.parameter_ordinal.is_some() {
            panic("FlowIR: non-parameter slot has an ordinal")
        }
        let mut right_index = index + 1
        while right_index < body.slots.len() {
            let right = body.slots.get(right_index).unwrap()
            if slot_ref_same(slot.reference, right.reference) {
                panic("FlowIR: duplicate frozen slot")
            }
            if flow_scope_ref_same(slot.scope, right.scope) &&
               slot.reverse_ordinal == right.reverse_ordinal {
                panic("FlowIR: duplicate reverse lexical slot ordinal")
            }
            right_index = right_index + 1
        }
        index = index + 1
    }
    // Reverse ordinals are dense per scope.  This makes cleanup order a finite
    // table rather than a backend spelling/order guess.
    for scope in body.scopes {
        let mut count = 0
        for slot in body.slots {
            if flow_scope_ref_same(slot.scope, scope.reference) {
                count = count + 1
            }
        }
        let mut expected = 0
        while expected < count {
            let mut matches = 0
            for slot in body.slots {
                if flow_scope_ref_same(slot.scope, scope.reference) &&
                   slot.reverse_ordinal == expected {
                    matches = matches + 1
                }
            }
            if matches != 1 {
                panic("FlowIR: reverse lexical slot order is not dense")
            }
            expected = expected + 1
        }
    }
}

fn validate_body_callable_parameters(body: FlowBody, callable: FlowCallable) {
    let parameter_types = flow_call_contract_parameter_types(
        callable.semantic_contract)
    if callable.parameter_slots.len() != parameter_types.len() {
        panic("FlowIR: concrete callable parameter relation is partial")
    }
    let mut ordinal = 0
    while ordinal < callable.parameter_slots.len() {
        let expected_slot = callable.parameter_slots.get(ordinal).unwrap()
        let expected_type = parameter_types.get(ordinal).unwrap()
        let mut matches = 0
        for slot in body.slots {
            if flow_storage_class_same(slot.storage, flow_storage_parameter()) &&
               slot.parameter_ordinal == some(ordinal) {
                if !slot_ref_same(slot.reference, expected_slot) ||
                   !core_type_ref_same(slot.ty, expected_type) {
                    panic("FlowIR: parameter ordinal slot/type relation drifted")
                }
                matches = matches + 1
            }
        }
        if matches != 1 {
            panic("FlowIR: parameter ordinal is missing or duplicated")
        }
        ordinal = ordinal + 1
    }
    match callable.effect_ctx {
        some(context) => {
            let mut matches = 0
            for slot in body.slots {
                if slot.parameter_ordinal.is_none() &&
                   slot_ref_same(slot.reference,
                        effect_ctx_slot(
                            core_callable_effect_ctx_reference(context))) {
                    if !core_type_ref_same(
                            slot.ty, core_callable_effect_ctx_type(context)) ||
                       slot.initial_state.tag != FLOW_SLOT_LIVE ||
                       flow_storage_contract_tag(slot.storage_contract) !=
                            flow_storage_contract_tag(flow_borrow_storage()) {
                        panic("FlowIR: callable EffectCtx slot differs")
                    }
                    matches = matches + 1
                }
            }
            if matches != 1 {
                panic("FlowIR: callable EffectCtx slot is missing/duplicated")
            }
        },
        none => {}
    }
    for slot in body.slots {
        if flow_storage_class_same(slot.storage, flow_storage_parameter()) {
            match slot.parameter_ordinal {
                some(slot_ordinal) => if
                        slot_ordinal >= callable.parameter_slots.len() {
                    panic("FlowIR: body has an extra parameter ordinal")
                },
                none => {
                    let mut matches = 0
                    match callable.effect_ctx {
                        some(context) => if slot_ref_same(
                                slot.reference, effect_ctx_slot(
                                    core_callable_effect_ctx_reference(
                                        context))) {
                            matches = matches + 1
                        },
                        none => {}
                    }
                    if matches != 1 {
                        panic("FlowIR: hidden parameter lacks exact EffectCtx")
                    }
                }
            }
        }
    }
}

fn validate_typed_flow_pattern(
    pattern: FlowPatternContract, expected: CoreTypeRef,
    body: FlowBody, type_nodes: List<FlowTypeNode>
) {
    require_same_flow_type(
        pattern.ty, expected, "FlowIR: pattern/scrutinee type differs")
    let node = type_node_for(type_nodes, pattern.ty)
    match pattern.value {
        FlowPatternContractValue::FlowWildcardPattern => {},
        FlowPatternContractValue::FlowBindingPattern(slot) =>
            require_same_flow_type(
                slot_type_for(body, slot), pattern.ty,
                "FlowIR: pattern binding type differs"),
        FlowPatternContractValue::FlowLiteralPattern(literal) => {
            let expected_kind = match flow_pattern_literal_kind_tag(literal) {
                0 => FLOW_TYPE_INT, 1 => FLOW_TYPE_FLOAT, 2 => FLOW_TYPE_STR,
                3 => FLOW_TYPE_BOOL, _ => FLOW_TYPE_UNIT
            }
            if flow_type_kind_tag(node.kind) != expected_kind {
                panic("FlowIR: literal pattern type differs")
            }
        },
        FlowPatternContractValue::FlowTuplePattern(elements) => {
            if flow_type_kind_tag(node.kind) != FLOW_TYPE_TUPLE ||
               elements.len() != node.children.len() {
                panic("FlowIR: tuple pattern type/arity differs")
            }
            let mut index = 0
            for element in elements {
                validate_typed_flow_pattern(
                    element, node.children.get(index).unwrap(),
                    body, type_nodes)
                index = index + 1
            }
        },
        FlowPatternContractValue::FlowStructPattern {
            owner, fields: field_values
        } => {
            if flow_type_kind_tag(node.kind) != FLOW_TYPE_STRUCT ||
               !symbol_ref_same(node.nominal.unwrap(), owner) ||
               field_values.len() != node.nominal_fields.len() {
                panic("FlowIR: struct pattern owner/field census differs")
            }
            let mut index = 0
            for field in field_values {
                let fact = node.nominal_fields.get(index).unwrap()
                if !flow_field_identity_same(field.field, fact.identity) {
                    panic("FlowIR: struct pattern field order differs")
                }
                validate_typed_flow_pattern(
                    field.pattern, fact.ty, body, type_nodes)
                index = index + 1
            }
        },
        FlowPatternContractValue::FlowVariantPattern {
            variant, fields: field_values
        } => {
            if flow_type_kind_tag(node.kind) != FLOW_TYPE_ENUM ||
               !symbol_ref_same(
                    node.nominal.unwrap(),
                    registered_nominal_ref_symbol(variant_ref_owner(variant))) {
                panic("FlowIR: variant pattern owner differs")
            }
            let mut expected_fields: List<FlowNominalFieldFact> = []
            for fact in node.nominal_fields {
                if flow_field_identity_is_variant(fact.identity) &&
                   variant_ref_same(
                        variant_field_ref_variant(
                            flow_field_identity_variant(fact.identity)),
                        variant) {
                    expected_fields.push(fact)
                }
            }
            if field_values.len() != expected_fields.len() {
                panic("FlowIR: variant pattern field census differs")
            }
            let mut index = 0
            for field in field_values {
                let fact = expected_fields.get(index).unwrap()
                if !flow_field_identity_same(field.field, fact.identity) {
                    panic("FlowIR: variant pattern field order differs")
                }
                validate_typed_flow_pattern(
                    field.pattern, fact.ty, body, type_nodes)
                index = index + 1
            }
        }
    }
}

fn validate_typed_terminators(
    body: FlowBody, callable: FlowCallable,
    type_nodes: List<FlowTypeNode>, callables: List<FlowCallable>
) {
    for block in body.blocks {
        match block.terminator.value {
            FlowTerminatorValue::BranchValue { condition, .. } => {
                let condition_type = slot_type_for(body, condition)
                if flow_type_kind_tag(
                        type_node_for(type_nodes, condition_type).kind) !=
                        FLOW_TYPE_BOOL {
                    panic("FlowIR: control condition is not Bool")
                }
            },
            FlowTerminatorValue::LoopValue { condition, .. } => {
                let condition_type = slot_type_for(body, condition)
                if flow_type_kind_tag(
                        type_node_for(type_nodes, condition_type).kind) !=
                        FLOW_TYPE_BOOL {
                    panic("FlowIR: control condition is not Bool")
                }
            },
            FlowTerminatorValue::ReturnValue { value, .. } => match value {
                some(slot) => require_same_flow_type(
                    slot_type_for(body, slot),
                    flow_call_contract_result_type(
                        callable.semantic_contract),
                    "FlowIR: Return slot type differs from callable"),
                none => {
                    let kind = flow_type_kind_tag(
                        type_node_for(
                            type_nodes,
                            flow_call_contract_result_type(
                                callable.semantic_contract)).kind)
                    if kind != FLOW_TYPE_UNIT && kind != FLOW_TYPE_NEVER {
                        panic("FlowIR: value-returning callable has empty Return")
                    }
                }
            },
            FlowTerminatorValue::PatternValue {
                scrutinee, pattern, ..
            } => validate_typed_flow_pattern(
                pattern, slot_type_for(body, scrutinee), body, type_nodes),
            FlowTerminatorValue::HandleInstallValue {
                installation, ..
            } => {
                let parent = slot_for_ref(
                    body.slots, effect_ctx_slot(installation.parent))
                let child = slot_for_ref(
                    body.slots, effect_ctx_slot(installation.child))
                require_same_flow_type(
                    parent.ty, child.ty,
                    "FlowIR: EffectCtx parent/child type differs")
                if flow_storage_contract_tag(child.storage_contract) !=
                        flow_storage_contract_tag(flow_own_storage()) {
                    panic("FlowIR: EffectCtx child is not owned")
                }
                for entry in installation.entries {
                    for binding in entry.handlers {
                        let _ = callable_for_ref(
                            callables, effect_operation_ref_callable(
                                binding.operation))
                        let handler = callable_for_ref(
                            callables, binding.handler)
                        if !executable_contract_mode_same(
                                handler.mode,
                                executable_contract_mode_concrete_body()) {
                            panic("FlowIR: installed handler is bodyless")
                        }
                        let _ = slot_for_ref(body.slots, binding.closure)
                    }
                }
            },
            _ => {}
        }
    }
}

fn binder_kind_tag_for_slot(body: FlowBody, target: SlotRef) -> Int {
    let mut found: Int? = none
    for binder in binder_manifest_entries(body.manifest) {
        if slot_ref_same(binder_entry_slot(binder), target) {
            if found.is_some() {
                panic("FlowIR: Return sink binder repeats")
            }
            found = some(binder_kind_tag(binder_entry_kind(binder)))
        }
    }
    match found {
        some(value) => value,
        none => panic("FlowIR: Return sink binder is absent")
    }
}

fn validate_stable_return_sinks(
    body: FlowBody, callable: FlowCallable,
    type_nodes: List<FlowTypeNode>
) {
    if body.scopes.len() < 2 {
        panic("FlowIR: body lacks permanent root/lexical scopes")
    }
    let root = body.scopes.get(0).unwrap()
    let lexical = body.scopes.get(1).unwrap()
    if flow_scope_has_parent(root) || !flow_scope_has_parent(lexical) ||
       !flow_scope_ref_same(flow_scope_parent(lexical), root.reference) ||
       !flow_scope_ref_same(
            block_for_ref(body.blocks, body.entry).scope,
            lexical.reference) {
        panic("FlowIR: body root/lexical scope relation differs")
    }
    for block in body.blocks {
        if flow_scope_ref_same(block.scope, root.reference) {
            panic("FlowIR: permanent root scope contains a block")
        }
    }
    let scope_result_tag = binder_kind_tag(binder_kind_scope_result())
    for slot in body.slots {
        let kind_tag = binder_kind_tag_for_slot(body, slot.reference)
        if flow_scope_ref_same(slot.scope, root.reference) {
            if kind_tag != scope_result_tag ||
               slot.initial_state.tag != FLOW_SLOT_EMPTY ||
               slot.parameter_ordinal.is_some() {
                panic("FlowIR: permanent root contains a non-Return sink")
            }
        } else if kind_tag == scope_result_tag {
            panic("FlowIR: Return sink escapes permanent root scope")
        }
        let entry_carrier = slot.initial_state.tag == FLOW_SLOT_LIVE ||
            flow_storage_class_same(slot.storage, flow_storage_parameter()) ||
            flow_storage_class_same(slot.storage, flow_storage_capture()) ||
            flow_storage_class_same(slot.storage, flow_storage_context())
        if entry_carrier &&
           !flow_scope_ref_same(slot.scope, lexical.reference) {
            panic("FlowIR: entry carrier escapes lexical body scope")
        }
    }

    let mut returned_sinks: List<SlotRef> = []
    for block in body.blocks {
        match block.terminator.value {
            FlowTerminatorValue::ReturnValue { value: some(sink), .. } => {
                let sink_slot = slot_for_ref(body.slots, sink)
                if !flow_scope_ref_same(sink_slot.scope, root.reference) ||
                   binder_kind_tag_for_slot(body, sink) != scope_result_tag ||
                   sink_slot.initial_state.tag != FLOW_SLOT_EMPTY {
                    panic("FlowIR: Return value is not an exact root sink")
                }
                for existing in returned_sinks {
                    if slot_ref_same(existing, sink) {
                        panic("FlowIR: Return sink is shared by two Returns")
                    }
                }
                returned_sinks.push(sink)
                let transfer = block.instructions.last().unwrap_or_else(fn() {
                    panic("FlowIR: value Return lacks sink transfer")
                })
                let kind = flow_instruction_kind_tag(transfer)
                let source = if kind == 5 {
                    let target = flow_assign_target(transfer)
                    if !flow_place_is_slot(target) ||
                       !slot_ref_same(flow_place_slot(target), sink) {
                        panic("FlowIR: Return Assign target differs")
                    }
                    flow_assign_rhs_temp(transfer)
                } else if kind == 1 {
                    if !slot_ref_same(flow_read_target(transfer), sink) {
                        panic("FlowIR: Return Read target differs")
                    }
                    flow_read_source(transfer)
                } else {
                    panic("FlowIR: Return sink transfer is not Assign/Read")
                }
                let source_slot = slot_for_ref(body.slots, source)
                if flow_scope_ref_same(source_slot.scope, root.reference) ||
                   !core_type_ref_same(source_slot.ty, sink_slot.ty) ||
                   !flow_storage_class_same(
                        source_slot.storage, sink_slot.storage) ||
                   flow_storage_contract_tag(source_slot.storage_contract) !=
                        flow_storage_contract_tag(sink_slot.storage_contract) {
                    panic("FlowIR: Return sink does not copy source facts")
                }
                let own = flow_storage_contract_tag(
                    source_slot.storage_contract) ==
                    flow_storage_contract_tag(flow_own_storage())
                let borrow = flow_storage_contract_tag(
                    source_slot.storage_contract) ==
                    flow_storage_contract_tag(flow_borrow_storage())
                if (own && kind != 5) || (borrow && kind != 1) ||
                   (!own && !borrow) {
                    panic("FlowIR: Return transfer differs from source storage")
                }
            },
            _ => {}
        }
    }
    for slot in body.slots {
        if flow_scope_ref_same(slot.scope, root.reference) {
            let mut returns = 0
            for sink in returned_sinks {
                if slot_ref_same(slot.reference, sink) {
                    returns = returns + 1
                }
            }
            if returns != 1 {
                panic("FlowIR: root Return sink has no unique Return")
            }
        }
    }
    let result_kind = flow_type_kind_tag(type_node_for(
        type_nodes,
        flow_call_contract_result_type(callable.semantic_contract)).kind)
    if (result_kind == FLOW_TYPE_UNIT || result_kind == FLOW_TYPE_NEVER) &&
       returned_sinks.len() != 0 {
        panic("FlowIR: Unit/Never Return owns a stable sink")
    }
}

fn validate_effect_ctx_overlays(bodies: List<FlowBody>) {
    for body in bodies {
        for block in body.blocks {
            let mut overlays: List<FlowInstruction> = []
            for instruction in block.instructions {
                match instruction.value {
                    FlowInstructionValue::InitializeValue { operation, .. } => {
                        if flow_operation_contract_kind_tag(operation) == 13 {
                            overlays.push(instruction)
                        }
                    },
                    _ => {}
                }
            }
            match block.terminator.value {
                FlowTerminatorValue::HandleInstallValue {
                    installation, ..
                } => {
                    if overlays.len() != 1 {
                        panic("FlowIR: HandleInstall lacks one exact overlay")
                    }
                    let overlay = overlays.get(0).unwrap()
                    let (operation, inputs, target) = match overlay.value {
                        FlowInstructionValue::InitializeValue {
                            operation, inputs, target
                        } => (operation, inputs, target),
                        _ => panic("FlowIR: overlay is not Initialize")
                    }
                    if !effect_ctx_ref_same(
                            flow_operation_contract_effect_ctx_parent(operation),
                            installation.parent) ||
                       !effect_ctx_ref_same(
                            flow_operation_contract_effect_ctx_child(operation),
                            installation.child) ||
                       !slot_ref_same(target, effect_ctx_slot(
                            installation.child)) {
                        panic("FlowIR: HandleInstall overlay identity differs")
                    }
                    let operation_tokens =
                        flow_operation_contract_effect_ctx_entries(operation)
                    if operation_tokens.len() != installation.entries.len() {
                        panic("FlowIR: HandleInstall overlay token census differs")
                    }
                    let mut token_index = 0
                    while token_index < operation_tokens.len() {
                        if !core_effect_ctx_token_same(
                                operation_tokens.get(token_index).unwrap(),
                                installation.entries.get(
                                    token_index).unwrap().token) {
                            panic("FlowIR: HandleInstall overlay token order differs")
                        }
                        token_index = token_index + 1
                    }
                    let mut expected_inputs: List<SlotRef> = [
                        effect_ctx_slot(installation.parent)
                    ]
                    for entry in installation.entries {
                        for handler in entry.handlers {
                            expected_inputs.push(handler.closure)
                        }
                    }
                    if inputs.len() != expected_inputs.len() ||
                       operation.input_types.len() != expected_inputs.len() ||
                       operation.input_roles.len() != expected_inputs.len() {
                        panic("FlowIR: HandleInstall overlay input arity differs")
                    }
                    let mut input_index = 0
                    while input_index < expected_inputs.len() {
                        let expected = expected_inputs.get(input_index).unwrap()
                        if !slot_ref_same(
                                inputs.get(input_index).unwrap(), expected) ||
                           !core_type_ref_same(
                                operation.input_types.get(input_index).unwrap(),
                                slot_type_for(body, expected)) {
                            panic("FlowIR: HandleInstall overlay input/type differs")
                        }
                        let expected_role = if input_index == 0 {
                            flow_semantic_role_read()
                        } else { flow_semantic_role_consume() }
                        if flow_semantic_role_tag(
                                operation.input_roles.get(input_index).unwrap()) !=
                           flow_semantic_role_tag(expected_role) {
                            panic("FlowIR: HandleInstall overlay role differs")
                        }
                        let mut right = input_index + 1
                        while right < expected_inputs.len() {
                            if slot_ref_same(
                                    expected,
                                    expected_inputs.get(right).unwrap()) {
                                panic("FlowIR: HandleInstall overlay input repeats")
                            }
                            right = right + 1
                        }
                        input_index = input_index + 1
                    }
                    require_same_flow_type(
                        operation.target_type,
                        slot_type_for(body, target),
                        "FlowIR: HandleInstall overlay target type differs")
                },
                _ => {
                    if overlays.len() != 0 {
                        panic("FlowIR: overlay Initialize lacks HandleInstall")
                    }
                }
            }
        }
    }
}

fn block_index(values: List<FlowBlock>, target: FlowBlockRef) -> Int? {
    let mut index = 0
    for value in values {
        if flow_block_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}

fn block_for_ref(values: List<FlowBlock>, target: FlowBlockRef) -> FlowBlock {
    match block_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("FlowIR: successor block is absent")
    }
}

fn scope_lineage(
    scopes: List<FlowScope>, start: FlowScopeRef
) -> List<FlowScopeRef> {
    let mut result: List<FlowScopeRef> = []
    let mut current: FlowScopeRef? = some(start)
    while current.is_some() {
        let reference = current.unwrap()
        result.push(reference)
        let scope = scope_for_ref(scopes, reference)
        current = scope.parent
    }
    result
}

fn validate_exited_scope_prefix(
    lineage: List<FlowScopeRef>, exited: List<FlowScopeRef>
) {
    if exited.len() > lineage.len() {
        panic("FlowIR: edge exits more scopes than are active")
    }
    let mut index = 0
    while index < exited.len() {
        if !flow_scope_ref_same(
                exited.get(index).unwrap(), lineage.get(index).unwrap()) {
            panic("FlowIR: exited scopes are not inner-to-outer")
        }
        index = index + 1
    }
}

fn validate_successor(
    body: FlowBody, from_scope: FlowScopeRef, successor: FlowSuccessor
) {
    if !executable_ref_same(successor.target.owner, body.reference) {
        panic("FlowIR: successor crosses executable body")
    }
    let target_block = block_for_ref(body.blocks, successor.target)
    let lineage = scope_lineage(body.scopes, from_scope)
    validate_exited_scope_prefix(lineage, successor.exited_scopes)
    if successor.exited_scopes.len() >= lineage.len() {
        panic("FlowIR: non-terminal edge exits the root scope")
    }
    let remaining = lineage.get(successor.exited_scopes.len()).unwrap()
    let mut active = remaining
    for entered in successor.entered_scopes {
        let scope = scope_for_ref(body.scopes, entered)
        let parent = match scope.parent {
            some(value) => value,
            none => panic("FlowIR: successor cannot enter root scope")
        }
        if !flow_scope_ref_same(parent, active) {
            panic("FlowIR: entered scopes are not outer-to-inner")
        }
        active = entered
    }
    if !flow_scope_ref_same(target_block.scope, active) {
        panic("FlowIR: successor target scope differs after exits")
    }
}

fn validate_terminal_exits(
    body: FlowBody, from_scope: FlowScopeRef, exited: List<FlowScopeRef>
) {
    let lineage = scope_lineage(body.scopes, from_scope)
    validate_exited_scope_prefix(lineage, exited)
    if exited.len() != lineage.len() {
        panic("FlowIR: terminal edge does not exit every active scope")
    }
}

fn validate_instruction_slots(body: FlowBody, instruction: FlowInstruction) {
    validate_origin_for_executable(instruction.origin, body.reference)
    match instruction.value {
        FlowInstructionValue::InitializeValue { inputs, target, .. } => {
            for input in inputs { let _ = slot_for_ref(body.slots, input) }
            let _ = slot_for_ref(body.slots, target)
        },
        FlowInstructionValue::ReadValue { source, target } => {
            let _ = slot_for_ref(body.slots, source)
            let _ = slot_for_ref(body.slots, target)
        },
        FlowInstructionValue::MutateValue {
            target, value, target_role, value_role
        } => {
            let _ = slot_for_ref(body.slots, target)
            let _ = slot_for_ref(body.slots, value)
            let _ = flow_semantic_role_tag(target_role)
            let _ = flow_semantic_role_tag(value_role)
        },
        FlowInstructionValue::ConsumeValue { source } => {
            let _ = slot_for_ref(body.slots, source)
        },
        FlowInstructionValue::DiscardValue { source } => {
            let _ = slot_for_ref(body.slots, source)
        },
        FlowInstructionValue::FailRaiseValue { payload, sink } => {
            let _ = slot_for_ref(body.slots, payload)
            let sink_slot = slot_for_ref(body.slots, sink)
            if !flow_storage_class_same(sink_slot.storage, flow_storage_temp()) ||
               sink_slot.initial_state.tag != FLOW_SLOT_EMPTY {
                panic("FlowIR: FailRaise sink is not an empty temp")
            }
        },
        FlowInstructionValue::AssignValue { rhs_temp, target } => {
            let rhs = slot_for_ref(body.slots, rhs_temp)
            if flow_place_is_slot(target) {
                let _ = slot_for_ref(body.slots, flow_place_slot(target))
            } else {
                let _ = slot_for_ref(body.slots, flow_place_base(target))
            }
            if !flow_storage_class_same(rhs.storage, flow_storage_temp()) {
                panic("FlowIR: Assign RHS is not an explicit temp slot")
            }
        },
        FlowInstructionValue::MovePlaceValue { source, target } => {
            if flow_place_is_slot(source) {
                let _ = slot_for_ref(body.slots, flow_place_slot(source))
            } else {
                let _ = slot_for_ref(body.slots, flow_place_base(source))
            }
            let target_slot = slot_for_ref(body.slots, target)
            let target_storage_ok = flow_storage_class_same(
                target_slot.storage, flow_storage_temp()) ||
                flow_storage_class_same(
                    target_slot.storage, flow_storage_local())
            if !target_storage_ok ||
               target_slot.initial_state.tag != FLOW_SLOT_EMPTY ||
               flow_storage_contract_tag(target_slot.storage_contract) !=
                    flow_storage_contract_tag(flow_own_storage()) {
                panic("FlowIR: MovePlace target is not empty owned storage")
            }
        },
        FlowInstructionValue::CallValue {
            target, arguments, evidence, effect_ctx, result
        } => {
            for argument in arguments {
                let _ = slot_for_ref(body.slots, argument)
            }
            match result {
                some(slot) => { let _ = slot_for_ref(body.slots, slot) },
                none => {}
            }
            for item in evidence {
                let _ = flow_evidence_dict(item)
            }
            match flow_effect_ctx_use_borrowed_slot(effect_ctx) {
                some(context) => { let _ = slot_for_ref(body.slots, context) },
                none => {}
            }
            if flow_call_target_is_local(target) {
                let _ = slot_for_ref(body.slots, flow_call_target_local(target))
            } else if !flow_call_target_is_direct(target) {
                if path_ref_module_key(flow_call_target_dynamic(target)) !=
                   executable_ref_origin_module_key(body.reference) {
                    panic("FlowIR: dynamic call adapter crosses module")
                }
            }
        },
        FlowInstructionValue::ProjectValue { base, result, .. } => {
            let _ = slot_for_ref(body.slots, base)
            let _ = slot_for_ref(body.slots, result)
        },
        FlowInstructionValue::CaptureValue {
            capture, source, target, source_role, target_role
        } => {
            if path_ref_module_key(capture) !=
               executable_ref_origin_module_key(body.reference) {
                panic("FlowIR: capture path crosses executable module")
            }
            let _ = slot_for_ref(body.slots, source)
            let _ = slot_for_ref(body.slots, target)
            let _ = flow_semantic_role_tag(source_role)
            let _ = flow_semantic_role_tag(target_role)
        },
        FlowInstructionValue::ScopeEnterValue { scope } => {
            if !executable_ref_same(scope.owner, body.reference) ||
               scope_index(body.scopes, scope).is_none() {
                panic("FlowIR: scope operation references an absent scope")
            }
        },
        FlowInstructionValue::ScopeExitValue { scope } => {
            if !executable_ref_same(scope.owner, body.reference) ||
               scope_index(body.scopes, scope).is_none() {
                panic("FlowIR: scope operation references an absent scope")
            }
        }
    }
}

fn advance_instruction_scope(
    body: FlowBody, current: FlowScopeRef, instruction: FlowInstruction
) -> FlowScopeRef {
    match instruction.value {
        FlowInstructionValue::ScopeEnterValue { scope } => {
            let entered = scope_for_ref(body.scopes, scope)
            let parent = match entered.parent {
                some(value) => value,
                none => panic("FlowIR: cannot enter the root scope")
            }
            if !flow_scope_ref_same(parent, current) {
                panic("FlowIR: scope enter is not a direct child")
            }
            scope
        },
        FlowInstructionValue::ScopeExitValue { scope } => {
            if !flow_scope_ref_same(scope, current) {
                panic("FlowIR: scope exit is not the active scope")
            }
            let exited = scope_for_ref(body.scopes, scope)
            match exited.parent {
                some(parent) => parent,
                none => panic("FlowIR: instruction cannot exit root scope")
            }
        },
        _ => current
    }
}

fn validate_flow_pattern_slots(body: FlowBody, pattern: FlowPatternContract) {
    match pattern.value {
        FlowPatternContractValue::FlowBindingPattern(slot) => {
            let _ = slot_for_ref(body.slots, slot)
        },
        FlowPatternContractValue::FlowTuplePattern(elements) => {
            for element in elements { validate_flow_pattern_slots(body, element) }
        },
        FlowPatternContractValue::FlowStructPattern {
            fields: field_values, ..
        } => {
            for field in field_values {
                validate_flow_pattern_slots(body, field.pattern)
            }
        },
        FlowPatternContractValue::FlowVariantPattern {
            fields: field_values, ..
        } => {
            for field in field_values {
                validate_flow_pattern_slots(body, field.pattern)
            }
        },
        _ => {}
    }
}

fn validate_terminator_slots(body: FlowBody, terminator: FlowTerminator) {
    validate_origin_for_executable(terminator.origin, body.reference)
    match terminator.value {
        FlowTerminatorValue::BranchValue { condition, .. } => {
            let _ = slot_for_ref(body.slots, condition)
        },
        FlowTerminatorValue::LoopValue { condition, .. } => {
            let _ = slot_for_ref(body.slots, condition)
        },
        FlowTerminatorValue::ReturnValue { value, .. } => match value {
            some(slot) => { let _ = slot_for_ref(body.slots, slot) },
            none => {}
        },
        FlowTerminatorValue::HandlerValue { operation, .. } => {
            let _ = slot_for_ref(body.slots, operation)
        },
        FlowTerminatorValue::PatternValue {
            scrutinee, pattern, ..
        } => {
            let _ = slot_for_ref(body.slots, scrutinee)
            validate_flow_pattern_slots(body, pattern)
        },
        FlowTerminatorValue::RaiseValue { error, .. } => {
            let _ = slot_for_ref(body.slots, error)
        },
        _ => {}
    }
}

fn validate_return_exits(
    body: FlowBody, from_scope: FlowScopeRef, exited: List<FlowScopeRef>
) {
    let lineage = scope_lineage(body.scopes, from_scope)
    validate_exited_scope_prefix(lineage, exited)
    if exited.len() + 1 != lineage.len() ||
       flow_scope_ref_ordinal(lineage.last().unwrap()) != 0 {
        panic("FlowIR: Return does not preserve only permanent root scope")
    }
}

fn validate_raise_block_contract(body: FlowBody, block: FlowBlock) {
    let is_raise = flow_terminator_kind_tag(block.terminator) == 11
    let mut fail_count = 0
    let mut fail_sink: SlotRef? = none
    let mut instruction_index = 0
    while instruction_index < block.instructions.len() {
        let instruction = block.instructions.get(instruction_index).unwrap()
        if flow_instruction_kind_tag(instruction) == 11 {
            fail_count = fail_count + 1
            fail_sink = some(flow_fail_raise_sink(instruction))
        }
        instruction_index = instruction_index + 1
    }
    if !is_raise {
        if fail_count != 0 {
            panic("FlowIR: FailRaise lacks an exact Raise edge")
        }
        return
    }
    let error = flow_raise_error(block.terminator)
    if fail_count != 1 || block.instructions.len() < 2 {
        panic("FlowIR: Raise edge lacks one failure sink transfer")
    }
    let fail_instruction = block.instructions.get(
        block.instructions.len() - 2).unwrap()
    let move_instruction = block.instructions.get(
        block.instructions.len() - 1).unwrap()
    if flow_instruction_kind_tag(fail_instruction) != 11 ||
       flow_instruction_kind_tag(move_instruction) != 12 ||
       !slot_ref_same(
            flow_fail_raise_sink(fail_instruction), fail_sink.unwrap()) {
        panic("FlowIR: Raise edge failure sequence differs")
    }
    let moved = flow_move_place_source(move_instruction)
    if !flow_place_is_slot(moved) ||
       !slot_ref_same(flow_place_slot(moved), fail_sink.unwrap()) ||
       !slot_ref_same(flow_move_place_target(move_instruction), error) {
        panic("FlowIR: failure sink/caught error transfer differs")
    }
    let caught = flow_raise_caught(block.terminator)
    let error_slot = slot_for_ref(body.slots, error)
    let error_scope = error_slot.scope
    let failure_scope = slot_for_ref(body.slots, fail_sink.unwrap()).scope
    let caught_scope = block_for_ref(body.blocks, caught.target).scope
    if !flow_storage_class_same(error_slot.storage, flow_storage_local()) ||
       error_slot.initial_state.tag != FLOW_SLOT_EMPTY ||
       flow_storage_contract_tag(error_slot.storage_contract) !=
            flow_storage_contract_tag(flow_own_storage()) ||
       !flow_scope_ref_same(error_scope, caught_scope) ||
       caught.entered_scopes.len() != 1 ||
       !flow_scope_ref_same(
            caught.entered_scopes.get(0).unwrap(), error_scope) ||
       !caught.exited_scopes.any(fn(scope) {
            flow_scope_ref_same(scope, failure_scope)
       }) ||
       caught.exited_scopes.any(fn(scope) {
            flow_scope_ref_same(scope, error_scope)
       }) {
        panic("FlowIR: Raise edge does not enter its exact catch scope")
    }
}

fn validate_body_blocks(body: FlowBody) {
    if body.blocks.len() == 0 {
        panic("FlowIR: concrete body has no blocks")
    }
    if !flow_block_ref_same(body.entry, body.blocks.get(0).unwrap().reference) ||
       body.entry.ordinal != 0 {
        panic("FlowIR: entry is not the first stable block")
    }
    let mut ordinal = 0
    for block in body.blocks {
        if !executable_ref_same(block.reference.owner, body.reference) ||
           block.reference.ordinal != ordinal {
            panic("FlowIR: block order/owner is not frozen")
        }
        if scope_index(body.scopes, block.scope).is_none() {
            panic("FlowIR: block scope is absent")
        }
        validate_origin_for_executable(block.origin, body.reference)
        let mut instruction_ordinal = 0
        let mut active_scope = block.scope
        for instruction in block.instructions {
            if !executable_ref_same(
                    instruction.reference.owner, body.reference) ||
               instruction.reference.block_ordinal != ordinal ||
               instruction.reference.instruction_ordinal != instruction_ordinal {
                panic("FlowIR: instruction site/order drifted")
            }
            validate_instruction_slots(body, instruction)
            active_scope = advance_instruction_scope(
                body, active_scope, instruction)
            instruction_ordinal = instruction_ordinal + 1
        }
        validate_terminator_slots(body, block.terminator)
        validate_raise_block_contract(body, block)
        for successor in terminator_successors(block.terminator) {
            validate_successor(body, active_scope, successor)
        }
        match block.terminator.value {
            FlowTerminatorValue::ReturnValue { exited_scopes, .. } =>
                validate_return_exits(body, active_scope, exited_scopes),
            FlowTerminatorValue::UnreachableValue { exited_scopes } |
            FlowTerminatorValue::DivergeValue { exited_scopes } =>
                validate_terminal_exits(body, active_scope, exited_scopes),
            _ => {}
        }
        ordinal = ordinal + 1
    }
    // Reject dead blocks: the frozen topology is exactly the executable graph,
    // not a bag of future or backend-only alternatives.
    let mut reachable: List<FlowBlockRef> = [body.entry]
    let mut cursor = 0
    while cursor < reachable.len() {
        let current = reachable.get(cursor).unwrap()
        let block = block_for_ref(body.blocks, current)
        for successor in terminator_successors(block.terminator) {
            let mut present = false
            for seen in reachable {
                if flow_block_ref_same(seen, successor.target) {
                    present = true
                }
            }
            if !present { reachable.push(successor.target) }
        }
        cursor = cursor + 1
    }
    // Structured lowering may retain a deterministic join after every arm
    // diverges.  Such blocks remain typed/frozen but have no incoming edge;
    // reachability is explicit topology, not an excuse to delete or renumber
    // stable blocks here.
}

fn validate_bodies(
    bodies: List<FlowBody>, callables: List<FlowCallable>,
    type_nodes: List<FlowTypeNode>
) {
    let mut expected_body_index = 0
    for callable in callables {
        if executable_contract_mode_same(
                callable.mode, executable_contract_mode_concrete_body()) {
            let body = match bodies.get(expected_body_index) {
                some(value) => value,
                none => panic("FlowIR: concrete callable body is missing")
            }
            if !executable_ref_same(callable.reference, body.reference) ||
               !origin_ref_same(callable.origin, body.origin) {
                panic("FlowIR: body order/identity differs from callable table")
            }
            validate_scopes(body.reference, body.scopes)
            validate_slots(body, type_nodes)
            validate_body_callable_parameters(body, callable)
            validate_body_blocks(body)
            validate_typed_terminators(
                body, callable, type_nodes, callables)
            validate_stable_return_sinks(body, callable, type_nodes)
            expected_body_index = expected_body_index + 1
        }
    }
    if expected_body_index != bodies.len() {
        panic("FlowIR: body has no concrete callable contract")
    }
}

fn flow_call_contract_actual_satisfies_formal(
    actual: FlowCallContract, formal: FlowCallContract,
    substitutions: List<FlowTypeSubstitution>,
    effect_actuals: List<CoreEffectSubstitution>,
    type_nodes: List<FlowTypeNode>
) -> Bool {
    let module_same = match (
            flow_call_contract_module_key(actual),
            flow_call_contract_module_key(formal)) {
        (some(a), some(b)) => a == b,
        (none, none) => true,
        _ => false
    }
    let actual_types = flow_call_contract_parameter_types(actual)
    let formal_types = flow_call_contract_parameter_types(formal)
    let actual_roles = flow_call_contract_parameter_roles(actual)
    let formal_roles = flow_call_contract_parameter_roles(formal)
    if !module_same || actual_types.len() != formal_types.len() ||
       actual_roles.len() != formal_roles.len() ||
       !flow_type_actual_satisfies_substituted_formal(
            type_nodes,
            flow_call_contract_result_type(actual),
            flow_call_contract_result_type(formal), substitutions,
            effect_actuals) ||
       flow_semantic_role_tag(flow_call_contract_result_role(actual)) !=
            flow_semantic_role_tag(flow_call_contract_result_role(formal)) ||
       !value_origin_same(
            flow_call_contract_result_origin(actual),
            flow_call_contract_result_origin(formal)) {
        return false
    }
    let mut index = 0
    while index < actual_types.len() {
        if flow_semantic_role_tag(actual_roles.get(index).unwrap()) !=
                flow_semantic_role_tag(formal_roles.get(index).unwrap()) ||
           !flow_type_actual_satisfies_substituted_formal(
                type_nodes, actual_types.get(index).unwrap(),
                formal_types.get(index).unwrap(), substitutions,
                effect_actuals) {
            return false
        }
        index = index + 1
    }
    true
}

fn validate_direct_calls(
    bodies: List<FlowBody>, callables: List<FlowCallable>,
    type_nodes: List<FlowTypeNode>
) {
    for body in bodies {
        for block in body.blocks {
            for instruction in block.instructions {
                match instruction.value {
                    FlowInstructionValue::CallValue {
                        target, arguments, effect_ctx, ..
                    } => {
                        let contract = target.contract
                        if arguments.len() !=
                                flow_call_contract_parameter_roles(
                                    contract).len() {
                            panic("FlowIR: call arguments/semantic contract arity differs")
                        }
                        if flow_call_target_is_direct(target) {
                            let substitutions = target.type_substitutions
                            let candidate = callable_for_ref(
                                callables, flow_call_target_direct(target))
                            validate_flow_type_substitutions_for_callable(
                                substitutions, candidate, type_nodes,
                                "FlowIR: direct type substitution identity/order differs")
                            validate_flow_effect_substitutions_for_callable(
                                target.effect_substitutions, candidate,
                                type_nodes,
                                "FlowIR: direct effect substitution identity/order differs")
                            if !core_effect_instantiation_projects_substitutions(
                                    target.effect_substitutions,
                                    target.effects) {
                                panic("FlowIR: direct top effect projection differs")
                            }
                            if flow_call_contract_parameter_types(
                                    candidate.semantic_contract).len() !=
                                        arguments.len() ||
                               !flow_call_contract_actual_satisfies_formal(
                                    contract, candidate.semantic_contract,
                                    substitutions, target.effect_substitutions,
                                    type_nodes) {
                                panic("FlowIR: direct callable contract differs")
                            }
                            if !flow_effect_actual_satisfies_substituted_formal(
                                    type_nodes,
                                    core_effect_instantiation_source(
                                        target.effects), candidate.effects,
                                    substitutions,
                                    target.effect_substitutions) {
                                panic("FlowIR: direct callable effect source differs")
                            }
                            if candidate.effect_ctx.is_some() ==
                                    (flow_effect_ctx_use_kind_tag(effect_ctx) == 0) {
                                panic("FlowIR: direct EffectCtx/foreign boundary differs")
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    }
}

fn callable_contains_symbol(
    callables: List<FlowCallable>, symbol: SymbolRef
) -> Bool {
    for callable in callables {
        if executable_ref_is_named(callable.reference) &&
           symbol_ref_same(
                executable_ref_named_symbol(callable.reference), symbol) {
            return true
        }
    }
    false
}

fn validate_type_provider_contracts(
    type_nodes: List<FlowTypeNode>, callables: List<FlowCallable>
) {
    for node in type_nodes {
        match node.drop_contract {
            some(contract) => {
                let provider = callable_for_ref(callables, contract.provider)
                let provider_parameters = flow_call_contract_parameter_types(
                    provider.semantic_contract)
                let provider_result = flow_call_contract_result_type(
                    provider.semantic_contract)
                if provider_parameters.len() != 1 ||
                   !core_type_ref_same(
                        provider_parameters.get(0).unwrap(),
                        node.reference) ||
                   flow_type_kind_tag(type_nodes.get(
                        core_type_ref_index(provider_result)
                    ).unwrap().kind) !=
                        FLOW_TYPE_UNIT {
                    panic("FlowIR: Drop provider contract differs from type")
                }
            },
            none => {}
        }
    }
}

fn require_same_flow_type(
    left: CoreTypeRef, right: CoreTypeRef, message: Str
) {
    if !core_type_ref_same(left, right) { panic(message) }
}

fn type_node_for(
    type_nodes: List<FlowTypeNode>, reference: CoreTypeRef
) -> FlowTypeNode {
    match type_nodes.get(core_type_ref_index(reference)) {
        some(value) => value,
        none => panic("FlowIR: typed operation references an absent type")
    }
}
fn require_flow_type_actual_satisfies_formal(
    actual: CoreTypeRef, formal: CoreTypeRef,
    type_nodes: List<FlowTypeNode>, message: Str
) {
    if !flow_type_actual_satisfies_formal(
            type_nodes,
            type_node_for(type_nodes, actual),
            type_node_for(type_nodes, formal)) {
        panic(message)
    }
}

fn slot_type_for(body: FlowBody, slot: SlotRef) -> CoreTypeRef {
    slot_for_ref(body.slots, slot).ty
}

fn aggregate_input_projection(
    location: FlowAggregateInputRef,
    base_type: CoreTypeRef, result_type: CoreTypeRef
) -> FlowProjectionContract {
    let kind = flow_aggregate_input_kind_tag(location)
    if kind == 0 {
        return make_nominal_flow_projection_contract(
            flow_aggregate_input_nominal(location), base_type, result_type,
            flow_semantic_role_read(), false)
    }
    if kind == 1 {
        return make_variant_flow_projection_contract(
            flow_aggregate_input_variant(location), base_type, result_type,
            flow_semantic_role_read(), false)
    }
    if kind == 2 {
        return make_tuple_flow_projection_contract(
            flow_aggregate_input_tuple_index(location), base_type, result_type,
            flow_semantic_role_read(), false)
    }
    make_structural_flow_projection_contract(
        flow_aggregate_input_structural_path(location),
        base_type, result_type, flow_semantic_role_read(), false)
}

fn flow_place_type(
    body: FlowBody, type_nodes: List<FlowTypeNode>,
    callables: List<FlowCallable>, place: FlowPlaceRef
) -> CoreTypeRef {
    if flow_place_is_slot(place) {
        return slot_type_for(body, flow_place_slot(place))
    }
    let value_type = flow_place_value_type(place)
    let contract = flow_place_projection(place)
    require_same_flow_type(
        slot_type_for(body, flow_place_base(place)), contract.base_type,
        "FlowIR: place base type differs")
    require_same_flow_type(
        contract.result_type, value_type,
        "FlowIR: place projection value type differs")
    if contract.partial {
        panic("FlowIR: assign place projection cannot be partial")
    }
    validate_projection_contract(contract, type_nodes)
    value_type
}

fn callable_for_symbol(
    callables: List<FlowCallable>, symbol: SymbolRef
) -> FlowCallable {
    let mut found: FlowCallable? = none
    for callable in callables {
        if executable_ref_is_named(callable.reference) &&
           symbol_ref_same(
                executable_ref_named_symbol(callable.reference), symbol) {
            if found.is_some() {
                panic("FlowIR: intrinsic symbol has multiple callable contracts")
            }
            found = some(callable)
        }
    }
    match found {
        some(value) => value,
        none => panic("FlowIR: intrinsic contract has no callable")
    }
}

fn validate_variant_construct_contract(
    operation: FlowOperationContract, variant: VariantRef,
    storage_contract: FlowStorageContract,
    type_nodes: List<FlowTypeNode>
) {
    let target = type_node_for(type_nodes, operation.target_type)
    let nominal = match target.nominal {
        some(value) => value,
        none => panic("FlowIR: variant construct target is not nominal")
    }
    if flow_type_kind_tag(target.kind) != FLOW_TYPE_ENUM ||
       !symbol_ref_same(
            nominal,
            registered_nominal_ref_symbol(variant_ref_owner(variant))) ||
       flow_semantic_role_tag(operation.target_role) !=
            flow_semantic_role_tag(flow_semantic_role_read()) ||
       !flow_value_origin_is_fresh(operation.target_origin) {
        panic("FlowIR: variant construct target contract differs")
    }
    let expected_storage = if variant_ref_same(
            variant, builtin_option_none_variant_ref()) {
        flow_borrow_storage()
    } else { flow_own_storage() }
    if flow_storage_contract_tag(storage_contract) !=
            flow_storage_contract_tag(expected_storage) {
        panic("FlowIR: variant construct result storage differs")
    }

    let mut expected: List<VariantFieldRef> = []
    for fact in target.nominal_fields {
        let identity = fact.identity
        if flow_field_identity_is_variant(identity) {
            let field = flow_field_identity_variant(identity)
            if variant_ref_same(
                    variant_field_ref_variant(field), variant) {
                expected.push(field)
            }
        }
    }
    if expected.len() != operation.input_types.len() ||
       expected.len() != operation.input_locations.len() ||
       expected.len() != operation.input_roles.len() {
        panic("FlowIR: variant construct field census differs")
    }
    let mut index = 0
    while index < expected.len() {
        if flow_semantic_role_tag(
                operation.input_roles.get(index).unwrap()) !=
                flow_semantic_role_tag(flow_semantic_role_consume()) {
            panic("FlowIR: variant construct field role differs")
        }
        let location = match operation.input_locations.get(index).unwrap() {
            some(value) => value,
            none => panic("FlowIR: variant construct field identity is absent")
        }
        if flow_aggregate_input_kind_tag(location) != 1 {
            panic("FlowIR: variant construct field is not a variant field")
        }
        let actual = flow_aggregate_input_variant(location)
        if variant_field_ref_index(actual) != index ||
           !variant_field_ref_same(actual, expected.get(index).unwrap()) {
            panic("FlowIR: variant construct field owner/order differs")
        }
        index = index + 1
    }
}

fn validate_flow_type_substitutions_for_callable(
    substitutions: List<FlowTypeSubstitution>, callable: FlowCallable,
    type_nodes: List<FlowTypeNode>, message: Str
) {
    let mut prior_index = 0 - 1
    for substitution in substitutions {
        let parameter = flow_type_substitution_parameter(substitution)
        let mut found_index: Int? = none
        let mut index = 0
        while index < callable.type_formals.len() {
            let formal_ref = callable.type_formals.get(index).unwrap()
            let declared = flow_type_node_generic_param(
                type_node_for(type_nodes, formal_ref))
            if flow_generic_param_fact_same(parameter, declared) {
                if found_index.is_some() { panic(message) }
                found_index = some(index)
            }
            index = index + 1
        }
        let exact_index = match found_index {
            some(value) => value,
            none => panic(message)
        }
        if exact_index <= prior_index { panic(message) }
        let _ = type_node_for(
            type_nodes, flow_type_substitution_replacement(substitution))
        prior_index = exact_index
    }
}

fn validate_flow_effect_substitutions_for_callable(
    substitutions: List<CoreEffectSubstitution>, callable: FlowCallable,
    type_nodes: List<FlowTypeNode>, message: Str
) {
    if substitutions.len() != callable.effect_formals.len() {
        panic(message)
    }
    let mut index = 0
    while index < substitutions.len() {
        let substitution = substitutions.get(index).unwrap()
        if !effect_param_ref_same(
                core_effect_substitution_parameter(substitution),
                callable.effect_formals.get(index).unwrap()) {
            panic(message)
        }
        for atom in core_effect_set_atoms(core_effect_contract_exact(
                core_effect_substitution_replacement(substitution))) {
            let kind = core_effect_atom_kind_tag(atom)
            if kind == 0 || kind == 1 {
                let _ = type_node_for(type_nodes, core_effect_atom_type(atom))
            } else if kind == 3 {
                for ty in core_effect_atom_type_arguments(atom) {
                    let _ = type_node_for(type_nodes, ty)
                }
            }
        }
        index = index + 1
    }
}

fn validate_callable_value_contract(
    target_type: CoreTypeRef, callable: FlowCallable,
    type_substitutions: List<FlowTypeSubstitution>,
    effect_substitutions: List<CoreEffectSubstitution>,
    effects: CoreEffectInstantiation,
    type_nodes: List<FlowTypeNode>
) {
    let node = type_node_for(type_nodes, target_type)
    if !flow_type_kind_same(node.kind, flow_type_kind_callable()) {
        panic("FlowIR: callable value target is not callable typed")
    }
    validate_flow_type_substitutions_for_callable(
        type_substitutions, callable, type_nodes,
        "FlowIR: callable value type substitution differs")
    validate_flow_effect_substitutions_for_callable(
        effect_substitutions, callable, type_nodes,
        "FlowIR: callable value effect substitution differs")
    if !core_effect_instantiation_projects_substitutions(
            effect_substitutions, effects) {
        panic("FlowIR: callable value top effect projection differs")
    }
    if !flow_type_actual_satisfies_substituted_formal(
            type_nodes, target_type, callable.header_type,
            type_substitutions, effect_substitutions) ||
       !flow_effect_actual_satisfies_substituted_formal(
            type_nodes, core_effect_instantiation_source(effects),
            callable.effects, type_substitutions,
            effect_substitutions) ||
       !core_effect_contract_same(
            node.callable_effects.unwrap(),
            core_effect_instantiation_result(effects)) {
        panic("FlowIR: callable value instantiation differs")
    }
}

fn validate_literal_or_primitive_contract(
    operation: FlowOperationContract, type_nodes: List<FlowTypeNode>
) {
    let target_kind = flow_type_kind_tag(
        type_node_for(type_nodes, operation.target_type).kind)
    match operation.value {
        FlowOperationValue::IntLiteralOperationValue(_) => if
            target_kind != FLOW_TYPE_INT {
            panic("FlowIR: Int literal target type differs")
        },
        FlowOperationValue::FloatLiteralOperationValue(_) => if
            target_kind != FLOW_TYPE_FLOAT {
            panic("FlowIR: Float literal target type differs")
        },
        FlowOperationValue::StrLiteralOperationValue(_) => if
            target_kind != FLOW_TYPE_STR {
            panic("FlowIR: Str literal target type differs")
        },
        FlowOperationValue::BoolLiteralOperationValue(_) => if
            target_kind != FLOW_TYPE_BOOL {
            panic("FlowIR: Bool literal target type differs")
        },
        FlowOperationValue::UnitLiteralOperationValue => if
            target_kind != FLOW_TYPE_UNIT {
            panic("FlowIR: Unit literal target type differs")
        },
        FlowOperationValue::PrimitiveOperationValue(primitive) => {
            let tag = flow_primitive_op_tag(primitive)
            if tag == FLOW_PRIMITIVE_NEGATE {
                if operation.input_types.len() != 1 {
                    panic("FlowIR: negate arity differs")
                }
                require_same_flow_type(
                    operation.input_types.get(0).unwrap(),
                    operation.target_type,
                    "FlowIR: negate input/result type differs")
            } else if tag == FLOW_PRIMITIVE_NOT {
                if operation.input_types.len() != 1 ||
                   target_kind != FLOW_TYPE_BOOL ||
                   flow_type_kind_tag(type_node_for(
                        type_nodes,
                        operation.input_types.get(0).unwrap()).kind) !=
                        FLOW_TYPE_BOOL {
                    panic("FlowIR: not input/result contract differs")
                }
            } else {
                if operation.input_types.len() != 2 {
                    panic("FlowIR: binary primitive arity differs")
                }
                require_same_flow_type(
                    operation.input_types.get(0).unwrap(),
                    operation.input_types.get(1).unwrap(),
                    "FlowIR: binary primitive operand types differ")
                if tag >= FLOW_PRIMITIVE_LT && tag <= FLOW_PRIMITIVE_GE {
                    if target_kind != FLOW_TYPE_BOOL {
                        panic("FlowIR: comparison result is not Bool")
                    }
                } else {
                    require_same_flow_type(
                        operation.input_types.get(0).unwrap(),
                        operation.target_type,
                        "FlowIR: arithmetic input/result type differs")
                }
            }
        },
        _ => {}
    }
}

fn validate_projection_contract(
    contract: FlowProjectionContract,
    type_nodes: List<FlowTypeNode>
) {
    let base = type_node_for(type_nodes, contract.base_type)
    let _ = type_node_for(type_nodes, contract.result_type)
    let _ = flow_semantic_role_tag(contract.base_role)
    match contract.value {
        FlowProjectionContractValue::StructuralProjectionValue(_) => {
            let kind = flow_type_kind_tag(base.kind)
            if kind != FLOW_TYPE_TUPLE && kind != FLOW_TYPE_RECORD {
                panic("FlowIR: structural projection base is not tuple/record")
            }
        },
        FlowProjectionContractValue::TupleProjectionValue(index) => {
            if flow_type_kind_tag(base.kind) != FLOW_TYPE_TUPLE ||
               index < 0 || index >= base.children.len() {
                panic("FlowIR: tuple projection index/result type differs")
            }
            require_flow_type_actual_satisfies_formal(
                contract.result_type, base.children.get(index).unwrap(),
                type_nodes,
                "FlowIR: tuple projection index/result type differs")
        },
        FlowProjectionContractValue::NominalProjectionValue(field) => {
            let nominal = match base.nominal {
                some(symbol) => symbol,
                none => panic("FlowIR: nominal projection base is not nominal")
            }
            if !symbol_ref_same(nominal_field_ref_owner(field), nominal) {
                panic("FlowIR: nominal projection field crosses base owner")
            }
            let mut matches = 0
            for fact in base.nominal_fields {
                if flow_field_identity_is_nominal(fact.identity) &&
                   nominal_field_ref_same(
                        flow_field_identity_nominal(fact.identity), field) {
                    require_flow_type_actual_satisfies_formal(
                        contract.result_type, fact.ty, type_nodes,
                        "FlowIR: nominal projection result type differs")
                    matches = matches + 1
                }
            }
            if matches != 1 {
                panic("FlowIR: nominal projection field fact is not exact")
            }
        },
        FlowProjectionContractValue::VariantProjectionValue(field) => {
            let nominal = match base.nominal {
                some(symbol) => symbol,
                none => panic("FlowIR: variant projection base is not nominal")
            }
            if !symbol_ref_same(
                    registered_nominal_ref_symbol(variant_ref_owner(
                        variant_field_ref_variant(field))), nominal) {
                panic("FlowIR: variant projection field crosses base owner")
            }
            let mut matches = 0
            for fact in base.nominal_fields {
                if flow_field_identity_is_variant(fact.identity) &&
                   variant_field_ref_same(
                        flow_field_identity_variant(fact.identity), field) {
                    require_flow_type_actual_satisfies_formal(
                        contract.result_type, fact.ty, type_nodes,
                        "FlowIR: variant projection result type differs")
                    matches = matches + 1
                }
            }
            if matches != 1 {
                panic("FlowIR: variant projection field fact is not exact")
            }
        }
    }
}

fn validate_typed_instructions(
    bodies: List<FlowBody>, callables: List<FlowCallable>,
    type_nodes: List<FlowTypeNode>
) {
    for body in bodies {
        for block in body.blocks {
            for instruction in block.instructions {
                match instruction.value {
                    FlowInstructionValue::InitializeValue {
                        operation, inputs, target
                    } => {
                        if operation.input_roles.len() != inputs.len() ||
                           operation.input_types.len() != inputs.len() ||
                           operation.input_locations.len() != inputs.len() {
                            panic("FlowIR: Initialize typed contract is partial")
                        }
                        let mut index = 0
                        while index < inputs.len() {
                            match operation.input_locations.get(index).unwrap() {
                                some(location) => {
                                    require_flow_type_actual_satisfies_formal(
                                        slot_type_for(
                                            body,
                                            inputs.get(index).unwrap()),
                                        operation.input_types.get(
                                            index).unwrap(),
                                        type_nodes,
                                        "FlowIR: Initialize input slot type differs")
                                    validate_projection_contract(
                                        aggregate_input_projection(
                                            location, operation.target_type,
                                            operation.input_types.get(
                                                index).unwrap()),
                                        type_nodes)
                                },
                                none => require_same_flow_type(
                                    slot_type_for(
                                        body, inputs.get(index).unwrap()),
                                    operation.input_types.get(index).unwrap(),
                                    "FlowIR: Initialize input slot type differs")
                            }
                            index = index + 1
                        }
                        require_same_flow_type(
                            slot_type_for(body, target), operation.target_type,
                            "FlowIR: Initialize target slot type differs")
                        validate_literal_or_primitive_contract(
                            operation, type_nodes)
                        match operation.value {
                            FlowOperationValue::VariantConstructOperationValue(
                                variant
                            ) => validate_variant_construct_contract(
                                operation, variant,
                                slot_for_ref(
                                    body.slots, target).storage_contract,
                                type_nodes),
                            FlowOperationValue::EffectCtxOverlayOperationValue {
                                parent, child, entries
                            } => {
                                if entries.len() == 0 || inputs.len() == 0 ||
                                   !slot_ref_same(
                                        inputs.get(0).unwrap(),
                                        effect_ctx_slot(parent)) ||
                                   !slot_ref_same(target, effect_ctx_slot(child)) {
                                    panic("FlowIR: EffectCtx overlay slot relation differs")
                                }
                            },
                            FlowOperationValue::ClosureOperationValue {
                                executable, capture_targets
                            } => {
                                let callable = callable_for_ref(callables, executable)
                                validate_callable_value_contract(
                                    operation.target_type, callable, [], [],
                                    make_explicit_core_effect_instantiation(
                                        callable.effects, callable.effects,
                                        callable.effects), type_nodes)
                                if !executable_contract_mode_same(
                                        callable.mode,
                                        executable_contract_mode_concrete_body()) {
                                    panic("FlowIR: closure executable is bodyless")
                                }
                                let mut child: FlowBody? = none
                                for candidate in bodies {
                                    if executable_ref_same(
                                            candidate.reference, executable) {
                                        if child.is_some() {
                                            panic("FlowIR: closure executable repeats a body")
                                        }
                                        child = some(candidate)
                                    }
                                }
                                let child_body = match child {
                                    some(value) => value,
                                    none => panic(
                                        "FlowIR: closure executable has no body")
                                }
                                if capture_targets.len() !=
                                        operation.input_types.len() {
                                    panic("FlowIR: closure capture contract is partial")
                                }
                                let mut capture_index = 0
                                while capture_index < capture_targets.len() {
                                    require_same_flow_type(
                                        slot_type_for(
                                            child_body,
                                            capture_targets.get(
                                                capture_index).unwrap()),
                                        operation.input_types.get(
                                            capture_index).unwrap(),
                                        "FlowIR: closure capture target type differs")
                                    capture_index = capture_index + 1
                                }
                            },
                            FlowOperationValue::CallableValueOperationValue {
                                executable, evidence, type_substitutions,
                                effect_substitutions, effects
                            } => {
                                let callable = callable_for_ref(callables, executable)
                                validate_callable_value_contract(
                                    operation.target_type, callable,
                                    type_substitutions, effect_substitutions,
                                    effects, type_nodes)
                                for item in evidence {
                                    validate_dictionary_evidence(
                                        flow_evidence_dict(item), body)
                                }
                            },
                            FlowOperationValue::DictConstructOperationValue {
                                ..
                            } => validate_dict_construct_initialize(
                                operation, inputs, target, body, type_nodes),
                            _ => {}
                        }
                    },
                    FlowInstructionValue::ReadValue { source, target } =>
                        require_same_flow_type(
                            slot_type_for(body, source),
                            slot_type_for(body, target),
                            "FlowIR: Read source/target type differs"),
                    FlowInstructionValue::MutateValue { target, value, .. } =>
                        require_same_flow_type(
                            slot_type_for(body, target),
                            slot_type_for(body, value),
                            "FlowIR: Mutate target/value type differs"),
                    FlowInstructionValue::FailRaiseValue { payload, sink } =>
                        require_same_flow_type(
                            slot_type_for(body, payload),
                            slot_type_for(body, sink),
                            "FlowIR: FailRaise payload/sink type differs"),
                    FlowInstructionValue::AssignValue { rhs_temp, target } =>
                        require_same_flow_type(
                            slot_type_for(body, rhs_temp),
                            flow_place_type(body, type_nodes, callables, target),
                            "FlowIR: Assign RHS/target type differs"),
                    FlowInstructionValue::MovePlaceValue { source, target } =>
                        require_same_flow_type(
                            flow_place_type(body, type_nodes, callables, source),
                            slot_type_for(body, target),
                            "FlowIR: MovePlace source/target type differs"),
                    FlowInstructionValue::CaptureValue {
                        source, target, ..
                    } => require_same_flow_type(
                        slot_type_for(body, source),
                        slot_type_for(body, target),
                        "FlowIR: Capture source/target type differs"),
                    FlowInstructionValue::CallValue {
                        target, arguments, effect_ctx, result, ..
                    } => {
                        let contract = target.contract
                        let parameter_types = flow_call_contract_parameter_types(
                            contract)
                        let result_type = flow_call_contract_result_type(contract)
                        if arguments.len() != parameter_types.len() {
                            panic("FlowIR: Call argument/type arity differs")
                        }
                        let mut index = 0
                        while index < arguments.len() {
                            if !flow_type_actual_satisfies_formal(
                                    type_nodes,
                                    type_node_for(type_nodes, slot_type_for(
                                        body, arguments.get(index).unwrap())),
                                    type_node_for(type_nodes,
                                        parameter_types.get(index).unwrap())) {
                                panic("FlowIR: Call argument slot type differs")
                            }
                            index = index + 1
                        }
                        match result {
                            some(slot) => require_same_flow_type(
                                slot_type_for(body, slot), result_type,
                                "FlowIR: Call result slot type differs"),
                            none => {
                                let kind = flow_type_kind_tag(type_node_for(
                                    type_nodes, result_type).kind)
                                if kind != FLOW_TYPE_UNIT &&
                                   kind != FLOW_TYPE_NEVER {
                                    panic("FlowIR: value-returning Call has no result slot")
                                }
                            }
                        }
                        if !flow_call_target_is_direct(target) {
                            let target_slot = if flow_call_target_is_local(target) {
                                slot_for_ref(
                                    body.slots, flow_call_target_local(target))
                            } else {
                                dynamic_call_slot_for_path(
                                    body.slots, flow_call_target_dynamic(target))
                            }
                            let callable_type = type_node_for(
                                type_nodes, target_slot.ty)
                            if !flow_type_kind_same(
                                    callable_type.kind,
                                    flow_type_kind_callable()) ||
                               callable_type.parameter_count !=
                                    parameter_types.len() {
                                panic("FlowIR: local callee slot is not exact callable type")
                            }
                            let mut callable_index = 0
                            while callable_index < parameter_types.len() {
                                if !flow_type_actual_satisfies_formal(
                                        type_nodes,
                                        type_node_for(type_nodes,
                                            parameter_types.get(
                                                callable_index).unwrap()),
                                        type_node_for(type_nodes,
                                            callable_type.children.get(
                                                callable_index).unwrap())) {
                                    panic("FlowIR: local callee parameter type differs")
                                }
                                callable_index = callable_index + 1
                            }
                            require_same_flow_type(
                                callable_type.children.get(
                                    callable_type.parameter_count).unwrap(),
                                result_type,
                                "FlowIR: local callee result type differs")
                            if !core_effect_contract_same(
                                    callable_type.callable_effects.unwrap(),
                                    core_effect_instantiation_source(
                                        target.effects)) {
                                panic("FlowIR: indirect callee effect source differs")
                            }
                        }
                        if flow_effect_ctx_use_kind_tag(effect_ctx) == 1 &&
                           !core_effect_contract_same(
                                core_effect_instantiation_result(
                                    core_effect_ctx_argument_receipt(
                                        flow_effect_ctx_use_argument(
                                            effect_ctx))),
                                core_effect_instantiation_result(
                                    target.effects)) {
                            panic("FlowIR: call EffectCtx receipt differs")
                        }
                    },
                    FlowInstructionValue::ProjectValue {
                        contract, base, result
                    } => {
                        require_same_flow_type(
                            slot_type_for(body, base), contract.base_type,
                            "FlowIR: Project base slot type differs")
                        require_same_flow_type(
                            slot_type_for(body, result), contract.result_type,
                            "FlowIR: Project result slot type differs")
                        validate_projection_contract(contract, type_nodes)
                    },
                    _ => {}
                }
            }
        }
    }
}

// ============================================================
// Deterministic topology fingerprint and frozen program
// ============================================================

fn encode_atom(value: Str) -> Str { "${value.len()}:${value}" }

fn encode_symbol(value: SymbolRef) -> Str {
    [
        "S",
        encode_atom(symbol_ref_origin_module_key(value)),
        namespace_kind_tag(symbol_ref_namespace_kind(value)).to_str(),
        encode_atom(symbol_ref_canonical_payload(value)),
        encode_atom(symbol_ref_declaration_site_path(value))
    ].join("/")
}

fn encode_variant_ref(value: VariantRef) -> Str {
    [
        "V",
        encode_symbol(registered_nominal_ref_symbol(
            variant_ref_owner(value))),
        encode_symbol(variant_ref_member(value)),
        variant_ref_source_index(value).to_str()
    ].join("/")
}

fn encode_path_owner(value: PathOwnerRef) -> Str {
    if path_owner_ref_is_symbol(value) {
        "OS/${encode_symbol(path_owner_ref_symbol(value))}"
    } else {
        let body = path_owner_ref_module_body(value)
        "OM/${encode_atom(module_body_ref_origin_module_key(body))}/${encode_atom(module_body_ref_declaration_site_path(body))}"
    }
}

fn encode_path(value: PathRef) -> Str {
    let mut parts: List<Str> = [
        "P", encode_path_owner(path_ref_owner(value)),
        path_role_tag(path_ref_role(value)).to_str()
    ]
    for component in path_ref_normalized_child_path(value) {
        parts.push(encode_atom(component))
    }
    parts.join("/")
}

fn encode_slot(value: SlotRef) -> Str {
    if slot_ref_is_source(value) {
        [
            "SL", encode_atom(slot_ref_source_origin_module_key(value)),
            slot_domain_tag(slot_ref_source_domain(value)).to_str(),
            slot_ref_source_def_id(value).to_str()
        ].join("/")
    } else {
        "SS/${encode_path(slot_ref_synthetic_path(value))}"
    }
}

fn encode_executable(value: ExecutableRef) -> Str {
    if executable_ref_is_named(value) {
        "EN/${encode_symbol(executable_ref_named_symbol(value))}"
    } else {
        "EA/${encode_path(executable_ref_anonymous_path(value))}"
    }
}

fn encode_origin(value: OriginRef) -> Str {
    if origin_ref_is_symbol(value) {
        "ON/${encode_symbol(origin_ref_symbol(value))}"
    } else {
        "OP/${encode_path(origin_ref_path(value))}"
    }
}

fn encode_type_ref(value: CoreTypeRef) -> Str {
    "T${core_type_ref_index(value).to_str()}"
}
fn encode_field_identity(value: FlowFieldIdentity) -> Str {
    if flow_field_identity_is_nominal(value) {
        let field = flow_field_identity_nominal(value)
        [
            "FN", encode_symbol(nominal_field_ref_owner(field)),
            encode_symbol(nominal_field_ref_member(field)),
            nominal_field_ref_index(field).to_str()
        ].join("/")
    } else if flow_field_identity_is_variant(value) {
        let field = flow_field_identity_variant(value)
        "FV/${variant_field_ref_index(field).to_str()}/${
            encode_symbol(variant_field_ref_member(field))}"
    } else {
        "FP/${encode_path(flow_field_identity_path(value))}"
    }
}
fn encode_scope_ref(value: FlowScopeRef) -> Str {
    "Q/${encode_executable(value.owner)}/${value.ordinal.to_str()}"
}
fn encode_block_ref(value: FlowBlockRef) -> Str {
    "B/${encode_executable(value.owner)}/${value.ordinal.to_str()}"
}
fn encode_instruction_ref(value: FlowInstructionRef) -> Str {
    "I/${encode_executable(value.owner)}/${value.block_ordinal.to_str()}/${value.instruction_ordinal.to_str()}"
}

fn encode_value_origin(value: FlowValueOriginContract) -> Str {
    if flow_value_origin_is_fresh(value) { return "fresh" }
    let mut parts: List<Str> = ["alias"]
    for ordinal in flow_value_origin_alias_ordinals(value) {
        parts.push(ordinal.to_str())
    }
    parts.join(":")
}

fn encode_effect_contract(value: CoreEffectContract) -> Str {
    let mut parts: List<Str> = []
    for atom in core_effect_set_atoms(core_effect_contract_exact(value)) {
        let kind = core_effect_atom_kind_tag(atom)
        let encoded = if kind == 0 {
            "F${encode_type_ref(core_effect_atom_type(atom))}"
        } else if kind == 1 {
            "M${encode_type_ref(core_effect_atom_type(atom))}"
        } else if kind == 2 {
            "U"
        } else if kind == 3 {
                let mut item = "H${encode_symbol(
                    handled_effect_ref_symbol(
                        core_effect_atom_handled_ref(atom)))}"
                for ty in core_effect_atom_type_arguments(atom) {
                    item = "${item}/${encode_type_ref(ty)}"
                }
                item
        } else if kind == 4 {
            "S${system_effect_ref_tag(
                core_effect_atom_system_ref(atom)).to_str()}"
        } else {
            panic("FlowIR: unknown effect atom in fingerprint")
        }
        parts.push(encoded)
    }
    match core_effect_contract_parameter(value) {
        some(parameter) => parts.push(
            "P${encode_origin(effect_param_owner(parameter))}/${
                effect_param_ordinal(parameter).to_str()}"),
        none => {}
    }
    parts.join(",")
}

fn encode_effect_instantiation(value: CoreEffectInstantiation) -> Str {
    let mut substitutions: List<Str> = []
    for substitution in core_effect_instantiation_substitutions(value) {
        let parameter = core_effect_substitution_parameter(substitution)
        substitutions.push("${encode_origin(
            effect_param_owner(parameter))}/${
            effect_param_ordinal(parameter).to_str()}=${
            encode_effect_contract(
                core_effect_substitution_replacement(substitution))}")
    }
    "${encode_effect_contract(core_effect_instantiation_source(value))}=>${
        substitutions.join(",")}=>${encode_effect_contract(
            core_effect_instantiation_result(value))}"
}

fn encode_call_target(value: FlowCallTarget) -> Str {
    let base = match value.value {
        FlowCallTargetValue::DirectTargetValue(target) =>
            "CD/${encode_executable(target)}",
        FlowCallTargetValue::LocalTargetValue(target) =>
            "CL/${encode_slot(target)}",
        FlowCallTargetValue::DynamicTargetValue(target) =>
            "CY/${encode_path(target)}"
    }
    let mut parts: List<Str> = [base]
    for ty in flow_call_contract_parameter_types(value.contract) {
        parts.push("T${encode_type_ref(ty)}")
    }
    for role in flow_call_contract_parameter_roles(value.contract) {
        parts.push("P${flow_semantic_role_tag(role).to_str()}")
    }
    parts.push("R${flow_semantic_role_tag(
        flow_call_contract_result_role(value.contract)).to_str()}")
    parts.push("Y${encode_type_ref(
        flow_call_contract_result_type(value.contract))}")
    parts.push("O${encode_value_origin(
        flow_call_contract_result_origin(value.contract))}")
    parts.push("E${encode_effect_instantiation(value.effects)}")
    for substitution in value.type_substitutions {
        let parameter = flow_type_substitution_parameter(substitution)
        parts.push("X${encode_symbol(flow_generic_param_owner(parameter))}/${
            flow_generic_param_index(parameter).to_str()}/${
            flow_generic_param_arity(parameter).to_str()}=${encode_type_ref(
                flow_type_substitution_replacement(substitution))}")
    }
    for substitution in value.effect_substitutions {
        let parameter = core_effect_substitution_parameter(substitution)
        parts.push("Z${encode_origin(effect_param_owner(parameter))}/${
            effect_param_ordinal(parameter).to_str()}=${
            encode_effect_contract(
                core_effect_substitution_replacement(substitution))}")
    }
    parts.join("/")
}

fn encode_effect_ctx_ref(value: EffectCtxRef) -> Str {
    [encode_executable(effect_ctx_contract_owner(value)),
     encode_slot(effect_ctx_slot(value))].join("/")
}
fn encode_effect_ctx_token(value: CoreEffectCtxTokenRef) -> Str {
    let atom = core_effect_ctx_token_instance(value)
    let mut parts: List<Str> = [
        encode_symbol(handled_effect_ref_symbol(
            core_effect_atom_handled_ref(atom)))
    ]
    for ty in core_effect_atom_type_arguments(atom) {
        parts.push(encode_type_ref(ty))
    }
    parts.join("/")
}
fn encode_effect_ctx_layout(value: CoreEffectCtxLayout) -> Str {
    let mut parts: List<Str> = []
    for entry in core_effect_ctx_layout_entries(value) {
        parts.push(encode_effect_ctx_token(entry))
    }
    match core_effect_ctx_layout_formal(value) {
        some(formal) => parts.push("F/${encode_origin(
            effect_param_owner(formal))}/${effect_param_ordinal(formal).to_str()}"),
        none => parts.push("C")
    }
    parts.join("|")
}
fn encode_effect_ctx_argument(value: CoreEffectCtxArgument) -> Str {
    let kind = core_effect_ctx_argument_kind_tag(value)
    let mut parts: List<Str> = ["A${kind.to_str()}"]
    if kind != 0 {
        parts.push(encode_effect_ctx_ref(
            core_effect_ctx_argument_context(value)))
        parts.push(encode_effect_ctx_layout(
            core_effect_ctx_argument_source_layout(value)))
    }
    parts.push(encode_effect_ctx_layout(
        core_effect_ctx_argument_target_layout(value)))
    parts.push(encode_effect_instantiation(
        core_effect_ctx_argument_receipt(value)))
    parts.join("/")
}
fn encode_flow_effect_ctx_use(value: FlowEffectCtxUse) -> Str {
    let kind = flow_effect_ctx_use_kind_tag(value)
    if kind == 0 { return "foreign" }
    if kind == 1 {
        return encode_effect_ctx_argument(
            flow_effect_ctx_use_argument(value))
    }
    let lookup = flow_effect_ctx_use_lookup(value)
    ["lookup", encode_effect_ctx_ref(
        core_effect_ctx_lookup_context(lookup)),
     encode_effect_ctx_layout(core_effect_ctx_lookup_layout(lookup)),
     encode_effect_ctx_token(core_effect_ctx_lookup_token(lookup))].join("/")
}

fn encode_operation(value: FlowOperationContract) -> Str {
    let mut parts: List<Str> = [
        "O${flow_operation_contract_kind_tag(value).to_str()}"
    ]
    match value.value {
        FlowOperationValue::IntLiteralOperationValue(literal) =>
            parts.push(literal.to_str()),
        FlowOperationValue::FloatLiteralOperationValue(literal) =>
            parts.push(literal.to_str()),
        FlowOperationValue::StrLiteralOperationValue(literal) =>
            parts.push(encode_atom(literal)),
        FlowOperationValue::BoolLiteralOperationValue(literal) =>
            parts.push(if literal { "true" } else { "false" }),
        FlowOperationValue::UnitLiteralOperationValue => parts.push("unit"),
        FlowOperationValue::PrimitiveOperationValue(operation) =>
            parts.push(flow_primitive_op_tag(operation).to_str()),
        FlowOperationValue::VariantConstructOperationValue(variant) =>
            parts.push(encode_variant_ref(variant)),
        FlowOperationValue::EffectCtxOverlayOperationValue {
            parent, child, entries
        } => {
            parts.push("parent:${encode_effect_ctx_ref(parent)}")
            parts.push("child:${encode_effect_ctx_ref(child)}")
            for entry in entries {
                parts.push("entry:${encode_effect_ctx_token(entry)}")
            }
        },
        FlowOperationValue::TupleAggregateOperationValue(arity) =>
            parts.push("tuple:${arity.to_str()}"),
        FlowOperationValue::RecordAggregateOperationValue(arity) =>
            parts.push("record:${arity.to_str()}"),
        FlowOperationValue::ClosureOperationValue {
            executable, capture_targets
        } => {
            parts.push("closure:${encode_executable(executable)}")
            for target in capture_targets {
                parts.push("capture:${encode_slot(target)}")
            }
        },
        FlowOperationValue::CallableValueOperationValue {
            executable, evidence, type_substitutions,
            effect_substitutions, effects
        } => {
            parts.push("callable:${encode_executable(executable)}")
            for item in evidence {
                parts.push("evidence:${encode_dict_evidence(
                    flow_evidence_dict(item))}")
            }
            parts.push("effects:${encode_effect_instantiation(effects)}")
            for substitution in type_substitutions {
                let parameter = flow_type_substitution_parameter(substitution)
                parts.push("type:${encode_symbol(
                    flow_generic_param_owner(parameter))}/${
                    flow_generic_param_index(parameter).to_str()}/${
                    flow_generic_param_arity(parameter).to_str()}=${
                    encode_type_ref(flow_type_substitution_replacement(
                        substitution))}")
            }
            for substitution in effect_substitutions {
                let parameter = core_effect_substitution_parameter(substitution)
                parts.push("effect:${encode_origin(
                    effect_param_owner(parameter))}/${
                    effect_param_ordinal(parameter).to_str()}=${
                    encode_effect_contract(
                        core_effect_substitution_replacement(substitution))}")
            }
        },
        FlowOperationValue::DictConstructOperationValue {
            dictionary, result
        } => {
            parts.push("dictionary:${encode_dict_evidence(dictionary)}")
            parts.push("result:${encode_slot(result)}")
        }
    }
    for ty in value.input_types {
        parts.push("T${encode_type_ref(ty)}")
    }
    for role in value.input_roles {
        parts.push("P${flow_semantic_role_tag(role).to_str()}")
    }
    for location in value.input_locations {
        parts.push(match location {
            some(exact) => {
                let kind = flow_aggregate_input_kind_tag(exact)
                if kind == 0 {
                    "LN${encode_field_identity(make_nominal_flow_field_identity(
                        flow_aggregate_input_nominal(exact)))}"
                } else if kind == 1 {
                    "LV${encode_field_identity(make_variant_flow_field_identity(
                        flow_aggregate_input_variant(exact)))}"
                } else if kind == 2 {
                    "LT${flow_aggregate_input_tuple_index(exact).to_str()}"
                } else {
                    "LS${encode_path(
                        flow_aggregate_input_structural_path(exact))}"
                }
            },
            none => "L-"
        })
    }
    parts.push("R${flow_semantic_role_tag(value.target_role).to_str()}")
    parts.push("Y${encode_type_ref(value.target_type)}")
    parts.push("A${encode_value_origin(value.target_origin)}")
    parts.join("/")
}

fn encode_flow_place(value: FlowPlaceRef) -> Str {
    if flow_place_is_slot(value) {
        return "PS/${encode_slot(flow_place_slot(value))}"
    }
    let mut parts: List<Str> = [
        "PP", encode_slot(flow_place_base(value)),
        encode_type_ref(flow_place_value_type(value))
    ]
    parts.push(encode_projection_contract(flow_place_projection(value)))
    parts.join("/")
}

fn encode_impl_owner(value: ImplOwnerRef) -> Str {
    let provider = impl_owner_ref_provider(value)
    let trait_identity = match impl_owner_ref_trait(value) {
        some(reference) => encode_symbol(reference),
        none => "inherent"
    }
    "${encode_symbol(impl_owner_ref_target(value))}/${encode_path(
        impl_provider_ref_site(provider))}/${impl_provider_kind_tag(
        impl_provider_ref_kind(provider)).to_str()}/${trait_identity}"
}

fn encode_dict_evidence(value: ExactDictRef) -> Str {
    if dict_ref_is_local(value) {
        "local:${encode_slot(dict_ref_local(value))}"
    } else if dict_ref_is_static(value) {
        "static:${encode_impl_owner(dict_ref_static(value))}"
    } else {
        let mut parts: List<Str> = [
            "wrapped", encode_impl_owner(dict_ref_wrapped_base(value))
        ]
        for inner in dict_ref_wrapped_inner(value) {
            parts.push(encode_dict_evidence(inner))
        }
        parts.join("/")
    }
}

fn encode_projection_contract(value: FlowProjectionContract) -> Str {
    let identity = match value.value {
        FlowProjectionContractValue::NominalProjectionValue(field) =>
            "N${encode_field_identity(make_nominal_flow_field_identity(field))}",
        FlowProjectionContractValue::VariantProjectionValue(field) =>
            "V${encode_field_identity(make_variant_flow_field_identity(field))}",
        FlowProjectionContractValue::TupleProjectionValue(index) =>
            "T${index.to_str()}",
        FlowProjectionContractValue::StructuralProjectionValue(path) =>
            "S${encode_path(path)}"
    }
    "${identity}/${encode_type_ref(value.base_type)}/${encode_type_ref(value.result_type)}/${flow_semantic_role_tag(value.base_role).to_str()}/${if value.partial { "partial" } else { "total" }}"
}

fn encode_scope_refs(values: List<FlowScopeRef>) -> Str {
    let mut parts: List<Str> = []
    for value in values { parts.push(encode_scope_ref(value)) }
    parts.join(",")
}

fn encode_successor(value: FlowSuccessor) -> Str {
    "${encode_block_ref(value.target)}[x:${encode_scope_refs(value.exited_scopes)}][e:${encode_scope_refs(value.entered_scopes)}]"
}

fn encode_instruction(value: FlowInstruction) -> Str {
    let mut parts: List<Str> = [
        encode_instruction_ref(value.reference),
        encode_origin(value.origin),
        flow_instruction_kind_tag(value).to_str()
    ]
    match value.value {
        FlowInstructionValue::InitializeValue { operation, inputs, target } => {
            parts.push(encode_operation(operation))
            for input in inputs { parts.push(encode_slot(input)) }
            parts.push(encode_slot(target))
        },
        FlowInstructionValue::ReadValue { source, target } => {
            parts.push(encode_slot(source)); parts.push(encode_slot(target))
        },
        FlowInstructionValue::MutateValue {
            target, value: input, target_role, value_role
        } => {
            parts.push(encode_slot(target)); parts.push(encode_slot(input))
            parts.push("T${flow_semantic_role_tag(target_role).to_str()}")
            parts.push("V${flow_semantic_role_tag(value_role).to_str()}")
        },
        FlowInstructionValue::ConsumeValue { source } =>
            parts.push(encode_slot(source)),
        FlowInstructionValue::DiscardValue { source } =>
            parts.push(encode_slot(source)),
        FlowInstructionValue::FailRaiseValue { payload, sink } => {
            parts.push(encode_slot(payload)); parts.push(encode_slot(sink))
        },
        FlowInstructionValue::AssignValue { rhs_temp, target } => {
            parts.push(encode_slot(rhs_temp)); parts.push(encode_flow_place(target))
        },
        FlowInstructionValue::MovePlaceValue { source, target } => {
            parts.push(encode_flow_place(source)); parts.push(encode_slot(target))
        },
        FlowInstructionValue::CallValue {
            target, arguments, evidence, effect_ctx, result
        } => {
            parts.push(encode_call_target(target))
            for argument in arguments { parts.push(encode_slot(argument)) }
            for item in evidence {
                parts.push("ED${encode_dict_evidence(flow_evidence_dict(item))}")
            }
            parts.push("EC${encode_flow_effect_ctx_use(effect_ctx)}")
            match result {
                some(slot) => parts.push(encode_slot(slot)),
                none => parts.push("void")
            }
        },
        FlowInstructionValue::ProjectValue {
            contract, base, result
        } => {
            parts.push(encode_projection_contract(contract))
            parts.push(encode_slot(base))
            parts.push(encode_slot(result))
        },
        FlowInstructionValue::CaptureValue {
            capture, source, target, source_role, target_role
        } => {
            parts.push(encode_path(capture)); parts.push(encode_slot(source))
            parts.push(encode_slot(target))
            parts.push("S${flow_semantic_role_tag(source_role).to_str()}")
            parts.push("T${flow_semantic_role_tag(target_role).to_str()}")
        },
        FlowInstructionValue::ScopeEnterValue { scope } => {
            parts.push(encode_scope_ref(scope))
        },
        FlowInstructionValue::ScopeExitValue { scope } => {
            parts.push(encode_scope_ref(scope))
        }
    }
    parts.join(";")
}

fn encode_flow_pattern(value: FlowPatternContract) -> Str {
    let mut parts: List<Str> = [
        flow_pattern_kind_tag(value).to_str(), encode_type_ref(value.ty)
    ]
    match value.value {
        FlowPatternContractValue::FlowWildcardPattern => {},
        FlowPatternContractValue::FlowBindingPattern(slot) =>
            parts.push(encode_slot(slot)),
        FlowPatternContractValue::FlowLiteralPattern(literal) => match
                literal.value {
            FlowPatternLiteralValue::PatternIntValue(item) =>
                parts.push(item.to_str()),
            FlowPatternLiteralValue::PatternFloatValue(item) =>
                parts.push(item.to_str()),
            FlowPatternLiteralValue::PatternStrValue(item) =>
                parts.push(encode_atom(item)),
            FlowPatternLiteralValue::PatternBoolValue(item) =>
                parts.push(if item { "true" } else { "false" }),
            FlowPatternLiteralValue::PatternUnitValue => parts.push("unit")
        },
        FlowPatternContractValue::FlowTuplePattern(elements) => {
            for element in elements { parts.push(encode_flow_pattern(element)) }
        },
        FlowPatternContractValue::FlowStructPattern {
            owner, fields: field_values
        } => {
            parts.push(encode_symbol(owner))
            for field in field_values {
                parts.push("${encode_field_identity(field.field)}=${encode_flow_pattern(field.pattern)}")
            }
        },
        FlowPatternContractValue::FlowVariantPattern {
            variant, fields: field_values
        } => {
            parts.push(encode_symbol(variant_ref_member(variant)))
            for field in field_values {
                parts.push("${encode_field_identity(field.field)}=${encode_flow_pattern(field.pattern)}")
            }
        }
    }
    parts.join("~")
}

fn encode_terminator(value: FlowTerminator) -> Str {
    let mut parts: List<Str> = [
        encode_origin(value.origin), flow_terminator_kind_tag(value).to_str()
    ]
    match value.value {
        FlowTerminatorValue::GotoValue(edge) =>
            parts.push(encode_successor(edge)),
        FlowTerminatorValue::BreakValue(edge) =>
            parts.push(encode_successor(edge)),
        FlowTerminatorValue::ContinueValue(edge) =>
            parts.push(encode_successor(edge)),
        FlowTerminatorValue::BranchValue {
            condition, when_true, when_false
        } => {
            parts.push(encode_slot(condition))
            parts.push(encode_successor(when_true))
            parts.push(encode_successor(when_false))
        },
        FlowTerminatorValue::LoopValue { condition, body, exit } => {
            parts.push(encode_slot(condition)); parts.push(encode_successor(body))
            parts.push(encode_successor(exit))
        },
        FlowTerminatorValue::ReturnValue { value: returned, exited_scopes } => {
            match returned {
                some(slot) => parts.push(encode_slot(slot)),
                none => parts.push("void")
            }
            parts.push(encode_scope_refs(exited_scopes))
        },
        FlowTerminatorValue::HandlerValue {
            operation, handled, unhandled
        } => {
            parts.push(encode_slot(operation))
            parts.push(encode_successor(handled))
            parts.push(encode_successor(unhandled))
        },
        FlowTerminatorValue::PatternValue {
            scrutinee, pattern, matched, unmatched
        } => {
            parts.push(encode_slot(scrutinee))
            parts.push(encode_flow_pattern(pattern))
            parts.push(encode_successor(matched))
            parts.push(encode_successor(unmatched))
        },
        FlowTerminatorValue::RaiseValue { error, caught } => {
            parts.push(encode_slot(error))
            parts.push(encode_successor(caught))
        },
        FlowTerminatorValue::HandleInstallValue {
            body, installation
        } => {
            parts.push(encode_successor(body))
            parts.push("P${encode_effect_ctx_ref(installation.parent)}")
            parts.push("C${encode_effect_ctx_ref(installation.child)}")
            for entry in installation.entries {
                parts.push("I${encode_effect_ctx_token(entry.token)}")
                for handler in entry.handlers {
                    parts.push("H${encode_symbol(
                        effect_operation_ref_member(handler.operation))}/${
                        encode_executable(handler.handler)}/${
                        encode_slot(handler.closure)}")
                }
            }
        },
        FlowTerminatorValue::UnreachableValue { exited_scopes } =>
            parts.push(encode_scope_refs(exited_scopes)),
        FlowTerminatorValue::DivergeValue { exited_scopes } =>
            parts.push(encode_scope_refs(exited_scopes))
    }
    parts.join(";")
}

fn compute_topology_encoding(
    type_nodes: List<FlowTypeNode>, callables: List<FlowCallable>,
    bodies: List<FlowBody>
) -> Str {
    let mut parts: List<Str> = ["FlowIR/0.1"]
    for node in type_nodes {
        let mut item: List<Str> = [
            "TY", core_type_ref_index(node.reference).to_str(),
            flow_type_kind_tag(node.kind).to_str(),
            node.parameter_count.to_str(),
            match node.generic_param {
                some(fact) => fact.index.to_str(),
                none => (0 - 1).to_str()
            }
        ]
        match node.nominal {
            some(symbol) => item.push(encode_symbol(symbol)),
            none => item.push("none")
        }
        item.push("S${flow_type_semantic_seed_tag(node.semantic_seed).to_str()}")
        for argument in node.generic_arguments {
            item.push("A${encode_type_ref(argument)}")
        }
        for child in node.children { item.push(encode_type_ref(child)) }
        for field in node.nominal_fields {
            item.push("F${encode_field_identity(field.identity)}/${encode_type_ref(field.ty)}")
        }
        match node.callable_effects {
            some(effects) => item.push(
                "CE${encode_effect_contract(effects)}"),
            none => {}
        }
        for ordinal in node.resource_storage_parameter_ordinals {
            item.push("Q${ordinal.to_str()}")
        }
        match node.generic_param {
            some(fact) => {
                item.push("G${encode_symbol(fact.owner)}/${fact.index.to_str()}/${fact.arity.to_str()}")
                for bound in fact.bounds {
                    item.push("D${encode_symbol(bound)}")
                }
            },
            none => {}
        }
        match node.drop_contract {
            some(contract) => item.push(
                "X${encode_executable(contract.provider)}"),
            none => {}
        }
        parts.push(item.join(";"))
    }
    for callable in callables {
        let mode_tag = if executable_contract_mode_same(
                callable.mode, executable_contract_mode_concrete_body()) {
            "0"
        } else if executable_contract_mode_same(
                callable.mode, executable_contract_mode_contract_only()) {
            "1"
        } else {
            panic("FlowIR: invalid executable contract mode")
        }
        let mut item: List<Str> = [
            "CA", encode_executable(callable.reference),
            encode_origin(callable.origin), mode_tag,
            "H${encode_type_ref(callable.header_type)}"
        ]
        let mut type_formal_ordinal = 0
        for formal in callable.type_formals {
            item.push("F${type_formal_ordinal.to_str()}/${
                encode_type_ref(formal)}")
            type_formal_ordinal = type_formal_ordinal + 1
        }
        for formal in callable.effect_formals {
            item.push("E${encode_origin(effect_param_owner(formal))}/${
                effect_param_ordinal(formal).to_str()}")
        }
        for parameter in flow_call_contract_parameter_types(
                callable.semantic_contract) {
            item.push(encode_type_ref(parameter))
        }
        let mut parameter_ordinal = 0
        for parameter_slot in callable.parameter_slots {
            item.push("Q${parameter_ordinal.to_str()}/${encode_slot(parameter_slot)}")
            parameter_ordinal = parameter_ordinal + 1
        }
        item.push("R${encode_type_ref(flow_call_contract_result_type(
            callable.semantic_contract))}")
        for role in flow_call_contract_parameter_roles(
                callable.semantic_contract) {
            item.push("L${flow_semantic_role_tag(role).to_str()}")
        }
        item.push("O${flow_semantic_role_tag(
            flow_call_contract_result_role(
                callable.semantic_contract)).to_str()}")
        item.push("G${encode_value_origin(flow_call_contract_result_origin(
            callable.semantic_contract))}")
        item.push("CE${encode_effect_contract(callable.effects)}")
        match callable.effect_ctx {
            some(context) => {
                item.push("XC${encode_effect_ctx_ref(
                    core_callable_effect_ctx_reference(context))}")
                item.push("XL${encode_effect_ctx_layout(
                    core_callable_effect_ctx_layout(context))}")
                item.push("XT${encode_type_ref(
                    core_callable_effect_ctx_type(context))}")
            },
            none => item.push("XF")
        }
        parts.push(item.join(";"))
    }
    for body in bodies {
        parts.push("BO/${encode_executable(body.reference)}/${encode_origin(body.origin)}")
        for scope in body.scopes {
            let parent = match scope.parent {
                some(value) => encode_scope_ref(value),
                none => "root"
            }
            parts.push("SC/${encode_scope_ref(scope.reference)}/${parent}")
        }
        for slot in body.slots {
            parts.push([
                "SL", encode_slot(slot.reference), encode_type_ref(slot.ty),
                encode_scope_ref(slot.scope), slot.reverse_ordinal.to_str(),
                slot.initial_state.tag.to_str(), slot.storage.tag.to_str(),
                flow_storage_contract_tag(slot.storage_contract).to_str(),
                match slot.parameter_ordinal {
                    some(ordinal) => ordinal.to_str(),
                    none => (0 - 1).to_str()
                }
            ].join(";"))
        }
        for block in body.blocks {
            parts.push([
                "BL", encode_block_ref(block.reference),
                encode_origin(block.origin), encode_scope_ref(block.scope)
            ].join(";"))
            for instruction in block.instructions {
                parts.push(encode_instruction(instruction))
            }
            parts.push(encode_terminator(block.terminator))
        }
    }
    parts.join("|")
}

pub struct FlowTopologyFingerprint { canonical: Str }

pub fn flow_topology_fingerprint_same(
    left: FlowTopologyFingerprint, right: FlowTopologyFingerprint
) -> Bool { left.canonical == right.canonical }

pub fn flow_topology_fingerprint_canonical(
    value: FlowTopologyFingerprint
) -> Str { value.canonical }

pub struct FlowProgram {
    type_nodes: List<FlowTypeNode>,
    callables: List<FlowCallable>,
    bodies: List<FlowBody>,
    topology_fingerprint: FlowTopologyFingerprint
}

fn copy_flow_callables(callables: List<FlowCallable>) -> List<FlowCallable> {
    let mut result: List<FlowCallable> = []
    for callable in callables {
        result.push(FlowCallable {
            reference: callable.reference, origin: callable.origin,
            header_type: callable.header_type,
            type_formals: callable.type_formals.map(fn(item) { item }),
            effect_formals: callable.effect_formals.map(fn(item) { item }),
            parameter_slots: copy_slot_refs(callable.parameter_slots),
            mode: callable.mode,
            semantic_contract: copy_call_contract(callable.semantic_contract),
            effects: copy_core_effect_contract(callable.effects),
            effect_ctx: callable.effect_ctx
        })
    }
    result
}

pub fn make_flow_program(
    type_nodes: List<FlowTypeNode>, callables: List<FlowCallable>,
    bodies: List<FlowBody>
) -> FlowProgram {
    validate_flow_type_graph_nodes(type_nodes)
    validate_callables(callables, type_nodes)
    validate_type_provider_contracts(type_nodes, callables)
    validate_bodies(bodies, callables, type_nodes)
    validate_effect_ctx_overlays(bodies)
    validate_direct_calls(bodies, callables, type_nodes)
    validate_typed_instructions(bodies, callables, type_nodes)
    let frozen_types = copy_flow_type_graph_nodes(type_nodes)
    let frozen_bodies = copy_bodies(bodies)
    let frozen_callables = copy_flow_callables(callables)
    let fingerprint = FlowTopologyFingerprint {
        canonical: compute_topology_encoding(
            frozen_types, frozen_callables, frozen_bodies)
    }
    FlowProgram {
        type_nodes: frozen_types, callables: frozen_callables,
        bodies: frozen_bodies, topology_fingerprint: fingerprint
    }
}

pub fn flow_program_type_nodes(value: FlowProgram) -> List<FlowTypeNode> {
    copy_flow_type_graph_nodes(value.type_nodes)
}
pub fn flow_program_callables(value: FlowProgram) -> List<FlowCallable> {
    let mut result: List<FlowCallable> = []
    for callable in value.callables {
        result.push(FlowCallable {
            reference: callable.reference, origin: callable.origin,
            header_type: callable.header_type,
            type_formals: callable.type_formals.map(fn(item) { item }),
            effect_formals: callable.effect_formals.map(fn(item) { item }),
            parameter_slots: copy_slot_refs(callable.parameter_slots),
            mode: callable.mode,
            semantic_contract: copy_call_contract(callable.semantic_contract),
            effects: copy_core_effect_contract(callable.effects),
            effect_ctx: callable.effect_ctx
        })
    }
    result
}
pub fn flow_program_bodies(value: FlowProgram) -> List<FlowBody> {
    copy_bodies(value.bodies)
}
pub fn flow_program_topology_fingerprint(
    value: FlowProgram
) -> FlowTopologyFingerprint { value.topology_fingerprint }

pub fn validate_flow_program(value: FlowProgram) {
    // Reconstructing through the sole freeze barrier rejects any representation
    // drift and recomputes, rather than trusts, the topology fingerprint.
    let rebuilt = make_flow_program(
        value.type_nodes, value.callables.map(fn(callable) {
            make_flow_callable(
                callable.reference, callable.origin,
                callable.header_type, callable.type_formals,
                callable.effect_formals,
                callable.parameter_slots, callable.mode,
                callable.semantic_contract, callable.effects,
                callable.effect_ctx)
        }), value.bodies)
    if !flow_topology_fingerprint_same(
            rebuilt.topology_fingerprint, value.topology_fingerprint) {
        panic("FlowIR: frozen topology fingerprint drifted")
    }
}
