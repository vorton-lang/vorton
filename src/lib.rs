pub mod ast;
pub mod diagnostic;
pub mod lexer;
pub mod parser;
pub mod source;

use diagnostic::Diagnostic;
use lexer::Token;
use parser::ParseOutput;
use source::SourceFile;

pub struct FrontendOutput {
    pub source: SourceFile,
    pub tokens: Vec<Token>,
    pub program: ast::Program,
    pub diagnostics: Vec<Diagnostic>,
}

pub fn parse_source(source: SourceFile) -> FrontendOutput {
    let lexed = lexer::lex(&source);
    let ParseOutput {
        program,
        diagnostics,
    } = parser::parse(&source, &lexed.tokens, lexed.diagnostics);

    FrontendOutput {
        source,
        tokens: lexed.tokens,
        program,
        diagnostics,
    }
}
