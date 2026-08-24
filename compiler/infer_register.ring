use types::{Type, Effect, EffectRow, StructField, EnumVariant,
    EMPTY_ROW, effects_same_kind, type_to_builtin_name, type_to_string, effect_to_string, nominal_display_name,
    types_equal}
use ast::{Decl, Span, TypeParam, Param, TypeExpr, EffectOpDecl, StructFieldDecl,
    EnumVariantDecl, NamedEnumField, TypeBound, span_zero, EffectExpr,
    UseDecl, UseImport, DeriveAttribute}
use env::{TypeEnv, TypeScheme, SchemeBound, AssocConstraintEntry, StructDef, EnumDef, EffectDef, EffectOpDef,
    TraitDef, TraitMethodDef, ImplEntry, ImplMethodSchemeCore,
    RegisteredTraitMethodContract, RegisteredTraitAssocContract,
    make_registered_trait_method_contract,
    make_registered_trait_assoc_contract,
    make_registered_trait_contract,
    ExplicitDerivedProviderPlan, NominalDerivedProviderPlan,
    DelegateChildProviderPlan, DelegatePlanState,
    make_delegate_child_provider_plan,
    ImplAssocPredicate, TypedImplPredicate, FrozenImplPredicateSet,
    TypeAliasDef, FnBound,
    EffectAliasDef, AssocTypeDef, mono, apply_subst, apply_subst_effect_map,
    apply_subst_map, add_impl, has_impl, find_impl,
    find_impl_by_provider,
    find_impls_by_provider,
    install_method_core, replace_impl_method_core,
    make_impl_method_scheme_core, impl_method_core_as_scheme,
    make_impl_assoc_predicate, make_typed_impl_predicate,
    direct_impl_predicate_provenance, expanded_impl_predicate_provenance,
    freeze_impl_predicate_set, empty_frozen_impl_predicate_set,
    frozen_impl_predicates, impl_predicate_subject_param_index,
    impl_predicate_subject_type_var, impl_predicate_trait_name,
    impl_predicate_assoc_constraints, impl_assoc_predicate_name,
    impl_assoc_predicate_type, instantiate_impl_runtime_requirements,
    impl_target_symbol,
    specialize_trait_method_scheme, build_type_var_map,
    delegate_plan_not_applicable, delegate_plan_pending,
    delegate_plan_final,
    finalize_delegate_provider_plan, assert_no_pending_delegate_plans}
use diagnostics::{DiagnosticContext}
use codes::{E0207, E0406, E0501, E0502, E0503, E0504, E0505, E0506, E0507, E0508, E0509, E0510, E0511, E0513, E0514}
use hir::{compare_by_first, module_item_identity, variant_ctor_name, ValueBindingKind}
use infer_ctx::{InferCtx, FnBoundsEntry, CompileError, type_error, resolve_type_expr, resolve_self_type, resolve_effect_expr,
    record_value_origin, record_variant_ctor_origin, record_value_binding_kind,
    resolve_dict_ref_for_type, impl_predicate_constraints_satisfied,
    resolve_mod_uses, bind_exact_import_alias,
    enter_project_root_frame, enter_project_child_frame,
    refresh_project_namespace_frame, exit_project_namespace_frame,
    enter_struct_identity_root_frame, enter_struct_identity_child_frame,
    exit_struct_identity_frame, peek_struct_identity_fact,
    commit_struct_identity_fact, peek_struct_identity_completion,
    commit_struct_identity_completion,
    commit_complete_nominal_identity_fact,
    peek_enum_identity_group, commit_enum_identity_group,
    peek_effect_identity_fact, commit_effect_identity_fact,
    peek_trait_identity_fact, commit_trait_identity_fact,
    peek_source_impl_provider_fact, commit_source_impl_provider_fact,
    publish_impl_check_owner,
    peek_delegate_provider_fact, commit_delegate_provider_fact,
    peek_nominal_derived_provider_fact,
    commit_nominal_derived_provider_fact,
    close_struct_identity_ledger}
use infer_helpers::{is_value_type}
use resolver::{StructIdentityFact, DelegateProviderFact,
    ImplMethodIdentityFact}
use ir_identity::{make_registered_nominal_ref, make_registered_trait_ref,
    registered_nominal_ref_symbol, nominal_field_ref_name,
    nominal_field_ref_index, symbol_ref_same,
    trait_method_ref_trait,
    trait_method_ref_source_member_index,
    trait_method_ref_callable_slot_index, trait_method_ref_name,
    variant_ref_owner, variant_ref_source_index,
    variant_field_ref_variant, variant_field_ref_index,
    registered_nominal_ref_same, variant_ref_same,
    ImplProviderRef, SymbolRef, ImplOwnerRef, ImplMethodRef,
    HandledEffectRef, handled_effect_ref_same,
    make_impl_owner_ref, make_impl_method_ref,
    impl_provider_ref_site, path_ref_owner, path_ref_normalized_child_path,
    path_owner_ref_module_body, module_body_ref_origin_module_key,
    make_symbol_ref, namespace_member,
    impl_provider_ref_same,
    registered_trait_ref_symbol}

// ============================================================
// Public entry points
// ============================================================

pub fn register_decl_public(
    mut ctx: InferCtx, decl: Decl, decl_index: Int
) {
    register_decl(ctx, decl, decl_index)
}

pub fn insert_mod_aliases(mut ctx: InferCtx, mod_name: Str, decls: List<Decl>, guard: Bool) {
    for d in decls {
        match d {
            Decl::Struct { name, .. } => {
                let qualified = "${mod_name}::${name}"
                if !guard || !ctx.env.types.structs.contains_key(name) {
                    match ctx.env.types.structs.get(qualified) {
                        some(sdef) => { ctx.env.types.structs.insert(name, sdef) },
                        none => {}
                    }
                }
            },
            Decl::Enum { name, .. } => {
                let qualified = "${mod_name}::${name}"
                if !guard || !ctx.env.types.enums.contains_key(name) {
                    match ctx.env.types.enums.get(qualified) {
                        some(edef) => { ctx.env.types.enums.insert(name, edef) },
                        none => {}
                    }
                }
            },
            Decl::Trait { name, .. } => {
                let qualified = "${mod_name}::${name}"
                if !guard || !ctx.env.trait_reg.traits.contains_key(name) {
                    match ctx.env.trait_reg.traits.get(qualified) {
                        some(tdef) => { ctx.env.trait_reg.traits.insert(name, tdef) },
                        none => {}
                    }
                }
            },
            Decl::Effect { name, .. } => {
                let qualified = "${mod_name}::${name}"
                if !guard || !ctx.env.types.effects.contains_key(name) {
                    match ctx.env.types.effects.get(qualified) {
                        some(edef) => { ctx.env.types.effects.insert(name, edef) },
                        none => {}
                    }
                }
            },
            Decl::EffectAlias { name, .. } => {
                let qualified = "${mod_name}::${name}"
                if !guard || !ctx.env.types.effect_aliases.contains_key(name) {
                    match ctx.env.types.effect_aliases.get(qualified) {
                        some(adef) => { ctx.env.types.effect_aliases.insert(name, adef) },
                        none => {}
                    }
                }
            },
            Decl::TypeAlias { name, .. } => {
                let qualified = "${mod_name}::${name}"
                if !guard || !ctx.env.types.type_aliases.contains_key(name) {
                    match ctx.env.types.type_aliases.get(qualified) {
                        some(adef) => { ctx.env.types.type_aliases.insert(name, adef) },
                        none => {}
                    }
                }
            },
            Decl::ExternType { name, .. } => {
                let qualified = "${mod_name}::${name}"
                match ctx.env.types.structs.get(qualified) {
                    some(def) => {
                        if !guard || !ctx.env.types.structs.contains_key(name) {
                            ctx.env.types.structs.insert(name, def)
                        }
                    },
                    none => match ctx.env.types.structs.get(name) {
                        some(def) => {
                            // Extern types keep their raw ABI identity, while
                            // relative imports still need a qualified source key.
                            ctx.env.types.structs.insert(qualified, def)
                        },
                        none => {}
                    }
                }
            },
            _ => {}
        }
    }
}

pub fn prefix_decl_name(mod_name: Str, decl: Decl) -> Decl {
    match decl {
        Decl::Fn { name, type_params, params, return_type, declared_effects, body, is_pub, is_abstract, span } =>
            Decl::Fn { name: "${mod_name}::${name}", type_params: type_params, params: params,
                       return_type: return_type, declared_effects: declared_effects, body: body,
                       is_pub: is_pub, is_abstract: is_abstract, span: span },
        Decl::Struct { name, type_params, fields, derive_attrs, is_pub, span } =>
            Decl::Struct { name: "${mod_name}::${name}", type_params: type_params, fields: fields,
                          derive_attrs: derive_attrs, is_pub: is_pub, span: span },
        Decl::Enum { name, type_params, variants, derive_attrs, is_pub, span } =>
            Decl::Enum { name: "${mod_name}::${name}", type_params: type_params, variants: variants,
                        derive_attrs: derive_attrs, is_pub: is_pub, span: span },
        Decl::ExternFn { name, type_params, params, return_type, declared_effects, is_pub, span } =>
            Decl::ExternFn { name: "${mod_name}::${name}", type_params: type_params, params: params,
                            return_type: return_type, declared_effects: declared_effects,
                            is_pub: is_pub, span: span },
        Decl::Const { name, type_annotation, init, is_pub, span } =>
            Decl::Const { name: "${mod_name}::${name}", type_annotation: type_annotation, init: init,
                         is_pub: is_pub, span: span },
        Decl::Impl { target_type, type_params, trait_name, methods, span } => {
            let prefixed_target = if target_type.contains("::") {
                target_type
            } else {
                "${mod_name}::${target_type}"
            }
            Decl::Impl { target_type: prefixed_target, type_params: type_params,
                         trait_name: trait_name, methods: methods, span: span }
        },
        Decl::Trait { name, type_params, supertraits, methods, is_pub, span } =>
            Decl::Trait { name: "${mod_name}::${name}", type_params: type_params, supertraits: supertraits,
                         methods: methods, is_pub: is_pub, span: span },
        Decl::Effect { name, type_params, ops, is_pub, span } =>
            Decl::Effect { name: "${mod_name}::${name}", type_params: type_params, ops: ops,
                          is_pub: is_pub, span: span },
        Decl::ExternType { name, type_params, is_pub, span } =>
            Decl::ExternType { name: "${mod_name}::${name}", type_params: type_params,
                              is_pub: is_pub, span: span },
        Decl::TypeAlias { name, type_params, type_expr, is_pub, span } =>
            Decl::TypeAlias { name: "${mod_name}::${name}", type_params: type_params, type_expr: type_expr,
                             is_pub: is_pub, span: span },
        Decl::EffectAlias { name, type_params, effects, is_pub, span } =>
            Decl::EffectAlias { name: "${mod_name}::${name}", type_params: type_params, effects: effects,
                               is_pub: is_pub, span: span },
        Decl::ModBlock { name, uses, decls, required_effects, is_pub, span } =>
            Decl::ModBlock { name: "${mod_name}::${name}", uses: uses, decls: decls,
                            required_effects: required_effects, is_pub: is_pub, span: span },
        Decl::AssocType { .. } => decl,  // Associated types are nested inside trait/impl, not prefixed
        _ => decl
    }
}

// Qualify a file-module's top-level declaration with its canonical identity.
// Unlike prefix_decl_name (inline `mod` scoping), this preserves the resolver's
// module boundary and cannot collide after backend identifier sanitization.
pub fn module_prefix_decl_name(module_prefix: Str, decl: Decl) -> Decl {
    match decl {
        Decl::Fn { name, type_params, params, return_type, declared_effects, body, is_pub, is_abstract, span } =>
            Decl::Fn { name: module_item_identity(module_prefix, name), type_params: type_params, params: params,
                       return_type: return_type, declared_effects: declared_effects, body: body,
                       is_pub: is_pub, is_abstract: is_abstract, span: span },
        Decl::Struct { name, type_params, fields, derive_attrs, is_pub, span } =>
            Decl::Struct { name: module_item_identity(module_prefix, name), type_params: type_params, fields: fields,
                          derive_attrs: derive_attrs, is_pub: is_pub, span: span },
        Decl::Enum { name, type_params, variants, derive_attrs, is_pub, span } =>
            Decl::Enum { name: module_item_identity(module_prefix, name), type_params: type_params, variants: variants,
                        derive_attrs: derive_attrs, is_pub: is_pub, span: span },
        Decl::ExternFn { name, type_params, params, return_type, declared_effects, is_pub, span } =>
            // The declaration participates in the same exact module identity
            // scheme as Ring functions. HIR stores its foreign ABI leaf
            // separately, so aliases/re-exports never collapse back to `name`.
            Decl::ExternFn { name: module_item_identity(module_prefix, name),
                            type_params: type_params, params: params,
                            return_type: return_type, declared_effects: declared_effects,
                            is_pub: is_pub, span: span },
        Decl::Const { name, type_annotation, init, is_pub, span } =>
            Decl::Const { name: module_item_identity(module_prefix, name), type_annotation: type_annotation, init: init,
                         is_pub: is_pub, span: span },
        Decl::Impl { target_type, type_params, trait_name, methods, span } => {
            // Keep the source spelling until registration.  At that point all
            // local/imported aliases are installed, so the target can be
            // resolved to the definition's exact nominal identity.
            Decl::Impl { target_type: target_type, type_params: type_params,
                         trait_name: trait_name, methods: methods, span: span }
        },
        Decl::Trait { name, type_params, supertraits, methods, is_pub, span } =>
            Decl::Trait { name: module_item_identity(module_prefix, name), type_params: type_params, supertraits: supertraits,
                         methods: methods, is_pub: is_pub, span: span },
        Decl::Effect { name, type_params, ops, is_pub, span } =>
            Decl::Effect { name: module_item_identity(module_prefix, name), type_params: type_params, ops: ops,
                          is_pub: is_pub, span: span },
        Decl::ExternType { name, type_params, is_pub, span } =>
            // Extern types denote foreign ABI identities shared across modules
            // (for example LLVMBuilderRef). Keep their declared ABI spelling.
            Decl::ExternType { name: name, type_params: type_params,
                              is_pub: is_pub, span: span },
        Decl::TypeAlias { name, type_params, type_expr, is_pub, span } =>
            Decl::TypeAlias { name: module_item_identity(module_prefix, name), type_params: type_params, type_expr: type_expr,
                             is_pub: is_pub, span: span },
        Decl::EffectAlias { name, type_params, effects, is_pub, span } =>
            Decl::EffectAlias { name: module_item_identity(module_prefix, name), type_params: type_params, effects: effects,
                               is_pub: is_pub, span: span },
        Decl::ModBlock { name, uses, decls, required_effects, is_pub, span } =>
            Decl::ModBlock { name: module_item_identity(module_prefix, name), uses: uses, decls: decls,
                            required_effects: required_effects, is_pub: is_pub, span: span },
        Decl::AssocType { .. } => decl,
        _ => decl
    }
}

// Shared 5-pass ModBlock registration strategy.
// When deferred_struct_names/deferred_enum_names are provided (some), operates in phase1 mode
// (preregister struct/enum only, defer field/variant completion).
// When none, operates in register_decl mode (complete struct/enum immediately).
fn inline_mod_leaf(name: Str) -> Str {
    let inline_parts = name.split("::")
    let inline_leaf = inline_parts.get(inline_parts.len() - 1).unwrap_or(name)
    let file_parts = inline_leaf.split("$$_")
    file_parts.get(file_parts.len() - 1).unwrap_or(inline_leaf)
}

struct IndexedDecl {
    decl_index: Int,
    decl: Decl
}

// Project registration walks the exact resolver frame tree once per disjoint
// declaration phase.  The barriers make every type namespace available before
// any value signature is registered without retrying or re-registering a decl.
enum ProjectRegistrationPhase {
    NominalPhase,
    TraitPhase,
    EffectPhase,
    EffectAliasPhase,
    ExternTypePhase,
    TypeAliasPhase,
    ValuePhase,
}

fn project_decl_matches_phase(
    decl: Decl, phase: ProjectRegistrationPhase
) -> Bool {
    match phase {
        ProjectRegistrationPhase::NominalPhase => match decl {
            Decl::Struct { .. } | Decl::Enum { .. } => true,
            _ => false
        },
        ProjectRegistrationPhase::TraitPhase => match decl {
            Decl::Trait { .. } => true,
            _ => false
        },
        ProjectRegistrationPhase::EffectPhase => match decl {
            Decl::Effect { .. } => true,
            _ => false
        },
        ProjectRegistrationPhase::EffectAliasPhase => match decl {
            Decl::EffectAlias { .. } => true,
            _ => false
        },
        ProjectRegistrationPhase::ExternTypePhase => match decl {
            Decl::ExternType { .. } => true,
            _ => false
        },
        ProjectRegistrationPhase::TypeAliasPhase => match decl {
            Decl::TypeAlias { .. } => true,
            _ => false
        },
        ProjectRegistrationPhase::ValuePhase => match decl {
            Decl::Struct { .. } | Decl::Enum { .. } |
            Decl::Trait { .. } | Decl::Effect { .. } |
            Decl::EffectAlias { .. } | Decl::ExternType { .. } |
            Decl::TypeAlias { .. } |
            Decl::ModBlock { .. } => false,
            _ => true
        }
    }
}

fn index_decls(decls: List<Decl>) -> List<IndexedDecl> {
    let mut indexed: List<IndexedDecl> = []
    for decl_index in 0..decls.len() {
        match decls.get(decl_index) {
            some(decl) => indexed.push(IndexedDecl {
                decl_index: decl_index,
                decl: decl
            }),
            none => {}
        }
    }
    indexed
}

// Source order must not decide whether `mod facade { use super::origin... }`
// can see a sibling. Order sibling ModBlocks by their direct super::module
// dependencies; cycles retain source order and are diagnosed during checking.
fn order_inline_mod_blocks(decls: List<Decl>) -> List<Decl> {
    let mut pending: List<Decl> = []
    let mut sibling_names: Set<Str> = set_new()
    for decl in decls {
        match decl {
            Decl::ModBlock { name, .. } => {
                pending.push(decl)
                sibling_names.insert(inline_mod_leaf(name))
            },
            _ => {}
        }
    }

    let mut ordered: List<Decl> = []
    let mut completed: Set<Str> = set_new()
    while pending.len() > 0 {
        let mut next: List<Decl> = []
        let mut progressed = false
        for decl in pending {
            let mut ready = true
            match decl {
                Decl::ModBlock { uses, .. } => {
                    for use_decl in uses {
                        let parts = use_decl.path.segments
                        if parts.len() > 1 && parts.get(0).unwrap_or("") == "super" &&
                           parts.get(1).unwrap_or("") != "super" {
                            let dep = parts.get(1).unwrap_or("")
                            if sibling_names.contains(dep) && !completed.contains(dep) {
                                ready = false
                            }
                        }
                    }
                },
                _ => {}
            }
            if ready {
                match decl {
                    Decl::ModBlock { name, .. } => { completed.insert(inline_mod_leaf(name)) },
                    _ => {}
                }
                ordered.push(decl)
                progressed = true
            } else {
                next.push(decl)
            }
        }
        if !progressed {
            for decl in next { ordered.push(decl) }
            next = []
        }
        pending = next
    }
    ordered
}

// Project registration may reorder sibling modules for dependency readiness,
// but the resolver-frame adapter must retain each module's original AST site.
fn order_indexed_inline_mod_blocks(
    decls: List<IndexedDecl>
) -> List<IndexedDecl> {
    let mut pending: List<IndexedDecl> = []
    let mut sibling_names: Set<Str> = set_new()
    for item in decls {
        match item.decl {
            Decl::ModBlock { name, .. } => {
                pending.push(item)
                sibling_names.insert(inline_mod_leaf(name))
            },
            _ => {}
        }
    }

    let mut ordered: List<IndexedDecl> = []
    let mut completed: Set<Str> = set_new()
    while pending.len() > 0 {
        let mut next: List<IndexedDecl> = []
        let mut progressed = false
        for item in pending {
            let mut ready = true
            match item.decl {
                Decl::ModBlock { uses, .. } => {
                    for use_decl in uses {
                        let parts = use_decl.path.segments
                        if parts.len() > 1 &&
                           parts.get(0).unwrap_or("") == "super" &&
                           parts.get(1).unwrap_or("") != "super" {
                            let dep = parts.get(1).unwrap_or("")
                            if sibling_names.contains(dep) &&
                               !completed.contains(dep) {
                                ready = false
                            }
                        }
                    }
                },
                _ => {}
            }
            if ready {
                match item.decl {
                    Decl::ModBlock { name, .. } => {
                        completed.insert(inline_mod_leaf(name))
                    },
                    _ => {}
                }
                ordered.push(item)
                progressed = true
            } else {
                next.push(item)
            }
        }
        if !progressed {
            for item in next { ordered.push(item) }
            next = []
        }
        pending = next
    }
    ordered
}

fn register_mod_block_items_legacy(
    mut ctx: InferCtx, mod_name: Str, mod_uses: List<UseDecl>, mod_decls: List<Decl>,
    deferred_struct_names: List<Str>?, deferred_enum_names: List<Str>?
) {
    // Imports are lexically visible to every declaration in the inline module,
    // including signatures registered before bodies are checked. Keep the
    // registration path stack identical to check_mod_decl so self/super paths
    // resolve to the same canonical identities in both phases.
    let segments = mod_name.split("::")
    let simple_name = segments.get(segments.len() - 1).unwrap_or(mod_name)
    ctx.mod_path_stack.push(simple_name)
    resolve_mod_uses(ctx, mod_uses, false)
    let indexed = index_decls(mod_decls)

    // Pass 1a: register struct/enum types first
    for item in indexed {
        match item.decl {
            Decl::Struct { .. } => {
                let prefixed = prefix_decl_name(mod_name, item.decl)
                register_mod_item(ctx, prefixed, item.decl_index,
                    deferred_struct_names, deferred_enum_names)
            },
            Decl::Enum { .. } => {
                let prefixed = prefix_decl_name(mod_name, item.decl)
                register_mod_item(ctx, prefixed, item.decl_index,
                    deferred_struct_names, deferred_enum_names)
            },
            _ => {}
        }
    }
    // Incremental aliases: struct/enum short names available for trait bounds
    insert_mod_aliases(ctx, mod_name, mod_decls, true)
    // Pass 1b-1: traits -- alias after each so supertraits resolve by short name (#83)
    for item in indexed {
        match item.decl {
            Decl::Trait { .. } => {
                let prefixed = prefix_decl_name(mod_name, item.decl)
                register_mod_item(ctx, prefixed, item.decl_index,
                    deferred_struct_names, deferred_enum_names)
                // Incremental alias: makes this trait's short name available
                // for subsequent traits' supertrait lookup (#83)
                insert_mod_aliases(ctx, mod_name, mod_decls, true)
            },
            _ => {}
        }
    }
    // Pass 1b-2: effects must exist under their short names before effect
    // alias bodies are canonicalized. Otherwise `{Signal}` is stored raw and
    // can later rebind to a consumer's same-spelled effect.
    for item in indexed {
        match item.decl {
            Decl::Effect { .. } => {
                let prefixed = prefix_decl_name(mod_name, item.decl)
                register_mod_item(ctx, prefixed, item.decl_index,
                    deferred_struct_names, deferred_enum_names)
            },
            _ => {}
        }
    }
    insert_mod_aliases(ctx, mod_name, mod_decls, true)
    // Pass 1b-3: effect aliases remain source ordered so an earlier alias may
    // feed a later alias, but every body sees all concrete effects above.
    for item in indexed {
        match item.decl {
            Decl::EffectAlias { .. } => {
                let prefixed = prefix_decl_name(mod_name, item.decl)
                register_mod_item(ctx, prefixed, item.decl_index,
                    deferred_struct_names, deferred_enum_names)
                insert_mod_aliases(ctx, mod_name, mod_decls, true)
            },
            _ => {}
        }
    }
    // Pass 1b-4: opaque extern types.
    for item in indexed {
        match item.decl {
            Decl::ExternType { .. } => {
                let prefixed = prefix_decl_name(mod_name, item.decl)
                register_mod_item(ctx, prefixed, item.decl_index,
                    deferred_struct_names, deferred_enum_names)
            },
            _ => {}
        }
    }
    // Pass 1b-5: aliases must exist before any value declaration
    // resolves its parameter/return types. Refresh short aliases after each
    // declaration so source-ordered alias chains can feed the next alias;
    // functions remain declaration-order independent from all aliases.
    for item in indexed {
        match item.decl {
            Decl::TypeAlias { .. } => {
                let prefixed = prefix_decl_name(mod_name, item.decl)
                register_mod_item(ctx, prefixed, item.decl_index,
                    deferred_struct_names, deferred_enum_names)
                insert_mod_aliases(ctx, mod_name, mod_decls, true)
            },
            _ => {}
        }
    }
    // Final aliases: all names available for remaining declarations
    insert_mod_aliases(ctx, mod_name, mod_decls, true)
    // Pass 2: register everything else (functions, impls, consts, etc.)
    for item in indexed {
        match item.decl {
            Decl::Struct { .. } => {},
            Decl::Enum { .. } => {},
            Decl::Trait { .. } => {},
            Decl::Effect { .. } => {},
            Decl::EffectAlias { .. } => {},
            Decl::ExternType { .. } => {},
            Decl::TypeAlias { .. } => {},
            Decl::ModBlock { .. } => {},
            _ => {
                let prefixed = prefix_decl_name(mod_name, item.decl)
                register_mod_item(ctx, prefixed, item.decl_index,
                    deferred_struct_names, deferred_enum_names)
            }
        }
    }
    for item in order_indexed_inline_mod_blocks(indexed) {
        let prefixed = prefix_decl_name(mod_name, item.decl)
        register_mod_item(ctx, prefixed, item.decl_index,
            deferred_struct_names, deferred_enum_names)
    }
    let _ = ctx.mod_path_stack.pop()
}

fn register_project_mod_local_item(
    mut ctx: InferCtx, mod_name: Str, item: IndexedDecl,
    deferred_struct_names: List<Str>, deferred_enum_names: List<Str>
) {
    match item.decl {
        // Extern types are foreign ABI identities, not inline-module
        // nominals.  The project plan owns every visible spelling; retain only
        // the raw source definition here so frame refresh can install and
        // later remove the exact leaf/display alias.
        Decl::ExternType { name, type_params, span, .. } => {
            register_project_extern_type(
                ctx, name, type_params, span, item.decl_index)
        },
        Decl::ModBlock { .. } =>
            panic("unreachable: project ModBlock reached local phase dispatcher"),
        _ => {
            let prefixed = prefix_decl_name(mod_name, item.decl)
            register_phase1(
                ctx, prefixed, deferred_struct_names, deferred_enum_names,
                item.decl_index)
        }
    }
    refresh_project_namespace_frame(ctx)
}

// Project inline registration is driven exclusively by the installed plan.
// The child frame is recovered from its exact parent/decl site, and every
// phase keeps the original decl_index even when sibling ModBlocks are
// dependency-reordered. ModBlocks recurse here and never reach the legacy
// monolithic registration helper.
fn register_project_mod_block_phase(
    mut ctx: InferCtx, mod_name: Str, mod_decls: List<Decl>,
    deferred_struct_names: List<Str>, deferred_enum_names: List<Str>,
    decl_index: Int, phase: ProjectRegistrationPhase
) {
    if !enter_project_child_frame(ctx, decl_index) {
        panic("unreachable: resolver plan missing inline registration frame")
    }
    enter_struct_identity_child_frame(ctx, decl_index)
    project_push_mod_path(ctx, mod_name)
    let indexed = index_decls(mod_decls)

    for item in indexed {
        if project_decl_matches_phase(item.decl, phase) {
            register_project_mod_local_item(
                ctx, mod_name, item,
                deferred_struct_names, deferred_enum_names)
        }
    }

    for item in order_indexed_inline_mod_blocks(indexed) {
        let canonical_decl = prefix_decl_name(mod_name, item.decl)
        match canonical_decl {
            Decl::ModBlock {
                name: nested_name, decls: nested_decls, ..
            } => {
                register_project_mod_block_phase(
                    ctx, nested_name, nested_decls,
                    deferred_struct_names, deferred_enum_names,
                    item.decl_index, phase)
                refresh_project_namespace_frame(ctx)
            },
            _ => panic("unreachable: ordered project child is not a ModBlock")
        }
    }

    let _ = ctx.mod_path_stack.pop()
    exit_struct_identity_frame(ctx)
    let _ = exit_project_namespace_frame(ctx)
}

fn register_mod_block_items(
    mut ctx: InferCtx, mod_name: Str, mod_uses: List<UseDecl>,
    mod_decls: List<Decl>,
    deferred_struct_names: List<Str>?, deferred_enum_names: List<Str>?
) {
    // This entry point is retained only for the single-file legacy pipeline.
    // Project callers use the phase-aware exact-frame traversal above.
    register_mod_block_items_legacy(
        ctx, mod_name, mod_uses, mod_decls,
        deferred_struct_names, deferred_enum_names)
}

// Dispatch a single declaration to the appropriate registration function.
// When deferred lists are provided, operates in phase1 mode; otherwise in register_decl mode.
fn register_mod_item(
    mut ctx: InferCtx, decl: Decl, decl_index: Int,
    deferred_struct_names: List<Str>?, deferred_enum_names: List<Str>?
) {
    match deferred_struct_names {
        some(dsn) => match deferred_enum_names {
            some(den) => register_phase1(ctx, decl, dsn, den, decl_index),
            none => register_decl(ctx, decl, decl_index)
        },
        none => register_decl(ctx, decl, decl_index)
    }
}

fn register_phase1(
    mut ctx: InferCtx, decl: Decl,
    mut deferred_struct_names: List<Str>,
    mut deferred_enum_names: List<Str>, decl_index: Int
) {
    match decl {
        Decl::Struct { name, type_params, fields, derive_attrs, span, .. } => {
            preregister_struct(
                ctx, name, type_params, derive_attrs,
                span, decl_index, fields.len())
            deferred_struct_names.push(name)
        },
        Decl::Enum { name, type_params, variants, derive_attrs, span, .. } => {
            preregister_enum(
                ctx, name, type_params, variants,
                derive_attrs, span, decl_index)
            deferred_enum_names.push(name)
        },
        Decl::ModBlock { name: mod_name, uses: mod_uses, decls: mod_decls, .. } => {
            enter_struct_identity_child_frame(ctx, decl_index)
            register_mod_block_items(ctx, mod_name, mod_uses, mod_decls, some(deferred_struct_names), some(deferred_enum_names))
            exit_struct_identity_frame(ctx)
        },
        _ => register_decl(ctx, decl, decl_index)
    }
}

fn register_phase2_struct(mut ctx: InferCtx, decl: Decl) {
    match decl {
        Decl::Struct { name, type_params, fields, span, .. } =>
            complete_struct_fields(ctx, name, fields),
        Decl::ModBlock { name: mod_name, decls: mod_decls, .. } => {
            for d in mod_decls {
                let prefixed = prefix_decl_name(mod_name, d)
                register_phase2_struct(ctx, prefixed)
            }
        },
        _ => {}
    }
}

fn register_phase2_enum(mut ctx: InferCtx, decl: Decl) {
    match decl {
        Decl::Enum { name, type_params, variants, span, .. } =>
            complete_enum_variants(ctx, name, type_params, variants),
        Decl::ModBlock { name: mod_name, decls: mod_decls, .. } => {
            for d in mod_decls {
                let prefixed = prefix_decl_name(mod_name, d)
                register_phase2_enum(ctx, prefixed)
            }
        },
        _ => {}
    }
}

pub fn register_decls_two_phase(mut ctx: InferCtx, decls: List<Decl>) {
    enter_struct_identity_root_frame(ctx)
    ctx.file_extern_types = set_new()
    for decl in decls {
        match decl {
            Decl::ExternType { name, .. } => { ctx.file_extern_types.insert(name) },
            _ => {}
        }
    }
    let mut deferred_struct_names: List<Str> = []
    let mut deferred_enum_names: List<Str> = []

    for item in index_decls(decls) {
        let result = some(register_phase1(
            ctx, item.decl, deferred_struct_names,
            deferred_enum_names, item.decl_index)) catch { _ => none }
    }

    for decl in decls {
        let result = some(register_phase2_struct(ctx, decl)) catch { _ => none }
    }
    for decl in decls {
        let result = some(register_phase2_enum(ctx, decl)) catch { _ => none }
    }

    // Phase 3: process delegates (after struct/enum fields are complete)
    for item in index_decls(decls) {
        register_nonproject_phase3_delegate(ctx, item)
    }
    exit_struct_identity_frame(ctx)
    assert_no_pending_delegate_plans(ctx.env.trait_reg)
    close_struct_identity_ledger(ctx)
}

// Register a resolver file-module under canonical declaration identities while
// retaining source-level short aliases in this module's checker environment.
// Imported canonical definitions may coexist; aliases are deliberately local.
fn register_project_root_local_item(
    mut ctx: InferCtx, item: IndexedDecl,
    deferred_struct_names: List<Str>,
    deferred_enum_names: List<Str>
) {
    match item.decl {
        // module_prefix_decl_name deliberately preserves the raw ABI spelling.
        // Do not route project externs through the legacy visible registry:
        // the root frame installs that spelling transactionally.
        Decl::ExternType { name, type_params, span, .. } =>
            register_project_extern_type(
                ctx, name, type_params, span, item.decl_index),
        Decl::ModBlock { .. } =>
            panic("unreachable: project ModBlock reached root local dispatcher"),
        _ => register_phase1(
            ctx, item.decl,
            deferred_struct_names, deferred_enum_names,
            item.decl_index)
    }
    refresh_project_namespace_frame(ctx)
}

fn register_project_root_phase(
    mut ctx: InferCtx, qualified: List<IndexedDecl>,
    deferred_struct_names: List<Str>,
    deferred_enum_names: List<Str>,
    phase: ProjectRegistrationPhase
) {
    for item in qualified {
        if project_decl_matches_phase(item.decl, phase) {
            register_project_root_local_item(
                ctx, item, deferred_struct_names, deferred_enum_names)
        }
    }
    for item in order_indexed_inline_mod_blocks(qualified) {
        match item.decl {
            Decl::ModBlock { name, decls, .. } => {
                register_project_mod_block_phase(
                    ctx, name, decls,
                    deferred_struct_names, deferred_enum_names,
                    item.decl_index, phase)
                refresh_project_namespace_frame(ctx)
            },
            _ => panic("unreachable: ordered project root child is not a ModBlock")
        }
    }
}

fn project_push_mod_path(mut ctx: InferCtx, mod_name: Str) {
    let segments = mod_name.split("::")
    let simple_name = segments.get(segments.len() - 1).unwrap_or(mod_name)
    ctx.mod_path_stack.push(simple_name)
}

fn register_project_phase2_struct(
    mut ctx: InferCtx, item: IndexedDecl
) {
    match item.decl {
        Decl::ModBlock { name, decls, .. } => {
            if !enter_project_child_frame(ctx, item.decl_index) {
                panic("unreachable: resolver plan missing phase2 struct frame")
            }
            project_push_mod_path(ctx, name)
            for child in index_decls(decls) {
                let qualified_child = IndexedDecl {
                    decl_index: child.decl_index,
                    decl: prefix_decl_name(name, child.decl)
                }
                register_project_phase2_struct(ctx, qualified_child)
            }
            let _ = ctx.mod_path_stack.pop()
            let _ = exit_project_namespace_frame(ctx)
        },
        _ => {
            register_phase2_struct(ctx, item.decl)
            refresh_project_namespace_frame(ctx)
        }
    }
}

fn register_project_phase2_enum(
    mut ctx: InferCtx, item: IndexedDecl
) {
    match item.decl {
        Decl::ModBlock { name, decls, .. } => {
            if !enter_project_child_frame(ctx, item.decl_index) {
                panic("unreachable: resolver plan missing phase2 enum frame")
            }
            project_push_mod_path(ctx, name)
            for child in index_decls(decls) {
                let qualified_child = IndexedDecl {
                    decl_index: child.decl_index,
                    decl: prefix_decl_name(name, child.decl)
                }
                register_project_phase2_enum(ctx, qualified_child)
            }
            let _ = ctx.mod_path_stack.pop()
            let _ = exit_project_namespace_frame(ctx)
        },
        _ => {
            register_phase2_enum(ctx, item.decl)
            // Enum completion creates canonical constructor schemes; refresh
            // the current exact frame before any later signature/delegate pass.
            refresh_project_namespace_frame(ctx)
        }
    }
}

fn register_project_phase3_delegate(
    mut ctx: InferCtx, item: IndexedDecl
) {
    match item.decl {
        Decl::ModBlock { name, decls, .. } => {
            if !enter_project_child_frame(ctx, item.decl_index) {
                panic("unreachable: resolver plan missing phase3 delegate frame")
            }
            enter_struct_identity_child_frame(ctx, item.decl_index)
            project_push_mod_path(ctx, name)
            for child in index_decls(decls) {
                let qualified_child = IndexedDecl {
                    decl_index: child.decl_index,
                    decl: prefix_decl_name(name, child.decl)
                }
                register_project_phase3_delegate(ctx, qualified_child)
            }
            let _ = ctx.mod_path_stack.pop()
            exit_struct_identity_frame(ctx)
            let _ = exit_project_namespace_frame(ctx)
        },
        _ => {
            register_phase3_delegate(ctx, item.decl, item.decl_index)
            refresh_project_namespace_frame(ctx)
        }
    }
}

fn register_project_module_decls_two_phase(
    mut ctx: InferCtx, module_prefix: Str, decls: List<Decl>
) -> List<Decl> {
    ctx.file_extern_types = set_new()
    for decl in decls {
        match decl {
            Decl::ExternType { name, .. } => {
                ctx.file_extern_types.insert(name)
            },
            _ => {}
        }
    }

    let mut qualified: List<IndexedDecl> = []
    for item in index_decls(decls) {
        qualified.push(IndexedDecl {
            decl_index: item.decl_index,
            decl: module_prefix_decl_name(module_prefix, item.decl)
        })
    }
    if !enter_project_root_frame(ctx) {
        panic("unreachable: resolver plan missing file root registration frame")
    }
    enter_struct_identity_root_frame(ctx)

    let mut deferred_struct_names: List<Str> = []
    let mut deferred_enum_names: List<Str> = []

    register_project_root_phase(
        ctx, qualified, deferred_struct_names, deferred_enum_names,
        ProjectRegistrationPhase::NominalPhase)
    register_project_root_phase(
        ctx, qualified, deferred_struct_names, deferred_enum_names,
        ProjectRegistrationPhase::TraitPhase)
    register_project_root_phase(
        ctx, qualified, deferred_struct_names, deferred_enum_names,
        ProjectRegistrationPhase::EffectPhase)
    register_project_root_phase(
        ctx, qualified, deferred_struct_names, deferred_enum_names,
        ProjectRegistrationPhase::EffectAliasPhase)
    register_project_root_phase(
        ctx, qualified, deferred_struct_names, deferred_enum_names,
        ProjectRegistrationPhase::ExternTypePhase)
    register_project_root_phase(
        ctx, qualified, deferred_struct_names, deferred_enum_names,
        ProjectRegistrationPhase::TypeAliasPhase)
    register_project_root_phase(
        ctx, qualified, deferred_struct_names, deferred_enum_names,
        ProjectRegistrationPhase::ValuePhase)

    for item in qualified {
        register_project_phase2_struct(ctx, item)
    }
    for item in qualified {
        register_project_phase2_enum(ctx, item)
    }
    for item in qualified {
        register_project_phase3_delegate(ctx, item)
    }
    refresh_project_namespace_frame(ctx)
    exit_struct_identity_frame(ctx)
    let _ = exit_project_namespace_frame(ctx)
    assert_no_pending_delegate_plans(ctx.env.trait_reg)
    close_struct_identity_ledger(ctx)

    let mut result: List<Decl> = []
    for item in qualified { result.push(item.decl) }
    result
}

pub fn register_module_decls_two_phase(mut ctx: InferCtx, module_prefix: Str, decls: List<Decl>) -> List<Decl> {
    if ctx.project_namespace_file_key.is_some() {
        return register_project_module_decls_two_phase(
            ctx, module_prefix, decls)
    }
    ctx.file_extern_types = set_new()
    for decl in decls {
        match decl {
            Decl::ExternType { name, .. } => { ctx.file_extern_types.insert(name) },
            _ => {}
        }
    }
    let mut qualified: List<IndexedDecl> = []
    for item in index_decls(decls) {
        qualified.push(IndexedDecl {
            decl_index: item.decl_index,
            decl: module_prefix_decl_name(module_prefix, item.decl)
        })
    }
    enter_struct_identity_root_frame(ctx)

    let mut deferred_struct_names: List<Str> = []
    let mut deferred_enum_names: List<Str> = []

    // Nominal declarations must all exist before any field/payload/signature is
    // resolved.  Their alias keys are display names; StructDef/EnumDef.name is
    // already canonical and therefore drives unification and backend metadata.
    for item in qualified {
        match item.decl {
            Decl::Struct { .. } => register_phase1(ctx, item.decl, deferred_struct_names, deferred_enum_names, item.decl_index),
            Decl::Enum { .. } => register_phase1(ctx, item.decl, deferred_struct_names, deferred_enum_names, item.decl_index),
            _ => {}
        }
    }
    insert_file_module_aliases(ctx, module_prefix, decls, false)

    // Match inline-module registration ordering: traits first, then effects and
    // opaque/type declarations, then values and impls.
    for item in qualified {
        match item.decl {
            Decl::Trait { .. } => {
                register_phase1(ctx, item.decl, deferred_struct_names, deferred_enum_names, item.decl_index)
                insert_file_module_aliases(ctx, module_prefix, decls, false)
            },
            _ => {}
        }
    }
    // Install all concrete effects before canonicalizing any effect-alias body.
    // The alias body must capture this module's exact effect identity rather
    // than retain a raw leaf that a downstream decoy can rebind.
    for item in qualified {
        match item.decl {
            Decl::Effect { .. } => register_phase1(ctx, item.decl, deferred_struct_names, deferred_enum_names, item.decl_index),
            _ => {}
        }
    }
    insert_file_module_aliases(ctx, module_prefix, decls, false)
    for item in qualified {
        match item.decl {
            Decl::EffectAlias { .. } => {
                register_phase1(ctx, item.decl, deferred_struct_names, deferred_enum_names, item.decl_index)
                insert_file_module_aliases(ctx, module_prefix, decls, false)
            },
            _ => {}
        }
    }
    for item in qualified {
        match item.decl {
            Decl::ExternType { .. } => register_phase1(ctx, item.decl, deferred_struct_names, deferred_enum_names, item.decl_index),
            Decl::TypeAlias { .. } => register_phase1(ctx, item.decl, deferred_struct_names, deferred_enum_names, item.decl_index),
            _ => {}
        }
    }
    insert_file_module_aliases(ctx, module_prefix, decls, false)
    for item in qualified {
        match item.decl {
            Decl::Struct { .. } => {}, Decl::Enum { .. } => {}, Decl::Trait { .. } => {},
            Decl::Effect { .. } => {}, Decl::EffectAlias { .. } => {},
            Decl::ExternType { .. } => {}, Decl::TypeAlias { .. } => {},
            Decl::ModBlock { .. } => {},
            _ => register_phase1(ctx, item.decl, deferred_struct_names, deferred_enum_names, item.decl_index)
        }
    }
    for item in order_indexed_inline_mod_blocks(qualified) {
        register_phase1(ctx, item.decl, deferred_struct_names, deferred_enum_names, item.decl_index)
    }

    for item in qualified { register_phase2_struct(ctx, item.decl) }
    for item in qualified { register_phase2_enum(ctx, item.decl) }
    for item in qualified { register_nonproject_phase3_delegate(ctx, item) }

    // Value schemes exist only after the final registration pass.  Binding the
    // short alias and recording its canonical origin makes HExpr::Ident exact.
    insert_file_module_aliases(ctx, module_prefix, decls, true)
    exit_struct_identity_frame(ctx)
    assert_no_pending_delegate_plans(ctx.env.trait_reg)
    close_struct_identity_ledger(ctx)
    let mut result: List<Decl> = []
    for item in qualified { result.push(item.decl) }
    result
}

fn insert_file_module_aliases(mut ctx: InferCtx, module_prefix: Str, decls: List<Decl>, include_values: Bool) {
    for decl in decls {
        match decl {
            Decl::Struct { name, .. } => {
                let canonical = module_item_identity(module_prefix, name)
                match ctx.env.types.structs.get(canonical) {
                    some(def) => { ctx.env.types.structs.insert(name, def) }, none => {}
                }
            },
            Decl::Enum { name, .. } => {
                let canonical = module_item_identity(module_prefix, name)
                match ctx.env.types.enums.get(canonical) {
                    some(def) => { ctx.env.types.enums.insert(name, def) }, none => {}
                }
            },
            Decl::Trait { name, .. } => {
                let canonical = module_item_identity(module_prefix, name)
                match ctx.env.trait_reg.traits.get(canonical) {
                    some(def) => { ctx.env.trait_reg.traits.insert(name, def) }, none => {}
                }
            },
            Decl::Effect { name, .. } => {
                let canonical = module_item_identity(module_prefix, name)
                match ctx.env.types.effects.get(canonical) {
                    some(def) => { ctx.env.types.effects.insert(name, def) }, none => {}
                }
            },
            Decl::EffectAlias { name, .. } => {
                let canonical = module_item_identity(module_prefix, name)
                match ctx.env.types.effect_aliases.get(canonical) {
                    some(def) => { ctx.env.types.effect_aliases.insert(name, def) }, none => {}
                }
            },
            Decl::ExternType { name, .. } => {
                match ctx.env.types.extern_structs.get(name) {
                    some(def) => { ctx.env.types.structs.insert(name, def) }, none => {}
                }
            },
            Decl::TypeAlias { name, .. } => {
                let canonical = module_item_identity(module_prefix, name)
                match ctx.env.types.type_aliases.get(canonical) {
                    some(def) => { ctx.env.types.type_aliases.insert(name, def) }, none => {}
                }
            },
            Decl::Fn { name, .. } => {
                if include_values {
                    let canonical = module_item_identity(module_prefix, name)
                    let _ = bind_exact_import_alias(
                        ctx, name, canonical, true)
                }
            },
            Decl::ExternFn { name, .. } => {
                if include_values {
                    let canonical = module_item_identity(module_prefix, name)
                    let _ = bind_exact_import_alias(
                        ctx, name, canonical, true)
                }
            },
            Decl::Const { name, .. } => {
                if include_values {
                    let canonical = module_item_identity(module_prefix, name)
                    let _ = bind_exact_import_alias(
                        ctx, name, canonical, true)
                }
            },
            Decl::ModBlock { name, uses, decls: mod_decls, .. } => {
                let canonical_mod = module_item_identity(module_prefix, name)
                insert_inline_display_aliases(ctx, name, canonical_mod,
                    uses, mod_decls, include_values)
            },
            _ => {}
        }
    }
}

fn insert_inline_display_aliases(
    mut ctx: InferCtx, display_mod: Str, canonical_mod: Str,
    uses: List<UseDecl>, decls: List<Decl>, include_values: Bool
) {
    // resolve_mod_uses has already materialised every public relative import
    // under `${canonical_mod}::<local>`. Display aliases consume that exact
    // key instead of re-resolving the use path or guessing its source leaf.
    for use_decl in uses {
        if use_decl.is_pub {
            match use_decl.imports {
                UseImport::NamedItems { names } => {
                    for item in names {
                        let local = match item.alias {
                            some(alias) => alias,
                            none => item.name
                        }
                        let _ = bind_exact_import_alias(ctx,
                            "${display_mod}::${local}",
                            "${canonical_mod}::${local}", include_values)
                    }
                },
                UseImport::Module => {
                    let path = use_decl.path.segments
                    if path.len() > 0 {
                        let leaf = path.get(path.len() - 1).unwrap_or("")
                        let local = match use_decl.alias {
                            some(alias) => alias,
                            none => leaf
                        }
                        let _ = bind_exact_import_alias(ctx,
                            "${display_mod}::${local}",
                            "${canonical_mod}::${local}", include_values)
                    }
                }
            }
        }
    }
    for decl in decls {
        match decl {
            Decl::Struct { name, .. } => {
                let display = "${display_mod}::${name}"
                let canonical = "${canonical_mod}::${name}"
                match ctx.env.types.structs.get(canonical) {
                    some(def) => { ctx.env.types.structs.insert(display, def) }, none => {}
                }
            },
            Decl::Enum { name, .. } => {
                let display = "${display_mod}::${name}"
                let canonical = "${canonical_mod}::${name}"
                match ctx.env.types.enums.get(canonical) {
                    some(def) => { ctx.env.types.enums.insert(display, def) }, none => {}
                }
            },
            Decl::Trait { name, .. } => {
                let display = "${display_mod}::${name}"
                let canonical = "${canonical_mod}::${name}"
                match ctx.env.trait_reg.traits.get(canonical) {
                    some(def) => { ctx.env.trait_reg.traits.insert(display, def) }, none => {}
                }
            },
            Decl::Effect { name, .. } => {
                let display = "${display_mod}::${name}"
                let canonical = "${canonical_mod}::${name}"
                match ctx.env.types.effects.get(canonical) {
                    some(def) => { ctx.env.types.effects.insert(display, def) }, none => {}
                }
            },
            Decl::EffectAlias { name, .. } => {
                let display = "${display_mod}::${name}"
                let canonical = "${canonical_mod}::${name}"
                match ctx.env.types.effect_aliases.get(canonical) {
                    some(def) => { ctx.env.types.effect_aliases.insert(display, def) }, none => {}
                }
            },
            Decl::TypeAlias { name, .. } => {
                let display = "${display_mod}::${name}"
                let canonical = "${canonical_mod}::${name}"
                match ctx.env.types.type_aliases.get(canonical) {
                    some(def) => { ctx.env.types.type_aliases.insert(display, def) }, none => {}
                }
            },
            Decl::ExternType { name, .. } => {
                let display = "${display_mod}::${name}"
                let canonical = "${canonical_mod}::${name}"
                match ctx.env.types.structs.get(canonical) {
                    some(def) => { ctx.env.types.structs.insert(display, def) },
                    none => match ctx.env.types.structs.get(name) {
                        some(def) => { ctx.env.types.structs.insert(display, def) }, none => {}
                    }
                }
            },
            Decl::Fn { name, .. } => {
                if include_values {
                    let display = "${display_mod}::${name}"
                    let canonical = "${canonical_mod}::${name}"
                    let _ = bind_exact_import_alias(
                        ctx, display, canonical, true)
                }
            },
            Decl::ExternFn { name, .. } => {
                if include_values {
                    let display = "${display_mod}::${name}"
                    let canonical = "${canonical_mod}::${name}"
                    let _ = bind_exact_import_alias(
                        ctx, display, canonical, true)
                }
            },
            Decl::Const { name, .. } => {
                if include_values {
                    let display = "${display_mod}::${name}"
                    let canonical = "${canonical_mod}::${name}"
                    let _ = bind_exact_import_alias(
                        ctx, display, canonical, true)
                }
            },
            Decl::ModBlock { name, uses: nested_uses, decls: nested, .. } => {
                insert_inline_display_aliases(ctx, "${display_mod}::${name}",
                    "${canonical_mod}::${name}", nested_uses, nested, include_values)
            },
            _ => {}
        }
    }
}

fn append_expanded_impl_predicates(
    ctx: InferCtx, subject_index: Int, subject_var: Int,
    direct_trait: Str, current_trait: Str, path: List<Str>,
    direct_keys: Set<Str>, mut seen: Set<Str>,
    mut predicates: List<TypedImplPredicate>, depth: Int
) {
    if depth > ctx.env.trait_reg.traits.len() + 1 {
        panic("impl predicate expansion exceeded finite trait registry")
    }
    match ctx.env.trait_reg.traits.get(current_trait) {
        some(def) => {
            for parent in def.supertraits {
                let key = "${subject_index.to_str()}|${parent}"
                let mut next_path = list_clone(path)
                next_path.push(parent)
                if !direct_keys.contains(key) && !seen.contains(key) {
                    seen.insert(key)
                    predicates.push(make_typed_impl_predicate(
                        subject_index, subject_var, parent, [],
                        expanded_impl_predicate_provenance(next_path)))
                    append_expanded_impl_predicates(
                        ctx, subject_index, subject_var,
                        direct_trait, parent, next_path,
                        direct_keys, seen, predicates, depth + 1)
                }
            }
        },
        none => {}
    }
}

fn freeze_source_impl_predicates(
    mut ctx: InferCtx, type_params: List<TypeParam>,
    impl_tv_ids: List<Int>
) -> FrozenImplPredicateSet {
    if type_params.len() != impl_tv_ids.len() {
        panic("impl predicate: owner arity mismatch")
    }
    let mut predicates: List<TypedImplPredicate> = []
    let mut direct_keys: Set<Str> = set_new()
    let mut subject_index = 0
    for param in type_params {
        let subject_var = impl_tv_ids.get(subject_index).unwrap_or(-1)
        for bound in param.bounds {
            reject_bound_shape(
                ctx, bound, BoundShapeContext::ImplOwnerBound, param.span)
            let trait_name = resolve_trait_identity(ctx, bound.trait_name)
            let trait_def = match ctx.env.trait_reg.traits.get(trait_name) {
                some(def) => def,
                none => {
                    let display = nominal_display_name(trait_name)
                    let _ = type_error(ctx.sink, E0501,
                        "Unknown trait: ${display}", bound.span,
                        DiagnosticContext::TraitError {
                            detail: "unknown impl predicate '${display}'"
                        })
                    fail.raise(CompileError {})
                }
            }
            let key = "${subject_index.to_str()}|${trait_name}"
            if direct_keys.contains(key) {
                let display = nominal_display_name(trait_name)
                let _ = type_error(ctx.sink, E0503,
                    "Duplicate impl predicate '${param.name}: ${display}'",
                    bound.span, DiagnosticContext::TraitError {
                        detail: "impl predicates must be unique"
                    })
                fail.raise(CompileError {})
            }
            let mut constraints: List<ImplAssocPredicate> = []
            let mut constraint_names: Set<Str> = set_new()
            for constraint in bound.assoc_constraints {
                if constraint_names.contains(constraint.name) {
                    let _ = type_error(ctx.sink, E0513,
                        "Duplicate associated type constraint '${constraint.name}'",
                        constraint.span, DiagnosticContext::TraitError {
                            detail: "associated constraints must be unique"
                        })
                    fail.raise(CompileError {})
                }
                let declared = trait_def.assoc_types.any(fn(assoc) {
                    assoc.name == constraint.name
                })
                if !declared {
                    let _ = type_error(ctx.sink, E0514,
                        "Unexpected associated type '${constraint.name}' in impl predicate '${nominal_display_name(trait_name)}'",
                        constraint.span, DiagnosticContext::TraitError {
                            detail: "predicate associated type is not declared"
                        })
                    fail.raise(CompileError {})
                }
                constraint_names.insert(constraint.name)
                constraints.push(make_impl_assoc_predicate(
                    constraint.name, resolve_type_expr(ctx, constraint.ty)))
            }
            direct_keys.insert(key)
            predicates.push(make_typed_impl_predicate(
                subject_index, subject_var, trait_name, constraints,
                direct_impl_predicate_provenance()))
        }
        subject_index = subject_index + 1
    }

    let mut seen = set_new()
    for key in direct_keys { seen.insert(key) }
    let direct_predicates = list_clone(predicates)
    for predicate in direct_predicates {
        let trait_name = impl_predicate_trait_name(predicate)
        append_expanded_impl_predicates(
            ctx,
            impl_predicate_subject_param_index(predicate),
            impl_predicate_subject_type_var(predicate),
            trait_name, trait_name, [trait_name],
            direct_keys, seen, predicates, 0)
    }
    freeze_impl_predicate_set(impl_tv_ids, predicates)
}

fn register_phase3_delegate(
    mut ctx: InferCtx, decl: Decl, decl_index: Int
) {
    match decl {
        Decl::Impl { target_type, type_params, trait_name, methods, span } => {
            let mut delegate_facts: List<DelegateProviderFact> = []
            for source_member_index in 0..methods.len() {
                match methods.get(source_member_index) {
                    some(Decl::Delegate { .. }) => {
                        let fact = peek_delegate_provider_fact(
                            ctx, decl_index, source_member_index)
                        commit_delegate_provider_fact(ctx, fact)
                        delegate_facts.push(fact)
                    },
                    _ => {}
                }
            }
            if delegate_facts.len() > 0 {
                let saved = map_clone(ctx.type_param_scope)
                let canonical_target = resolve_nominal_identity(ctx, target_type)
                let canonical_trait = match trait_name {
                    some(name) => some(resolve_trait_identity(ctx, name)),
                    none => none
                }
                let canonical_trait_ref = exact_trait_ref(
                    ctx, canonical_trait)
                let parent_provider_ref = delegate_facts.first().unwrap().parent_provider_ref
                for fact in delegate_facts {
                    if !impl_provider_ref_same(
                            fact.parent_provider_ref, parent_provider_ref) {
                        panic("delegate registration: parent provider changed")
                    }
                }
                let owner = match find_impl_by_provider(
                    ctx.env.trait_reg, canonical_target,
                    canonical_trait_ref, parent_provider_ref) {
                    some(entry) => entry,
                    none => {
                        ctx.type_param_scope = saved
                        fail.raise(CompileError {})
                    }
                }
                if owner.type_param_vars.len() != type_params.len() {
                    panic("delegate registration: outer owner arity mismatch")
                }
                for index in 0..type_params.len() {
                    match (type_params.get(index),
                           owner.type_param_vars.get(index)) {
                        (some(param), some(id)) => ctx.type_param_scope.insert(
                            param.name,
                            Type::TypeVar { id: id, name: some(param.name) }),
                        _ => panic(
                            "delegate registration: outer owner mapping is incomplete")
                    }
                }
                let mut delegate_index = 0
                let mut child_plans: List<DelegateChildProviderPlan> = []
                for source_member_index in 0..methods.len() {
                    match methods.get(source_member_index) {
                        some(Decl::Delegate {
                            field, trait_names, span: dspan
                        }) => {
                            let fact = delegate_facts.get(
                                delegate_index).unwrap()
                            if fact.source_member_index != source_member_index {
                                panic("delegate registration: provider order changed")
                            }
                            let outcome = some(register_delegate(
                                ctx, owner, canonical_target,
                                field, trait_names, dspan, type_params,
                                fact.provider_ref)) catch { _ => none }
                            let had_semantic_error = outcome.unwrap_or(true)
                            let produced_owner_count = find_impls_by_provider(
                                ctx.env.trait_reg, canonical_target,
                                fact.provider_ref).len()
                            child_plans.push(
                                make_delegate_child_provider_plan(
                                    source_member_index, fact.provider_ref,
                                    produced_owner_count,
                                    had_semantic_error))
                            delegate_index = delegate_index + 1
                        },
                        _ => {}
                    }
                }
                finalize_delegate_provider_plan(
                    ctx.env.trait_reg, canonical_target,
                    canonical_trait_ref, parent_provider_ref, child_plans)

                ctx.type_param_scope = saved
            }
        },
        _ => {}
    }
}

fn register_nonproject_phase3_delegate(
    mut ctx: InferCtx, item: IndexedDecl
) {
    match item.decl {
        Decl::ModBlock { name, decls, .. } => {
            enter_struct_identity_child_frame(ctx, item.decl_index)
            for child in index_decls(decls) {
                register_nonproject_phase3_delegate(ctx, IndexedDecl {
                    decl_index: child.decl_index,
                    decl: prefix_decl_name(name, child.decl)
                })
            }
            exit_struct_identity_frame(ctx)
        },
        _ => register_phase3_delegate(ctx, item.decl, item.decl_index)
    }
}

// ============================================================
// Struct registration
// ============================================================

fn consume_nominal_derived_provider_plan(
    mut ctx: InferCtx, decl_index: Int,
    derive_attrs: List<DeriveAttribute>
) -> NominalDerivedProviderPlan {
    let fact = peek_nominal_derived_provider_fact(
        ctx, decl_index, derive_attrs.len())
    let mut explicit: List<ExplicitDerivedProviderPlan> = []
    for attr_index in 0..derive_attrs.len() {
        let attribute = derive_attrs.get(attr_index).unwrap()
        let provider = match fact.explicit_providers.get(attr_index) {
            some(value) => {
                if value.attr_index != attr_index {
                    panic("impl provider: explicit derive order changed")
                }
                value.provider_ref
            },
            none => panic("impl provider: explicit derive provider is missing")
        }
        explicit.push(ExplicitDerivedProviderPlan {
            attribute: attribute,
            provider_ref: provider
        })
    }
    commit_nominal_derived_provider_fact(ctx, fact)
    NominalDerivedProviderPlan {
        implicit_provider_ref: fact.implicit_provider_ref,
        explicit_providers: explicit
    }
}

fn preregister_struct(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    derive_attrs: List<DeriveAttribute>, span: Span, decl_index: Int,
    field_count: Int
) {
    let derived_provider_plan = consume_nominal_derived_provider_plan(
        ctx, decl_index, derive_attrs)
    validate_type_param_bound_shapes(
        ctx, type_params, BoundShapeContext::OrdinaryBound, span)
    let identity = peek_struct_identity_fact(
        ctx, decl_index, false, field_count)
    let mut tp_names: List<Str> = []
    let mut tp_vars: List<Int> = []
    for tp in type_params {
        tp_names.push(tp.name)
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }
    let def = StructDef { name: name,
        owner_ref: make_registered_nominal_ref(identity.owner_ref, name),
        type_params: tp_names, type_param_vars: tp_vars, fields: [],
        derive_attrs: derive_attrs,
        derived_provider_plan: some(derived_provider_plan),
        is_extern: false }
    commit_struct_identity_fact(ctx, identity, true)
    ctx.env.types.structs.insert(name, def)
}

fn complete_struct_fields(mut ctx: InferCtx, name: Str, fields: List<StructFieldDecl>) {
    match ctx.env.types.structs.get(name) {
        some(def) => {
            let identity = peek_struct_identity_completion(
                ctx, registered_nominal_ref_symbol(def.owner_ref))
            if identity.fields.len() != fields.len() {
                panic("struct identity ledger: field completion arity mismatch")
            }
            let saved = map_clone(ctx.type_param_scope)
            let mut i = 0
            while i < def.type_params.len() {
                match (def.type_params.get(i), def.type_param_vars.get(i)) {
                    (some(tp_name), some(tp_var)) =>
                        ctx.type_param_scope.insert(tp_name, Type::TypeVar { id: tp_var, name: none }),
                    _ => {}
                }
                i = i + 1
            }
            let mut resolved_fields: List<StructField> = []
            let mut resolution_failed = false
            for field_index in 0..fields.len() {
                match (fields.get(field_index), identity.fields.get(field_index)) {
                    (some(f), some(field_identity)) => {
                        if field_identity.field_index != field_index ||
                           nominal_field_ref_index(field_identity.field_ref) !=
                                field_index ||
                           nominal_field_ref_name(field_identity.field_ref) !=
                                f.name {
                            panic("struct identity ledger: field relation drifted")
                        }
                        let resolved = some(resolve_type_expr(
                            ctx, f.type_annotation)) catch { _ => none }
                        match resolved {
                            some(field_type) => resolved_fields.push(StructField {
                                name: f.name,
                                ty: field_type,
                                is_pub: f.is_pub,
                                field_ref: field_identity.field_ref,
                                field_index: field_index,
                                span: f.span
                            }),
                            none => { resolution_failed = true }
                        }
                    },
                    _ => panic("struct identity ledger: missing field identity")
                }
            }
            ctx.type_param_scope = saved
            if resolution_failed { fail.raise(CompileError {}) }
            let mut committed_def = def
            commit_struct_identity_completion(ctx, identity)
            committed_def.fields = resolved_fields
        },
        none => {}
    }
}

// ============================================================
// Enum registration
// ============================================================

fn preregister_enum(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    variants: List<EnumVariantDecl>, derive_attrs: List<DeriveAttribute>,
    span: Span, decl_index: Int
) {
    let derived_provider_plan = consume_nominal_derived_provider_plan(
        ctx, decl_index, derive_attrs)
    validate_type_param_bound_shapes(
        ctx, type_params, BoundShapeContext::OrdinaryBound, span)
    let identity = peek_struct_identity_fact(ctx, decl_index, false, 0)
    let mut variant_field_counts: List<Int> = []
    for variant in variants {
        variant_field_counts.push(match variant.named_fields {
            some(named) => if named.len() > 0 {
                named.len()
            } else { variant.fields.len() },
            none => variant.fields.len()
        })
    }
    let enum_identity = peek_enum_identity_group(
        ctx, identity.owner_ref, variant_field_counts)
    let mut tp_names: List<Str> = []
    let mut tv_ids: List<Int> = []
    for tp in type_params {
        tp_names.push(tp.name)
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tv_ids.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }
    let def = EnumDef {
        name: name,
        owner_ref: make_registered_nominal_ref(identity.owner_ref, name),
        type_params: tp_names, type_param_vars: tv_ids,
        variants: [], derive_attrs: derive_attrs,
        variant_refs: enum_identity.variants.map(fn(variant) {
            variant.variant_ref
        }),
        variant_field_refs: enum_identity.variants.map(fn(variant) {
            variant.fields
        }),
        derived_provider_plan: some(derived_provider_plan),
        variant_index: map_new()
    }
    commit_complete_nominal_identity_fact(ctx, identity)
    commit_enum_identity_group(ctx, enum_identity)
    ctx.env.types.enums.insert(name, def)
}

fn complete_enum_variants(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, variants: List<EnumVariantDecl>) {
    match ctx.env.types.enums.get(name) {
        some(def) => {
            let project_active = ctx.project_namespace_file_key.is_some()
            let saved = map_clone(ctx.type_param_scope)
            let mut tv_types: List<Type> = []
            let mut i = 0
            while i < def.type_params.len() {
                match (def.type_params.get(i), def.type_param_vars.get(i)) {
                    (some(tp_name), some(tp_var)) => {
                        let tv = Type::TypeVar { id: tp_var, name: none }
                        ctx.type_param_scope.insert(tp_name, tv)
                        tv_types.push(tv)
                    },
                    _ => {}
                }
                i = i + 1
            }

            let mut vi = 0
            for v in variants {
                let variant_ref = def.variant_refs.get(vi).unwrap()
                if variant_ref_source_index(variant_ref) != vi ||
                   !registered_nominal_ref_same(
                        variant_ref_owner(variant_ref), def.owner_ref) {
                    panic("enum identity ledger: variant owner/order drifted")
                }
                let expected_fields = def.variant_field_refs.get(vi).unwrap()
                let actual_field_count = match v.named_fields {
                    some(named) => if named.len() > 0 {
                        named.len()
                    } else { v.fields.len() },
                    none => v.fields.len()
                }
                if expected_fields.len() != actual_field_count {
                    panic("enum identity ledger: variant payload census drifted")
                }
                for field_index in 0..expected_fields.len() {
                    let field_ref = expected_fields.get(field_index).unwrap()
                    if variant_field_ref_index(field_ref) != field_index ||
                       !variant_ref_same(
                            variant_field_ref_variant(field_ref), variant_ref) {
                        panic("enum identity ledger: payload field order drifted")
                    }
                }
                match v.named_fields {
                    some(nf) => {
                        if nf.len() > 0 {
                            let mut field_types: List<Type> = []
                            let mut field_names: List<Str> = []
                            for f in nf {
                                field_types.push(resolve_type_expr(ctx, f.type_expr))
                                field_names.push(f.name)
                            }
                            def.variants.push(EnumVariant { name: v.name, fields: field_types, field_names: some(field_names) })
                        } else {
                            let mut field_types: List<Type> = []
                            for f in v.fields { field_types.push(resolve_type_expr(ctx, f)) }
                            def.variants.push(EnumVariant { name: v.name, fields: field_types, field_names: none })
                        }
                    },
                    none => {
                        let mut field_types: List<Type> = []
                        for f in v.fields { field_types.push(resolve_type_expr(ctx, f)) }
                        def.variants.push(EnumVariant { name: v.name, fields: field_types, field_names: none })
                    }
                }
                def.variant_index.insert(v.name, vi)
                vi = vi + 1
            }

            let enum_type = Type::EnumType { name: name, type_params: tv_types }
            let tv_ids = def.type_param_vars
            for variant in def.variants {
                let ctor_payload = variant_ctor_name(name, variant.name)
                let binding_name = if project_active {
                    ctor_payload
                } else {
                    variant.name
                }
                if !project_active {
                    ctx.env.types.variant_to_enum.insert(variant.name, name)
                }
                if variant.field_names.is_some() {
                    bind_variant_constructor(ctx, binding_name, enum_type, tv_ids)
                } else if variant.fields.len() == 0 {
                    bind_variant_constructor(ctx, binding_name, enum_type, tv_ids)
                } else {
                    let fn_type = Type::FnType { params: variant.fields, return_type: enum_type, effects: EMPTY_ROW }
                    if tv_ids.len() > 0 {
                        ctx.env.bind(binding_name, TypeScheme { ty: fn_type, type_vars: tv_ids, bounds: [], def_id: none })
                    } else {
                        ctx.env.bind_mono(binding_name, fn_type)
                    }
                }
                if !project_active {
                    // The single-file pipeline still binds the historical leaf
                    // first. Mirror its exact scheme under the canonical
                    // payload without changing legacy visibility.
                    match ctx.env.lookup(variant.name) {
                        some(scheme) => {
                            ctx.env.bind(ctor_payload, TypeScheme {
                                ty: scheme.ty,
                                type_vars: scheme.type_vars,
                                bounds: scheme.bounds,
                                def_id: none
                            })
                        },
                        none => {}
                    }
                }
                // Bare fieldless variants and positional payload constructors
                // both lower through Ident/Call codegen and need an exact
                // canonical constructor symbol. Named-field variants lower via
                // HExpr::NamedVariantConstruct instead.
                if variant.field_names.is_none() {
                    if !project_active {
                        record_variant_ctor_origin(ctx, variant.name,
                            ctor_payload)
                    }
                    record_variant_ctor_origin(ctx, ctor_payload,
                        ctor_payload)
                }
            }

            ctx.type_param_scope = saved
        },
        none => {}
    }
}

fn bind_variant_constructor(mut ctx: InferCtx, variant_name: Str, enum_type: Type, tv_ids: List<Int>) {
    if tv_ids.len() > 0 {
        ctx.env.bind(variant_name, TypeScheme { ty: enum_type, type_vars: tv_ids, bounds: [], def_id: none })
    } else {
        ctx.env.bind_mono(variant_name, enum_type)
    }
}

// ============================================================
// Effect registration
// ============================================================

fn register_effect(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    ops: List<EffectOpDecl>, span: Span, decl_index: Int
) {
    validate_type_param_bound_shapes(
        ctx, type_params, BoundShapeContext::OrdinaryBound, span)
    let identity = peek_effect_identity_fact(ctx, decl_index, ops.len())
    let saved = map_clone(ctx.type_param_scope)
    let mut tp_names: List<Str> = []
    let mut tp_vars: List<Int> = []
    for tp in type_params {
        tp_names.push(tp.name)
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }
    let mut effect_ops: List<EffectOpDef> = []
    let mut op_index = 0
    for op in ops {
        let mut param_types: List<Type> = []
        for p in op.params {
            match p.type_annotation {
                some(ta) => param_types.push(resolve_type_expr(ctx, ta)),
                none => param_types.push(ctx.env.fresh_var())
            }
        }
        let ret = resolve_type_expr(ctx, op.return_type)
        let op_has_default = op.body.is_some()
        effect_ops.push(EffectOpDef {
            name: op.name,
            operation_ref: some(identity.operations.get(op_index).unwrap()),
            params: param_types, return_type: ret,
            has_default: op_has_default
        })
        op_index = op_index + 1
    }
    let mut all_defaults = true
    for eop in effect_ops {
        if !eop.has_default { all_defaults = false }
    }
    if effect_ops.len() == 0 { all_defaults = false }
    ctx.type_param_scope = saved
    commit_effect_identity_fact(ctx, identity)
    ctx.env.types.effects.insert(name, EffectDef {
        name: name, owner_ref: some(identity.owner_ref),
        handled_ref: some(identity.handled_ref),
        type_params: tp_names, type_param_vars: tp_vars,
        ops: effect_ops, built_in_kind: none,
        all_have_defaults: all_defaults
    })
}

// ============================================================
// Trait registration
// ============================================================

enum BoundShapeContext {
    OrdinaryBound,
    ImplOwnerBound,
    ImplMethodBound,
    SupertraitBound,
    ProtocolImplBound
}

fn reject_bound_shape(
    mut ctx: InferCtx, bound: TypeBound,
    context: BoundShapeContext, owner_span: Span
) {
    if bound.type_args.len() > 0 {
        let display = nominal_display_name(bound.trait_name)
        let _ = type_error(ctx.sink, E0503,
            "Trait bound '${display}' uses unsupported type arguments",
            bound.span, DiagnosticContext::TraitError {
                detail: "trait-bound type arguments are not representable"
            })
        fail.raise(CompileError {})
    }
    match context {
        BoundShapeContext::ImplMethodBound => {
            let display = nominal_display_name(bound.trait_name)
            let _ = type_error(ctx.sink, E0503,
                "Impl method type parameter bound '${display}' is unsupported",
                bound.span, DiagnosticContext::TraitError {
                    detail: "impl method predicates are not supported"
                })
            fail.raise(CompileError {})
        },
        BoundShapeContext::SupertraitBound => {
            if bound.assoc_constraints.len() > 0 {
                let display = nominal_display_name(bound.trait_name)
                let _ = type_error(ctx.sink, E0503,
                    "Supertrait bound '${display}' uses unsupported associated constraints",
                    bound.span, DiagnosticContext::TraitError {
                        detail: "complex supertrait predicates are not supported"
                    })
                fail.raise(CompileError {})
            }
        },
        BoundShapeContext::ProtocolImplBound => {
            if bound.assoc_constraints.len() > 0 {
                let display = nominal_display_name(bound.trait_name)
                let _ = type_error(ctx.sink, E0503,
                    "Iteration protocol impl bound '${display}' uses nested type arguments or associated constraints",
                    bound.span, DiagnosticContext::TraitError {
                        detail: "nested iteration protocol predicates remain unsupported"
                    })
                fail.raise(CompileError {})
            }
        },
        _ => {}
    }
}

fn validate_type_param_bound_shapes(
    mut ctx: InferCtx, type_params: List<TypeParam>,
    context: BoundShapeContext, owner_span: Span
) {
    for param in type_params {
        for bound in param.bounds {
            reject_bound_shape(ctx, bound, context, owner_span)
        }
    }
}

fn collect_supertraits_dfs(
    ctx: InferCtx, current: Str,
    mut visited: Set<Str>, mut result: List<Str>, depth: Int
) {
    if depth > ctx.env.trait_reg.traits.len() + 1 {
        panic("supertrait traversal exceeded finite registry")
    }
    match ctx.env.trait_reg.traits.get(current) {
        some(def) => {
            for parent in def.supertraits {
                if !visited.contains(parent) {
                    visited.insert(parent)
                    result.push(parent)
                    collect_supertraits_dfs(
                        ctx, parent, visited, result, depth + 1)
                }
            }
        },
        none => {}
    }
}

// Declaration-order deterministic transitive closure.  The previous LIFO
// stack reversed sibling order and could not provide stable expansion paths.
pub fn collect_all_supertraits(ctx: InferCtx, trait_name: Str) -> List<Str> {
    let mut result: List<Str> = []
    let mut visited: Set<Str> = set_new()
    visited.insert(trait_name)
    collect_supertraits_dfs(ctx, trait_name, visited, result, 0)
    result
}

pub fn resolve_trait_identity(ctx: InferCtx, trait_name: Str) -> Str {
    match ctx.env.trait_reg.traits.get(trait_name) {
        some(def) => def.name,
        none => trait_name
    }
}

pub fn resolve_nominal_identity(ctx: InferCtx, type_name: Str) -> Str {
    match ctx.env.types.structs.get(type_name) {
        some(def) => def.name,
        none => match ctx.env.types.enums.get(type_name) {
            some(def) => def.name,
            none => type_name
        }
    }
}

fn push_unique_symbol(mut values: List<SymbolRef>, value: SymbolRef) {
    for existing in values {
        if symbol_ref_same(existing, value) { return }
    }
    values.push(value)
}

fn register_trait(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    supertraits: List<TypeBound>, methods: List<Decl>, span: Span,
    decl_index: Int
) {
    let mut method_count = 0
    let mut assoc_count = 0
    for method in methods {
        match method {
            Decl::Fn { .. } => { method_count = method_count + 1 },
            Decl::AssocType { .. } => { assoc_count = assoc_count + 1 },
            _ => {}
        }
    }
    let identity = peek_trait_identity_fact(
        ctx, decl_index, method_count, assoc_count)
    let mut identity_callable_slot_index = 0
    for identity_source_member_index in 0..methods.len() {
        match methods.get(identity_source_member_index) {
            some(Decl::Fn { name: identity_method_name, .. }) => {
                let method_ref = match identity.methods.get(
                    identity_callable_slot_index) {
                    some(value) => value,
                    none => panic("trait identity ledger: method slot is missing")
                }
                if !symbol_ref_same(
                        trait_method_ref_trait(method_ref), identity.owner_ref) ||
                   trait_method_ref_source_member_index(method_ref) !=
                        identity_source_member_index ||
                   trait_method_ref_callable_slot_index(method_ref) !=
                        identity_callable_slot_index ||
                   trait_method_ref_name(method_ref) != identity_method_name {
                    panic("trait identity ledger: method relation drifted")
                }
                identity_callable_slot_index = identity_callable_slot_index + 1
            },
            _ => {}
        }
    }
    commit_trait_identity_fact(ctx, identity)
    validate_type_param_bound_shapes(
        ctx, type_params, BoundShapeContext::OrdinaryBound, span)
    let saved = map_clone(ctx.type_param_scope)
    let saved_qualified_assoc = map_clone(ctx.qualified_assoc_scope)
    let mut tp_names: List<Str> = []
    let mut tp_vars: List<Int> = []
    for tp in type_params {
        tp_names.push(tp.name)
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }

    // Validate and collect supertrait names
    let mut supertrait_names: List<Str> = []
    for st in supertraits {
        reject_bound_shape(ctx, st, BoundShapeContext::SupertraitBound, span)
        if !ctx.env.trait_reg.traits.contains_key(st.trait_name) {
            let trait_display = nominal_display_name(st.trait_name)
            let _ = type_error(ctx.sink, E0501,
                "Unknown supertrait: ${trait_display}", span,
                DiagnosticContext::TraitError { detail: "unknown supertrait '${trait_display}'" })
        } else {
            supertrait_names.push(resolve_trait_identity(ctx, st.trait_name))
        }
    }
    let mut dict_obligations: List<SymbolRef> = []
    for supertrait_name in supertrait_names {
        match ctx.env.trait_reg.traits.get(supertrait_name) {
            some(supertrait_def) => push_unique_symbol(
                dict_obligations,
                registered_trait_ref_symbol(supertrait_def.owner_ref)),
            none => {}
        }
    }

    // Detect cyclic supertrait inheritance via DFS
    for st_name in supertrait_names {
        let mut visited: Set<Str> = set_new()
        visited.insert(name)
        let mut stack: List<Str> = [st_name]
        while stack.len() > 0 {
            let current = stack.pop().unwrap()
            if visited.contains(current) {
                let name_display = nominal_display_name(name)
                let current_display = nominal_display_name(current)
                let _ = type_error(ctx.sink, E0506,
                    "Cyclic supertrait inheritance: '${name_display}' -> '${current_display}'", span,
                    DiagnosticContext::TraitError { detail: "cyclic supertrait inheritance" })
                break
            }
            visited.insert(current)
            match ctx.env.trait_reg.traits.get(current) {
                some(parent_def) => {
                    for parent_st in parent_def.supertraits {
                        stack.push(parent_st)
                    }
                },
                none => {}
            }
        }
    }

    let self_var = ctx.env.fresh_var()

    // Collect associated types first, inject into type_param_scope
    let mut assoc_type_defs: List<AssocTypeDef> = []
    let mut assoc_slot_index = 0
    for method in methods {
        match method {
            Decl::AssocType { name: aname, bounds: abounds, value: avalue, .. } => {
                // Create a named type variable for this associated type
                // so error messages show "Item" instead of "?NNN"
                let at_var_id = ctx.env.fresh_var_id()
                let at_var = Type::TypeVar { id: at_var_id, name: some(aname) }
                ctx.type_param_scope.insert(aname, at_var)
                let mut bound_names: List<Str> = []
                for b in abounds {
                    reject_bound_shape(
                        ctx, b, BoundShapeContext::SupertraitBound, span)
                    bound_names.push(resolve_trait_identity(ctx, b.trait_name))
                }
                let default_ty = match avalue {
                    some(v) => some(resolve_type_expr(ctx, v)),
                    none => none
                }
                let member_ref = identity.assoc_members.get(
                    assoc_slot_index).unwrap()
                assoc_type_defs.push(AssocTypeDef {
                    name: aname, member_ref: member_ref,
                    bounds: bound_names, default_type: default_ty,
                    var_id: at_var_id
                })
                assoc_slot_index = assoc_slot_index + 1
            },
            _ => {}
        }
    }
    if assoc_slot_index != identity.assoc_members.len() {
        panic("trait identity ledger: associated member census drifted")
    }

    // Inject Self into type_param_scope so Self::Item resolves in trait method signatures
    ctx.type_param_scope.insert("Self", self_var)
    // Inject Self::Item into qualified_assoc_scope
    for atd in assoc_type_defs {
        match ctx.type_param_scope.get(atd.name) {
            some(at_ty) => {
                ctx.qualified_assoc_scope.insert("Self::${atd.name}", at_ty)
            },
            none => {}
        }
    }

    let mut trait_methods: List<TraitMethodDef> = []
    let mut handled_effect_obligations: List<HandledEffectRef> = []
    let mut callable_slot_index = 0
    for source_member_index in 0..methods.len() {
        let method = methods.get(source_member_index).unwrap()
        match method {
            Decl::Fn { name: mname, type_params: method_tps, params, return_type, declared_effects, is_abstract, .. } => {
                let method_ref = match identity.methods.get(callable_slot_index) {
                    some(value) => value,
                    none => panic("trait identity ledger: method slot is missing")
                }
                validate_type_param_bound_shapes(
                    ctx, method_tps,
                    BoundShapeContext::ImplMethodBound, span)
                for method_type_param in method_tps {
                    for bound in method_type_param.bounds {
                        match ctx.env.trait_reg.traits.get(
                                resolve_trait_identity(ctx, bound.trait_name)) {
                            some(bound_trait) => push_unique_symbol(
                                dict_obligations,
                                registered_trait_ref_symbol(
                                    bound_trait.owner_ref)),
                            none => {}
                        }
                    }
                }
                let mut param_types: List<Type> = []
                let mut param_muts: List<Bool> = []
                for p in params {
                    param_muts.push(p.is_mutable)
                    if p.name == "self" {
                        param_types.push(self_var)
                    } else {
                        match p.type_annotation {
                            some(ta) => param_types.push(resolve_type_expr(ctx, ta)),
                            none => param_types.push(ctx.env.fresh_var())
                        }
                    }
                }
                let ret = match return_type {
                    some(rt) => resolve_type_expr(ctx, rt),
                    none => ctx.env.fresh_var()
                }
                // #77: Resolve declared effects so delegate forwarding can propagate evidence
                let method_effects = match declared_effects {
                    some(de) => resolve_declared_effects(ctx, de),
                    none => EMPTY_ROW
                }
                for method_effect in method_effects.effects {
                    match method_effect {
                        Effect::CustomEffect { name: effect_name, .. } =>
                            match ctx.env.types.effects.get(effect_name) {
                                some(effect_def) => match effect_def.handled_ref {
                                    some(effect_ref) => {
                                        let mut seen_effect = false
                                        for existing in handled_effect_obligations {
                                            if handled_effect_ref_same(
                                                    existing, effect_ref) {
                                                seen_effect = true
                                            }
                                        }
                                        if !seen_effect {
                                            handled_effect_obligations.push(effect_ref)
                                        }
                                    },
                                    none => {}
                                },
                                none => {}
                            },
                        _ => {}
                    }
                }
                let fn_type = Type::FnType { params: param_types, return_type: ret, effects: method_effects }
                trait_methods.push(TraitMethodDef {
                    name: mname, method_ref: method_ref, ty: fn_type,
                    has_default: !is_abstract,
                    param_mutabilities: param_muts,
                    method_type_params: method_tps
                })
                callable_slot_index = callable_slot_index + 1
            },
            _ => {}
        }
    }

    ctx.type_param_scope = saved
    ctx.qualified_assoc_scope = saved_qualified_assoc
    let registered_owner = make_registered_trait_ref(identity.owner_ref, name)
    let mut method_contracts: List<RegisteredTraitMethodContract> = []
    for method in trait_methods {
        method_contracts.push(make_registered_trait_method_contract(
            method.method_ref, method.ty, method.has_default,
            method.param_mutabilities))
    }
    let mut assoc_contracts: List<RegisteredTraitAssocContract> = []
    for assoc in assoc_type_defs {
        let mut bound_refs: List<SymbolRef> = []
        for bound_name in assoc.bounds {
            match ctx.env.trait_reg.traits.get(bound_name) {
                some(bound_trait) => push_unique_symbol(
                    bound_refs,
                    registered_trait_ref_symbol(bound_trait.owner_ref)),
                none => {}
            }
        }
        assoc_contracts.push(make_registered_trait_assoc_contract(
            assoc.member_ref,
            Type::TypeVar { id: assoc.var_id, name: some(assoc.name) },
            assoc.default_type, bound_refs))
    }
    let contract = make_registered_trait_contract(
        registered_owner, method_contracts, assoc_contracts,
        handled_effect_obligations, dict_obligations)
    ctx.env.trait_reg.traits.insert(name, TraitDef {
        name: name,
        owner_ref: registered_owner,
        type_params: tp_names, type_param_vars: tp_vars,
        methods: trait_methods, supertraits: supertrait_names,
        assoc_types: assoc_type_defs,
        contract: contract
    })
}

// ============================================================
// Impl registration
// ============================================================

fn reject_unsupported_protocol_impl_bounds(
    mut ctx: InferCtx, trait_name: Str?, type_params: List<TypeParam>
) {
    let is_iteration_protocol = match trait_name {
        some(name) => name == "Iterable" || name == "Iterator",
        none => false
    }
    if !is_iteration_protocol { return }
    for tp in type_params {
        for bound in tp.bounds {
            if bound.type_args.len() > 0 || bound.assoc_constraints.len() > 0 {
                let _ = type_error(ctx.sink, E0503,
                    "Iteration protocol impl bound '${tp.name}: ${nominal_display_name(bound.trait_name)}' uses nested type arguments or associated constraints that protocol lowering does not yet consume",
                    bound.span, DiagnosticContext::TraitError {
                        detail: "protocol lowering has not consumed nested impl predicates"
                    })
                fail.raise(CompileError {})
            }
        }
    }
}

fn exact_trait_ref(ctx: InferCtx, trait_name: Str?) -> SymbolRef? {
    match trait_name {
        some(name) => match ctx.env.trait_reg.traits.get(name) {
            some(def) => some(registered_trait_ref_symbol(def.owner_ref)),
            none => none
        },
        none => none
    }
}

fn impl_provider_module_key(provider: ImplProviderRef) -> Str {
    module_body_ref_origin_module_key(path_owner_ref_module_body(
        path_ref_owner(impl_provider_ref_site(provider))))
}

fn generated_impl_method_member(
    provider: ImplProviderRef, discriminator: Str
) -> SymbolRef {
    let module_key = impl_provider_module_key(provider)
    let provider_path = path_ref_normalized_child_path(
        impl_provider_ref_site(provider)).join("/")
    make_symbol_ref(
        module_key, namespace_member(),
        "impl-generated-member:${provider_path}:${discriminator}",
        "provider:${provider_path}|${discriminator}")
}

fn register_impl(
    mut ctx: InferCtx, target_type: Str, type_params: List<TypeParam>,
    trait_name: Str?, methods: List<Decl>, span: Span, decl_index: Int
) {
    let provider_fact = peek_source_impl_provider_fact(ctx, decl_index)
    let mut fact_slot = 0
    for source_member_index in 0..methods.len() {
        match methods.get(source_member_index) {
            some(Decl::Fn { name, .. }) => {
                let method_fact = match provider_fact.methods.get(fact_slot) {
                    some(value) => value,
                    none => panic("impl method identity ledger: method is missing")
                }
                if method_fact.source_member_index != source_member_index ||
                   method_fact.callable_slot_index != fact_slot ||
                   method_fact.name != name {
                    panic("impl method identity ledger: source order drifted")
                }
                fact_slot = fact_slot + 1
            },
            _ => {}
        }
    }
    if fact_slot != provider_fact.methods.len() {
        panic("impl method identity ledger: extra method fact")
    }
    commit_source_impl_provider_fact(ctx, provider_fact)
    let mut has_delegate = false
    for source_member_index in 0..methods.len() {
        match methods.get(source_member_index) {
            some(Decl::Delegate { .. }) => { has_delegate = true },
            _ => {}
        }
    }
    let delegate_plan = if has_delegate {
        delegate_plan_pending()
    } else {
        delegate_plan_final([])
    }
    register_impl_canonical(
        ctx, resolve_nominal_identity(ctx, target_type), type_params,
        trait_name, methods, span, provider_fact.provider_ref,
        provider_fact.methods, decl_index, delegate_plan)
}

fn register_impl_canonical(
    mut ctx: InferCtx, target_type: Str, type_params: List<TypeParam>,
    trait_name: Str?, methods: List<Decl>, span: Span,
    provider_ref: ImplProviderRef,
    method_identity_facts: List<ImplMethodIdentityFact>,
    decl_index: Int,
    delegate_plan: DelegatePlanState
) {
    for source_member in methods {
        match source_member {
            Decl::ExternFn { .. } => panic(
                "impl registration: forbidden extern member crossed parser"),
            _ => {}
        }
    }
    let resolved_trait_name = match trait_name {
        some(name) => some(resolve_trait_identity(ctx, name)), none => none
    }
    let resolved_trait_ref = exact_trait_ref(ctx, resolved_trait_name)
    reject_unsupported_protocol_impl_bounds(ctx, resolved_trait_name, type_params)

    let saved = map_clone(ctx.type_param_scope)
    let saved_qualified_assoc = map_clone(ctx.qualified_assoc_scope)
    let mut impl_tv_ids: List<Int> = []
    for tp in type_params {
        let tv = ctx.env.fresh_var()
        match tv {
            Type::TypeVar { id, .. } => { impl_tv_ids.push(id) },
            _ => {}
        }
        ctx.type_param_scope.insert(tp.name, tv)
    }

    let frozen_predicates = freeze_source_impl_predicates(
        ctx, type_params, impl_tv_ids)

    // Collect associated type assignments from impl
    let mut assoc_type_map: Map<Str, Type> = map_new()
    for method in methods {
        match method {
            Decl::AssocType { name: aname, value: avalue, span: aspan, .. } => {
                match avalue {
                    some(v) => {
                        let resolved_ty = resolve_type_expr(ctx, v)
                        assoc_type_map.insert(aname, resolved_ty)
                        // Also inject into type_param_scope so method signatures can reference it
                        ctx.type_param_scope.insert(aname, resolved_ty)
                    },
                    none => {
                        // impl must provide a value
                        let _ = type_error(ctx.sink, E0510,
                            "Associated type '${aname}' must have a value in impl",
                            aspan, DiagnosticContext::TraitError { detail: "missing associated type value" })
                    }
                }
            },
            _ => {}
        }
    }

    // Inject Self into type_param_scope so Self::Item resolves in impl method signatures
    let impl_self_type = resolve_impl_self_type(ctx, target_type, type_params)
    ctx.type_param_scope.insert("Self", impl_self_type)
    // Inject Self::Item into qualified_assoc_scope
    let mut sorted_assoc_map = assoc_type_map.entries()
    sorted_assoc_map.sort_by(compare_by_first)
    for entry in sorted_assoc_map {
        let (aname, aty) = entry
        ctx.qualified_assoc_scope.insert("Self::${aname}", aty)
    }

    let mut exact_method_schemes: Map<Str, ImplMethodSchemeCore> = map_new()
    let mut declared_method_names: Set<Str> = set_new()
    for method in methods {
        match method {
            Decl::Fn { name: mname, type_params: mtps, params, return_type, declared_effects, span: mspan, .. } => {
                if declared_method_names.contains(mname) {
                    let _ = type_error(ctx.sink, E0504,
                        "Duplicate method '${mname}' in impl for '${nominal_display_name(target_type)}'",
                        mspan, DiagnosticContext::TraitError {
                            detail: "an impl block may declare each method name only once"
                        })
                } else {
                    declared_method_names.insert(mname)
                    let scheme = register_impl_method(
                        ctx, impl_tv_ids, target_type, mname, mtps, params,
                        return_type, declared_effects, mspan,
                        saved, type_params)
                    exact_method_schemes.insert(mname, scheme)
                }
            },
            Decl::Delegate { .. } => {},  // Deferred to register_phase3_delegate (needs complete struct fields)
            Decl::AssocType { .. } => {},  // Already handled above
            _ => {}
        }
    }

    let mut owner_valid = true
    match resolved_trait_name {
        some(tname) => {
            let trait_display = nominal_display_name(tname)
            let target_display = nominal_display_name(target_type)
            match ctx.env.trait_reg.traits.get(tname) {
                some(trait_def) => {
                    match find_impl(ctx.env.trait_reg, target_type, tname) {
                        some(existing) => {
                            let same_provider = match existing.provider_ref {
                                some(existing_provider) => impl_provider_ref_same(
                                    existing_provider, provider_ref),
                                none => false
                            }
                            if !same_provider {
                                let _ = type_error(ctx.sink, E0504,
                                    "Duplicate impl '${trait_display}' for '${target_display}'",
                                    span, DiagnosticContext::TraitError {
                                        detail: "distinct exact impl providers supply the same target/trait pair"
                                    })
                            }
                        },
                        none => {}
                    }
                    for tm in trait_def.methods {
                        if !tm.has_default && !declared_method_names.contains(tm.name) {
                            let _ = type_error(ctx.sink, E0502,
                                "Missing method '${tm.name}' in impl ${trait_display} for ${target_display}",
                                span, DiagnosticContext::TraitError { detail: "missing method '${tm.name}'" })
                        }
                    }

                    // Validate associated types
                    let mut impl_assoc_names: Set<Str> = set_new()
                    let mut sorted_assoc_map2 = assoc_type_map.entries()
                    sorted_assoc_map2.sort_by(compare_by_first)
                    for entry in sorted_assoc_map2 {
                        let (aname, _) = entry
                        impl_assoc_names.insert(aname)
                    }
                    // Check: every trait assoc type is provided (or has default)
                    for atdef in trait_def.assoc_types {
                        if !impl_assoc_names.contains(atdef.name) {
                            match atdef.default_type {
                                some(dt) => {
                                    // Use the default
                                    assoc_type_map.insert(atdef.name, dt)
                                },
                                none => {
                                    let _ = type_error(ctx.sink, E0510,
                                        "Missing associated type '${atdef.name}' in impl ${trait_display} for ${target_display}",
                                        span, DiagnosticContext::TraitError { detail: "missing associated type '${atdef.name}'" })
                                }
                            }
                        }
                    }
                    // Check: no extra assoc types in impl that trait doesn't declare
                    let mut trait_assoc_names: Set<Str> = set_new()
                    for atdef in trait_def.assoc_types {
                        trait_assoc_names.insert(atdef.name)
                    }
                    let mut sorted_assoc_map3 = assoc_type_map.entries()
                    sorted_assoc_map3.sort_by(compare_by_first)
                    for entry in sorted_assoc_map3 {
                        let (aname, _) = entry
                        if !trait_assoc_names.contains(aname) {
                            let _ = type_error(ctx.sink, E0514,
                                "Unexpected associated type '${aname}' in impl ${trait_display} for ${target_display}; trait '${trait_display}' does not declare it",
                                span, DiagnosticContext::TraitError { detail: "unexpected associated type '${aname}'" })
                        }
                    }

                    // Validate associated type bounds are satisfied
                    for atdef in trait_def.assoc_types {
                        if atdef.bounds.len() > 0 {
                            match assoc_type_map.get(atdef.name) {
                                some(concrete_ty) => {
                                    let concrete_name = type_to_builtin_name(concrete_ty)
                                    match concrete_name {
                                        some(cname) => {
                                            for bound_trait in atdef.bounds {
                                                if !has_impl(ctx.env.trait_reg, cname, bound_trait) {
                                                    let bound_display = nominal_display_name(bound_trait)
                                                    let concrete_display = nominal_display_name(cname)
                                                    let _ = type_error(ctx.sink, E0513,
                                                        "Associated type '${atdef.name}' requires '${bound_display}', but '${type_to_string(concrete_ty)}' does not implement it",
                                                        span, DiagnosticContext::TraitError { detail: "associated type bound '${bound_display}' not satisfied by '${concrete_display}'" })
                                                }
                                            }
                                        },
                                        none => {}  // TypeVar or other non-named types: skip bound check
                                    }
                                },
                                none => {}  // Missing assoc type already reported via E0510
                            }
                        }
                    }

                    // Validate supertrait impls exist (recursively)
                    let all_supertraits = collect_all_supertraits(ctx, tname)
                    for required_st in all_supertraits {
                        if !has_impl(ctx.env.trait_reg, target_type, required_st) {
                            let required_display = nominal_display_name(required_st)
                            let _ = type_error(ctx.sink, E0505,
                                "Type '${target_display}' does not implement supertrait '${required_display}' required by '${trait_display}'",
                                span, DiagnosticContext::TraitError { detail: "missing supertrait impl '${required_display}'" })
                        }
                    }

                    // An omitted default method is still owned by this exact
                    // impl. Specialize the trait declaration through Self,
                    // associated types, and impl type variables before either
                    // exact or ordinary lookup can observe it.
                    let mut trait_type_args: List<Type> = []
                    let mut trait_index = 0
                    while trait_index < trait_def.type_params.len() {
                        match trait_def.type_params.get(trait_index) {
                            some(type_param_name) =>
                                match ctx.type_param_scope.get(type_param_name) {
                                    some(actual) => trait_type_args.push(actual),
                                    none => match trait_def.type_param_vars.get(trait_index) {
                                        some(source_id) => trait_type_args.push(
                                            Type::TypeVar {
                                                id: source_id,
                                                name: some(type_param_name)
                                            }),
                                        none => {}
                                    }
                                },
                            none => {}
                        }
                        trait_index = trait_index + 1
                    }
                    for trait_method in trait_def.methods {
                        if trait_method.has_default &&
                           !declared_method_names.contains(trait_method.name) {
                            exact_method_schemes.insert(
                                trait_method.name,
                                specialize_trait_method_scheme(
                                    trait_def, trait_method, impl_self_type,
                                    trait_type_args, impl_tv_ids,
                                    assoc_type_map))
                        }
                    }
                },
                none => {
                    owner_valid = false
                    let _ = type_error(ctx.sink, E0501,
                        "Unknown trait: ${trait_display}", span,
                        DiagnosticContext::TraitError {
                            detail: "unknown trait '${trait_display}'"
                        })
                }
            }
        },
        none => {}
    }

    if owner_valid {
        let mut tp_names: List<Str> = []
        for tp in type_params { tp_names.push(tp.name) }
        let mut explicit_method_names = declared_method_names.to_list()
        explicit_method_names.sort()
        let target_ref = match impl_target_symbol(ctx.env, target_type) {
            some(symbol) => symbol,
            none => panic("impl owner: exact target symbol is missing")
        }
        let owner_ref = make_impl_owner_ref(
            target_ref, provider_ref, resolved_trait_ref)
        publish_impl_check_owner(ctx, decl_index, owner_ref)
        let mut exact_method_refs: Map<Str, ImplMethodRef> = map_new()
        for fact in method_identity_facts {
            if exact_method_schemes.contains_key(fact.name) &&
               !exact_method_refs.contains_key(fact.name) {
                exact_method_refs.insert(fact.name, make_impl_method_ref(
                    owner_ref, fact.member_ref,
                    fact.source_member_index,
                    fact.callable_slot_index, fact.name))
            }
        }
        let mut sorted_method_cores = exact_method_schemes.entries()
        sorted_method_cores.sort_by(compare_by_first)
        let mut generated_index = 0
        for method_entry in sorted_method_cores {
            let (method_name, _) = method_entry
            if !exact_method_refs.contains_key(method_name) {
                let mut discriminator = "generated:${generated_index}"
                match resolved_trait_name {
                    some(trait_identity) => match
                            ctx.env.trait_reg.traits.get(trait_identity) {
                        some(trait_def) => match trait_def.methods.find(fn(method) {
                            method.name == method_name
                        }) {
                            some(method) => {
                                discriminator = "default:${trait_method_ref_source_member_index(
                                    method.method_ref)}:${trait_method_ref_callable_slot_index(
                                    method.method_ref)}"
                            },
                            none => {}
                        },
                        none => {}
                    },
                    none => {}
                }
                let callable_index = method_identity_facts.len() + generated_index
                exact_method_refs.insert(method_name, make_impl_method_ref(
                    owner_ref,
                    generated_impl_method_member(provider_ref, discriminator),
                    methods.len() + generated_index,
                    callable_index, method_name))
                generated_index = generated_index + 1
            }
        }
        let owner_entry = ImplEntry {
            trait_name: resolved_trait_name,
            target_type_name: target_type,
            type_params: tp_names,
            type_param_vars: impl_tv_ids,
            predicates: frozen_predicates,
            method_names: explicit_method_names,
            assoc_types: map_clone(assoc_type_map),
            method_schemes: map_clone(exact_method_schemes),
            method_refs: exact_method_refs,
            method_intrinsics: map_new(),
            provider_ref: some(provider_ref),
            trait_ref: resolved_trait_ref,
            owner_ref: some(owner_ref),
            delegate_plan: delegate_plan,
            span: span
        }
        add_impl(ctx.env.trait_reg, owner_entry)

        let mut sorted_exact_methods = exact_method_schemes.entries()
        sorted_exact_methods.sort_by(compare_by_first)
        for entry in sorted_exact_methods {
            let (method_name, core) = entry
            let _ = install_method_core(
                ctx.env.trait_reg, ctx.sink,
                target_type, method_name, core,
                exact_method_refs.get(method_name).unwrap(), span)
        }
    }

    ctx.type_param_scope = saved
    ctx.qualified_assoc_scope = saved_qualified_assoc
}

// Construct the self type for an impl method, using the impl's type params
// from type_param_scope instead of creating unrelated fresh vars.
// This ensures the self type shares the same type variables as the rest of
// the method signature, so instantiation correctly replaces all occurrences.
fn resolve_impl_self_type(mut ctx: InferCtx, target_type: Str, impl_type_params: List<TypeParam>) -> Type {
    if impl_type_params.len() == 0 {
        return resolve_self_type(ctx, target_type)
    }
    let mut impl_tp_types: List<Type> = []
    for tp in impl_type_params {
        match ctx.type_param_scope.get(tp.name) {
            some(tv) => impl_tp_types.push(tv),
            none => impl_tp_types.push(ctx.env.fresh_var())
        }
    }
    match ctx.env.types.structs.get(target_type) {
        some(def) => Type::StructType { name: def.name, type_params: impl_tp_types },
        none => match ctx.env.types.enums.get(target_type) {
            some(def) => Type::EnumType { name: def.name, type_params: impl_tp_types },
            none => resolve_self_type(ctx, target_type)
        }
    }
}

fn register_impl_method(
    mut ctx: InferCtx, impl_tv_ids: List<Int>,
    target_type: Str, mname: Str, mtps: List<TypeParam>, params: List<Param>,
    return_type: TypeExpr?, declared_effects: List<EffectExpr>?, method_span: Span,
    outer_saved: Map<Str, Type>,
    impl_type_params: List<TypeParam>
) -> ImplMethodSchemeCore {
    validate_type_param_bound_shapes(
        ctx, mtps, BoundShapeContext::ImplMethodBound, method_span)
    let saved_method = map_clone(ctx.type_param_scope)
    let mut method_tv_ids: List<Int> = []
    for mtp in mtps {
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { method_tv_ids.push(id) }, _ => {} }
        ctx.type_param_scope.insert(mtp.name, tv)
    }

    let self_type = resolve_impl_self_type(ctx, target_type, impl_type_params)
    let mut param_types: List<Type> = []
    for p in params {
        match p.type_annotation {
            some(ta) => param_types.push(resolve_type_expr(ctx, ta)),
            none => if p.name == "self" { param_types.push(self_type) } else { param_types.push(ctx.env.fresh_var()) }
        }
    }
    let ret = match return_type { some(rt) => resolve_type_expr(ctx, rt), none => ctx.env.fresh_var() }

    let mut all_tvs = list_clone(impl_tv_ids)
    for mtv in method_tv_ids { all_tvs.push(mtv) }

    // Non-extern methods: filter unused type variables from outer scope
    {
        let mut declared_names: Set<Str> = set_new()
        let mut sorted_tp_scope = ctx.type_param_scope.entries()
        sorted_tp_scope.sort_by(compare_by_first)
        for entry in sorted_tp_scope {
            let (tpname, _) = entry
            if outer_saved.contains_key(tpname) { declared_names.insert(tpname) }
        }
        for entry in sorted_tp_scope {
            let (tpname, tv) = entry
            if !outer_saved.contains_key(tpname) && !declared_names.contains(tpname) {
                match tv { Type::TypeVar { id, .. } => {
                    if !all_tvs.contains(id) { all_tvs.push(id) }
                }, _ => {} }
            }
        }
    }

    let impl_m_effects = match declared_effects {
        some(de) => resolve_declared_effects(ctx, de),
        none => infer_hof_effect_row(param_types)
    }
    let fn_type = Type::FnType { params: param_types, return_type: ret, effects: impl_m_effects }
    collect_effect_tail_vars(fn_type, all_tvs)
    let scheme = make_impl_method_scheme_core(fn_type, all_tvs, none)

    // Track mut self methods
    if params.len() > 0 {
        match params.first() {
            some(first_p) => {
                if first_p.name == "self" && first_p.is_mutable {
                    let mut mut_set = match ctx.env.trait_reg.mut_methods.get(target_type) {
                        some(s) => s,
                        none => {
                            let mut new_set: Set<Str> = set_new()
                            ctx.env.trait_reg.mut_methods.insert(target_type, new_set)
                            new_set
                        }
                    }
                    mut_set.insert(mname)
                }
            },
            none => {}
        }
    }

    ctx.type_param_scope = saved_method
    scheme
}

// ============================================================
// Delegate registration
// ============================================================

pub fn impl_owner_fn_bounds(owner: ImplEntry) -> List<FnBoundsEntry> {
    let mut result: List<FnBoundsEntry> = []
    for predicate in frozen_impl_predicates(owner.predicates) {
        let index = impl_predicate_subject_param_index(predicate)
        let type_param_name = owner.type_params.get(index).unwrap_or("")
        if type_param_name == "" {
            panic("impl owner: predicate lost source parameter name")
        }
        let mut constraints: List<AssocConstraintEntry> = []
        for constraint in impl_predicate_assoc_constraints(predicate) {
            constraints.push(AssocConstraintEntry {
                name: impl_assoc_predicate_name(constraint),
                ty: impl_assoc_predicate_type(constraint)
            })
        }
        result.push(FnBoundsEntry {
            type_param_var_id: impl_predicate_subject_type_var(predicate),
            trait_name: impl_predicate_trait_name(predicate),
            type_param_name: type_param_name,
            assoc_constraints: constraints
        })
    }
    result
}

fn specialize_delegate_method_core(
    field_core: ImplMethodSchemeCore,
    field_var_map: Map<Int, Type>, self_type: Type,
    impl_tv_ids: List<Int>
) -> ImplMethodSchemeCore {
    let field_scheme = impl_method_core_as_scheme(field_core)
    let mapped_type = apply_subst_map(field_var_map, field_scheme.ty)
    let specialized_type = match mapped_type {
        Type::FnType { params, return_type, effects } => {
            let mut forwarded_params: List<Type> = []
            let mut first = true
            for param in params {
                if first {
                    forwarded_params.push(self_type)
                    first = false
                } else {
                    forwarded_params.push(param)
                }
            }
            Type::FnType {
                params: forwarded_params,
                return_type: return_type,
                effects: effects
            }
        },
        _ => mapped_type
    }

    let mut type_vars = list_clone(impl_tv_ids)
    for source_id in field_scheme.type_vars {
        let mapped_owner = apply_subst_map(field_var_map, Type::TypeVar {
            id: source_id, name: none
        })
        match mapped_owner {
            Type::TypeVar { id: mapped_id, .. } => {
                if !type_vars.contains(mapped_id) {
                    type_vars.push(mapped_id)
                }
            },
            _ => {}
        }
    }

    make_impl_method_scheme_core(specialized_type, type_vars, none)
}

fn delegate_constraint_lists_same(
    left: List<ImplAssocPredicate>, right: List<ImplAssocPredicate>
) -> Bool {
    if left.len() != right.len() { return false }
    for index in 0..left.len() {
        match (left.get(index), right.get(index)) {
            (some(a), some(b)) => {
                if impl_assoc_predicate_name(a) !=
                       impl_assoc_predicate_name(b) ||
                   !types_equal(impl_assoc_predicate_type(a),
                                impl_assoc_predicate_type(b)) {
                    return false
                }
            },
            _ => return false
        }
    }
    true
}

fn append_delegate_predicate(
    mut ctx: InferCtx, predicate: TypedImplPredicate,
    mut predicates: List<TypedImplPredicate>, span: Span
) {
    for existing in predicates {
        if impl_predicate_subject_param_index(existing) ==
               impl_predicate_subject_param_index(predicate) &&
           impl_predicate_trait_name(existing) ==
               impl_predicate_trait_name(predicate) {
            if !delegate_constraint_lists_same(
                impl_predicate_assoc_constraints(existing),
                impl_predicate_assoc_constraints(predicate)) {
                let _ = type_error(ctx.sink, E0503,
                    "Delegated impl predicate '${nominal_display_name(impl_predicate_trait_name(predicate))}' conflicts with wrapper owner",
                    span, DiagnosticContext::TraitError {
                        detail: "delegate predicate merge is not exact"
                    })
                fail.raise(CompileError {})
            }
            return
        }
    }
    predicates.push(predicate)
}

fn merge_delegate_owner_predicates(
    mut ctx: InferCtx, wrapper_owner: ImplEntry,
    field_owner: ImplEntry, field_var_map: Map<Int, Type>,
    wrapper_fn_bounds: List<FnBoundsEntry>, span: Span
) -> FrozenImplPredicateSet {
    let mut predicates = frozen_impl_predicates(wrapper_owner.predicates)
    for source in frozen_impl_predicates(field_owner.predicates) {
        let mapped_subject = apply_subst_map(
            field_var_map, Type::TypeVar {
                id: impl_predicate_subject_type_var(source), name: none
            })
        let mut constraints: List<ImplAssocPredicate> = []
        for constraint in impl_predicate_assoc_constraints(source) {
            constraints.push(make_impl_assoc_predicate(
                impl_assoc_predicate_name(constraint),
                apply_subst_map(
                    field_var_map, impl_assoc_predicate_type(constraint))))
        }
        match mapped_subject {
            Type::TypeVar { id, .. } => {
                let mut wrapper_index = -1
                for index in 0..wrapper_owner.type_param_vars.len() {
                    if wrapper_owner.type_param_vars.get(index).unwrap_or(-2) == id {
                        wrapper_index = index
                    }
                }
                if wrapper_index < 0 {
                    let _ = type_error(ctx.sink, E0503,
                        "Delegated impl predicate '${nominal_display_name(impl_predicate_trait_name(source))}' does not map to a wrapper type parameter",
                        span, DiagnosticContext::TraitError {
                            detail: "delegate predicate subject is not representable"
                        })
                    fail.raise(CompileError {})
                }
                append_delegate_predicate(ctx,
                    make_typed_impl_predicate(
                        wrapper_index, id,
                        impl_predicate_trait_name(source), constraints,
                        direct_impl_predicate_provenance()),
                    predicates, span)
            },
            _ => {
                if resolve_dict_ref_for_type(
                    ctx.env, wrapper_fn_bounds, mapped_subject,
                    ctx.subst, impl_predicate_trait_name(source)
                ).is_none() || !impl_predicate_constraints_satisfied(
                    ctx.env, wrapper_fn_bounds, mapped_subject,
                    impl_predicate_trait_name(source), constraints,
                    ctx.subst) {
                    let _ = type_error(ctx.sink, E0503,
                        "Delegated impl predicate '${nominal_display_name(impl_predicate_trait_name(source))}' is not satisfied by concrete owner '${type_to_string(mapped_subject)}'",
                        span, DiagnosticContext::TraitError {
                            detail: "delegate concrete predicate is not satisfied"
                        })
                    fail.raise(CompileError {})
                }
            }
        }
    }
    freeze_impl_predicate_set(wrapper_owner.type_param_vars, predicates)
}

fn register_delegate(
    mut ctx: InferCtx, wrapper_owner: ImplEntry,
    target_type: Str, field: Str, trait_names: List<Str>, span: Span,
    impl_type_params: List<TypeParam>, provider_ref: ImplProviderRef
) -> Bool {
    let mut had_semantic_error = false
    let wrapper_fn_bounds = impl_owner_fn_bounds(wrapper_owner)
    // 1. Validate field exists on target struct
    let target_display = nominal_display_name(target_type)
    match ctx.env.types.structs.get(target_type) {
        none => {
            had_semantic_error = true
            let _ = type_error(ctx.sink, E0507,
                "delegate can only be used on struct types, '${target_display}' is not a struct",
                span, DiagnosticContext::TraitError { detail: "delegate on non-struct type" })
        },
        some(struct_def) => {
            let impl_self_type = resolve_impl_self_type(
                ctx, target_type, impl_type_params)
            let mut declared_params: List<Type> = []
            let mut declared_index = 0
            for declared_id in struct_def.type_param_vars {
                let declared_name = match struct_def.type_params.get(declared_index) {
                    some(name) => some(name), none => none
                }
                declared_params.push(Type::TypeVar {
                    id: declared_id, name: declared_name
                })
                declared_index = declared_index + 1
            }
            let declared_self_type = Type::StructType {
                name: struct_def.name, type_params: declared_params
            }
            let field_owner_map = build_type_var_map(
                declared_self_type, impl_self_type,
                struct_def.type_param_vars)
            let mut field_type: Type? = none
            for f in struct_def.fields {
                if f.name == field {
                    field_type = some(apply_subst_map(field_owner_map, f.ty))
                }
            }
            match field_type {
                none => {
                    had_semantic_error = true
                    let _ = type_error(ctx.sink, E0507,
                        "field '${field}' not found in struct '${target_display}'",
                        span, DiagnosticContext::TraitError { detail: "delegate field not found" })
                },
                some(ft) => {
                    // Get the field type name for looking up trait impls
                    let mut field_type_name: Str? = none
                    match ft {
                        Type::StructType { name, .. } => { field_type_name = some(name) },
                        Type::EnumType { name, .. } => { field_type_name = some(name) },
                        _ => {
                            had_semantic_error = true
                            let _ = type_error(ctx.sink, E0507,
                                "delegate field '${field}' must have a named type (struct or enum)",
                                span, DiagnosticContext::TraitError { detail: "delegate field has unnamed type" })
                        }
                    }
                    match field_type_name {
                        none => {},
                        some(ftn) => {
                            if register_delegate_traits(
                                ctx, wrapper_owner, target_type,
                                field, trait_names, span,
                                wrapper_fn_bounds, impl_type_params, ftn, ft,
                                provider_ref) {
                                had_semantic_error = true
                            }
                        }
                    }
                }
            }
        }
    }
    had_semantic_error
}

fn register_delegate_traits(
    mut ctx: InferCtx, wrapper_owner: ImplEntry,
    target_type: Str, field: Str, trait_names: List<Str>, span: Span,
    wrapper_fn_bounds: List<FnBoundsEntry>,
    impl_type_params: List<TypeParam>, field_type_name: Str, ft: Type,
    provider_ref: ImplProviderRef
) -> Bool {
    let mut had_semantic_error = false
    for tname in trait_names {
        let canonical_trait = resolve_trait_identity(ctx, tname)
        let trait_display = nominal_display_name(canonical_trait)
        let field_type_display = nominal_display_name(field_type_name)
        let target_display = nominal_display_name(target_type)
        match ctx.env.trait_reg.traits.get(canonical_trait) {
            none => {
                had_semantic_error = true
                let _ = type_error(ctx.sink, E0501,
                    "Unknown trait: ${trait_display}",
                    span, DiagnosticContext::TraitError { detail: "unknown trait '${trait_display}'" })
            },
            some(trait_def) => {
                // Validate that the field type implements the trait
                if !has_impl(ctx.env.trait_reg, field_type_name, canonical_trait) {
                    had_semantic_error = true
                    let _ = type_error(ctx.sink, E0508,
                        "type '${field_type_display}' (field '${field}') does not implement trait '${trait_display}'",
                        span, DiagnosticContext::TraitError { detail: "delegate field type missing trait impl" })
                } else {
                    // Check for conflict: same trait already implemented (hand-written) for this type
                    if has_impl(ctx.env.trait_reg, target_type, canonical_trait) {
                        had_semantic_error = true
                        let _ = type_error(ctx.sink, E0509,
                            "trait '${trait_display}' is already implemented for '${target_display}'; cannot delegate the same trait",
                            span, DiagnosticContext::TraitError { detail: "delegate conflicts with existing impl" })
                        continue
                    }
                    // Collect all traits to register: the explicit trait + its supertraits
                    let mut all_traits_to_register: List<Str> = [canonical_trait]
                    let supers = collect_all_supertraits(ctx, canonical_trait)
                    for st_name in supers {
                        all_traits_to_register.push(st_name)
                    }

                    let self_type = resolve_impl_self_type(ctx, target_type, impl_type_params)

                    for reg_tname in all_traits_to_register {
                        // Check if this trait (or supertrait) is already implemented
                        if has_impl(ctx.env.trait_reg, target_type, reg_tname) { continue }

                        // Validate that the field type implements this trait
                        if !has_impl(ctx.env.trait_reg, field_type_name, reg_tname) {
                            had_semantic_error = true
                            continue
                        }

                        match ctx.env.trait_reg.traits.get(reg_tname) {
                            none => { had_semantic_error = true },
                            some(reg_trait_def) => {
                                let field_impl = find_impl(
                                    ctx.env.trait_reg, field_type_name, reg_tname)
                                let mut field_var_map: Map<Int, Type> = map_new()
                                match field_impl {
                                    some(found) => {
                                        // Derive one canonical source-impl-var
                                        // mapping from the exact field method
                                        // receiver and the wrapper's actual
                                        // field type (for example Source<A>
                                        // against Source<T>).
                                        for trait_method in reg_trait_def.methods {
                                            match found.method_schemes.get(
                                                trait_method.name) {
                                                some(field_core) => {
                                                    let field_scheme =
                                                        impl_method_core_as_scheme(
                                                            field_core)
                                                    match field_scheme.ty {
                                                        Type::FnType { params, .. } =>
                                                            match params.first() {
                                                                some(field_receiver) => {
                                                                    let candidate = build_type_var_map(
                                                                        field_receiver, ft,
                                                                        field_scheme.type_vars)
                                                                    let mut source_ids = candidate.keys()
                                                                    source_ids.sort()
                                                                    for source_id in source_ids {
                                                                        match candidate.get(source_id) {
                                                                            some(mapped) =>
                                                                                field_var_map.insert(
                                                                                    source_id, mapped),
                                                                            none => {}
                                                                        }
                                                                    }
                                                                },
                                                                none => {}
                                                            },
                                                        _ => {}
                                                    }
                                                },
                                                none => {}
                                            }
                                        }
                                    },
                                    none => {}
                                }

                                let mut field_assoc_types: Map<Str, Type> = map_new()
                                match field_impl {
                                    some(found) => {
                                        let mut assoc_entries = found.assoc_types.entries()
                                        assoc_entries.sort_by(compare_by_first)
                                        for assoc_entry in assoc_entries {
                                            let (assoc_name, assoc_type) = assoc_entry
                                            field_assoc_types.insert(
                                                assoc_name,
                                                apply_subst_map(
                                                    field_var_map, assoc_type))
                                        }
                                    },
                                    none => {}
                                }

                                let mut tp_names: List<Str> = []
                                for tp in impl_type_params { tp_names.push(tp.name) }
                                let delegated_predicates = match field_impl {
                                    some(found) => merge_delegate_owner_predicates(
                                        ctx, wrapper_owner, found,
                                        field_var_map, wrapper_fn_bounds, span),
                                    none => panic(
                                        "delegate registration: field owner disappeared")
                                }
                                let mut exact_method_schemes: Map<Str, ImplMethodSchemeCore> = map_new()

                                // Every forwarding scheme is the exact field
                                // scheme under the same structural mapping.
                                for tm in reg_trait_def.methods {
                                    let resolved_method_scheme = match field_impl {
                                        some(found) => found.method_schemes.get(tm.name),
                                        none => none
                                    }
                                    match resolved_method_scheme {
                                        some(field_core) => {
                                            let core = specialize_delegate_method_core(
                                                field_core, field_var_map,
                                                self_type,
                                                wrapper_owner.type_param_vars)
                                            exact_method_schemes.insert(tm.name, core)
                                        },
                                        none => {
                                            had_semantic_error = true
                                            let _ = type_error(ctx.sink, E0508,
                                                "type '${field_type_display}' has no exact '${nominal_display_name(reg_tname)}::${tm.name}' scheme to delegate",
                                                span, DiagnosticContext::TraitError {
                                                    detail: "delegate source method evidence is missing"
                                                })
                                        }
                                    }
                                }

                                let mut method_names = exact_method_schemes.keys()
                                method_names.sort()
                                let delegate_trait_ref =
                                    registered_trait_ref_symbol(
                                        reg_trait_def.owner_ref)
                                let delegate_target_ref = match
                                        impl_target_symbol(ctx.env, target_type) {
                                    some(symbol) => symbol,
                                    none => panic(
                                        "delegate owner: exact target symbol is missing")
                                }
                                let delegate_owner_ref = make_impl_owner_ref(
                                    delegate_target_ref, provider_ref,
                                    some(delegate_trait_ref))
                                let mut exact_method_refs:
                                    Map<Str, ImplMethodRef> = map_new()
                                for tm in reg_trait_def.methods {
                                    if exact_method_schemes.contains_key(tm.name) {
                                        let source_index =
                                            trait_method_ref_source_member_index(
                                                tm.method_ref)
                                        let callable_index =
                                            trait_method_ref_callable_slot_index(
                                                tm.method_ref)
                                        exact_method_refs.insert(
                                            tm.name, make_impl_method_ref(
                                                delegate_owner_ref,
                                                generated_impl_method_member(
                                                    provider_ref,
                                                    "delegate:${source_index}:${callable_index}"),
                                                source_index, callable_index,
                                                tm.name))
                                    }
                                }

                                add_impl(ctx.env.trait_reg, ImplEntry {
                                    trait_name: some(reg_tname),
                                    target_type_name: target_type,
                                    type_params: tp_names,
                                    type_param_vars: wrapper_owner.type_param_vars,
                                    predicates: delegated_predicates,
                                    method_names: method_names,
                                    assoc_types: map_clone(field_assoc_types),
                                    method_schemes: map_clone(exact_method_schemes),
                                    method_refs: exact_method_refs,
                                    method_intrinsics: map_new(),
                                    provider_ref: some(provider_ref),
                                    trait_ref: some(delegate_trait_ref),
                                    owner_ref: some(delegate_owner_ref),
                                    delegate_plan: delegate_plan_not_applicable(),
                                    span: span
                                })
                                let mut sorted_cores =
                                    exact_method_schemes.entries()
                                sorted_cores.sort_by(compare_by_first)
                                for core_entry in sorted_cores {
                                    let (method_name, core) = core_entry
                                    let _ = install_method_core(
                                        ctx.env.trait_reg, ctx.sink,
                                        target_type, method_name, core,
                                        exact_method_refs.get(
                                            method_name).unwrap(), span)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    had_semantic_error
}

fn expand_effect_exprs(mut ctx: InferCtx, decl_effects: List<EffectExpr>, mut expanding: Set<Str>) -> List<Effect> {
    let mut effects: List<Effect> = []
    for eff in decl_effects {
        match ctx.env.types.effect_aliases.get(eff.name) {
            some(alias_def) => {
                // Cycle detection
                if expanding.contains(eff.name) {
                    let effect_display = nominal_display_name(eff.name)
                    let _ = type_error(ctx.sink, E0406,
                        "Cyclic effect alias: '${effect_display}' references itself", eff.span,
                        DiagnosticContext::OtherContext { detail: some("cyclic effect alias") })
                } else {
                    expanding.insert(eff.name)

                    // Save any existing type_param_scope entries that alias type params might shadow
                    let mut saved_scope: List<(Str, Type?)> = []
                    let mut vi = 0
                    for tp_name in alias_def.type_params {
                        saved_scope.push((tp_name, ctx.type_param_scope.get(tp_name)))
                        // Install alias's fresh type vars into type_param_scope
                        match alias_def.type_param_vars.get(vi) {
                            some(var_id) => {
                                ctx.type_param_scope.insert(tp_name, Type::TypeVar { id: var_id, name: none })
                            },
                            none => {}
                        }
                        vi = vi + 1
                    }

                    // Recursively expand the alias body effects using the fresh type vars in scope
                    let expanded = expand_effect_exprs(ctx, alias_def.effects, expanding)

                    // Restore saved type_param_scope entries
                    for entry in saved_scope {
                        match entry {
                            (name, some(prev_type)) => { ctx.type_param_scope.insert(name, prev_type) },
                            (name, none) => { ctx.type_param_scope.remove(name) }
                        }
                    }

                    // Build substitution map: alias type_param_vars -> resolved call-site type args
                    let mut subst_map: Map<Int, Type> = map_new()
                    let mut si = 0
                    while si < alias_def.type_param_vars.len() && si < eff.type_args.len() {
                        match (alias_def.type_param_vars.get(si), eff.type_args.get(si)) {
                            (some(var_id), some(ta)) => {
                                subst_map.insert(var_id, resolve_type_expr(ctx, ta))
                            },
                            _ => {}
                        }
                        si = si + 1
                    }

                    // Apply type var substitution to each expanded effect
                    for e in expanded {
                        effects.push(apply_subst_effect_map(subst_map, e))
                    }

                    expanding.remove(eff.name)
                }
            },
            none => {
                effects.push(resolve_effect_expr(ctx, eff))
            }
        }
    }
    effects
}

fn collect_effect_tail_vars(ty: Type, mut vars: List<Int>) {
    match ty {
        Type::FnType { params, return_type, effects } => {
            match effects.tail {
                some(t_id) => {
                    if !vars.contains(t_id) { vars.push(t_id) }
                },
                none => {}
            }
            for p in params { collect_effect_tail_vars(p, vars) }
            collect_effect_tail_vars(return_type, vars)
        },
        Type::StructType { type_params, .. } => {
            for tp in type_params { collect_effect_tail_vars(tp, vars) }
        },
        Type::EnumType { type_params, .. } => {
            for tp in type_params { collect_effect_tail_vars(tp, vars) }
        },
        Type::TupleType { elements } => {
            for e in elements { collect_effect_tail_vars(e, vars) }
        },
        Type::GenericType { base, args } => {
            collect_effect_tail_vars(base, vars)
            for a in args { collect_effect_tail_vars(a, vars) }
        },
        _ => {}
    }
}

fn infer_hof_effect_row(param_types: List<Type>) -> EffectRow {
    for pt in param_types {
        match pt {
            Type::FnType { effects, .. } => match effects.tail {
                some(t_id) => { return EffectRow { effects: [], tail: some(t_id) } },
                none => {}
            },
            _ => {}
        }
    }
    EMPTY_ROW
}

pub fn resolve_declared_effects(mut ctx: InferCtx, decl_effects: List<EffectExpr>) -> EffectRow {
    let mut expanding: Set<Str> = set_new()
    let effects = expand_effect_exprs(ctx, decl_effects, expanding)
    // Deduplicate effects after alias expansion (e.g. {IO, io} -> [io, fail<Str>, io] -> [io, fail<Str>])
    let mut deduped: List<Effect> = []
    let mut seen: Set<Str> = set_new()
    for eff in effects {
        let key = effect_to_string(eff)
        if !seen.contains(key) {
            seen.insert(key)
            deduped.push(eff)
        }
    }
    EffectRow { effects: deduped, tail: none }
}

// ============================================================
// Function registration
// ============================================================

fn check_duplicate_def(ctx: InferCtx, name: Str, span: Span) {
    match ctx.env.lookup(name) {
        some(existing) => match existing.def_id {
            some(did) => match ctx.env.scope.def_spans.get(did) {
                some(_) => {
                    let display = nominal_display_name(name)
                    let _ = type_error(ctx.sink, E0207,
                        "Duplicate definition: '${display}' is already defined", span,
                        DiagnosticContext::TypeMismatch { expected: "unique name", actual: display, expression: none })
                },
                none => {}
            },
            none => {}
        },
        none => {}
    }
}

// Inject associated type variables into type_param_scope for type params with bounds.
// This makes T::Item references resolve during registration (Pass 1).
// Also resolves assoc_constraints (e.g., T: Trait<Item = Int>) by directly binding the
// associated type name to the concrete type.
pub fn inject_assoc_types_from_bounds(mut ctx: InferCtx, type_params: List<TypeParam>) {
    for tp in type_params {
        for b in tp.bounds {
            // First, handle explicit assoc constraints (Item = Int)
            for ac in b.assoc_constraints {
                let concrete_ty = resolve_type_expr(ctx, ac.ty)
                ctx.type_param_scope.insert(ac.name, concrete_ty)
                // Also insert into qualified_assoc_scope for disambiguation
                ctx.qualified_assoc_scope.insert("${tp.name}::${ac.name}", concrete_ty)
            }
            // Then, inject remaining associated types from trait definition
            match ctx.env.trait_reg.traits.get(b.trait_name) {
                some(tdef) => {
                    for atdef in tdef.assoc_types {
                        // Only inject if not already in scope (avoid overwriting constraints)
                        if !ctx.type_param_scope.contains_key(atdef.name) {
                            let at_var = ctx.env.fresh_var()
                            ctx.type_param_scope.insert(atdef.name, at_var)
                            ctx.qualified_assoc_scope.insert("${tp.name}::${atdef.name}", at_var)
                        } else {
                            // Already in scope (another type param's bound injected it).
                            // Still inject into qualified_assoc_scope with this type param's own fresh var.
                            let at_var = ctx.env.fresh_var()
                            ctx.qualified_assoc_scope.insert("${tp.name}::${atdef.name}", at_var)
                        }
                    }
                },
                none => {}
            }
        }
    }
}

// Shared helper for register_fn and register_extern_fn.
// - check_dup: call check_duplicate_def (true for fn, false for extern fn)
// - track_mut_params: track fn_mut_params (true for fn, false for extern fn)
// - track_fn_bounds: build fn_bounds_list and insert into scope (true for fn, false for extern fn)
fn register_fn_common(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    params: List<Param>, return_type: TypeExpr?, declared_effects: List<EffectExpr>?,
    span: Span, check_dup: Bool, track_mut_params: Bool, track_fn_bounds: Bool
) {
    validate_type_param_bound_shapes(
        ctx, type_params, BoundShapeContext::OrdinaryBound, span)
    if check_dup { check_duplicate_def(ctx, name, span) }

    let mut type_vars: List<Int> = []
    let saved = map_clone(ctx.type_param_scope)
    let saved_qualified = map_clone(ctx.qualified_assoc_scope)
    for tp in type_params {
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { type_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }

    // Inject associated types from type param bounds into type_param_scope
    // so that T::Item references in return types / param types resolve correctly.
    inject_assoc_types_from_bounds(ctx, type_params)

    let mut param_types: List<Type> = []
    if track_mut_params {
        let mut mut_flags: List<Bool> = []
        for p in params {
            let pt = match p.type_annotation {
                some(ta) => resolve_type_expr(ctx, ta),
                none => ctx.env.fresh_var()
            }
            param_types.push(pt)
            // Register fn_mut_params: only flag mut value-type params (not self)
            if p.name == "self" || !p.is_mutable {
                mut_flags.push(false)
            } else {
                mut_flags.push(is_value_type(pt))
            }
        }
        ctx.fn_mut_params.insert(name, mut_flags)
    } else {
        for p in params {
            match p.type_annotation {
                some(ta) => param_types.push(resolve_type_expr(ctx, ta)),
                none => param_types.push(ctx.env.fresh_var())
            }
        }
    }
    let ret = match return_type { some(rt) => resolve_type_expr(ctx, rt), none => ctx.env.fresh_var() }

    let mut declared_names: Set<Str> = set_new()
    for tp in type_params { declared_names.insert(tp.name) }
    let mut sorted_tp_scope3 = ctx.type_param_scope.entries()
    sorted_tp_scope3.sort_by(compare_by_first)
    for entry in sorted_tp_scope3 {
        let (tpname, tv) = entry
        if !saved.contains_key(tpname) && !declared_names.contains(tpname) {
            match tv { Type::TypeVar { id, .. } => { type_vars.push(id) }, _ => {} }
        }
    }

    let effects = match declared_effects {
        some(de) => resolve_declared_effects(ctx, de),
        none => infer_hof_effect_row(param_types)
    }
    let fn_type = Type::FnType { params: param_types, return_type: ret, effects: effects }
    collect_effect_tail_vars(fn_type, type_vars)

    let mut fn_bounds_list: List<FnBound> = []
    let mut scheme_bounds: List<SchemeBound> = []
    for tp in type_params {
        let tv = ctx.type_param_scope.get(tp.name)
        for b in tp.bounds {
            let bound_trait = resolve_trait_identity(ctx, b.trait_name)
            if !ctx.env.trait_reg.traits.contains_key(bound_trait) {
                let trait_display = nominal_display_name(bound_trait)
                let _ = type_error(ctx.sink, E0501,
                    "Unknown trait: ${trait_display}", tp.span,
                    DiagnosticContext::TraitError { detail: "unknown trait '${trait_display}'" })
            }
            if track_fn_bounds {
                fn_bounds_list.push(FnBound { type_param: tp.name, trait_name: bound_trait })
            }
            // Build associated type constraint entries from bound's assoc_constraints
            let mut assoc_entries: List<AssocConstraintEntry> = []
            for ac in b.assoc_constraints {
                let concrete_ty = resolve_type_expr(ctx, ac.ty)
                assoc_entries.push(AssocConstraintEntry { name: ac.name, ty: concrete_ty })
            }
            // B-100 Fix 3: also record IMPLICIT associated type vars from the
            // trait definition.  When the scheme is instantiated at a call site,
            // check_assoc_constraints unifies these TypeVars with the concrete
            // associated types from the impl, so that return types depending on
            // associated types (e.g. T::Item) resolve to concrete types.
            match ctx.env.trait_reg.traits.get(bound_trait) {
                some(tdef) => {
                    for atdef in tdef.assoc_types {
                        let already = assoc_entries.any(fn(e) { e.name == atdef.name })
                        if !already {
                            let qk = "${tp.name}::${atdef.name}"
                            match ctx.qualified_assoc_scope.get(qk) {
                                some(at_var) => assoc_entries.push(AssocConstraintEntry { name: atdef.name, ty: at_var }),
                                none => {},
                            }
                        }
                    }
                },
                none => {},
            }
            match tv {
                some(t) => match t { Type::TypeVar { id, .. } => {
                    scheme_bounds.push(SchemeBound { type_var: id, trait_name: bound_trait, assoc_constraints: assoc_entries })
                }, _ => {} },
                none => {}
            }
            // Expand supertrait bounds: if T: Ord and Ord: Eq, add T: Eq too
            let supers = collect_all_supertraits(ctx, bound_trait)
            for st_name in supers {
                if track_fn_bounds {
                    fn_bounds_list.push(FnBound { type_param: tp.name, trait_name: st_name })
                }
                match tv {
                    some(t) => match t { Type::TypeVar { id, .. } => {
                        scheme_bounds.push(SchemeBound { type_var: id, trait_name: st_name, assoc_constraints: [] })
                    }, _ => {} },
                    none => {}
                }
            }
        }
    }
    if track_fn_bounds && fn_bounds_list.len() > 0 {
        ctx.env.scope.fn_bounds.insert(name, fn_bounds_list)
    }

    ctx.type_param_scope = saved
    ctx.qualified_assoc_scope = saved_qualified

    if type_vars.len() > 0 {
        ctx.env.bind(name, TypeScheme { ty: fn_type, type_vars: type_vars, bounds: scheme_bounds, def_id: none })
    } else {
        ctx.env.bind_mono(name, fn_type)
    }
    let callable_kind = if track_fn_bounds {
        ValueBindingKind::DirectCallable
    } else {
        ValueBindingKind::ExternCallable
    }
    record_value_binding_kind(ctx, name, callable_kind)
    match ctx.env.lookup(name) {
        some(s) => match s.def_id { some(did) => ctx.env.record_def_span(did, span), none => {} },
        none => {}
    }
}

fn register_fn(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, params: List<Param>, return_type: TypeExpr?, declared_effects: List<EffectExpr>?, span: Span) {
    register_fn_common(ctx, name, type_params, params, return_type, declared_effects, span, true, true, true)
}

fn register_extern_fn(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, params: List<Param>, return_type: TypeExpr?, declared_effects: List<EffectExpr>?, span: Span) {
    register_fn_common(ctx, name, type_params, params, return_type, declared_effects, span, false, false, false)
}

fn register_extern_type_common(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    span: Span, install_visible_name: Bool, decl_index: Int
) {
    validate_type_param_bound_shapes(
        ctx, type_params, BoundShapeContext::OrdinaryBound, span)
    let identity = peek_struct_identity_fact(ctx, decl_index, true, 0)
    let mut tp_names: List<Str> = []
    let saved = map_clone(ctx.type_param_scope)
    let mut tp_vars: List<Int> = []
    for tp in type_params {
        tp_names.push(tp.name)
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }
    ctx.type_param_scope = saved
    // is_extern: true marks this as an opaque FFI type so trait derivation skips
    // it (B-074). An opaque type has no fields to compare/clone/order/debug, and
    // a derived dict would reference a non-existent runtime constructor.
    let def = StructDef { name: name,
        owner_ref: make_registered_nominal_ref(identity.owner_ref, name),
        type_params: tp_names, type_param_vars: tp_vars, fields: [],
        derive_attrs: [], derived_provider_plan: none, is_extern: true }
    commit_struct_identity_fact(ctx, identity, false)
    if install_visible_name {
        ctx.env.types.structs.insert(name, def)
    }
    ctx.env.types.extern_structs.insert(name, def)
}

fn register_project_extern_type(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    span: Span, decl_index: Int
) {
    register_extern_type_common(
        ctx, name, type_params, span, false, decl_index)
}

fn register_extern_type(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    span: Span, decl_index: Int
) {
    register_extern_type_common(
        ctx, name, type_params, span, true, decl_index)
}

fn register_type_alias(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>,
    type_expr: TypeExpr, span: Span
) {
    validate_type_param_bound_shapes(
        ctx, type_params, BoundShapeContext::OrdinaryBound, span)
    let saved = map_clone(ctx.type_param_scope)
    let mut tp_vars: List<Int> = []
    for tp in type_params {
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }
    let resolved = resolve_type_expr(ctx, type_expr)
    ctx.type_param_scope = saved
    let mut tp_names: List<Str> = []
    for tp in type_params { tp_names.push(tp.name) }
    ctx.env.types.type_aliases.insert(name, TypeAliasDef { name: name, type_params: tp_names, type_param_vars: tp_vars, ty: resolved })
}

fn register_const(mut ctx: InferCtx, name: Str, type_annotation: TypeExpr?, span: Span) {
    check_duplicate_def(ctx, name, span)
    match type_annotation {
        some(texpr) => {
            let ty = resolve_type_expr(ctx, texpr)
            ctx.env.bind_mono(name, ty)
        },
        none => {
            let tv = ctx.env.fresh_var()
            ctx.env.bind_mono(name, tv)
        }
    }
    match ctx.env.lookup(name) {
        some(s) => match s.def_id { some(did) => ctx.env.record_def_span(did, span), none => {} },
        none => {}
    }
    record_value_binding_kind(ctx, name, ValueBindingKind::ConstGetter)
}

// ============================================================
// Effect alias registration
// ============================================================

fn canonicalize_effect_alias_body(ctx: InferCtx, effects: List<EffectExpr>) -> List<EffectExpr> {
    let mut result: List<EffectExpr> = []
    for eff in effects {
        let canonical_name = match ctx.env.types.effects.get(eff.name) {
            some(def) => def.name,
            none => match ctx.env.types.effect_aliases.get(eff.name) {
                some(def) => def.name,
                none => eff.name
            }
        }
        result.push(EffectExpr { name: canonical_name, type_args: eff.type_args, span: eff.span })
    }
    result
}

fn register_effect_alias(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, effects: List<EffectExpr>, span: Span) {
    validate_type_param_bound_shapes(
        ctx, type_params, BoundShapeContext::OrdinaryBound, span)
    if ctx.env.types.effect_aliases.contains_key(name) {
        let display = nominal_display_name(name)
        let _ = type_error(ctx.sink, E0207,
            "Duplicate definition: effect alias '${display}' is already defined", span,
            DiagnosticContext::OtherContext { detail: some("duplicate effect alias") })
    } else {
        let mut tp_names: List<Str> = []
        let mut tp_vars: List<Int> = []
        for tp in type_params {
            tp_names.push(tp.name)
            let tv = ctx.env.fresh_var()
            match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        }
        let canonical_effects = canonicalize_effect_alias_body(ctx, effects)
        ctx.env.types.effect_aliases.insert(name, EffectAliasDef {
            name: name,
            type_params: tp_names,
            type_param_vars: tp_vars,
            effects: canonical_effects,
            span: span
        })
    }
}

// ============================================================
// Dispatch: register individual declaration
// ============================================================

fn register_decl(mut ctx: InferCtx, decl: Decl, decl_index: Int) {
    match decl {
        Decl::Struct { name, type_params, fields, derive_attrs, span, .. } => {
            preregister_struct(
                ctx, name, type_params, derive_attrs,
                span, decl_index, fields.len())
            complete_struct_fields(ctx, name, fields)
        },
        Decl::Enum { name, type_params, variants, derive_attrs, span, .. } => {
            preregister_enum(
                ctx, name, type_params, variants,
                derive_attrs, span, decl_index)
            complete_enum_variants(ctx, name, type_params, variants)
        },
        Decl::Effect { name, type_params, ops, span, .. } =>
            register_effect(ctx, name, type_params, ops, span, decl_index),
        Decl::Impl { target_type, type_params, trait_name, methods, span } =>
            register_impl(
                ctx, target_type, type_params, trait_name, methods, span,
                decl_index),
        Decl::Fn { name, type_params, params, return_type, declared_effects, span, .. } =>
            register_fn(ctx, name, type_params, params, return_type, declared_effects, span),
        Decl::Test { .. } => {},
        Decl::Trait { name, type_params, supertraits, methods, span, .. } =>
            register_trait(
                ctx, name, type_params, supertraits, methods, span,
                decl_index),
        Decl::ExternFn { name, type_params, params, return_type, declared_effects, span, .. } =>
            register_extern_fn(ctx, name, type_params, params, return_type, declared_effects, span),
        Decl::ExternType { name, type_params, span, .. } =>
            register_extern_type(ctx, name, type_params, span, decl_index),
        Decl::TypeAlias { name, type_params, type_expr, span, .. } =>
            register_type_alias(ctx, name, type_params, type_expr, span),
        Decl::Const { name, type_annotation, span, .. } =>
            register_const(ctx, name, type_annotation, span),
        Decl::EffectAlias { name, type_params, effects, span, .. } =>
            register_effect_alias(ctx, name, type_params, effects, span),
        Decl::Delegate { .. } => {},  // Only valid inside impl blocks, handled by register_impl
        Decl::AssocType { .. } => {},  // Only valid inside trait/impl blocks
        Decl::ModBlock { name: mod_name, uses: mod_uses, decls: mod_decls, .. } => {
            enter_struct_identity_child_frame(ctx, decl_index)
            register_mod_block_items(ctx, mod_name, mod_uses, mod_decls, none, none)
            exit_struct_identity_frame(ctx)
        }
    }
}
