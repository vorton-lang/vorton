//! Strict, structure-only decoding for the public Vorton contract format.

#![allow(
    dead_code,
    reason = "the opaque document must retain every decoded field without exposing a query API"
)]

use serde::de;
use serde::{Deserialize, Deserializer};

/// An owned contract input whose complete format-1 structure has been decoded.
///
/// The carrier is intentionally opaque. Decoding does not bind references to a
/// project, apply clauses, or establish any source-language semantic fact.
pub struct ContractDocument(Document);

/// A stable category for one contract input failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContractDiagnosticKind {
    /// The supplied bytes are not valid UTF-8.
    InvalidEncoding,
    /// The input is not one complete strict JSON document.
    InvalidJson,
    /// The JSON value does not match the supported format-1 record structure.
    InvalidStructure,
    /// `format_version` is a well-formed integer but is not supported.
    UnsupportedFormatVersion,
    /// `semantics_version` is a well-formed string but is not supported.
    UnsupportedSemanticsVersion,
    /// The JSON container depth reaches the reader's fixed protection limit.
    NestingLimitExceeded,
}

/// Structured information about a failed [`crate::decode_contract`] call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContractDiagnostic {
    /// Stable high-level failure category.
    pub kind: ContractDiagnosticKind,
    /// A readable description of the rejected input.
    pub message: String,
    /// A JSON path when the decoder can prove a containing field or element.
    pub path: Option<String>,
    /// One-based JSON line when reported by the parser or derived from a byte.
    pub line: Option<usize>,
    /// One-based byte column when reported by the parser or derived from a byte.
    pub column: Option<usize>,
    /// Zero-based input byte offset when it can be derived without guessing.
    pub byte_offset: Option<usize>,
}

pub(crate) fn decode_contract(source: &[u8]) -> Result<ContractDocument, ContractDiagnostic> {
    if let Err(error) = std::str::from_utf8(source) {
        let byte_offset = error.valid_up_to();
        let (line, column) = line_column_at(source, byte_offset);
        return Err(ContractDiagnostic {
            kind: ContractDiagnosticKind::InvalidEncoding,
            message: "contract input is not valid UTF-8".to_owned(),
            path: None,
            line: Some(line),
            column: Some(column),
            byte_offset: Some(byte_offset),
        });
    }

    let mut deserializer = serde_json::Deserializer::from_slice(source);
    let document =
        serde_path_to_error::deserialize::<_, Document>(&mut deserializer).map_err(|error| {
            let path = json_path(error.path());
            json_diagnostic(source, error.into_inner(), path)
        })?;
    deserializer
        .end()
        .map_err(|error| json_diagnostic(source, error, None))?;
    validate_document(&document)?;
    Ok(ContractDocument(document))
}

fn validate_document(document: &Document) -> Result<(), ContractDiagnostic> {
    if document.format != "vorton.contract" {
        return Err(structure_diagnostic(
            "$.format",
            "format must be `vorton.contract`",
        ));
    }
    if document.format_version.0 != 1 {
        return Err(ContractDiagnostic {
            kind: ContractDiagnosticKind::UnsupportedFormatVersion,
            message: format!(
                "unsupported contract format version {}; only version 1 is supported",
                document.format_version.0
            ),
            path: Some("$.format_version".to_owned()),
            line: None,
            column: None,
            byte_offset: None,
        });
    }
    if document.semantics_version != "0.1" {
        return Err(ContractDiagnostic {
            kind: ContractDiagnosticKind::UnsupportedSemanticsVersion,
            message: format!(
                "unsupported contract semantics version {:?}; only `0.1` is supported",
                document.semantics_version
            ),
            path: Some("$.semantics_version".to_owned()),
            line: None,
            column: None,
            byte_offset: None,
        });
    }
    if document.owner.is_empty() {
        return Err(structure_diagnostic(
            "$.owner",
            "owner must contain at least one character",
        ));
    }

    for (record_index, record) in document.records.iter().enumerate() {
        if record.set.is_none() && record.check.is_none() {
            return Err(structure_diagnostic(
                &format!("$.records[{record_index}]"),
                "record must provide `set`, `check`, or both",
            ));
        }
        if let Some(set) = &record.set
            && set.is_empty()
        {
            return Err(structure_diagnostic(
                &format!("$.records[{record_index}].set"),
                "set must contain at least one clause",
            ));
        }
        if let Some(check) = &record.check
            && check.is_empty()
        {
            return Err(structure_diagnostic(
                &format!("$.records[{record_index}].check"),
                "check must contain at least one clause",
            ));
        }
    }
    Ok(())
}

fn structure_diagnostic(path: &str, message: &str) -> ContractDiagnostic {
    ContractDiagnostic {
        kind: ContractDiagnosticKind::InvalidStructure,
        message: message.to_owned(),
        path: Some(path.to_owned()),
        line: None,
        column: None,
        byte_offset: None,
    }
}

fn json_diagnostic(
    source: &[u8],
    error: serde_json::Error,
    path: Option<String>,
) -> ContractDiagnostic {
    let message = error.to_string();
    let kind = if message.starts_with("recursion limit exceeded") {
        ContractDiagnosticKind::NestingLimitExceeded
    } else if error.is_data() || message.starts_with("number out of range") {
        ContractDiagnosticKind::InvalidStructure
    } else {
        ContractDiagnosticKind::InvalidJson
    };
    let line = (error.line() != 0).then_some(error.line());
    let column = (error.column() != 0).then_some(error.column());
    let byte_offset = line
        .zip(column)
        .and_then(|(line, column)| byte_offset_at(source, line, column));
    ContractDiagnostic {
        kind,
        message,
        path,
        line,
        column,
        byte_offset,
    }
}

fn json_path(path: &serde_path_to_error::Path) -> Option<String> {
    let path = path.to_string();
    if path.is_empty() || path == "." {
        None
    } else if path.starts_with('[') {
        Some(format!("${path}"))
    } else {
        Some(format!("$.{path}"))
    }
}

fn line_column_at(source: &[u8], byte_offset: usize) -> (usize, usize) {
    let prefix = &source[..byte_offset.min(source.len())];
    let line = prefix.iter().filter(|byte| **byte == b'\n').count() + 1;
    let line_start = prefix
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |index| index + 1);
    (line, byte_offset.saturating_sub(line_start) + 1)
}

fn byte_offset_at(source: &[u8], line: usize, column: usize) -> Option<usize> {
    if line == 0 || column == 0 {
        return None;
    }
    let mut current_line = 1;
    let mut line_start = 0;
    for (index, byte) in source.iter().enumerate() {
        if current_line == line {
            break;
        }
        if *byte == b'\n' {
            current_line += 1;
            line_start = index + 1;
        }
    }
    if current_line != line {
        return None;
    }
    let offset = line_start.checked_add(column - 1)?;
    (offset <= source.len()).then_some(offset)
}

fn deserialize_optional<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
}

#[derive(Debug, PartialEq, Deserialize)]
struct WireU64(u64);

#[derive(Debug, PartialEq)]
struct NonEmptyVec<T>(Vec<T>);

impl<'de, T> Deserialize<'de> for NonEmptyVec<T>
where
    T: Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let values = Vec::deserialize(deserializer)?;
        if values.is_empty() {
            Err(de::Error::custom("array must contain at least one item"))
        } else {
            Ok(Self(values))
        }
    }
}

#[derive(Debug, PartialEq)]
struct TupleElements<T>(Vec<T>);

impl<'de, T> Deserialize<'de> for TupleElements<T>
where
    T: Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let values = Vec::deserialize(deserializer)?;
        if values.len() < 2 {
            Err(de::Error::custom(
                "tuple type must contain at least two elements",
            ))
        } else {
            Ok(Self(values))
        }
    }
}

#[derive(Debug, PartialEq)]
struct Identifier(String);

impl<'de> Deserialize<'de> for Identifier {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        let valid = value
            .as_bytes()
            .first()
            .is_some_and(|byte| byte.is_ascii_alphabetic() || *byte == b'_')
            && value
                .as_bytes()
                .iter()
                .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_');
        if valid {
            Ok(Self(value))
        } else {
            Err(de::Error::custom(
                "identifier must match ^[A-Za-z_][A-Za-z0-9_]*$",
            ))
        }
    }
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    format: String,
    format_version: WireU64,
    semantics_version: String,
    owner: String,
    records: Vec<Record>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    display: Option<DisplayFields>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct DisplayFields {
    #[serde(default, deserialize_with = "deserialize_optional")]
    label: Option<String>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    note: Option<String>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
enum LibraryRef {
    #[serde(rename = "self")]
    Current {},
    Dependency {
        alias: Identifier,
    },
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum DeclarationKind {
    Function,
    Struct,
    Enum,
    Trait,
    TypeAlias,
    Const,
    Effect,
    EffectAlias,
    Module,
    ExternType,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct DeclRef {
    library: LibraryRef,
    path: Vec<Identifier>,
    kind: DeclarationKind,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum TraitKind {
    Trait,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct TraitRef {
    library: LibraryRef,
    path: Vec<Identifier>,
    kind: TraitKind,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum FunctionKind {
    Function,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct FunctionDeclRef {
    library: LibraryRef,
    path: Vec<Identifier>,
    kind: FunctionKind,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum EffectKind {
    Effect,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct EffectDeclRef {
    library: LibraryRef,
    path: Vec<Identifier>,
    kind: EffectKind,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum SelfDeclarationKind {
    Struct,
    Enum,
    Trait,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct SelfDeclRef {
    library: LibraryRef,
    path: Vec<Identifier>,
    kind: SelfDeclarationKind,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum MemberKind {
    Method,
    AssociatedType,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum MethodKind {
    Method,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct PatternTrait {
    #[serde(rename = "trait")]
    trait_ref: TraitRef,
    arguments: Vec<TypePattern>,
    associated_bindings: Vec<PatternAssociatedBinding>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct PatternAssociatedBinding {
    name: Identifier,
    #[serde(rename = "type")]
    value_type: TypePattern,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
enum TypePattern {
    Primitive {
        name: PrimitiveType,
    },
    Ptr {
        pointee: Box<TypePattern>,
    },
    Nominal {
        declaration: DeclRef,
        arguments: Vec<TypePattern>,
    },
    LocalTypeParameter {
        index: WireU64,
    },
    Tuple {
        elements: TupleElements<TypePattern>,
    },
    Associated {
        base: Box<TypePattern>,
        #[serde(rename = "trait")]
        trait_ref: PatternTrait,
        name: Identifier,
    },
    List {
        element: Box<TypePattern>,
    },
    Range {
        element: Box<TypePattern>,
    },
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "PascalCase")]
enum PrimitiveType {
    Int,
    Float,
    Str,
    Bool,
    Unit,
    Never,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct ImplRef {
    library: LibraryRef,
    type_parameter_count: WireU64,
    target: TypePattern,
    #[serde(default, deserialize_with = "deserialize_optional")]
    #[serde(rename = "trait")]
    trait_ref: Option<PatternTrait>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
enum EntityRef {
    Declaration {
        declaration: DeclRef,
    },
    TraitMember {
        owner: TraitRef,
        kind: MemberKind,
        name: Identifier,
    },
    ImplMember {
        owner: ImplRef,
        kind: MemberKind,
        name: Identifier,
    },
    Impl {
        implementation: ImplRef,
    },
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
enum FunctionRef {
    Declaration {
        declaration: FunctionDeclRef,
    },
    TraitMember {
        owner: TraitRef,
        kind: MethodKind,
        name: Identifier,
    },
    ImplMember {
        owner: Box<ImplRef>,
        kind: MethodKind,
        name: Identifier,
    },
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Binder {
    Declaration,
    Impl,
    Method,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum TypeFormalKind {
    Type,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct TypeFormalRef {
    owner: EntityRef,
    binder: Binder,
    kind: TypeFormalKind,
    index: WireU64,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum EffectFormalKind {
    Effect,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct EffectFormalRef {
    owner: EntityRef,
    binder: Binder,
    kind: EffectFormalKind,
    index: WireU64,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct TraitUse {
    #[serde(rename = "trait")]
    trait_ref: TraitRef,
    arguments: Vec<Type>,
    associated_bindings: Vec<AssociatedBinding>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct AssociatedBinding {
    name: Identifier,
    #[serde(rename = "type")]
    value_type: Type,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
enum Type {
    Primitive {
        name: PrimitiveType,
    },
    Ptr {
        pointee: Box<Type>,
    },
    Nominal {
        declaration: DeclRef,
        arguments: Vec<Type>,
    },
    Formal {
        formal: TypeFormalRef,
    },
    Tuple {
        elements: TupleElements<Type>,
    },
    Associated {
        base: Box<Type>,
        #[serde(rename = "trait")]
        trait_ref: TraitUse,
        name: Identifier,
    },
    FunctionItem {
        function: FunctionRef,
        owner_type_arguments: Vec<Type>,
        type_arguments: Vec<Type>,
        effect_arguments: Vec<EffectRow>,
    },
    OpaqueCallable {
        function: FunctionRef,
        owner_type_arguments: Vec<Type>,
        type_arguments: Vec<Type>,
        effect_arguments: Vec<EffectRow>,
    },
    List {
        element: Box<Type>,
    },
    Range {
        element: Box<Type>,
    },
    #[serde(rename = "self_type")]
    SelfReference {
        owner: SelfOwner,
    },
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
enum SelfOwner {
    Declaration { declaration: SelfDeclRef },
    Impl { implementation: ImplRef },
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Mode {
    Borrow,
    Mut,
    Move,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
enum ModeRule {
    Fixed { mode: Mode },
    CallableUse { callable: Box<Type> },
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum EscapeRule {
    Noescape,
    MayEscape,
}

type EffectRow = Vec<EffectTerm>;

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum SystemEffect {
    Console,
    Fs,
    Process,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
enum EffectTerm {
    System {
        name: SystemEffect,
    },
    Handled {
        effect: EffectDeclRef,
        arguments: Vec<Type>,
    },
    Fail {
        payload: Type,
    },
    Mut {},
    Unsafe {},
    Formal {
        formal: EffectFormalRef,
    },
    MethodApplication {
        method: TraitMethodRef,
        #[serde(rename = "self")]
        self_type: Type,
        trait_type_arguments: Vec<Type>,
        method_type_arguments: Vec<Type>,
        effect_arguments: Vec<EffectRow>,
    },
    FullDestruction {
        #[serde(rename = "type")]
        value_type: Type,
    },
    SelectedCall {
        callable: Type,
    },
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct TraitMethodRef {
    tag: TraitMemberTag,
    owner: TraitRef,
    kind: MethodKind,
    name: Identifier,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum TraitMemberTag {
    TraitMember,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
enum ParameterRef {
    Receiver {},
    Position { index: WireU64 },
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct PatternPredicate {
    subject: TypePattern,
    requires: PatternTrait,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct ParameterTypeSet {
    parameter: ParameterRef,
    #[serde(rename = "type")]
    value_type: Type,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct ParameterModeSet {
    parameter: ParameterRef,
    mode: ModeRule,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct ParameterEscapeSet {
    parameter: ParameterRef,
    escape: EscapeRule,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct SetClauses {
    #[serde(default, deserialize_with = "deserialize_optional")]
    parameter_types: Option<NonEmptyVec<ParameterTypeSet>>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    return_type: Option<Type>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    parameter_modes: Option<NonEmptyVec<ParameterModeSet>>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    parameter_escape: Option<NonEmptyVec<ParameterEscapeSet>>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    effect_upper: Option<EffectRow>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    generic_requirements: Option<Vec<GenericRequirement>>,
}

impl SetClauses {
    fn is_empty(&self) -> bool {
        self.parameter_types.is_none()
            && self.return_type.is_none()
            && self.parameter_modes.is_none()
            && self.parameter_escape.is_none()
            && self.effect_upper.is_none()
            && self.generic_requirements.is_none()
    }
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Visibility {
    Public,
    Private,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct FieldRequirement {
    name: Identifier,
    #[serde(default, deserialize_with = "deserialize_optional")]
    #[serde(rename = "type")]
    value_type: Option<Type>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    visibility: Option<Visibility>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct ParameterRequirement {
    parameter: ParameterRef,
    #[serde(default, deserialize_with = "deserialize_optional")]
    #[serde(rename = "type")]
    value_type: Option<Type>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum MatchRule {
    Exact,
    Contains,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
enum VariantLayout {
    Unit {},
    Tuple {
        elements: Vec<Type>,
    },
    Named {
        #[serde(rename = "match")]
        match_rule: MatchRule,
        ordered: bool,
        fields: Vec<FieldRequirement>,
    },
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct VariantRequirement {
    name: Identifier,
    #[serde(default, deserialize_with = "deserialize_optional")]
    layout: Option<VariantLayout>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct MemberRequirement {
    name: Identifier,
    kind: MemberKind,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
enum StructureCheck {
    Parameters {
        #[serde(rename = "match")]
        match_rule: MatchRule,
        items: Vec<ParameterRequirement>,
    },
    Fields {
        #[serde(rename = "match")]
        match_rule: MatchRule,
        ordered: bool,
        items: Vec<FieldRequirement>,
    },
    Variants {
        #[serde(rename = "match")]
        match_rule: MatchRule,
        ordered: bool,
        items: Vec<VariantRequirement>,
    },
    Members {
        #[serde(rename = "match")]
        match_rule: MatchRule,
        items: Vec<MemberRequirement>,
        ordered: bool,
    },
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Namespace {
    Type,
    Value,
    Effect,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct ExportName {
    path: NonEmptyVec<Identifier>,
    namespace: Namespace,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct ExportRequirement {
    name: ExportName,
    #[serde(default, deserialize_with = "deserialize_optional")]
    target: Option<EntityRef>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct ExportsCheck {
    #[serde(rename = "match")]
    match_rule: MatchRule,
    items: Vec<ExportRequirement>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct ImplAllowance {
    implementation: ImplRef,
    predicates: Vec<PatternPredicate>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct RejectNewCheck {
    allowed_exports: Vec<ExportName>,
    allowed_impls: Vec<ImplAllowance>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct CheckClauses {
    #[serde(default, deserialize_with = "deserialize_optional")]
    return_traits: Option<NonEmptyVec<TraitUse>>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    structure: Option<NonEmptyVec<StructureCheck>>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    visibility: Option<Visibility>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    exports: Option<ExportsCheck>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    reject_new: Option<RejectNewCheck>,
}

impl CheckClauses {
    fn is_empty(&self) -> bool {
        self.return_traits.is_none()
            && self.structure.is_none()
            && self.visibility.is_none()
            && self.exports.is_none()
            && self.reject_new.is_none()
    }
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    target: EntityRef,
    #[serde(default, deserialize_with = "deserialize_optional")]
    set: Option<SetClauses>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    check: Option<CheckClauses>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    display: Option<DisplayFields>,
    #[serde(default, deserialize_with = "deserialize_optional")]
    type_parameters: Option<Vec<Identifier>>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct ShapeParameter {
    #[serde(rename = "type")]
    value_type: Type,
    mode: ModeRule,
    escape: EscapeRule,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
struct CallableShapeConstraint {
    parameters: Vec<ShapeParameter>,
    result: Type,
    #[serde(default, deserialize_with = "deserialize_optional")]
    effect_upper: Option<EffectRow>,
}

#[derive(Debug, PartialEq, Deserialize)]
#[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
enum GenericRequirement {
    Trait {
        subject: Type,
        bound: TraitUse,
    },
    CallableShape {
        subject: Type,
        shape: Box<CallableShapeConstraint>,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    const COMPLETE_FIXTURE: &str = include_str!("../tests/fixtures/contract-format-1.json");
    const PUBLISHED_SCHEMA: &str = include_str!("../../../docs/contract-format-1.schema.json");

    fn document_with_record(record: &str) -> String {
        format!(
            r#"{{"format":"vorton.contract","format_version":1,"semantics_version":"0.1","owner":"owner","records":[{record}]}}"#
        )
    }

    fn declaration_target() -> &'static str {
        r#"{"tag":"declaration","declaration":{"library":{"tag":"self"},"path":["missing"],"kind":"function"}}"#
    }

    fn document_with_return_type(value_type: &str) -> String {
        document_with_record(&format!(
            r#"{{"target":{},"set":{{"return_type":{value_type}}}}}"#,
            declaration_target()
        ))
    }

    fn minimal_document() -> String {
        document_with_return_type(r#"{"tag":"primitive","name":"Unit"}"#)
    }

    fn error(source: impl AsRef<[u8]>) -> ContractDiagnostic {
        match decode_contract(source.as_ref()) {
            Ok(_) => panic!("input should be rejected"),
            Err(diagnostic) => diagnostic,
        }
    }

    fn max_container_depth(source: &str) -> usize {
        let mut depth = 0;
        let mut maximum = 0;
        let mut in_string = false;
        let mut escaped = false;
        for byte in source.bytes() {
            if in_string {
                if escaped {
                    escaped = false;
                } else if byte == b'\\' {
                    escaped = true;
                } else if byte == b'"' {
                    in_string = false;
                }
                continue;
            }
            match byte {
                b'"' => in_string = true,
                b'{' | b'[' => {
                    depth += 1;
                    maximum = maximum.max(depth);
                }
                b'}' | b']' => depth -= 1,
                _ => {}
            }
        }
        maximum
    }

    #[test]
    fn complete_fixture_preserves_records_order_and_optional_states_without_binding() {
        let document = crate::decode_contract(COMPLETE_FIXTURE.as_bytes())
            .expect("the complete format-1 fixture should decode")
            .0;

        assert_eq!(document.owner, "host-selected-library-label");
        assert_eq!(document.records.len(), 4);
        let display = document.display.expect("top-level display is preserved");
        assert_eq!(display.label.as_deref(), Some("Complete format-1 fixture"));
        assert_eq!(
            display.note.as_deref(),
            Some("fixture keeps display text and input order")
        );

        let first = &document.records[0];
        let type_parameters = first
            .type_parameters
            .as_ref()
            .expect("explicit type parameter list");
        assert_eq!(type_parameters[0].0, "Zed");
        assert_eq!(type_parameters[1].0, "Alpha");
        let set = first.set.as_ref().expect("set clauses");
        assert_eq!(
            set.generic_requirements
                .as_ref()
                .expect("selected requirements")
                .len(),
            2
        );
        let effects = set.effect_upper.as_ref().expect("selected effect upper");
        assert!(matches!(effects[0], EffectTerm::System { .. }));
        assert!(matches!(effects[1], EffectTerm::Handled { .. }));
        assert!(matches!(effects[2], EffectTerm::Fail { .. }));
        assert!(matches!(effects[3], EffectTerm::Mut {}));
        assert!(matches!(effects[4], EffectTerm::Unsafe {}));
        assert!(matches!(effects[5], EffectTerm::Formal { .. }));
        assert!(matches!(effects[6], EffectTerm::MethodApplication { .. }));
        assert!(matches!(effects[7], EffectTerm::FullDestruction { .. }));
        assert!(matches!(effects[8], EffectTerm::SelectedCall { .. }));
        assert_eq!(
            first
                .check
                .as_ref()
                .expect("check clauses")
                .structure
                .as_ref()
                .expect("structure checks")
                .0
                .len(),
            4
        );

        let explicit_empty = document.records[1].set.as_ref().expect("set clauses");
        assert_eq!(explicit_empty.effect_upper.as_deref(), Some(&[][..]));
        assert_eq!(
            explicit_empty.generic_requirements.as_deref(),
            Some(&[][..])
        );
        let omitted = document.records[2].set.as_ref().expect("set clauses");
        assert!(omitted.effect_upper.is_none());
        assert!(omitted.generic_requirements.is_none());

        assert!(matches!(
            document.records[0]
                .set
                .as_ref()
                .and_then(|clauses| clauses.return_type.as_ref()),
            Some(Type::SelfReference {
                owner: SelfOwner::Declaration { .. }
            })
        ));
        assert!(matches!(
            document.records[3]
                .set
                .as_ref()
                .and_then(|clauses| clauses.return_type.as_ref()),
            Some(Type::SelfReference {
                owner: SelfOwner::Impl { .. }
            })
        ));
    }

    #[test]
    fn published_schema_names_the_same_format_profile_and_complete_record_families() {
        let schema: serde_json::Value =
            serde_json::from_str(PUBLISHED_SCHEMA).expect("published schema is strict JSON");
        assert_eq!(schema["$id"], "urn:vorton:contract:format-1");
        assert_eq!(schema["properties"]["format"]["const"], "vorton.contract");
        assert_eq!(schema["properties"]["format_version"]["const"], 1);
        assert_eq!(schema["properties"]["semantics_version"]["const"], "0.1");
        assert_eq!(schema["$defs"]["Index"]["maximum"].as_u64(), Some(u64::MAX));
        for definition in [
            "Record",
            "Set",
            "Check",
            "Type",
            "TypePattern",
            "EffectTerm",
            "GenericRequirement",
            "SelfOwner",
        ] {
            assert!(
                schema["$defs"].get(definition).is_some(),
                "schema must publish {definition}"
            );
        }
        decode_contract(COMPLETE_FIXTURE.as_bytes())
            .expect("the published representative fixture follows the reader profile");
    }

    #[test]
    fn object_member_order_does_not_change_the_decoded_structure() {
        let canonical = minimal_document();
        let reordered = r#"{
            "records":[{
                "set":{"return_type":{"name":"Unit","tag":"primitive"}},
                "target":{"declaration":{"kind":"function","path":["missing"],"library":{"tag":"self"}},"tag":"declaration"}
            }],
            "owner":"owner",
            "semantics_version":"0.1",
            "format_version":1,
            "format":"vorton.contract"
        }"#;
        let left = decode_contract(canonical.as_bytes())
            .expect("canonical order")
            .0;
        let right = decode_contract(reordered.as_bytes())
            .expect("reordered members")
            .0;
        assert_eq!(left, right);
    }

    #[test]
    fn missing_empty_and_nonempty_generic_requirements_remain_distinct() {
        let source = format!(
            r#"{{"format":"vorton.contract","format_version":1,"semantics_version":"0.1","owner":"owner","records":[
                {{"target":{},"set":{{"return_type":{{"tag":"primitive","name":"Unit"}}}}}},
                {{"target":{},"set":{{"generic_requirements":[]}}}},
                {{"target":{},"set":{{"generic_requirements":[{{"tag":"trait","subject":{{"tag":"primitive","name":"Int"}},"bound":{{"trait":{{"library":{{"tag":"self"}},"path":["Missing"],"kind":"trait"}},"arguments":[],"associated_bindings":[]}}}}]}}}}
            ]}}"#,
            declaration_target(),
            declaration_target(),
            declaration_target()
        );
        let document = decode_contract(source.as_bytes())
            .expect("three requirement states")
            .0;
        assert!(
            document.records[0]
                .set
                .as_ref()
                .expect("set")
                .generic_requirements
                .is_none()
        );
        assert_eq!(
            document.records[1]
                .set
                .as_ref()
                .expect("set")
                .generic_requirements
                .as_deref(),
            Some(&[][..])
        );
        assert_eq!(
            document.records[2]
                .set
                .as_ref()
                .expect("set")
                .generic_requirements
                .as_ref()
                .expect("selected requirements")
                .len(),
            1
        );
    }

    #[test]
    fn explicit_null_empty_clause_objects_and_type_parameter_only_records_are_rejected() {
        let null_cases = [
            minimal_document().replace(r#""records":"#, r#""display":null,"records":"#),
            document_with_record(&format!(
                r#"{{"target":{},"set":{{"effect_upper":null}}}}"#,
                declaration_target()
            )),
            document_with_record(&format!(
                r#"{{"target":{},"set":{{"return_type":{{"tag":"self_type","owner":{{"tag":"impl","implementation":{{"library":{{"tag":"self"}},"type_parameter_count":0,"target":{{"tag":"primitive","name":"Int"}},"trait":null}}}}}}}}}}"#,
                declaration_target()
            )),
        ];
        for source in null_cases {
            assert_eq!(error(source).kind, ContractDiagnosticKind::InvalidStructure);
        }

        for record in [
            format!(r#"{{"target":{},"set":{{}}}}"#, declaration_target()),
            format!(r#"{{"target":{},"check":{{}}}}"#, declaration_target()),
            format!(
                r#"{{"target":{},"type_parameters":["T"]}}"#,
                declaration_target()
            ),
        ] {
            assert_eq!(
                error(document_with_record(&record)).kind,
                ContractDiagnosticKind::InvalidStructure
            );
        }
    }

    #[test]
    fn duplicate_members_are_rejected_after_json_escape_decoding() {
        let ordinary =
            minimal_document().replace(r#""owner":"owner""#, r#""owner":"first","owner":"second""#);
        let escaped = minimal_document().replace(
            r#""owner":"owner""#,
            r#""owner":"first","\u006fwner":"second""#,
        );
        let nested = document_with_return_type(
            r#"{"tag":"primitive","\u0074ag":"primitive","name":"Unit"}"#,
        );
        for source in [ordinary, escaped, nested] {
            assert_eq!(error(source).kind, ContractDiagnosticKind::InvalidStructure);
        }
    }

    #[test]
    fn tagged_unit_object_variants_reject_unknown_members() {
        let library_self = minimal_document().replacen(
            r#"{"tag":"self"}"#,
            r#"{"tag":"self","alias":"extra"}"#,
            1,
        );
        let effect_mut = document_with_record(&format!(
            r#"{{"target":{},"set":{{"effect_upper":[{{"future":true,"tag":"mut"}}]}}}}"#,
            declaration_target()
        ));
        let effect_unsafe = document_with_record(&format!(
            r#"{{"target":{},"set":{{"effect_upper":[{{"tag":"unsafe","payload":0}}]}}}}"#,
            declaration_target()
        ));
        let receiver = document_with_record(&format!(
            r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"receiver","index":0}},"type":{{"tag":"primitive","name":"Int"}}}}]}}}}"#,
            declaration_target()
        ));
        let unit_layout = document_with_record(&format!(
            r#"{{"target":{},"check":{{"structure":[{{"tag":"variants","match":"exact","ordered":true,"items":[{{"name":"Only","layout":{{"tag":"unit","elements":[]}}}}]}}]}}}}"#,
            declaration_target()
        ));

        let mut accepted = Vec::new();
        for (label, source) in [
            ("library self", library_self),
            ("mut effect", effect_mut),
            ("unsafe effect", effect_unsafe),
            ("receiver", receiver),
            ("unit variant layout", unit_layout),
        ] {
            match crate::decode_contract(source.as_bytes()) {
                Ok(_) => accepted.push(label),
                Err(diagnostic) => assert_eq!(
                    diagnostic.kind,
                    ContractDiagnosticKind::InvalidStructure,
                    "{label} must reject an unknown object member as structure"
                ),
            }
        }
        assert!(
            accepted.is_empty(),
            "unit object variants accepted unknown members: {accepted:?}"
        );
    }

    #[test]
    fn unknown_fields_tags_and_invalid_self_owners_are_rejected() {
        let unknown_field =
            minimal_document().replace(r#""name":"Unit""#, r#""name":"Unit","future":true"#);
        let unknown_tag = document_with_return_type(r#"{"tag":"future","value":1}"#);
        let missing_element = document_with_return_type(r#"{"tag":"list"}"#);
        let invalid_self_owner = document_with_return_type(
            r#"{"tag":"self_type","owner":{"tag":"declaration","declaration":{"library":{"tag":"self"},"path":["f"],"kind":"function"}}}"#,
        );
        for source in [
            unknown_field,
            unknown_tag,
            missing_element,
            invalid_self_owner,
        ] {
            assert_eq!(error(source).kind, ContractDiagnosticKind::InvalidStructure);
        }
    }

    #[test]
    fn schema_cardinalities_and_identifier_boundaries_are_enforced() {
        let empty_parameter_types = document_with_record(&format!(
            r#"{{"target":{},"set":{{"parameter_types":[]}}}}"#,
            declaration_target()
        ));
        let empty_return_traits = document_with_record(&format!(
            r#"{{"target":{},"check":{{"return_traits":[]}}}}"#,
            declaration_target()
        ));
        let empty_structure = document_with_record(&format!(
            r#"{{"target":{},"check":{{"structure":[]}}}}"#,
            declaration_target()
        ));
        let short_tuple = document_with_return_type(
            r#"{"tag":"tuple","elements":[{"tag":"primitive","name":"Int"}]}"#,
        );
        let empty_export_path = document_with_record(&format!(
            r#"{{"target":{},"check":{{"exports":{{"match":"exact","items":[{{"name":{{"path":[],"namespace":"value"}}}}]}}}}}}"#,
            declaration_target()
        ));
        let short_pattern_tuple = document_with_record(
            r#"{"target":{"tag":"impl","implementation":{"library":{"tag":"self"},"type_parameter_count":0,"target":{"tag":"tuple","elements":[{"tag":"primitive","name":"Int"}]}}},"check":{"visibility":"public"}}"#,
        );
        let empty_owner = minimal_document().replace(r#""owner":"owner""#, r#""owner":"""#);
        let invalid_identifier =
            minimal_document().replace(r#""path":["missing"]"#, r#""path":["not-an-identifier"]"#);

        for source in [
            empty_parameter_types,
            empty_return_traits,
            empty_structure,
            short_tuple,
            empty_export_path,
            short_pattern_tuple,
            empty_owner,
            invalid_identifier,
        ] {
            assert_eq!(error(source).kind, ContractDiagnosticKind::InvalidStructure);
        }
    }

    #[test]
    fn restricted_reference_kinds_do_not_become_early_semantic_lookups() {
        let wrong_function_declaration = document_with_return_type(
            r#"{"tag":"function_item","function":{"tag":"declaration","declaration":{"library":{"tag":"self"},"path":["Data"],"kind":"struct"}},"owner_type_arguments":[],"type_arguments":[],"effect_arguments":[]}"#,
        );
        let wrong_method_kind = document_with_return_type(
            r#"{"tag":"opaque_callable","function":{"tag":"trait_member","owner":{"library":{"tag":"self"},"path":["Trait"],"kind":"trait"},"kind":"associated_type","name":"Item"},"owner_type_arguments":[],"type_arguments":[],"effect_arguments":[]}"#,
        );
        let self_pattern = document_with_record(
            r#"{"target":{"tag":"impl","implementation":{"library":{"tag":"self"},"type_parameter_count":0,"target":{"tag":"self_type","owner":{"tag":"declaration","declaration":{"library":{"tag":"self"},"path":["Data"],"kind":"struct"}}}}},"check":{"visibility":"public"}}"#,
        );
        for source in [wrong_function_declaration, wrong_method_kind, self_pattern] {
            assert_eq!(error(source).kind, ContractDiagnosticKind::InvalidStructure);
        }

        let unresolved_but_structural = document_with_return_type(
            r#"{"tag":"formal","formal":{"owner":{"tag":"declaration","declaration":{"library":{"tag":"dependency","alias":"missing_dep"},"path":["Missing"],"kind":"function"}},"binder":"method","kind":"type","index":18446744073709551615}}"#,
        );
        decode_contract(unresolved_but_structural.as_bytes())
            .expect("the reader transports unresolved owner, binder, and formal facts");
    }

    #[test]
    fn versions_have_separate_stable_diagnostic_categories() {
        let format = minimal_document().replace(r#""format_version":1"#, r#""format_version":2"#);
        let semantics = minimal_document().replace(
            r#""semantics_version":"0.1""#,
            r#""semantics_version":"0.2""#,
        );
        let format_error = error(format);
        assert_eq!(
            format_error.kind,
            ContractDiagnosticKind::UnsupportedFormatVersion
        );
        assert_eq!(format_error.path.as_deref(), Some("$.format_version"));
        let semantics_error = error(semantics);
        assert_eq!(
            semantics_error.kind,
            ContractDiagnosticKind::UnsupportedSemanticsVersion
        );
        assert_eq!(semantics_error.path.as_deref(), Some("$.semantics_version"));
    }

    #[test]
    fn indices_accept_the_full_u64_range_and_reject_non_unsigned_integer_tokens() {
        let indexed_record = |index: &str| {
            document_with_record(&format!(
                r#"{{"target":{},"set":{{"parameter_types":[{{"parameter":{{"tag":"position","index":{index}}},"type":{{"tag":"primitive","name":"Int"}}}}]}}}}"#,
                declaration_target()
            ))
        };
        decode_contract(indexed_record("18446744073709551615").as_bytes())
            .expect("u64::MAX is part of the wire range");
        for token in ["-0", "-1", "1.0", "1e0", "18446744073709551616"] {
            assert_eq!(
                error(indexed_record(token)).kind,
                ContractDiagnosticKind::InvalidStructure,
                "integer token {token} must be rejected as a wire structure error"
            );
        }

        for token in ["-0", "1.0", "1e0", "18446744073709551616"] {
            let source = minimal_document().replace(
                r#""format_version":1"#,
                &format!(r#""format_version":{token}"#),
            );
            assert_eq!(
                error(source).kind,
                ContractDiagnosticKind::InvalidStructure,
                "format_version token {token} must be rejected as a wire structure error"
            );
        }
    }

    #[test]
    fn invalid_utf8_and_non_single_json_documents_report_real_positions() {
        let invalid = b"{\n  \"owner\": \"\xff\"\n}";
        let diagnostic = error(invalid);
        assert_eq!(diagnostic.kind, ContractDiagnosticKind::InvalidEncoding);
        assert_eq!(diagnostic.line, Some(2));
        assert_eq!(diagnostic.byte_offset, Some(14));
        assert!(diagnostic.column.is_some());

        let trailing = format!("{} {{}}", minimal_document());
        let diagnostic = error(trailing);
        assert_eq!(diagnostic.kind, ContractDiagnosticKind::InvalidJson);
        assert!(diagnostic.line.is_some());
        assert!(diagnostic.column.is_some());
        assert!(diagnostic.byte_offset.is_some());

        let comment =
            minimal_document().replace(r#""owner":"owner""#, r#""owner":"owner"/* comment */"#);
        assert_eq!(error(comment).kind, ContractDiagnosticKind::InvalidJson);
    }

    #[test]
    fn serde_container_depth_127_is_accepted_and_128_is_rejected() {
        let nested = |wrappers: usize| {
            let mut value_type = r#"{"tag":"primitive","name":"Int"}"#.to_owned();
            for _ in 0..wrappers {
                value_type = format!(r#"{{"tag":"list","element":{value_type}}}"#);
            }
            document_with_return_type(&value_type)
        };

        let depth_127 = nested(122);
        assert_eq!(max_container_depth(&depth_127), 127);
        decode_contract(depth_127.as_bytes()).expect("container depth 127 is supported");
        let depth_128 = nested(123);
        assert_eq!(max_container_depth(&depth_128), 128);
        let diagnostic = error(depth_128);
        assert_eq!(
            diagnostic.kind,
            ContractDiagnosticKind::NestingLimitExceeded
        );

        let brackets_in_string = minimal_document().replace(
            r#""owner":"owner""#,
            &format!(r#""owner":"{}""#, "[{".repeat(256)),
        );
        decode_contract(brackets_in_string.as_bytes())
            .expect("brackets inside strings do not add container depth");
    }

    #[test]
    fn structural_errors_expose_a_proven_container_path_without_source_origins() {
        let source = document_with_return_type(
            r#"{"tag":"list","element":{"tag":"primitive","name":"Missing"}}"#,
        );
        let diagnostic = error(source);
        assert_eq!(diagnostic.kind, ContractDiagnosticKind::InvalidStructure);
        assert!(
            diagnostic
                .path
                .as_deref()
                .is_some_and(|path| path.contains("records[0].set.return_type"))
        );
        assert!(diagnostic.line.is_some());
        assert!(diagnostic.column.is_some());
        assert!(diagnostic.byte_offset.is_some());
    }
}
