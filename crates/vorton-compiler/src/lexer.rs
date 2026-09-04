use crate::ast::{RawStringDelimiter, Span};
use crate::diagnostic::{
    ExpectedToken, FoundToken, FrontendDiagnostic, LexicalDiagnosticKind, TokenClass,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Token {
    pub(crate) kind: TokenKind,
    pub(crate) span: Span,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TokenKind {
    Ident(String),
    Integer(String),
    Float(String),
    String(String),
    RawString(String, RawStringDelimiter),
    InterpolationStart(String),
    InterpolationMiddle(String),
    InterpolationEnd(String),
    Fn,
    Let,
    Mut,
    Move,
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
    AndAnd,
    OrOr,
    Bang,
    Pipe,
    Equal,
    PlusEqual,
    MinusEqual,
    StarEqual,
    SlashEqual,
    PercentEqual,
    DotDot,
    DotDotEqual,
    Dot,
    ColonColon,
    Question,
    Arrow,
    FatArrow,
    LParen,
    RParen,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    Comma,
    Colon,
    Semicolon,
    Eof,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Tag {
    Ident,
    Integer,
    Float,
    String,
    RawString,
    InterpolationStart,
    InterpolationMiddle,
    InterpolationEnd,
    Fn,
    Let,
    Mut,
    Move,
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
    AndAnd,
    OrOr,
    Bang,
    Pipe,
    Equal,
    PlusEqual,
    MinusEqual,
    StarEqual,
    SlashEqual,
    PercentEqual,
    DotDot,
    DotDotEqual,
    Dot,
    ColonColon,
    Question,
    Arrow,
    FatArrow,
    LParen,
    RParen,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    Comma,
    Colon,
    Semicolon,
    Eof,
}

impl TokenKind {
    pub(crate) const fn tag(&self) -> Tag {
        match self {
            Self::Ident(_) => Tag::Ident,
            Self::Integer(_) => Tag::Integer,
            Self::Float(_) => Tag::Float,
            Self::String(_) => Tag::String,
            Self::RawString(_, _) => Tag::RawString,
            Self::InterpolationStart(_) => Tag::InterpolationStart,
            Self::InterpolationMiddle(_) => Tag::InterpolationMiddle,
            Self::InterpolationEnd(_) => Tag::InterpolationEnd,
            Self::Fn => Tag::Fn,
            Self::Let => Tag::Let,
            Self::Mut => Tag::Mut,
            Self::Move => Tag::Move,
            Self::Const => Tag::Const,
            Self::Struct => Tag::Struct,
            Self::Enum => Tag::Enum,
            Self::Match => Tag::Match,
            Self::Impl => Tag::Impl,
            Self::Effect => Tag::Effect,
            Self::Handle => Tag::Handle,
            Self::With => Tag::With,
            Self::If => Tag::If,
            Self::Else => Tag::Else,
            Self::Catch => Tag::Catch,
            Self::Test => Tag::Test,
            Self::Return => Tag::Return,
            Self::For => Tag::For,
            Self::In => Tag::In,
            Self::Pub => Tag::Pub,
            Self::Where => Tag::Where,
            Self::True => Tag::True,
            Self::False => Tag::False,
            Self::Trait => Tag::Trait,
            Self::Try => Tag::Try,
            Self::While => Tag::While,
            Self::Break => Tag::Break,
            Self::Continue => Tag::Continue,
            Self::Loop => Tag::Loop,
            Self::Use => Tag::Use,
            Self::As => Tag::As,
            Self::Extern => Tag::Extern,
            Self::Mod => Tag::Mod,
            Self::Super => Tag::Super,
            Self::Requires => Tag::Requires,
            Self::Unsafe => Tag::Unsafe,
            Self::Plus => Tag::Plus,
            Self::Minus => Tag::Minus,
            Self::Star => Tag::Star,
            Self::Slash => Tag::Slash,
            Self::Percent => Tag::Percent,
            Self::EqualEqual => Tag::EqualEqual,
            Self::BangEqual => Tag::BangEqual,
            Self::Less => Tag::Less,
            Self::Greater => Tag::Greater,
            Self::LessEqual => Tag::LessEqual,
            Self::GreaterEqual => Tag::GreaterEqual,
            Self::AndAnd => Tag::AndAnd,
            Self::OrOr => Tag::OrOr,
            Self::Bang => Tag::Bang,
            Self::Pipe => Tag::Pipe,
            Self::Equal => Tag::Equal,
            Self::PlusEqual => Tag::PlusEqual,
            Self::MinusEqual => Tag::MinusEqual,
            Self::StarEqual => Tag::StarEqual,
            Self::SlashEqual => Tag::SlashEqual,
            Self::PercentEqual => Tag::PercentEqual,
            Self::DotDot => Tag::DotDot,
            Self::DotDotEqual => Tag::DotDotEqual,
            Self::Dot => Tag::Dot,
            Self::ColonColon => Tag::ColonColon,
            Self::Question => Tag::Question,
            Self::Arrow => Tag::Arrow,
            Self::FatArrow => Tag::FatArrow,
            Self::LParen => Tag::LParen,
            Self::RParen => Tag::RParen,
            Self::LBrace => Tag::LBrace,
            Self::RBrace => Tag::RBrace,
            Self::LBracket => Tag::LBracket,
            Self::RBracket => Tag::RBracket,
            Self::Comma => Tag::Comma,
            Self::Colon => Tag::Colon,
            Self::Semicolon => Tag::Semicolon,
            Self::Eof => Tag::Eof,
        }
    }
}

impl Tag {
    pub(crate) fn expected(self) -> ExpectedToken {
        match self {
            Self::Ident => ExpectedToken::Class(TokenClass::Identifier),
            Self::Integer => ExpectedToken::Class(TokenClass::IntegerLiteral),
            Self::Float => ExpectedToken::Class(TokenClass::FloatLiteral),
            Self::String => ExpectedToken::Class(TokenClass::StringLiteral),
            Self::RawString => ExpectedToken::Class(TokenClass::RawStringLiteral),
            Self::InterpolationStart => ExpectedToken::Class(TokenClass::InterpolatedStringStart),
            Self::InterpolationMiddle => ExpectedToken::Class(TokenClass::InterpolatedStringMiddle),
            Self::InterpolationEnd => ExpectedToken::Class(TokenClass::InterpolatedStringEnd),
            Self::Eof => ExpectedToken::Eof,
            fixed => ExpectedToken::Fixed(fixed.fixed_spelling().to_owned()),
        }
    }

    pub(crate) const fn fixed_spelling(self) -> &'static str {
        match self {
            Self::Fn => "fn",
            Self::Let => "let",
            Self::Mut => "mut",
            Self::Move => "move",
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
            Self::AndAnd => "&&",
            Self::OrOr => "||",
            Self::Bang => "!",
            Self::Pipe => "|",
            Self::Equal => "=",
            Self::PlusEqual => "+=",
            Self::MinusEqual => "-=",
            Self::StarEqual => "*=",
            Self::SlashEqual => "/=",
            Self::PercentEqual => "%=",
            Self::DotDot => "..",
            Self::DotDotEqual => "..=",
            Self::Dot => ".",
            Self::ColonColon => "::",
            Self::Question => "?",
            Self::Arrow => "->",
            Self::FatArrow => "=>",
            Self::LParen => "(",
            Self::RParen => ")",
            Self::LBrace => "{",
            Self::RBrace => "}",
            Self::LBracket => "[",
            Self::RBracket => "]",
            Self::Comma => ",",
            Self::Colon => ":",
            Self::Semicolon => ";",
            Self::Ident
            | Self::Integer
            | Self::Float
            | Self::String
            | Self::RawString
            | Self::InterpolationStart
            | Self::InterpolationMiddle
            | Self::InterpolationEnd
            | Self::Eof => "",
        }
    }

    pub(crate) fn found(self) -> FoundToken {
        match self {
            Self::Ident => FoundToken::Class(TokenClass::Identifier),
            Self::Integer => FoundToken::Class(TokenClass::IntegerLiteral),
            Self::Float => FoundToken::Class(TokenClass::FloatLiteral),
            Self::String => FoundToken::Class(TokenClass::StringLiteral),
            Self::RawString => FoundToken::Class(TokenClass::RawStringLiteral),
            Self::InterpolationStart => FoundToken::Class(TokenClass::InterpolatedStringStart),
            Self::InterpolationMiddle => FoundToken::Class(TokenClass::InterpolatedStringMiddle),
            Self::InterpolationEnd => FoundToken::Class(TokenClass::InterpolatedStringEnd),
            Self::Eof => FoundToken::Eof,
            fixed => FoundToken::Fixed(fixed.fixed_spelling().to_owned()),
        }
    }
}

pub(crate) fn lex(source: &str) -> Result<Vec<Token>, FrontendDiagnostic> {
    let mut lexer = Lexer {
        source,
        bytes: source.as_bytes(),
        position: 0,
        tokens: Vec::new(),
    };
    lexer.lex_top_level()?;
    lexer.tokens.push(Token {
        kind: TokenKind::Eof,
        span: Span::new(source.len(), source.len()),
    });
    Ok(lexer.tokens)
}

struct Lexer<'source> {
    source: &'source str,
    bytes: &'source [u8],
    position: usize,
    tokens: Vec<Token>,
}

impl Lexer<'_> {
    fn lex_top_level(&mut self) -> Result<(), FrontendDiagnostic> {
        loop {
            self.skip_trivia();
            if self.position == self.bytes.len() {
                return Ok(());
            }
            self.lex_token()?;
        }
    }

    fn lex_interpolation(&mut self, interpolation_start: usize) -> Result<(), FrontendDiagnostic> {
        let mut brace_depth = 0usize;
        loop {
            self.skip_trivia();
            if self.position == self.bytes.len() {
                return Err(self.error_from(
                    interpolation_start,
                    LexicalDiagnosticKind::UnterminatedInterpolation,
                ));
            }
            match self.bytes[self.position] {
                b'{' => {
                    let start = self.position;
                    self.position += 1;
                    brace_depth += 1;
                    self.push(TokenKind::LBrace, start);
                }
                b'}' if brace_depth == 0 => {
                    let segment_start = self.position;
                    self.position += 1;
                    return self.lex_interpolation_continuation(interpolation_start, segment_start);
                }
                b'}' => {
                    let start = self.position;
                    self.position += 1;
                    brace_depth -= 1;
                    self.push(TokenKind::RBrace, start);
                }
                _ => self.lex_token()?,
            }
        }
    }

    fn lex_token(&mut self) -> Result<(), FrontendDiagnostic> {
        let start = self.position;

        if self.starts_with(b"r#\"") {
            return self.lex_raw_string(RawStringDelimiter::HashQuote);
        }
        if self.starts_with(b"r\"") {
            return self.lex_raw_string(RawStringDelimiter::Quote);
        }

        let byte = self.bytes[start];
        if is_ident_start(byte) {
            self.position += 1;
            while self.position < self.bytes.len() && is_ident_continue(self.bytes[self.position]) {
                self.position += 1;
            }
            let spelling = &self.source[start..self.position];
            let kind = keyword(spelling).unwrap_or_else(|| TokenKind::Ident(spelling.to_owned()));
            self.push(kind, start);
            return Ok(());
        }
        if byte.is_ascii_digit() {
            return self.lex_number();
        }
        if byte == b'"' {
            return self.lex_cooked_string();
        }

        for (spelling, kind) in MULTI_CHARACTER_TOKENS {
            if self.starts_with(spelling.as_bytes()) {
                self.position += spelling.len();
                self.push(kind.clone(), start);
                return Ok(());
            }
        }

        let kind = match byte {
            b'+' => TokenKind::Plus,
            b'-' => TokenKind::Minus,
            b'*' => TokenKind::Star,
            b'/' => TokenKind::Slash,
            b'%' => TokenKind::Percent,
            b'<' => TokenKind::Less,
            b'>' => TokenKind::Greater,
            b'!' => TokenKind::Bang,
            b'|' => TokenKind::Pipe,
            b'=' => TokenKind::Equal,
            b'.' => TokenKind::Dot,
            b'?' => TokenKind::Question,
            b'(' => TokenKind::LParen,
            b')' => TokenKind::RParen,
            b'{' => TokenKind::LBrace,
            b'}' => TokenKind::RBrace,
            b'[' => TokenKind::LBracket,
            b']' => TokenKind::RBracket,
            b',' => TokenKind::Comma,
            b':' => TokenKind::Colon,
            b';' => TokenKind::Semicolon,
            _ => {
                let width = self.source[start..]
                    .chars()
                    .next()
                    .expect("position is before EOF")
                    .len_utf8();
                self.position += width;
                return Err(FrontendDiagnostic::lexical(
                    Span::new(start, self.position),
                    LexicalDiagnosticKind::UnexpectedCharacter,
                ));
            }
        };
        self.position += 1;
        self.push(kind, start);
        Ok(())
    }

    fn lex_number(&mut self) -> Result<(), FrontendDiagnostic> {
        let start = self.position;
        while self.position < self.bytes.len() && self.bytes[self.position].is_ascii_digit() {
            self.position += 1;
        }
        let is_float = self.position + 1 < self.bytes.len()
            && self.bytes[self.position] == b'.'
            && self.bytes[self.position + 1].is_ascii_digit();
        if is_float {
            self.position += 1;
            while self.position < self.bytes.len() && self.bytes[self.position].is_ascii_digit() {
                self.position += 1;
            }
            self.push(
                TokenKind::Float(self.source[start..self.position].to_owned()),
                start,
            );
        } else {
            self.push(
                TokenKind::Integer(self.source[start..self.position].to_owned()),
                start,
            );
        }
        Ok(())
    }

    fn lex_raw_string(&mut self, delimiter: RawStringDelimiter) -> Result<(), FrontendDiagnostic> {
        let start = self.position;
        let (prefix_length, terminator): (usize, &[u8]) = match delimiter {
            RawStringDelimiter::Quote => (2, b"\""),
            RawStringDelimiter::HashQuote => (3, b"\"#"),
        };
        self.position += prefix_length;
        let content_start = self.position;
        while self.position < self.bytes.len() {
            if self.bytes[self.position..].starts_with(terminator) {
                let value = self.source[content_start..self.position].to_owned();
                self.position += terminator.len();
                self.push(TokenKind::RawString(value, delimiter), start);
                return Ok(());
            }
            self.position += self.source[self.position..]
                .chars()
                .next()
                .expect("position is before EOF")
                .len_utf8();
        }
        Err(self.error_from(start, LexicalDiagnosticKind::UnterminatedRawString))
    }

    fn lex_cooked_string(&mut self) -> Result<(), FrontendDiagnostic> {
        let start = self.position;
        self.position += 1;
        let mut value = String::new();
        loop {
            if self.position == self.bytes.len() {
                return Err(self.error_from(start, LexicalDiagnosticKind::UnterminatedCookedString));
            }
            if self.bytes[self.position] == b'"' {
                self.position += 1;
                self.push(TokenKind::String(value), start);
                return Ok(());
            }
            if self.starts_with(b"${") {
                self.position += 2;
                self.push(TokenKind::InterpolationStart(value), start);
                return self.lex_interpolation(start);
            }
            self.push_cooked_character(
                &mut value,
                start,
                LexicalDiagnosticKind::UnterminatedCookedString,
            )?;
        }
    }

    fn lex_interpolation_continuation(
        &mut self,
        interpolation_start: usize,
        segment_start: usize,
    ) -> Result<(), FrontendDiagnostic> {
        let mut value = String::new();
        loop {
            if self.position == self.bytes.len() {
                return Err(self.error_from(
                    interpolation_start,
                    LexicalDiagnosticKind::UnterminatedInterpolation,
                ));
            }
            if self.bytes[self.position] == b'"' {
                self.position += 1;
                self.push(TokenKind::InterpolationEnd(value), segment_start);
                return Ok(());
            }
            if self.starts_with(b"${") {
                self.position += 2;
                self.push(TokenKind::InterpolationMiddle(value), segment_start);
                return self.lex_interpolation(interpolation_start);
            }
            self.push_cooked_character(
                &mut value,
                interpolation_start,
                LexicalDiagnosticKind::UnterminatedInterpolation,
            )?;
        }
    }

    fn push_cooked_character(
        &mut self,
        value: &mut String,
        unterminated_start: usize,
        unterminated_kind: LexicalDiagnosticKind,
    ) -> Result<(), FrontendDiagnostic> {
        let start = self.position;
        match self.bytes[start] {
            b'\r' | b'\n' => Err(FrontendDiagnostic::lexical(
                Span::new(unterminated_start, start),
                unterminated_kind,
            )),
            b'\\' => {
                self.position += 1;
                if self.position == self.bytes.len() {
                    return Err(FrontendDiagnostic::lexical(
                        Span::new(start, self.position),
                        LexicalDiagnosticKind::InvalidEscape,
                    ));
                }
                let decoded = match self.bytes[self.position] {
                    b'\\' => '\\',
                    b'"' => '"',
                    b'n' => '\n',
                    b't' => '\t',
                    b'r' => '\r',
                    b'0' => '\0',
                    _ => {
                        let width = self.source[self.position..]
                            .chars()
                            .next()
                            .expect("position is before EOF")
                            .len_utf8();
                        self.position += width;
                        return Err(FrontendDiagnostic::lexical(
                            Span::new(start, self.position),
                            LexicalDiagnosticKind::InvalidEscape,
                        ));
                    }
                };
                self.position += 1;
                value.push(decoded);
                Ok(())
            }
            _ => {
                let character = self.source[start..]
                    .chars()
                    .next()
                    .expect("position is before EOF");
                self.position += character.len_utf8();
                value.push(character);
                Ok(())
            }
        }
    }

    fn skip_trivia(&mut self) {
        loop {
            while self.position < self.bytes.len()
                && matches!(self.bytes[self.position], b' ' | b'\t' | b'\r' | b'\n')
            {
                self.position += 1;
            }
            if self.starts_with(b"//") {
                self.position += 2;
                while self.position < self.bytes.len()
                    && !matches!(self.bytes[self.position], b'\r' | b'\n')
                {
                    self.position += 1;
                }
                continue;
            }
            return;
        }
    }

    fn starts_with(&self, spelling: &[u8]) -> bool {
        self.bytes[self.position..].starts_with(spelling)
    }

    fn push(&mut self, kind: TokenKind, start: usize) {
        self.tokens.push(Token {
            kind,
            span: Span::new(start, self.position),
        });
    }

    fn error_from(&self, start: usize, kind: LexicalDiagnosticKind) -> FrontendDiagnostic {
        FrontendDiagnostic::lexical(Span::new(start, self.position), kind)
    }
}

const MULTI_CHARACTER_TOKENS: &[(&str, TokenKind)] = &[
    ("..=", TokenKind::DotDotEqual),
    ("==", TokenKind::EqualEqual),
    ("!=", TokenKind::BangEqual),
    ("<=", TokenKind::LessEqual),
    (">=", TokenKind::GreaterEqual),
    ("&&", TokenKind::AndAnd),
    ("||", TokenKind::OrOr),
    ("+=", TokenKind::PlusEqual),
    ("-=", TokenKind::MinusEqual),
    ("*=", TokenKind::StarEqual),
    ("/=", TokenKind::SlashEqual),
    ("%=", TokenKind::PercentEqual),
    ("..", TokenKind::DotDot),
    ("::", TokenKind::ColonColon),
    ("->", TokenKind::Arrow),
    ("=>", TokenKind::FatArrow),
];

fn is_ident_start(byte: u8) -> bool {
    byte.is_ascii_alphabetic() || byte == b'_'
}

fn is_ident_continue(byte: u8) -> bool {
    is_ident_start(byte) || byte.is_ascii_digit()
}

fn keyword(spelling: &str) -> Option<TokenKind> {
    Some(match spelling {
        "fn" => TokenKind::Fn,
        "let" => TokenKind::Let,
        "mut" => TokenKind::Mut,
        "move" => TokenKind::Move,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diagnostic::FrontendDiagnosticKind;

    fn tags(source: &str) -> Vec<Tag> {
        lex(source)
            .expect("source should lex")
            .into_iter()
            .map(|token| token.kind.tag())
            .collect()
    }

    #[test]
    fn scans_every_fixed_token() {
        let source = "fn let mut move const struct enum match impl effect handle with if else \
            catch test return for in pub where true false trait try while break continue loop \
            use as extern mod super requires unsafe \
            + - * / % == != < > <= >= && || ! | = += -= *= /= %= .. ..= . :: ? -> => \
            ( ) { } [ ] , : ;";
        assert_eq!(
            tags(source),
            vec![
                Tag::Fn,
                Tag::Let,
                Tag::Mut,
                Tag::Move,
                Tag::Const,
                Tag::Struct,
                Tag::Enum,
                Tag::Match,
                Tag::Impl,
                Tag::Effect,
                Tag::Handle,
                Tag::With,
                Tag::If,
                Tag::Else,
                Tag::Catch,
                Tag::Test,
                Tag::Return,
                Tag::For,
                Tag::In,
                Tag::Pub,
                Tag::Where,
                Tag::True,
                Tag::False,
                Tag::Trait,
                Tag::Try,
                Tag::While,
                Tag::Break,
                Tag::Continue,
                Tag::Loop,
                Tag::Use,
                Tag::As,
                Tag::Extern,
                Tag::Mod,
                Tag::Super,
                Tag::Requires,
                Tag::Unsafe,
                Tag::Plus,
                Tag::Minus,
                Tag::Star,
                Tag::Slash,
                Tag::Percent,
                Tag::EqualEqual,
                Tag::BangEqual,
                Tag::Less,
                Tag::Greater,
                Tag::LessEqual,
                Tag::GreaterEqual,
                Tag::AndAnd,
                Tag::OrOr,
                Tag::Bang,
                Tag::Pipe,
                Tag::Equal,
                Tag::PlusEqual,
                Tag::MinusEqual,
                Tag::StarEqual,
                Tag::SlashEqual,
                Tag::PercentEqual,
                Tag::DotDot,
                Tag::DotDotEqual,
                Tag::Dot,
                Tag::ColonColon,
                Tag::Question,
                Tag::Arrow,
                Tag::FatArrow,
                Tag::LParen,
                Tag::RParen,
                Tag::LBrace,
                Tag::RBrace,
                Tag::LBracket,
                Tag::RBracket,
                Tag::Comma,
                Tag::Colon,
                Tag::Semicolon,
                Tag::Eof,
            ]
        );
    }

    #[test]
    fn applies_boundaries_longest_match_and_decimal_rules() {
        let tokens = lex("move_value 1..2 12.340 type self alias rvalue").unwrap();
        assert!(matches!(&tokens[0].kind, TokenKind::Ident(value) if value == "move_value"));
        assert!(matches!(&tokens[1].kind, TokenKind::Integer(value) if value == "1"));
        assert_eq!(tokens[2].kind.tag(), Tag::DotDot);
        assert!(matches!(&tokens[3].kind, TokenKind::Integer(value) if value == "2"));
        assert!(matches!(&tokens[4].kind, TokenKind::Float(value) if value == "12.340"));
        assert!(
            tokens[5..9]
                .iter()
                .all(|token| token.kind.tag() == Tag::Ident)
        );
    }

    #[test]
    fn decodes_cooked_and_preserves_raw_strings() {
        let source = "\"a\\n\\t\\r\\0\\\\\\\"λ\" r\"a\\nb\" r#\"a\"b#\r\n\0\"#";
        let tokens = lex(source).unwrap();
        assert!(matches!(&tokens[0].kind, TokenKind::String(value) if value == "a\n\t\r\0\\\"λ"));
        assert!(matches!(
            &tokens[1].kind,
            TokenKind::RawString(value, RawStringDelimiter::Quote) if value == "a\\nb"
        ));
        assert!(matches!(
            &tokens[2].kind,
            TokenKind::RawString(value, RawStringDelimiter::HashQuote)
                if value == "a\"b#\r\n\0"
        ));
    }

    #[test]
    fn nests_braces_and_interpolated_strings() {
        let tokens = lex(r#""a${outer(Item { field: "b${inner}" })}c${last}d""#).unwrap();
        assert_eq!(
            tokens
                .iter()
                .map(|token| token.kind.tag())
                .collect::<Vec<_>>(),
            vec![
                Tag::InterpolationStart,
                Tag::Ident,
                Tag::LParen,
                Tag::Ident,
                Tag::LBrace,
                Tag::Ident,
                Tag::Colon,
                Tag::InterpolationStart,
                Tag::Ident,
                Tag::InterpolationEnd,
                Tag::RBrace,
                Tag::RParen,
                Tag::InterpolationMiddle,
                Tag::Ident,
                Tag::InterpolationEnd,
                Tag::Eof,
            ]
        );
        assert!(matches!(&tokens[0].kind, TokenKind::InterpolationStart(value) if value == "a"));
        assert!(matches!(&tokens[12].kind, TokenKind::InterpolationMiddle(value) if value == "c"));
        assert!(matches!(&tokens[14].kind, TokenKind::InterpolationEnd(value) if value == "d"));
    }

    #[test]
    fn retains_utf8_and_crlf_byte_spans() {
        let tokens = lex("// λ\r\nname\r\n\"λ\"").unwrap();
        assert_eq!(tokens[0].span, Span::new(7, 11));
        assert_eq!(tokens[1].span, Span::new(13, 17));
    }

    #[test]
    fn reports_each_lexical_diagnostic_kind() {
        let cases = [
            ("@", LexicalDiagnosticKind::UnexpectedCharacter),
            ("\"\\x\"", LexicalDiagnosticKind::InvalidEscape),
            ("\"open", LexicalDiagnosticKind::UnterminatedCookedString),
            ("r#\"open", LexicalDiagnosticKind::UnterminatedRawString),
            ("\"${open", LexicalDiagnosticKind::UnterminatedInterpolation),
        ];
        for (source, expected) in cases {
            let diagnostic = lex(source).expect_err(source);
            assert_eq!(
                diagnostic.kind,
                FrontendDiagnosticKind::Lexical(expected),
                "{source:?}"
            );
        }
    }
}
