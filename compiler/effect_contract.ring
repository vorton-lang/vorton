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
pub fn core_effect_contract_handled_requirements(
    value: CoreEffectContract
) -> List<HandledEffectRef> {
    let mut result: List<HandledEffectRef> = []
    for atom in value.exact.atoms {
        match atom.value {
            CoreEffectAtomValue::HandledEffectValue { effect_ref, .. } =>
                result.push(effect_ref),
            _ => {}
        }
    }
    result
}
