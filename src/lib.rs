pub mod ast;
pub mod diagnostic;
pub mod lexer;
pub mod parser;
pub mod source;

use diagnostic::Diagnostic;
use lexer::Token;
use source::SourceFile;

pub struct FrontendOutput {
    pub source: SourceFile,
    pub tokens: Vec<Token>,
    pub syntax: Result<ast::Program, Vec<Diagnostic>>,
}

pub fn parse_source(source: SourceFile) -> FrontendOutput {
    let mut lexed = lexer::lex(&source);
    let syntax = if lexed.diagnostics.is_empty() {
        parser::parse(&source, &lexed.tokens)
    } else {
        diagnostic::sort_diagnostics(&mut lexed.diagnostics);
        Err(lexed.diagnostics)
    };

    FrontendOutput {
        source,
        tokens: lexed.tokens,
        syntax,
    }
}
