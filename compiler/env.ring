use types::{Type, Effect, EffectRow, StructField, EnumVariant, RecordField, INT,
    effects_match_kind, nominal_display_name}
use union_find::{UnionFind, uf_find, uf_lookup}
use ast::{Span, EffectExpr, TypeParam, DeriveAttribute}
use diagnostics::{CollectingSink, DiagnosticSink, DiagnosticContext, Severity,
    make_diag}
use codes::{E0504}

// ============================================================
// Type Scheme (for let-polymorphism)
// ============================================================

pub struct AssocConstraintEntry {
    pub name: Str,   // "Item"
    pub ty: Type     // the constrained concrete type
}

pub struct SchemeBound {
    pub type_var: Int,
    pub trait_name: Str,
    pub assoc_constraints: List<AssocConstraintEntry>
}

pub struct TypeScheme {
    pub ty: Type,
    pub type_vars: List<Int>,
    pub bounds: List<SchemeBound>,
    pub def_id: Int?
}

// Follow a scheme's lexical DefId to its final declaration identity. Alias
// consumers in checker/export must share this rule: an intermediate re-export
// key is a lookup location, never callable provenance.
pub fn exact_scheme_value_origin(
    exact_origins: Map<Int, Str>, scheme: TypeScheme, fallback: Str
) -> Str {
    match scheme.def_id {
        some(def_id) => match exact_origins.get(def_id) {
            some(origin) => origin,
            none => fallback
        },
        none => fallback
    }
}

// ============================================================
// Struct / Enum / Effect definitions stored in environment
// ============================================================

pub struct StructDef {
    pub name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub fields: List<StructField>,
    pub derive_attrs: List<DeriveAttribute>,
    // True for opaque extern (FFI) types registered as zero-field structs.
    // Carries cross-module via TypeDef::StructDef_ so both the declaring and
    // consuming modules can exclude it from trait derivation (B-074).
    pub is_extern: Bool
}

pub struct EnumDef {
    pub name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub variants: List<EnumVariant>,
    pub derive_attrs: List<DeriveAttribute>,
    pub variant_index: Map<Str, Int>
}

pub fn lookup_variant(def: EnumDef, name: Str) -> EnumVariant? {
    match def.variant_index.get(name) {
        some(idx) => def.variants.get(idx),
        none => none
    }
}

pub struct EffectOpDef {
    pub name: Str,
    pub def_id: Int,
    pub params: List<Type>,
    pub return_type: Type,
    pub has_default: Bool
}

pub enum BuiltInKind { BkIo, BkFail, BkMut }

pub struct EffectDef {
    pub name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub ops: List<EffectOpDef>,
    pub built_in_kind: BuiltInKind?,
    pub all_have_defaults: Bool
}

// ============================================================
// Trait definitions
// ============================================================

pub struct TraitMethodDef {
    pub name: Str,
    pub def_id: Int,
    pub ty: Type,
    pub has_default: Bool,
    pub param_mutabilities: List<Bool>,
    pub method_type_params: List<TypeParam>
}

pub struct AssocTypeDef {
    pub name: Str,
    pub bounds: List<Str>,        // trait name bounds
    pub default_type: Type?,      // trait-level default value
    pub var_id: Int               // type variable ID used in trait method signatures
}

pub struct TraitDef {
    pub name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub methods: List<TraitMethodDef>,
    pub supertraits: List<Str>,
    pub assoc_types: List<AssocTypeDef>
}

// Ordered impl predicates that require runtime dictionary evidence.
// This is not a complete impl predicate: current impl registration does not
// carry TypeBound type_args or assoc_constraints here.
pub struct ImplDictBound {
    pub type_param_index: Int,
    pub trait_name: Str
}

// One runtime dictionary predicate instantiated against a nominal use site's
// actual type arguments.  Both ordinary inference and synthetic derive code
// consume this mapping so bound order/index/trait cannot drift between them.
pub struct ImplDictRequirement {
    pub type_arg: Type,
    pub trait_name: Str
}

pub struct ImplEntry {
    pub trait_name: Str,
    pub target_type_name: Str,
    pub type_params: List<Str>,
    pub dict_bounds: List<ImplDictBound>,
    pub method_names: List<Str>,
    pub assoc_types: Map<Str, Type>,
    // Trait-specific method evidence.  This is authoritative for protocol
    // lowering; impl_methods remains only the unambiguous ordinary-call view.
    pub method_schemes: Map<Str, TypeScheme>,
    // Stable across export/re-export hydration.  Distinct source impl blocks
    // must never be collapsed merely because target/trait spellings match.
    pub origin: Str,
    pub span: Span
}

pub struct MethodOrigin {
    pub origin: Str,
    pub trait_name: Str?,
    pub span: Span
}

// ============================================================
// Type alias + function bounds
// ============================================================

pub struct TypeAliasDef {
    pub name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub ty: Type
}

pub struct EffectAliasDef {
    pub name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub effects: List<EffectExpr>,
    pub span: Span
}

pub struct FnBound {
    pub type_param: Str,
    pub trait_name: Str
}

pub struct SigDef {
    pub name: Str,
    pub members: Map<Str, TypeScheme>,
    pub is_pub: Bool
}

// ============================================================
// Scope
// ============================================================

pub struct Scope {
    pub variables: Map<Str, TypeScheme>
}

// ============================================================
// TypeEnv sub-structs
// ============================================================

pub struct TypeRegistry {
    pub structs: Map<Str, StructDef>,
    // Stable raw-ABI extern definitions. Ordinary nominal aliases may replace
    // the same leaf in `structs`, but must never erase the extern declaration.
    pub extern_structs: Map<Str, StructDef>,
    pub enums: Map<Str, EnumDef>,
    pub effects: Map<Str, EffectDef>,
    pub variant_to_enum: Map<Str, Str>,
    // Exact constructor provenance keyed by the lexical binding DefId. This is
    // a codegen identity table for every variant constructor; ownership
    // freshness is classified separately in shared HIR helpers.
    pub variant_ctor_origins: Map<Int, Str>,
    pub type_aliases: Map<Str, TypeAliasDef>,
    pub sigs: Map<Str, SigDef>,
    pub effect_aliases: Map<Str, EffectAliasDef>
}

pub struct TraitRegistry {
    pub traits: Map<Str, TraitDef>,
    pub trait_impls: Map<Str, List<ImplEntry>>,
    pub impl_methods: Map<Str, Map<Str, TypeScheme>>,
    pub method_origins: Map<Str, Map<Str, MethodOrigin>>,
    pub mut_methods: Map<Str, Set<Str>>
}

pub struct ScopeManager {
    pub scopes: List<Scope>,
    pub fn_bounds: Map<Str, List<FnBound>>,
    pub var_bounds: Map<Int, Set<Str>>,
    pub def_spans: Map<Int, Span>,
    pub mutable_vars: Set<Int>,
    pub let_defs: Set<Int>,
    pub mut_param_defs: Set<Int>
}

pub struct IdGen {
    pub next_type_var_id: Int,
    pub next_def_id: Int
}

// ============================================================
// TypeEnv
// ============================================================

pub struct TypeEnv {
    pub types: TypeRegistry,
    pub trait_reg: TraitRegistry,
    pub scope: ScopeManager,
    pub ids: IdGen
}

// ============================================================
// Constructor + helpers
// ============================================================

pub fn mono(ty: Type) -> TypeScheme {
    TypeScheme { ty: ty, type_vars: [], bounds: [], def_id: none }
}

pub fn new_type_env() -> TypeEnv {
    let initial_scope = Scope { variables: map_new() }
    TypeEnv {
        types: TypeRegistry {
            structs: map_new(),
            extern_structs: map_new(),
            enums: map_new(),
            effects: map_new(),
            variant_to_enum: map_new(),
            variant_ctor_origins: map_new(),
            type_aliases: map_new(),
            sigs: map_new(),
            effect_aliases: map_new()
        },
        trait_reg: TraitRegistry {
            traits: map_new(),
            trait_impls: map_new(),
            impl_methods: map_new(),
            method_origins: map_new(),
            mut_methods: map_new()
        },
        scope: ScopeManager {
            scopes: [initial_scope],
            fn_bounds: map_new(),
            var_bounds: map_new(),
            def_spans: map_new(),
            mutable_vars: set_new(),
            let_defs: set_new(),
            mut_param_defs: set_new()
        },
        ids: IdGen {
            next_type_var_id: 0,
            next_def_id: 0
        }
    }
}

// ============================================================
// TypeEnv methods
// ============================================================

impl TypeEnv {
    pub fn current_var_id(self) -> Int { self.ids.next_type_var_id }

    pub fn fresh_var(mut self) -> Type {
        let id = self.ids.next_type_var_id
        self.ids.next_type_var_id = id + 1
        Type::TypeVar { id: id, name: none }
    }

    pub fn fresh_var_id(mut self) -> Int {
        let id = self.ids.next_type_var_id
        self.ids.next_type_var_id = id + 1
        id
    }

    pub fn fresh_def_id(mut self) -> Int {
        let id = self.ids.next_def_id
        self.ids.next_def_id = id + 1
        id
    }

    pub fn push_scope(mut self) {
        self.scope.scopes.push(Scope { variables: map_new() })
    }

    pub fn pop_scope(mut self) {
        if self.scope.scopes.len() <= 1 {
            panic("unreachable: cannot pop global scope")
        }
        self.scope.scopes.pop()
    }

    pub fn bind(mut self, name: Str, scheme: TypeScheme) {
        let s = match scheme.def_id {
            some(_) => scheme,
            none => TypeScheme { ..scheme, def_id: some(self.fresh_def_id()) }
        }
        let idx = self.scope.scopes.len() - 1
        match self.scope.scopes.get(idx) {
            some(scope) => scope.variables.insert(name, s),
            none => panic("unreachable: no current scope")
        }
    }

    pub fn bind_mono(mut self, name: Str, ty: Type) {
        self.bind(name, mono(ty))
    }

    pub fn record_def_span(mut self, def_id: Int, span: Span) {
        self.scope.def_spans.insert(def_id, span)
    }

    pub fn rebind(mut self, name: Str, scheme: TypeScheme) {
        let mut i = self.scope.scopes.len() - 1
        while i >= 0 {
            match self.scope.scopes.get(i) {
                some(scope) => {
                    if scope.variables.contains_key(name) {
                        scope.variables.insert(name, scheme)
                        return
                    }
                },
                none => {}
            }
            i = i - 1
        }
        panic("unreachable: rebind failed — variable '${name}' not found in any scope")
    }

    pub fn lookup(self, name: Str) -> TypeScheme? {
        let mut i = self.scope.scopes.len() - 1
        while i >= 0 {
            let found = match self.scope.scopes.get(i) {
                some(scope) => scope.variables.get(name),
                none => none
            }
            if found.is_some() { return found }
            i = i - 1
        }
        none
    }

    pub fn instantiate(mut self, scheme: TypeScheme) -> Type {
        if scheme.type_vars.len() == 0 { return scheme.ty }
        let mut mapping: Map<Int, Type> = map_new()
        for tv in scheme.type_vars {
            mapping.insert(tv, self.fresh_var())
        }
        for bound in scheme.bounds {
            match mapping.get(bound.type_var) {
                some(fresh) => match fresh {
                    Type::TypeVar { id, .. } => {
                        let mut existing: Set<Str> = match self.scope.var_bounds.get(id) {
                            some(s) => s,
                            none => set_new()
                        }
                        existing.insert(bound.trait_name)
                        self.scope.var_bounds.insert(id, existing)
                    },
                    _ => {}
                },
                none => {}
            }
        }
        apply_subst_map(mapping, scheme.ty)
    }
}

// ============================================================
// trait_impls helpers (Map<Str, List<ImplEntry>> keyed by target_type_name)
// ============================================================

pub fn impl_origin(
    target_type_name: Str, trait_name: Str?, span: Span
) -> Str {
    let trait_part = match trait_name {
        some(name) => name,
        none => "<inherent>"
    }
    "${span.file}:${span.start.offset.to_str()}:${target_type_name}:${trait_part}"
}

fn path_has_suffix(path: Str, suffix: Str) -> Bool {
    let normalized = path.replace("\\", "/")
    if normalized.len() < suffix.len() { return false }
    normalized.slice(normalized.len() - suffix.len(), normalized.len()) == suffix
}

// List/Map/Set HOF schemes are compiler predeclarations for the matching
// standard-library impl blocks. Give the declaration and definition one
// stable source identity so the definition may rebind its inferred effects
// without weakening duplicate detection for any user impl block.
pub fn impl_decl_origin(
    target_type_name: Str, trait_name: Str?,
    type_params: List<TypeParam>, span: Span
) -> Str {
    if trait_name.is_none() {
        let has_bounds = type_params.any(fn(param) {
            param.bounds.len() > 0
        })
        if target_type_name == "List" && !has_bounds &&
           path_has_suffix(span.file, "std/list.ring") {
            return "<std-predecl>:List:unbounded"
        }
        if target_type_name == "Map" &&
           path_has_suffix(span.file, "std/map.ring") {
            if has_bounds {
                return "<std-predecl>:Map:bounded"
            }
            return "<std-predecl>:Map:unbounded"
        }
        if target_type_name == "Set" &&
           path_has_suffix(span.file, "std/set.ring") {
            if has_bounds {
                return "<std-predecl>:Set:bounded"
            }
            return "<std-predecl>:Set:unbounded"
        }
    }
    impl_origin(target_type_name, trait_name, span)
}

pub fn impl_method_origin(impl_origin_: Str, method_name: Str) -> Str {
    "${impl_origin_}::${method_name}"
}

fn method_owner_display(trait_name: Str?) -> Str {
    match trait_name {
        some(name) => "trait '${nominal_display_name(name)}'",
        none => "an inherent impl"
    }
}

// The sole writer for the ordinary method lookup table and its provenance.
// Re-export hydration may replay the same origin, but no distinct source may
// replace an existing same-target/same-name identity.
pub fn install_method_scheme(
    mut reg: TraitRegistry, mut sink: CollectingSink,
    target_type: Str, method_name: Str,
    scheme: TypeScheme, incoming: MethodOrigin
) -> Bool {
    if scheme.def_id.is_none() {
        panic("unreachable: registered method scheme has no exact DefId")
    }
    let mut methods = match reg.impl_methods.get(target_type) {
        some(existing) => existing,
        none => {
            let created: Map<Str, TypeScheme> = map_new()
            reg.impl_methods.insert(target_type, created)
            created
        }
    }
    let mut origins = match reg.method_origins.get(target_type) {
        some(existing) => existing,
        none => {
            let created: Map<Str, MethodOrigin> = map_new()
            reg.method_origins.insert(target_type, created)
            created
        }
    }

    match origins.get(method_name) {
        some(existing) => {
            if existing.origin == incoming.origin {
                methods.insert(method_name, scheme)
                origins.insert(method_name, incoming)
                true
            } else {
                let old_owner = method_owner_display(existing.trait_name)
                let new_owner = method_owner_display(incoming.trait_name)
                sink.report(make_diag(
                    E0504, Severity::SevError,
                    "Ambiguous method '${method_name}' on '${nominal_display_name(target_type)}': provided by ${old_owner} and ${new_owner}",
                    incoming.span,
                    DiagnosticContext::TraitError {
                        detail: "same-target method origins must be unique"
                    }))
                false
            }
        },
        none => {
            if methods.contains_key(method_name) {
                // A scheme without provenance cannot be proven identical to
                // the incoming method. Preserve the prior recovery view.
                sink.report(make_diag(
                    E0504, Severity::SevError,
                    "Ambiguous method '${method_name}' on '${nominal_display_name(target_type)}': existing method identity has no stable origin",
                    incoming.span,
                    DiagnosticContext::TraitError {
                        detail: "method scheme is missing origin provenance"
                    }))
                false
            } else {
                methods.insert(method_name, scheme)
                origins.insert(method_name, incoming)
                true
            }
        }
    }
}

pub fn add_impl(mut reg: TraitRegistry, entry: ImplEntry) {
    match reg.trait_impls.get(entry.target_type_name) {
        some(impls) => {
            // The same exported impl may arrive through both its defining
            // module and one or more facades.  Preserve one exact entry while
            // retaining genuinely distinct, already-diagnosed collisions for
            // checker recovery.
            if !impls.any(fn(i) { i.origin == entry.origin }) {
                impls.push(entry)
            }
        },
        none => {
            let mut list: List<ImplEntry> = []
            list.push(entry)
            reg.trait_impls.insert(entry.target_type_name, list)
        }
    }
}

pub fn has_impl(reg: TraitRegistry, type_name: Str, trait_name: Str) -> Bool {
    match reg.trait_impls.get(type_name) {
        some(impls) => impls.any(fn(i) { i.trait_name == trait_name }),
        none => false
    }
}

pub fn find_impl(reg: TraitRegistry, type_name: Str, trait_name: Str) -> ImplEntry? {
    match reg.trait_impls.get(type_name) {
        some(impls) => impls.find(fn(i) { i.trait_name == trait_name }),
        none => none
    }
}

pub fn instantiate_impl_dict_requirements(
    entry: ImplEntry, type_args: List<Type>
) -> List<ImplDictRequirement>? {
    let mut requirements: List<ImplDictRequirement> = []
    for bound in entry.dict_bounds {
        match type_args.get(bound.type_param_index) {
            some(type_arg) => requirements.push(ImplDictRequirement {
                type_arg: type_arg,
                trait_name: bound.trait_name
            }),
            none => return none
        }
    }
    some(requirements)
}

pub fn find_impl_by_origin(
    reg: TraitRegistry, type_name: Str, origin: Str
) -> ImplEntry? {
    match reg.trait_impls.get(type_name) {
        some(impls) => impls.find(fn(i) { i.origin == origin }),
        none => none
    }
}

// ============================================================
// Map-based substitution: apply a local Map<Int, Type> mapping to a type.
// Used for local type parameter instantiation maps (not the global substitution).
// ============================================================

fn chase_type_var_map(subst: Map<Int, Type>, id: Int, depth: Int) -> Type {
    if depth > 100 { return Type::TypeVar { id: id, name: none } }
    match subst.get(id) {
        some(resolved) => match resolved {
            Type::TypeVar { id: next_id, .. } => chase_type_var_map(subst, next_id, depth + 1),
            _ => apply_subst_map(subst, resolved)
        },
        none => Type::TypeVar { id: id, name: none }
    }
}

pub fn apply_subst_map(subst: Map<Int, Type>, t: Type) -> Type {
    match t {
        Type::IntType => Type::IntType,
        Type::FloatType => Type::FloatType,
        Type::StrType => Type::StrType,
        Type::BoolType => Type::BoolType,
        Type::UnitType => Type::UnitType,
        Type::NeverType => Type::NeverType,
        Type::AnyType => Type::AnyType,
        Type::TypeVar { id, .. } => chase_type_var_map(subst, id, 0),
        Type::FnType { params, return_type, effects, ownership_term } =>
            Type::FnType {
                params: params.map(fn(p) { apply_subst_map(subst, p) }),
                return_type: apply_subst_map(subst, return_type),
                effects: apply_subst_row_map(subst, effects),
                ownership_term: ownership_term
            },
        Type::StructType { name, type_params } =>
            Type::StructType {
                name: name,
                type_params: type_params.map(fn(p) { apply_subst_map(subst, p) })
            },
        Type::EnumType { name, type_params } =>
            Type::EnumType {
                name: name,
                type_params: type_params.map(fn(p) { apply_subst_map(subst, p) })
            },
        Type::GenericType { base, args } =>
            Type::GenericType {
                base: apply_subst_map(subst, base),
                args: args.map(fn(a) { apply_subst_map(subst, a) })
            },
        Type::RecordType { fields, tail, tail_name } => {
            let mapped_fields = fields.map(fn(f) {
                RecordField { name: f.name, ty: apply_subst_map(subst, f.ty) }
            })
            match tail {
                some(t_id) => match subst.get(t_id) {
                    some(resolved) => {
                        let chased = apply_subst_map(subst, resolved)
                        match chased {
                            Type::TypeVar { id: new_id, name: new_name } =>
                                Type::RecordType { fields: mapped_fields, tail: some(new_id), tail_name: new_name },
                            Type::RecordType { fields: extra_fields, tail: extra_tail, tail_name: extra_tn } => {
                                let mut all_fields = list_clone(mapped_fields)
                                for ef in extra_fields {
                                    all_fields.push(RecordField { name: ef.name, ty: apply_subst_map(subst, ef.ty) })
                                }
                                Type::RecordType { fields: all_fields, tail: extra_tail, tail_name: extra_tn }
                            },
                            _ => Type::RecordType { fields: mapped_fields, tail: none, tail_name: none }
                        }
                    },
                    none => Type::RecordType { fields: mapped_fields, tail: some(t_id), tail_name: tail_name }
                },
                none => Type::RecordType { fields: mapped_fields, tail: none, tail_name: tail_name }
            }
        },
        Type::EffectRowType { effects, tail } => {
            let row = apply_subst_row_map(subst, EffectRow { effects: effects, tail: tail })
            Type::EffectRowType { effects: row.effects, tail: row.tail }
        },
        Type::TupleType { elements } =>
            Type::TupleType { elements: elements.map(fn(e) { apply_subst_map(subst, e) }) },
        Type::PtrType { pointee } =>
            Type::PtrType { pointee: apply_subst_map(subst, pointee) },
        Type::ErrorType => Type::ErrorType
    }
}

pub fn apply_subst_effect_map(subst: Map<Int, Type>, e: Effect) -> Effect {
    match e {
        Effect::FailEffect { error_type } =>
            Effect::FailEffect { error_type: apply_subst_map(subst, error_type) },
        Effect::MutEffect { state_type } =>
            Effect::MutEffect { state_type: apply_subst_map(subst, state_type) },
        Effect::CustomEffect { name, type_args } =>
            Effect::CustomEffect { name: name, type_args: type_args.map(fn(a) { apply_subst_map(subst, a) }) },
        Effect::IoEffect => Effect::IoEffect,
        Effect::UnsafeEffect => Effect::UnsafeEffect
    }
}

pub fn apply_subst_row_map(subst: Map<Int, Type>, row: EffectRow) -> EffectRow {
    let effects = row.effects.map(fn(e) { apply_subst_effect_map(subst, e) })
    match row.tail {
        some(t_id) => match subst.get(t_id) {
            some(resolved) => {
                let chased = apply_subst_map(subst, resolved)
                match chased {
                    Type::TypeVar { id: new_id, .. } =>
                        EffectRow { effects: effects, tail: some(new_id) },
                    Type::EffectRowType { effects: extra_effs, tail: extra_tail } => {
                        let mut merged = list_clone(effects)
                        for ee in extra_effs {
                            merged.push(apply_subst_effect_map(subst, ee))
                        }
                        EffectRow { effects: merged, tail: extra_tail }
                    },
                    _ => EffectRow { effects: effects, tail: none }
                }
            },
            none => EffectRow { effects: effects, tail: some(t_id) }
        },
        none => EffectRow { effects: effects, tail: none }
    }
}

// ============================================================
// Shared structural TypeVar mapping
// ============================================================

fn collect_effect_var_mappings(
    source_row: EffectRow, target_row: EffectRow,
    source_vars: Set<Int>, mut result: Map<Int, Type>
) {
    match (source_row.tail, target_row.tail) {
        (some(source_id), some(target_id)) => {
            if source_vars.contains(source_id) {
                result.insert(source_id, Type::TypeVar {
                    id: target_id, name: none
                })
            }
        },
        _ => {}
    }

    for source_effect in source_row.effects {
        for target_effect in target_row.effects {
            if effects_match_kind(source_effect, target_effect) {
                match (source_effect, target_effect) {
                    (Effect::FailEffect { error_type: source_type },
                     Effect::FailEffect { error_type: target_type }) =>
                        collect_var_mappings(
                            source_type, target_type, source_vars, result),
                    (Effect::MutEffect { state_type: source_type },
                     Effect::MutEffect { state_type: target_type }) =>
                        collect_var_mappings(
                            source_type, target_type, source_vars, result),
                    (Effect::CustomEffect { type_args: source_args, .. },
                     Effect::CustomEffect { type_args: target_args, .. }) => {
                        let mut i = 0
                        while i < source_args.len() && i < target_args.len() {
                            match (source_args.get(i), target_args.get(i)) {
                                (some(source_arg), some(target_arg)) =>
                                    collect_var_mappings(
                                        source_arg, target_arg,
                                        source_vars, result),
                                _ => {}
                            }
                            i = i + 1
                        }
                    },
                    _ => {}
                }
            }
        }
    }
}

fn collect_var_mappings(
    source_type: Type, target_type: Type,
    source_vars: Set<Int>, mut result: Map<Int, Type>
) {
    match source_type {
        Type::TypeVar { id, .. } => {
            if source_vars.contains(id) {
                result.insert(id, target_type)
            }
        },
        Type::StructType { name: source_name, type_params: source_params } =>
            match target_type {
                Type::StructType {
                    name: target_name, type_params: target_params
                } => {
                    if source_name == target_name {
                        let mut i = 0
                        while i < source_params.len() && i < target_params.len() {
                            match (source_params.get(i), target_params.get(i)) {
                                (some(source_param), some(target_param)) =>
                                    collect_var_mappings(
                                        source_param, target_param,
                                        source_vars, result),
                                _ => {}
                            }
                            i = i + 1
                        }
                    }
                },
                _ => {}
            },
        Type::EnumType { name: source_name, type_params: source_params } =>
            match target_type {
                Type::EnumType {
                    name: target_name, type_params: target_params
                } => {
                    if source_name == target_name {
                        let mut i = 0
                        while i < source_params.len() && i < target_params.len() {
                            match (source_params.get(i), target_params.get(i)) {
                                (some(source_param), some(target_param)) =>
                                    collect_var_mappings(
                                        source_param, target_param,
                                        source_vars, result),
                                _ => {}
                            }
                            i = i + 1
                        }
                    }
                },
                _ => {}
            },
        Type::FnType {
            params: source_params, return_type: source_return,
            effects: source_effects, ..
        } => match target_type {
            Type::FnType {
                params: target_params, return_type: target_return,
                effects: target_effects, ..
            } => {
                let mut i = 0
                while i < source_params.len() && i < target_params.len() {
                    match (source_params.get(i), target_params.get(i)) {
                        (some(source_param), some(target_param)) =>
                            collect_var_mappings(
                                source_param, target_param,
                                source_vars, result),
                        _ => {}
                    }
                    i = i + 1
                }
                collect_var_mappings(
                    source_return, target_return, source_vars, result)
                collect_effect_var_mappings(
                    source_effects, target_effects, source_vars, result)
            },
            _ => {}
        },
        Type::TupleType { elements: source_elements } => match target_type {
            Type::TupleType { elements: target_elements } => {
                let mut i = 0
                while i < source_elements.len() && i < target_elements.len() {
                    match (source_elements.get(i), target_elements.get(i)) {
                        (some(source_element), some(target_element)) =>
                            collect_var_mappings(
                                source_element, target_element,
                                source_vars, result),
                        _ => {}
                    }
                    i = i + 1
                }
            },
            _ => {}
        },
        Type::GenericType { base: source_base, args: source_args } =>
            match target_type {
                Type::GenericType { base: target_base, args: target_args } => {
                    collect_var_mappings(
                        source_base, target_base, source_vars, result)
                    let mut i = 0
                    while i < source_args.len() && i < target_args.len() {
                        match (source_args.get(i), target_args.get(i)) {
                            (some(source_arg), some(target_arg)) =>
                                collect_var_mappings(
                                    source_arg, target_arg,
                                    source_vars, result),
                            _ => {}
                        }
                        i = i + 1
                    }
                },
                _ => {}
            },
        Type::RecordType { fields: source_fields, tail: source_tail, .. } =>
            match target_type {
                Type::RecordType { fields: target_fields, tail: target_tail, .. } => {
                    for source_field in source_fields {
                        match target_fields.find(fn(field) {
                            field.name == source_field.name
                        }) {
                            some(target_field) => collect_var_mappings(
                                source_field.ty, target_field.ty,
                                source_vars, result),
                            none => {}
                        }
                    }
                    match (source_tail, target_tail) {
                        (some(source_id), some(target_id)) => {
                            if source_vars.contains(source_id) {
                                result.insert(source_id, Type::TypeVar {
                                    id: target_id, name: none
                                })
                            }
                        },
                        _ => {}
                    }
                },
                _ => {}
            },
        Type::PtrType { pointee: source_pointee } => match target_type {
            Type::PtrType { pointee: target_pointee } =>
                collect_var_mappings(
                    source_pointee, target_pointee, source_vars, result),
            _ => {}
        },
        Type::EffectRowType {
            effects: source_effects, tail: source_tail
        } => match target_type {
            Type::EffectRowType {
                effects: target_effects, tail: target_tail
            } => collect_effect_var_mappings(
                EffectRow { effects: source_effects, tail: source_tail },
                EffectRow { effects: target_effects, tail: target_tail },
                source_vars, result),
            _ => {}
        },
        _ => {}
    }
}

pub fn build_type_var_map(
    source_type: Type, target_type: Type, source_var_ids: List<Int>
) -> Map<Int, Type> {
    let mut result: Map<Int, Type> = map_new()
    collect_var_mappings(
        source_type, target_type, set_from(source_var_ids), result)
    result
}

pub fn build_scheme_var_map(
    scheme: TypeScheme, instantiated_type: Type
) -> Map<Int, Type> {
    build_type_var_map(scheme.ty, instantiated_type, scheme.type_vars)
}

fn collect_type_var_ids(t: Type, mut result: Set<Int>) {
    match t {
        Type::TypeVar { id, .. } => { result.insert(id) },
        Type::FnType { params, return_type, effects, .. } => {
            for param in params { collect_type_var_ids(param, result) }
            collect_type_var_ids(return_type, result)
            match effects.tail {
                some(id) => { result.insert(id) }, none => {}
            }
            for eff in effects.effects {
                match eff {
                    Effect::FailEffect { error_type } =>
                        collect_type_var_ids(error_type, result),
                    Effect::MutEffect { state_type } =>
                        collect_type_var_ids(state_type, result),
                    Effect::CustomEffect { type_args, .. } => {
                        for arg in type_args { collect_type_var_ids(arg, result) }
                    },
                    _ => {}
                }
            }
        },
        Type::StructType { type_params, .. } => {
            for param in type_params { collect_type_var_ids(param, result) }
        },
        Type::EnumType { type_params, .. } => {
            for param in type_params { collect_type_var_ids(param, result) }
        },
        Type::GenericType { base, args } => {
            collect_type_var_ids(base, result)
            for arg in args { collect_type_var_ids(arg, result) }
        },
        Type::RecordType { fields, tail, .. } => {
            for field in fields { collect_type_var_ids(field.ty, result) }
            match tail { some(id) => { result.insert(id) }, none => {} }
        },
        Type::TupleType { elements } => {
            for element in elements { collect_type_var_ids(element, result) }
        },
        Type::PtrType { pointee } => collect_type_var_ids(pointee, result),
        Type::EffectRowType { effects, tail } => {
            match tail { some(id) => { result.insert(id) }, none => {} }
            for eff in effects {
                match eff {
                    Effect::FailEffect { error_type } =>
                        collect_type_var_ids(error_type, result),
                    Effect::MutEffect { state_type } =>
                        collect_type_var_ids(state_type, result),
                    Effect::CustomEffect { type_args, .. } => {
                        for arg in type_args { collect_type_var_ids(arg, result) }
                    },
                    _ => {}
                }
            }
        },
        _ => {}
    }
}

// Specialize a trait declaration method for one concrete/generic impl owner.
// Default methods and built-in impl entries share this exact construction.
pub fn specialize_trait_method_scheme(
    trait_def: TraitDef, method: TraitMethodDef,
    self_type: Type, trait_type_args: List<Type>,
    impl_type_vars: List<Int>, assoc_types: Map<Str, Type>,
    bounds: List<SchemeBound>
) -> TypeScheme {
    let mut mapping: Map<Int, Type> = map_new()
    match method.ty {
        Type::FnType { params, .. } => match params.first() {
            some(receiver) => {
                let mut receiver_vars: Set<Int> = set_new()
                collect_type_var_ids(receiver, receiver_vars)
                let receiver_map = build_type_var_map(
                    receiver, self_type, receiver_vars.to_list())
                let mut receiver_ids = receiver_map.keys()
                receiver_ids.sort()
                for id in receiver_ids {
                    match receiver_map.get(id) {
                        some(mapped) => mapping.insert(id, mapped),
                        none => {}
                    }
                }
            },
            none => {}
        },
        _ => {}
    }

    let mut trait_index = 0
    while trait_index < trait_def.type_params.len() &&
          trait_index < trait_def.type_param_vars.len() &&
          trait_index < trait_type_args.len() {
        match (trait_def.type_param_vars.get(trait_index),
               trait_type_args.get(trait_index)) {
            (some(source_id), some(target_type)) =>
                mapping.insert(source_id, target_type),
            _ => {}
        }
        trait_index = trait_index + 1
    }
    for assoc_def in trait_def.assoc_types {
        match assoc_types.get(assoc_def.name) {
            some(concrete) => mapping.insert(assoc_def.var_id, concrete),
            none => {}
        }
    }

    let specialized_type = apply_subst_map(mapping, method.ty)
    let mut quantified = list_clone(impl_type_vars)
    let mut remaining: Set<Int> = set_new()
    collect_type_var_ids(specialized_type, remaining)
    let mut remaining_ids = remaining.to_list()
    remaining_ids.sort()
    for id in remaining_ids {
        if !quantified.contains(id) { quantified.push(id) }
    }
    TypeScheme {
        ty: specialized_type,
        type_vars: quantified,
        bounds: bounds,
        def_id: none
    }
}

// ============================================================
// Union-Find substitution: apply UnionFind-based substitution to a type.
// This is the primary apply_subst used by the type inference engine.
// Uses uf_find for O(alpha(n)) path-compressed type variable resolution.
// ============================================================

pub fn apply_subst(subst: UnionFind, t: Type) -> Type {
    match t {
        Type::IntType => Type::IntType,
        Type::FloatType => Type::FloatType,
        Type::StrType => Type::StrType,
        Type::BoolType => Type::BoolType,
        Type::UnitType => Type::UnitType,
        Type::NeverType => Type::NeverType,
        Type::AnyType => Type::AnyType,
        Type::TypeVar { id, name } => match uf_lookup(subst, id) {
            some(resolved) => apply_subst(subst, resolved),
            none => {
                // Always construct a new TypeVar to avoid returning borrowed `t`.
                // Perceus treats Call results as owned and inserts scope-end Drop;
                // returning the borrowed parameter `t` would cause UAF on the
                // original holder (UF table / effect list).
                let root = uf_find(subst, id)
                Type::TypeVar { id: root, name: name }
            }
        },
        Type::FnType { params, return_type, effects, ownership_term } =>
            Type::FnType {
                params: params.map(fn(p) { apply_subst(subst, p) }),
                return_type: apply_subst(subst, return_type),
                effects: apply_subst_row(subst, effects),
                ownership_term: ownership_term
            },
        Type::StructType { name, type_params } =>
            Type::StructType {
                name: name,
                type_params: type_params.map(fn(p) { apply_subst(subst, p) })
            },
        Type::EnumType { name, type_params } =>
            Type::EnumType {
                name: name,
                type_params: type_params.map(fn(p) { apply_subst(subst, p) })
            },
        Type::GenericType { base, args } =>
            Type::GenericType {
                base: apply_subst(subst, base),
                args: args.map(fn(a) { apply_subst(subst, a) })
            },
        Type::RecordType { fields, tail, tail_name } => {
            let mapped_fields = fields.map(fn(f) {
                RecordField { name: f.name, ty: apply_subst(subst, f.ty) }
            })
            match tail {
                some(t_id) => {
                    let root_id = uf_find(subst, t_id)
                    match uf_lookup(subst, root_id) {
                        some(resolved) => {
                            let chased = apply_subst(subst, resolved)
                            match chased {
                                Type::TypeVar { id: new_id, name: new_name } =>
                                    Type::RecordType { fields: mapped_fields, tail: some(new_id), tail_name: new_name },
                                Type::RecordType { fields: extra_fields, tail: extra_tail, tail_name: extra_tn } => {
                                    let mut all_fields = list_clone(mapped_fields)
                                    for ef in extra_fields {
                                        all_fields.push(RecordField { name: ef.name, ty: apply_subst(subst, ef.ty) })
                                    }
                                    Type::RecordType { fields: all_fields, tail: extra_tail, tail_name: extra_tn }
                                },
                                _ => Type::RecordType { fields: mapped_fields, tail: none, tail_name: none }
                            }
                        },
                        none => {
                            let actual_id = if root_id == t_id { t_id } else { root_id }
                            Type::RecordType { fields: mapped_fields, tail: some(actual_id), tail_name: tail_name }
                        }
                    }
                },
                none => Type::RecordType { fields: mapped_fields, tail: none, tail_name: tail_name }
            }
        },
        Type::EffectRowType { effects, tail } => {
            let row = apply_subst_row(subst, EffectRow { effects: effects, tail: tail })
            Type::EffectRowType { effects: row.effects, tail: row.tail }
        },
        Type::TupleType { elements } =>
            Type::TupleType { elements: elements.map(fn(e) { apply_subst(subst, e) }) },
        Type::PtrType { pointee } =>
            Type::PtrType { pointee: apply_subst(subst, pointee) },
        Type::ErrorType => Type::ErrorType
    }
}

fn apply_subst_effect(subst: UnionFind, e: Effect) -> Effect {
    match e {
        Effect::FailEffect { error_type } =>
            Effect::FailEffect { error_type: apply_subst(subst, error_type) },
        Effect::MutEffect { state_type } =>
            Effect::MutEffect { state_type: apply_subst(subst, state_type) },
        Effect::CustomEffect { name, type_args } =>
            Effect::CustomEffect { name: name, type_args: type_args.map(fn(a) { apply_subst(subst, a) }) },
        Effect::IoEffect => Effect::IoEffect,
        Effect::UnsafeEffect => Effect::UnsafeEffect
    }
}

pub fn apply_subst_row(subst: UnionFind, row: EffectRow) -> EffectRow {
    let effects = row.effects.map(fn(e) { apply_subst_effect(subst, e) })
    match row.tail {
        some(t_id) => {
            let root_id = uf_find(subst, t_id)
            match uf_lookup(subst, root_id) {
                some(resolved) => {
                    let chased = apply_subst(subst, resolved)
                    match chased {
                        Type::TypeVar { id: new_id, .. } =>
                            EffectRow { effects: effects, tail: some(new_id) },
                        Type::EffectRowType { effects: extra_effs, tail: extra_tail } => {
                            let mut merged = list_clone(effects)
                            for ee in extra_effs {
                                merged.push(apply_subst_effect(subst, ee))
                            }
                            EffectRow { effects: merged, tail: extra_tail }
                        },
                        _ => EffectRow { effects: effects, tail: none }
                    }
                },
                none => {
                    let actual_id = if root_id == t_id { t_id } else { root_id }
                    EffectRow { effects: effects, tail: some(actual_id) }
                }
            }
        },
        none => EffectRow { effects: effects, tail: none }
    }
}
