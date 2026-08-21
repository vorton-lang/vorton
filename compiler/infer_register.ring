use types::{Type, Effect, EffectRow, StructField, EnumVariant,
    EMPTY_ROW, effects_same_kind, type_to_builtin_name, type_to_string, effect_to_string, nominal_display_name}
use ast::{Decl, Span, TypeParam, Param, TypeExpr, EffectOpDecl, StructFieldDecl,
    EnumVariantDecl, NamedEnumField, TypeBound, span_zero, EffectExpr, SigMember,
    UseDecl, UseImport, DeriveAttribute}
use env::{TypeEnv, TypeScheme, SchemeBound, AssocConstraintEntry, StructDef, EnumDef, EffectDef, EffectOpDef,
    TraitDef, TraitMethodDef, ImplEntry, ImplDictBound, TypeAliasDef, FnBound, SigDef,
    EffectAliasDef, AssocTypeDef, MethodOrigin, mono, apply_subst, apply_subst_effect_map,
    apply_subst_map, add_impl, has_impl, find_impl, impl_origin, impl_decl_origin,
    install_method_scheme, specialize_trait_method_scheme, build_type_var_map}
use diagnostics::{DiagnosticContext}
use codes::{E0207, E0406, E0501, E0502, E0503, E0504, E0505, E0506, E0507, E0508, E0509, E0510, E0511, E0513, E0514}
use hir::{compare_by_first, module_item_identity, variant_ctor_name, ValueBindingKind}
use infer_ctx::{InferCtx, FnBoundsEntry, CompileError, type_error, resolve_type_expr, resolve_self_type, resolve_effect_expr,
    record_value_origin, record_variant_ctor_origin, record_value_binding_kind,
    resolve_dict_ref_for_type,
    resolve_mod_uses, bind_exact_import_alias,
    enter_project_root_frame, enter_project_child_frame,
    refresh_project_namespace_frame, exit_project_namespace_frame}
use infer_helpers::{is_value_type}

// ============================================================
// Public entry points
// ============================================================

pub fn register_decl_public(mut ctx: InferCtx, decl: Decl) {
    register_decl(ctx, decl)
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
            Decl::Sig { name, .. } => {
                let qualified = "${mod_name}::${name}"
                if !guard || !ctx.env.types.sigs.contains_key(name) {
                    match ctx.env.types.sigs.get(qualified) {
                        some(def) => { ctx.env.types.sigs.insert(name, def) },
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
        Decl::Sig { name, members, is_pub, span } =>
            Decl::Sig { name: "${mod_name}::${name}", members: members, is_pub: is_pub, span: span },
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
        Decl::Sig { name, members, is_pub, span } =>
            Decl::Sig { name: module_item_identity(module_prefix, name), members: members, is_pub: is_pub, span: span },
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
    TypeAliasSigPhase,
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
        ProjectRegistrationPhase::TypeAliasSigPhase => match decl {
            // Keep aliases and signatures in one source-ordered frame pass.
            Decl::TypeAlias { .. } | Decl::Sig { .. } => true,
            _ => false
        },
        ProjectRegistrationPhase::ValuePhase => match decl {
            Decl::Struct { .. } | Decl::Enum { .. } |
            Decl::Trait { .. } | Decl::Effect { .. } |
            Decl::EffectAlias { .. } | Decl::ExternType { .. } |
            Decl::TypeAlias { .. } | Decl::Sig { .. } |
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

    // Pass 1a: register struct/enum types first
    for d in mod_decls {
        match d {
            Decl::Struct { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
            },
            Decl::Enum { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
            },
            _ => {}
        }
    }
    // Incremental aliases: struct/enum short names available for trait bounds
    insert_mod_aliases(ctx, mod_name, mod_decls, true)
    // Pass 1b-1: traits -- alias after each so supertraits resolve by short name (#83)
    for d in mod_decls {
        match d {
            Decl::Trait { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
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
    for d in mod_decls {
        match d {
            Decl::Effect { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
            },
            _ => {}
        }
    }
    insert_mod_aliases(ctx, mod_name, mod_decls, true)
    // Pass 1b-3: effect aliases remain source ordered so an earlier alias may
    // feed a later alias, but every body sees all concrete effects above.
    for d in mod_decls {
        match d {
            Decl::EffectAlias { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
                insert_mod_aliases(ctx, mod_name, mod_decls, true)
            },
            _ => {}
        }
    }
    // Pass 1b-4: opaque extern types.
    for d in mod_decls {
        match d {
            Decl::ExternType { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
            },
            _ => {}
        }
    }
    // Pass 1b-5: aliases/signatures must exist before any value declaration
    // resolves its parameter/return types. Refresh short aliases after each
    // declaration so source-ordered alias chains can feed the next alias;
    // functions remain declaration-order independent from all aliases.
    for d in mod_decls {
        match d {
            Decl::TypeAlias { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
                insert_mod_aliases(ctx, mod_name, mod_decls, true)
            },
            Decl::Sig { .. } => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
                insert_mod_aliases(ctx, mod_name, mod_decls, true)
            },
            _ => {}
        }
    }
    // Final aliases: all names available for remaining declarations
    insert_mod_aliases(ctx, mod_name, mod_decls, true)
    // Pass 2: register everything else (functions, impls, consts, etc.)
    for d in mod_decls {
        match d {
            Decl::Struct { .. } => {},
            Decl::Enum { .. } => {},
            Decl::Trait { .. } => {},
            Decl::Effect { .. } => {},
            Decl::EffectAlias { .. } => {},
            Decl::ExternType { .. } => {},
            Decl::TypeAlias { .. } => {},
            Decl::Sig { .. } => {},
            Decl::ModBlock { .. } => {},
            _ => {
                let prefixed = prefix_decl_name(mod_name, d)
                register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
            }
        }
    }
    for d in order_inline_mod_blocks(mod_decls) {
        let prefixed = prefix_decl_name(mod_name, d)
        register_mod_item(ctx, prefixed, deferred_struct_names, deferred_enum_names)
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
        Decl::ExternType { name, type_params, .. } => {
            register_project_extern_type(ctx, name, type_params)
        },
        Decl::ModBlock { .. } =>
            panic("unreachable: project ModBlock reached local phase dispatcher"),
        _ => {
            let prefixed = prefix_decl_name(mod_name, item.decl)
            register_phase1(
                ctx, prefixed, deferred_struct_names, deferred_enum_names)
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
    mut ctx: InferCtx, decl: Decl,
    deferred_struct_names: List<Str>?, deferred_enum_names: List<Str>?
) {
    match deferred_struct_names {
        some(dsn) => match deferred_enum_names {
            some(den) => register_phase1(ctx, decl, dsn, den),
            none => register_decl(ctx, decl)
        },
        none => register_decl(ctx, decl)
    }
}

fn register_phase1(mut ctx: InferCtx, decl: Decl, mut deferred_struct_names: List<Str>, mut deferred_enum_names: List<Str>) {
    match decl {
        Decl::Struct { name, type_params, fields, derive_attrs, span, .. } => {
            preregister_struct(ctx, name, type_params, derive_attrs)
            deferred_struct_names.push(name)
        },
        Decl::Enum { name, type_params, variants, derive_attrs, span, .. } => {
            preregister_enum(ctx, name, type_params, derive_attrs)
            deferred_enum_names.push(name)
        },
        Decl::ModBlock { name: mod_name, uses: mod_uses, decls: mod_decls, .. } => {
            register_mod_block_items(ctx, mod_name, mod_uses, mod_decls, some(deferred_struct_names), some(deferred_enum_names))
        },
        _ => register_decl(ctx, decl)
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
    ctx.file_extern_types = set_new()
    for decl in decls {
        match decl {
            Decl::ExternType { name, .. } => { ctx.file_extern_types.insert(name) },
            _ => {}
        }
    }
    let mut deferred_struct_names: List<Str> = []
    let mut deferred_enum_names: List<Str> = []

    for decl in decls {
        let result = some(register_phase1(
            ctx, decl, deferred_struct_names,
            deferred_enum_names)) catch { _ => none }
    }

    for decl in decls {
        let result = some(register_phase2_struct(ctx, decl)) catch { _ => none }
    }
    for decl in decls {
        let result = some(register_phase2_enum(ctx, decl)) catch { _ => none }
    }

    // Phase 3: process delegates (after struct/enum fields are complete)
    for decl in decls {
        register_phase3_delegate(ctx, decl)
    }
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
        Decl::ExternType { name, type_params, .. } =>
            register_project_extern_type(ctx, name, type_params),
        Decl::ModBlock { .. } =>
            panic("unreachable: project ModBlock reached root local dispatcher"),
        _ => register_phase1(
            ctx, item.decl,
            deferred_struct_names, deferred_enum_names)
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
            project_push_mod_path(ctx, name)
            for child in index_decls(decls) {
                let qualified_child = IndexedDecl {
                    decl_index: child.decl_index,
                    decl: prefix_decl_name(name, child.decl)
                }
                register_project_phase3_delegate(ctx, qualified_child)
            }
            let _ = ctx.mod_path_stack.pop()
            let _ = exit_project_namespace_frame(ctx)
        },
        _ => {
            register_phase3_delegate(ctx, item.decl)
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
        ProjectRegistrationPhase::TypeAliasSigPhase)
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
    let _ = exit_project_namespace_frame(ctx)

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
    let mut qualified: List<Decl> = []
    for decl in decls { qualified.push(module_prefix_decl_name(module_prefix, decl)) }

    let mut deferred_struct_names: List<Str> = []
    let mut deferred_enum_names: List<Str> = []

    // Nominal declarations must all exist before any field/payload/signature is
    // resolved.  Their alias keys are display names; StructDef/EnumDef.name is
    // already canonical and therefore drives unification and backend metadata.
    for decl in qualified {
        match decl {
            Decl::Struct { .. } => register_phase1(ctx, decl, deferred_struct_names, deferred_enum_names),
            Decl::Enum { .. } => register_phase1(ctx, decl, deferred_struct_names, deferred_enum_names),
            _ => {}
        }
    }
    insert_file_module_aliases(ctx, module_prefix, decls, false)

    // Match inline-module registration ordering: traits first, then effects and
    // opaque/type declarations, then values and impls.
    for decl in qualified {
        match decl {
            Decl::Trait { .. } => {
                register_phase1(ctx, decl, deferred_struct_names, deferred_enum_names)
                insert_file_module_aliases(ctx, module_prefix, decls, false)
            },
            _ => {}
        }
    }
    // Install all concrete effects before canonicalizing any effect-alias body.
    // The alias body must capture this module's exact effect identity rather
    // than retain a raw leaf that a downstream decoy can rebind.
    for decl in qualified {
        match decl {
            Decl::Effect { .. } => register_phase1(ctx, decl, deferred_struct_names, deferred_enum_names),
            _ => {}
        }
    }
    insert_file_module_aliases(ctx, module_prefix, decls, false)
    for decl in qualified {
        match decl {
            Decl::EffectAlias { .. } => {
                register_phase1(ctx, decl, deferred_struct_names, deferred_enum_names)
                insert_file_module_aliases(ctx, module_prefix, decls, false)
            },
            _ => {}
        }
    }
    for decl in qualified {
        match decl {
            Decl::ExternType { .. } => register_phase1(ctx, decl, deferred_struct_names, deferred_enum_names),
            Decl::TypeAlias { .. } => register_phase1(ctx, decl, deferred_struct_names, deferred_enum_names),
            Decl::Sig { .. } => register_phase1(ctx, decl, deferred_struct_names, deferred_enum_names),
            _ => {}
        }
    }
    insert_file_module_aliases(ctx, module_prefix, decls, false)
    for decl in qualified {
        match decl {
            Decl::Struct { .. } => {}, Decl::Enum { .. } => {}, Decl::Trait { .. } => {},
            Decl::Effect { .. } => {}, Decl::EffectAlias { .. } => {},
            Decl::ExternType { .. } => {}, Decl::TypeAlias { .. } => {}, Decl::Sig { .. } => {},
            Decl::ModBlock { .. } => {},
            _ => register_phase1(ctx, decl, deferred_struct_names, deferred_enum_names)
        }
    }
    for decl in order_inline_mod_blocks(qualified) {
        register_phase1(ctx, decl, deferred_struct_names, deferred_enum_names)
    }

    for decl in qualified { register_phase2_struct(ctx, decl) }
    for decl in qualified { register_phase2_enum(ctx, decl) }
    for decl in qualified { register_phase3_delegate(ctx, decl) }

    // Value schemes exist only after the final registration pass.  Binding the
    // short alias and recording its canonical origin makes HExpr::Ident exact.
    insert_file_module_aliases(ctx, module_prefix, decls, true)
    qualified
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
            Decl::Sig { name, .. } => {
                let canonical = module_item_identity(module_prefix, name)
                match ctx.env.types.sigs.get(canonical) {
                    some(def) => { ctx.env.types.sigs.insert(name, def) }, none => {}
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
            Decl::Sig { name, .. } => {
                let display = "${display_mod}::${name}"
                let canonical = "${canonical_mod}::${name}"
                match ctx.env.types.sigs.get(canonical) {
                    some(def) => { ctx.env.types.sigs.insert(display, def) }, none => {}
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

struct NormalizedImplBounds {
    scheme_bounds: List<SchemeBound>,
    dict_bounds: List<ImplDictBound>
}

// Keep method-scheme evidence and ImplEntry's runtime dictionary requirements
// in one canonical order. General impl registration retains the legacy shape
// that cannot carry TypeBound type_args or assoc_constraints; iteration
// protocol impls reject those predicates before reaching this normalization.
fn normalize_impl_bounds(
    ctx: InferCtx, type_params: List<TypeParam>, impl_tv_ids: List<Int>
) -> NormalizedImplBounds {
    let mut scheme_bounds: List<SchemeBound> = []
    let mut dict_bounds: List<ImplDictBound> = []
    let mut tp_idx = 0
    for tp in type_params {
        for b in tp.bounds {
            if tp_idx < impl_tv_ids.len() {
                let tv_id = impl_tv_ids.get(tp_idx).unwrap()
                let bound_trait = resolve_trait_identity(ctx, b.trait_name)
                scheme_bounds.push(SchemeBound {
                    type_var: tv_id,
                    trait_name: bound_trait,
                    assoc_constraints: []
                })
                dict_bounds.push(ImplDictBound {
                    type_param_index: tp_idx,
                    trait_name: bound_trait
                })
                let supers = collect_all_supertraits(ctx, bound_trait)
                for st_name in supers {
                    scheme_bounds.push(SchemeBound {
                        type_var: tv_id,
                        trait_name: st_name,
                        assoc_constraints: []
                    })
                    dict_bounds.push(ImplDictBound {
                        type_param_index: tp_idx,
                        trait_name: st_name
                    })
                }
            }
        }
        tp_idx = tp_idx + 1
    }
    NormalizedImplBounds {
        scheme_bounds: scheme_bounds,
        dict_bounds: dict_bounds
    }
}

fn register_phase3_delegate(mut ctx: InferCtx, decl: Decl) {
    match decl {
        Decl::Impl { target_type, type_params, methods, span, .. } => {
            // Check if any methods are delegates
            let mut has_delegates = false
            for m in methods {
                match m { Decl::Delegate { .. } => { has_delegates = true }, _ => {} }
            }
            if has_delegates {
                // Reconstruct the impl type-parameter scope for registration.
                let saved = map_clone(ctx.type_param_scope)
                let mut impl_tv_ids: List<Int> = []
                for tp in type_params {
                    let tv = ctx.env.fresh_var()
                    match tv { Type::TypeVar { id, .. } => { impl_tv_ids.push(id) }, _ => {} }
                    ctx.type_param_scope.insert(tp.name, tv)
                }

                let impl_bounds = normalize_impl_bounds(ctx, type_params, impl_tv_ids)

                let canonical_target = resolve_nominal_identity(ctx, target_type)
                for m in methods {
                    match m {
                        Decl::Delegate { field, trait_names, span: dspan } => {
                            register_delegate(ctx, impl_tv_ids, canonical_target,
                                field, trait_names, dspan,
                                impl_bounds.scheme_bounds, impl_bounds.dict_bounds,
                                type_params)
                        },
                        _ => {}
                    }
                }

                ctx.type_param_scope = saved
            }
        },
        Decl::ModBlock { name: mod_name, decls: mod_decls, .. } => {
            for d in mod_decls {
                let prefixed = prefix_decl_name(mod_name, d)
                register_phase3_delegate(ctx, prefixed)
            }
        },
        _ => {}
    }
}

// ============================================================
// Struct registration
// ============================================================

fn preregister_struct(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, derive_attrs: List<DeriveAttribute>) {
    let mut tp_names: List<Str> = []
    let mut tp_vars: List<Int> = []
    for tp in type_params {
        tp_names.push(tp.name)
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tp_vars.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }
    let def = StructDef { name: name, type_params: tp_names, type_param_vars: tp_vars, fields: [], derive_attrs: derive_attrs, is_extern: false }
    ctx.env.types.structs.insert(name, def)
}

fn complete_struct_fields(mut ctx: InferCtx, name: Str, fields: List<StructFieldDecl>) {
    match ctx.env.types.structs.get(name) {
        some(def) => {
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
            for f in fields {
                def.fields.push(StructField {
                    name: f.name,
                    ty: resolve_type_expr(ctx, f.type_annotation),
                    is_pub: f.is_pub
                })
            }
            ctx.type_param_scope = saved
        },
        none => {}
    }
}

// ============================================================
// Enum registration
// ============================================================

fn preregister_enum(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, derive_attrs: List<DeriveAttribute>) {
    let mut tp_names: List<Str> = []
    let mut tv_ids: List<Int> = []
    for tp in type_params {
        tp_names.push(tp.name)
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { tv_ids.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }
    let def = EnumDef { name: name, type_params: tp_names, type_param_vars: tv_ids, variants: [], derive_attrs: derive_attrs, variant_index: map_new() }
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

fn register_effect(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, ops: List<EffectOpDecl>) {
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
        effect_ops.push(EffectOpDef { name: op.name, params: param_types, return_type: ret, has_default: op_has_default })
    }
    let mut all_defaults = true
    for eop in effect_ops {
        if !eop.has_default { all_defaults = false }
    }
    if effect_ops.len() == 0 { all_defaults = false }
    ctx.type_param_scope = saved
    ctx.env.types.effects.insert(name, EffectDef { name: name, type_params: tp_names, type_param_vars: tp_vars, ops: effect_ops, built_in_kind: none, all_have_defaults: all_defaults })
}

// ============================================================
// Trait registration
// ============================================================

// Recursively collect all supertraits (transitive closure).
// For example, if Top: Mid, Mid: Base, then collect_all_supertraits(_, "Top") = ["Mid", "Base"]
pub fn collect_all_supertraits(ctx: InferCtx, trait_name: Str) -> List<Str> {
    let mut result: List<Str> = []
    let mut visited: Set<Str> = set_new()
    let mut stack: List<Str> = []
    match ctx.env.trait_reg.traits.get(trait_name) {
        some(tdef) => {
            for st in tdef.supertraits { stack.push(st) }
        },
        none => {}
    }
    while stack.len() > 0 {
        let current = stack.pop().unwrap()
        if visited.contains(current) { continue }
        visited.insert(current)
        result.push(current)
        match ctx.env.trait_reg.traits.get(current) {
            some(parent_def) => {
                for parent_st in parent_def.supertraits {
                    stack.push(parent_st)
                }
            },
            none => {}
        }
    }
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

fn register_trait(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, supertraits: List<TypeBound>, methods: List<Decl>, span: Span) {
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
        if !ctx.env.trait_reg.traits.contains_key(st.trait_name) {
            let trait_display = nominal_display_name(st.trait_name)
            let _ = type_error(ctx.sink, E0501,
                "Unknown supertrait: ${trait_display}", span,
                DiagnosticContext::TraitError { detail: "unknown supertrait '${trait_display}'" })
        } else {
            supertrait_names.push(resolve_trait_identity(ctx, st.trait_name))
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
                    bound_names.push(resolve_trait_identity(ctx, b.trait_name))
                }
                let default_ty = match avalue {
                    some(v) => some(resolve_type_expr(ctx, v)),
                    none => none
                }
                assoc_type_defs.push(AssocTypeDef { name: aname, bounds: bound_names, default_type: default_ty, var_id: at_var_id })
            },
            _ => {}
        }
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
    for method in methods {
        match method {
            Decl::Fn { name: mname, type_params: method_tps, params, return_type, declared_effects, is_abstract, .. } => {
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
                let fn_type = Type::FnType { params: param_types, return_type: ret, effects: method_effects }
                trait_methods.push(TraitMethodDef { name: mname, ty: fn_type, has_default: !is_abstract, param_mutabilities: param_muts, method_type_params: method_tps })
            },
            _ => {}
        }
    }

    ctx.type_param_scope = saved
    ctx.qualified_assoc_scope = saved_qualified_assoc
    ctx.env.trait_reg.traits.insert(name, TraitDef { name: name, type_params: tp_names, type_param_vars: tp_vars, methods: trait_methods, supertraits: supertrait_names, assoc_types: assoc_type_defs })
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
                    "Iteration protocol impl bound '${tp.name}: ${nominal_display_name(bound.trait_name)}' uses nested type arguments or associated constraints that exact dictionary evidence cannot preserve",
                    bound.span, DiagnosticContext::TraitError {
                        detail: "nested impl predicates are not yet representable in ImplEntry"
                    })
            }
        }
    }
}

fn register_impl(mut ctx: InferCtx, target_type: Str, type_params: List<TypeParam>, trait_name: Str?, methods: List<Decl>, span: Span) {
    register_impl_canonical(ctx, resolve_nominal_identity(ctx, target_type), type_params, trait_name, methods, span)
}

fn register_impl_canonical(mut ctx: InferCtx, target_type: Str, type_params: List<TypeParam>, trait_name: Str?, methods: List<Decl>, span: Span) {
    let resolved_trait_name = match trait_name {
        some(name) => some(resolve_trait_identity(ctx, name)), none => none
    }
    let origin = impl_decl_origin(
        target_type, resolved_trait_name, type_params, span)
    reject_unsupported_protocol_impl_bounds(ctx, resolved_trait_name, type_params)

    let saved = map_clone(ctx.type_param_scope)
    let saved_qualified_assoc = map_clone(ctx.qualified_assoc_scope)
    let mut impl_tv_ids: List<Int> = []
    for tp in type_params {
        let tv = ctx.env.fresh_var()
        match tv { Type::TypeVar { id, .. } => { impl_tv_ids.push(id) }, _ => {} }
        ctx.type_param_scope.insert(tp.name, tv)
    }

    let impl_bounds = normalize_impl_bounds(ctx, type_params, impl_tv_ids)

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

    let mut exact_method_schemes: Map<Str, TypeScheme> = map_new()
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
                        return_type, declared_effects, impl_bounds.scheme_bounds,
                        saved, type_params, false)
                    exact_method_schemes.insert(mname, scheme)
                }
            },
            Decl::ExternFn { name: mname, type_params: mtps, params, return_type, declared_effects, span: mspan, .. } => {
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
                        return_type, declared_effects, impl_bounds.scheme_bounds,
                        saved, type_params, true)
                    exact_method_schemes.insert(mname, scheme)
                }
            },
            Decl::Delegate { .. } => {},  // Deferred to register_phase3_delegate (needs complete struct fields)
            Decl::AssocType { .. } => {},  // Already handled above
            _ => {}
        }
    }

    match resolved_trait_name {
        some(tname) => {
            let trait_display = nominal_display_name(tname)
            let target_display = nominal_display_name(target_type)
            match ctx.env.trait_reg.traits.get(tname) {
                some(trait_def) => {
                    match find_impl(ctx.env.trait_reg, target_type, tname) {
                        some(existing) => {
                            if existing.origin != origin {
                                let _ = type_error(ctx.sink, E0504,
                                    "Duplicate impl '${trait_display}' for '${target_display}'",
                                    span, DiagnosticContext::TraitError {
                                        detail: "distinct impl origins provide the same target/trait pair"
                                    })
                            }
                        },
                        none => {}
                    }
                    let mut impl_method_names: Set<Str> = set_new()
                    for m in methods {
                        match m {
                            Decl::Fn { name: mn, .. } => {
                                impl_method_names.insert(mn)
                            },
                            Decl::ExternFn { name: mn, .. } => {
                                impl_method_names.insert(mn)
                            },
                            _ => {}
                        }
                    }
                    for tm in trait_def.methods {
                        if !tm.has_default && !impl_method_names.contains(tm.name) {
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
                           !impl_method_names.contains(trait_method.name) {
                            exact_method_schemes.insert(
                                trait_method.name,
                                specialize_trait_method_scheme(
                                    trait_def, trait_method, impl_self_type,
                                    trait_type_args, impl_tv_ids,
                                    assoc_type_map,
                                    impl_bounds.scheme_bounds))
                        }
                    }

                    let mut tp_names: List<Str> = []
                    for tp in type_params { tp_names.push(tp.name) }
                    // Keep method_names as the explicit-body set. Defaults
                    // live in method_schemes but still need this distinction
                    // when delegate HIR chooses direct versus dict dispatch.
                    let mut method_names = impl_method_names.to_list()
                    method_names.sort()
                    add_impl(ctx.env.trait_reg, ImplEntry {
                        trait_name: tname, target_type_name: target_type,
                        type_params: tp_names, method_names: method_names,
                        dict_bounds: impl_bounds.dict_bounds,
                        assoc_types: map_clone(assoc_type_map),
                        method_schemes: map_clone(exact_method_schemes),
                        origin: origin, span: span
                    })
                },
                none => { let _ = type_error(ctx.sink, E0501,
                    "Unknown trait: ${trait_display}", span,
                    DiagnosticContext::TraitError { detail: "unknown trait '${trait_display}'" }) }
            }
        },
        none => {}
    }

    let mut sorted_exact_methods = exact_method_schemes.entries()
    sorted_exact_methods.sort_by(compare_by_first)
    for entry in sorted_exact_methods {
        let (method_name, scheme) = entry
        let _ = install_method_scheme(
            ctx.env.trait_reg, ctx.sink,
            target_type, method_name, scheme,
            MethodOrigin {
                origin: origin, trait_name: resolved_trait_name, span: span
            })
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
    return_type: TypeExpr?, declared_effects: List<EffectExpr>?, impl_scheme_bounds: List<SchemeBound>, outer_saved: Map<Str, Type>,
    impl_type_params: List<TypeParam>, is_extern: Bool
) -> TypeScheme {
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
    if !is_extern {
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
    let scheme = TypeScheme {
        ty: fn_type, type_vars: all_tvs,
        bounds: impl_scheme_bounds, def_id: none
    }

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

fn remap_delegate_scheme_bounds(
    mut ctx: InferCtx, bounds: List<SchemeBound>,
    mapping: Map<Int, Type>, wrapper_fn_bounds: List<FnBoundsEntry>,
    span: Span
) -> List<SchemeBound> {
    let mut remapped: List<SchemeBound> = []
    for bound in bounds {
        let owner = apply_subst_map(mapping, Type::TypeVar {
            id: bound.type_var, name: none
        })
        match owner {
            Type::TypeVar { id: mapped_id, .. } => {
                let mut constraints: List<AssocConstraintEntry> = []
                for constraint in bound.assoc_constraints {
                    constraints.push(AssocConstraintEntry {
                        name: constraint.name,
                        ty: apply_subst_map(mapping, constraint.ty)
                    })
                }
                remapped.push(SchemeBound {
                    type_var: mapped_id,
                    trait_name: bound.trait_name,
                    assoc_constraints: constraints
                })
            },
            _ => {
                if bound.assoc_constraints.len() > 0 {
                    let _ = type_error(ctx.sink, E0503,
                        "Delegated method bound '${nominal_display_name(bound.trait_name)}' with associated constraints cannot be discharged for concrete owner '${type_to_string(owner)}'",
                        span, DiagnosticContext::TraitError {
                            detail: "delegate concrete bound discharge cannot prove associated constraints"
                        })
                } else {
                    match resolve_dict_ref_for_type(
                        ctx.env, wrapper_fn_bounds, owner, ctx.subst,
                        bound.trait_name
                    ) {
                        some(_) => {},
                        none => {
                            let _ = type_error(ctx.sink, E0503,
                                "Delegated impl bound '${nominal_display_name(bound.trait_name)}' is not satisfied by concrete owner '${type_to_string(owner)}'",
                                span, DiagnosticContext::TraitError {
                                    detail: "delegate concrete bound has no static trait evidence"
                                })
                        }
                    }
                }
            }
        }
    }
    remapped
}

fn specialize_delegate_method_scheme(
    mut ctx: InferCtx, field_scheme: TypeScheme,
    field_var_map: Map<Int, Type>, self_type: Type,
    impl_tv_ids: List<Int>, impl_scheme_bounds: List<SchemeBound>,
    wrapper_fn_bounds: List<FnBoundsEntry>, span: Span
) -> TypeScheme {
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

    let mut bounds = remap_delegate_scheme_bounds(
        ctx, field_scheme.bounds, field_var_map,
        wrapper_fn_bounds, span)
    for impl_bound in impl_scheme_bounds {
        let already = bounds.any(fn(existing) {
            existing.type_var == impl_bound.type_var &&
                existing.trait_name == impl_bound.trait_name
        })
        if !already { bounds.push(impl_bound) }
    }
    TypeScheme {
        ty: specialized_type,
        type_vars: type_vars,
        bounds: bounds,
        def_id: none
    }
}

fn remap_delegate_dict_bounds(
    mut ctx: InferCtx, source_bounds: List<ImplDictBound>,
    source_type_args: List<Type>, mapping: Map<Int, Type>,
    impl_tv_ids: List<Int>, wrapper_fn_bounds: List<FnBoundsEntry>,
    span: Span
) -> List<ImplDictBound> {
    let mut remapped: List<ImplDictBound> = []
    for source_bound in source_bounds {
        match source_type_args.get(source_bound.type_param_index) {
            some(source_arg) => {
                let mapped_owner = apply_subst_map(mapping, source_arg)
                match mapped_owner {
                    Type::TypeVar { id: mapped_id, .. } => {
                        let mut mapped_index = 0 - 1
                        let mut index = 0
                        while index < impl_tv_ids.len() {
                            match impl_tv_ids.get(index) {
                                some(wrapper_id) => {
                                    if wrapper_id == mapped_id {
                                        mapped_index = index
                                    }
                                },
                                none => {}
                            }
                            index = index + 1
                        }
                        if mapped_index >= 0 {
                            let duplicate = remapped.any(fn(existing) {
                                existing.type_param_index == mapped_index &&
                                    existing.trait_name == source_bound.trait_name
                            })
                            if !duplicate {
                                remapped.push(ImplDictBound {
                                    type_param_index: mapped_index,
                                    trait_name: source_bound.trait_name
                                })
                            }
                        } else {
                            let _ = type_error(ctx.sink, E0503,
                                "Delegated impl bound '${nominal_display_name(source_bound.trait_name)}' does not map to a wrapper impl type parameter",
                                span, DiagnosticContext::TraitError {
                                    detail: "delegate dictionary bound owner is not representable"
                                })
                        }
                    },
                    _ => {
                        match resolve_dict_ref_for_type(
                            ctx.env, wrapper_fn_bounds, mapped_owner, ctx.subst,
                            source_bound.trait_name
                        ) {
                            some(_) => {},
                            none => {
                                let _ = type_error(ctx.sink, E0503,
                                    "Delegated impl bound '${nominal_display_name(source_bound.trait_name)}' is not satisfied by concrete owner '${type_to_string(mapped_owner)}'",
                                    span, DiagnosticContext::TraitError {
                                        detail: "delegate concrete bound has no static trait evidence"
                                    })
                            }
                        }
                    }
                }
            },
            none => {
                let _ = type_error(ctx.sink, E0503,
                    "Delegated impl bound '${nominal_display_name(source_bound.trait_name)}' has no exact source type parameter",
                    span, DiagnosticContext::TraitError {
                        detail: "delegate source impl predicate is incomplete"
                    })
            }
        }
    }
    remapped
}

// Present both delegate-bound remappers with one exact view of the wrapper
// impl's runtime evidence. ImplDictBound owns the canonical parameter index;
// the matching registration-time var id and source name define the dictionary
// parameter that resolve_dict_ref_for_type may recursively consume.
fn build_delegate_wrapper_fn_bounds(
    mut ctx: InferCtx, impl_dict_bounds: List<ImplDictBound>,
    impl_tv_ids: List<Int>, impl_type_params: List<TypeParam>,
    span: Span
) -> List<FnBoundsEntry> {
    let mut fn_bounds: List<FnBoundsEntry> = []
    for dict_bound in impl_dict_bounds {
        match (impl_tv_ids.get(dict_bound.type_param_index),
               impl_type_params.get(dict_bound.type_param_index)) {
            (some(type_var_id), some(type_param)) => {
                fn_bounds.push(FnBoundsEntry {
                    type_param_var_id: type_var_id,
                    trait_name: dict_bound.trait_name,
                    type_param_name: type_param.name
                })
            },
            _ => {
                let _ = type_error(ctx.sink, E0503,
                    "Delegated wrapper bound '${nominal_display_name(dict_bound.trait_name)}' has no exact wrapper type parameter evidence",
                    span, DiagnosticContext::TraitError {
                        detail: "delegate wrapper dictionary bound is incomplete"
                    })
            }
        }
    }
    fn_bounds
}

fn register_delegate(
    mut ctx: InferCtx, impl_tv_ids: List<Int>,
    target_type: Str, field: Str, trait_names: List<Str>, span: Span,
    impl_scheme_bounds: List<SchemeBound>, impl_dict_bounds: List<ImplDictBound>,
    impl_type_params: List<TypeParam>
) {
    let wrapper_fn_bounds = build_delegate_wrapper_fn_bounds(
        ctx, impl_dict_bounds, impl_tv_ids, impl_type_params, span)
    // 1. Validate field exists on target struct
    let target_display = nominal_display_name(target_type)
    match ctx.env.types.structs.get(target_type) {
        none => {
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
                            let _ = type_error(ctx.sink, E0507,
                                "delegate field '${field}' must have a named type (struct or enum)",
                                span, DiagnosticContext::TraitError { detail: "delegate field has unnamed type" })
                        }
                    }
                    match field_type_name {
                        none => {},
                        some(ftn) => {
                            register_delegate_traits(ctx, impl_tv_ids, target_type,
                                field, trait_names, span, impl_scheme_bounds, impl_dict_bounds,
                                wrapper_fn_bounds, impl_type_params, ftn, ft)
                        }
                    }
                }
            }
        }
    }
}

fn register_delegate_traits(
    mut ctx: InferCtx, impl_tv_ids: List<Int>,
    target_type: Str, field: Str, trait_names: List<Str>, span: Span,
    impl_scheme_bounds: List<SchemeBound>, impl_dict_bounds: List<ImplDictBound>,
    wrapper_fn_bounds: List<FnBoundsEntry>,
    impl_type_params: List<TypeParam>, field_type_name: Str, ft: Type
) {
    for tname in trait_names {
        let canonical_trait = resolve_trait_identity(ctx, tname)
        let trait_display = nominal_display_name(canonical_trait)
        let field_type_display = nominal_display_name(field_type_name)
        let target_display = nominal_display_name(target_type)
        match ctx.env.trait_reg.traits.get(canonical_trait) {
            none => {
                let _ = type_error(ctx.sink, E0501,
                    "Unknown trait: ${trait_display}",
                    span, DiagnosticContext::TraitError { detail: "unknown trait '${trait_display}'" })
            },
            some(trait_def) => {
                // Validate that the field type implements the trait
                if !has_impl(ctx.env.trait_reg, field_type_name, canonical_trait) {
                    let _ = type_error(ctx.sink, E0508,
                        "type '${field_type_display}' (field '${field}') does not implement trait '${trait_display}'",
                        span, DiagnosticContext::TraitError { detail: "delegate field type missing trait impl" })
                } else {
                    // Check for conflict: same trait already implemented (hand-written) for this type
                    if has_impl(ctx.env.trait_reg, target_type, canonical_trait) {
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
                        if !has_impl(ctx.env.trait_reg, field_type_name, reg_tname) { continue }

                        match ctx.env.trait_reg.traits.get(reg_tname) {
                            none => {},
                            some(reg_trait_def) => {
                                let field_impl = find_impl(
                                    ctx.env.trait_reg, field_type_name, reg_tname)
                                let mut field_var_map: Map<Int, Type> = map_new()
                                let mut field_impl_type_args: List<Type> = []
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
                                                some(field_scheme) =>
                                                    match field_scheme.ty {
                                                        Type::FnType { params, .. } =>
                                                            match params.first() {
                                                                some(field_receiver) => {
                                                                    if field_impl_type_args.len() == 0 {
                                                                        match field_receiver {
                                                                            Type::StructType { name, type_params } => {
                                                                                if name == field_type_name {
                                                                                    field_impl_type_args = list_clone(type_params)
                                                                                }
                                                                            },
                                                                            Type::EnumType { name, type_params } => {
                                                                                if name == field_type_name {
                                                                                    field_impl_type_args = list_clone(type_params)
                                                                                }
                                                                            },
                                                                            _ => {}
                                                                        }
                                                                    }
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
                                let mut delegated_dict_bounds = list_clone(impl_dict_bounds)
                                match field_impl {
                                    some(found) => {
                                        let mapped_dict_bounds = remap_delegate_dict_bounds(
                                            ctx, found.dict_bounds,
                                            field_impl_type_args, field_var_map,
                                            impl_tv_ids, wrapper_fn_bounds, span)
                                        for mapped_bound in mapped_dict_bounds {
                                            let duplicate = delegated_dict_bounds.any(fn(existing) {
                                                existing.type_param_index == mapped_bound.type_param_index &&
                                                    existing.trait_name == mapped_bound.trait_name
                                            })
                                            if !duplicate {
                                                delegated_dict_bounds.push(mapped_bound)
                                            }
                                        }
                                    },
                                    none => {}
                                }
                                let mut exact_method_schemes: Map<Str, TypeScheme> = map_new()
                                let origin = impl_origin(
                                    target_type, some(reg_tname), span)

                                // Every forwarding scheme is the exact field
                                // scheme under the same structural mapping.
                                for tm in reg_trait_def.methods {
                                    let resolved_method_scheme = match field_impl {
                                        some(found) => found.method_schemes.get(tm.name),
                                        none => none
                                    }
                                    match resolved_method_scheme {
                                        some(field_scheme) => {
                                            let scheme = specialize_delegate_method_scheme(
                                                ctx, field_scheme, field_var_map,
                                                self_type, impl_tv_ids,
                                                impl_scheme_bounds,
                                                wrapper_fn_bounds, span)
                                            exact_method_schemes.insert(tm.name, scheme)
                                            let _ = install_method_scheme(
                                                ctx.env.trait_reg, ctx.sink,
                                                target_type, tm.name, scheme,
                                                MethodOrigin {
                                                    origin: origin,
                                                    trait_name: some(reg_tname),
                                                    span: span
                                                })
                                        },
                                        none => {
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

                                add_impl(ctx.env.trait_reg, ImplEntry {
                                    trait_name: reg_tname,
                                    target_type_name: target_type,
                                    type_params: tp_names,
                                    method_names: method_names,
                                    dict_bounds: delegated_dict_bounds,
                                    assoc_types: map_clone(field_assoc_types),
                                    method_schemes: exact_method_schemes,
                                    origin: origin,
                                    span: span
                                })
                            }
                        }
                    }
                }
            }
        }
    }
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
    install_visible_name: Bool
) {
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
    let def = StructDef { name: name, type_params: tp_names, type_param_vars: tp_vars, fields: [], derive_attrs: [], is_extern: true }
    if install_visible_name {
        ctx.env.types.structs.insert(name, def)
    }
    ctx.env.types.extern_structs.insert(name, def)
}

fn register_project_extern_type(
    mut ctx: InferCtx, name: Str, type_params: List<TypeParam>
) {
    register_extern_type_common(ctx, name, type_params, false)
}

fn register_extern_type(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>) {
    register_extern_type_common(ctx, name, type_params, true)
}

fn register_type_alias(mut ctx: InferCtx, name: Str, type_params: List<TypeParam>, type_expr: TypeExpr) {
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

fn register_sig(mut ctx: InferCtx, name: Str, members: List<SigMember>, is_pub: Bool) {
    let saved = map_clone(ctx.type_param_scope)
    let mut sig_members: Map<Str, TypeScheme> = map_new()
    for m in members {
        let mut type_vars: List<Int> = []
        let msaved = map_clone(ctx.type_param_scope)
        for tp in m.type_params {
            let tv = ctx.env.fresh_var()
            match tv { Type::TypeVar { id, .. } => { type_vars.push(id) }, _ => {} }
            ctx.type_param_scope.insert(tp.name, tv)
        }
        let mut param_types: List<Type> = []
        for p in m.params {
            match p.type_annotation {
                some(ta) => param_types.push(resolve_type_expr(ctx, ta)),
                none => param_types.push(ctx.env.fresh_var())
            }
        }
        let ret = match m.return_type {
            some(rt) => resolve_type_expr(ctx, rt),
            none => ctx.env.fresh_var()
        }
        let fn_type = Type::FnType { params: param_types, return_type: ret, effects: EMPTY_ROW }
        sig_members.insert(m.name, TypeScheme { ty: fn_type, type_vars: type_vars, bounds: [], def_id: none })
        ctx.type_param_scope = msaved
    }
    ctx.type_param_scope = saved
    ctx.env.types.sigs.insert(name, SigDef { name: name, members: sig_members, is_pub: is_pub })
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

fn register_decl(mut ctx: InferCtx, decl: Decl) {
    match decl {
        Decl::Struct { name, type_params, fields, derive_attrs, span, .. } => {
            preregister_struct(ctx, name, type_params, derive_attrs)
            complete_struct_fields(ctx, name, fields)
        },
        Decl::Enum { name, type_params, variants, derive_attrs, span, .. } => {
            preregister_enum(ctx, name, type_params, derive_attrs)
            complete_enum_variants(ctx, name, type_params, variants)
        },
        Decl::Effect { name, type_params, ops, .. } =>
            register_effect(ctx, name, type_params, ops),
        Decl::Impl { target_type, type_params, trait_name, methods, span } =>
            register_impl(ctx, target_type, type_params, trait_name, methods, span),
        Decl::Fn { name, type_params, params, return_type, declared_effects, span, .. } =>
            register_fn(ctx, name, type_params, params, return_type, declared_effects, span),
        Decl::Test { .. } => {},
        Decl::Trait { name, type_params, supertraits, methods, span, .. } =>
            register_trait(ctx, name, type_params, supertraits, methods, span),
        Decl::ExternFn { name, type_params, params, return_type, declared_effects, span, .. } =>
            register_extern_fn(ctx, name, type_params, params, return_type, declared_effects, span),
        Decl::ExternType { name, type_params, .. } =>
            register_extern_type(ctx, name, type_params),
        Decl::TypeAlias { name, type_params, type_expr, .. } =>
            register_type_alias(ctx, name, type_params, type_expr),
        Decl::Const { name, type_annotation, span, .. } =>
            register_const(ctx, name, type_annotation, span),
        Decl::Sig { name, members, is_pub, .. } =>
            register_sig(ctx, name, members, is_pub),
        Decl::EffectAlias { name, type_params, effects, span, .. } =>
            register_effect_alias(ctx, name, type_params, effects, span),
        Decl::Delegate { .. } => {},  // Only valid inside impl blocks, handled by register_impl
        Decl::AssocType { .. } => {},  // Only valid inside trait/impl blocks
        Decl::ModBlock { name: mod_name, uses: mod_uses, decls: mod_decls, .. } => {
            register_mod_block_items(ctx, mod_name, mod_uses, mod_decls, none, none)
        }
    }
}
