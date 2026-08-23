// Physical CoreHIR closure shared by semantic lowerings.
//
// A CoreBodyEntry records only the exact executable, its exact origin, and the
// already-validated body anchor declared by ExecutableInventory. ContractOnly
// builtin intrinsics close through the same inventory/manifests constructor
// with no body entry; executable bodies never escape through legacy HIR here.

use ir_identity::{
    OriginRef, PathRef, origin_ref_same, path_ref_same,
    impl_method_ref_member, symbol_ref_same
}
use ir_inventory::{
    ExecutableRef, ExecutableInventory,
    BinderManifest, IrInventoryClosure,
    executable_ref_same,
    executable_ref_is_named, executable_ref_named_symbol,
    executable_entry_reference, executable_entry_contract,
    executable_contract_mode, executable_contract_mode_same,
    executable_contract_mode_concrete_body,
    executable_contract_mode_contract_only,
    executable_contract_body_path,
    executable_inventory_entries,
    close_ir_inventory,
    ir_inventory_closure_inventory,
    ir_inventory_closure_manifests}
use core_expr::{
    CoreBody, CoreTypeGraph, CoreCallableContract, CoreImplMetadata,
    validate_core_body, validate_core_callable_contracts,
    validate_core_body_with_program,
    core_body_reference, core_body_origin,
    core_type_graph_count, core_type_graph_nodes,
    make_core_type_graph,
    core_callable_reference, core_callable_mode,
    copy_core_callables, copy_core_impl_metadata,
    core_impl_methods, core_impl_assoc_bindings,
    core_assoc_binding_type, core_type_ref_index
}
use flow_ir::{
    flow_callable_mode_same, flow_callable_mode_concrete_body,
    flow_callable_mode_contract_only
}

pub struct CoreBodyEntry {
    reference: ExecutableRef,
    origin: OriginRef,
    body_anchor: PathRef,
    body: CoreBody
}

pub fn make_core_body_entry(
    reference: ExecutableRef, origin: OriginRef,
    body_anchor: PathRef, body: CoreBody
) -> CoreBodyEntry {
    validate_core_body(body)
    if !executable_ref_same(reference, core_body_reference(body)) ||
       !origin_ref_same(origin, core_body_origin(body)) {
        panic("CoreHIR: body entry identity differs from body")
    }
    CoreBodyEntry {
        reference: reference,
        origin: origin,
        body_anchor: body_anchor,
        body: body
    }
}

fn copy_core_body_entries(values: List<CoreBodyEntry>) -> List<CoreBodyEntry> {
    let mut result: List<CoreBodyEntry> = []
    for value in values {
        result.push(CoreBodyEntry {
            reference: value.reference,
            origin: value.origin,
            body_anchor: value.body_anchor,
            body: value.body
        })
    }
    result
}

fn core_body_refs_are_unique(values: List<CoreBodyEntry>) -> Bool {
    let mut left_index = 0
    while left_index < values.len() {
        let left = values.get(left_index).unwrap()
        let mut right_index = left_index + 1
        while right_index < values.len() {
            let right = values.get(right_index).unwrap()
            if executable_ref_same(left.reference, right.reference) {
                return false
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    true
}

// Bodies form the exact concrete-body subsequence of ExecutableInventory.
// ContractOnly entries have no body anchor.  Matching is positional and exact;
// sorting or searching by a display spelling would create a second authority.
fn validate_core_body_subsequence(
    bodies: List<CoreBodyEntry>, inventory: ExecutableInventory
) {
    if !core_body_refs_are_unique(bodies) {
        panic("CoreHIR: duplicate executable body reference")
    }
    let entries = executable_inventory_entries(inventory)
    let mut body_index = 0
    for entry in entries {
        let contract = executable_entry_contract(entry)
        let mode = executable_contract_mode(contract)
        if executable_contract_mode_same(
                mode, executable_contract_mode_concrete_body()) {
            let body = match bodies.get(body_index) {
                some(value) => value,
                none => panic("CoreHIR: concrete executable body is missing")
            }
            if !executable_ref_same(
                    body.reference, executable_entry_reference(entry)) {
                panic("CoreHIR: body order differs from executable inventory")
            }
            if !path_ref_same(
                    body.body_anchor,
                    executable_contract_body_path(contract)) {
                panic("CoreHIR: body anchor differs from executable contract")
            }
            body_index = body_index + 1
        } else if !executable_contract_mode_same(
                mode, executable_contract_mode_contract_only()) {
            panic("CoreHIR: executable contract mode is invalid")
        }
    }
    if body_index != bodies.len() {
        panic("CoreHIR: body has no concrete executable inventory entry")
    }
}

fn validate_core_callable_inventory(
    callables: List<CoreCallableContract>, inventory: ExecutableInventory
) {
    let entries = executable_inventory_entries(inventory)
    if entries.len() != callables.len() {
        panic("CoreHIR: callable/inventory census differs")
    }
    let mut index = 0
    while index < entries.len() {
        let entry = entries.get(index).unwrap()
        let callable = callables.get(index).unwrap()
        if !executable_ref_same(
                executable_entry_reference(entry),
                core_callable_reference(callable)) {
            panic("CoreHIR: callable order differs from inventory")
        }
        let inventory_mode = executable_contract_mode(
            executable_entry_contract(entry))
        let core_mode = core_callable_mode(callable)
        if (executable_contract_mode_same(
                inventory_mode, executable_contract_mode_concrete_body()) &&
            !flow_callable_mode_same(
                core_mode, flow_callable_mode_concrete_body())) ||
           (executable_contract_mode_same(
                inventory_mode, executable_contract_mode_contract_only()) &&
            !flow_callable_mode_same(
                core_mode, flow_callable_mode_contract_only())) {
            panic("CoreHIR: callable/inventory body mode differs")
        }
        index = index + 1
    }
}

fn validate_core_impls(
    values: List<CoreImplMetadata>, graph: CoreTypeGraph,
    callables: List<CoreCallableContract>
) {
    for value in values {
        for method in core_impl_methods(value) {
            let member = impl_method_ref_member(method)
            let mut found = 0
            for callable in callables {
                let reference = core_callable_reference(callable)
                if executable_ref_is_named(reference) &&
                   symbol_ref_same(
                        executable_ref_named_symbol(reference),
                        member) {
                    found = found + 1
                }
            }
            if found != 1 {
                panic("CoreHIR: impl method has no unique callable")
            }
        }
        for binding in core_impl_assoc_bindings(value) {
            if core_type_ref_index(core_assoc_binding_type(binding)) < 0 ||
               core_type_ref_index(core_assoc_binding_type(binding)) >=
                    core_type_graph_count(graph) {
                panic("CoreHIR: impl associated binding type is absent")
            }
        }
    }
}

pub struct CoreProgram {
    closure: IrInventoryClosure,
    type_graph: CoreTypeGraph,
    callables: List<CoreCallableContract>,
    impls: List<CoreImplMetadata>,
    bodies: List<CoreBodyEntry>
}

pub fn make_core_program(
    type_graph: CoreTypeGraph,
    callables: List<CoreCallableContract>,
    impls: List<CoreImplMetadata>, bodies: List<CoreBodyEntry>,
    inventory: ExecutableInventory, manifests: List<BinderManifest>
) -> CoreProgram {
    let closure = close_ir_inventory(inventory, manifests)
    let closed_inventory = ir_inventory_closure_inventory(closure)
    let closed_callables = copy_core_callables(callables)
    validate_core_callable_contracts(type_graph, closed_callables)
    validate_core_callable_inventory(closed_callables, closed_inventory)
    validate_core_body_subsequence(bodies, closed_inventory)
    let mut body_index = 0
    for callable in closed_callables {
        if flow_callable_mode_same(
                core_callable_mode(callable),
                flow_callable_mode_concrete_body()) {
            let entry = bodies.get(body_index).unwrap()
            validate_core_body_with_program(
                entry.body, type_graph, closed_callables, callable)
            body_index = body_index + 1
        }
    }
    validate_core_impls(impls, type_graph, closed_callables)
    CoreProgram {
        closure: closure,
        type_graph: make_core_type_graph(core_type_graph_nodes(type_graph)),
        callables: copy_core_callables(closed_callables),
        impls: copy_core_impl_metadata(impls),
        bodies: copy_core_body_entries(bodies)
    }
}

pub fn core_program_body_count(value: CoreProgram) -> Int {
    value.bodies.len()
}

pub fn core_program_bodies(value: CoreProgram) -> List<CoreBodyEntry> {
    copy_core_body_entries(value.bodies)
}

pub fn core_body_entry_body(value: CoreBodyEntry) -> CoreBody {
    value.body
}
pub fn core_body_entry_reference(value: CoreBodyEntry) -> ExecutableRef {
    value.reference
}
pub fn core_body_entry_origin(value: CoreBodyEntry) -> OriginRef { value.origin }
pub fn core_body_entry_anchor(value: CoreBodyEntry) -> PathRef { value.body_anchor }

pub fn core_program_type_graph(value: CoreProgram) -> CoreTypeGraph {
    make_core_type_graph(core_type_graph_nodes(value.type_graph))
}
pub fn core_program_callables(value: CoreProgram) -> List<CoreCallableContract> {
    copy_core_callables(value.callables)
}
pub fn core_program_impls(value: CoreProgram) -> List<CoreImplMetadata> {
    copy_core_impl_metadata(value.impls)
}

pub fn core_program_inventory(value: CoreProgram) -> ExecutableInventory {
    ir_inventory_closure_inventory(value.closure)
}

pub fn core_program_manifests(value: CoreProgram) -> List<BinderManifest> {
    ir_inventory_closure_manifests(value.closure)
}
