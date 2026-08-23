// Delegate TypedPlan -> ordinary CoreHIR bodies.
//
// This pass is deliberately forgetful: its output is only the same CoreBody
// representation used by source/default/derived methods.  No delegate kind,
// root, identity, provider lookup, or fallback survives this boundary.

use ir_identity::{
    NominalFieldRef, handled_effect_ref_symbol
}

use core_expr::{
    CoreBody, CoreImplMetadata,
    make_core_assoc_binding, make_core_obligation_binding,
    make_core_impl_metadata,
    make_core_effect_set,
    make_core_nominal_field,
    make_core_project_expr,
    make_core_method_call_expr,
    make_core_initialize_stmt,
    make_core_block,
    make_core_body,
    validate_core_body
}
use delegate_plan::{
    DelegateTypedPlan, DelegateMethodPlan, DelegateMethodBodyPlan,
    delegate_typed_plan_field, delegate_typed_plan_methods,
    delegate_typed_plan_outer_owner,
    delegate_typed_plan_assoc_bindings,
    delegate_typed_plan_effect_evidence,
    delegate_typed_plan_dict_evidence,
    delegate_assoc_binding_member, delegate_assoc_binding_type,
    delegate_handled_evidence_requirement,
    delegate_handled_evidence_value,
    delegate_evidence_requirement, delegate_evidence_value,
    delegate_method_executable, delegate_method_origin,
    delegate_method_generated,
    delegate_method_child_call, delegate_method_child_callee,
    delegate_method_body,
    delegate_body_type_count, delegate_body_manifest,
    delegate_body_scopes, delegate_body_slots, delegate_body_parameter_slots,
    delegate_body_field_type, delegate_body_result_type,
    delegate_body_wrapper_receiver, delegate_body_field_receiver,
    delegate_body_forwarded_arguments, delegate_body_result_slot,
    delegate_body_effects, delegate_body_evidence,
    delegate_body_origin, delegate_body_scope
}

fn elaborate_delegate_method(
    field: NominalFieldRef,
    method: DelegateMethodPlan
) -> CoreBody {
    let body = delegate_method_body(method)
    let body_origin = delegate_body_origin(body)
    let projected = make_core_project_expr(
        delegate_body_field_receiver(body),
        delegate_body_field_type(body),
        make_core_effect_set([]), body_origin,
        delegate_body_wrapper_receiver(body),
        make_core_nominal_field(field), false)
    let project_stmt = make_core_initialize_stmt(
        delegate_body_field_receiver(body), projected, body_origin)
    let forwarded = make_core_method_call_expr(
        delegate_body_result_slot(body),
        delegate_body_result_type(body),
        delegate_body_effects(body), body_origin,
        delegate_method_child_callee(method),
        delegate_method_child_call(method),
        delegate_body_field_receiver(body),
        delegate_body_forwarded_arguments(body),
        delegate_body_evidence(body))
    let block = make_core_block(
        [project_stmt], some(forwarded), body_origin,
        delegate_body_scope(body))
    let result = make_core_body(
        delegate_method_executable(method), delegate_method_origin(method),
        delegate_body_type_count(body), delegate_body_manifest(body),
        delegate_body_scopes(body), delegate_body_slots(body),
        delegate_body_parameter_slots(body),
        delegate_body_result_type(body), block)
    validate_core_body(result)
    result
}

pub fn elaborate_delegate_to_core(
    plan: DelegateTypedPlan
) -> (CoreImplMetadata, List<CoreBody>) {
    let field = delegate_typed_plan_field(plan)
    let mut result: List<CoreBody> = []
    let mut methods = []
    for method in delegate_typed_plan_methods(plan) {
        result.push(elaborate_delegate_method(field, method))
        methods.push(delegate_method_generated(method))
    }
    let assoc = delegate_typed_plan_assoc_bindings(plan).map(fn(binding) {
        make_core_assoc_binding(
            delegate_assoc_binding_member(binding),
            delegate_assoc_binding_type(binding))
    })
    let mut obligations = []
    for binding in delegate_typed_plan_effect_evidence(plan) {
        obligations.push(make_core_obligation_binding(
            handled_effect_ref_symbol(
                delegate_handled_evidence_requirement(binding)),
            delegate_handled_evidence_value(binding)))
    }
    for binding in delegate_typed_plan_dict_evidence(plan) {
        obligations.push(make_core_obligation_binding(
            delegate_evidence_requirement(binding),
            delegate_evidence_value(binding)))
    }
    (make_core_impl_metadata(
        delegate_typed_plan_outer_owner(plan),
        methods, assoc, obligations), result)
}
