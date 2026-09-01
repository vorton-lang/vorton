use std::collections::{BTreeMap, BTreeSet};

use vorton::ast::Program;
use vorton::source::{SourceFile, SourceId};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Polarity {
    Valid,
    Invalid,
    Context,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct CaseMeta {
    pub(crate) id: &'static str,
    pub(crate) production: Option<&'static str>,
    pub(crate) polarity: Polarity,
}

pub(crate) enum SyntaxExpectation {
    Valid(fn(&Program)),
    Invalid {
        code: &'static str,
        found: &'static str,
    },
}

pub(crate) struct SyntaxCase {
    pub(crate) id: &'static str,
    pub(crate) production: Option<&'static str>,
    pub(crate) source: &'static str,
    pub(crate) expectation: SyntaxExpectation,
}

impl SyntaxCase {
    pub(crate) const fn valid(
        id: &'static str,
        production: &'static str,
        source: &'static str,
        assertion: fn(&Program),
    ) -> Self {
        Self {
            id,
            production: Some(production),
            source,
            expectation: SyntaxExpectation::Valid(assertion),
        }
    }

    pub(crate) const fn invalid(
        id: &'static str,
        production: &'static str,
        source: &'static str,
        code: &'static str,
        found: &'static str,
    ) -> Self {
        Self {
            id,
            production: Some(production),
            source,
            expectation: SyntaxExpectation::Invalid { code, found },
        }
    }

    pub(crate) const fn context_valid(
        id: &'static str,
        source: &'static str,
        assertion: fn(&Program),
    ) -> Self {
        Self {
            id,
            production: None,
            source,
            expectation: SyntaxExpectation::Valid(assertion),
        }
    }

    pub(crate) const fn context_invalid(
        id: &'static str,
        source: &'static str,
        code: &'static str,
        found: &'static str,
    ) -> Self {
        Self {
            id,
            production: None,
            source,
            expectation: SyntaxExpectation::Invalid { code, found },
        }
    }

    pub(crate) fn meta(&self) -> CaseMeta {
        let polarity = match self.expectation {
            SyntaxExpectation::Valid(_) if self.production.is_some() => Polarity::Valid,
            SyntaxExpectation::Invalid { .. } if self.production.is_some() => Polarity::Invalid,
            SyntaxExpectation::Valid(_) | SyntaxExpectation::Invalid { .. } => Polarity::Context,
        };
        CaseMeta {
            id: self.id,
            production: self.production,
            polarity,
        }
    }
}

pub(crate) fn run_syntax_cases(cases: &[SyntaxCase]) {
    let mut failures = Vec::new();
    for (index, case) in cases.iter().enumerate() {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            run_syntax_case(case, index)
        }));
        if result.is_err() {
            failures.push(case.id);
        }
    }
    assert!(
        failures.is_empty(),
        "grammar conformance RED cases:\n{}",
        failures.join("\n")
    );
}

fn run_syntax_case(case: &SyntaxCase, index: usize) {
    let source = SourceFile::new(
        SourceId(u32::try_from(index + 100).expect("case index")),
        format!("{}.vorton", case.id),
        case.source,
    )
    .expect("valid conformance source");
    let output = vorton::parse_source(source);
    match (&case.expectation, output.syntax) {
        (SyntaxExpectation::Valid(assertion), Ok(program)) => assertion(&program),
        (SyntaxExpectation::Valid(_), Err(diagnostics)) => {
            panic!("{} expected Ok(Program), got {diagnostics:#?}", case.id)
        }
        (SyntaxExpectation::Invalid { .. }, Ok(program)) => {
            panic!("{} expected fail-closed Err, got {program:#?}", case.id)
        }
        (SyntaxExpectation::Invalid { code, found }, Err(diagnostics)) => {
            assert_eq!(diagnostics.len(), 1, "{} diagnostics", case.id);
            let diagnostic = &diagnostics[0];
            assert_eq!(&diagnostic.code, code, "{} code", case.id);
            let actual =
                &output.source.text()[diagnostic.span.start as usize..diagnostic.span.end as usize];
            assert_eq!(actual, *found, "{} source slice", case.id);
        }
    }
}

fn production_ids(prefix: &str, document: &str) -> BTreeSet<String> {
    let mut in_ebnf = false;
    let mut ids = BTreeSet::new();
    for line in document.lines() {
        if line.trim() == "```ebnf" {
            in_ebnf = true;
            continue;
        }
        if in_ebnf && line.trim() == "```" {
            in_ebnf = false;
            continue;
        }
        if !in_ebnf {
            continue;
        }
        let Some((lhs, _)) = line.split_once("::=") else {
            continue;
        };
        let lhs = lhs.trim();
        assert!(
            !lhs.is_empty() && lhs.chars().all(|value| value.is_ascii_alphanumeric()),
            "invalid EBNF LHS {lhs:?}"
        );
        assert!(
            ids.insert(format!("{prefix}.{lhs}")),
            "duplicate EBNF LHS {prefix}.{lhs}"
        );
    }
    ids
}

fn all_case_meta() -> Vec<CaseMeta> {
    let mut cases = crate::grammar::lexical::case_meta();
    for syntax_cases in [
        crate::grammar::declarations::cases(),
        crate::grammar::types::cases(),
        crate::grammar::statements::cases(),
        crate::grammar::expressions::cases(),
        crate::grammar::patterns::cases(),
        crate::grammar::context::cases(),
        crate::grammar::precedence::cases(),
    ] {
        cases.extend(syntax_cases.iter().map(SyntaxCase::meta));
    }
    cases
}

const REQUIRED_CASE_IDS: &[&str] = &[
    "V.S.DeclKind.all-alternatives",
    "V.S.VariantFields.positional-and-named",
    "V.S.ImplDecl.inherent-and-trait",
    "V.S.InherentImplMember.fn-and-type",
    "V.S.TraitMember.all-alternatives",
    "V.S.TypeExpr.all-alternatives",
    "V.S.EffectName.all-alternatives",
    "V.S.Stmt.all-alternatives",
    "V.S.AssignStmt.all-operators",
    "V.S.PrimaryExpr.all-alternatives",
    "V.S.Pattern.all-single-alternatives",
    "V.S.EffectSet.many-trailing",
    "I.S.EffectSet.missing-comma",
    "V.S.Params.many-trailing",
    "I.S.Params.missing-comma",
    "V.S.TypeParams.many-trailing",
    "I.S.TypeParams.empty",
    "V.S.TypeBound.mixed-trailing",
    "I.S.TypeBound.empty-angles",
    "V.S.TypeArgs.nested-trailing",
    "I.S.TypeArgs.missing-comma",
    "V.S.ForBinding.tuple-trailing",
    "I.S.ForBinding.tuple-one",
    "V.S.NamedLiteralBody.spread-and-fields",
    "I.S.NamedLiteralBody.missing-comma-after-spread",
    "V.S.ListLit.many-trailing",
    "I.S.ListLit.leading-comma",
    "V.S.TupleOrParen.tuple-trailing",
    "I.S.TupleOrParen.single-tuple",
    "V.S.HandleExpr.many-trailing",
    "I.S.HandleExpr.empty",
    "V.S.PatList.many-trailing",
    "I.S.PatList.missing-comma",
    "V.S.NamedPatGroup.fields-rest-trailing",
    "I.S.NamedPatGroup.rest-first-with-fields",
    "I.S.BreakStmt.expression-after-break",
    "I.S.ContinueStmt.expression-after-continue",
    "V.S.ReturnStmt.bare-before-let",
    "I.S.Block.extra-token-after-tail",
    "C.expr.precedence.postfix-over-unary",
    "C.expr.precedence.unary-over-mul",
    "C.expr.precedence.mul-over-add",
    "C.expr.precedence.add-over-range",
    "C.expr.precedence.range-over-compare",
    "C.expr.precedence.compare-over-equality",
    "C.expr.precedence.equality-over-and",
    "C.expr.precedence.and-over-or",
    "C.expr.precedence.or-over-catch",
    "C.expr.nonassoc.equality-chain-rejected",
    "C.expr.nonassoc.compare-chain-rejected",
    "C.expr.call.same-line",
    "C.expr.call.next-line-not-call",
    "C.expr.method-call.same-line",
    "C.expr.method-call.next-line-is-field-then-paren",
    "C.context.self-colon-colon-rejected",
    "C.path.lowercase-named-literal",
    "C.path.lowercase-positional-constructor",
    "C.path.lowercase-constructor-pattern",
    "C.return.bare-before-statement-token",
];

#[test]
fn docs_lhs_and_executable_manifest_are_mechanically_closed() {
    let lexical = production_ids("L", include_str!("../../../docs/lang-spec/lexical.md"));
    let syntax = production_ids("S", include_str!("../../../docs/lang-spec/syntax.md"));
    assert_eq!(lexical.len(), 8, "lexical production count");
    assert_eq!(syntax.len(), 104, "syntax production count");

    let documented: BTreeSet<_> = lexical.union(&syntax).cloned().collect();
    let cases = all_case_meta();
    assert_eq!(cases.len(), 326, "executable case count");
    let mut ids = BTreeSet::new();
    let mut coverage: BTreeMap<&str, (bool, bool)> = BTreeMap::new();
    for case in &cases {
        assert!(ids.insert(case.id), "duplicate case ID {}", case.id);
        match (case.production, case.polarity) {
            (Some(production), Polarity::Valid) => {
                assert!(
                    case.id.starts_with(&format!("V.{production}.")),
                    "{} must use V.<PID>.<slug>",
                    case.id
                );
                coverage.entry(production).or_default().0 = true;
            }
            (Some(production), Polarity::Invalid) => {
                assert!(
                    case.id.starts_with(&format!("I.{production}.")),
                    "{} must use I.<PID>.<slug>",
                    case.id
                );
                coverage.entry(production).or_default().1 = true;
            }
            (None, Polarity::Context) => {
                assert!(case.id.starts_with("C."), "context ID {}", case.id);
            }
            _ => panic!("invalid manifest polarity for {}", case.id),
        }
    }

    for required in REQUIRED_CASE_IDS {
        assert!(ids.contains(required), "missing required case {required}");
    }

    let registered: BTreeSet<_> = coverage.keys().map(|value| (*value).to_owned()).collect();
    assert_eq!(registered, documented, "manifest/document production drift");
    for (production, (valid, invalid)) in coverage {
        assert!(valid, "{production} has no executable valid case");
        assert!(
            invalid,
            "{production} has no executable boundary-invalid case"
        );
    }
}
