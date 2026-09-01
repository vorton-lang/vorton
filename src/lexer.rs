use serde::Serialize;

use crate::diagnostic::{Diagnostic, push_diagnostic};
use crate::source::{SourceFile, Span};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
pub enum TokenKind {
    Fn,
    Let,
    Mut,
    Const,
    Struct,
    Enum,
    Match,
    Impl,
    Effect,
    Handle,
    With,
    If,
    Else,
    Catch,
    Test,
    Return,
    For,
    In,
    Pub,
    Where,
    True,
    False,
    Trait,
    Try,
    While,
    Break,
    Continue,
    Loop,
    Use,
    As,
    Extern,
    Mod,
    Super,
    Requires,
    Unsafe,
    Integer,
    Float,
    String,
    RawString,
    InterpolationStart,
    InterpolationMiddle,
    InterpolationEnd,
    Identifier,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    EqualEqual,
    BangEqual,
    Less,
    Greater,
    LessEqual,
    GreaterEqual,
    AmpAmp,
    PipePipe,
    Pipe,
    Bang,
    Equal,
    PlusEqual,
    MinusEqual,
    StarEqual,
    SlashEqual,
    PercentEqual,
    LeftParen,
    RightParen,
    LeftBrace,
    RightBrace,
    LeftBracket,
    RightBracket,
    Comma,
    Colon,
    ColonColon,
    Dot,
    DotDot,
    DotDotEqual,
    FatArrow,
    Arrow,
    Question,
    At,
    Semicolon,
    Error,
    Eof,
}

impl TokenKind {
    pub fn spelling(self) -> &'static str {
        match self {
            Self::Fn => "fn",
            Self::Let => "let",
            Self::Mut => "mut",
            Self::Const => "const",
            Self::Struct => "struct",
            Self::Enum => "enum",
            Self::Match => "match",
            Self::Impl => "impl",
            Self::Effect => "effect",
            Self::Handle => "handle",
            Self::With => "with",
            Self::If => "if",
            Self::Else => "else",
            Self::Catch => "catch",
            Self::Test => "test",
            Self::Return => "return",
            Self::For => "for",
            Self::In => "in",
            Self::Pub => "pub",
            Self::Where => "where",
            Self::True => "true",
            Self::False => "false",
            Self::Trait => "trait",
            Self::Try => "try",
            Self::While => "while",
            Self::Break => "break",
            Self::Continue => "continue",
            Self::Loop => "loop",
            Self::Use => "use",
            Self::As => "as",
            Self::Extern => "extern",
            Self::Mod => "mod",
            Self::Super => "super",
            Self::Requires => "requires",
            Self::Unsafe => "unsafe",
            Self::Integer => "integer literal",
            Self::Float => "float literal",
            Self::String => "string literal",
            Self::RawString => "raw string literal",
            Self::InterpolationStart => "string interpolation start",
            Self::InterpolationMiddle => "string interpolation middle",
            Self::InterpolationEnd => "string interpolation end",
            Self::Identifier => "identifier",
            Self::Plus => "+",
            Self::Minus => "-",
            Self::Star => "*",
            Self::Slash => "/",
            Self::Percent => "%",
            Self::EqualEqual => "==",
            Self::BangEqual => "!=",
            Self::Less => "<",
            Self::Greater => ">",
            Self::LessEqual => "<=",
            Self::GreaterEqual => ">=",
            Self::AmpAmp => "&&",
            Self::PipePipe => "||",
            Self::Pipe => "|",
            Self::Bang => "!",
            Self::Equal => "=",
            Self::PlusEqual => "+=",
            Self::MinusEqual => "-=",
            Self::StarEqual => "*=",
            Self::SlashEqual => "/=",
            Self::PercentEqual => "%=",
            Self::LeftParen => "(",
            Self::RightParen => ")",
            Self::LeftBrace => "{",
            Self::RightBrace => "}",
            Self::LeftBracket => "[",
            Self::RightBracket => "]",
            Self::Comma => ",",
            Self::Colon => ":",
            Self::ColonColon => "::",
            Self::Dot => ".",
            Self::DotDot => "..",
            Self::DotDotEqual => "..=",
            Self::FatArrow => "=>",
            Self::Arrow => "->",
            Self::Question => "?",
            Self::At => "@",
            Self::Semicolon => ";",
            Self::Error => "invalid token",
            Self::Eof => "end of file",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Token {
    pub kind: TokenKind,
    pub value: String,
    pub span: Span,
}

pub struct LexOutput {
    pub tokens: Vec<Token>,
    pub diagnostics: Vec<Diagnostic>,
}

#[derive(Clone, Copy)]
struct InterpolationFrame {
    // A `}` resumes the surrounding string only when all braces opened by
    // the interpolation expression have closed. Nested strings push their
    // own frame, so quote/braces inside them cannot close the outer frame.
    brace_depth: u32,
    opening_span: Span,
}

pub fn lex(source: &SourceFile) -> LexOutput {
    Lexer::new(source).tokenize()
}

struct Lexer<'a> {
    source: &'a SourceFile,
    position: usize,
    diagnostics: Vec<Diagnostic>,
    interpolation: Vec<InterpolationFrame>,
}

impl<'a> Lexer<'a> {
    fn new(source: &'a SourceFile) -> Self {
        Self {
            source,
            position: 0,
            diagnostics: Vec::new(),
            interpolation: Vec::new(),
        }
    }

    fn tokenize(mut self) -> LexOutput {
        let mut tokens = Vec::new();
        loop {
            let token = self.next_token();
            let at_end = token.kind == TokenKind::Eof;
            tokens.push(token);
            if at_end {
                break;
            }
        }
        LexOutput {
            tokens,
            diagnostics: self.diagnostics,
        }
    }

    fn next_token(&mut self) -> Token {
        self.skip_trivia();
        if self.position >= self.source.len() {
            if let Some(frame) = self.interpolation.last().copied() {
                self.report(Diagnostic::parse(
                    "E0102",
                    "Unterminated string interpolation: expected '}'",
                    frame.opening_span,
                    "${",
                ));
                self.interpolation.clear();
            }
            return self.token(TokenKind::Eof, String::new(), self.position, self.position);
        }

        if self
            .interpolation
            .last()
            .is_some_and(|frame| frame.brace_depth == 0)
            && self.peek_char() == Some('}')
        {
            self.advance_char();
            return self.lex_string_body(self.position, false);
        }

        let start = self.position;
        let current = self.peek_char().expect("position is in bounds");
        if current == 'r' && self.raw_string_prefix() {
            return self.lex_raw_string(start);
        }
        if current == '"' {
            self.advance_char();
            return self.lex_string_body(start, true);
        }
        if current.is_ascii_digit() {
            return self.lex_number(start);
        }
        if is_identifier_start(current) {
            return self.lex_identifier(start);
        }
        self.lex_punctuation(start)
    }

    fn lex_number(&mut self, start: usize) -> Token {
        while self.peek_char().is_some_and(|value| value.is_ascii_digit()) {
            self.advance_char();
        }
        let mut kind = TokenKind::Integer;
        if self.peek_char() == Some('.')
            && self
                .peek_nth_char(1)
                .is_some_and(|value| value.is_ascii_digit())
        {
            kind = TokenKind::Float;
            self.advance_char();
            while self.peek_char().is_some_and(|value| value.is_ascii_digit()) {
                self.advance_char();
            }
        }
        self.source_token(kind, start, self.position)
    }

    fn lex_identifier(&mut self, start: usize) -> Token {
        while self.peek_char().is_some_and(is_identifier_continue) {
            self.advance_char();
        }
        let value = &self.source.text()[start..self.position];
        let kind = keyword(value).unwrap_or(TokenKind::Identifier);
        self.token(kind, value.to_owned(), start, self.position)
    }

    fn lex_string_body(&mut self, start: usize, first_segment: bool) -> Token {
        let mut value = String::new();
        while let Some(current) = self.peek_char() {
            if current == '"' {
                self.advance_char();
                if first_segment {
                    return self.token(TokenKind::String, value, start, self.position);
                }
                self.interpolation.pop();
                return self.token(TokenKind::InterpolationEnd, value, start, self.position);
            }
            if current == '$' && self.peek_nth_char(1) == Some('{') {
                let opening = self.position;
                self.advance_char();
                self.advance_char();
                let opening_span = self.source.span(opening, self.position);
                if first_segment {
                    self.interpolation.push(InterpolationFrame {
                        brace_depth: 0,
                        opening_span,
                    });
                    return self.token(TokenKind::InterpolationStart, value, start, self.position);
                }
                if let Some(frame) = self.interpolation.last_mut() {
                    *frame = InterpolationFrame {
                        brace_depth: 0,
                        opening_span,
                    };
                }
                return self.token(TokenKind::InterpolationMiddle, value, start, self.position);
            }
            if current == '\\' {
                let escape_start = self.position;
                self.advance_char();
                let Some(escaped) = self.peek_char() else {
                    value.push('\\');
                    break;
                };
                self.advance_char();
                match escaped {
                    '\\' => value.push('\\'),
                    '"' => value.push('"'),
                    'n' => value.push('\n'),
                    't' => value.push('\t'),
                    'r' => value.push('\r'),
                    '0' => value.push('\0'),
                    '$' => value.push('$'),
                    other => {
                        self.report(
                            Diagnostic::parse(
                                "E0101",
                                format!("Unknown string escape '\\{other}'"),
                                self.source.span(escape_start, self.position),
                                format!("\\{other}"),
                            )
                            .with_suggestion(r#"Use one of \\, \", \n, \t, \r, \0, or \$"#, None),
                        );
                        value.push(other);
                    }
                }
                continue;
            }
            if current != '\r' || self.peek_nth_char(1) != Some('\n') {
                value.push(current);
            }
            self.advance_char();
        }

        if !first_segment {
            self.interpolation.pop();
        }
        let span = self.source.span(start, self.position);
        self.report(Diagnostic::parse(
            "E0102",
            "Unterminated string literal",
            span,
            value.clone(),
        ));
        self.token(TokenKind::Error, value, start, self.position)
    }

    fn raw_string_prefix(&self) -> bool {
        self.peek_nth_char(1) == Some('"')
            || (self.peek_nth_char(1) == Some('#') && self.peek_nth_char(2) == Some('"'))
    }

    fn lex_raw_string(&mut self, start: usize) -> Token {
        self.advance_char();
        let hashed = self.peek_char() == Some('#');
        if hashed {
            self.advance_char();
        }
        self.advance_char();
        let mut value = String::new();
        while let Some(current) = self.peek_char() {
            if current == '"' && (!hashed || self.peek_nth_char(1) == Some('#')) {
                self.advance_char();
                if hashed {
                    self.advance_char();
                }
                return self.token(TokenKind::RawString, value, start, self.position);
            }
            if current != '\r' || self.peek_nth_char(1) != Some('\n') {
                value.push(current);
            }
            self.advance_char();
        }

        let span = self.source.span(start, self.position);
        self.report(Diagnostic::parse(
            "E0102",
            "Unterminated raw string literal",
            span,
            value.clone(),
        ));
        self.token(TokenKind::Error, value, start, self.position)
    }

    fn lex_punctuation(&mut self, start: usize) -> Token {
        let current = self.advance_char().expect("position is in bounds");
        let pair = self.peek_char();
        let (kind, consume_pair) = match current {
            '(' => (TokenKind::LeftParen, false),
            ')' => (TokenKind::RightParen, false),
            '{' => {
                if let Some(frame) = self.interpolation.last_mut() {
                    frame.brace_depth += 1;
                }
                (TokenKind::LeftBrace, false)
            }
            '}' => {
                if let Some(frame) = self.interpolation.last_mut() {
                    frame.brace_depth = frame.brace_depth.saturating_sub(1);
                }
                (TokenKind::RightBrace, false)
            }
            '[' => (TokenKind::LeftBracket, false),
            ']' => (TokenKind::RightBracket, false),
            ',' => (TokenKind::Comma, false),
            ';' => (TokenKind::Semicolon, false),
            '?' => (TokenKind::Question, false),
            '@' => (TokenKind::At, false),
            ':' if pair == Some(':') => (TokenKind::ColonColon, true),
            ':' => (TokenKind::Colon, false),
            '.' if pair == Some('.') => {
                self.advance_char();
                if self.peek_char() == Some('=') {
                    (TokenKind::DotDotEqual, true)
                } else {
                    return self.source_token(TokenKind::DotDot, start, self.position);
                }
            }
            '.' => (TokenKind::Dot, false),
            '+' if pair == Some('=') => (TokenKind::PlusEqual, true),
            '+' => (TokenKind::Plus, false),
            '-' if pair == Some('>') => (TokenKind::Arrow, true),
            '-' if pair == Some('=') => (TokenKind::MinusEqual, true),
            '-' => (TokenKind::Minus, false),
            '*' if pair == Some('=') => (TokenKind::StarEqual, true),
            '*' => (TokenKind::Star, false),
            '/' if pair == Some('=') => (TokenKind::SlashEqual, true),
            '/' => (TokenKind::Slash, false),
            '%' if pair == Some('=') => (TokenKind::PercentEqual, true),
            '%' => (TokenKind::Percent, false),
            '=' if pair == Some('=') => (TokenKind::EqualEqual, true),
            '=' if pair == Some('>') => (TokenKind::FatArrow, true),
            '=' => (TokenKind::Equal, false),
            '!' if pair == Some('=') => (TokenKind::BangEqual, true),
            '!' => (TokenKind::Bang, false),
            '<' if pair == Some('=') => (TokenKind::LessEqual, true),
            '<' => (TokenKind::Less, false),
            '>' if pair == Some('=') => (TokenKind::GreaterEqual, true),
            '>' => (TokenKind::Greater, false),
            '&' if pair == Some('&') => (TokenKind::AmpAmp, true),
            '|' if pair == Some('|') => (TokenKind::PipePipe, true),
            '|' => (TokenKind::Pipe, false),
            invalid => {
                let span = self.source.span(start, self.position);
                let message = if invalid == '&' {
                    "Unexpected character '&'; use '&&' for logical AND".to_owned()
                } else {
                    format!("Unexpected character '{invalid}'")
                };
                self.report(Diagnostic::parse(
                    "E0101",
                    message,
                    span,
                    invalid.to_string(),
                ));
                return self.token(TokenKind::Error, invalid.to_string(), start, self.position);
            }
        };
        if consume_pair {
            self.advance_char();
        }
        self.source_token(kind, start, self.position)
    }

    fn skip_trivia(&mut self) {
        loop {
            while self
                .peek_char()
                .is_some_and(|value| matches!(value, ' ' | '\t' | '\r' | '\n'))
            {
                self.advance_char();
            }
            if self.peek_char() == Some('/') && self.peek_nth_char(1) == Some('/') {
                while self.peek_char().is_some_and(|value| value != '\n') {
                    self.advance_char();
                }
                continue;
            }
            break;
        }
    }

    fn peek_char(&self) -> Option<char> {
        self.source.text()[self.position..].chars().next()
    }

    fn peek_nth_char(&self, index: usize) -> Option<char> {
        self.source.text()[self.position..].chars().nth(index)
    }

    fn advance_char(&mut self) -> Option<char> {
        let value = self.peek_char()?;
        self.position += value.len_utf8();
        Some(value)
    }

    fn source_token(&self, kind: TokenKind, start: usize, end: usize) -> Token {
        self.token(kind, self.source.text()[start..end].to_owned(), start, end)
    }

    fn token(&self, kind: TokenKind, value: String, start: usize, end: usize) -> Token {
        Token {
            kind,
            value,
            span: self.source.span(start, end),
        }
    }

    fn report(&mut self, diagnostic: Diagnostic) {
        push_diagnostic(&mut self.diagnostics, diagnostic);
    }
}

fn is_identifier_start(value: char) -> bool {
    value.is_ascii_alphabetic() || value == '_'
}

fn is_identifier_continue(value: char) -> bool {
    is_identifier_start(value) || value.is_ascii_digit()
}

fn keyword(value: &str) -> Option<TokenKind> {
    Some(match value {
        "fn" => TokenKind::Fn,
        "let" => TokenKind::Let,
        "mut" => TokenKind::Mut,
        "const" => TokenKind::Const,
        "struct" => TokenKind::Struct,
        "enum" => TokenKind::Enum,
        "match" => TokenKind::Match,
        "impl" => TokenKind::Impl,
        "effect" => TokenKind::Effect,
        "handle" => TokenKind::Handle,
        "with" => TokenKind::With,
        "if" => TokenKind::If,
        "else" => TokenKind::Else,
        "catch" => TokenKind::Catch,
        "test" => TokenKind::Test,
        "return" => TokenKind::Return,
        "for" => TokenKind::For,
        "in" => TokenKind::In,
        "pub" => TokenKind::Pub,
        "where" => TokenKind::Where,
        "true" => TokenKind::True,
        "false" => TokenKind::False,
        "trait" => TokenKind::Trait,
        "try" => TokenKind::Try,
        "while" => TokenKind::While,
        "break" => TokenKind::Break,
        "continue" => TokenKind::Continue,
        "loop" => TokenKind::Loop,
        "use" => TokenKind::Use,
        "as" => TokenKind::As,
        "extern" => TokenKind::Extern,
        "mod" => TokenKind::Mod,
        "super" => TokenKind::Super,
        "requires" => TokenKind::Requires,
        "unsafe" => TokenKind::Unsafe,
        _ => return None,
    })
}
