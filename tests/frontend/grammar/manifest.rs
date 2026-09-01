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

const EXPECTED_CASE_IDS: &str = include_str!("expected_case_ids.txt");
#[test]
fn docs_lhs_and_executable_manifest_are_mechanically_closed() {
    let lexical = production_ids("L", include_str!("../../../docs/lang-spec/lexical.md"));
    let syntax = production_ids("S", include_str!("../../../docs/lang-spec/syntax.md"));
    assert_eq!(lexical.len(), 8, "lexical production count");
    assert_eq!(syntax.len(), 106, "syntax production count");

    let documented: BTreeSet<_> = lexical.union(&syntax).cloned().collect();
    let cases = all_case_meta();
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

    let expected_lines: Vec<_> = EXPECTED_CASE_IDS
        .lines()
        .filter(|line| !line.is_empty())
        .collect();
    let expected: BTreeSet<_> = expected_lines.iter().copied().collect();
    assert!(
        expected_lines.windows(2).all(|pair| pair[0] < pair[1]),
        "expected case IDs must stay sorted"
    );
    assert_eq!(
        expected.len(),
        expected_lines.len(),
        "duplicate expected case ID"
    );
    assert_eq!(ids, expected, "expected/executable case-ID drift");

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
