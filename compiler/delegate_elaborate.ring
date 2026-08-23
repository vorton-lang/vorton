// Delegate TypedPlan -> ordinary CoreHIR bodies.
//
// This pass is deliberately forgetful: its output is only the same CoreBody
// representation used by source/default/derived methods.  No delegate kind,
// root, identity, provider lookup, or fallback survives this boundary.

use ir_identity::{NominalFieldRef}

use core_expr::{
    CoreBody,
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
    delegate_method_executable, delegate_method_origin,
    delegate_method_child_call, delegate_method_child_callee,
    delegate_method_body,
    delegate_body_type_count, delegate_body_manifest,
    delegate_body_slots, delegate_body_parameter_slots,
    delegate_body_field_type, delegate_body_result_type,
    delegate_body_wrapper_receiver, delegate_body_field_receiver,
    delegate_body_forwarded_arguments, delegate_body_result_slot,
    delegate_body_effects, delegate_body_evidence,
    delegate_body_origin
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
    let block = make_core_block([project_stmt], some(forwarded), body_origin)
    let result = make_core_body(
        delegate_method_executable(method), delegate_method_origin(method),
        delegate_body_type_count(body), delegate_body_manifest(body),
        delegate_body_slots(body), delegate_body_parameter_slots(body),
        delegate_body_result_type(body), block)
    validate_core_body(result)
    result
}

pub fn elaborate_delegate_to_core(
    plan: DelegateTypedPlan
) -> List<CoreBody> {
    let field = delegate_typed_plan_field(plan)
    let mut result: List<CoreBody> = []
    for method in delegate_typed_plan_methods(plan) {
        result.push(elaborate_delegate_method(field, method))
    }
    result
}
