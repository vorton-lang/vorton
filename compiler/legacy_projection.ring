// Immutable typed bridge from verified Core/Flow/Rc stages to the temporary
// legacy HProgram serializer.
//
// Every identity-bearing fact remains a typed ref. Names and integer DefIds
// are physical legacy-HIR/C projection payload only; no lookup, resolver,
// source span, backend guess, or post-0.1 extension is available here.

use types::{Type, EffectRow, types_equal, effects_equal}
use ir_identity::{
    SymbolRef, ModuleBodyRef, OriginRef, SlotRef,
    ImplOwnerRef, ImplMethodRef,
    handled_effect_ref_same, system_effect_ref_same,
    symbol_ref_same, symbol_ref_origin_module_key,
    module_body_ref_same, module_body_ref_origin_module_key,
    origin_ref_is_symbol, origin_ref_symbol, origin_ref_path, origin_ref_same,
    path_ref_owner, path_owner_ref_is_symbol,
    path_owner_ref_symbol, path_owner_ref_module_body,
    slot_ref_is_source, slot_ref_source_origin_module_key,
    slot_ref_source_def_id, slot_ref_synthetic_path, slot_ref_same,
    impl_owner_ref_target, impl_owner_ref_trait, impl_owner_ref_same,
    impl_method_ref_owner, impl_method_ref_member, impl_method_ref_same}
use ir_inventory::{
    ExecutableRef, ExecutableKind,
    make_named_executable_ref,
    executable_inventory_entries, executable_entry_reference,
    executable_ref_same, executable_ref_origin_module_key,
    executable_kind_same}
use core_expr::{
    CoreTypeRef, CoreTypeFactRef, CoreEffectAtom, CoreEffectSet,
    core_type_ref_index, core_type_ref_same, core_type_graph_count,
    core_type_fact_module_key, core_type_fact_ordinal, core_type_fact_same,
    make_core_effect_set, core_effect_set_atoms,
    core_effect_atom_kind_tag, core_effect_atom_type,
    core_effect_atom_handled_ref, core_effect_atom_system_ref}
use core_hir::{core_program_type_graph, core_program_inventory}
use core_type_source::{
    CoreTypeSourceFact,
    core_type_source_type, core_type_source_fact
}
use core_from_hir::{
    CoreEffectSetFact, CoreAssemblyResult,
    CoreAssemblyTypeRemap,
    core_effect_set_fact_local_set,
    core_assembly_result_program,
    core_assembly_result_type_remap,
    core_assembly_result_effect_remap,
    core_assembly_remap_type, core_assembly_remap_effect}

// ============================================================
// Total CoreTypeRef <-> legacy Type bijection
// ============================================================

pub struct LegacyTypeProjection {
    core_type: CoreTypeRef,
    legacy_type: Type
}

pub fn make_legacy_type_projection(
    core_type: CoreTypeRef, legacy_type: Type
) -> LegacyTypeProjection {
    if core_type_ref_index(core_type) < 0 {
        panic("legacy projection: negative Core type reference")
    }
    match legacy_type {
        Type::ErrorType => panic("legacy projection: ErrorType crossed Core closure"),
        _ => {}
    }
    LegacyTypeProjection {
        core_type: core_type, legacy_type: legacy_type
    }
}

pub fn legacy_type_projection_core(
    value: LegacyTypeProjection
) -> CoreTypeRef { value.core_type }

pub fn legacy_type_projection_type(value: LegacyTypeProjection) -> Type {
    value.legacy_type
}

pub fn legacy_type_projection_same(
    left: LegacyTypeProjection, right: LegacyTypeProjection
) -> Bool {
    core_type_ref_same(left.core_type, right.core_type) &&
        types_equal(left.legacy_type, right.legacy_type)
}

fn copy_legacy_types(
    values: List<LegacyTypeProjection>
) -> List<LegacyTypeProjection> {
    let mut result: List<LegacyTypeProjection> = []
    for value in values {
        result.push(make_legacy_type_projection(
            value.core_type, value.legacy_type))
    }
    result
}

fn core_effect_atom_projection_same(
    left: CoreEffectAtom, right: CoreEffectAtom
) -> Bool {
    let tag = core_effect_atom_kind_tag(left)
    if tag != core_effect_atom_kind_tag(right) { return false }
    if tag == 0 || tag == 1 {
        return core_type_ref_same(
            core_effect_atom_type(left), core_effect_atom_type(right))
    }
    if tag == 2 { return true }
    if tag == 3 {
        return handled_effect_ref_same(
            core_effect_atom_handled_ref(left),
            core_effect_atom_handled_ref(right))
    }
    system_effect_ref_same(
        core_effect_atom_system_ref(left),
        core_effect_atom_system_ref(right))
}

fn core_effect_sets_same(left: CoreEffectSet, right: CoreEffectSet) -> Bool {
    let left_atoms = core_effect_set_atoms(left)
    let right_atoms = core_effect_set_atoms(right)
    if left_atoms.len() != right_atoms.len() { return false }
    for left_atom in left_atoms {
        let mut matches = 0
        for right_atom in right_atoms {
            if core_effect_atom_projection_same(left_atom, right_atom) {
                matches = matches + 1
            }
        }
        if matches != 1 { return false }
    }
    true
}

fn effect_rows_same(left: EffectRow, right: EffectRow) -> Bool {
    if left.tail != right.tail || left.effects.len() != right.effects.len() {
        return false
    }
    for left_effect in left.effects {
        let mut matches = 0
        for right_effect in right.effects {
            if effects_equal(left_effect, right_effect) { matches = matches + 1 }
        }
        if matches != 1 { return false }
    }
    true
}

pub struct LegacyEffectProjection {
    core_effects: CoreEffectSet,
    legacy_effects: EffectRow
}

pub fn make_legacy_effect_projection(
    core_effects: CoreEffectSet, legacy_effects: EffectRow
) -> LegacyEffectProjection {
    LegacyEffectProjection {
        core_effects: make_core_effect_set(core_effect_set_atoms(core_effects)),
        legacy_effects: EffectRow {
            effects: legacy_effects.effects, tail: legacy_effects.tail
        }
    }
}

pub fn legacy_effect_projection_core(
    value: LegacyEffectProjection
) -> CoreEffectSet {
    make_core_effect_set(core_effect_set_atoms(value.core_effects))
}
pub fn legacy_effect_projection_row(value: LegacyEffectProjection) -> EffectRow {
    EffectRow {
        effects: value.legacy_effects.effects, tail: value.legacy_effects.tail
    }
}
pub fn legacy_effect_projection_same(
    left: LegacyEffectProjection, right: LegacyEffectProjection
) -> Bool {
    core_effect_sets_same(left.core_effects, right.core_effects) &&
        effect_rows_same(left.legacy_effects, right.legacy_effects)
}

fn copy_legacy_effects(
    values: List<LegacyEffectProjection>
) -> List<LegacyEffectProjection> {
    let mut result: List<LegacyEffectProjection> = []
    for value in values {
        result.push(make_legacy_effect_projection(
            value.core_effects, value.legacy_effects))
    }
    result
}

// ============================================================
// Binder and generic contracts
// ============================================================

pub struct LegacyBinderProjection {
    slot: SlotRef,
    name: Str,
    def_id: Int,
    core_type: CoreTypeRef,
    ty: Type,
    is_mutable: Bool
}

pub fn make_legacy_binder_projection(
    slot: SlotRef, name: Str, def_id: Int,
    core_type: CoreTypeRef, ty: Type, is_mutable: Bool
) -> LegacyBinderProjection {
    if name.len() == 0 {
        panic("legacy projection: binder physical name is empty")
    }
    if slot_ref_is_source(slot) {
        if def_id < 0 || def_id != slot_ref_source_def_id(slot) {
            panic("legacy projection: source binder DefId differs from SlotRef")
        }
    } else if def_id >= 0 {
        panic("legacy projection: synthetic binder DefId is not negative")
    }
    LegacyBinderProjection {
        slot: slot, name: name, def_id: def_id,
        core_type: core_type, ty: ty, is_mutable: is_mutable
    }
}

pub fn legacy_binder_projection_slot(value: LegacyBinderProjection) -> SlotRef {
    value.slot
}
pub fn legacy_binder_projection_name(value: LegacyBinderProjection) -> Str {
    value.name
}
pub fn legacy_binder_projection_def_id(value: LegacyBinderProjection) -> Int {
    value.def_id
}
pub fn legacy_binder_projection_core_type(
    value: LegacyBinderProjection
) -> CoreTypeRef { value.core_type }
pub fn legacy_binder_projection_type(value: LegacyBinderProjection) -> Type {
    value.ty
}
pub fn legacy_binder_projection_is_mutable(
    value: LegacyBinderProjection
) -> Bool { value.is_mutable }

fn copy_legacy_binders(
    values: List<LegacyBinderProjection>
) -> List<LegacyBinderProjection> {
    let mut result: List<LegacyBinderProjection> = []
    for value in values {
        result.push(make_legacy_binder_projection(
            value.slot, value.name, value.def_id,
            value.core_type, value.ty, value.is_mutable))
    }
    result
}

pub struct LegacyTypeParameterProjection {
    name: Str,
    type_var_id: Int,
    bounds: List<SymbolRef>
}

pub fn make_legacy_type_parameter_projection(
    name: Str, type_var_id: Int, bounds: List<SymbolRef>
) -> LegacyTypeParameterProjection {
    if name.len() == 0 || type_var_id < 0 {
        panic("legacy projection: invalid type parameter")
    }
    let mut copied: List<SymbolRef> = []
    for bound in bounds {
        for existing in copied {
            if symbol_ref_same(existing, bound) {
                panic("legacy projection: duplicate exact type-parameter bound")
            }
        }
        copied.push(bound)
    }
    LegacyTypeParameterProjection {
        name: name, type_var_id: type_var_id, bounds: copied
    }
}

pub fn legacy_type_parameter_name(
    value: LegacyTypeParameterProjection
) -> Str { value.name }
pub fn legacy_type_parameter_var_id(
    value: LegacyTypeParameterProjection
) -> Int { value.type_var_id }
pub fn legacy_type_parameter_bounds(
    value: LegacyTypeParameterProjection
) -> List<SymbolRef> {
    let mut result: List<SymbolRef> = []
    for bound in value.bounds { result.push(bound) }
    result
}

fn copy_type_parameters(
    values: List<LegacyTypeParameterProjection>
) -> List<LegacyTypeParameterProjection> {
    let mut result: List<LegacyTypeParameterProjection> = []
    for value in values {
        result.push(make_legacy_type_parameter_projection(
            value.name, value.type_var_id, value.bounds))
    }
    result
}

pub struct LegacyTraitBoundProjection {
    type_parameter_index: Int,
    trait_ref: SymbolRef
}

pub fn make_legacy_trait_bound_projection(
    type_parameter_index: Int, trait_ref: SymbolRef
) -> LegacyTraitBoundProjection {
    if type_parameter_index < 0 {
        panic("legacy projection: negative trait-bound parameter index")
    }
    LegacyTraitBoundProjection {
        type_parameter_index: type_parameter_index,
        trait_ref: trait_ref
    }
}

pub fn legacy_trait_bound_parameter_index(
    value: LegacyTraitBoundProjection
) -> Int { value.type_parameter_index }
pub fn legacy_trait_bound_trait(
    value: LegacyTraitBoundProjection
) -> SymbolRef { value.trait_ref }

fn copy_trait_bounds(
    values: List<LegacyTraitBoundProjection>
) -> List<LegacyTraitBoundProjection> {
    let mut result: List<LegacyTraitBoundProjection> = []
    for value in values {
        result.push(make_legacy_trait_bound_projection(
            value.type_parameter_index, value.trait_ref))
    }
    result
}

// ============================================================
// Exact module/container identity
// ============================================================

enum LegacyContainerRefValue {
    ModuleContainerValue(ModuleBodyRef),
    ExecutableContainerValue(ExecutableRef)
}

pub struct LegacyContainerRef { value: LegacyContainerRefValue }

pub fn make_legacy_module_container(
    value: ModuleBodyRef
) -> LegacyContainerRef {
    LegacyContainerRef { value: LegacyContainerRefValue::ModuleContainerValue(value) }
}

pub fn make_legacy_executable_container(
    value: ExecutableRef
) -> LegacyContainerRef {
    LegacyContainerRef {
        value: LegacyContainerRefValue::ExecutableContainerValue(value)
    }
}

pub fn legacy_container_is_module(value: LegacyContainerRef) -> Bool {
    match value.value {
        LegacyContainerRefValue::ModuleContainerValue(_) => true,
        LegacyContainerRefValue::ExecutableContainerValue(_) => false
    }
}
pub fn legacy_container_module(value: LegacyContainerRef) -> ModuleBodyRef {
    match value.value {
        LegacyContainerRefValue::ModuleContainerValue(module) => module,
        _ => panic("legacy projection: executable container has no module body")
    }
}
pub fn legacy_container_executable(
    value: LegacyContainerRef
) -> ExecutableRef {
    match value.value {
        LegacyContainerRefValue::ExecutableContainerValue(executable) =>
            executable,
        _ => panic("legacy projection: module container has no executable")
    }
}

fn legacy_container_module_key(value: LegacyContainerRef) -> Str {
    if legacy_container_is_module(value) {
        module_body_ref_origin_module_key(legacy_container_module(value))
    } else {
        executable_ref_origin_module_key(legacy_container_executable(value))
    }
}

fn legacy_container_same(
    left: LegacyContainerRef, right: LegacyContainerRef
) -> Bool {
    match (left.value, right.value) {
        (LegacyContainerRefValue::ModuleContainerValue(a),
         LegacyContainerRefValue::ModuleContainerValue(b)) =>
            module_body_ref_same(a, b),
        (LegacyContainerRefValue::ExecutableContainerValue(a),
         LegacyContainerRefValue::ExecutableContainerValue(b)) =>
            executable_ref_same(a, b),
        _ => false
    }
}

fn origin_module_key(value: OriginRef) -> Str {
    if origin_ref_is_symbol(value) {
        symbol_ref_origin_module_key(origin_ref_symbol(value))
    } else {
        let owner = path_ref_owner(origin_ref_path(value))
        if path_owner_ref_is_symbol(owner) {
            symbol_ref_origin_module_key(path_owner_ref_symbol(owner))
        } else {
            module_body_ref_origin_module_key(
                path_owner_ref_module_body(owner))
        }
    }
}

// ============================================================
// Callable, impl, and executable shell carriers
// ============================================================

pub struct LegacyCallableProjection {
    reference: ExecutableRef,
    origin: OriginRef,
    module_body: ModuleBodyRef,
    container: LegacyContainerRef,
    kind: ExecutableKind,
    type_parameters: List<LegacyTypeParameterProjection>,
    bounds: List<LegacyTraitBoundProjection>,
    parameters: List<LegacyBinderProjection>,
    result_core_type: CoreTypeRef,
    result_type: Type,
    effects: EffectRow,
    is_public: Bool
}

pub fn make_legacy_callable_projection(
    reference: ExecutableRef, origin: OriginRef,
    module_body: ModuleBodyRef, container: LegacyContainerRef,
    kind: ExecutableKind,
    type_parameters: List<LegacyTypeParameterProjection>,
    bounds: List<LegacyTraitBoundProjection>,
    parameters: List<LegacyBinderProjection>,
    result_core_type: CoreTypeRef, result_type: Type,
    effects: EffectRow, is_public: Bool
) -> LegacyCallableProjection {
    let module_key = module_body_ref_origin_module_key(module_body)
    if executable_ref_origin_module_key(reference) != module_key ||
       origin_module_key(origin) != module_key ||
       legacy_container_module_key(container) != module_key {
        panic("legacy projection: callable module/container identity differs")
    }
    let mut type_index = 0
    while type_index < type_parameters.len() {
        let left = type_parameters.get(type_index).unwrap()
        let mut other = type_index + 1
        while other < type_parameters.len() {
            let right = type_parameters.get(other).unwrap()
            if left.name == right.name || left.type_var_id == right.type_var_id {
                panic("legacy projection: duplicate callable type parameter")
            }
            other = other + 1
        }
        type_index = type_index + 1
    }
    for bound in bounds {
        if bound.type_parameter_index >= type_parameters.len() {
            panic("legacy projection: callable bound parameter is absent")
        }
    }
    let mut bound_index = 0
    while bound_index < bounds.len() {
        let left = bounds.get(bound_index).unwrap()
        let mut other = bound_index + 1
        while other < bounds.len() {
            let right = bounds.get(other).unwrap()
            if left.type_parameter_index == right.type_parameter_index &&
               symbol_ref_same(left.trait_ref, right.trait_ref) {
                panic("legacy projection: duplicate callable exact bound")
            }
            other = other + 1
        }
        bound_index = bound_index + 1
    }
    LegacyCallableProjection {
        reference: reference, origin: origin,
        module_body: module_body, container: container, kind: kind,
        type_parameters: copy_type_parameters(type_parameters),
        bounds: copy_trait_bounds(bounds),
        parameters: copy_legacy_binders(parameters),
        result_core_type: result_core_type, result_type: result_type,
        effects: EffectRow { effects: effects.effects, tail: effects.tail },
        is_public: is_public
    }
}

pub fn legacy_callable_reference(value: LegacyCallableProjection) -> ExecutableRef {
    value.reference
}
pub fn legacy_callable_origin(value: LegacyCallableProjection) -> OriginRef {
    value.origin
}
pub fn legacy_callable_module(value: LegacyCallableProjection) -> ModuleBodyRef {
    value.module_body
}
pub fn legacy_callable_container(
    value: LegacyCallableProjection
) -> LegacyContainerRef { value.container }
pub fn legacy_callable_kind(value: LegacyCallableProjection) -> ExecutableKind {
    value.kind
}
pub fn legacy_callable_type_parameters(
    value: LegacyCallableProjection
) -> List<LegacyTypeParameterProjection> {
    copy_type_parameters(value.type_parameters)
}
pub fn legacy_callable_bounds(
    value: LegacyCallableProjection
) -> List<LegacyTraitBoundProjection> { copy_trait_bounds(value.bounds) }
pub fn legacy_callable_parameters(
    value: LegacyCallableProjection
) -> List<LegacyBinderProjection> { copy_legacy_binders(value.parameters) }
pub fn legacy_callable_result_core_type(
    value: LegacyCallableProjection
) -> CoreTypeRef { value.result_core_type }
pub fn legacy_callable_result_type(value: LegacyCallableProjection) -> Type {
    value.result_type
}
pub fn legacy_callable_effects(value: LegacyCallableProjection) -> EffectRow {
    EffectRow { effects: value.effects.effects, tail: value.effects.tail }
}
pub fn legacy_callable_is_public(value: LegacyCallableProjection) -> Bool {
    value.is_public
}

fn copy_callables(
    values: List<LegacyCallableProjection>
) -> List<LegacyCallableProjection> {
    let mut result: List<LegacyCallableProjection> = []
    for value in values {
        result.push(make_legacy_callable_projection(
            value.reference, value.origin, value.module_body,
            value.container, value.kind, value.type_parameters,
            value.bounds, value.parameters, value.result_core_type,
            value.result_type, value.effects, value.is_public))
    }
    result
}

pub struct LegacyAssocBindingProjection {
    member_ref: SymbolRef,
    core_type: CoreTypeRef,
    ty: Type
}

pub fn make_legacy_assoc_binding_projection(
    member_ref: SymbolRef, core_type: CoreTypeRef, ty: Type
) -> LegacyAssocBindingProjection {
    LegacyAssocBindingProjection {
        member_ref: member_ref, core_type: core_type, ty: ty
    }
}
pub fn legacy_assoc_binding_member(
    value: LegacyAssocBindingProjection
) -> SymbolRef { value.member_ref }
pub fn legacy_assoc_binding_core_type(
    value: LegacyAssocBindingProjection
) -> CoreTypeRef { value.core_type }
pub fn legacy_assoc_binding_type(
    value: LegacyAssocBindingProjection
) -> Type { value.ty }

fn copy_assoc_bindings(
    values: List<LegacyAssocBindingProjection>
) -> List<LegacyAssocBindingProjection> {
    let mut result: List<LegacyAssocBindingProjection> = []
    for value in values {
        result.push(make_legacy_assoc_binding_projection(
            value.member_ref, value.core_type, value.ty))
    }
    result
}

pub struct LegacyImplProjection {
    owner: ImplOwnerRef,
    target_core_type: CoreTypeRef,
    target_type: Type,
    target_nominal: SymbolRef,
    trait_ref: SymbolRef?,
    type_parameters: List<LegacyTypeParameterProjection>,
    assoc_bindings: List<LegacyAssocBindingProjection>,
    methods: List<ImplMethodRef>,
    module_body: ModuleBodyRef,
    container: LegacyContainerRef
}

pub fn make_legacy_impl_projection(
    owner: ImplOwnerRef,
    target_core_type: CoreTypeRef, target_type: Type,
    target_nominal: SymbolRef, trait_ref: SymbolRef?,
    type_parameters: List<LegacyTypeParameterProjection>,
    assoc_bindings: List<LegacyAssocBindingProjection>,
    methods: List<ImplMethodRef>, module_body: ModuleBodyRef,
    container: LegacyContainerRef
) -> LegacyImplProjection {
    if !symbol_ref_same(impl_owner_ref_target(owner), target_nominal) {
        panic("legacy projection: impl target nominal differs from owner")
    }
    match (impl_owner_ref_trait(owner), trait_ref) {
        (some(a), some(b)) => if !symbol_ref_same(a, b) {
            panic("legacy projection: impl trait differs from owner")
        },
        (none, none) => {},
        _ => panic("legacy projection: impl trait presence differs from owner")
    }
    let module_key = module_body_ref_origin_module_key(module_body)
    if symbol_ref_origin_module_key(target_nominal) != module_key ||
       legacy_container_module_key(container) != module_key {
        panic("legacy projection: impl module/container identity differs")
    }
    let mut type_index = 0
    while type_index < type_parameters.len() {
        let left = type_parameters.get(type_index).unwrap()
        let mut other = type_index + 1
        while other < type_parameters.len() {
            let right = type_parameters.get(other).unwrap()
            if left.name == right.name || left.type_var_id == right.type_var_id {
                panic("legacy projection: duplicate impl type parameter")
            }
            other = other + 1
        }
        type_index = type_index + 1
    }
    let mut method_index = 0
    while method_index < methods.len() {
        let method = methods.get(method_index).unwrap()
        if !impl_owner_ref_same(impl_method_ref_owner(method), owner) {
            panic("legacy projection: impl method crosses owner")
        }
        let mut other = method_index + 1
        while other < methods.len() {
            if impl_method_ref_same(method, methods.get(other).unwrap()) {
                panic("legacy projection: duplicate ordered impl method")
            }
            other = other + 1
        }
        method_index = method_index + 1
    }
    let mut assoc_index = 0
    while assoc_index < assoc_bindings.len() {
        let left = assoc_bindings.get(assoc_index).unwrap()
        let mut other = assoc_index + 1
        while other < assoc_bindings.len() {
            if symbol_ref_same(
                    left.member_ref,
                    assoc_bindings.get(other).unwrap().member_ref) {
                panic("legacy projection: duplicate impl associated binding")
            }
            other = other + 1
        }
        assoc_index = assoc_index + 1
    }
    LegacyImplProjection {
        owner: owner, target_core_type: target_core_type,
        target_type: target_type, target_nominal: target_nominal,
        trait_ref: trait_ref,
        type_parameters: copy_type_parameters(type_parameters),
        assoc_bindings: copy_assoc_bindings(assoc_bindings),
        methods: methods, module_body: module_body, container: container
    }
}

pub fn legacy_impl_owner(value: LegacyImplProjection) -> ImplOwnerRef { value.owner }
pub fn legacy_impl_target_core_type(value: LegacyImplProjection) -> CoreTypeRef {
    value.target_core_type
}
pub fn legacy_impl_target_type(value: LegacyImplProjection) -> Type {
    value.target_type
}
pub fn legacy_impl_target_nominal(value: LegacyImplProjection) -> SymbolRef {
    value.target_nominal
}
pub fn legacy_impl_trait(value: LegacyImplProjection) -> SymbolRef? {
    value.trait_ref
}
pub fn legacy_impl_type_parameters(
    value: LegacyImplProjection
) -> List<LegacyTypeParameterProjection> {
    copy_type_parameters(value.type_parameters)
}
pub fn legacy_impl_assoc_bindings(
    value: LegacyImplProjection
) -> List<LegacyAssocBindingProjection> {
    copy_assoc_bindings(value.assoc_bindings)
}
pub fn legacy_impl_methods(value: LegacyImplProjection) -> List<ImplMethodRef> {
    let mut result: List<ImplMethodRef> = []
    for method in value.methods { result.push(method) }
    result
}
pub fn legacy_impl_module(value: LegacyImplProjection) -> ModuleBodyRef {
    value.module_body
}
pub fn legacy_impl_container(value: LegacyImplProjection) -> LegacyContainerRef {
    value.container
}

fn copy_impls(values: List<LegacyImplProjection>) -> List<LegacyImplProjection> {
    let mut result: List<LegacyImplProjection> = []
    for value in values {
        result.push(make_legacy_impl_projection(
            value.owner, value.target_core_type, value.target_type,
            value.target_nominal, value.trait_ref, value.type_parameters,
            value.assoc_bindings, value.methods,
            value.module_body, value.container))
    }
    result
}

pub struct LegacyExecutableShell {
    reference: ExecutableRef,
    origin: OriginRef,
    kind: ExecutableKind,
    module_body: ModuleBodyRef,
    container: LegacyContainerRef
}

pub fn make_legacy_executable_shell(
    reference: ExecutableRef, origin: OriginRef, kind: ExecutableKind,
    module_body: ModuleBodyRef, container: LegacyContainerRef
) -> LegacyExecutableShell {
    let module_key = module_body_ref_origin_module_key(module_body)
    if executable_ref_origin_module_key(reference) != module_key ||
       origin_module_key(origin) != module_key ||
       legacy_container_module_key(container) != module_key {
        panic("legacy projection: executable shell identity differs")
    }
    LegacyExecutableShell {
        reference: reference, origin: origin, kind: kind,
        module_body: module_body, container: container
    }
}

pub fn legacy_executable_shell_reference(
    value: LegacyExecutableShell
) -> ExecutableRef { value.reference }
pub fn legacy_executable_shell_origin(value: LegacyExecutableShell) -> OriginRef {
    value.origin
}
pub fn legacy_executable_shell_kind(value: LegacyExecutableShell) -> ExecutableKind {
    value.kind
}
pub fn legacy_executable_shell_module(
    value: LegacyExecutableShell
) -> ModuleBodyRef { value.module_body }
pub fn legacy_executable_shell_container(
    value: LegacyExecutableShell
) -> LegacyContainerRef { value.container }

pub struct LegacyExecutableShellMap { entries: List<LegacyExecutableShell> }

pub fn make_legacy_executable_shell_map(
    entries: List<LegacyExecutableShell>
) -> LegacyExecutableShellMap {
    let mut left_index = 0
    while left_index < entries.len() {
        let left = entries.get(left_index).unwrap()
        let mut right_index = left_index + 1
        while right_index < entries.len() {
            if executable_ref_same(
                    left.reference, entries.get(right_index).unwrap().reference) {
                panic("legacy projection: duplicate executable shell ref")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    LegacyExecutableShellMap { entries: entries }
}

pub fn legacy_executable_shell_entries(
    value: LegacyExecutableShellMap
) -> List<LegacyExecutableShell> {
    let mut result: List<LegacyExecutableShell> = []
    for entry in value.entries {
        result.push(make_legacy_executable_shell(
            entry.reference, entry.origin, entry.kind,
            entry.module_body, entry.container))
    }
    result
}

pub fn legacy_executable_shell_for(
    value: LegacyExecutableShellMap, reference: ExecutableRef
) -> LegacyExecutableShell {
    for entry in value.entries {
        if executable_ref_same(entry.reference, reference) { return entry }
    }
    panic("legacy projection: executable shell ref is absent")
}

// ============================================================
// Module-domain projection facts (no project CoreTypeRef)
// ============================================================

pub struct LegacyEffectFactProjection {
    fact: CoreEffectSetFact,
    legacy_effects: EffectRow
}
pub fn make_legacy_effect_fact_projection(
    fact: CoreEffectSetFact, legacy_effects: EffectRow
) -> LegacyEffectFactProjection {
    LegacyEffectFactProjection {
        fact: fact,
        legacy_effects: EffectRow {
            effects: legacy_effects.effects, tail: legacy_effects.tail
        }
    }
}
pub fn legacy_effect_fact_projection_fact(
    value: LegacyEffectFactProjection
) -> CoreEffectSetFact { value.fact }
pub fn legacy_effect_fact_projection_row(
    value: LegacyEffectFactProjection
) -> EffectRow {
    EffectRow {
        effects: value.legacy_effects.effects,
        tail: value.legacy_effects.tail
    }
}

pub struct LegacyBinderFactProjection {
    slot: SlotRef,
    name: Str,
    def_id: Int,
    type_fact: CoreTypeFactRef,
    ty: Type,
    is_mutable: Bool
}
pub fn make_legacy_binder_fact_projection(
    slot: SlotRef, name: Str, def_id: Int,
    type_fact: CoreTypeFactRef, ty: Type, is_mutable: Bool
) -> LegacyBinderFactProjection {
    if name.len() == 0 {
        panic("legacy projection: module binder physical name is empty")
    }
    if slot_ref_is_source(slot) {
        if def_id < 0 || def_id != slot_ref_source_def_id(slot) {
            panic("legacy projection: module source binder DefId differs")
        }
    } else if def_id >= 0 {
        panic("legacy projection: module synthetic binder DefId is not negative")
    }
    LegacyBinderFactProjection {
        slot: slot, name: name, def_id: def_id,
        type_fact: type_fact, ty: ty, is_mutable: is_mutable
    }
}
pub fn legacy_binder_fact_slot(value: LegacyBinderFactProjection) -> SlotRef {
    value.slot
}
pub fn legacy_binder_fact_name(value: LegacyBinderFactProjection) -> Str {
    value.name
}
pub fn legacy_binder_fact_def_id(value: LegacyBinderFactProjection) -> Int {
    value.def_id
}
pub fn legacy_binder_fact_type_fact(
    value: LegacyBinderFactProjection
) -> CoreTypeFactRef { value.type_fact }
pub fn legacy_binder_fact_type(value: LegacyBinderFactProjection) -> Type {
    value.ty
}
pub fn legacy_binder_fact_is_mutable(
    value: LegacyBinderFactProjection
) -> Bool { value.is_mutable }

pub struct LegacyCallableFactProjection {
    reference: ExecutableRef,
    origin: OriginRef,
    module_body: ModuleBodyRef,
    container: LegacyContainerRef,
    kind: ExecutableKind,
    type_parameters: List<LegacyTypeParameterProjection>,
    bounds: List<LegacyTraitBoundProjection>,
    parameters: List<LegacyBinderFactProjection>,
    result_type_fact: CoreTypeFactRef,
    result_type: Type,
    effects: EffectRow,
    is_public: Bool
}
pub fn make_legacy_callable_fact_projection(
    reference: ExecutableRef, origin: OriginRef,
    module_body: ModuleBodyRef, container: LegacyContainerRef,
    kind: ExecutableKind,
    type_parameters: List<LegacyTypeParameterProjection>,
    bounds: List<LegacyTraitBoundProjection>,
    parameters: List<LegacyBinderFactProjection>,
    result_type_fact: CoreTypeFactRef, result_type: Type,
    effects: EffectRow, is_public: Bool
) -> LegacyCallableFactProjection {
    let module_key = module_body_ref_origin_module_key(module_body)
    if executable_ref_origin_module_key(reference) != module_key ||
       origin_module_key(origin) != module_key ||
       legacy_container_module_key(container) != module_key ||
       core_type_fact_module_key(result_type_fact) != module_key {
        panic("legacy projection: module callable identity/type domain differs")
    }
    for parameter in parameters {
        if core_type_fact_module_key(parameter.type_fact) != module_key {
            panic("legacy projection: callable parameter fact crosses module")
        }
    }
    LegacyCallableFactProjection {
        reference: reference, origin: origin,
        module_body: module_body, container: container, kind: kind,
        type_parameters: copy_type_parameters(type_parameters),
        bounds: copy_trait_bounds(bounds), parameters: parameters,
        result_type_fact: result_type_fact, result_type: result_type,
        effects: EffectRow { effects: effects.effects, tail: effects.tail },
        is_public: is_public
    }
}

pub struct LegacyAssocBindingFactProjection {
    member_ref: SymbolRef,
    type_fact: CoreTypeFactRef,
    ty: Type
}
pub fn make_legacy_assoc_binding_fact_projection(
    member_ref: SymbolRef, type_fact: CoreTypeFactRef, ty: Type
) -> LegacyAssocBindingFactProjection {
    LegacyAssocBindingFactProjection {
        member_ref: member_ref, type_fact: type_fact, ty: ty
    }
}

pub struct LegacyImplFactProjection {
    owner: ImplOwnerRef,
    target_type_fact: CoreTypeFactRef,
    target_type: Type,
    target_nominal: SymbolRef,
    trait_ref: SymbolRef?,
    type_parameters: List<LegacyTypeParameterProjection>,
    assoc_bindings: List<LegacyAssocBindingFactProjection>,
    methods: List<ImplMethodRef>,
    module_body: ModuleBodyRef,
    container: LegacyContainerRef
}
pub fn make_legacy_impl_fact_projection(
    owner: ImplOwnerRef,
    target_type_fact: CoreTypeFactRef, target_type: Type,
    target_nominal: SymbolRef, trait_ref: SymbolRef?,
    type_parameters: List<LegacyTypeParameterProjection>,
    assoc_bindings: List<LegacyAssocBindingFactProjection>,
    methods: List<ImplMethodRef>, module_body: ModuleBodyRef,
    container: LegacyContainerRef
) -> LegacyImplFactProjection {
    let module_key = module_body_ref_origin_module_key(module_body)
    if core_type_fact_module_key(target_type_fact) != module_key ||
       !symbol_ref_same(impl_owner_ref_target(owner), target_nominal) ||
       legacy_container_module_key(container) != module_key {
        panic("legacy projection: module impl identity/type domain differs")
    }
    match (impl_owner_ref_trait(owner), trait_ref) {
        (some(a), some(b)) => if !symbol_ref_same(a, b) {
            panic("legacy projection: module impl trait differs")
        },
        (none, none) => {},
        _ => panic("legacy projection: module impl trait presence differs")
    }
    for binding in assoc_bindings {
        if core_type_fact_module_key(binding.type_fact) != module_key {
            panic("legacy projection: impl assoc fact crosses module")
        }
    }
    for method in methods {
        if !impl_owner_ref_same(impl_method_ref_owner(method), owner) {
            panic("legacy projection: module impl method crosses owner")
        }
    }
    LegacyImplFactProjection {
        owner: owner, target_type_fact: target_type_fact,
        target_type: target_type, target_nominal: target_nominal,
        trait_ref: trait_ref,
        type_parameters: copy_type_parameters(type_parameters),
        assoc_bindings: assoc_bindings, methods: methods,
        module_body: module_body, container: container
    }
}

fn slot_projection_module_key(value: SlotRef) -> Str {
    if slot_ref_is_source(value) {
        slot_ref_source_origin_module_key(value)
    } else {
        let owner = path_ref_owner(slot_ref_synthetic_path(value))
        if path_owner_ref_is_symbol(owner) {
            symbol_ref_origin_module_key(path_owner_ref_symbol(owner))
        } else {
            module_body_ref_origin_module_key(path_owner_ref_module_body(owner))
        }
    }
}

pub struct LegacyProjectionFacts {
    module_key: Str,
    module_order: Int,
    local_type_count: Int,
    types: List<CoreTypeSourceFact>,
    effects: List<LegacyEffectFactProjection>,
    binders: List<LegacyBinderFactProjection>,
    callables: List<LegacyCallableFactProjection>,
    impls: List<LegacyImplFactProjection>,
    shells: LegacyExecutableShellMap
}

pub fn make_legacy_projection_facts(
    module_key: Str, module_order: Int, local_type_count: Int,
    types: List<CoreTypeSourceFact>,
    effects: List<LegacyEffectFactProjection>,
    binders: List<LegacyBinderFactProjection>,
    callables: List<LegacyCallableFactProjection>,
    impls: List<LegacyImplFactProjection>,
    shells: LegacyExecutableShellMap
) -> LegacyProjectionFacts {
    if module_key.len() == 0 || module_order < 0 ||
       local_type_count <= 0 || types.len() != local_type_count {
        panic("legacy projection: invalid/incomplete module projection facts")
    }
    let mut index = 0
    while index < types.len() {
        let value = types.get(index).unwrap()
        if core_type_fact_module_key(core_type_source_fact(value)) != module_key ||
           core_type_fact_ordinal(core_type_source_fact(value)) != index {
            panic("legacy projection: module Type facts are not dense/ordered")
        }
        index = index + 1
    }
    index = 0
    while index < binders.len() {
        let left = binders.get(index).unwrap()
        if slot_projection_module_key(left.slot) != module_key ||
           core_type_fact_module_key(left.type_fact) != module_key {
            panic("legacy projection: module binder fact crosses module")
        }
        let mut other = index + 1
        while other < binders.len() {
            let right = binders.get(other).unwrap()
            if slot_ref_same(left.slot, right.slot) ||
               left.def_id == right.def_id {
                panic("legacy projection: duplicate module binder SlotRef/DefId")
            }
            other = other + 1
        }
        index = index + 1
    }
    for callable in callables {
        if executable_ref_origin_module_key(callable.reference) != module_key {
            panic("legacy projection: callable fact crosses module")
        }
    }
    for item in impls {
        if core_type_fact_module_key(item.target_type_fact) != module_key {
            panic("legacy projection: impl fact crosses module")
        }
    }
    LegacyProjectionFacts {
        module_key: module_key, module_order: module_order,
        local_type_count: local_type_count,
        types: types, effects: effects, binders: binders,
        callables: callables, impls: impls,
        shells: make_legacy_executable_shell_map(
            legacy_executable_shell_entries(shells))
    }
}

pub fn legacy_projection_facts_module_key(value: LegacyProjectionFacts) -> Str {
    value.module_key
}
pub fn legacy_projection_facts_module_order(value: LegacyProjectionFacts) -> Int {
    value.module_order
}

// ============================================================
// Collection-complete immutable projection table
// ============================================================

fn projected_type_for(
    values: List<LegacyTypeProjection>, core_type: CoreTypeRef
) -> Type {
    for value in values {
        if core_type_ref_same(value.core_type, core_type) {
            return value.legacy_type
        }
    }
    panic("legacy projection: Core type mapping is absent")
}

fn validate_projected_type(
    values: List<LegacyTypeProjection>, core_type: CoreTypeRef, ty: Type
) {
    if !types_equal(projected_type_for(values, core_type), ty) {
        panic("legacy projection: Core/legacy Type relation differs")
    }
}

fn legacy_binder_projection_same(
    left: LegacyBinderProjection, right: LegacyBinderProjection
) -> Bool {
    slot_ref_same(left.slot, right.slot) && left.name == right.name &&
        left.def_id == right.def_id &&
        core_type_ref_same(left.core_type, right.core_type) &&
        types_equal(left.ty, right.ty) &&
        left.is_mutable == right.is_mutable
}

fn binder_projection_for(
    values: List<LegacyBinderProjection>, slot: SlotRef
) -> LegacyBinderProjection {
    for value in values {
        if slot_ref_same(value.slot, slot) { return value }
    }
    panic("legacy projection: binder SlotRef is absent")
}

pub struct LegacyProjectionTable {
    core_type_count: Int,
    types: List<LegacyTypeProjection>,
    effects: List<LegacyEffectProjection>,
    binders: List<LegacyBinderProjection>,
    callables: List<LegacyCallableProjection>,
    impls: List<LegacyImplProjection>,
    shells: LegacyExecutableShellMap
}

pub fn make_legacy_projection_table(
    core_type_count: Int, types: List<LegacyTypeProjection>,
    effects: List<LegacyEffectProjection>,
    binders: List<LegacyBinderProjection>,
    callables: List<LegacyCallableProjection>,
    impls: List<LegacyImplProjection>,
    shells: LegacyExecutableShellMap
) -> LegacyProjectionTable {
    if core_type_count <= 0 || types.len() != core_type_count {
        panic("legacy projection: Core type projection is not total")
    }
    let shell_entries = legacy_executable_shell_entries(shells)
    if shell_entries.len() != callables.len() {
        panic("legacy projection: callable/executable shell census differs")
    }
    let mut index = 0
    while index < types.len() {
        let left = types.get(index).unwrap()
        if core_type_ref_index(left.core_type) != index {
            panic("legacy projection: Core type projection is not dense/ordered")
        }
        let mut other = index + 1
        while other < types.len() {
            let right = types.get(other).unwrap()
            if core_type_ref_same(left.core_type, right.core_type) ||
               types_equal(left.legacy_type, right.legacy_type) {
                panic("legacy projection: Core/legacy Type mapping is not bijective")
            }
            other = other + 1
        }
        index = index + 1
    }
    index = 0
    while index < effects.len() {
        let left = effects.get(index).unwrap()
        let mut other = index + 1
        while other < effects.len() {
            let right = effects.get(other).unwrap()
            if core_effect_sets_same(left.core_effects, right.core_effects) {
                panic("legacy projection: duplicate Core effect-set mapping")
            }
            other = other + 1
        }
        index = index + 1
    }
    index = 0
    while index < binders.len() {
        let left = binders.get(index).unwrap()
        validate_projected_type(types, left.core_type, left.ty)
        let mut other = index + 1
        while other < binders.len() {
            let right = binders.get(other).unwrap()
            if slot_ref_same(left.slot, right.slot) ||
               left.def_id == right.def_id {
                panic("legacy projection: duplicate binder SlotRef/DefId")
            }
            other = other + 1
        }
        index = index + 1
    }
    index = 0
    while index < callables.len() {
        let callable = callables.get(index).unwrap()
        validate_projected_type(
            types, callable.result_core_type, callable.result_type)
        for parameter in callable.parameters {
            validate_projected_type(types, parameter.core_type, parameter.ty)
            if !legacy_binder_projection_same(
                    parameter, binder_projection_for(binders, parameter.slot)) {
                panic("legacy projection: callable parameter/binder table differs")
            }
        }
        let shell = legacy_executable_shell_for(shells, callable.reference)
        if !origin_ref_same(shell.origin, callable.origin) ||
           !executable_kind_same(shell.kind, callable.kind) ||
           !module_body_ref_same(shell.module_body, callable.module_body) ||
           !legacy_container_same(shell.container, callable.container) {
            panic("legacy projection: callable shell relation differs")
        }
        let mut other = index + 1
        while other < callables.len() {
            if executable_ref_same(
                    callable.reference, callables.get(other).unwrap().reference) {
                panic("legacy projection: duplicate callable ref")
            }
            other = other + 1
        }
        index = index + 1
    }
    index = 0
    while index < impls.len() {
        let value = impls.get(index).unwrap()
        validate_projected_type(types, value.target_core_type, value.target_type)
        for binding in value.assoc_bindings {
            validate_projected_type(types, binding.core_type, binding.ty)
        }
        for method in value.methods {
            let _ = legacy_executable_shell_for(
                shells, make_named_executable_ref(
                    impl_method_ref_member(method)))
        }
        let mut other = index + 1
        while other < impls.len() {
            if impl_owner_ref_same(
                    value.owner, impls.get(other).unwrap().owner) {
                panic("legacy projection: duplicate impl owner")
            }
            other = other + 1
        }
        index = index + 1
    }
    LegacyProjectionTable {
        core_type_count: core_type_count,
        types: copy_legacy_types(types),
        effects: copy_legacy_effects(effects),
        binders: copy_legacy_binders(binders),
        callables: copy_callables(callables),
        impls: copy_impls(impls),
        shells: make_legacy_executable_shell_map(
            legacy_executable_shell_entries(shells))
    }
}

pub fn legacy_projection_core_type_count(
    value: LegacyProjectionTable
) -> Int { value.core_type_count }
pub fn legacy_projection_types(
    value: LegacyProjectionTable
) -> List<LegacyTypeProjection> { copy_legacy_types(value.types) }
pub fn legacy_projection_effects(
    value: LegacyProjectionTable
) -> List<LegacyEffectProjection> { copy_legacy_effects(value.effects) }
pub fn legacy_projection_binders(
    value: LegacyProjectionTable
) -> List<LegacyBinderProjection> { copy_legacy_binders(value.binders) }
pub fn legacy_projection_callables(
    value: LegacyProjectionTable
) -> List<LegacyCallableProjection> { copy_callables(value.callables) }
pub fn legacy_projection_impls(
    value: LegacyProjectionTable
) -> List<LegacyImplProjection> { copy_impls(value.impls) }
pub fn legacy_projection_shells(
    value: LegacyProjectionTable
) -> LegacyExecutableShellMap {
    make_legacy_executable_shell_map(
        legacy_executable_shell_entries(value.shells))
}

pub fn legacy_projection_type_for(
    value: LegacyProjectionTable, core_type: CoreTypeRef
) -> LegacyTypeProjection {
    for projection in value.types {
        if core_type_ref_same(projection.core_type, core_type) {
            return make_legacy_type_projection(
                projection.core_type, projection.legacy_type)
        }
    }
    panic("legacy projection: requested Core type is absent")
}

pub fn legacy_projection_effect_for(
    value: LegacyProjectionTable, core_effects: CoreEffectSet
) -> LegacyEffectProjection {
    for projection in value.effects {
        if core_effect_sets_same(projection.core_effects, core_effects) {
            return make_legacy_effect_projection(
                projection.core_effects, projection.legacy_effects)
        }
    }
    panic("legacy projection: requested Core effect set is absent")
}

pub fn legacy_projection_binder_for(
    value: LegacyProjectionTable, slot: SlotRef
) -> LegacyBinderProjection {
    let projection = binder_projection_for(value.binders, slot)
    make_legacy_binder_projection(
        projection.slot, projection.name, projection.def_id,
        projection.core_type, projection.ty, projection.is_mutable)
}

pub fn legacy_projection_callable_for(
    value: LegacyProjectionTable, reference: ExecutableRef
) -> LegacyCallableProjection {
    for projection in value.callables {
        if executable_ref_same(projection.reference, reference) {
            return make_legacy_callable_projection(
                projection.reference, projection.origin,
                projection.module_body, projection.container,
                projection.kind, projection.type_parameters,
                projection.bounds, projection.parameters,
                projection.result_core_type, projection.result_type,
                projection.effects, projection.is_public)
        }
    }
    panic("legacy projection: requested callable is absent")
}

pub fn legacy_projection_impl_for(
    value: LegacyProjectionTable, owner: ImplOwnerRef
) -> LegacyImplProjection {
    for projection in value.impls {
        if impl_owner_ref_same(projection.owner, owner) {
            return make_legacy_impl_projection(
                projection.owner, projection.target_core_type,
                projection.target_type, projection.target_nominal,
                projection.trait_ref, projection.type_parameters,
                projection.assoc_bindings, projection.methods,
                projection.module_body, projection.container)
        }
    }
    panic("legacy projection: requested impl owner is absent")
}

// ============================================================
// One-shot module-facts -> project projection assembly
// ============================================================

fn append_assembled_type_projection(
    mut values: List<LegacyTypeProjection>, projection: LegacyTypeProjection
) {
    for existing in values {
        if core_type_ref_same(existing.core_type, projection.core_type) {
            if !types_equal(existing.legacy_type, projection.legacy_type) {
                panic("legacy projection: interned Type fact has two physical types")
            }
            return
        }
    }
    values.push(projection)
}

fn order_assembled_type_projections(
    values: List<LegacyTypeProjection>, count: Int
) -> List<LegacyTypeProjection> {
    let mut result: List<LegacyTypeProjection> = []
    let mut index = 0
    while index < count {
        let mut found: LegacyTypeProjection? = none
        for value in values {
            if core_type_ref_index(value.core_type) == index {
                if found.is_some() {
                    panic("legacy projection: project type projection repeats")
                }
                found = some(value)
            }
        }
        result.push(match found {
            some(value) => value,
            none => panic("legacy projection: assembled project Type is absent")
        })
        index = index + 1
    }
    if result.len() != values.len() {
        panic("legacy projection: assembled Type lies outside project graph")
    }
    result
}

fn append_assembled_effect_projection(
    mut values: List<LegacyEffectProjection>, projection: LegacyEffectProjection
) {
    for existing in values {
        if core_effect_sets_same(existing.core_effects, projection.core_effects) {
            if !effect_rows_same(
                    existing.legacy_effects, projection.legacy_effects) {
                panic("legacy projection: remapped effect set has two physical rows")
            }
            return
        }
    }
    values.push(projection)
}

fn assemble_fact_binder(
    type_remap: CoreAssemblyTypeRemap, value: LegacyBinderFactProjection
) -> LegacyBinderProjection {
    make_legacy_binder_projection(
        value.slot, value.name, value.def_id,
        core_assembly_remap_type(type_remap, value.type_fact),
        value.ty, value.is_mutable)
}

fn assemble_fact_callable(
    type_remap: CoreAssemblyTypeRemap,
    value: LegacyCallableFactProjection
) -> LegacyCallableProjection {
    let mut parameters: List<LegacyBinderProjection> = []
    for parameter in value.parameters {
        parameters.push(assemble_fact_binder(type_remap, parameter))
    }
    make_legacy_callable_projection(
        value.reference, value.origin, value.module_body,
        value.container, value.kind, value.type_parameters,
        value.bounds, parameters,
        core_assembly_remap_type(type_remap, value.result_type_fact),
        value.result_type, value.effects, value.is_public)
}

fn assemble_fact_impl(
    type_remap: CoreAssemblyTypeRemap, value: LegacyImplFactProjection
) -> LegacyImplProjection {
    let mut bindings: List<LegacyAssocBindingProjection> = []
    for binding in value.assoc_bindings {
        bindings.push(make_legacy_assoc_binding_projection(
            binding.member_ref,
            core_assembly_remap_type(type_remap, binding.type_fact),
            binding.ty))
    }
    make_legacy_impl_projection(
        value.owner,
        core_assembly_remap_type(type_remap, value.target_type_fact),
        value.target_type, value.target_nominal, value.trait_ref,
        value.type_parameters, bindings, value.methods,
        value.module_body, value.container)
}

fn validate_projection_fact_order(values: List<LegacyProjectionFacts>) {
    let mut index = 0
    while index < values.len() {
        let value = values.get(index).unwrap()
        if value.module_order != index {
            panic("legacy projection: module facts are not topologically ordered")
        }
        let mut prior = 0
        while prior < index {
            if values.get(prior).unwrap().module_key == value.module_key {
                panic("legacy projection: duplicate module projection facts")
            }
            prior = prior + 1
        }
        index = index + 1
    }
}

fn validate_projection_shells_against_core(
    result: CoreAssemblyResult, shells: LegacyExecutableShellMap
) {
    let inventory = executable_inventory_entries(core_program_inventory(
        core_assembly_result_program(result)))
    let entries = legacy_executable_shell_entries(shells)
    if inventory.len() != entries.len() {
        panic("legacy projection: executable shells/Core inventory census differs")
    }
    for inventory_entry in inventory {
        let reference = executable_entry_reference(inventory_entry)
        let mut matches = 0
        for shell in entries {
            if executable_ref_same(shell.reference, reference) {
                matches = matches + 1
            }
        }
        if matches != 1 {
            panic("legacy projection: Core executable lacks one exact shell")
        }
    }
}

pub fn assemble_legacy_projection(
    facts_in_topological_order: List<LegacyProjectionFacts>,
    assembly: CoreAssemblyResult
) -> LegacyProjectionTable {
    if facts_in_topological_order.len() == 0 {
        panic("legacy projection: project has no module projection facts")
    }
    validate_projection_fact_order(facts_in_topological_order)
    let program = core_assembly_result_program(assembly)
    let type_remap = core_assembly_result_type_remap(assembly)
    let effect_remap = core_assembly_result_effect_remap(assembly)
    let project_type_count = core_type_graph_count(
        core_program_type_graph(program))
    let mut projected_types: List<LegacyTypeProjection> = []
    let mut projected_effects: List<LegacyEffectProjection> = []
    let mut projected_binders: List<LegacyBinderProjection> = []
    let mut projected_callables: List<LegacyCallableProjection> = []
    let mut projected_impls: List<LegacyImplProjection> = []
    let mut projected_shells: List<LegacyExecutableShell> = []
    for facts in facts_in_topological_order {
        for value in facts.types {
            append_assembled_type_projection(
                projected_types, make_legacy_type_projection(
                    core_assembly_remap_type(
                        type_remap, core_type_source_fact(value)),
                    core_type_source_type(value)))
        }
        for value in facts.effects {
            let local = core_effect_set_fact_local_set(value.fact)
            append_assembled_effect_projection(
                projected_effects, make_legacy_effect_projection(
                    core_assembly_remap_effect(
                        effect_remap, facts.module_key, local),
                    value.legacy_effects))
        }
        for value in facts.binders {
            projected_binders.push(assemble_fact_binder(type_remap, value))
        }
        for value in facts.callables {
            projected_callables.push(assemble_fact_callable(type_remap, value))
        }
        for value in facts.impls {
            projected_impls.push(assemble_fact_impl(type_remap, value))
        }
        for shell in legacy_executable_shell_entries(facts.shells) {
            projected_shells.push(shell)
        }
    }
    let ordered_types = order_assembled_type_projections(
        projected_types, project_type_count)
    let shell_map = make_legacy_executable_shell_map(projected_shells)
    validate_projection_shells_against_core(assembly, shell_map)
    make_legacy_projection_table(
        project_type_count, ordered_types, projected_effects,
        projected_binders, projected_callables,
        projected_impls, shell_map)
}
