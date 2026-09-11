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
pub struct ContractDocument(pub(crate) Document);

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

struct JsonObjectVisitor<T>(std::marker::PhantomData<fn() -> T>);

impl<'de, T> de::Visitor<'de> for JsonObjectVisitor<T>
where
    T: Deserialize<'de>,
{
    type Value = T;

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("a JSON object")
    }

    fn visit_map<A>(self, map: A) -> Result<Self::Value, A::Error>
    where
        A: de::MapAccess<'de>,
    {
        T::deserialize(de::value::MapAccessDeserializer::new(map))
    }
}

fn deserialize_json_object<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    deserializer.deserialize_map(JsonObjectVisitor(std::marker::PhantomData))
}

struct JsonStringVisitor<T>(std::marker::PhantomData<fn() -> T>);

impl<'de, T> de::Visitor<'de> for JsonStringVisitor<T>
where
    T: de::DeserializeOwned,
{
    type Value = T;

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("a JSON string")
    }

    fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        T::deserialize(de::value::StrDeserializer::<E>::new(value))
    }

    fn visit_string<E>(self, value: String) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        T::deserialize(de::value::StringDeserializer::<E>::new(value))
    }
}

fn deserialize_json_string<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: de::DeserializeOwned,
{
    deserializer.deserialize_str(JsonStringVisitor(std::marker::PhantomData))
}

// Serde's derived struct and unit-enum readers accept JSON representations that
// are broader than the published schema. These macros keep each wire shape in
// one declaration while requiring the schema's object and string containers.
macro_rules! json_object {
    (
        struct $name:ident {
            $(
                $(#[$field_attribute:meta])*
                $field:ident: $field_type:ty
            ),* $(,)?
        }
    ) => {
        #[derive(Debug, PartialEq)]
        pub(crate) struct $name {
            $(pub(crate) $field: $field_type),*
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                #[derive(Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Wire {
                    $(
                        $(#[$field_attribute])*
                        $field: $field_type
                    ),*
                }

                let Wire { $($field),* } = deserialize_json_object(deserializer)?;
                Ok(Self { $($field),* })
            }
        }
    };
}

macro_rules! json_string_enum {
    (
        $rename_all:literal;
        enum $name:ident {
            $(
                $(#[$variant_attribute:meta])*
                $variant:ident
            ),* $(,)?
        }
    ) => {
        #[derive(Debug, PartialEq)]
        pub(crate) enum $name {
            $($variant),*
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                #[derive(Deserialize)]
                #[serde(rename_all = $rename_all)]
                enum Wire {
                    $(
                        $(#[$variant_attribute])*
                        $variant
                    ),*
                }

                Ok(match deserialize_json_string(deserializer)? {
                    $(Wire::$variant => Self::$variant),*
                })
            }
        }
    };
}

macro_rules! json_tagged_object_enum {
    (
        enum $name:ident {
            $(
                $(#[$variant_attribute:meta])*
                $variant:ident {
                    $(
                        $(#[$field_attribute:meta])*
                        $field:ident: $field_type:ty
                    ),* $(,)?
                }
            ),* $(,)?
        }
    ) => {
        #[derive(Debug, PartialEq)]
        pub(crate) enum $name {
            $(
                $variant {
                    $($field: $field_type),*
                }
            ),*
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                #[derive(Deserialize)]
                #[serde(tag = "tag", rename_all = "snake_case", deny_unknown_fields)]
                enum Wire {
                    $(
                        $(#[$variant_attribute])*
                        $variant {
                            $(
                                $(#[$field_attribute])*
                                $field: $field_type
                            ),*
                        }
                    ),*
                }

                Ok(match deserialize_json_object(deserializer)? {
                    $(
                        Wire::$variant { $($field),* } => Self::$variant { $($field),* }
                    ),*
                })
            }
        }
    };
}

#[derive(Debug, PartialEq, Deserialize)]
pub(crate) struct WireU64(pub(crate) u64);

#[derive(Debug, PartialEq)]
pub(crate) struct NonEmptyVec<T>(pub(crate) Vec<T>);

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
pub(crate) struct TupleElements<T>(pub(crate) Vec<T>);

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
pub(crate) struct Identifier(pub(crate) String);

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

json_object! {
    struct Document {
        format: String,
        format_version: WireU64,
        semantics_version: String,
        owner: String,
        records: Vec<Record>,
        #[serde(default, deserialize_with = "deserialize_optional")]
        display: Option<DisplayFields>,
    }
}

json_object! {
    struct DisplayFields {
        #[serde(default, deserialize_with = "deserialize_optional")]
        label: Option<String>,
        #[serde(default, deserialize_with = "deserialize_optional")]
        note: Option<String>,
    }
}

json_tagged_object_enum! {
    enum LibraryRef {
        #[serde(rename = "self")]
        Current {},
        Dependency {
            alias: Identifier,
        },
    }
}

json_string_enum! {
    "snake_case";
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
}

json_object! {
    struct DeclRef {
        library: LibraryRef,
        path: Vec<Identifier>,
        kind: DeclarationKind,
    }
}

json_string_enum! {
    "snake_case";
    enum TraitKind {
        Trait,
    }
}

json_object! {
    struct TraitRef {
        library: LibraryRef,
        path: Vec<Identifier>,
        kind: TraitKind,
    }
}

json_string_enum! {
    "snake_case";
    enum FunctionKind {
        Function,
    }
}

json_object! {
    struct FunctionDeclRef {
        library: LibraryRef,
        path: Vec<Identifier>,
        kind: FunctionKind,
    }
}

json_string_enum! {
    "snake_case";
    enum EffectKind {
        Effect,
    }
}

json_object! {
    struct EffectDeclRef {
        library: LibraryRef,
        path: Vec<Identifier>,
        kind: EffectKind,
    }
}

json_string_enum! {
    "snake_case";
    enum SelfDeclarationKind {
        Struct,
        Enum,
        Trait,
    }
}

json_object! {
    struct SelfDeclRef {
        library: LibraryRef,
        path: Vec<Identifier>,
        kind: SelfDeclarationKind,
    }
}

json_string_enum! {
    "snake_case";
    enum MemberKind {
        Method,
        AssociatedType,
    }
}

json_string_enum! {
    "snake_case";
    enum MethodKind {
        Method,
    }
}

json_object! {
    struct PatternTrait {
        #[serde(rename = "trait")]
        trait_ref: TraitRef,
        arguments: Vec<TypePattern>,
        associated_bindings: Vec<PatternAssociatedBinding>,
    }
}

json_object! {
    struct PatternAssociatedBinding {
        name: Identifier,
        #[serde(rename = "type")]
        value_type: TypePattern,
    }
}

json_tagged_object_enum! {
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
}

json_string_enum! {
    "PascalCase";
    enum PrimitiveType {
        Int,
        Float,
        Str,
        Bool,
        Unit,
        Never,
    }
}

json_object! {
    struct ImplRef {
        library: LibraryRef,
        type_parameter_count: WireU64,
        target: TypePattern,
        #[serde(default, deserialize_with = "deserialize_optional")]
        #[serde(rename = "trait")]
        trait_ref: Option<PatternTrait>,
    }
}

json_tagged_object_enum! {
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
}

json_tagged_object_enum! {
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
}

json_string_enum! {
    "snake_case";
    enum Binder {
        Declaration,
        Impl,
        Method,
    }
}

json_string_enum! {
    "snake_case";
    enum TypeFormalKind {
        Type,
    }
}

json_object! {
    struct TypeFormalRef {
        owner: EntityRef,
        binder: Binder,
        kind: TypeFormalKind,
        index: WireU64,
    }
}

json_string_enum! {
    "snake_case";
    enum EffectFormalKind {
        Effect,
    }
}

json_object! {
    struct EffectFormalRef {
        owner: EntityRef,
        binder: Binder,
        kind: EffectFormalKind,
        index: WireU64,
    }
}

json_object! {
    struct TraitUse {
        #[serde(rename = "trait")]
        trait_ref: TraitRef,
        arguments: Vec<Type>,
        associated_bindings: Vec<AssociatedBinding>,
    }
}

json_object! {
    struct AssociatedBinding {
        name: Identifier,
        #[serde(rename = "type")]
        value_type: Type,
    }
}

json_tagged_object_enum! {
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
}

json_tagged_object_enum! {
enum SelfOwner {
    Declaration { declaration: SelfDeclRef },
    Impl { implementation: ImplRef },
}
}

json_string_enum! {
    "snake_case";
    enum Mode {
        Borrow,
        Mut,
        Move,
    }
}

json_tagged_object_enum! {
enum ModeRule {
    Fixed { mode: Mode },
    CallableUse { callable: Box<Type> },
}
}

json_string_enum! {
    "snake_case";
    enum EscapeRule {
        Noescape,
        MayEscape,
    }
}

type EffectRow = Vec<EffectTerm>;

json_string_enum! {
    "snake_case";
    enum SystemEffect {
        Console,
        Fs,
        Process,
    }
}

json_tagged_object_enum! {
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
}

json_object! {
    struct TraitMethodRef {
        tag: TraitMemberTag,
        owner: TraitRef,
        kind: MethodKind,
        name: Identifier,
    }
}

json_string_enum! {
    "snake_case";
    enum TraitMemberTag {
        TraitMember,
    }
}

json_tagged_object_enum! {
enum ParameterRef {
    Receiver {},
    Position { index: WireU64 },
}
}

json_object! {
    struct PatternPredicate {
        subject: TypePattern,
        requires: PatternTrait,
    }
}

json_object! {
    struct ParameterTypeSet {
        parameter: ParameterRef,
        #[serde(rename = "type")]
        value_type: Type,
    }
}

json_object! {
    struct ParameterModeSet {
        parameter: ParameterRef,
        mode: ModeRule,
    }
}

json_object! {
    struct ParameterEscapeSet {
        parameter: ParameterRef,
        escape: EscapeRule,
    }
}

json_object! {
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

json_string_enum! {
    "snake_case";
    enum Visibility {
        Public,
        Private,
    }
}

json_object! {
    struct FieldRequirement {
        name: Identifier,
        #[serde(default, deserialize_with = "deserialize_optional")]
        #[serde(rename = "type")]
        value_type: Option<Type>,
        #[serde(default, deserialize_with = "deserialize_optional")]
        visibility: Option<Visibility>,
    }
}

json_object! {
    struct ParameterRequirement {
        parameter: ParameterRef,
        #[serde(default, deserialize_with = "deserialize_optional")]
        #[serde(rename = "type")]
        value_type: Option<Type>,
    }
}

json_string_enum! {
    "snake_case";
    enum MatchRule {
        Exact,
        Contains,
    }
}

json_tagged_object_enum! {
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
}

json_object! {
    struct VariantRequirement {
        name: Identifier,
        #[serde(default, deserialize_with = "deserialize_optional")]
        layout: Option<VariantLayout>,
    }
}

json_object! {
    struct MemberRequirement {
        name: Identifier,
        kind: MemberKind,
    }
}

json_tagged_object_enum! {
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
}

json_string_enum! {
    "snake_case";
    enum Namespace {
        Type,
        Value,
        Effect,
    }
}

json_object! {
    struct ExportName {
        path: NonEmptyVec<Identifier>,
        namespace: Namespace,
    }
}

json_object! {
    struct ExportRequirement {
        name: ExportName,
        #[serde(default, deserialize_with = "deserialize_optional")]
        target: Option<EntityRef>,
    }
}

json_object! {
    struct ExportsCheck {
        #[serde(rename = "match")]
        match_rule: MatchRule,
        items: Vec<ExportRequirement>,
    }
}

json_object! {
    struct ImplAllowance {
        implementation: ImplRef,
        predicates: Vec<PatternPredicate>,
    }
}

json_object! {
    struct RejectNewCheck {
        allowed_exports: Vec<ExportName>,
        allowed_impls: Vec<ImplAllowance>,
    }
}

json_object! {
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

json_object! {
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
}

json_object! {
    struct ShapeParameter {
        #[serde(rename = "type")]
        value_type: Type,
        mode: ModeRule,
        escape: EscapeRule,
    }
}

json_object! {
    struct CallableShapeConstraint {
        parameters: Vec<ShapeParameter>,
        result: Type,
        #[serde(default, deserialize_with = "deserialize_optional")]
        effect_upper: Option<EffectRow>,
    }
}

json_tagged_object_enum! {
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
    fn schema_objects_and_string_enums_reject_alternative_serde_representations() {
        let root_sequence = r#"["vorton.contract",1,"0.1","app",[]]"#.to_owned();
        let declaration_sequence = minimal_document().replace(
            r#"{"library":{"tag":"self"},"path":["missing"],"kind":"function"}"#,
            r#"[{"tag":"self"},["missing"],"function"]"#,
        );
        let display_sequence =
            minimal_document().replace(r#""records":"#, r#""display":["label","note"],"records":"#);
        let declaration_kind_object =
            minimal_document().replace(r#""kind":"function""#, r#""kind":{"function":null}"#);
        let visibility_object = document_with_record(&format!(
            r#"{{"target":{},"check":{{"visibility":{{"public":null}}}}}}"#,
            declaration_target()
        ));
        let primitive_name_object =
            document_with_return_type(r#"{"tag":"primitive","name":{"Int":null}}"#);

        let escaped_enum =
            minimal_document().replace(r#""kind":"function""#, r#""kind":"funct\u0069on""#);
        decode_contract(escaped_enum.as_bytes())
            .expect("JSON escapes preserve the decoded string enum value");

        for (label, source) in [
            ("root document", root_sequence),
            ("declaration reference", declaration_sequence),
            ("display", display_sequence),
            ("declaration kind", declaration_kind_object),
            ("visibility", visibility_object),
            ("primitive type name", primitive_name_object),
        ] {
            assert_eq!(
                error(source).kind,
                ContractDiagnosticKind::InvalidStructure,
                "{label} must use the JSON representation published by the schema"
            );
        }
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
