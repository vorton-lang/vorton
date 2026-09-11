# Vorton contract format 1

`vorton_compiler::decode_contract(&[u8])` reads one in-memory contract document and returns an owned, opaque `ContractDocument`. Successful decoding means that the bytes satisfy the supported UTF-8 JSON profile, version fields, and complete record structure. It does not bind an owner or reference to a source library, apply `set`, run `check`, validate declaration or formal existence, or establish an effective signature.

The complete structural definition is [`contract-format-1.schema.json`](contract-format-1.schema.json). A document has `format: "vorton.contract"`, `format_version: 1`, `semantics_version: "0.1"`, a non-empty host-selected `owner` label, an ordered `records` array, and optional display text. Records preserve every selected `set` and `check` clause, target and formal reference, parameter position, type parameter name, array order, and the distinction between an omitted optional field and an explicit empty array.

The decoder applies these additional wire rules that JSON Schema alone does not express:

- Every object rejects duplicate members after JSON string escapes are decoded, as well as unknown members and tags. Explicit `null` is not valid for any optional field.
- Indices, `type_parameter_count`, and `format_version` use the full `u64` range and require unsigned decimal JSON integer tokens. Negative signs, fractional syntax, exponent syntax, and values beyond `18446744073709551615` are rejected.
- The root container has depth 1. Container depth through 127 is supported; reaching depth 128 is rejected by the fixed reader profile. Brackets inside strings do not affect depth.
- Exactly one JSON document plus trailing JSON whitespace is accepted. Comments, a second document, invalid UTF-8, and other relaxed JSON forms are rejected.

`ContractDiagnostic` reports a stable `ContractDiagnosticKind`, readable message, and the nearest JSON path and input position that the decoder can prove. Position fields are optional because version and cross-field structure checks do not always retain a parser location. Contract diagnostics do not contain Vorton `LibraryId`, `SourceRef`, or a fabricated source origin; the caller owns the association between an error and the supplied byte document.
