use ast::{Position, Span}
use diagnostics::{CollectingSink, Severity, DiagnosticContext, new_collecting_sink, make_diag}
use codes::{E0101, E0102}

// ============================================================
// TokenKind
// ============================================================

pub enum TokenKind {
    // Keywords
    TkFn, TkLet, TkMut, TkConst, TkStruct, TkEnum, TkMatch,
    TkImpl, TkEffect, TkHandle, TkWith,
    TkIf, TkElse, TkCatch, TkTest, TkReturn,
    TkFor, TkIn, TkPub, TkWhere,
    TkTrue, TkFalse, TkTrait, TkTry,
    TkWhile, TkBreak, TkContinue, TkLoop,
    TkUse, TkAs, TkExtern, TkMod, TkSuper, TkRequires, TkUnsafe,

    // Literals
    TkIntLit, TkFloatLit, TkStringLit,
    TkStringInterpStart, TkStringInterpMiddle, TkStringInterpEnd,
    TkRawStringLit,

    // Identifier
    TkIdent,

    // Operators
    TkPlus, TkMinus, TkStar, TkSlash, TkPercent,
    TkEqEq, TkBangEq, TkLt, TkGt, TkLtEq, TkGtEq,
    TkAmpAmp, TkPipePipe, TkPipe, TkBang,
    TkEq, TkPlusEq, TkMinusEq, TkStarEq, TkSlashEq, TkPercentEq,

    // Delimiters
    TkLParen, TkRParen, TkLBrace, TkRBrace, TkLBracket, TkRBracket,
    TkComma, TkColon, TkColonColon, TkDot, TkDotDot, TkDotDotEq,
    TkFatArrow, TkArrow, TkQuestion, TkAt,

    // Semicolons
    TkSemi,

    // Special
    TkEof, TkError
}

pub fn token_kind_value(k: TokenKind) -> Str {
    match k {
        TkFn => "fn", TkLet => "let", TkMut => "mut", TkConst => "const",
        TkStruct => "struct", TkEnum => "enum", TkMatch => "match",
        TkImpl => "impl", TkEffect => "effect", TkHandle => "handle", TkWith => "with",
        TkIf => "if", TkElse => "else", TkCatch => "catch",
        TkTest => "test", TkReturn => "return",
        TkFor => "for", TkIn => "in", TkPub => "pub", TkWhere => "where",
        TkTrue => "true", TkFalse => "false", TkTrait => "trait", TkTry => "try",
        TkWhile => "while", TkBreak => "break", TkContinue => "continue", TkLoop => "loop",
        TkUse => "use", TkAs => "as", TkExtern => "extern", TkMod => "mod",
        TkSuper => "super", TkRequires => "requires", TkUnsafe => "unsafe",
        TkIntLit => "int_lit", TkFloatLit => "float_lit", TkStringLit => "string_lit",
        TkStringInterpStart => "string_interp_start",
        TkStringInterpMiddle => "string_interp_middle",
        TkStringInterpEnd => "string_interp_end",
        TkRawStringLit => "raw_string_lit",
        TkIdent => "ident",
        TkPlus => "+", TkMinus => "-", TkStar => "*", TkSlash => "/", TkPercent => "%",
        TkEqEq => "==", TkBangEq => "!=", TkLt => "<", TkGt => ">",
        TkLtEq => "<=", TkGtEq => ">=",
        TkAmpAmp => "&&", TkPipePipe => "||", TkPipe => "|", TkBang => "!",
        TkEq => "=", TkPlusEq => "+=", TkMinusEq => "-=", TkStarEq => "*=", TkSlashEq => "/=", TkPercentEq => "%=",
        TkLParen => "(", TkRParen => ")", TkLBrace => "{", TkRBrace => "}",
        TkLBracket => "[", TkRBracket => "]",
        TkComma => ",", TkColon => ":", TkColonColon => "::",
        TkDot => ".", TkDotDot => "..", TkDotDotEq => "..=",
        TkFatArrow => "=>", TkArrow => "->", TkQuestion => "?", TkAt => "@",
        TkSemi => ";",
        TkEof => "eof", TkError => "error_token"
    }
}

fn keyword_lookup(word: Str) -> TokenKind? {
    match word {
        "fn" => some(TokenKind::TkFn),
        "let" => some(TokenKind::TkLet),
        "mut" => some(TokenKind::TkMut),
        "const" => some(TokenKind::TkConst),
        "struct" => some(TokenKind::TkStruct),
        "enum" => some(TokenKind::TkEnum),
        "match" => some(TokenKind::TkMatch),
        "impl" => some(TokenKind::TkImpl),
        "effect" => some(TokenKind::TkEffect),
        "handle" => some(TokenKind::TkHandle),
        "with" => some(TokenKind::TkWith),
        "if" => some(TokenKind::TkIf),
        "else" => some(TokenKind::TkElse),
        "catch" => some(TokenKind::TkCatch),
        "test" => some(TokenKind::TkTest),
        "return" => some(TokenKind::TkReturn),
        "for" => some(TokenKind::TkFor),
        "in" => some(TokenKind::TkIn),
        "pub" => some(TokenKind::TkPub),
        "where" => some(TokenKind::TkWhere),
        "true" => some(TokenKind::TkTrue),
        "false" => some(TokenKind::TkFalse),
        "trait" => some(TokenKind::TkTrait),
        "try" => some(TokenKind::TkTry),
        "while" => some(TokenKind::TkWhile),
        "break" => some(TokenKind::TkBreak),
        "continue" => some(TokenKind::TkContinue),
        "loop" => some(TokenKind::TkLoop),
        "use" => some(TokenKind::TkUse),
        "as" => some(TokenKind::TkAs),
        "extern" => some(TokenKind::TkExtern),
        "mod" => some(TokenKind::TkMod),
        "super" => some(TokenKind::TkSuper),
        "requires" => some(TokenKind::TkRequires),
        "unsafe" => some(TokenKind::TkUnsafe),
        _ => none
    }
}

// ============================================================
// Token
// ============================================================

pub struct Token {
    pub kind: TokenKind,
    pub value: Str,
    pub span: Span
}

// ============================================================
// Character helpers (free functions)
// ============================================================

fn code_in_range(c: Int, low: Int, high: Int) -> Bool {
    if c >= low && c <= high { true } else { false }
}

fn is_digit(ch: Str) -> Bool {
    code_in_range(ch.char_code_at(0).unwrap_or(0), 48, 57)
}

fn is_ident_start(ch: Str) -> Bool {
    let c = ch.char_code_at(0).unwrap_or(0)
    if code_in_range(c, 97, 122) { true }
    else if code_in_range(c, 65, 90) { true }
    else { c == 95 }
}

fn is_ident_continue(ch: Str) -> Bool {
    if is_ident_start(ch) { true } else { is_digit(ch) }
}

// ============================================================
// Lexer
// ============================================================

// One stack frame per open `${` interpolation: brace nesting depth inside the
// expression (`}` only resumes the string at depth 0) plus the span of the
// opening `${` for unterminated-interpolation diagnostics.
struct InterpFrame {
    depth: Int,
    start_span: Span
}

pub struct Lexer {
    pub source: Str,
    pub file: Str,
    pos: Int,
    line: Int,
    column: Int,
    pub sink: CollectingSink,
    interp_frames: List<InterpFrame>
}

pub fn new_lexer(source: Str, file: Str, sink: CollectingSink) -> Lexer {
    Lexer {
        source: source,
        file: file,
        pos: 0,
        line: 1,
        column: 0,
        sink: sink,
        interp_frames: []
    }
}

impl Lexer {
    pub fn tokenize(mut self) -> List<Token> {
        let mut tokens: List<Token> = []
        while true {
            let tok = self.next_token()
            let is_eof = match tok.kind { TkEof => true, _ => false }
            tokens.push(tok)
            if is_eof { break }
        }
        tokens
    }

    pub fn next_token(mut self) -> Token {
        self.skip_whitespace_and_comments()

        if self.pos >= self.source.len() {
            if self.interp_frames.len() > 0 {
                let interp_span = self.last_frame_span()
                self.sink.report(make_diag(E0102, Severity::SevError, "Unterminated string interpolation: missing '}' to close '\${'", interp_span, DiagnosticContext::ParseError { token: "\${", expected: none }))
                while self.interp_frames.len() > 0 {
                    self.interp_frames.pop()
                }
            }
            return self.make_token(TokenKind::TkEof, "", self.current_position(), self.current_position())
        }

        if self.interp_frames.len() > 0 {
            if self.last_frame_depth() == 0 && self.peek() == "}" {
                self.advance()
                return self.lex_string_continuation()
            }
        }

        let start = self.current_position()
        let ch = self.peek()

        if ch == "r" && self.pos + 1 < self.source.len() {
            let next_ch = self.source.char_at(self.pos + 1).unwrap_or("")
            if next_ch == "#" || next_ch == "\"" {
                return self.lex_raw_string(start)
            }
        }

        if ch == "\"" {
            return self.lex_string(start)
        }

        if is_digit(ch) {
            return self.lex_number(start)
        }

        if is_ident_start(ch) {
            return self.lex_ident(start)
        }

        self.lex_punctuation(start)
    }

    // ============================================================
    // String lexing
    // ============================================================

    fn lex_string(mut self, start: Position) -> Token {
        self.advance()
        self.lex_string_body(start, true)
    }

    fn lex_string_continuation(mut self) -> Token {
        let start = self.current_position()
        self.lex_string_body(start, false)
    }

    fn lex_string_body(mut self, start: Position, is_new: Bool) -> Token {
        let mut value = ""
        while self.pos < self.source.len() {
            let ch = self.peek()
            if ch == "\"" {
                self.advance()
                let end = self.current_position()
                if is_new {
                    return self.make_token(TokenKind::TkStringLit, value, start, end)
                } else {
                    self.interp_frames.pop()
                    return self.make_token(TokenKind::TkStringInterpEnd, value, start, end)
                }
            }
            if ch == "$" && self.pos + 1 < self.source.len() && self.source.char_at(self.pos + 1).unwrap_or("") == "{" {
                let interp_start = self.current_position()
                self.advance()
                self.advance()
                let end = self.current_position()
                let interp_span = Span { file: self.file, start: interp_start, end: end }
                if is_new {
                    self.interp_frames.push(InterpFrame { depth: 0, start_span: interp_span })
                    return self.make_token(TokenKind::TkStringInterpStart, value, start, end)
                } else {
                    self.reset_last_frame(interp_span)
                    return self.make_token(TokenKind::TkStringInterpMiddle, value, start, end)
                }
            }
            if ch == "\\" {
                self.advance()
                if self.pos >= self.source.len() {
                    value = "${value}\\"
                    break
                }
                let esc = self.peek()
                self.advance()
                if esc == "n" { value = "${value}\n" }
                else if esc == "t" { value = "${value}\t" }
                else if esc == "r" { value = "${value}\r" }
                else if esc == "\\" { value = "${value}\\" }
                else if esc == "\"" { value = "${value}\"" }
                else if esc == "$" { value = "${value}$" }
                else { value = "${value}${esc}" }
            } else {
                if ch != "\r" {
                    value = "${value}${ch}"
                }
                self.advance()
            }
        }
        // Unterminated string at EOF. In continuation mode the `${...}` was
        // already closed by `}`, so pop this string's frame — only the plain
        // unterminated-string diagnostic applies, not unterminated-interpolation.
        if is_new == false {
            self.interp_frames.pop()
        }
        let end = self.current_position()
        let span = Span { file: self.file, start: start, end: end }
        self.sink.report(make_diag(E0102, Severity::SevError, "Unterminated string literal", span, DiagnosticContext::ParseError { token: value, expected: none }))
        self.make_token(TokenKind::TkError, value, start, end)
    }

    fn lex_raw_string(mut self, start: Position) -> Token {
        self.advance()
        let has_hash = self.peek() == "#"
        if has_hash {
            // r#"..."# format
            let saved_line = self.line
            self.advance()
            if self.peek() != "\"" {
                self.pos = self.pos - 1
                self.column = self.column - 1
                self.line = saved_line
                let end = self.current_position()
                return self.make_token(TokenKind::TkIdent, "r", start, end)
            }
            self.advance()
            let mut value = ""
            while self.pos < self.source.len() {
                let ch = self.peek()
                if ch == "\"" && self.pos + 1 < self.source.len() && self.source.char_at(self.pos + 1).unwrap_or("") == "#" {
                    self.advance()
                    self.advance()
                    let end = self.current_position()
                    return self.make_token(TokenKind::TkRawStringLit, value, start, end)
                }
                if ch != "\r" {
                    value = "${value}${ch}"
                }
                self.advance()
            }
            let span = Span { file: self.file, start: start, end: self.current_position() }
            self.sink.report(make_diag(E0102, Severity::SevError, "Unterminated raw string literal", span, DiagnosticContext::ParseError { token: value, expected: none }))
            let end = self.current_position()
            self.make_token(TokenKind::TkError, value, start, end)
        } else {
            // r"..." format (no hash delimiter)
            if self.peek() != "\"" {
                let end = self.current_position()
                return self.make_token(TokenKind::TkIdent, "r", start, end)
            }
            self.advance()
            let mut value = ""
            while self.pos < self.source.len() {
                let ch = self.peek()
                if ch == "\"" {
                    self.advance()
                    let end = self.current_position()
                    return self.make_token(TokenKind::TkRawStringLit, value, start, end)
                }
                if ch != "\r" {
                    value = "${value}${ch}"
                }
                self.advance()
            }
            let span = Span { file: self.file, start: start, end: self.current_position() }
            self.sink.report(make_diag(E0102, Severity::SevError, "Unterminated raw string literal", span, DiagnosticContext::ParseError { token: value, expected: none }))
            let end = self.current_position()
            self.make_token(TokenKind::TkError, value, start, end)
        }
    }

    // ============================================================
    // Number lexing
    // ============================================================

    fn lex_number(mut self, start: Position) -> Token {
        let mut value = ""
        let mut is_float = false

        while self.pos < self.source.len() && is_digit(self.peek()) {
            value = "${value}${self.peek()}"
            self.advance()
        }

        if self.pos < self.source.len() && self.peek() == "." && self.pos + 1 < self.source.len() && is_digit(self.source.char_at(self.pos + 1).unwrap_or("")) {
            is_float = true
            value = "${value}."
            self.advance()
            while self.pos < self.source.len() && is_digit(self.peek()) {
                value = "${value}${self.peek()}"
                self.advance()
            }
        }

        let end = self.current_position()
        if is_float {
            self.make_token(TokenKind::TkFloatLit, value, start, end)
        } else {
            self.make_token(TokenKind::TkIntLit, value, start, end)
        }
    }

    // ============================================================
    // Identifier / Keyword lexing
    // ============================================================

    fn lex_ident(mut self, start: Position) -> Token {
        let mut value = ""
        while self.pos < self.source.len() && is_ident_continue(self.peek()) {
            value = "${value}${self.peek()}"
            self.advance()
        }
        let end = self.current_position()
        let kind = keyword_lookup(value).unwrap_or(TokenKind::TkIdent)
        self.make_token(kind, value, start, end)
    }

    // ============================================================
    // Punctuation / Operators
    // ============================================================

    fn lex_punctuation(mut self, start: Position) -> Token {
        let ch = self.peek()
        self.advance()

        if ch == "(" { return self.make_token(TokenKind::TkLParen, "(", start, self.current_position()) }
        if ch == ")" { return self.make_token(TokenKind::TkRParen, ")", start, self.current_position()) }
        if ch == "{" {
            if self.interp_frames.len() > 0 {
                self.inc_last_depth()
            }
            return self.make_token(TokenKind::TkLBrace, "{", start, self.current_position())
        }
        if ch == "}" {
            if self.interp_frames.len() > 0 {
                self.dec_last_depth()
            }
            return self.make_token(TokenKind::TkRBrace, "}", start, self.current_position())
        }
        if ch == "[" { return self.make_token(TokenKind::TkLBracket, "[", start, self.current_position()) }
        if ch == "]" { return self.make_token(TokenKind::TkRBracket, "]", start, self.current_position()) }
        if ch == "," { return self.make_token(TokenKind::TkComma, ",", start, self.current_position()) }
        if ch == ":" {
            if self.peek() == ":" { self.advance(); return self.make_token(TokenKind::TkColonColon, "::", start, self.current_position()) }
            return self.make_token(TokenKind::TkColon, ":", start, self.current_position())
        }
        if ch == ";" { return self.make_token(TokenKind::TkSemi, ";", start, self.current_position()) }
        if ch == "?" { return self.make_token(TokenKind::TkQuestion, "?", start, self.current_position()) }
        if ch == "@" { return self.make_token(TokenKind::TkAt, "@", start, self.current_position()) }
        if ch == "." {
            if self.peek() == "." {
                self.advance()
                if self.peek() == "=" { self.advance(); return self.make_token(TokenKind::TkDotDotEq, "..=", start, self.current_position()) }
                return self.make_token(TokenKind::TkDotDot, "..", start, self.current_position())
            }
            return self.make_token(TokenKind::TkDot, ".", start, self.current_position())
        }
        if ch == "+" {
            if self.peek() == "=" { self.advance(); return self.make_token(TokenKind::TkPlusEq, "+=", start, self.current_position()) }
            return self.make_token(TokenKind::TkPlus, "+", start, self.current_position())
        }
        if ch == "-" {
            if self.peek() == ">" { self.advance(); return self.make_token(TokenKind::TkArrow, "->", start, self.current_position()) }
            if self.peek() == "=" { self.advance(); return self.make_token(TokenKind::TkMinusEq, "-=", start, self.current_position()) }
            return self.make_token(TokenKind::TkMinus, "-", start, self.current_position())
        }
        if ch == "*" {
            if self.peek() == "=" { self.advance(); return self.make_token(TokenKind::TkStarEq, "*=", start, self.current_position()) }
            return self.make_token(TokenKind::TkStar, "*", start, self.current_position())
        }
        if ch == "/" {
            if self.peek() == "=" { self.advance(); return self.make_token(TokenKind::TkSlashEq, "/=", start, self.current_position()) }
            return self.make_token(TokenKind::TkSlash, "/", start, self.current_position())
        }
        if ch == "%" {
            if self.peek() == "=" { self.advance(); return self.make_token(TokenKind::TkPercentEq, "%=", start, self.current_position()) }
            return self.make_token(TokenKind::TkPercent, "%", start, self.current_position())
        }
        if ch == "=" {
            if self.peek() == "=" { self.advance(); return self.make_token(TokenKind::TkEqEq, "==", start, self.current_position()) }
            if self.peek() == ">" { self.advance(); return self.make_token(TokenKind::TkFatArrow, "=>", start, self.current_position()) }
            return self.make_token(TokenKind::TkEq, "=", start, self.current_position())
        }
        if ch == "!" {
            if self.peek() == "=" { self.advance(); return self.make_token(TokenKind::TkBangEq, "!=", start, self.current_position()) }
            return self.make_token(TokenKind::TkBang, "!", start, self.current_position())
        }
        if ch == "<" {
            if self.peek() == "=" { self.advance(); return self.make_token(TokenKind::TkLtEq, "<=", start, self.current_position()) }
            return self.make_token(TokenKind::TkLt, "<", start, self.current_position())
        }
        if ch == ">" {
            if self.peek() == "=" { self.advance(); return self.make_token(TokenKind::TkGtEq, ">=", start, self.current_position()) }
            return self.make_token(TokenKind::TkGt, ">", start, self.current_position())
        }
        if ch == "&" {
            if self.peek() == "&" { self.advance(); return self.make_token(TokenKind::TkAmpAmp, "&&", start, self.current_position()) }
            let tok = self.make_token(TokenKind::TkError, "&", start, self.current_position())
            self.sink.report(make_diag(E0101, Severity::SevError, "Unexpected character '&' (use '&&' for logical AND)", tok.span, DiagnosticContext::ParseError { token: "&", expected: none }))
            return tok
        }
        if ch == "|" {
            if self.peek() == "|" { self.advance(); return self.make_token(TokenKind::TkPipePipe, "||", start, self.current_position()) }
            return self.make_token(TokenKind::TkPipe, "|", start, self.current_position())
        }

        let tok = self.make_token(TokenKind::TkError, ch, start, self.current_position())
        self.sink.report(make_diag(E0101, Severity::SevError, "Unexpected character '${ch}'", tok.span, DiagnosticContext::ParseError { token: ch, expected: none }))
        tok
    }

    // ============================================================
    // Helpers
    // ============================================================

    fn skip_whitespace_and_comments(mut self) {
        while self.pos < self.source.len() {
            let ch = self.peek()
            if ch == " " || ch == "\t" || ch == "\r" {
                self.advance()
            } else if ch == "\n" {
                self.advance()
            } else if ch == "/" && self.pos + 1 < self.source.len() && self.source.char_at(self.pos + 1).unwrap_or("") == "/" {
                while self.pos < self.source.len() && self.peek() != "\n" {
                    self.advance()
                }
            } else {
                break
            }
        }
    }

    fn peek(self) -> Str {
        self.source.char_at(self.pos).unwrap_or("")
    }

    fn advance(mut self) {
        if self.pos < self.source.len() {
            if self.source.char_at(self.pos).unwrap_or("") == "\n" {
                self.line = self.line + 1
                self.column = 0
            } else {
                self.column = self.column + 1
            }
            self.pos = self.pos + 1
        }
    }

    fn current_position(self) -> Position {
        Position { line: self.line, column: self.column, offset: self.pos }
    }

    fn make_token(self, kind: TokenKind, value: Str, start: Position, end: Position) -> Token {
        Token {
            kind: kind,
            value: value,
            span: Span { file: self.file, start: start, end: end }
        }
    }

    fn last_frame_depth(self) -> Int {
        match self.interp_frames.last() {
            some(f) => f.depth,
            none => 0
        }
    }

    fn last_frame_span(self) -> Span {
        match self.interp_frames.last() {
            some(f) => f.start_span,
            none => Span { file: self.file, start: self.current_position(), end: self.current_position() }
        }
    }

    fn inc_last_depth(mut self) {
        match self.interp_frames.pop() {
            some(f) => self.interp_frames.push(InterpFrame { depth: f.depth + 1, start_span: f.start_span }),
            none => {}
        }
    }

    fn dec_last_depth(mut self) {
        match self.interp_frames.pop() {
            some(f) => self.interp_frames.push(InterpFrame { depth: f.depth - 1, start_span: f.start_span }),
            none => {}
        }
    }

    // On `}...${` (TkStringInterpMiddle) the previous interpolation in this
    // string closed and a new one opened: reuse the frame, reset its depth and
    // point it at the new `${`.
    fn reset_last_frame(mut self, span: Span) {
        self.interp_frames.pop()
        self.interp_frames.push(InterpFrame { depth: 0, start_span: span })
    }
}
