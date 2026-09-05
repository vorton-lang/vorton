use std::collections::{BTreeMap, BTreeSet};

use crate::ast::*;
use crate::project::*;

const LANGUAGE_TYPES: &[&str] = &[
    "Int", "Float", "Str", "Bool", "Unit", "Never", "Option", "List", "Range", "Ptr",
];
const LANGUAGE_TRAITS: &[&str] = &[
    "Eq", "Hash", "Clone", "Debug", "Ord", "Drop", "Iterable", "Iterator",
];
const LANGUAGE_EFFECTS: &[&str] = &["console", "fs", "process", "fail", "mut", "unsafe"];

pub(crate) fn resolve_project(
    sources: &ProjectSources,
) -> Result<ResolvedProject, ProjectDiagnostic> {
    let parsed = parse_reachable_sources(sources)?;
    let modules = build_module_graph(sources, &parsed)?;
    let mut state = ResolverState::new(modules);
    state.index_entities()?;
    state.resolve_imports()?;
    state.resolve_bodies()
}

#[derive(Clone)]
struct ParsedSource {
    origin: SourceRef,
    program: Program,
}

fn parse_reachable_sources(
    sources: &ProjectSources,
) -> Result<BTreeMap<ModuleRef, ParsedSource>, ProjectDiagnostic> {
    let inventory = inventory_modules(sources);
    let file_sources = sources
        .modules
        .iter()
        .map(|(path, source)| (ModuleRef::from(path), (path, source)))
        .collect::<BTreeMap<_, _>>();
    let mut attempted = BTreeSet::new();
    let mut parsed = BTreeMap::new();
    let mut failures = BTreeMap::<ModuleRef, ProjectDiagnostic>::new();
    let mut pending = BTreeSet::from([ModuleRef::root()]);

    loop {
        while let Some(module) = pending.pop_first() {
            if !attempted.insert(module.clone()) {
                continue;
            }
            let (origin, source) = if module.0.is_empty() {
                (SourceRef::Root, sources.root.as_str())
            } else {
                let Some((path, source)) = file_sources.get(&module) else {
                    continue;
                };
                (SourceRef::File((*path).clone()), source.as_str())
            };
            match crate::parse(source) {
                Ok(program) => {
                    parsed.insert(module, ParsedSource { origin, program });
                }
                Err(diagnostic) => {
                    failures.insert(
                        module,
                        ProjectDiagnostic {
                            kind: ProjectDiagnosticKind::Frontend(diagnostic.kind),
                            primary: Some(OriginRef {
                                source: origin,
                                span: diagnostic.span,
                            }),
                            related: Vec::new(),
                        },
                    );
                }
            }
        }

        let (known_modules, uses) = discovery_snapshot(&inventory, &parsed);
        let (aliases, visited) = discover_module_aliases(&known_modules, &uses);
        let mut newly_reachable = visited;
        for (module, use_declaration) in &uses {
            newly_reachable.extend(modules_named_by_use(
                module,
                use_declaration,
                &known_modules,
                &aliases,
            ));
        }
        newly_reachable.retain(|module| file_sources.contains_key(module));
        newly_reachable.retain(|module| !attempted.contains(module));
        if newly_reachable.is_empty() {
            break;
        }
        pending = newly_reachable;
    }

    if let Some((_, diagnostic)) = failures.pop_first() {
        return Err(diagnostic);
    }
    Ok(parsed)
}

fn inventory_modules(sources: &ProjectSources) -> BTreeSet<ModuleRef> {
    let mut modules = BTreeSet::from([ModuleRef::root()]);
    for path in sources.modules.keys() {
        for length in 1..=path.segments().len() {
            modules.insert(ModuleRef(path.segments()[..length].to_vec()));
        }
    }
    modules
}

fn discovery_snapshot(
    inventory: &BTreeSet<ModuleRef>,
    parsed: &BTreeMap<ModuleRef, ParsedSource>,
) -> (BTreeSet<ModuleRef>, Vec<(ModuleRef, UseDeclaration)>) {
    let mut modules = inventory.clone();
    let mut uses = Vec::new();
    for (module, source) in parsed {
        collect_discovery_items(
            module,
            &source.program.uses,
            &source.program.declarations,
            &mut modules,
            &mut uses,
        );
    }
    (modules, uses)
}

fn collect_discovery_items(
    module: &ModuleRef,
    module_uses: &[UseDeclaration],
    declarations: &[Declaration],
    modules: &mut BTreeSet<ModuleRef>,
    uses: &mut Vec<(ModuleRef, UseDeclaration)>,
) {
    uses.extend(
        module_uses
            .iter()
            .cloned()
            .map(|use_declaration| (module.clone(), use_declaration)),
    );
    for declaration in declarations {
        if let DeclarationKind::Module(declared) = &declaration.kind {
            let child = module.child(&declared.item.name.text);
            modules.insert(child.clone());
            collect_discovery_items(
                &child,
                &declared.item.uses,
                &declared.item.declarations,
                modules,
                uses,
            );
        }
    }
}

type ModuleAliases = BTreeMap<(ModuleRef, String), BTreeSet<ModuleRef>>;

fn discover_module_aliases(
    modules: &BTreeSet<ModuleRef>,
    uses: &[(ModuleRef, UseDeclaration)],
) -> (ModuleAliases, BTreeSet<ModuleRef>) {
    let mut aliases = ModuleAliases::new();
    let mut all_visited = BTreeSet::new();
    loop {
        let mut changed = false;
        for (module, declaration) in uses {
            let (base_targets, visited) =
                scan_module_path(module, &declaration.path, modules, &aliases);
            all_visited.extend(visited);
            match &declaration.suffix {
                Some(UseSuffix::Items { items, .. }) => {
                    for item in items {
                        let mut targets = BTreeSet::new();
                        for base in &base_targets {
                            targets.extend(module_children_named(
                                base,
                                &item.name.text,
                                modules,
                                &aliases,
                            ));
                        }
                        all_visited.extend(targets.iter().cloned());
                        let local_name = item.alias.as_ref().unwrap_or(&item.name).text.clone();
                        let entry = aliases.entry((module.clone(), local_name)).or_default();
                        let old_length = entry.len();
                        entry.extend(targets);
                        changed |= entry.len() != old_length;
                    }
                }
                suffix => {
                    let local_name = match suffix {
                        Some(UseSuffix::Alias(alias)) => Some(alias.text.clone()),
                        None => path_terminal_name(&declaration.path),
                        Some(UseSuffix::Items { .. }) => unreachable!(),
                    };
                    if let Some(local_name) = local_name {
                        let entry = aliases.entry((module.clone(), local_name)).or_default();
                        let old_length = entry.len();
                        entry.extend(base_targets);
                        changed |= entry.len() != old_length;
                    }
                }
            }
        }
        if !changed {
            break;
        }
    }
    (aliases, all_visited)
}

fn modules_named_by_use(
    module: &ModuleRef,
    declaration: &UseDeclaration,
    modules: &BTreeSet<ModuleRef>,
    aliases: &ModuleAliases,
) -> BTreeSet<ModuleRef> {
    let (targets, mut visited) = scan_module_path(module, &declaration.path, modules, aliases);
    if let Some(UseSuffix::Items { items, .. }) = &declaration.suffix {
        for target in targets {
            for item in items {
                let children = module_children_named(&target, &item.name.text, modules, aliases);
                visited.extend(children);
            }
        }
    }
    visited
}

fn scan_module_path(
    current: &ModuleRef,
    path: &Path,
    modules: &BTreeSet<ModuleRef>,
    aliases: &ModuleAliases,
) -> (BTreeSet<ModuleRef>, BTreeSet<ModuleRef>) {
    let mut visited = BTreeSet::new();
    let Some((mut candidates, start_index)) = module_path_start(current, path, modules, aliases)
    else {
        return (BTreeSet::new(), visited);
    };
    visited.extend(candidates.iter().cloned());
    for segment in &path.segments[start_index..] {
        let PathSegment::Identifier(identifier) = segment else {
            return (BTreeSet::new(), visited);
        };
        let mut next = BTreeSet::new();
        for candidate in &candidates {
            next.extend(module_children_named(
                candidate,
                &identifier.text,
                modules,
                aliases,
            ));
        }
        if next.is_empty() {
            return (BTreeSet::new(), visited);
        }
        visited.extend(next.iter().cloned());
        candidates = next;
    }
    (candidates, visited)
}

fn module_path_start(
    current: &ModuleRef,
    path: &Path,
    modules: &BTreeSet<ModuleRef>,
    aliases: &ModuleAliases,
) -> Option<(BTreeSet<ModuleRef>, usize)> {
    let first = path.segments.first()?;
    match first {
        PathSegment::Super(_) => {
            let mut base = current.clone();
            let mut index = 0;
            while matches!(path.segments.get(index), Some(PathSegment::Super(_))) {
                base = base.parent()?;
                index += 1;
            }
            Some((BTreeSet::from([base]), index))
        }
        PathSegment::Identifier(identifier)
            if path.segments.len() > 1 && identifier.text == "root" =>
        {
            Some((BTreeSet::from([ModuleRef::root()]), 1))
        }
        PathSegment::Identifier(identifier)
            if path.segments.len() > 1 && identifier.text == "self" =>
        {
            Some((BTreeSet::from([current.clone()]), 1))
        }
        PathSegment::Identifier(identifier) => {
            let candidates = module_children_named(current, &identifier.text, modules, aliases);
            (!candidates.is_empty()).then_some((candidates, 1))
        }
    }
}

fn module_children_named(
    module: &ModuleRef,
    name: &str,
    modules: &BTreeSet<ModuleRef>,
    aliases: &ModuleAliases,
) -> BTreeSet<ModuleRef> {
    let mut children = aliases
        .get(&(module.clone(), name.to_owned()))
        .cloned()
        .unwrap_or_default();
    let direct = module.child(name);
    if modules.contains(&direct) {
        children.insert(direct);
    }
    children
}

fn path_terminal_name(path: &Path) -> Option<String> {
    match path.segments.last()? {
        PathSegment::Identifier(identifier) => Some(identifier.text.clone()),
        PathSegment::Super(_) => None,
    }
}

#[derive(Clone)]
struct ModuleBodyAst {
    origin: SourceRef,
    span: Span,
    requires: Option<EffectSet>,
    uses: Vec<UseDeclaration>,
    declarations: Vec<Declaration>,
}

#[derive(Clone)]
struct ModuleInfo {
    body: Option<ModuleBodyAst>,
    file_body_present: bool,
    declared_at: Option<OriginRef>,
    public: bool,
}

fn build_module_graph(
    sources: &ProjectSources,
    parsed: &BTreeMap<ModuleRef, ParsedSource>,
) -> Result<BTreeMap<ModuleRef, ModuleInfo>, ProjectDiagnostic> {
    let mut modules = BTreeMap::from([(
        ModuleRef::root(),
        ModuleInfo {
            body: None,
            file_body_present: false,
            declared_at: None,
            public: true,
        },
    )]);
    for path in sources.modules.keys() {
        for length in 1..=path.segments().len() {
            let module = ModuleRef(path.segments()[..length].to_vec());
            let exact = length == path.segments().len();
            modules
                .entry(module)
                .and_modify(|info| info.file_body_present |= exact)
                .or_insert(ModuleInfo {
                    body: None,
                    file_body_present: exact,
                    declared_at: None,
                    public: true,
                });
        }
    }

    for (module, parsed_source) in parsed {
        let body = ModuleBodyAst {
            origin: parsed_source.origin.clone(),
            span: parsed_source.program.span,
            requires: parsed_source
                .program
                .requires
                .as_ref()
                .map(|requires| requires.effects.clone()),
            uses: parsed_source.program.uses.clone(),
            declarations: parsed_source.program.declarations.clone(),
        };
        modules
            .entry(module.clone())
            .or_insert(ModuleInfo {
                body: None,
                file_body_present: !module.0.is_empty(),
                declared_at: None,
                public: true,
            })
            .body = Some(body);
    }

    for (module, parsed_source) in parsed {
        register_inline_modules(
            module,
            &parsed_source.origin,
            &parsed_source.program.declarations,
            &mut modules,
        )?;
    }
    Ok(modules)
}

fn register_inline_modules(
    parent: &ModuleRef,
    source: &SourceRef,
    declarations: &[Declaration],
    modules: &mut BTreeMap<ModuleRef, ModuleInfo>,
) -> Result<(), ProjectDiagnostic> {
    for declaration in declarations {
        let DeclarationKind::Module(declared) = &declaration.kind else {
            continue;
        };
        let name = &declared.item.name;
        if is_reserved_module_segment(&name.text) {
            return Err(ProjectDiagnostic {
                kind: ProjectDiagnosticKind::InvalidModuleName {
                    name: name.text.clone(),
                },
                primary: Some(OriginRef {
                    source: source.clone(),
                    span: name.span,
                }),
                related: Vec::new(),
            });
        }
        let module = parent.child(&name.text);
        let origin = OriginRef {
            source: source.clone(),
            span: name.span,
        };
        let entry = modules.entry(module.clone()).or_insert(ModuleInfo {
            body: None,
            file_body_present: false,
            declared_at: None,
            public: declared.visibility.is_some(),
        });
        if entry.file_body_present || entry.body.is_some() {
            let related = entry.declared_at.clone().into_iter().collect();
            return Err(ProjectDiagnostic {
                kind: ProjectDiagnosticKind::ModuleBodyConflict { module: module.0 },
                primary: Some(origin),
                related,
            });
        }
        entry.declared_at = Some(origin);
        entry.public = declared.visibility.is_some();
        entry.body = Some(ModuleBodyAst {
            origin: source.clone(),
            span: declaration.span,
            requires: declared.item.requires.clone(),
            uses: declared.item.uses.clone(),
            declarations: declared.item.declarations.clone(),
        });
        register_inline_modules(&module, source, &declared.item.declarations, modules)?;
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Delivery {
    target: EntityId,
    public: bool,
    owner_module: ModuleRef,
    origin: Option<OriginRef>,
}

type BindingTable = BTreeMap<(Namespace, String), BTreeMap<EntityId, Delivery>>;

#[derive(Clone)]
struct ImportDirective {
    module: ModuleRef,
    origin: OriginRef,
    public: bool,
    path: Path,
    local_name: String,
    candidates: BTreeSet<EntityId>,
    inaccessible: BTreeSet<EntityId>,
    invalid: Option<ProjectDiagnosticKind>,
}

struct ResolverState {
    modules: BTreeMap<ModuleRef, ModuleInfo>,
    entities: BTreeMap<EntityId, Entity>,
    own_bindings: BTreeMap<ModuleRef, BindingTable>,
    bindings: BTreeMap<ModuleRef, BindingTable>,
    imports: Vec<ImportDirective>,
}

impl ResolverState {
    fn new(modules: BTreeMap<ModuleRef, ModuleInfo>) -> Self {
        Self {
            modules,
            entities: BTreeMap::new(),
            own_bindings: BTreeMap::new(),
            bindings: BTreeMap::new(),
            imports: Vec::new(),
        }
    }

    fn index_entities(&mut self) -> Result<(), ProjectDiagnostic> {
        self.index_language_entities();
        self.index_modules();
        let bodies = self
            .modules
            .iter()
            .filter_map(|(module, info)| info.body.clone().map(|body| (module.clone(), body)))
            .collect::<Vec<_>>();
        for (module, body) in bodies {
            self.index_declarations(&module, &body)?;
            self.imports
                .extend(flatten_imports(&module, &body.origin, &body.uses));
        }
        self.check_own_bindings()?;
        self.bindings = self.own_bindings.clone();
        Ok(())
    }

    fn index_language_entities(&mut self) {
        for name in LANGUAGE_TYPES {
            self.insert_language_entity(Namespace::Type, EntityKind::LanguageType, name, None);
        }
        for name in LANGUAGE_TRAITS {
            self.insert_language_entity(Namespace::Type, EntityKind::LanguageTrait, name, None);
        }
        for name in LANGUAGE_EFFECTS {
            self.insert_language_entity(Namespace::Effect, EntityKind::LanguageEffect, name, None);
        }

        let option = language_id(Namespace::Type, EntityKind::LanguageType, "Option", None);
        for (name, shape) in [
            ("Some", EntityShape::ConstructorPositional),
            ("None", EntityShape::ConstructorUnit),
        ] {
            let owner = OwnerKey {
                module: ModuleRef::root(),
                source: SourceRef::Root,
                span: Span::new(0, 0),
                kind: EntityKind::LanguageType,
                name: "Option".to_owned(),
            };
            let id = language_id(
                Namespace::Value,
                EntityKind::LanguageConstructor,
                name,
                Some(owner),
            );
            self.entities.insert(
                id.clone(),
                Entity {
                    id: id.clone(),
                    declared_at: None,
                    public: true,
                    owner: Some(option.clone()),
                    members: BTreeMap::new(),
                    shape,
                },
            );
            self.entities
                .get_mut(&option)
                .expect("Option language entity exists")
                .members
                .entry(name.to_owned())
                .or_default()
                .push(id);
        }
    }

    fn insert_language_entity(
        &mut self,
        namespace: Namespace,
        kind: EntityKind,
        name: &str,
        owner: Option<OwnerKey>,
    ) {
        let id = language_id(namespace, kind, name, owner);
        self.entities.insert(
            id.clone(),
            Entity {
                id,
                declared_at: None,
                public: true,
                owner: None,
                members: BTreeMap::new(),
                shape: EntityShape::Plain,
            },
        );
    }

    fn index_modules(&mut self) {
        let modules = self.modules.clone();
        for (module, info) in modules {
            self.own_bindings.entry(module.clone()).or_default();
            if module.0.is_empty() {
                continue;
            }
            let id = module_id(&module);
            self.entities.insert(
                id.clone(),
                Entity {
                    id: id.clone(),
                    declared_at: info.declared_at.clone(),
                    public: info.public,
                    owner: None,
                    members: BTreeMap::new(),
                    shape: EntityShape::Plain,
                },
            );
            let parent = module.parent().expect("non-root module has a parent");
            let name = module.0.last().expect("non-root module has a name").clone();
            add_delivery(
                self.own_bindings.entry(parent.clone()).or_default(),
                Delivery {
                    target: id,
                    public: info.public,
                    owner_module: parent,
                    origin: info.declared_at,
                },
                Namespace::Type,
                name,
            );
        }
    }

    fn index_declarations(
        &mut self,
        module: &ModuleRef,
        body: &ModuleBodyAst,
    ) -> Result<(), ProjectDiagnostic> {
        for declaration in &body.declarations {
            let Some((id, public)) = declaration_entity(module, &body.origin, declaration) else {
                self.index_impl_members(module, &body.origin, declaration)?;
                continue;
            };
            if id.kind == EntityKind::Module {
                continue;
            }
            let declared_at = match &id.site {
                EntitySite::Source(origin) => Some(origin.clone()),
                EntitySite::Language | EntitySite::Module(_) => None,
            };
            self.entities.insert(
                id.clone(),
                Entity {
                    id: id.clone(),
                    declared_at: declared_at.clone(),
                    public,
                    owner: None,
                    members: BTreeMap::new(),
                    shape: EntityShape::Plain,
                },
            );
            add_delivery(
                self.own_bindings.entry(module.clone()).or_default(),
                Delivery {
                    target: id.clone(),
                    public,
                    owner_module: module.clone(),
                    origin: declared_at,
                },
                id.namespace,
                id.name.clone(),
            );
            self.index_owned_members(module, &body.origin, declaration, &id)?;
        }
        Ok(())
    }

    fn index_owned_members(
        &mut self,
        module: &ModuleRef,
        source: &SourceRef,
        declaration: &Declaration,
        owner: &EntityId,
    ) -> Result<(), ProjectDiagnostic> {
        let owner_key = owner_key_from_entity(owner);
        match &declaration.kind {
            DeclarationKind::Struct(declared) => {
                for field in &declared.item.fields {
                    let id = source_id(
                        module,
                        source,
                        field.name.span,
                        Namespace::Member,
                        EntityKind::Field,
                        &field.name.text,
                        Some(owner_key.clone()),
                    );
                    self.insert_member(owner, id, field.visibility.is_some(), EntityShape::Plain)?;
                }
                self.insert_self_entity(module, source, owner);
            }
            DeclarationKind::Enum(declared) => {
                for variant in &declared.item.variants {
                    let shape = match &variant.fields {
                        VariantFields::Unit => EntityShape::ConstructorUnit,
                        VariantFields::Positional(_) => EntityShape::ConstructorPositional,
                        VariantFields::Named(_) => EntityShape::ConstructorNamed,
                    };
                    let variant_id = source_id(
                        module,
                        source,
                        variant.name.span,
                        Namespace::Value,
                        EntityKind::EnumConstructor,
                        &variant.name.text,
                        Some(owner_key.clone()),
                    );
                    self.insert_member(
                        owner,
                        variant_id.clone(),
                        owner_public(self, owner),
                        shape,
                    )?;
                    let variant_owner = owner_key_from_entity(&variant_id);
                    match &variant.fields {
                        VariantFields::Unit => {}
                        VariantFields::Positional(fields) => {
                            for (index, field) in fields.iter().enumerate() {
                                let id = source_id(
                                    module,
                                    source,
                                    field.span,
                                    Namespace::Member,
                                    EntityKind::Field,
                                    &format!("#{index}"),
                                    Some(variant_owner.clone()),
                                );
                                self.insert_member(&variant_id, id, true, EntityShape::Plain)?;
                            }
                        }
                        VariantFields::Named(fields) => {
                            for field in fields {
                                let id = source_id(
                                    module,
                                    source,
                                    field.name.span,
                                    Namespace::Member,
                                    EntityKind::Field,
                                    &field.name.text,
                                    Some(variant_owner.clone()),
                                );
                                self.insert_member(&variant_id, id, true, EntityShape::Plain)?;
                            }
                        }
                    }
                }
                self.insert_self_entity(module, source, owner);
            }
            DeclarationKind::Trait(declared) => {
                for member in &declared.item.members {
                    let (name, namespace, kind) = match &member.kind {
                        TraitMemberKind::Method(method) => {
                            (&method.name, Namespace::Value, EntityKind::Method)
                        }
                        TraitMemberKind::AssociatedType(associated) => (
                            &associated.name,
                            Namespace::Type,
                            EntityKind::AssociatedType,
                        ),
                    };
                    let id = source_id(
                        module,
                        source,
                        name.span,
                        namespace,
                        kind,
                        &name.text,
                        Some(owner_key.clone()),
                    );
                    self.insert_member(owner, id, owner_public(self, owner), EntityShape::Plain)?;
                }
                self.insert_self_entity(module, source, owner);
            }
            DeclarationKind::Effect(declared) => {
                for operation in &declared.item.operations {
                    let id = source_id(
                        module,
                        source,
                        operation.name.span,
                        Namespace::Value,
                        EntityKind::EffectOperation,
                        &operation.name.text,
                        Some(owner_key.clone()),
                    );
                    self.insert_member(owner, id, owner_public(self, owner), EntityShape::Plain)?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn index_impl_members(
        &mut self,
        module: &ModuleRef,
        source: &SourceRef,
        declaration: &Declaration,
    ) -> Result<(), ProjectDiagnostic> {
        let (members, owner_kind) = match &declaration.kind {
            DeclarationKind::InherentImpl(implementation) => {
                (&implementation.members, EntityKind::InherentImpl)
            }
            DeclarationKind::TraitImpl(implementation) => {
                (&implementation.members, EntityKind::TraitImpl)
            }
            _ => return Ok(()),
        };
        let owner = OwnerKey {
            module: module.clone(),
            source: source.clone(),
            span: declaration.span,
            kind: owner_kind,
            name: "impl".to_owned(),
        };
        let mut seen = BTreeMap::<(Namespace, String), OriginRef>::new();
        for member in members {
            let (name, namespace, kind) = match &member.kind {
                ImplMemberKind::Function(function) => {
                    (&function.name, Namespace::Value, EntityKind::Method)
                }
                ImplMemberKind::AssociatedType(associated) => (
                    &associated.name,
                    Namespace::Type,
                    EntityKind::AssociatedType,
                ),
            };
            let origin = OriginRef {
                source: source.clone(),
                span: name.span,
            };
            if let Some(previous) = seen.insert((namespace, name.text.clone()), origin.clone()) {
                return Err(ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::MemberConflict {
                        name: name.text.clone(),
                    },
                    primary: Some(origin),
                    related: vec![previous],
                });
            }
            let id = source_id(
                module,
                source,
                name.span,
                namespace,
                kind,
                &name.text,
                Some(owner.clone()),
            );
            self.entities.insert(
                id.clone(),
                Entity {
                    id,
                    declared_at: Some(origin),
                    public: member.visibility.is_some(),
                    owner: None,
                    members: BTreeMap::new(),
                    shape: EntityShape::Plain,
                },
            );
        }
        self.insert_impl_self(module, source, declaration.span, owner_kind);
        Ok(())
    }

    fn insert_member(
        &mut self,
        owner: &EntityId,
        id: EntityId,
        public: bool,
        shape: EntityShape,
    ) -> Result<(), ProjectDiagnostic> {
        let declared_at = match &id.site {
            EntitySite::Source(origin) => Some(origin.clone()),
            EntitySite::Language | EntitySite::Module(_) => None,
        };
        let existing = self
            .entities
            .get(owner)
            .and_then(|entity| entity.members.get(&id.name))
            .into_iter()
            .flatten()
            .find(|candidate| candidate.namespace == id.namespace)
            .cloned();
        if let Some(existing) = existing {
            return Err(ProjectDiagnostic {
                kind: ProjectDiagnosticKind::MemberConflict {
                    name: id.name.clone(),
                },
                primary: declared_at,
                related: self
                    .entities
                    .get(&existing)
                    .and_then(|entity| entity.declared_at.clone())
                    .into_iter()
                    .collect(),
            });
        }
        self.entities.insert(
            id.clone(),
            Entity {
                id: id.clone(),
                declared_at,
                public,
                owner: Some(owner.clone()),
                members: BTreeMap::new(),
                shape,
            },
        );
        self.entities
            .get_mut(owner)
            .expect("member owner is indexed before its members")
            .members
            .entry(id.name.clone())
            .or_default()
            .push(id);
        Ok(())
    }

    fn insert_self_entity(&mut self, module: &ModuleRef, source: &SourceRef, owner: &EntityId) {
        let id = source_id(
            module,
            source,
            owner_site_span(owner),
            Namespace::Type,
            EntityKind::SelfType,
            "Self",
            Some(owner_key_from_entity(owner)),
        );
        self.entities.insert(
            id.clone(),
            Entity {
                id,
                declared_at: None,
                public: false,
                owner: Some(owner.clone()),
                members: BTreeMap::new(),
                shape: EntityShape::Plain,
            },
        );
    }

    fn insert_impl_self(
        &mut self,
        module: &ModuleRef,
        source: &SourceRef,
        span: Span,
        kind: EntityKind,
    ) {
        let owner = OwnerKey {
            module: module.clone(),
            source: source.clone(),
            span,
            kind,
            name: "impl".to_owned(),
        };
        let id = source_id(
            module,
            source,
            span,
            Namespace::Type,
            EntityKind::SelfType,
            "Self",
            Some(owner),
        );
        self.entities.insert(
            id.clone(),
            Entity {
                id,
                declared_at: None,
                public: false,
                owner: None,
                members: BTreeMap::new(),
                shape: EntityShape::Plain,
            },
        );
    }

    fn check_own_bindings(&self) -> Result<(), ProjectDiagnostic> {
        for table in self.own_bindings.values() {
            for ((namespace, name), deliveries) in table {
                let Some(public_namespace) = namespace.public() else {
                    continue;
                };
                if is_language_name(*namespace, name)
                    && !deliveries.keys().all(|target| {
                        target.origin == DeclarationOrigin::Language
                            && target.name.as_str() == name.as_str()
                    })
                {
                    let primary = sorted_delivery_origins(deliveries).into_iter().next();
                    return Err(ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::ReservedLanguageBinding {
                            namespace: public_namespace,
                            name: name.clone(),
                        },
                        primary,
                        related: Vec::new(),
                    });
                }
                if deliveries.len() > 1 {
                    let mut origins = sorted_delivery_origins(deliveries).into_iter();
                    let primary = origins.next();
                    return Err(ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::NameConflict {
                            namespace: public_namespace,
                            name: name.clone(),
                        },
                        primary,
                        related: origins.collect(),
                    });
                }
                if *namespace == Namespace::Type && name == "Self" {
                    return Err(ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::InvalidSelf,
                        primary: sorted_delivery_origins(deliveries).into_iter().next(),
                        related: Vec::new(),
                    });
                }
            }
        }
        Ok(())
    }

    fn resolve_imports(&mut self) -> Result<(), ProjectDiagnostic> {
        loop {
            let mut changed = false;
            for index in 0..self.imports.len() {
                let outcome = {
                    let directive = &self.imports[index];
                    self.lookup_import_path(&directive.module, &directive.path)
                };
                let directive = &mut self.imports[index];
                if directive.invalid.is_none() {
                    directive.invalid = outcome.invalid;
                }
                let old_candidates = directive.candidates.len();
                let old_inaccessible = directive.inaccessible.len();
                directive.candidates.extend(outcome.accessible);
                directive.inaccessible.extend(outcome.inaccessible);
                changed |= directive.candidates.len() != old_candidates
                    || directive.inaccessible.len() != old_inaccessible;

                let deliveries = directive.candidates.iter().cloned().collect::<Vec<_>>();
                for target in deliveries {
                    let namespace = target.namespace;
                    if namespace == Namespace::Member {
                        continue;
                    }
                    let table = self.bindings.entry(directive.module.clone()).or_default();
                    let key = (namespace, directive.local_name.clone());
                    let entry = table.entry(key).or_default();
                    if let Some(existing) = entry.get_mut(&target) {
                        let was_public = existing.public;
                        existing.public |= directive.public;
                        changed |= existing.public != was_public;
                    } else {
                        entry.insert(
                            target.clone(),
                            Delivery {
                                target,
                                public: directive.public,
                                owner_module: directive.module.clone(),
                                origin: Some(directive.origin.clone()),
                            },
                        );
                        changed = true;
                    }
                }
            }
            if !changed {
                break;
            }
        }

        self.check_import_directives()?;
        self.check_import_bindings()?;
        self.check_constructor_owner_closure()?;
        Ok(())
    }

    fn lookup_import_path(&self, module: &ModuleRef, path: &Path) -> LookupOutcome {
        self.lookup_global_path(module, module, path)
    }

    fn lookup_global_path(
        &self,
        current: &ModuleRef,
        requester: &ModuleRef,
        path: &Path,
    ) -> LookupOutcome {
        let Some((mut containers, start, anchored)) = self.lookup_path_start(current, path) else {
            return LookupOutcome::invalid(ProjectDiagnosticKind::InvalidPath);
        };
        if containers.escaped_root {
            return LookupOutcome::invalid(ProjectDiagnosticKind::PathEscapesRoot);
        }
        if start == path.segments.len() {
            let mut outcome = LookupOutcome::default();
            for container in containers.accessible {
                if let LookupContainer::Module(module) = container
                    && let Some(id) = module_entity(&module)
                {
                    outcome.accessible.insert(id);
                }
            }
            return outcome;
        }

        for (offset, segment) in path.segments[start..].iter().enumerate() {
            let PathSegment::Identifier(identifier) = segment else {
                return LookupOutcome::invalid(ProjectDiagnosticKind::InvalidPath);
            };
            let terminal = start + offset + 1 == path.segments.len();
            let include_language = !anchored && start == 0 && offset == 0;
            containers = self.lookup_container_members(
                &containers,
                requester,
                &identifier.text,
                include_language,
                terminal,
            );
            if containers.accessible.is_empty() && containers.inaccessible.is_empty() {
                return LookupOutcome::default();
            }
            if terminal {
                let mut outcome = LookupOutcome::default();
                for candidate in containers.accessible {
                    if let LookupContainer::Entity(id) = candidate {
                        outcome.accessible.insert(id);
                    }
                }
                for candidate in containers.inaccessible {
                    if let LookupContainer::Entity(id) = candidate {
                        outcome.inaccessible.insert(id);
                    }
                }
                return outcome;
            }
        }
        LookupOutcome::default()
    }

    fn lookup_path_start(
        &self,
        current: &ModuleRef,
        path: &Path,
    ) -> Option<(ContainerOutcome, usize, bool)> {
        let first = path.segments.first()?;
        match first {
            PathSegment::Super(_) => {
                let mut base = current.clone();
                let mut index = 0;
                while matches!(path.segments.get(index), Some(PathSegment::Super(_))) {
                    let Some(parent) = base.parent() else {
                        return Some((ContainerOutcome::escaped(), index, true));
                    };
                    base = parent;
                    index += 1;
                }
                Some((ContainerOutcome::module(base), index, true))
            }
            PathSegment::Identifier(identifier)
                if path.segments.len() > 1 && identifier.text == "root" =>
            {
                Some((ContainerOutcome::module(ModuleRef::root()), 1, true))
            }
            PathSegment::Identifier(identifier)
                if path.segments.len() > 1 && identifier.text == "self" =>
            {
                Some((ContainerOutcome::module(current.clone()), 1, true))
            }
            PathSegment::Identifier(_) => {
                Some((ContainerOutcome::module(current.clone()), 0, false))
            }
        }
    }

    fn lookup_container_members(
        &self,
        containers: &ContainerOutcome,
        requester: &ModuleRef,
        name: &str,
        include_language: bool,
        terminal: bool,
    ) -> ContainerOutcome {
        let mut result = ContainerOutcome::default();
        for container in &containers.accessible {
            match container {
                LookupContainer::Module(module) => {
                    self.lookup_module_name(
                        module,
                        requester,
                        name,
                        include_language,
                        terminal,
                        &mut result,
                    );
                }
                LookupContainer::Entity(entity) => {
                    self.lookup_entity_member(entity, requester, name, terminal, &mut result);
                }
            }
        }
        result
    }

    fn lookup_module_name(
        &self,
        module: &ModuleRef,
        requester: &ModuleRef,
        name: &str,
        include_language: bool,
        terminal: bool,
        result: &mut ContainerOutcome,
    ) {
        if let Some(table) = self.bindings.get(module) {
            for ((namespace, spelling), deliveries) in table {
                if spelling != name || *namespace == Namespace::Member {
                    continue;
                }
                for delivery in deliveries.values() {
                    let accessible =
                        delivery.public || requester.is_descendant_of(&delivery.owner_module);
                    let target = if delivery.target.kind == EntityKind::Module && !terminal {
                        LookupContainer::Module(delivery.target.module.clone())
                    } else {
                        LookupContainer::Entity(delivery.target.clone())
                    };
                    if accessible {
                        result.accessible.insert(target);
                    } else {
                        result.inaccessible.insert(target);
                    }
                }
            }
        }
        if include_language {
            for entity in self.entities.values() {
                if entity.id.origin == DeclarationOrigin::Language
                    && entity.id.kind != EntityKind::LanguageConstructor
                    && entity.id.name == name
                {
                    result
                        .accessible
                        .insert(LookupContainer::Entity(entity.id.clone()));
                }
            }
        }
        if !terminal {
            result.retain_containers(&self.entities);
        }
    }

    fn lookup_entity_member(
        &self,
        entity: &EntityId,
        requester: &ModuleRef,
        name: &str,
        terminal: bool,
        result: &mut ContainerOutcome,
    ) {
        let Some(metadata) = self.entities.get(entity) else {
            return;
        };
        for target in metadata.members.get(name).into_iter().flatten() {
            let Some(target_metadata) = self.entities.get(target) else {
                continue;
            };
            let accessible = target_metadata.public || requester.is_descendant_of(&target.module);
            let container = LookupContainer::Entity(target.clone());
            if accessible {
                result.accessible.insert(container);
            } else {
                result.inaccessible.insert(container);
            }
        }
        if !terminal {
            result.retain_containers(&self.entities);
        }
    }

    fn check_import_directives(&self) -> Result<(), ProjectDiagnostic> {
        for directive in &self.imports {
            if let Some(kind) = &directive.invalid {
                return Err(ProjectDiagnostic {
                    kind: kind.clone(),
                    primary: Some(directive.origin.clone()),
                    related: Vec::new(),
                });
            }
            let path = path_text(&directive.path);
            if directive.candidates.is_empty() {
                let kind = if !directive.inaccessible.is_empty() {
                    ProjectDiagnosticKind::InaccessibleImport { path }
                } else if self.import_reaches_cycle(directive) {
                    ProjectDiagnosticKind::ImportCycle { path }
                } else {
                    ProjectDiagnosticKind::UnresolvedImport { path }
                };
                return Err(ProjectDiagnostic {
                    kind,
                    primary: Some(directive.origin.clone()),
                    related: Vec::new(),
                });
            }
            if directive.candidates.len() > 1 {
                return Err(ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::AmbiguousImport { path },
                    primary: Some(directive.origin.clone()),
                    related: declaration_origins(&directive.candidates, &self.entities),
                });
            }
            let target = directive
                .candidates
                .first()
                .expect("nonempty import candidate set");
            if directive.public
                && !self
                    .entities
                    .get(target)
                    .is_some_and(|entity| entity.public)
            {
                return Err(ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::PrivateReExport {
                        name: directive.local_name.clone(),
                    },
                    primary: Some(directive.origin.clone()),
                    related: self
                        .entities
                        .get(target)
                        .and_then(|entity| entity.declared_at.clone())
                        .into_iter()
                        .collect(),
                });
            }
        }
        Ok(())
    }

    fn import_reaches_cycle(&self, directive: &ImportDirective) -> bool {
        let mut visiting = BTreeSet::new();
        let mut visited = BTreeSet::new();
        self.import_dependency_cycle(directive, &mut visiting, &mut visited)
    }

    fn import_dependency_cycle(
        &self,
        directive: &ImportDirective,
        visiting: &mut BTreeSet<(ModuleRef, Span)>,
        visited: &mut BTreeSet<(ModuleRef, Span)>,
    ) -> bool {
        let key = (directive.module.clone(), directive.origin.span);
        if visiting.contains(&key) {
            return true;
        }
        if !visited.insert(key.clone()) {
            return false;
        }
        visiting.insert(key.clone());
        for dependency in self.import_dependencies(directive) {
            if self.import_dependency_cycle(dependency, visiting, visited) {
                return true;
            }
        }
        visiting.remove(&key);
        false
    }

    fn import_dependencies<'a>(&'a self, directive: &ImportDirective) -> Vec<&'a ImportDirective> {
        let Some(last_name) = path_terminal_name(&directive.path) else {
            return Vec::new();
        };
        let mut prefix = directive.path.clone();
        prefix.segments.pop();
        if prefix.segments.is_empty() {
            return self
                .imports
                .iter()
                .filter(|candidate| {
                    candidate.module == directive.module && candidate.local_name == last_name
                })
                .collect();
        }
        prefix.span.end = prefix
            .segments
            .last()
            .map(path_segment_span)
            .map_or(prefix.span.start, |span| span.end);
        let outcome = self.lookup_global_path(&directive.module, &directive.module, &prefix);
        outcome
            .accessible
            .iter()
            .filter(|entity| entity.kind == EntityKind::Module)
            .flat_map(|entity| {
                self.imports.iter().filter(|candidate| {
                    candidate.module == entity.module && candidate.local_name == last_name
                })
            })
            .collect()
    }

    fn check_import_bindings(&self) -> Result<(), ProjectDiagnostic> {
        for table in self.bindings.values() {
            for ((namespace, name), deliveries) in table {
                let Some(public_namespace) = namespace.public() else {
                    continue;
                };
                if is_language_name(*namespace, name)
                    && !deliveries.keys().all(|target| {
                        target.origin == DeclarationOrigin::Language
                            && target.name.as_str() == name.as_str()
                    })
                {
                    return Err(ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::ReservedLanguageBinding {
                            namespace: public_namespace,
                            name: name.clone(),
                        },
                        primary: sorted_delivery_origins(deliveries).into_iter().next(),
                        related: Vec::new(),
                    });
                }
                if deliveries.len() > 1 {
                    let mut origins = sorted_delivery_origins(deliveries).into_iter();
                    let primary = origins.next();
                    return Err(ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::NameConflict {
                            namespace: public_namespace,
                            name: name.clone(),
                        },
                        primary,
                        related: origins.collect(),
                    });
                }
                if *namespace == Namespace::Type && name == "Self" {
                    return Err(ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::InvalidSelf,
                        primary: sorted_delivery_origins(deliveries).into_iter().next(),
                        related: Vec::new(),
                    });
                }
            }
        }
        Ok(())
    }

    fn check_constructor_owner_closure(&self) -> Result<(), ProjectDiagnostic> {
        for (module, table) in &self.bindings {
            let public_types = table
                .iter()
                .filter(|((namespace, _), _)| *namespace == Namespace::Type)
                .flat_map(|(_, deliveries)| deliveries.values())
                .filter(|delivery| delivery.public)
                .map(|delivery| delivery.target.clone())
                .collect::<BTreeSet<_>>();
            for directive in self
                .imports
                .iter()
                .filter(|directive| directive.module == *module && directive.public)
            {
                let Some(target) = directive.candidates.first() else {
                    continue;
                };
                if directive.candidates.len() != 1
                    || !matches!(
                        target.kind,
                        EntityKind::EnumConstructor | EntityKind::LanguageConstructor
                    )
                {
                    continue;
                }
                let owner = self
                    .entities
                    .get(target)
                    .and_then(|entity| entity.owner.as_ref());
                if owner.is_some_and(|owner| !public_types.contains(owner)) {
                    return Err(ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::MissingConstructorOwner {
                            constructor: target.name.clone(),
                        },
                        primary: Some(directive.origin.clone()),
                        related: owner
                            .and_then(|owner| self.entities.get(owner))
                            .and_then(|entity| entity.declared_at.clone())
                            .into_iter()
                            .collect(),
                    });
                }
            }
        }
        Ok(())
    }

    fn resolve_bodies(mut self) -> Result<ResolvedProject, ProjectDiagnostic> {
        let module_inputs = self
            .modules
            .iter()
            .map(|(module, info)| (module.clone(), info.body.clone()))
            .collect::<Vec<_>>();
        let mut modules = BTreeMap::new();
        for (module, body) in module_inputs {
            let resolved_body = if let Some(body) = body {
                let imports = self
                    .imports
                    .iter()
                    .filter(|directive| directive.module == module)
                    .map(|directive| ResolvedImport {
                        origin: directive.origin.clone(),
                        public: directive.public,
                        local_name: directive.local_name.clone(),
                        target: directive
                            .candidates
                            .first()
                            .expect("imports are validated before bodies")
                            .clone(),
                    })
                    .collect();
                let mut resolver =
                    BodyResolver::new(&mut self, module.clone(), body.origin.clone());
                Some(resolver.resolve_module_body(body, imports)?)
            } else {
                None
            };
            modules.insert(
                module.clone(),
                ResolvedModule {
                    reference: module,
                    body: resolved_body,
                },
            );
        }
        Ok(ResolvedProject {
            modules,
            entities: self.entities,
        })
    }
}

struct BodyResolver<'state> {
    state: &'state mut ResolverState,
    module: ModuleRef,
    source: SourceRef,
    type_scopes: Vec<BTreeMap<String, EntityId>>,
    value_scopes: Vec<BTreeMap<String, EntityId>>,
    self_entity: Option<EntityId>,
    owner: OwnerKey,
}

impl<'state> BodyResolver<'state> {
    fn new(state: &'state mut ResolverState, module: ModuleRef, source: SourceRef) -> Self {
        let owner = OwnerKey {
            module: module.clone(),
            source: source.clone(),
            span: Span::new(0, 0),
            kind: EntityKind::Module,
            name: module
                .0
                .last()
                .cloned()
                .unwrap_or_else(|| "<root>".to_owned()),
        };
        Self {
            state,
            module,
            source,
            type_scopes: Vec::new(),
            value_scopes: Vec::new(),
            self_entity: None,
            owner,
        }
    }

    fn resolve_module_body(
        &mut self,
        body: ModuleBodyAst,
        imports: Vec<ResolvedImport>,
    ) -> Result<ResolvedModuleBody, ProjectDiagnostic> {
        let requires = body
            .requires
            .as_ref()
            .map(|effects| self.resolve_effect_set(effects))
            .transpose()?;
        let declarations = body
            .declarations
            .iter()
            .map(|declaration| self.resolve_declaration(declaration))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(ResolvedModuleBody {
            origin: body.origin,
            span: body.span,
            requires,
            imports,
            declarations,
        })
    }

    fn resolve_declaration(
        &mut self,
        declaration: &Declaration,
    ) -> Result<ResolvedDeclaration, ProjectDiagnostic> {
        let entity =
            declaration_entity(&self.module, &self.source, declaration).map(|value| value.0);
        let public = match &declaration.kind {
            DeclarationKind::Function(declared) => declared.visibility.is_some(),
            DeclarationKind::Struct(declared) => declared.visibility.is_some(),
            DeclarationKind::Enum(declared) => declared.visibility.is_some(),
            DeclarationKind::Trait(declared) => declared.visibility.is_some(),
            DeclarationKind::Effect(declared) => declared.visibility.is_some(),
            DeclarationKind::EffectAlias(declared) => declared.visibility.is_some(),
            DeclarationKind::Extern(declared) => declared.visibility.is_some(),
            DeclarationKind::TypeAlias(declared) => declared.visibility.is_some(),
            DeclarationKind::Const(declared) => declared.visibility.is_some(),
            DeclarationKind::Module(declared) => declared.visibility.is_some(),
            DeclarationKind::InherentImpl(_) | DeclarationKind::TraitImpl(_) => false,
        };
        let kind = match &declaration.kind {
            DeclarationKind::Function(declared) => {
                let id = entity.as_ref().expect("function declaration is indexed");
                ResolvedDeclarationKind::Function(self.resolve_function(&declared.item, id)?)
            }
            DeclarationKind::Struct(declared) => {
                let id = entity.as_ref().expect("struct declaration is indexed");
                let previous_self = self.self_entity.replace(self.self_id_for_entity(id));
                let type_parameters = self.push_type_parameters(
                    &declared.item.type_parameters,
                    owner_key_from_entity(id),
                )?;
                let owner = owner_key_from_entity(id);
                let mut fields = Vec::new();
                for field in &declared.item.fields {
                    let identity = source_id(
                        &self.module,
                        &self.source,
                        field.name.span,
                        Namespace::Member,
                        EntityKind::Field,
                        &field.name.text,
                        Some(owner.clone()),
                    );
                    fields.push(ResolvedField {
                        identity,
                        public: field.visibility.is_some(),
                        ty: self.resolve_type(&field.ty)?,
                    });
                }
                self.type_scopes.pop();
                self.self_entity = previous_self;
                ResolvedDeclarationKind::Struct {
                    type_parameters,
                    fields,
                }
            }
            DeclarationKind::Enum(declared) => {
                let id = entity.as_ref().expect("enum declaration is indexed");
                let previous_self = self.self_entity.replace(self.self_id_for_entity(id));
                let type_parameters = self.push_type_parameters(
                    &declared.item.type_parameters,
                    owner_key_from_entity(id),
                )?;
                let owner = owner_key_from_entity(id);
                let mut variants = Vec::new();
                for variant in &declared.item.variants {
                    let identity = source_id(
                        &self.module,
                        &self.source,
                        variant.name.span,
                        Namespace::Value,
                        EntityKind::EnumConstructor,
                        &variant.name.text,
                        Some(owner.clone()),
                    );
                    let variant_owner = owner_key_from_entity(&identity);
                    let fields = match &variant.fields {
                        VariantFields::Unit => ResolvedVariantFields::Unit,
                        VariantFields::Positional(fields) => ResolvedVariantFields::Positional(
                            fields
                                .iter()
                                .map(|field| self.resolve_type(field))
                                .collect::<Result<Vec<_>, _>>()?,
                        ),
                        VariantFields::Named(fields) => {
                            let mut resolved = Vec::new();
                            for field in fields {
                                resolved.push(ResolvedNamedField {
                                    identity: source_id(
                                        &self.module,
                                        &self.source,
                                        field.name.span,
                                        Namespace::Member,
                                        EntityKind::Field,
                                        &field.name.text,
                                        Some(variant_owner.clone()),
                                    ),
                                    ty: self.resolve_type(&field.ty)?,
                                });
                            }
                            ResolvedVariantFields::Named(resolved)
                        }
                    };
                    variants.push(ResolvedVariant { identity, fields });
                }
                self.type_scopes.pop();
                self.self_entity = previous_self;
                ResolvedDeclarationKind::Enum {
                    type_parameters,
                    variants,
                }
            }
            DeclarationKind::InherentImpl(implementation) => {
                ResolvedDeclarationKind::InherentImpl(self.resolve_impl(
                    declaration.span,
                    EntityKind::InherentImpl,
                    &implementation.type_parameters,
                    &implementation.target,
                    &implementation.members,
                )?)
            }
            DeclarationKind::TraitImpl(implementation) => {
                let owner = self.impl_owner(declaration.span, EntityKind::TraitImpl);
                let previous_owner = std::mem::replace(&mut self.owner, owner.clone());
                self.type_scopes
                    .push(self.impl_associated_type_scope(&implementation.members, &owner));
                let type_parameters =
                    self.push_type_parameters(&implementation.type_parameters, owner.clone())?;
                let trait_type = self.resolve_named_type(&implementation.trait_type)?;
                let target = self.resolve_named_type(&implementation.target)?;
                let previous_self = self
                    .self_entity
                    .replace(self.self_id_for_impl(declaration.span, EntityKind::TraitImpl));
                let members = self.resolve_impl_members(&implementation.members, &owner)?;
                self.self_entity = previous_self;
                self.type_scopes.pop();
                self.type_scopes.pop();
                self.owner = previous_owner;
                ResolvedDeclarationKind::TraitImpl {
                    implementation: Box::new(ResolvedImpl {
                        type_parameters,
                        target,
                        members,
                    }),
                    trait_type,
                }
            }
            DeclarationKind::Trait(declared) => {
                let id = entity.as_ref().expect("trait declaration is indexed");
                let previous_self = self.self_entity.replace(self.self_id_for_entity(id));
                let owner = owner_key_from_entity(id);
                self.type_scopes
                    .push(self.associated_type_scope(&declared.item.members, &owner));
                let type_parameters =
                    self.push_type_parameters(&declared.item.type_parameters, owner.clone())?;
                let supertraits = declared
                    .item
                    .supertraits
                    .iter()
                    .map(|bound| self.resolve_named_type(bound))
                    .collect::<Result<Vec<_>, _>>()?;
                let mut members = Vec::new();
                for member in &declared.item.members {
                    members.push(self.resolve_trait_member(member, id, &owner)?);
                }
                self.type_scopes.pop();
                self.type_scopes.pop();
                self.self_entity = previous_self;
                ResolvedDeclarationKind::Trait {
                    type_parameters,
                    supertraits,
                    members,
                }
            }
            DeclarationKind::Effect(declared) => {
                let id = entity.as_ref().expect("effect declaration is indexed");
                let type_parameters = self.push_type_parameters(
                    &declared.item.type_parameters,
                    owner_key_from_entity(id),
                )?;
                let owner = owner_key_from_entity(id);
                let mut operations = Vec::new();
                for operation in &declared.item.operations {
                    let identity = source_id(
                        &self.module,
                        &self.source,
                        operation.name.span,
                        Namespace::Value,
                        EntityKind::EffectOperation,
                        &operation.name.text,
                        Some(owner.clone()),
                    );
                    let (parameters, _) = self.resolve_parameters(
                        &operation.parameters,
                        owner_key_from_entity(&identity),
                    )?;
                    operations.push(ResolvedEffectOperation {
                        identity,
                        parameters,
                        return_type: self.resolve_type(&operation.return_type)?,
                    });
                }
                self.type_scopes.pop();
                ResolvedDeclarationKind::Effect {
                    type_parameters,
                    operations,
                }
            }
            DeclarationKind::EffectAlias(declared) => {
                let id = entity
                    .as_ref()
                    .expect("effect alias declaration is indexed");
                let type_parameters = self.push_type_parameters(
                    &declared.item.type_parameters,
                    owner_key_from_entity(id),
                )?;
                let effects = self.resolve_effect_set(&declared.item.effects)?;
                self.type_scopes.pop();
                ResolvedDeclarationKind::EffectAlias {
                    type_parameters,
                    effects,
                }
            }
            DeclarationKind::Extern(declared) => match &declared.item {
                ExternDeclaration::Function(function) => {
                    let id = entity
                        .as_ref()
                        .expect("extern function declaration is indexed");
                    ResolvedDeclarationKind::ExternFunction(
                        self.resolve_function_signature(function, id)?,
                    )
                }
                ExternDeclaration::Type {
                    type_parameters, ..
                } => {
                    let id = entity.as_ref().expect("extern type declaration is indexed");
                    let type_parameters =
                        self.push_type_parameters(type_parameters, owner_key_from_entity(id))?;
                    self.type_scopes.pop();
                    ResolvedDeclarationKind::ExternType { type_parameters }
                }
            },
            DeclarationKind::TypeAlias(declared) => {
                let id = entity.as_ref().expect("type alias declaration is indexed");
                let type_parameters = self.push_type_parameters(
                    &declared.item.type_parameters,
                    owner_key_from_entity(id),
                )?;
                let value = self.resolve_type(&declared.item.value)?;
                self.type_scopes.pop();
                ResolvedDeclarationKind::TypeAlias {
                    type_parameters,
                    value,
                }
            }
            DeclarationKind::Const(declared) => ResolvedDeclarationKind::Const {
                annotation: declared
                    .item
                    .annotation
                    .as_ref()
                    .map(|annotation| self.resolve_type(annotation))
                    .transpose()?,
                value: self.resolve_expr(&declared.item.value)?,
            },
            DeclarationKind::Module(declared) => {
                ResolvedDeclarationKind::Module(self.module.child(&declared.item.name.text))
            }
        };
        Ok(ResolvedDeclaration {
            origin: OriginRef {
                source: self.source.clone(),
                span: declaration.span,
            },
            identity: entity,
            public,
            kind,
        })
    }

    fn resolve_impl(
        &mut self,
        span: Span,
        kind: EntityKind,
        parameters: &[TypeParameter],
        target: &NamedType,
        members: &[ImplMember],
    ) -> Result<ResolvedImpl, ProjectDiagnostic> {
        let owner = self.impl_owner(span, kind);
        let previous_owner = std::mem::replace(&mut self.owner, owner.clone());
        self.type_scopes
            .push(self.impl_associated_type_scope(members, &owner));
        let type_parameters = self.push_type_parameters(parameters, owner.clone())?;
        let target = self.resolve_named_type(target)?;
        let previous_self = self.self_entity.replace(self.self_id_for_impl(span, kind));
        let members = self.resolve_impl_members(members, &owner)?;
        self.self_entity = previous_self;
        self.type_scopes.pop();
        self.type_scopes.pop();
        self.owner = previous_owner;
        Ok(ResolvedImpl {
            type_parameters,
            target,
            members,
        })
    }

    fn resolve_impl_members(
        &mut self,
        members: &[ImplMember],
        owner: &OwnerKey,
    ) -> Result<Vec<ResolvedImplMember>, ProjectDiagnostic> {
        let mut resolved = Vec::new();
        for member in members {
            let (identity, kind) = match &member.kind {
                ImplMemberKind::Function(function) => {
                    let identity = source_id(
                        &self.module,
                        &self.source,
                        function.name.span,
                        Namespace::Value,
                        EntityKind::Method,
                        &function.name.text,
                        Some(owner.clone()),
                    );
                    let function = self.resolve_function(function, &identity)?;
                    (identity, ResolvedImplMemberKind::Function(function))
                }
                ImplMemberKind::AssociatedType(associated) => {
                    let identity = source_id(
                        &self.module,
                        &self.source,
                        associated.name.span,
                        Namespace::Type,
                        EntityKind::AssociatedType,
                        &associated.name.text,
                        Some(owner.clone()),
                    );
                    let value = self.resolve_type(&associated.value)?;
                    (identity, ResolvedImplMemberKind::AssociatedType(value))
                }
            };
            resolved.push(ResolvedImplMember {
                identity,
                public: member.visibility.is_some(),
                kind,
            });
        }
        Ok(resolved)
    }

    fn impl_associated_type_scope(
        &self,
        members: &[ImplMember],
        owner: &OwnerKey,
    ) -> BTreeMap<String, EntityId> {
        members
            .iter()
            .filter_map(|member| match &member.kind {
                ImplMemberKind::AssociatedType(associated) => Some((
                    associated.name.text.clone(),
                    source_id(
                        &self.module,
                        &self.source,
                        associated.name.span,
                        Namespace::Type,
                        EntityKind::AssociatedType,
                        &associated.name.text,
                        Some(owner.clone()),
                    ),
                )),
                ImplMemberKind::Function(_) => None,
            })
            .collect()
    }

    fn resolve_trait_member(
        &mut self,
        member: &TraitMember,
        trait_id: &EntityId,
        owner: &OwnerKey,
    ) -> Result<ResolvedTraitMember, ProjectDiagnostic> {
        match &member.kind {
            TraitMemberKind::Method(method) => {
                let identity = source_id(
                    &self.module,
                    &self.source,
                    method.name.span,
                    Namespace::Value,
                    EntityKind::Method,
                    &method.name.text,
                    Some(owner.clone()),
                );
                Ok(ResolvedTraitMember {
                    identity: identity.clone(),
                    kind: ResolvedTraitMemberKind::Method(Box::new(
                        self.resolve_function_signature(method, &identity)?,
                    )),
                })
            }
            TraitMemberKind::AssociatedType(associated) => {
                let identity = source_id(
                    &self.module,
                    &self.source,
                    associated.name.span,
                    Namespace::Type,
                    EntityKind::AssociatedType,
                    &associated.name.text,
                    Some(owner.clone()),
                );
                let bounds = associated
                    .bounds
                    .iter()
                    .map(|bound| self.resolve_named_type(bound))
                    .collect::<Result<Vec<_>, _>>()?;
                let default = associated
                    .default
                    .as_ref()
                    .map(|default| self.resolve_type(default))
                    .transpose()?;
                debug_assert_eq!(
                    self.state
                        .entities
                        .get(&identity)
                        .and_then(|entity| entity.owner.as_ref()),
                    Some(trait_id)
                );
                Ok(ResolvedTraitMember {
                    identity,
                    kind: ResolvedTraitMemberKind::AssociatedType { bounds, default },
                })
            }
        }
    }

    fn associated_type_scope(
        &self,
        members: &[TraitMember],
        owner: &OwnerKey,
    ) -> BTreeMap<String, EntityId> {
        members
            .iter()
            .filter_map(|member| match &member.kind {
                TraitMemberKind::AssociatedType(associated) => Some((
                    associated.name.text.clone(),
                    source_id(
                        &self.module,
                        &self.source,
                        associated.name.span,
                        Namespace::Type,
                        EntityKind::AssociatedType,
                        &associated.name.text,
                        Some(owner.clone()),
                    ),
                )),
                TraitMemberKind::Method(_) => None,
            })
            .collect()
    }

    fn resolve_function(
        &mut self,
        function: &FunctionDeclaration,
        identity: &EntityId,
    ) -> Result<ResolvedFunction, ProjectDiagnostic> {
        let owner = owner_key_from_entity(identity);
        let previous_owner = std::mem::replace(&mut self.owner, owner.clone());
        let type_parameters =
            self.push_type_parameters(&function.type_parameters, owner.clone())?;
        let (parameters, value_scope) = self.resolve_parameters(&function.parameters, owner)?;
        let return_type = function
            .return_type
            .as_ref()
            .map(|return_type| self.resolve_type(return_type))
            .transpose()?;
        let effects = function
            .effects
            .as_ref()
            .map(|effects| self.resolve_effect_set(effects))
            .transpose()?;
        self.value_scopes.push(value_scope);
        let body = self.resolve_block(&function.body)?;
        self.value_scopes.pop();
        self.type_scopes.pop();
        self.owner = previous_owner;
        Ok(ResolvedFunction {
            type_parameters,
            parameters,
            return_type,
            effects,
            body,
        })
    }

    fn resolve_function_signature(
        &mut self,
        function: &FunctionSignature,
        identity: &EntityId,
    ) -> Result<ResolvedFunctionSignature, ProjectDiagnostic> {
        let owner = owner_key_from_entity(identity);
        let previous_owner = std::mem::replace(&mut self.owner, owner.clone());
        let type_parameters =
            self.push_type_parameters(&function.type_parameters, owner.clone())?;
        let (parameters, _) = self.resolve_parameters(&function.parameters, owner)?;
        let return_type = function
            .return_type
            .as_ref()
            .map(|return_type| self.resolve_type(return_type))
            .transpose()?;
        let effects = function
            .effects
            .as_ref()
            .map(|effects| self.resolve_effect_set(effects))
            .transpose()?;
        self.type_scopes.pop();
        self.owner = previous_owner;
        Ok(ResolvedFunctionSignature {
            identity: identity.clone(),
            type_parameters,
            parameters,
            return_type,
            effects,
        })
    }

    fn push_type_parameters(
        &mut self,
        parameters: &[TypeParameter],
        owner: OwnerKey,
    ) -> Result<Vec<ResolvedTypeParameter>, ProjectDiagnostic> {
        let mut scope = BTreeMap::new();
        for parameter in parameters {
            let origin = self.origin(parameter.name.span);
            if parameter.name.text == "Self" {
                return Err(self.diagnostic(ProjectDiagnosticKind::InvalidSelf, origin));
            }
            if is_language_name(Namespace::Type, &parameter.name.text) {
                return Err(self.diagnostic(
                    ProjectDiagnosticKind::ReservedLanguageBinding {
                        namespace: NameNamespace::Type,
                        name: parameter.name.text.clone(),
                    },
                    origin,
                ));
            }
            if let Some(existing) = self
                .type_scopes
                .iter()
                .rev()
                .find_map(|scope| scope.get(&parameter.name.text))
            {
                return Err(ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::DuplicateBinding {
                        name: parameter.name.text.clone(),
                    },
                    primary: Some(origin),
                    related: entity_origin(existing).into_iter().collect(),
                });
            }
            let identity = source_id(
                &self.module,
                &self.source,
                parameter.name.span,
                Namespace::Type,
                EntityKind::TypeParameter,
                &parameter.name.text,
                Some(owner.clone()),
            );
            if let Some(existing) = scope.insert(parameter.name.text.clone(), identity.clone()) {
                return Err(ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::DuplicateBinding {
                        name: parameter.name.text.clone(),
                    },
                    primary: Some(origin),
                    related: entity_origin(&existing).into_iter().collect(),
                });
            }
            self.insert_scoped_entity(identity);
        }
        self.type_scopes.push(scope.clone());
        let mut resolved = Vec::new();
        for parameter in parameters {
            resolved.push(ResolvedTypeParameter {
                span: parameter.span,
                binding: ResolvedBinding {
                    origin: self.origin(parameter.name.span),
                    identity: scope
                        .get(&parameter.name.text)
                        .expect("type parameter was inserted")
                        .clone(),
                },
                bounds: parameter
                    .bounds
                    .iter()
                    .map(|bound| self.resolve_named_type(bound))
                    .collect::<Result<Vec<_>, _>>()?,
            });
        }
        Ok(resolved)
    }

    fn resolve_parameters(
        &mut self,
        parameters: &[NamedParameter],
        owner: OwnerKey,
    ) -> Result<(Vec<ResolvedParameter>, BTreeMap<String, EntityId>), ProjectDiagnostic> {
        let mut scope = BTreeMap::new();
        let mut resolved = Vec::new();
        for parameter in parameters {
            let origin = self.origin(parameter.name.span);
            let identity = source_id(
                &self.module,
                &self.source,
                parameter.name.span,
                Namespace::Value,
                EntityKind::Parameter,
                &parameter.name.text,
                Some(owner.clone()),
            );
            if let Some(existing) = scope.insert(parameter.name.text.clone(), identity.clone()) {
                return Err(ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::DuplicateBinding {
                        name: parameter.name.text.clone(),
                    },
                    primary: Some(origin),
                    related: entity_origin(&existing).into_iter().collect(),
                });
            }
            self.insert_scoped_entity(identity.clone());
            let (mode, annotation) = match &parameter.annotation {
                Some(annotation) => (
                    annotation.mode.as_ref().map(|mode| (mode.span, mode.kind)),
                    Some(self.resolve_type(&annotation.ty)?),
                ),
                None => (None, None),
            };
            resolved.push(ResolvedParameter {
                span: parameter.span,
                binding: ResolvedBinding { origin, identity },
                mode,
                annotation,
            });
        }
        Ok((resolved, scope))
    }

    fn insert_scoped_entity(&mut self, identity: EntityId) {
        let declared_at = entity_origin(&identity);
        self.state.entities.insert(
            identity.clone(),
            Entity {
                id: identity,
                declared_at,
                public: false,
                owner: None,
                members: BTreeMap::new(),
                shape: EntityShape::Plain,
            },
        );
    }

    fn self_id_for_entity(&self, owner: &EntityId) -> EntityId {
        source_id(
            &self.module,
            &self.source,
            owner_site_span(owner),
            Namespace::Type,
            EntityKind::SelfType,
            "Self",
            Some(owner_key_from_entity(owner)),
        )
    }

    fn self_id_for_impl(&self, span: Span, kind: EntityKind) -> EntityId {
        source_id(
            &self.module,
            &self.source,
            span,
            Namespace::Type,
            EntityKind::SelfType,
            "Self",
            Some(self.impl_owner(span, kind)),
        )
    }

    fn impl_owner(&self, span: Span, kind: EntityKind) -> OwnerKey {
        OwnerKey {
            module: self.module.clone(),
            source: self.source.clone(),
            span,
            kind,
            name: "impl".to_owned(),
        }
    }

    fn origin(&self, span: Span) -> OriginRef {
        OriginRef {
            source: self.source.clone(),
            span,
        }
    }

    fn diagnostic(&self, kind: ProjectDiagnosticKind, primary: OriginRef) -> ProjectDiagnostic {
        ProjectDiagnostic {
            kind,
            primary: Some(primary),
            related: Vec::new(),
        }
    }
}

fn entity_origin(entity: &EntityId) -> Option<OriginRef> {
    match &entity.site {
        EntitySite::Source(origin) => Some(origin.clone()),
        EntitySite::Language | EntitySite::Module(_) => None,
    }
}

#[derive(Clone, PartialEq, Eq)]
enum PathCandidate {
    Module(ModuleRef),
    Exact(EntityId),
    Selection {
        base: EntityId,
        members: Vec<ResolvedSelection>,
    },
}

#[derive(Default)]
struct BodyLookupOutcome {
    candidates: Vec<PathCandidate>,
    inaccessible: Vec<EntityId>,
    invalid: Option<ProjectDiagnosticKind>,
}

#[derive(Clone, Copy)]
enum ExpectedName {
    Type,
    Value,
    Effect,
    Construct,
    PatternConstructor,
    MethodReceiver,
}

impl ExpectedName {
    fn namespace(self) -> NameNamespace {
        match self {
            Self::Type => NameNamespace::Type,
            Self::Effect => NameNamespace::Effect,
            Self::Value | Self::Construct | Self::PatternConstructor | Self::MethodReceiver => {
                NameNamespace::Value
            }
        }
    }

    fn accepts_type_scope(self) -> bool {
        matches!(
            self,
            Self::Type | Self::Construct | Self::PatternConstructor | Self::Value
        )
    }

    fn accepts_selection(self) -> bool {
        !matches!(self, Self::Effect)
    }
}

impl BodyResolver<'_> {
    fn resolve_type(&mut self, ty: &TypeExpr) -> Result<ResolvedType, ProjectDiagnostic> {
        let kind = match &ty.kind {
            TypeKind::Named(named) => {
                ResolvedTypeKind::Named(Box::new(self.resolve_named_type_parts(ty.span, named)?))
            }
            TypeKind::Function(function) => ResolvedTypeKind::Function {
                parameters: function
                    .parameters
                    .iter()
                    .map(|parameter| {
                        Ok(ResolvedFunctionTypeParameter {
                            span: parameter.span,
                            mode: parameter.mode.as_ref().map(|mode| (mode.span, mode.kind)),
                            ty: self.resolve_type(&parameter.ty)?,
                        })
                    })
                    .collect::<Result<Vec<_>, ProjectDiagnostic>>()?,
                return_type: Box::new(self.resolve_type(&function.return_type)?),
                effects: function
                    .effects
                    .as_ref()
                    .map(|effects| self.resolve_effect_set(effects))
                    .transpose()?,
            },
            TypeKind::Tuple(elements) => ResolvedTypeKind::Tuple(
                elements
                    .iter()
                    .map(|element| self.resolve_type(element))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
        };
        Ok(ResolvedType {
            span: ty.span,
            kind,
        })
    }

    fn resolve_named_type(
        &mut self,
        ty: &NamedType,
    ) -> Result<ResolvedNamedType, ProjectDiagnostic> {
        self.resolve_named_type_parts(ty.span, &ty.kind)
    }

    fn resolve_named_type_parts(
        &mut self,
        span: Span,
        ty: &NamedTypeKind,
    ) -> Result<ResolvedNamedType, ProjectDiagnostic> {
        let reference = self.resolve_path(&ty.path, ExpectedName::Type)?;
        let mut arguments = Vec::new();
        for argument in &ty.arguments {
            arguments.push(match argument {
                TypeArgument::Type(ty) => {
                    ResolvedTypeArgument::Type(Box::new(self.resolve_type(ty)?))
                }
                TypeArgument::AssociatedType { name, value, .. } => {
                    ResolvedTypeArgument::AssociatedType {
                        member: Box::new(self.selection_for_reference(
                            &reference,
                            &name.text,
                            name.span,
                            EntityKind::AssociatedType,
                        )),
                        value: Box::new(self.resolve_type(value)?),
                    }
                }
            });
        }
        Ok(ResolvedNamedType {
            span,
            reference,
            arguments,
        })
    }

    fn resolve_effect_set(
        &mut self,
        set: &EffectSet,
    ) -> Result<ResolvedEffectSet, ProjectDiagnostic> {
        let effects = set
            .effects
            .iter()
            .map(|effect| self.resolve_effect(effect))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(ResolvedEffectSet {
            span: set.span,
            effects,
        })
    }

    fn resolve_effect(&mut self, effect: &EffectExpr) -> Result<ResolvedEffect, ProjectDiagnostic> {
        let (reference, arguments) = match &effect.kind {
            EffectKind::Named { path, arguments } => (
                self.resolve_path(path, ExpectedName::Effect)?,
                arguments
                    .iter()
                    .map(|argument| self.resolve_type(argument))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            EffectKind::Mutation { arguments } => (
                ResolvedReference::Exact {
                    occurrence: self.origin(effect.span),
                    target: language_id(Namespace::Effect, EntityKind::LanguageEffect, "mut", None),
                },
                arguments
                    .iter()
                    .map(|argument| self.resolve_type(argument))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            EffectKind::Unsafe => (
                ResolvedReference::Exact {
                    occurrence: self.origin(effect.span),
                    target: language_id(
                        Namespace::Effect,
                        EntityKind::LanguageEffect,
                        "unsafe",
                        None,
                    ),
                },
                Vec::new(),
            ),
        };
        Ok(ResolvedEffect {
            span: effect.span,
            reference,
            arguments,
        })
    }

    fn resolve_path(
        &self,
        path: &Path,
        expected: ExpectedName,
    ) -> Result<ResolvedReference, ProjectDiagnostic> {
        let outcome = self.lookup_body_path(path, expected);
        if let Some(kind) = outcome.invalid {
            return Err(self.diagnostic(kind, self.origin(path.span)));
        }
        let mut accepted = outcome
            .candidates
            .into_iter()
            .map(|candidate| self.normalize_type_dependent_candidate(candidate, path))
            .filter(|candidate| self.candidate_matches(candidate, expected))
            .collect::<Vec<_>>();
        deduplicate_candidates(&mut accepted);
        if accepted.is_empty() {
            let name = path_terminal_name(path).unwrap_or_else(|| path_text(path));
            let kind = if !outcome.inaccessible.is_empty() {
                ProjectDiagnosticKind::InaccessibleName { name }
            } else {
                ProjectDiagnosticKind::UnresolvedName {
                    namespace: expected.namespace(),
                    name,
                }
            };
            return Err(self.diagnostic(kind, self.origin(path.span)));
        }
        if accepted.len() > 1 {
            let related = accepted
                .iter()
                .filter_map(|candidate| match candidate {
                    PathCandidate::Exact(entity) => entity_origin(entity),
                    PathCandidate::Module(_) | PathCandidate::Selection { .. } => None,
                })
                .collect();
            return Err(ProjectDiagnostic {
                kind: ProjectDiagnosticKind::AmbiguousName {
                    name: path_text(path),
                },
                primary: Some(self.origin(path.span)),
                related,
            });
        }
        Ok(match accepted.pop().expect("one accepted path candidate") {
            PathCandidate::Exact(target) => ResolvedReference::Exact {
                occurrence: self.origin(path.span),
                target,
            },
            PathCandidate::Selection { base, members } => ResolvedReference::Selection {
                occurrence: self.origin(path.span),
                base,
                members,
            },
            PathCandidate::Module(_) => unreachable!("modules do not match body name contexts"),
        })
    }

    fn lookup_body_path(&self, path: &Path, expected: ExpectedName) -> BodyLookupOutcome {
        let Some(first) = path.segments.first() else {
            return BodyLookupOutcome {
                invalid: Some(ProjectDiagnosticKind::InvalidPath),
                ..BodyLookupOutcome::default()
            };
        };
        let mut outcome = BodyLookupOutcome::default();
        let mut candidates;
        let mut index;
        match first {
            PathSegment::Super(_) => {
                let mut base = self.module.clone();
                index = 0;
                while matches!(path.segments.get(index), Some(PathSegment::Super(_))) {
                    let Some(parent) = base.parent() else {
                        outcome.invalid = Some(ProjectDiagnosticKind::PathEscapesRoot);
                        return outcome;
                    };
                    base = parent;
                    index += 1;
                }
                candidates = vec![PathCandidate::Module(base)];
            }
            PathSegment::Identifier(identifier)
                if path.segments.len() > 1 && identifier.text == "root" =>
            {
                candidates = vec![PathCandidate::Module(ModuleRef::root())];
                index = 1;
            }
            PathSegment::Identifier(identifier)
                if path.segments.len() > 1 && identifier.text == "self" =>
            {
                candidates = vec![PathCandidate::Module(self.module.clone())];
                index = 1;
            }
            PathSegment::Identifier(identifier) => {
                if identifier.text == "Self"
                    && expected.accepts_type_scope()
                    && (!matches!(expected, ExpectedName::Value) || path.segments.len() > 1)
                {
                    let Some(self_entity) = &self.self_entity else {
                        outcome.invalid = Some(ProjectDiagnosticKind::InvalidSelf);
                        return outcome;
                    };
                    candidates = vec![PathCandidate::Exact(self_entity.clone())];
                } else if matches!(expected, ExpectedName::Value)
                    && self.lookup_value_binding(&identifier.text).is_some()
                {
                    candidates = vec![PathCandidate::Exact(
                        self.lookup_value_binding(&identifier.text)
                            .expect("value binding was present"),
                    )];
                } else if matches!(expected, ExpectedName::MethodReceiver)
                    && self.lookup_value_binding(&identifier.text).is_some()
                {
                    candidates = vec![PathCandidate::Exact(
                        self.lookup_value_binding(&identifier.text)
                            .expect("value binding was present"),
                    )];
                    let module_names =
                        self.lookup_module_name_for_body(&self.module, &identifier.text, true);
                    for candidate in module_names.candidates {
                        if matches!(
                            &candidate,
                            PathCandidate::Exact(entity)
                                if entity.namespace == Namespace::Effect
                        ) {
                            push_candidate(&mut candidates, candidate);
                        }
                    }
                    outcome.inaccessible.extend(module_names.inaccessible);
                } else if expected.accepts_type_scope()
                    && (!matches!(expected, ExpectedName::Value) || path.segments.len() > 1)
                    && self.lookup_type_binding(&identifier.text).is_some()
                {
                    candidates = vec![PathCandidate::Exact(
                        self.lookup_type_binding(&identifier.text)
                            .expect("type binding was present"),
                    )];
                } else {
                    let names =
                        self.lookup_module_name_for_body(&self.module, &identifier.text, true);
                    candidates = names.candidates;
                    outcome.inaccessible.extend(names.inaccessible);
                }
                index = 1;
            }
        }

        while index < path.segments.len() {
            let PathSegment::Identifier(identifier) = &path.segments[index] else {
                outcome.invalid = Some(ProjectDiagnosticKind::InvalidPath);
                return outcome;
            };
            let step = self.advance_body_candidates(candidates, identifier);
            candidates = step.candidates;
            outcome.inaccessible.extend(step.inaccessible);
            if candidates.is_empty() {
                break;
            }
            index += 1;
        }
        outcome.candidates = candidates;
        outcome
    }

    fn lookup_module_name_for_body(
        &self,
        module: &ModuleRef,
        name: &str,
        include_language: bool,
    ) -> BodyLookupOutcome {
        let mut containers = ContainerOutcome::default();
        self.state.lookup_module_name(
            module,
            &self.module,
            name,
            include_language,
            true,
            &mut containers,
        );
        let mut outcome = BodyLookupOutcome::default();
        for container in containers.accessible {
            match container {
                LookupContainer::Module(module) => {
                    push_candidate(&mut outcome.candidates, PathCandidate::Module(module));
                }
                LookupContainer::Entity(entity) if entity.kind == EntityKind::Module => {
                    push_candidate(
                        &mut outcome.candidates,
                        PathCandidate::Module(entity.module),
                    );
                }
                LookupContainer::Entity(entity) => {
                    push_candidate(&mut outcome.candidates, PathCandidate::Exact(entity));
                }
            }
        }
        outcome
            .inaccessible
            .extend(
                containers
                    .inaccessible
                    .into_iter()
                    .filter_map(|container| match container {
                        LookupContainer::Entity(entity) => Some(entity),
                        LookupContainer::Module(module) => module_entity(&module),
                    }),
            );
        outcome
    }

    fn advance_body_candidates(
        &self,
        candidates: Vec<PathCandidate>,
        identifier: &Identifier,
    ) -> BodyLookupOutcome {
        let mut outcome = BodyLookupOutcome::default();
        for candidate in candidates {
            match candidate {
                PathCandidate::Module(module) => {
                    let names = self.lookup_module_name_for_body(&module, &identifier.text, false);
                    for candidate in names.candidates {
                        push_candidate(&mut outcome.candidates, candidate);
                    }
                    outcome.inaccessible.extend(names.inaccessible);
                }
                PathCandidate::Exact(base) => {
                    if base.kind == EntityKind::Module {
                        let names =
                            self.lookup_module_name_for_body(&base.module, &identifier.text, false);
                        for candidate in names.candidates {
                            push_candidate(&mut outcome.candidates, candidate);
                        }
                        outcome.inaccessible.extend(names.inaccessible);
                        continue;
                    }
                    let declared_members = self
                        .state
                        .entities
                        .get(&base)
                        .and_then(|entity| entity.members.get(&identifier.text))
                        .cloned()
                        .unwrap_or_default();
                    let hard_members = declared_members
                        .iter()
                        .filter(|member| {
                            matches!(
                                member.kind,
                                EntityKind::EnumConstructor
                                    | EntityKind::LanguageConstructor
                                    | EntityKind::EffectOperation
                            )
                        })
                        .cloned()
                        .collect::<Vec<_>>();
                    if !hard_members.is_empty() {
                        for member in hard_members {
                            let accessible =
                                self.state.entities.get(&member).is_some_and(|entity| {
                                    entity.public || self.module.is_descendant_of(&member.module)
                                });
                            if accessible {
                                push_candidate(
                                    &mut outcome.candidates,
                                    PathCandidate::Exact(member),
                                );
                            } else {
                                outcome.inaccessible.push(member);
                            }
                        }
                    } else if is_selection_base(&base) {
                        let declaration = declared_members.into_iter().next();
                        push_candidate(
                            &mut outcome.candidates,
                            PathCandidate::Selection {
                                base,
                                members: vec![ResolvedSelection {
                                    origin: self.origin(identifier.span),
                                    name: identifier.text.clone(),
                                    declaration,
                                }],
                            },
                        );
                    }
                }
                PathCandidate::Selection { base, mut members } => {
                    members.push(ResolvedSelection {
                        origin: self.origin(identifier.span),
                        name: identifier.text.clone(),
                        declaration: None,
                    });
                    push_candidate(
                        &mut outcome.candidates,
                        PathCandidate::Selection { base, members },
                    );
                }
            }
        }
        outcome
    }

    fn candidate_matches(&self, candidate: &PathCandidate, expected: ExpectedName) -> bool {
        match candidate {
            PathCandidate::Module(_) => false,
            PathCandidate::Selection { .. } => expected.accepts_selection(),
            PathCandidate::Exact(entity) => match expected {
                ExpectedName::Type => {
                    entity.namespace == Namespace::Type && entity.kind != EntityKind::Module
                }
                ExpectedName::Value => entity.namespace == Namespace::Value,
                ExpectedName::Effect => entity.namespace == Namespace::Effect,
                ExpectedName::MethodReceiver => {
                    matches!(entity.namespace, Namespace::Value | Namespace::Effect)
                }
                ExpectedName::Construct | ExpectedName::PatternConstructor => {
                    (entity.namespace == Namespace::Type && entity.kind != EntityKind::Module)
                        || matches!(
                            entity.kind,
                            EntityKind::EnumConstructor | EntityKind::LanguageConstructor
                        )
                }
            },
        }
    }

    fn normalize_type_dependent_candidate(
        &self,
        candidate: PathCandidate,
        path: &Path,
    ) -> PathCandidate {
        let PathCandidate::Exact(declaration) = &candidate else {
            return candidate;
        };
        if !matches!(
            declaration.kind,
            EntityKind::Method | EntityKind::AssociatedType | EntityKind::Field
        ) {
            return candidate;
        }
        let base = self
            .state
            .entities
            .get(declaration)
            .and_then(|entity| entity.owner.clone())
            .or_else(|| self.self_entity.clone());
        let Some(base) = base else {
            return candidate;
        };
        let segment = path.segments.last().expect("resolved path is nonempty");
        let name = match segment {
            PathSegment::Identifier(identifier) => identifier.text.clone(),
            PathSegment::Super(_) => declaration.name.clone(),
        };
        PathCandidate::Selection {
            base,
            members: vec![ResolvedSelection {
                origin: self.origin(path_segment_span(segment)),
                name,
                declaration: Some(declaration.clone()),
            }],
        }
    }

    fn lookup_value_binding(&self, name: &str) -> Option<EntityId> {
        self.value_scopes
            .iter()
            .rev()
            .find_map(|scope| scope.get(name).cloned())
    }

    fn lookup_type_binding(&self, name: &str) -> Option<EntityId> {
        self.type_scopes
            .iter()
            .rev()
            .find_map(|scope| scope.get(name).cloned())
    }

    fn selection_for_reference(
        &self,
        reference: &ResolvedReference,
        name: &str,
        span: Span,
        expected_kind: EntityKind,
    ) -> ResolvedSelection {
        let declaration = match reference {
            ResolvedReference::Exact { target, .. } => self
                .state
                .entities
                .get(target)
                .and_then(|entity| entity.members.get(name))
                .into_iter()
                .flatten()
                .find(|member| member.kind == expected_kind)
                .cloned(),
            ResolvedReference::Selection { .. } => None,
        };
        ResolvedSelection {
            origin: self.origin(span),
            name: name.to_owned(),
            declaration,
        }
    }

    fn resolve_effect_operation(
        &self,
        effect: &ResolvedReference,
        operation: &Identifier,
    ) -> Result<ResolvedSelection, ProjectDiagnostic> {
        let selection = self.selection_for_reference(
            effect,
            &operation.text,
            operation.span,
            EntityKind::EffectOperation,
        );
        if reference_exact_target(effect).is_some_and(|target| target.kind == EntityKind::Effect)
            && selection.declaration.is_none()
        {
            return Err(self.diagnostic(
                ProjectDiagnosticKind::UnresolvedName {
                    namespace: NameNamespace::Value,
                    name: operation.text.clone(),
                },
                self.origin(operation.span),
            ));
        }
        Ok(selection)
    }

    fn resolve_block(&mut self, block: &Block) -> Result<ResolvedBlock, ProjectDiagnostic> {
        self.value_scopes.push(BTreeMap::new());
        let mut statements = Vec::new();
        for statement in &block.statements {
            statements.push(self.resolve_statement(statement)?);
        }
        let tail = block
            .tail
            .as_ref()
            .map(|tail| self.resolve_expr(tail).map(Box::new))
            .transpose()?;
        self.value_scopes.pop();
        Ok(ResolvedBlock {
            span: block.span,
            statements,
            tail,
        })
    }

    fn resolve_block_with_bindings(
        &mut self,
        block: &Block,
        bindings: BTreeMap<String, EntityId>,
    ) -> Result<ResolvedBlock, ProjectDiagnostic> {
        self.value_scopes.push(bindings);
        let resolved = self.resolve_block(block)?;
        self.value_scopes.pop();
        Ok(resolved)
    }

    fn resolve_statement(
        &mut self,
        statement: &Statement,
    ) -> Result<ResolvedStatement, ProjectDiagnostic> {
        let kind = match &statement.kind {
            StatementKind::Let { binding, value } => match binding {
                LetBinding::Name {
                    name, annotation, ..
                } => {
                    let annotation = annotation
                        .as_ref()
                        .map(|annotation| self.resolve_type(annotation))
                        .transpose()?;
                    let value = self.resolve_expr(value)?;
                    let binding = self.make_value_binding(
                        name,
                        name.span,
                        EntityKind::Local,
                        self.owner.clone(),
                    );
                    self.value_scopes
                        .last_mut()
                        .expect("let appears in a block scope")
                        .insert(name.text.clone(), binding.identity.clone());
                    ResolvedStatementKind::Let {
                        bindings: vec![binding],
                        annotation,
                        value,
                    }
                }
                LetBinding::Tuple(pattern) => {
                    let (pattern, bindings) = self.resolve_single_pattern(pattern)?;
                    let value = self.resolve_expr(value)?;
                    let resolved_bindings = bindings
                        .iter()
                        .map(|(name, identity)| ResolvedBinding {
                            origin: pattern_binding_origin(&pattern, name)
                                .unwrap_or_else(|| self.origin(pattern.span)),
                            identity: identity.clone(),
                        })
                        .collect::<Vec<_>>();
                    self.value_scopes
                        .last_mut()
                        .expect("let appears in a block scope")
                        .extend(bindings);
                    ResolvedStatementKind::Let {
                        bindings: resolved_bindings,
                        annotation: None,
                        value,
                    }
                }
            },
            StatementKind::Return(value) => ResolvedStatementKind::Return(
                value
                    .as_ref()
                    .map(|value| self.resolve_expr(value))
                    .transpose()?,
            ),
            StatementKind::Break => ResolvedStatementKind::Break,
            StatementKind::Continue => ResolvedStatementKind::Continue,
            StatementKind::Assignment {
                target,
                operator,
                value,
            } => ResolvedStatementKind::Assignment {
                target: self.resolve_place(target)?,
                operator: (operator.span, operator.kind),
                value: self.resolve_expr(value)?,
            },
            StatementKind::Expression(expression) => {
                ResolvedStatementKind::Expression(self.resolve_expr(expression)?)
            }
            StatementKind::IfLet {
                pattern,
                value,
                then_branch,
                else_branch,
            } => {
                let (pattern, bindings) = self.resolve_single_pattern(pattern)?;
                let value = self.resolve_expr(value)?;
                let then_branch = self.resolve_block_with_bindings(then_branch, bindings)?;
                let else_branch = else_branch
                    .as_ref()
                    .map(|branch| self.resolve_block(branch))
                    .transpose()?;
                ResolvedStatementKind::IfLet {
                    pattern,
                    value,
                    then_branch,
                    else_branch,
                }
            }
            StatementKind::While { condition, body } => ResolvedStatementKind::While {
                condition: self.resolve_expr(condition)?,
                body: self.resolve_block(body)?,
            },
            StatementKind::For {
                binding,
                iterable,
                body,
            } => {
                let mut bindings = BTreeMap::new();
                let names = match binding {
                    ForBinding::Name(name) => vec![name],
                    ForBinding::Tuple { names, .. } => names.iter().collect(),
                };
                let mut resolved_bindings = Vec::new();
                for name in names {
                    let resolved = self.make_value_binding(
                        name,
                        name.span,
                        EntityKind::Local,
                        self.owner.clone(),
                    );
                    if let Some(previous) =
                        bindings.insert(name.text.clone(), resolved.identity.clone())
                    {
                        return Err(ProjectDiagnostic {
                            kind: ProjectDiagnosticKind::DuplicateBinding {
                                name: name.text.clone(),
                            },
                            primary: Some(self.origin(name.span)),
                            related: entity_origin(&previous).into_iter().collect(),
                        });
                    }
                    resolved_bindings.push(resolved);
                }
                let iterable = self.resolve_expr(iterable)?;
                let body = self.resolve_block_with_bindings(body, bindings)?;
                ResolvedStatementKind::For {
                    bindings: resolved_bindings,
                    iterable,
                    body,
                }
            }
            StatementKind::Loop(body) => ResolvedStatementKind::Loop(self.resolve_block(body)?),
        };
        Ok(ResolvedStatement {
            span: statement.span,
            kind,
            terminator: statement.terminator.clone(),
        })
    }

    fn resolve_place(&self, place: &PlaceExpr) -> Result<ResolvedPlace, ProjectDiagnostic> {
        let path = single_identifier_path(&place.root);
        Ok(ResolvedPlace {
            span: place.span,
            root: self.resolve_path(&path, ExpectedName::Value)?,
            fields: place
                .fields
                .iter()
                .map(|field| ResolvedSelection {
                    origin: self.origin(field.span),
                    name: field.text.clone(),
                    declaration: None,
                })
                .collect(),
        })
    }

    fn resolve_expr(&mut self, expression: &Expr) -> Result<ResolvedExpr, ProjectDiagnostic> {
        let kind = match &expression.kind {
            ExprKind::Integer(value) => ResolvedExprKind::Integer(value.clone()),
            ExprKind::Float(value) => ResolvedExprKind::Float(value.clone()),
            ExprKind::String(value) => ResolvedExprKind::String(value.clone()),
            ExprKind::RawString { value, delimiter } => ResolvedExprKind::RawString {
                value: value.clone(),
                delimiter: *delimiter,
            },
            ExprKind::InterpolatedString(parts) => ResolvedExprKind::InterpolatedString(
                parts
                    .iter()
                    .map(|part| match part {
                        InterpolationPart::String(value) => Ok(ResolvedInterpolationPart::String {
                            origin: self.origin(value.span),
                            value: value.value.clone(),
                        }),
                        InterpolationPart::Expression(expression) => {
                            Ok(ResolvedInterpolationPart::Expression(Box::new(
                                self.resolve_expr(expression)?,
                            )))
                        }
                    })
                    .collect::<Result<Vec<_>, ProjectDiagnostic>>()?,
            ),
            ExprKind::Boolean(value) => ResolvedExprKind::Boolean(*value),
            ExprKind::Path(path) => {
                ResolvedExprKind::Path(self.resolve_path(path, ExpectedName::Value)?)
            }
            ExprKind::NamedConstruct { path, entries } => {
                let target = self.resolve_path(path, ExpectedName::Construct)?;
                let mut resolved_entries = Vec::new();
                for entry in entries {
                    resolved_entries.push(match &entry.kind {
                        ConstructEntryKind::Spread(expression) => {
                            ResolvedConstructEntry::Spread(self.resolve_expr(expression)?)
                        }
                        ConstructEntryKind::Field { name, value } => {
                            let member = self.selection_for_reference(
                                &target,
                                &name.text,
                                name.span,
                                EntityKind::Field,
                            );
                            let shorthand = if value.is_none() {
                                Some(Box::new(self.resolve_path(
                                    &single_identifier_path(name),
                                    ExpectedName::Value,
                                )?))
                            } else {
                                None
                            };
                            ResolvedConstructEntry::Field {
                                member,
                                value: value
                                    .as_ref()
                                    .map(|value| self.resolve_expr(value).map(Box::new))
                                    .transpose()?,
                                shorthand,
                            }
                        }
                    });
                }
                ResolvedExprKind::NamedConstruct {
                    target,
                    entries: resolved_entries,
                }
            }
            ExprKind::List(elements) => ResolvedExprKind::List(
                elements
                    .iter()
                    .map(|element| self.resolve_expr(element))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            ExprKind::Unit => ResolvedExprKind::Unit,
            ExprKind::Parenthesized(inner) => {
                ResolvedExprKind::Parenthesized(Box::new(self.resolve_expr(inner)?))
            }
            ExprKind::Tuple(elements) => ResolvedExprKind::Tuple(
                elements
                    .iter()
                    .map(|element| self.resolve_expr(element))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            ExprKind::Block(block) => ResolvedExprKind::Block(self.resolve_block(block)?),
            ExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => ResolvedExprKind::If {
                condition: Box::new(self.resolve_expr(condition)?),
                then_branch: self.resolve_block(then_branch)?,
                else_branch: else_branch
                    .as_ref()
                    .map(|branch| self.resolve_expr(branch).map(Box::new))
                    .transpose()?,
            },
            ExprKind::Match { scrutinee, arms } => ResolvedExprKind::Match {
                scrutinee: Box::new(self.resolve_expr(scrutinee)?),
                arms: arms
                    .iter()
                    .map(|arm| self.resolve_match_arm(arm))
                    .collect::<Result<Vec<_>, _>>()?,
            },
            ExprKind::Handle { body, handlers } => ResolvedExprKind::Handle {
                body: self.resolve_block(body)?,
                handlers: handlers
                    .iter()
                    .map(|handler| self.resolve_handler(handler))
                    .collect::<Result<Vec<_>, _>>()?,
            },
            ExprKind::Closure(closure) => {
                ResolvedExprKind::Closure(self.resolve_closure(expression.span, closure)?)
            }
            ExprKind::Unsafe(block) => ResolvedExprKind::Unsafe(self.resolve_block(block)?),
            ExprKind::Catch { expression, arms } => ResolvedExprKind::Catch {
                expression: Box::new(self.resolve_expr(expression)?),
                arms: arms
                    .iter()
                    .map(|arm| self.resolve_match_arm(arm))
                    .collect::<Result<Vec<_>, _>>()?,
            },
            ExprKind::Unary { operator, operand } => ResolvedExprKind::Unary {
                operator: (operator.span, operator.kind),
                operand: Box::new(self.resolve_expr(operand)?),
            },
            ExprKind::Binary {
                left,
                operator,
                right,
            } => ResolvedExprKind::Binary {
                left: Box::new(self.resolve_expr(left)?),
                operator: (operator.span, operator.kind),
                right: Box::new(self.resolve_expr(right)?),
            },
            ExprKind::Propagate(inner) => {
                ResolvedExprKind::Propagate(Box::new(self.resolve_expr(inner)?))
            }
            ExprKind::Call { callee, arguments } => ResolvedExprKind::Call {
                callee: Box::new(self.resolve_expr(callee)?),
                arguments: arguments
                    .iter()
                    .map(|argument| self.resolve_call_argument(argument))
                    .collect::<Result<Vec<_>, _>>()?,
            },
            ExprKind::Index { receiver, index } => ResolvedExprKind::Index {
                receiver: Box::new(self.resolve_expr(receiver)?),
                index: Box::new(self.resolve_expr(index)?),
            },
            ExprKind::TupleField { receiver, index } => ResolvedExprKind::TupleField {
                receiver: Box::new(self.resolve_expr(receiver)?),
                index: index.value.clone(),
                origin: self.origin(index.span),
            },
            ExprKind::Field { receiver, name } => ResolvedExprKind::Field {
                receiver: Box::new(self.resolve_expr(receiver)?),
                field: ResolvedSelection {
                    origin: self.origin(name.span),
                    name: name.text.clone(),
                    declaration: None,
                },
            },
            ExprKind::MethodCall {
                receiver,
                method,
                arguments,
            } => {
                let receiver = if let ExprKind::Path(path) = &receiver.kind {
                    ResolvedExpr {
                        span: receiver.span,
                        kind: ResolvedExprKind::Path(
                            self.resolve_path(path, ExpectedName::MethodReceiver)?,
                        ),
                    }
                } else {
                    self.resolve_expr(receiver)?
                };
                let method = match &receiver.kind {
                    ResolvedExprKind::Path(reference)
                        if reference_exact_target(reference)
                            .is_some_and(|target| target.namespace == Namespace::Effect) =>
                    {
                        self.resolve_effect_operation(reference, method)?
                    }
                    _ => ResolvedSelection {
                        origin: self.origin(method.span),
                        name: method.text.clone(),
                        declaration: None,
                    },
                };
                ResolvedExprKind::MethodCall {
                    receiver: Box::new(receiver),
                    method,
                    arguments: arguments
                        .iter()
                        .map(|argument| self.resolve_call_argument(argument))
                        .collect::<Result<Vec<_>, _>>()?,
                }
            }
        };
        Ok(ResolvedExpr {
            span: expression.span,
            kind,
        })
    }

    fn resolve_call_argument(
        &mut self,
        argument: &CallArgument,
    ) -> Result<ResolvedCallArgument, ProjectDiagnostic> {
        Ok(match argument {
            CallArgument::Expression(expression) => {
                ResolvedCallArgument::Expression(self.resolve_expr(expression)?)
            }
            CallArgument::Mode { span, mode, place } => ResolvedCallArgument::Mode {
                span: *span,
                mode: (mode.span, mode.kind),
                place: self.resolve_place(place)?,
            },
        })
    }

    fn resolve_match_arm(&mut self, arm: &MatchArm) -> Result<ResolvedMatchArm, ProjectDiagnostic> {
        let (pattern, bindings) = self.resolve_or_pattern(&arm.pattern)?;
        self.value_scopes.push(bindings);
        let guard = arm
            .guard
            .as_ref()
            .map(|guard| self.resolve_expr(guard))
            .transpose()?;
        let body = self.resolve_expr(&arm.body)?;
        self.value_scopes.pop();
        Ok(ResolvedMatchArm {
            span: arm.span,
            pattern,
            guard,
            body,
        })
    }

    fn resolve_handler(&mut self, handler: &Handler) -> Result<ResolvedHandler, ProjectDiagnostic> {
        let effect = self.resolve_path(&handler.effect, ExpectedName::Effect)?;
        let operation = self.resolve_effect_operation(&effect, &handler.operation)?;
        let owner = OwnerKey {
            module: self.module.clone(),
            source: self.source.clone(),
            span: handler.span,
            kind: EntityKind::Handler,
            name: handler.operation.text.clone(),
        };
        let previous_owner = std::mem::replace(&mut self.owner, owner.clone());
        let (parameters, bindings) = self.resolve_parameters(&handler.parameters, owner)?;
        self.value_scopes.push(bindings);
        let body = self.resolve_expr(&handler.body)?;
        self.value_scopes.pop();
        self.owner = previous_owner;
        Ok(ResolvedHandler {
            span: handler.span,
            effect,
            operation,
            parameters,
            body,
        })
    }

    fn resolve_closure(
        &mut self,
        span: Span,
        closure: &ClosureExpression,
    ) -> Result<ResolvedClosure, ProjectDiagnostic> {
        let mut seen_captures = BTreeMap::<String, OriginRef>::new();
        let mut captures = Vec::new();
        if let Some(list) = &closure.captures {
            for capture in &list.captures {
                let origin = self.origin(capture.name.span);
                if let Some(previous) =
                    seen_captures.insert(capture.name.text.clone(), origin.clone())
                {
                    return Err(ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::DuplicateBinding {
                            name: capture.name.text.clone(),
                        },
                        primary: Some(origin),
                        related: vec![previous],
                    });
                }
                captures.push(ResolvedCapture {
                    span: capture.span,
                    mode: capture.mode.as_ref().map(|mode| (mode.span, mode.kind)),
                    reference: self.resolve_path(
                        &single_identifier_path(&capture.name),
                        ExpectedName::Value,
                    )?,
                    annotation: capture
                        .annotation
                        .as_ref()
                        .map(|annotation| self.resolve_type(annotation))
                        .transpose()?,
                });
            }
        }
        let owner = OwnerKey {
            module: self.module.clone(),
            source: self.source.clone(),
            span,
            kind: EntityKind::Closure,
            name: "closure".to_owned(),
        };
        let previous_owner = std::mem::replace(&mut self.owner, owner.clone());
        let (parameters, bindings) = self.resolve_parameters(&closure.parameters, owner)?;
        let return_type = closure
            .return_type
            .as_ref()
            .map(|return_type| self.resolve_type(return_type))
            .transpose()?;
        let effects = closure
            .effects
            .as_ref()
            .map(|effects| self.resolve_effect_set(effects))
            .transpose()?;
        self.value_scopes.push(bindings);
        let body = self.resolve_block(&closure.body)?;
        self.value_scopes.pop();
        self.owner = previous_owner;
        Ok(ResolvedClosure {
            captures,
            parameters,
            return_type,
            effects,
            body,
        })
    }

    fn resolve_single_pattern(
        &mut self,
        pattern: &Pattern,
    ) -> Result<(ResolvedPattern, BTreeMap<String, EntityId>), ProjectDiagnostic> {
        let mut bindings = BTreeMap::new();
        let mut seen = BTreeSet::new();
        let resolved =
            self.resolve_pattern(pattern, pattern.span, None, &mut bindings, &mut seen)?;
        Ok((resolved, bindings))
    }

    fn resolve_or_pattern(
        &mut self,
        pattern: &OrPattern,
    ) -> Result<(ResolvedPattern, BTreeMap<String, EntityId>), ProjectDiagnostic> {
        let mut alternatives = Vec::new();
        let mut canonical = BTreeMap::new();
        for (index, alternative) in pattern.alternatives.iter().enumerate() {
            let mut bindings = BTreeMap::new();
            let mut seen = BTreeSet::new();
            alternatives.push(self.resolve_pattern(
                alternative,
                pattern.span,
                (index != 0).then_some(&canonical),
                &mut bindings,
                &mut seen,
            )?);
            if index == 0 {
                canonical = bindings;
            } else if bindings.keys().collect::<Vec<_>>() != canonical.keys().collect::<Vec<_>>() {
                return Err(self.diagnostic(
                    ProjectDiagnosticKind::PatternBindingMismatch,
                    self.origin(pattern.span),
                ));
            }
        }
        let kind = if alternatives.len() == 1 {
            alternatives
                .pop()
                .expect("or-pattern has one alternative")
                .kind
        } else {
            ResolvedPatternKind::Or(alternatives)
        };
        Ok((
            ResolvedPattern {
                span: pattern.span,
                kind,
            },
            canonical,
        ))
    }

    fn resolve_pattern(
        &mut self,
        pattern: &Pattern,
        anchor: Span,
        expected: Option<&BTreeMap<String, EntityId>>,
        bindings: &mut BTreeMap<String, EntityId>,
        seen: &mut BTreeSet<String>,
    ) -> Result<ResolvedPattern, ProjectDiagnostic> {
        let kind = match &pattern.kind {
            PatternKind::Wildcard => ResolvedPatternKind::Wildcard,
            PatternKind::Integer(value) => ResolvedPatternKind::Integer(value.clone()),
            PatternKind::Float(value) => ResolvedPatternKind::Float(value.clone()),
            PatternKind::String(value) => ResolvedPatternKind::String(value.clone()),
            PatternKind::Boolean(value) => ResolvedPatternKind::Boolean(*value),
            PatternKind::Tuple(elements) => ResolvedPatternKind::Tuple(
                elements
                    .iter()
                    .map(|element| self.resolve_pattern(element, anchor, expected, bindings, seen))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            PatternKind::Path { path, fields }
                if fields.is_none()
                    && path.segments.len() == 1
                    && matches!(path.segments.first(), Some(PathSegment::Identifier(_))) =>
            {
                let identifier = match path.segments.first().expect("one path segment") {
                    PathSegment::Identifier(identifier) => identifier,
                    PathSegment::Super(_) => unreachable!(),
                };
                if let Some(target) = self.unit_constructor(path)? {
                    ResolvedPatternKind::Constructor {
                        target: ResolvedReference::Exact {
                            occurrence: self.origin(path.span),
                            target,
                        },
                        fields: None,
                    }
                } else {
                    ResolvedPatternKind::Binding(
                        self.pattern_binding(identifier, anchor, expected, bindings, seen)?,
                    )
                }
            }
            PatternKind::Path { path, fields } => {
                let target = self.resolve_path(path, ExpectedName::PatternConstructor)?;
                let fields = fields
                    .as_ref()
                    .map(|fields| {
                        self.resolve_pattern_fields(
                            fields, &target, anchor, expected, bindings, seen,
                        )
                    })
                    .transpose()?;
                ResolvedPatternKind::Constructor { target, fields }
            }
        };
        Ok(ResolvedPattern {
            span: pattern.span,
            kind,
        })
    }

    fn resolve_pattern_fields(
        &mut self,
        fields: &PatternFields,
        target: &ResolvedReference,
        anchor: Span,
        expected: Option<&BTreeMap<String, EntityId>>,
        bindings: &mut BTreeMap<String, EntityId>,
        seen: &mut BTreeSet<String>,
    ) -> Result<ResolvedPatternFields, ProjectDiagnostic> {
        Ok(match fields {
            PatternFields::Positional(patterns) => ResolvedPatternFields::Positional(
                patterns
                    .iter()
                    .map(|pattern| self.resolve_pattern(pattern, anchor, expected, bindings, seen))
                    .collect::<Result<Vec<_>, _>>()?,
            ),
            PatternFields::Named { fields, rest } => {
                let mut resolved = Vec::new();
                for field in fields {
                    let pattern = if let Some(pattern) = &field.pattern {
                        self.resolve_pattern(pattern, anchor, expected, bindings, seen)?
                    } else {
                        ResolvedPattern {
                            span: field.name.span,
                            kind: ResolvedPatternKind::Binding(self.pattern_binding(
                                &field.name,
                                anchor,
                                expected,
                                bindings,
                                seen,
                            )?),
                        }
                    };
                    resolved.push(ResolvedNamedPatternField {
                        member: self.selection_for_reference(
                            target,
                            &field.name.text,
                            field.name.span,
                            EntityKind::Field,
                        ),
                        pattern,
                    });
                }
                ResolvedPatternFields::Named {
                    fields: resolved,
                    rest: *rest,
                }
            }
        })
    }

    fn pattern_binding(
        &mut self,
        identifier: &Identifier,
        anchor: Span,
        expected: Option<&BTreeMap<String, EntityId>>,
        bindings: &mut BTreeMap<String, EntityId>,
        seen: &mut BTreeSet<String>,
    ) -> Result<ResolvedBinding, ProjectDiagnostic> {
        if !seen.insert(identifier.text.clone()) {
            return Err(self.diagnostic(
                ProjectDiagnosticKind::DuplicateBinding {
                    name: identifier.text.clone(),
                },
                self.origin(identifier.span),
            ));
        }
        let identity = expected
            .and_then(|expected| expected.get(&identifier.text).cloned())
            .unwrap_or_else(|| {
                source_id(
                    &self.module,
                    &self.source,
                    anchor,
                    Namespace::Value,
                    EntityKind::PatternBinding,
                    &identifier.text,
                    Some(self.owner.clone()),
                )
            });
        bindings.insert(identifier.text.clone(), identity.clone());
        self.insert_scoped_entity(identity.clone());
        Ok(ResolvedBinding {
            origin: self.origin(identifier.span),
            identity,
        })
    }

    fn unit_constructor(&self, path: &Path) -> Result<Option<EntityId>, ProjectDiagnostic> {
        let outcome = self.lookup_body_path(path, ExpectedName::Value);
        if let Some(kind) = outcome.invalid {
            return Err(self.diagnostic(kind, self.origin(path.span)));
        }
        let mut units =
            outcome
                .candidates
                .into_iter()
                .filter_map(|candidate| match candidate {
                    PathCandidate::Exact(entity)
                        if self.state.entities.get(&entity).is_some_and(|metadata| {
                            metadata.shape == EntityShape::ConstructorUnit
                        }) =>
                    {
                        Some(entity)
                    }
                    _ => None,
                })
                .collect::<Vec<_>>();
        units.sort();
        units.dedup();
        if units.len() > 1 {
            return Err(ProjectDiagnostic {
                kind: ProjectDiagnosticKind::AmbiguousName {
                    name: path_text(path),
                },
                primary: Some(self.origin(path.span)),
                related: units.iter().filter_map(entity_origin).collect(),
            });
        }
        Ok(units.pop())
    }

    fn make_value_binding(
        &mut self,
        identifier: &Identifier,
        site: Span,
        kind: EntityKind,
        owner: OwnerKey,
    ) -> ResolvedBinding {
        let identity = source_id(
            &self.module,
            &self.source,
            site,
            Namespace::Value,
            kind,
            &identifier.text,
            Some(owner),
        );
        self.insert_scoped_entity(identity.clone());
        ResolvedBinding {
            origin: self.origin(identifier.span),
            identity,
        }
    }
}

fn single_identifier_path(identifier: &Identifier) -> Path {
    Path {
        span: identifier.span,
        segments: vec![PathSegment::Identifier(identifier.clone())],
    }
}

fn pattern_binding_origin(pattern: &ResolvedPattern, name: &str) -> Option<OriginRef> {
    match &pattern.kind {
        ResolvedPatternKind::Binding(binding) if binding.identity.name == name => {
            Some(binding.origin.clone())
        }
        ResolvedPatternKind::Tuple(patterns) | ResolvedPatternKind::Or(patterns) => patterns
            .iter()
            .find_map(|pattern| pattern_binding_origin(pattern, name)),
        ResolvedPatternKind::Constructor {
            fields: Some(fields),
            ..
        } => match fields {
            ResolvedPatternFields::Positional(patterns) => patterns
                .iter()
                .find_map(|pattern| pattern_binding_origin(pattern, name)),
            ResolvedPatternFields::Named { fields, .. } => fields
                .iter()
                .find_map(|field| pattern_binding_origin(&field.pattern, name)),
        },
        ResolvedPatternKind::Wildcard
        | ResolvedPatternKind::Integer(_)
        | ResolvedPatternKind::Float(_)
        | ResolvedPatternKind::String(_)
        | ResolvedPatternKind::Boolean(_)
        | ResolvedPatternKind::Binding(_)
        | ResolvedPatternKind::Constructor { fields: None, .. } => None,
    }
}

fn reference_exact_target(reference: &ResolvedReference) -> Option<&EntityId> {
    match reference {
        ResolvedReference::Exact { target, .. } => Some(target),
        ResolvedReference::Selection { .. } => None,
    }
}

fn is_selection_base(entity: &EntityId) -> bool {
    matches!(
        entity.kind,
        EntityKind::Struct
            | EntityKind::Enum
            | EntityKind::TypeAlias
            | EntityKind::ExternType
            | EntityKind::Trait
            | EntityKind::TypeParameter
            | EntityKind::SelfType
            | EntityKind::EffectAlias
            | EntityKind::LanguageType
            | EntityKind::LanguageTrait
            | EntityKind::LanguageEffect
    )
}

fn push_candidate(candidates: &mut Vec<PathCandidate>, candidate: PathCandidate) {
    if !candidates.contains(&candidate) {
        candidates.push(candidate);
    }
}

fn deduplicate_candidates(candidates: &mut Vec<PathCandidate>) {
    let mut unique = Vec::new();
    for candidate in candidates.drain(..) {
        push_candidate(&mut unique, candidate);
    }
    *candidates = unique;
}

#[derive(Default)]
struct LookupOutcome {
    accessible: BTreeSet<EntityId>,
    inaccessible: BTreeSet<EntityId>,
    invalid: Option<ProjectDiagnosticKind>,
}

impl LookupOutcome {
    fn invalid(kind: ProjectDiagnosticKind) -> Self {
        Self {
            invalid: Some(kind),
            ..Self::default()
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum LookupContainer {
    Module(ModuleRef),
    Entity(EntityId),
}

#[derive(Default)]
struct ContainerOutcome {
    accessible: BTreeSet<LookupContainer>,
    inaccessible: BTreeSet<LookupContainer>,
    escaped_root: bool,
}

impl ContainerOutcome {
    fn module(module: ModuleRef) -> Self {
        Self {
            accessible: BTreeSet::from([LookupContainer::Module(module)]),
            ..Self::default()
        }
    }

    fn escaped() -> Self {
        Self {
            escaped_root: true,
            ..Self::default()
        }
    }

    fn retain_containers(&mut self, entities: &BTreeMap<EntityId, Entity>) {
        self.accessible
            .retain(|container| is_lookup_container(container, entities));
        self.inaccessible
            .retain(|container| is_lookup_container(container, entities));
    }
}

fn is_lookup_container(container: &LookupContainer, entities: &BTreeMap<EntityId, Entity>) -> bool {
    match container {
        LookupContainer::Module(_) => true,
        LookupContainer::Entity(id) => {
            id.kind == EntityKind::Module
                || entities
                    .get(id)
                    .is_some_and(|entity| !entity.members.is_empty())
        }
    }
}

fn flatten_imports(
    module: &ModuleRef,
    source: &SourceRef,
    declarations: &[UseDeclaration],
) -> Vec<ImportDirective> {
    let mut directives = Vec::new();
    for declaration in declarations {
        let public = declaration.visibility.is_some();
        match &declaration.suffix {
            Some(UseSuffix::Items { items, .. }) => {
                for item in items {
                    let mut path = declaration.path.clone();
                    path.span.end = item.name.span.end;
                    path.segments
                        .push(PathSegment::Identifier(item.name.clone()));
                    directives.push(ImportDirective {
                        module: module.clone(),
                        origin: OriginRef {
                            source: source.clone(),
                            span: item.span,
                        },
                        public,
                        path,
                        local_name: item.alias.as_ref().unwrap_or(&item.name).text.clone(),
                        candidates: BTreeSet::new(),
                        inaccessible: BTreeSet::new(),
                        invalid: None,
                    });
                }
            }
            Some(UseSuffix::Alias(alias)) => directives.push(ImportDirective {
                module: module.clone(),
                origin: OriginRef {
                    source: source.clone(),
                    span: declaration.span,
                },
                public,
                path: declaration.path.clone(),
                local_name: alias.text.clone(),
                candidates: BTreeSet::new(),
                inaccessible: BTreeSet::new(),
                invalid: None,
            }),
            None => {
                if let Some(local_name) = path_terminal_name(&declaration.path) {
                    directives.push(ImportDirective {
                        module: module.clone(),
                        origin: OriginRef {
                            source: source.clone(),
                            span: declaration.span,
                        },
                        public,
                        path: declaration.path.clone(),
                        local_name,
                        candidates: BTreeSet::new(),
                        inaccessible: BTreeSet::new(),
                        invalid: None,
                    });
                } else {
                    directives.push(ImportDirective {
                        module: module.clone(),
                        origin: OriginRef {
                            source: source.clone(),
                            span: declaration.span,
                        },
                        public,
                        path: declaration.path.clone(),
                        local_name: "super".to_owned(),
                        candidates: BTreeSet::new(),
                        inaccessible: BTreeSet::new(),
                        invalid: Some(ProjectDiagnosticKind::InvalidPath),
                    });
                }
            }
        }
    }
    directives
}

fn declaration_entity(
    module: &ModuleRef,
    source: &SourceRef,
    declaration: &Declaration,
) -> Option<(EntityId, bool)> {
    let (name, namespace, kind, public) = match &declaration.kind {
        DeclarationKind::Function(declared) => (
            &declared.item.name,
            Namespace::Value,
            EntityKind::Function,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Struct(declared) => (
            &declared.item.name,
            Namespace::Type,
            EntityKind::Struct,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Enum(declared) => (
            &declared.item.name,
            Namespace::Type,
            EntityKind::Enum,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Trait(declared) => (
            &declared.item.name,
            Namespace::Type,
            EntityKind::Trait,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Effect(declared) => (
            &declared.item.name,
            Namespace::Effect,
            EntityKind::Effect,
            declared.visibility.is_some(),
        ),
        DeclarationKind::EffectAlias(declared) => (
            &declared.item.name,
            Namespace::Effect,
            EntityKind::EffectAlias,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Extern(declared) => match &declared.item {
            ExternDeclaration::Function(function) => (
                &function.name,
                Namespace::Value,
                EntityKind::ExternFunction,
                declared.visibility.is_some(),
            ),
            ExternDeclaration::Type { name, .. } => (
                name,
                Namespace::Type,
                EntityKind::ExternType,
                declared.visibility.is_some(),
            ),
        },
        DeclarationKind::TypeAlias(declared) => (
            &declared.item.name,
            Namespace::Type,
            EntityKind::TypeAlias,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Const(declared) => (
            &declared.item.name,
            Namespace::Value,
            EntityKind::Const,
            declared.visibility.is_some(),
        ),
        DeclarationKind::Module(declared) => {
            return Some((
                module_id(&module.child(&declared.item.name.text)),
                declared.visibility.is_some(),
            ));
        }
        DeclarationKind::InherentImpl(_) | DeclarationKind::TraitImpl(_) => return None,
    };
    Some((
        source_id(module, source, name.span, namespace, kind, &name.text, None),
        public,
    ))
}

fn add_delivery(table: &mut BindingTable, delivery: Delivery, namespace: Namespace, name: String) {
    table
        .entry((namespace, name))
        .or_default()
        .entry(delivery.target.clone())
        .and_modify(|existing| existing.public |= delivery.public)
        .or_insert(delivery);
}

fn module_id(module: &ModuleRef) -> EntityId {
    EntityId {
        origin: DeclarationOrigin::Source(module.clone()),
        module: module.clone(),
        namespace: Namespace::Type,
        kind: EntityKind::Module,
        name: module
            .0
            .last()
            .cloned()
            .unwrap_or_else(|| "<root>".to_owned()),
        site: EntitySite::Module(module.clone()),
        owner: None,
    }
}

fn module_entity(module: &ModuleRef) -> Option<EntityId> {
    (!module.0.is_empty()).then(|| module_id(module))
}

fn language_id(
    namespace: Namespace,
    kind: EntityKind,
    name: &str,
    owner: Option<OwnerKey>,
) -> EntityId {
    EntityId {
        origin: DeclarationOrigin::Language,
        module: ModuleRef::root(),
        namespace,
        kind,
        name: name.to_owned(),
        site: EntitySite::Language,
        owner,
    }
}

fn source_id(
    module: &ModuleRef,
    source: &SourceRef,
    span: Span,
    namespace: Namespace,
    kind: EntityKind,
    name: &str,
    owner: Option<OwnerKey>,
) -> EntityId {
    EntityId {
        origin: DeclarationOrigin::Source(module.clone()),
        module: module.clone(),
        namespace,
        kind,
        name: name.to_owned(),
        site: EntitySite::Source(OriginRef {
            source: source.clone(),
            span,
        }),
        owner,
    }
}

fn owner_key_from_entity(entity: &EntityId) -> OwnerKey {
    let (source, span) = match &entity.site {
        EntitySite::Source(origin) => (origin.source.clone(), origin.span),
        EntitySite::Language => (SourceRef::Root, Span::new(0, 0)),
        EntitySite::Module(module) => (SourceRef::Root, Span::new(module.0.len(), module.0.len())),
    };
    OwnerKey {
        module: entity.module.clone(),
        source,
        span,
        kind: entity.kind,
        name: entity.name.clone(),
    }
}

fn owner_site_span(entity: &EntityId) -> Span {
    match &entity.site {
        EntitySite::Source(origin) => origin.span,
        EntitySite::Language | EntitySite::Module(_) => Span::new(0, 0),
    }
}

fn owner_public(state: &ResolverState, owner: &EntityId) -> bool {
    state
        .entities
        .get(owner)
        .is_some_and(|entity| entity.public)
}

fn is_language_name(namespace: Namespace, name: &str) -> bool {
    match namespace {
        Namespace::Type => LANGUAGE_TYPES.contains(&name) || LANGUAGE_TRAITS.contains(&name),
        Namespace::Effect => LANGUAGE_EFFECTS.contains(&name),
        Namespace::Value | Namespace::Member => false,
    }
}

fn path_text(path: &Path) -> String {
    path.segments
        .iter()
        .map(|segment| match segment {
            PathSegment::Identifier(identifier) => identifier.text.as_str(),
            PathSegment::Super(_) => "super",
        })
        .collect::<Vec<_>>()
        .join("::")
}

fn path_segment_span(segment: &PathSegment) -> Span {
    match segment {
        PathSegment::Identifier(identifier) => identifier.span,
        PathSegment::Super(span) => *span,
    }
}

fn declaration_origins(
    entities: &BTreeSet<EntityId>,
    metadata: &BTreeMap<EntityId, Entity>,
) -> Vec<OriginRef> {
    let mut origins = entities
        .iter()
        .filter_map(|entity| metadata.get(entity)?.declared_at.clone())
        .collect::<Vec<_>>();
    origins.sort();
    origins.dedup();
    origins
}

fn sorted_delivery_origins(deliveries: &BTreeMap<EntityId, Delivery>) -> Vec<OriginRef> {
    let mut origins = deliveries
        .values()
        .filter_map(|delivery| delivery.origin.clone())
        .collect::<Vec<_>>();
    origins.sort();
    origins.dedup();
    origins
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(root: &str, modules: Vec<(Vec<&str>, &str)>) -> ProjectSources {
        ProjectSources {
            root: root.to_owned(),
            modules: modules
                .into_iter()
                .map(|(path, source)| {
                    (
                        FileModulePath::new(path).expect("test module path is valid"),
                        source.to_owned(),
                    )
                })
                .collect(),
        }
    }

    fn module_body<'a>(resolved: &'a ResolvedProject, path: &[&str]) -> &'a ResolvedModuleBody {
        resolved
            .modules
            .get(&ModuleRef(
                path.iter().map(|segment| (*segment).to_owned()).collect(),
            ))
            .and_then(|module| module.body.as_ref())
            .expect("resolved module body exists")
    }

    fn function<'a>(body: &'a ResolvedModuleBody, name: &str) -> &'a ResolvedFunction {
        body.declarations
            .iter()
            .find_map(|declaration| {
                (declaration
                    .identity
                    .as_ref()
                    .is_some_and(|identity| identity.name == name))
                .then_some(&declaration.kind)
            })
            .and_then(|kind| match kind {
                ResolvedDeclarationKind::Function(function) => Some(function),
                _ => None,
            })
            .expect("resolved function exists")
    }

    fn exact(reference: &ResolvedReference) -> &EntityId {
        match reference {
            ResolvedReference::Exact { target, .. } => target,
            ResolvedReference::Selection { .. } => panic!("expected an exact reference"),
        }
    }

    fn path_expression(expression: &ResolvedExpr) -> &ResolvedReference {
        match &expression.kind {
            ResolvedExprKind::Path(reference) => reference,
            _ => panic!("expected path expression"),
        }
    }

    #[test]
    fn validates_abstract_file_module_paths() {
        assert!(FileModulePath::new(["parser", "lexer"]).is_ok());
        assert!(FileModulePath::new(["type", "alias", "_"]).is_ok());
        for invalid in [
            Vec::<&str>::new(),
            vec![""],
            vec!["not-valid"],
            vec!["self"],
            vec!["root"],
        ] {
            assert!(FileModulePath::new(invalid).is_err());
        }
    }

    #[test]
    fn resolves_owned_language_generic_and_sequential_bindings() {
        let mut sources = project(
            r#"
fn choose<T: Eq>(value: T) -> Option<T> {
    let old = value;
    let value = old;
    Option::Some(value)
}
"#,
            vec![],
        );
        let resolved = resolve_project(&sources).expect("project resolves");
        sources.root.clear();
        assert_eq!(resolved, resolved.clone());

        let function = function(module_body(&resolved, &[]), "choose");
        let parameter = &function.parameters[0].binding.identity;
        let first = &function.body.statements[0];
        let second = &function.body.statements[1];
        let ResolvedStatementKind::Let {
            bindings: first_bindings,
            value: first_value,
            ..
        } = &first.kind
        else {
            panic!("first statement is let");
        };
        let ResolvedStatementKind::Let {
            bindings: second_bindings,
            value: second_value,
            ..
        } = &second.kind
        else {
            panic!("second statement is let");
        };
        assert_eq!(exact(path_expression(first_value)), parameter);
        assert_eq!(
            exact(path_expression(second_value)),
            &first_bindings[0].identity
        );
        assert_ne!(first_bindings[0].identity, second_bindings[0].identity);
        let tail = function.body.tail.as_deref().expect("tail expression");
        let ResolvedExprKind::Call { callee, arguments } = &tail.kind else {
            panic!("tail is constructor call");
        };
        assert_eq!(
            exact(path_expression(callee)).kind,
            EntityKind::LanguageConstructor
        );
        let ResolvedCallArgument::Expression(argument) = &arguments[0] else {
            panic!("ordinary argument");
        };
        assert_eq!(
            exact(path_expression(argument)),
            &second_bindings[0].identity
        );
    }

    #[test]
    fn parses_only_sources_reached_by_use() {
        let sources = project(
            "use api; fn main() -> Int { api::answer() }",
            vec![
                ((vec!["api"]), "pub fn answer() -> Int { 42 }"),
                ((vec!["unused"]), "@not_vorton"),
            ],
        );
        let resolved = resolve_project(&sources).expect("unreachable bad source is ignored");
        assert!(module_body(&resolved, &["api"]).declarations.len() == 1);
        assert!(
            resolved
                .modules
                .get(&ModuleRef(vec!["unused".to_owned()]))
                .is_some_and(|module| module.body.is_none())
        );

        let diagnostic = resolve_project(&project("use bad;", vec![(vec!["bad"], "@not_vorton")]))
            .expect_err("reachable bad source fails");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::Frontend(_)
        ));
        assert_eq!(
            diagnostic.primary.expect("source origin").source,
            SourceRef::File(FileModulePath::new(["bad"]).unwrap())
        );
    }

    #[test]
    fn combines_file_inline_and_synthetic_modules_with_modern_paths() {
        let sources = project(
            r#"
use tree::leaf::read;
pub fn root_value() -> Int { 1 }
fn main() -> Int { read() }
"#,
            vec![
                (
                    vec!["tree"],
                    r#"
use root::root_value;
pub fn helper() -> Int { root_value() }
pub mod inline { pub fn plus() -> Int { super::helper() } }
"#,
                ),
                (
                    vec!["tree", "leaf"],
                    r#"
use super::helper;
use super::inline::plus;
pub fn local() -> Int { 1 }
pub fn read() -> Int { self::local() + helper() + plus() }
"#,
                ),
            ],
        );
        let resolved = resolve_project(&sources).expect("mixed logical module tree resolves");
        for path in [vec!["tree"], vec!["tree", "leaf"], vec!["tree", "inline"]] {
            assert!(!module_body(&resolved, &path).declarations.is_empty());
        }
    }

    #[test]
    fn rejects_file_inline_body_collision_even_when_file_is_otherwise_unreached() {
        let diagnostic = resolve_project(&project(
            "mod same {}",
            vec![(vec!["same"], "fn hidden() {}")],
        ))
        .expect_err("one logical path cannot have two bodies");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::ModuleBodyConflict { ref module }
                if module == &vec!["same".to_owned()]
        ));
    }

    #[test]
    fn module_import_binds_only_the_module_and_supports_aliases() {
        resolve_project(&project(
            "use lib as library; fn main() -> Int { library::item() }",
            vec![(vec!["lib"], "pub fn item() -> Int { 1 }")],
        ))
        .expect("module alias resolves");
        resolve_project(&project(
            "use tree as t; use t::leaf::item; fn main() -> Int { item() }",
            vec![
                (vec!["tree"], ""),
                (vec!["tree", "leaf"], "pub fn item() -> Int { 1 }"),
            ],
        ))
        .expect("module alias can make a nested file source reachable");

        let diagnostic = resolve_project(&project(
            "use lib; fn main() -> Int { item() }",
            vec![(vec!["lib"], "pub fn item() -> Int { 1 }")],
        ))
        .expect_err("module import does not import all members");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName {
                namespace: NameNamespace::Value,
                ref name
            } if name == "item"
        ));
    }

    #[test]
    fn rejects_cross_namespace_import_ambiguity() {
        let diagnostic = resolve_project(&project(
            "use names::Same;",
            vec![(vec!["names"], "pub struct Same {} pub fn Same() {}")],
        ))
        .expect_err("one use item cannot import multiple namespaces");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::AmbiguousImport { .. }
        ));
    }

    #[test]
    fn same_origin_diamond_is_idempotent_but_different_origins_conflict() {
        let resolved = resolve_project(&project(
            "use left::item; use right::item; fn main() -> Int { item() }",
            vec![
                (vec!["leaf"], "pub fn item() -> Int { 1 }"),
                (vec!["left"], "pub use root::leaf::item;"),
                (vec!["right"], "pub use root::leaf::item;"),
            ],
        ))
        .expect("same exact declaration delivered twice is one binding");
        let root_values = resolved
            .entities
            .keys()
            .filter(|entity| entity.name == "item" && entity.kind == EntityKind::Function)
            .collect::<Vec<_>>();
        assert_eq!(root_values.len(), 1);

        let diagnostic = resolve_project(&project(
            "use left::item; use right::item;",
            vec![
                (vec!["left"], "pub fn item() -> Int { 1 }"),
                (vec!["right"], "pub fn item() -> Int { 2 }"),
            ],
        ))
        .expect_err("different declarations do not merge by leaf name");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::NameConflict {
                namespace: NameNamespace::Value,
                ref name
            } if name == "item"
        ));
    }

    #[test]
    fn resolves_real_module_cycles_and_rejects_originless_forwarding_cycles() {
        resolve_project(&project(
            "use a::call_a; fn main() -> Int { call_a() }",
            vec![
                (
                    vec!["a"],
                    "use root::b::call_b; pub fn call_a() -> Int { call_b() }",
                ),
                (
                    vec!["b"],
                    "use root::a::call_a; pub fn call_b() -> Int { call_a() }",
                ),
            ],
        ))
        .expect("module back-edges with real declarations resolve");

        let diagnostic = resolve_project(&project(
            "use a::missing;",
            vec![
                (vec!["a"], "pub use root::b::missing;"),
                (vec!["b"], "pub use root::a::missing;"),
            ],
        ))
        .expect_err("forwarding cycle without a declaration has no origin");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::ImportCycle { .. }
        ));
    }

    #[test]
    fn enforces_private_reexports_and_allows_private_module_facades() {
        resolve_project(&project(
            "use facade::visible; fn main() -> Int { visible() }",
            vec![(
                vec!["facade"],
                "pub use hidden::visible; mod hidden { pub fn visible() -> Int { 1 } }",
            )],
        ))
        .expect("facade can expose a public item from its private module");

        let diagnostic = resolve_project(&project(
            "use facade;",
            vec![(vec!["facade"], "pub use private; fn private() -> Int { 1 }")],
        ))
        .expect_err("re-export cannot make a private item public");
        assert!(
            matches!(
                diagnostic.kind,
                ProjectDiagnosticKind::PrivateReExport { .. }
            ),
            "{diagnostic:?}"
        );
    }

    #[test]
    fn constructor_import_is_explicit_and_public_export_keeps_owner_closure() {
        let modules = vec![
            (vec!["leaf"], "pub enum Shape { Circle, Rect(Int) }"),
            (
                vec!["facade"],
                "pub use root::leaf::Shape; pub use root::leaf::Shape::{Circle};",
            ),
        ];
        resolve_project(&project(
            "use facade::{Shape, Circle}; fn main() { match Circle { Circle => (), _ => (), } }",
            modules.clone(),
        ))
        .expect("owner and explicitly imported constructor resolve");

        let diagnostic = resolve_project(&project(
            "use facade;",
            vec![
                (vec!["leaf"], "pub enum Shape { Circle, Rect(Int) }"),
                (vec!["facade"], "pub use root::leaf::Shape::{Circle};"),
            ],
        ))
        .expect_err("public constructor export requires exact owner export");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::MissingConstructorOwner { .. }
        ));

        let diagnostic = resolve_project(&project(
            "use facade::Circle;",
            vec![
                (vec!["leaf"], "pub enum Shape { Circle }"),
                (vec!["facade"], "pub use root::leaf::Shape;"),
            ],
        ))
        .expect_err("re-exporting enum alone does not inject constructors");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedImport { .. }
        ));
    }

    #[test]
    fn language_constructors_require_explicit_import_and_keep_option_owner() {
        let resolved = resolve_project(&project(
            r#"
use Option::{Some, None};
fn make(value: Int) -> Option<Int> {
    match None { None => Some(value), _ => Some(value), }
}
"#,
            vec![],
        ))
        .expect("explicit language constructor imports resolve");
        let constructors = resolved
            .entities
            .values()
            .filter(|entity| entity.id.kind == EntityKind::LanguageConstructor)
            .collect::<Vec<_>>();
        assert_eq!(constructors.len(), 2);
        assert!(constructors.iter().all(|constructor| {
            constructor
                .owner
                .as_ref()
                .is_some_and(|owner| owner.name == "Option")
        }));

        let diagnostic = resolve_project(&project(
            "fn make(value: Int) -> Option<Int> { Some(value) }",
            vec![],
        ))
        .expect_err("constructors are not in an implicit prelude");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "Some"
        ));
    }

    #[test]
    fn branch_bindings_do_not_escape_and_or_pattern_binders_share_identity() {
        let diagnostic = resolve_project(&project(
            r#"
fn leak(value: Option<Int>) {
    if let Option::Some(inner) = value { inner; }
    inner
}
"#,
            vec![],
        ))
        .expect_err("if-let binding is branch-local");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "inner"
        ));
        let diagnostic = resolve_project(&project(
            "fn leak_loop() { for item in [1] { item; } item }",
            vec![],
        ))
        .expect_err("for binding is loop-local");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "item"
        ));

        let resolved = resolve_project(&project(
            r#"
enum Choice { Left(Int), Right(Int) }
fn read(value: Choice) -> Int {
    match value { Choice::Left(item) | Choice::Right(item) => item, }
}
"#,
            vec![],
        ))
        .expect("or-pattern alternatives bind one logical value");
        let function = function(module_body(&resolved, &[]), "read");
        let tail = function.body.tail.as_deref().expect("match tail");
        let ResolvedExprKind::Match { arms, .. } = &tail.kind else {
            panic!("tail is match");
        };
        let ResolvedPatternKind::Or(alternatives) = &arms[0].pattern.kind else {
            panic!("arm retains or alternatives");
        };
        let binder = |pattern: &ResolvedPattern| {
            let ResolvedPatternKind::Constructor {
                fields: Some(ResolvedPatternFields::Positional(fields)),
                ..
            } = &pattern.kind
            else {
                panic!("constructor pattern");
            };
            let ResolvedPatternKind::Binding(binding) = &fields[0].kind else {
                panic!("payload binding");
            };
            binding.identity.clone()
        };
        assert_eq!(binder(&alternatives[0]), binder(&alternatives[1]));

        let diagnostic = resolve_project(&project(
            "fn bad(value: Int) { match value { left | right => (), } }",
            vec![],
        ))
        .expect_err("or alternatives need the same binding set");
        assert_eq!(
            diagnostic.kind,
            ProjectDiagnosticKind::PatternBindingMismatch
        );
    }

    #[test]
    fn generic_self_and_capture_rules_resolve_without_type_selection() {
        let resolved = resolve_project(&project(
            r#"
struct Boxed<T> { value: T }
impl<T: Eq> Boxed<T> {
    fn get(self: Self) -> T {
        let closure = fn [self]() -> T { self.value };
        closure()
    }
}
trait Identity<T> { fn identity(self: Self) -> T; }
"#,
            vec![],
        ))
        .expect("generic and owner Self scopes resolve");
        assert!(
            resolved
                .entities
                .keys()
                .any(|entity| entity.kind == EntityKind::SelfType)
        );
        let self_bindings = resolved
            .entities
            .keys()
            .filter(|entity| entity.name == "self" && entity.namespace == Namespace::Value)
            .collect::<Vec<_>>();
        assert_eq!(self_bindings.len(), 2, "method and trait parameters");
        assert!(
            self_bindings
                .iter()
                .all(|binding| binding.kind == EntityKind::Parameter),
            "capture occurrence must not create a source binder"
        );

        let diagnostic = resolve_project(&project(
            "fn bad<T: Eq>() { let closure = fn [missing]() { missing; }; }",
            vec![],
        ))
        .expect_err("explicit capture resolves in the outer value scope");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "missing"
        ));

        let diagnostic = resolve_project(&project(
            "struct Boxed<T> { value: T } impl<T> Boxed<T> { fn bad<T>() {} }",
            vec![],
        ))
        .expect_err("member generic cannot shadow visible impl generic");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::DuplicateBinding { ref name } if name == "T"
        ));
    }

    #[test]
    fn type_dependent_member_selection_keeps_exact_base_without_faking_target() {
        let resolved = resolve_project(&project(
            r#"
trait HasItem { type Item; fn get(self: Self) -> Item; }
fn read<T: HasItem>(value: T) -> T::Item { value.get() }
"#,
            vec![],
        ))
        .expect("type-dependent selection is a resolved carrier state");
        let root = module_body(&resolved, &[]);
        let trait_declaration = root
            .declarations
            .iter()
            .find(|declaration| {
                declaration
                    .identity
                    .as_ref()
                    .is_some_and(|identity| identity.name == "HasItem")
            })
            .expect("trait declaration");
        let ResolvedDeclarationKind::Trait { members, .. } = &trait_declaration.kind else {
            panic!("resolved trait");
        };
        let ResolvedTraitMemberKind::Method(signature) = &members[1].kind else {
            panic!("trait method");
        };
        let ResolvedTypeKind::Named(unqualified_item) = &signature
            .return_type
            .as_ref()
            .expect("trait method return")
            .kind
        else {
            panic!("unqualified associated type");
        };
        let ResolvedReference::Selection { members, .. } = &unqualified_item.reference else {
            panic!("unqualified associated item is still an explicit selection");
        };
        assert_eq!(
            members[0]
                .declaration
                .as_ref()
                .expect("exact associated declaration")
                .kind,
            EntityKind::AssociatedType
        );

        let function = function(root, "read");
        let return_type = function.return_type.as_ref().expect("return annotation");
        let ResolvedTypeKind::Named(named) = &return_type.kind else {
            panic!("named associated type");
        };
        let ResolvedReference::Selection { base, members, .. } = &named.reference else {
            panic!("associated type remains an explicit selection");
        };
        assert_eq!(base.kind, EntityKind::TypeParameter);
        assert_eq!(members[0].name, "Item");
        assert!(members[0].declaration.is_none());
        let tail = function.body.tail.as_deref().expect("method call tail");
        let ResolvedExprKind::MethodCall { method, .. } = &tail.kind else {
            panic!("method call remains a member selection");
        };
        assert_eq!(method.name, "get");
        assert!(method.declaration.is_none());
    }

    #[test]
    fn effect_operation_receiver_is_exact_and_cross_namespace_ambiguity_is_rejected() {
        let resolved = resolve_project(&project(
            r#"
effect Logger { fn log(value: Int) -> Unit; }
fn write() -> Unit with {Logger} { Logger.log(1) }
"#,
            vec![],
        ))
        .expect("custom effect operation resolves through the method surface");
        let function = function(module_body(&resolved, &[]), "write");
        let tail = function.body.tail.as_deref().expect("effect call tail");
        let ResolvedExprKind::MethodCall {
            receiver, method, ..
        } = &tail.kind
        else {
            panic!("effect operation is a method-shaped call");
        };
        let ResolvedExprKind::Path(receiver) = &receiver.kind else {
            panic!("effect receiver retains its exact path");
        };
        assert_eq!(exact(receiver).kind, EntityKind::Effect);
        assert_eq!(
            method
                .declaration
                .as_ref()
                .expect("known custom operation declaration")
                .kind,
            EntityKind::EffectOperation
        );

        let diagnostic = resolve_project(&project(
            r#"
effect Source { fn read() -> Int; }
fn Source() -> Int { 1 }
fn ambiguous() -> Int { Source.read() }
"#,
            vec![],
        ))
        .expect_err("effect and value receivers have no namespace priority");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::AmbiguousName { ref name } if name == "Source"
        ));

        let diagnostic = resolve_project(&project(
            "effect Empty {} fn bad() { Empty.missing() }",
            vec![],
        ))
        .expect_err("known custom effect cannot invent an operation");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "missing"
        ));
    }

    #[test]
    fn expression_paths_do_not_load_file_sources() {
        let diagnostic = resolve_project(&project(
            "fn main() { dormant::call() }",
            vec![(vec!["dormant"], "@bad")],
        ))
        .expect_err("ordinary expression path cannot make a file source reachable");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::UnresolvedName { ref name, .. } if name == "call"
        ));
    }

    #[test]
    fn language_bindings_are_reserved_only_in_their_namespace() {
        let diagnostic = resolve_project(&project("struct Int {}", vec![]))
            .expect_err("language type cannot be redeclared");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::ReservedLanguageBinding {
                namespace: NameNamespace::Type,
                ref name
            } if name == "Int"
        ));

        resolve_project(&project("fn Int() -> Int { 1 }", vec![]))
            .expect("same spelling in value namespace is independent");
        resolve_project(&project(
            "fn Self() -> Int { 1 } fn call() -> Int { Self() }",
            vec![],
        ))
        .expect("special Type spelling does not occupy the Value namespace");

        let diagnostic = resolve_project(&project("fn bad<Int>(value: Int) {}", vec![]))
            .expect_err("generic cannot shadow language type");
        assert!(matches!(
            diagnostic.kind,
            ProjectDiagnosticKind::ReservedLanguageBinding { .. }
        ));
        let diagnostic = resolve_project(&project(
            "use types::Thing as Self;",
            vec![(vec!["types"], "pub struct Thing {}")],
        ))
        .expect_err("import cannot occupy owner-scoped Self in the Type namespace");
        assert_eq!(diagnostic.kind, ProjectDiagnosticKind::InvalidSelf);
    }

    #[test]
    fn result_and_diagnostic_are_stable_across_map_insertion_order() {
        let mut first = BTreeMap::new();
        first.insert(
            FileModulePath::new(["a"]).unwrap(),
            "pub fn item() -> Int { 1 }".to_owned(),
        );
        first.insert(FileModulePath::new(["z"]).unwrap(), "@bad".to_owned());
        let mut second = BTreeMap::new();
        second.insert(FileModulePath::new(["z"]).unwrap(), "@bad".to_owned());
        second.insert(
            FileModulePath::new(["a"]).unwrap(),
            "pub fn item() -> Int { 1 }".to_owned(),
        );
        let root = "use a::item; fn main() -> Int { item() }".to_owned();
        let left = resolve_project(&ProjectSources {
            root: root.clone(),
            modules: first,
        })
        .expect("project resolves");
        let right = resolve_project(&ProjectSources {
            root,
            modules: second,
        })
        .expect("project resolves independently of insertion order");
        assert_eq!(left, right);

        let bad_root = "use z;".to_owned();
        let left_error = resolve_project(&ProjectSources {
            root: bad_root.clone(),
            modules: left_source_maps(),
        })
        .expect_err("reachable bad module fails");
        let right_error = resolve_project(&ProjectSources {
            root: bad_root,
            modules: right_source_maps(),
        })
        .expect_err("same error with reverse construction");
        assert_eq!(left_error, right_error);
    }

    fn left_source_maps() -> BTreeMap<FileModulePath, String> {
        let mut modules = BTreeMap::new();
        modules.insert(FileModulePath::new(["a"]).unwrap(), "fn ok() {}".to_owned());
        modules.insert(FileModulePath::new(["z"]).unwrap(), "@bad".to_owned());
        modules
    }

    fn right_source_maps() -> BTreeMap<FileModulePath, String> {
        let mut modules = BTreeMap::new();
        modules.insert(FileModulePath::new(["z"]).unwrap(), "@bad".to_owned());
        modules.insert(FileModulePath::new(["a"]).unwrap(), "fn ok() {}".to_owned());
        modules
    }
}
