// Stable identity for one generalized effect-row tail.
//
// Raw inference/UnionFind ids are intentionally absent from this module.  A
// producer may construct a reference only after TypedHIR has resolved ordinary
// effect metavariables and chosen a callable origin plus deterministic ordinal.
// CoreHIR and FlowIR transport this identity without reopening inference.

use ir_identity::{
    CoreTypeRef, core_type_ref_same,
    OriginRef, origin_ref_same,
    HandledEffectRef, SystemEffectRef,
    handled_effect_ref_same, system_effect_ref_same
}
use ir_inventory::{ExecutableRef, EffectCtxRef, effect_ctx_ref_same,
    effect_ctx_binding, binder_entry_kind, binder_kind_tag,
    binder_kind_effect_ctx_param, binder_kind_effect_ctx_local,
    binder_kind_effect_ctx_parent_capture}
use types::{Type, Effect, EffectRow, types_equal}

pub struct EffectParamRef {
    owner: OriginRef,
    ordinal: Int
}

pub fn make_effect_param_ref(
    owner: OriginRef, ordinal: Int
) -> EffectParamRef {
    if ordinal < 0 {
        panic("effect contract: invalid formal parameter identity")
    }
    EffectParamRef { owner: owner, ordinal: ordinal }
}

pub fn effect_param_owner(value: EffectParamRef) -> OriginRef {
    value.owner
}

pub fn effect_param_ordinal(value: EffectParamRef) -> Int {
    value.ordinal
}

pub fn effect_param_ref_same(
    left: EffectParamRef, right: EffectParamRef
) -> Bool {
    origin_ref_same(left.owner, right.owner) &&
        left.ordinal == right.ordinal
}

// Complete TypedHIR identity for one handled-effect context entry.  The
// nominal reference alone is deliberately insufficient: GenericProbe<Str>
// and GenericProbe<Int> are distinct entries even when both are live.
pub struct TypedHandledEffectInstance {
    reference: HandledEffectRef,
    type_arguments: List<Type>
}

pub fn make_typed_handled_effect_instance(
    reference: HandledEffectRef, type_arguments: List<Type>
) -> TypedHandledEffectInstance {
    TypedHandledEffectInstance {
        reference: reference,
        type_arguments: type_arguments.map(fn(value) { value })
    }
}

pub fn typed_handled_effect_instance_reference(
    value: TypedHandledEffectInstance
) -> HandledEffectRef { value.reference }

pub fn typed_handled_effect_instance_type_arguments(
    value: TypedHandledEffectInstance
) -> List<Type> { value.type_arguments.map(fn(item) { item }) }

pub fn typed_handled_effect_instance_same(
    left: TypedHandledEffectInstance, right: TypedHandledEffectInstance
) -> Bool {
    if !handled_effect_ref_same(left.reference, right.reference) ||
       left.type_arguments.len() != right.type_arguments.len() {
        return false
    }
    let mut index = 0
    while index < left.type_arguments.len() {
        if !types_equal(
                left.type_arguments.get(index).unwrap(),
                right.type_arguments.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}

pub fn typed_handled_effect_instances_from_row(
    row: EffectRow
) -> List<TypedHandledEffectInstance> {
    let mut result: List<TypedHandledEffectInstance> = []
    for atom in row.effects {
        match atom {
            Effect::CustomEffect { reference, type_args, .. } => {
                let instance = make_typed_handled_effect_instance(
                    reference, type_args)
                if result.any(fn(existing) {
                        typed_handled_effect_instance_same(existing, instance)
                    }) {
                    panic("typed effect context: callable entry repeats")
                }
                result.push(instance)
            },
            _ => {}
        }
    }
    result
}

enum TypedEffectCtxLayoutValue {
    EmptyEffectCtxLayout,
    FixedEffectCtxLayout(List<TypedHandledEffectInstance>),
    OpenEffectCtxLayout {
        entries: List<TypedHandledEffectInstance>,
        formal: EffectParamRef
    }
}

// The variant itself is the empty/fixed/open marker.  No raw inference tail
// crosses this contract and no downstream consumer may reclassify the row.
pub struct TypedEffectCtxLayout { value: TypedEffectCtxLayoutValue }

fn copy_typed_handled_effect_instances(
    values: List<TypedHandledEffectInstance>
) -> List<TypedHandledEffectInstance> {
    values.map(fn(value) {
        make_typed_handled_effect_instance(
            value.reference, value.type_arguments)
    })
}

fn validate_typed_effect_ctx_entries(
    entries: List<TypedHandledEffectInstance>
) {
    let mut left = 0
    while left < entries.len() {
        let mut right = left + 1
        while right < entries.len() {
            if typed_handled_effect_instance_same(
                    entries.get(left).unwrap(),
                    entries.get(right).unwrap()) {
                panic("typed effect context: exact entry repeats")
            }
            right = right + 1
        }
        left = left + 1
    }
}

pub fn make_typed_effect_ctx_layout(
    entries: List<TypedHandledEffectInstance>, formal: EffectParamRef?
) -> TypedEffectCtxLayout {
    validate_typed_effect_ctx_entries(entries)
    let copied = copy_typed_handled_effect_instances(entries)
    match formal {
        some(parameter) => TypedEffectCtxLayout {
            value: TypedEffectCtxLayoutValue::OpenEffectCtxLayout {
                entries: copied, formal: parameter
            }
        },
        none => if copied.len() == 0 {
            TypedEffectCtxLayout {
                value: TypedEffectCtxLayoutValue::EmptyEffectCtxLayout
            }
        } else {
            TypedEffectCtxLayout {
                value: TypedEffectCtxLayoutValue::FixedEffectCtxLayout(copied)
            }
        }
    }
}

pub fn empty_typed_effect_ctx_layout() -> TypedEffectCtxLayout {
    make_typed_effect_ctx_layout([], none)
}

pub fn typed_effect_ctx_layout_entries(
    value: TypedEffectCtxLayout
) -> List<TypedHandledEffectInstance> {
    match value.value {
        TypedEffectCtxLayoutValue::EmptyEffectCtxLayout => [],
        TypedEffectCtxLayoutValue::FixedEffectCtxLayout(entries) =>
            copy_typed_handled_effect_instances(entries),
        TypedEffectCtxLayoutValue::OpenEffectCtxLayout { entries, .. } =>
            copy_typed_handled_effect_instances(entries)
    }
}

pub fn typed_effect_ctx_layout_formal(
    value: TypedEffectCtxLayout
) -> EffectParamRef? {
    match value.value {
        TypedEffectCtxLayoutValue::OpenEffectCtxLayout { formal, .. } =>
            some(formal),
        _ => none
    }
}

pub fn typed_effect_ctx_layout_is_empty(
    value: TypedEffectCtxLayout
) -> Bool {
    match value.value {
        TypedEffectCtxLayoutValue::EmptyEffectCtxLayout => true,
        _ => false
    }
}

pub fn typed_effect_ctx_layout_same(
    left: TypedEffectCtxLayout, right: TypedEffectCtxLayout
) -> Bool {
    let left_entries = typed_effect_ctx_layout_entries(left)
    let right_entries = typed_effect_ctx_layout_entries(right)
    if left_entries.len() != right_entries.len() { return false }
    let mut index = 0
    while index < left_entries.len() {
        if !typed_handled_effect_instance_same(
                left_entries.get(index).unwrap(),
                right_entries.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    match (typed_effect_ctx_layout_formal(left),
           typed_effect_ctx_layout_formal(right)) {
        (some(a), some(b)) => effect_param_ref_same(a, b),
        (none, none) => true,
        _ => false
    }
}

pub struct TypedCallableEffectCtx {
    binding: EffectCtxRef,
    layout: TypedEffectCtxLayout
}

pub fn make_typed_callable_effect_ctx(
    binding: EffectCtxRef, layout: TypedEffectCtxLayout
) -> TypedCallableEffectCtx {
    let kind = binder_kind_tag(binder_entry_kind(effect_ctx_binding(binding)))
    if kind != binder_kind_tag(binder_kind_effect_ctx_param()) &&
       kind != binder_kind_tag(binder_kind_effect_ctx_parent_capture()) {
        panic("typed effect context: callable binding is not borrowed")
    }
    TypedCallableEffectCtx { binding: binding, layout: layout }
}

pub fn typed_callable_effect_ctx_binding(
    value: TypedCallableEffectCtx
) -> EffectCtxRef { value.binding }

pub fn typed_callable_effect_ctx_layout(
    value: TypedCallableEffectCtx
) -> TypedEffectCtxLayout { value.layout }

enum TypedEffectCtxSourceValue {
    EmptyEffectCtxSource,
    BorrowedEffectCtxSource(EffectCtxRef)
}

pub struct TypedEffectCtxSource { value: TypedEffectCtxSourceValue }

pub fn make_empty_effect_ctx_source() -> TypedEffectCtxSource {
    TypedEffectCtxSource {
        value: TypedEffectCtxSourceValue::EmptyEffectCtxSource
    }
}

pub fn make_borrowed_effect_ctx_source(
    context: EffectCtxRef
) -> TypedEffectCtxSource {
    TypedEffectCtxSource {
        value: TypedEffectCtxSourceValue::BorrowedEffectCtxSource(context)
    }
}

pub fn typed_effect_ctx_source_is_empty(
    value: TypedEffectCtxSource
) -> Bool {
    match value.value {
        TypedEffectCtxSourceValue::EmptyEffectCtxSource => true,
        TypedEffectCtxSourceValue::BorrowedEffectCtxSource(_) => false
    }
}

pub fn typed_effect_ctx_source_context(
    value: TypedEffectCtxSource
) -> EffectCtxRef {
    match value.value {
        TypedEffectCtxSourceValue::BorrowedEffectCtxSource(context) => context,
        TypedEffectCtxSourceValue::EmptyEffectCtxSource =>
            panic("typed effect context: empty source has no binding")
    }
}

pub struct TypedEffectCtxLookup {
    context: EffectCtxRef,
    instance: TypedHandledEffectInstance
}

pub fn make_typed_effect_ctx_lookup(
    context: EffectCtxRef, instance: TypedHandledEffectInstance
) -> TypedEffectCtxLookup {
    TypedEffectCtxLookup {
        context: context, instance: instance
    }
}

pub fn typed_effect_ctx_lookup_context(
    value: TypedEffectCtxLookup
) -> EffectCtxRef { value.context }

pub fn typed_effect_ctx_lookup_instance(
    value: TypedEffectCtxLookup
) -> TypedHandledEffectInstance { value.instance }

pub struct TypedEffectCtxInstall {
    parent: EffectCtxRef,
    child: EffectCtxRef,
    entries: List<TypedHandledEffectInstance>
}

pub fn make_typed_effect_ctx_install(
    parent: EffectCtxRef, child: EffectCtxRef,
    entries: List<TypedHandledEffectInstance>
) -> TypedEffectCtxInstall {
    if effect_ctx_ref_same(parent, child) || entries.len() == 0 ||
       binder_kind_tag(binder_entry_kind(effect_ctx_binding(child))) !=
            binder_kind_tag(binder_kind_effect_ctx_local()) {
        panic("typed effect context: invalid owned child install")
    }
    validate_typed_effect_ctx_entries(entries)
    TypedEffectCtxInstall {
        parent: parent, child: child,
        entries: copy_typed_handled_effect_instances(entries)
    }
}

pub fn typed_effect_ctx_install_parent(
    value: TypedEffectCtxInstall
) -> EffectCtxRef { value.parent }

pub fn typed_effect_ctx_install_child(
    value: TypedEffectCtxInstall
) -> EffectCtxRef { value.child }

pub fn typed_effect_ctx_install_entries(
    value: TypedEffectCtxInstall
) -> List<TypedHandledEffectInstance> {
    copy_typed_handled_effect_instances(value.entries)
}

// One canonical TypedHIR definition-header relation.  The raw tail remains a
// module-local inference token; EffectParamRef is the semantic identity that
// survives import/re-export.  A schema may carry parameters from more than one
// existing owner (for example a generated specialization), but each owner's
// parameters must appear once in their original ordinal order.  Density is a
// definition-producer invariant: a transported subset may start at ordinal 2.
pub struct TypedEffectHeaderBinding {
    raw_tail: Int,
    parameter: EffectParamRef
}

pub fn make_typed_effect_header_binding(
    raw_tail: Int, parameter: EffectParamRef
) -> TypedEffectHeaderBinding {
    if raw_tail < 0 {
        panic("typed effect header: invalid inference-row tail")
    }
    TypedEffectHeaderBinding {
        raw_tail: raw_tail, parameter: parameter
    }
}

pub fn typed_effect_header_binding_raw_tail(
    value: TypedEffectHeaderBinding
) -> Int { value.raw_tail }

pub fn typed_effect_header_binding_parameter(
    value: TypedEffectHeaderBinding
) -> EffectParamRef { value.parameter }

pub struct TypedEffectHeaderSchema {
    bindings: List<TypedEffectHeaderBinding>
}

pub fn make_typed_effect_header_schema(
    bindings: List<TypedEffectHeaderBinding>
) -> TypedEffectHeaderSchema {
    let mut copied: List<TypedEffectHeaderBinding> = []
    let mut index = 0
    while index < bindings.len() {
        let binding = bindings.get(index).unwrap()
        let raw_tail = binding.raw_tail
        let parameter = binding.parameter
        let mut prior_owner_ordinal: Int? = none
        let mut prior = 0
        while prior < index {
            let earlier = bindings.get(prior).unwrap()
            if earlier.raw_tail == raw_tail {
                panic("typed effect header: raw tail repeats")
            }
            if effect_param_ref_same(earlier.parameter, parameter) {
                panic("typed effect header: parameter repeats")
            }
            if origin_ref_same(
                    effect_param_owner(earlier.parameter),
                    effect_param_owner(parameter)) {
                prior_owner_ordinal = some(
                    effect_param_ordinal(earlier.parameter))
            }
            prior = prior + 1
        }
        match prior_owner_ordinal {
            some(ordinal) => if effect_param_ordinal(parameter) <= ordinal {
                panic("typed effect header: owner ordinal order changed")
            },
            none => {}
        }
        copied.push(make_typed_effect_header_binding(
            raw_tail, parameter))
        index = index + 1
    }
    TypedEffectHeaderSchema { bindings: copied }
}

pub fn empty_typed_effect_header_schema() -> TypedEffectHeaderSchema {
    make_typed_effect_header_schema([])
}

pub fn typed_effect_header_schema_bindings(
    value: TypedEffectHeaderSchema
) -> List<TypedEffectHeaderBinding> {
    value.bindings.map(fn(binding) {
        make_typed_effect_header_binding(
            binding.raw_tail, binding.parameter)
    })
}

pub fn typed_effect_header_schema_same(
    left: TypedEffectHeaderSchema, right: TypedEffectHeaderSchema
) -> Bool {
    if left.bindings.len() != right.bindings.len() { return false }
    let mut index = 0
    while index < left.bindings.len() {
        let a = left.bindings.get(index).unwrap()
        let b = right.bindings.get(index).unwrap()
        if a.raw_tail != b.raw_tail ||
           !effect_param_ref_same(a.parameter, b.parameter) {
            return false
        }
        index = index + 1
    }
    true
}

// TypedHIR's immutable bridge from one module-local inference-row tail to the
// stable formal identity that Core is allowed to consume.  `raw_tail` is only
// a lookup token inside the already-closed module; it is never transported as
// Core identity and may not be reminted or re-owned downstream.
pub struct TypedEffectFormalFact {
    raw_tail: Int,
    parameter: EffectParamRef
}

pub fn make_typed_effect_formal_fact(
    raw_tail: Int, parameter: EffectParamRef
) -> TypedEffectFormalFact {
    if raw_tail < 0 {
        panic("typed effect freeze: invalid inference-row tail")
    }
    TypedEffectFormalFact {
        raw_tail: raw_tail,
        parameter: parameter
    }
}

pub fn typed_effect_formal_raw_tail(
    value: TypedEffectFormalFact
) -> Int { value.raw_tail }

pub fn typed_effect_formal_parameter(
    value: TypedEffectFormalFact
) -> EffectParamRef { value.parameter }

pub struct TypedCallableEffectFact {
    reference: ExecutableRef,
    row: EffectRow
}

pub fn make_typed_callable_effect_fact(
    reference: ExecutableRef, row: EffectRow
) -> TypedCallableEffectFact {
    TypedCallableEffectFact {
        reference: reference,
        row: EffectRow { effects: row.effects, tail: row.tail }
    }
}

pub fn typed_callable_effect_reference(
    value: TypedCallableEffectFact
) -> ExecutableRef { value.reference }

pub fn typed_callable_effect_row(
    value: TypedCallableEffectFact
) -> EffectRow {
    EffectRow { effects: value.row.effects, tail: value.row.tail }
}

// One exact effect contract freezes at the Core boundary and is transported
// unchanged through Flow.  Flow must not rebuild or translate this relation.
enum CoreEffectAtomValue {
    FailEffectValue(CoreTypeRef),
    MutEffectValue(CoreTypeRef),
    UnsafeEffectValue,
    HandledEffectValue {
        effect_ref: HandledEffectRef,
        type_arguments: List<CoreTypeRef>
    },
    SystemEffectValue(SystemEffectRef)
}

pub struct CoreEffectAtom { value: CoreEffectAtomValue }

fn copy_core_type_refs(values: List<CoreTypeRef>) -> List<CoreTypeRef> {
    values.map(fn(value) { value })
}

pub fn make_core_fail_effect(error_type: CoreTypeRef) -> CoreEffectAtom {
    CoreEffectAtom { value: CoreEffectAtomValue::FailEffectValue(error_type) }
}
pub fn make_core_mut_effect(state_type: CoreTypeRef) -> CoreEffectAtom {
    CoreEffectAtom { value: CoreEffectAtomValue::MutEffectValue(state_type) }
}
pub fn make_core_unsafe_effect() -> CoreEffectAtom {
    CoreEffectAtom { value: CoreEffectAtomValue::UnsafeEffectValue }
}
pub fn make_core_handled_effect(
    effect_ref: HandledEffectRef, type_arguments: List<CoreTypeRef>
) -> CoreEffectAtom {
    CoreEffectAtom {
        value: CoreEffectAtomValue::HandledEffectValue {
            effect_ref: effect_ref,
            type_arguments: copy_core_type_refs(type_arguments)
        }
    }
}
pub fn make_core_system_effect(effect_ref: SystemEffectRef) -> CoreEffectAtom {
    CoreEffectAtom {
        value: CoreEffectAtomValue::SystemEffectValue(effect_ref)
    }
}

pub fn core_effect_atom_kind_tag(value: CoreEffectAtom) -> Int {
    match value.value {
        CoreEffectAtomValue::FailEffectValue(_) => 0,
        CoreEffectAtomValue::MutEffectValue(_) => 1,
        CoreEffectAtomValue::UnsafeEffectValue => 2,
        CoreEffectAtomValue::HandledEffectValue { .. } => 3,
        CoreEffectAtomValue::SystemEffectValue(_) => 4
    }
}
pub fn core_effect_atom_type(value: CoreEffectAtom) -> CoreTypeRef {
    match value.value {
        CoreEffectAtomValue::FailEffectValue(ty) => ty,
        CoreEffectAtomValue::MutEffectValue(ty) => ty,
        _ => panic("effect contract: atom has no type argument")
    }
}
pub fn core_effect_atom_handled_ref(value: CoreEffectAtom) -> HandledEffectRef {
    match value.value {
        CoreEffectAtomValue::HandledEffectValue { effect_ref, .. } => effect_ref,
        _ => panic("effect contract: atom is not handled")
    }
}
pub fn core_effect_atom_type_arguments(
    value: CoreEffectAtom
) -> List<CoreTypeRef> {
    match value.value {
        CoreEffectAtomValue::HandledEffectValue { type_arguments, .. } =>
            copy_core_type_refs(type_arguments),
        _ => []
    }
}
pub fn core_effect_atom_system_ref(value: CoreEffectAtom) -> SystemEffectRef {
    match value.value {
        CoreEffectAtomValue::SystemEffectValue(effect_ref) => effect_ref,
        _ => panic("effect contract: atom is not system")
    }
}

pub fn core_effect_atom_same(
    left: CoreEffectAtom, right: CoreEffectAtom
) -> Bool {
    match (left.value, right.value) {
        (CoreEffectAtomValue::FailEffectValue(a),
         CoreEffectAtomValue::FailEffectValue(b)) => core_type_ref_same(a, b),
        (CoreEffectAtomValue::MutEffectValue(a),
         CoreEffectAtomValue::MutEffectValue(b)) => core_type_ref_same(a, b),
        (CoreEffectAtomValue::UnsafeEffectValue,
         CoreEffectAtomValue::UnsafeEffectValue) => true,
        (CoreEffectAtomValue::HandledEffectValue {
            effect_ref: a, type_arguments: aa
         }, CoreEffectAtomValue::HandledEffectValue {
            effect_ref: b, type_arguments: ba
         }) => {
            if !handled_effect_ref_same(a, b) || aa.len() != ba.len() {
                return false
            }
            let mut index = 0
            while index < aa.len() {
                if !core_type_ref_same(
                        aa.get(index).unwrap(), ba.get(index).unwrap()) {
                    return false
                }
                index = index + 1
            }
            true
        },
        (CoreEffectAtomValue::SystemEffectValue(a),
         CoreEffectAtomValue::SystemEffectValue(b)) =>
            system_effect_ref_same(a, b),
        _ => false
    }
}

fn copy_effect_atoms(values: List<CoreEffectAtom>) -> List<CoreEffectAtom> {
    values.map(fn(value) { value })
}

pub struct CoreEffectSet { atoms: List<CoreEffectAtom> }

pub fn make_core_effect_set(atoms: List<CoreEffectAtom>) -> CoreEffectSet {
    let mut left_index = 0
    while left_index < atoms.len() {
        let mut right_index = left_index + 1
        while right_index < atoms.len() {
            if core_effect_atom_same(
                    atoms.get(left_index).unwrap(),
                    atoms.get(right_index).unwrap()) {
                panic("effect contract: effect set repeats an exact atom")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    CoreEffectSet { atoms: copy_effect_atoms(atoms) }
}
pub fn core_effect_set_atoms(value: CoreEffectSet) -> List<CoreEffectAtom> {
    copy_effect_atoms(value.atoms)
}
pub fn core_effect_set_same(left: CoreEffectSet, right: CoreEffectSet) -> Bool {
    if left.atoms.len() != right.atoms.len() { return false }
    for atom in left.atoms {
        let mut matches = 0
        for candidate in right.atoms {
            if core_effect_atom_same(atom, candidate) { matches = matches + 1 }
        }
        if matches != 1 { return false }
    }
    true
}

pub struct CoreEffectContract {
    exact: CoreEffectSet,
    parameter: EffectParamRef?
}

pub fn make_core_effect_contract(
    exact: CoreEffectSet, parameter: EffectParamRef?
) -> CoreEffectContract {
    CoreEffectContract {
        exact: make_core_effect_set(exact.atoms), parameter: parameter
    }
}
pub fn make_closed_core_effect_contract(
    exact: CoreEffectSet
) -> CoreEffectContract { make_core_effect_contract(exact, none) }
pub fn core_effect_contract_exact(
    value: CoreEffectContract
) -> CoreEffectSet { make_core_effect_set(value.exact.atoms) }
pub fn core_effect_contract_parameter(
    value: CoreEffectContract
) -> EffectParamRef? { value.parameter }
pub fn core_effect_contract_same(
    left: CoreEffectContract, right: CoreEffectContract
) -> Bool {
    if !core_effect_set_same(left.exact, right.exact) { return false }
    match (left.parameter, right.parameter) {
        (some(a), some(b)) => effect_param_ref_same(a, b),
        (none, none) => true,
        _ => false
    }
}
pub fn copy_core_effect_contract(
    value: CoreEffectContract
) -> CoreEffectContract { make_core_effect_contract(value.exact, value.parameter) }

fn merge_core_effect_sets(
    left: CoreEffectSet, right: CoreEffectSet
) -> CoreEffectSet {
    let mut result = copy_effect_atoms(left.atoms)
    for atom in right.atoms {
        if !result.any(fn(existing) { core_effect_atom_same(existing, atom) }) {
            result.push(atom)
        }
    }
    make_core_effect_set(result)
}

pub fn core_effect_set_contains_atom(
    value: CoreEffectSet, target: CoreEffectAtom
) -> Bool {
    value.atoms.any(fn(atom) { core_effect_atom_same(atom, target) })
}

pub struct CoreEffectInstantiation {
    source: CoreEffectContract,
    substitutions: List<CoreEffectSubstitution>,
    result: CoreEffectContract
}
pub struct CoreEffectSubstitution {
    parameter: EffectParamRef,
    replacement: CoreEffectContract
}
pub fn make_core_effect_substitution(
    parameter: EffectParamRef, replacement: CoreEffectContract
) -> CoreEffectSubstitution {
    CoreEffectSubstitution {
        parameter: parameter,
        replacement: copy_core_effect_contract(replacement)
    }
}
pub fn core_effect_substitution_parameter(
    value: CoreEffectSubstitution
) -> EffectParamRef { value.parameter }
pub fn core_effect_substitution_replacement(
    value: CoreEffectSubstitution
) -> CoreEffectContract { copy_core_effect_contract(value.replacement) }
pub fn make_core_effect_instantiation(
    source: CoreEffectContract, substitutions: List<CoreEffectSubstitution>,
    result: CoreEffectContract
) -> CoreEffectInstantiation {
    match source.parameter {
        some(parameter) => {
            if substitutions.len() != 1 ||
               !effect_param_ref_same(
                    substitutions.get(0).unwrap().parameter, parameter) {
                panic("effect contract: substitution formal arity/order differs")
            }
            let actual = substitutions.get(0).unwrap().replacement
            let expected = make_core_effect_contract(
                merge_core_effect_sets(source.exact, actual.exact),
                actual.parameter)
            if !core_effect_contract_same(expected, result) {
                panic("effect contract: substitution/result differs")
            }
        },
        none => if substitutions.len() != 0 ||
                !core_effect_contract_same(source, result) {
            panic("effect contract: closed effect call carries a substitution")
        }
    }
    CoreEffectInstantiation {
        source: copy_core_effect_contract(source),
        substitutions: substitutions.map(fn(value) {
            make_core_effect_substitution(value.parameter, value.replacement)
        }),
        result: copy_core_effect_contract(result)
    }
}
pub fn make_explicit_core_effect_instantiation(
    source: CoreEffectContract, replacement: CoreEffectContract,
    result: CoreEffectContract
) -> CoreEffectInstantiation {
    match source.parameter {
        none => make_core_effect_instantiation(source, [], result),
        some(parameter) => make_core_effect_instantiation(
            source, [make_core_effect_substitution(parameter, replacement)], result)
    }
}
// The one directional effect-contract relation used by callable type
// compatibility.  A closed formal is exact.  An open formal admits precisely
// the one substitution already modelled by CoreEffectInstantiation; passing
// the actual contract as both replacement and result is legal exactly when
// every fixed formal atom is retained.
pub fn core_effect_contract_actual_satisfies_formal(
    actual: CoreEffectContract, formal: CoreEffectContract
) -> Bool {
    match formal.parameter {
        none => if !core_effect_contract_same(actual, formal) {
            return false
        },
        some(_) => {
            for atom in formal.exact.atoms {
                if !core_effect_set_contains_atom(actual.exact, atom) {
                    return false
                }
            }
        }
    }
    let _ = make_explicit_core_effect_instantiation(
        formal, actual, actual)
    true
}
pub fn core_effect_instantiation_source(
    value: CoreEffectInstantiation
) -> CoreEffectContract { copy_core_effect_contract(value.source) }
pub fn core_effect_instantiation_substitutions(
    value: CoreEffectInstantiation
) -> List<CoreEffectSubstitution> {
    value.substitutions.map(fn(item) {
        make_core_effect_substitution(item.parameter, item.replacement)
    })
}
pub fn core_effect_instantiation_result(
    value: CoreEffectInstantiation
) -> CoreEffectContract { copy_core_effect_contract(value.result) }
pub fn core_effect_contract_handled_instances(
    value: CoreEffectContract
) -> List<CoreEffectAtom> {
    let mut result: List<CoreEffectAtom> = []
    for atom in value.exact.atoms {
        match atom.value {
            CoreEffectAtomValue::HandledEffectValue { .. } =>
                result.push(atom),
            _ => {}
        }
    }
    result
}
