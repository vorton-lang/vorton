use ast::{
    Position, Span, span_zero,
    TypeExpr, RecordTypeField, EffectExpr,
    Pattern, NamedPatternField, LiteralValue,
    BinOp, UnaryOp,
    Param, MatchArm, StructFieldInit, EffectHandler, StringInterpPart,
    Expr, Stmt, DestructureBinding,
    UsePath, NamedImport, UseImport, UseDecl,
    TypeBound, AssocConstraint, TypeParam, StructFieldDecl, NamedEnumField, EnumVariantDecl, EffectOpDecl,
    DeriveAttribute, Decl, Program
}
use lexer::{TokenKind, Token, Lexer, new_lexer, token_kind_value}
use diagnostics::{CollectingSink, Severity, DiagnosticContext, new_collecting_sink, make_diag, make_diagnostic}
use codes::{E0101, E0103, E0104, E0105, E0106, E0706, W0002}

extern fn __ring_raise_fail(msg: Str) -> Never with {fail}

// ============================================================
// Operator Precedence
// ============================================================

pub const PREC_NONE: Int = 0
pub const PREC_CATCH: Int = 1
pub const PREC_LOGIC_OR: Int = 2
pub const PREC_LOGIC_AND: Int = 3
pub const PREC_EQUALITY: Int = 4
pub const PREC_COMPARE: Int = 5
pub const PREC_RANGE: Int = 6
pub const PREC_ADD_SUB: Int = 7
pub const PREC_MUL_DIV: Int = 8
pub const PREC_UNARY: Int = 9
pub const PREC_POSTFIX: Int = 10

pub fn infix_precedence(kind: TokenKind) -> Int {
    match kind {
        TkCatch => PREC_CATCH,
        TkPipePipe => PREC_LOGIC_OR,
        TkAmpAmp => PREC_LOGIC_AND,
        TkEqEq => PREC_EQUALITY,
        TkBangEq => PREC_EQUALITY,
        TkLt => PREC_COMPARE,
        TkGt => PREC_COMPARE,
        TkLtEq => PREC_COMPARE,
        TkGtEq => PREC_COMPARE,
        TkDotDot => PREC_RANGE,
        TkDotDotEq => PREC_RANGE,
        TkPlus => PREC_ADD_SUB,
        TkMinus => PREC_ADD_SUB,
        TkStar => PREC_MUL_DIV,
        TkSlash => PREC_MUL_DIV,
        TkPercent => PREC_MUL_DIV,
        TkDot => PREC_POSTFIX,
        TkLParen => PREC_POSTFIX,
        TkLBracket => PREC_POSTFIX,
        _ => PREC_NONE
    }
}

// ============================================================
// BinOp / UnaryOp string conversion
// ============================================================

fn str_to_binop(s: Str) -> BinOp {
    if s == "+" { return BinOp::Add }
    if s == "-" { return BinOp::Sub }
    if s == "*" { return BinOp::Mul }
    if s == "/" { return BinOp::Div }
    if s == "%" { return BinOp::Mod }
    if s == "==" { return BinOp::Eq }
    if s == "!=" { return BinOp::Neq }
    if s == "<" { return BinOp::Lt }
    if s == "<=" { return BinOp::Lte }
    if s == ">" { return BinOp::Gt }
    if s == ">=" { return BinOp::Gte }
    if s == "&&" { return BinOp::And }
    if s == "||" { return BinOp::Or }
    panic("unreachable: unknown binary operator '${s}'")
}

fn str_to_unaryop(s: Str) -> UnaryOp {
    if s == "-" { return UnaryOp::Neg }
    if s == "!" { return UnaryOp::Not }
    panic("unreachable: unknown unary operator '${s}'")
}

fn dummy_type_expr() -> TypeExpr {
    TypeExpr::Named { name: "", qualifier: none, type_args: [], span: span_zero() }
}

fn dummy_expr() -> Expr {
    Expr::BoolLit { value: false, span: span_zero() }
}

fn is_decl_start(k: TokenKind) -> Bool {
    match k {
        TkFn => true, TkStruct => true, TkEnum => true,
        TkEffect => true, TkTrait => true, TkImpl => true,
        TkExtern => true, TkUse => true, TkPub => true, TkTest => true,
        TkConst => true, TkMod => true, TkAt => true,
        _ => false
    }
}

fn is_uppercase(ch: Str) -> Bool {
    let c = ch.char_code_at(0).unwrap_or(0)
    c >= 65 && c <= 90
}

pub fn type_expr_span(te: TypeExpr) -> Span {
    match te {
        Named { span, .. } => span,
        FnType { span, .. } => span,
        OptionType { span, .. } => span,
        RecordType { span, .. } => span,
        TupleType { span, .. } => span
    }
}

pub fn expr_span(e: Expr) -> Span {
    match e {
        IntLit { span, .. } => span,
        FloatLit { span, .. } => span,
        StrLit { span, .. } => span,
        BoolLit { span, .. } => span,
        Ident { span, .. } => span,
        BinOp { span, .. } => span,
        UnaryOp { span, .. } => span,
        Call { span, .. } => span,
        MethodCall { span, .. } => span,
        FieldAccess { span, .. } => span,
        StructLit { span, .. } => span,
        MatchExpr { span, .. } => span,
        Block { span, .. } => span,
        IfExpr { span, .. } => span,
        StringInterp { span, .. } => span,
        CatchExpr { span, .. } => span,
        HandleExpr { span, .. } => span,
        Lambda { span, .. } => span,
        Range { span, .. } => span,
        ListLit { span, .. } => span,
        TupleLit { span, .. } => span,
        IndexExpr { span, .. } => span,
        ReturnExpr { span, .. } => span,
        UnsafeBlock { span, .. } => span
    }
}

pub fn pattern_span(p: Pattern) -> Span {
    match p {
        Pattern::Wildcard { span, .. } => span,
        Pattern::Binding { span, .. } => span,
        Pattern::Constructor { span, .. } => span,
        Pattern::NamedConstructor { span, .. } => span,
        Pattern::Literal { span, .. } => span,
        Pattern::TuplePattern { span, .. } => span,
        Pattern::OrPattern { span, .. } => span
    }
}

// ============================================================
// Parser struct
// ============================================================

pub struct Parser {
    pub tokens: List<Token>,
    pub pos: Int,
    pub file: Str,
    pub sink: CollectingSink,
    pub error_count: Int
}

const MAX_ERRORS: Int = 20

pub fn new_parser(tokens: List<Token>, file: Str, sink: CollectingSink) -> Parser {
    Parser { tokens: tokens, pos: 0, file: file, sink: sink, error_count: 0 }
}

pub fn parse(source: Str, file: Str, sink: CollectingSink) -> Program {
    let mut lexer = new_lexer(source, file, sink)
    let tokens = lexer.tokenize()
    let mut parser = new_parser(tokens, file, sink)
    parser.parse_program()
}

impl Parser {

    // ============================================================
    // Token helpers
    // ============================================================

    pub fn peek(self) -> Token {
        if self.pos >= self.tokens.len() {
            return self.tokens.get(self.tokens.len() - 1).unwrap_or(Token {
                kind: TokenKind::TkEof,
                value: "",
                span: Span { file: self.file, start: Position { line: 1, column: 0, offset: 0 }, end: Position { line: 1, column: 0, offset: 0 } }
            })
        }
        self.tokens.get(self.pos).unwrap_or(Token {
            kind: TokenKind::TkEof,
            value: "",
            span: Span { file: self.file, start: Position { line: 1, column: 0, offset: 0 }, end: Position { line: 1, column: 0, offset: 0 } }
        })
    }

    pub fn peek_at(self, offset: Int) -> Token {
        let idx = self.pos + offset
        if idx >= self.tokens.len() {
            return Token {
                kind: TokenKind::TkEof,
                value: "",
                span: Span { file: self.file, start: Position { line: 1, column: 0, offset: 0 }, end: Position { line: 1, column: 0, offset: 0 } }
            }
        }
        self.tokens.get(idx).unwrap_or(Token {
            kind: TokenKind::TkEof,
            value: "",
            span: Span { file: self.file, start: Position { line: 1, column: 0, offset: 0 }, end: Position { line: 1, column: 0, offset: 0 } }
        })
    }

    pub fn advance(mut self) -> Token {
        let tok = self.peek()
        self.pos = self.pos + 1
        tok
    }

    pub fn check(self, kind: TokenKind) -> Bool {
        self.peek().kind == kind
    }

    pub fn try_consume(mut self, kind: TokenKind) -> Bool {
        if self.check(kind) {
            self.advance()
            return true
        }
        false
    }

    pub fn expect(mut self, kind: TokenKind) -> Token {
        let tok = self.peek()
        if tok.kind != kind {
            self.error("Expected '${token_kind_value(kind)}', got '${tok.value}' (${token_kind_value(tok.kind)})")
        }
        self.advance()
    }

    pub fn at_end(self) -> Bool {
        self.check(TokenKind::TkEof)
    }

    // ============================================================
    // Recovery helpers
    // ============================================================

    // Skip tokens until we reach one of the stop tokens at brace depth 0,
    // or an unmatched closing brace. Tracks brace nesting so we don't stop
    // inside a nested block.
    fn skip_to_recovery_point(mut self, stop_tokens: List<TokenKind>) {
        let mut brace_depth = 0
        while !self.at_end() {
            let kind = self.peek().kind
            // Check stop tokens before tracking braces, so that TkLBrace
            // itself can be a stop token (stops at the opening brace).
            if brace_depth == 0 {
                for stop in stop_tokens {
                    if kind == stop { return }
                }
            }
            if kind == TokenKind::TkRBrace {
                if brace_depth == 0 { return }
                brace_depth = brace_depth - 1
            }
            if kind == TokenKind::TkLBrace { brace_depth = brace_depth + 1 }
            self.advance()
        }
    }

    // ============================================================
    // Span helpers
    // ============================================================

    pub fn current_span_start(self) -> Position {
        self.peek().span.start
    }

    pub fn make_span(self, start: Position, end: Position) -> Span {
        Span { file: self.file, start: start, end: end }
    }

    // ============================================================
    // Error helpers
    // ============================================================

    pub fn report_error(mut self, code: Str, msg: Str, span: Span?) {
        let tok = self.peek()
        let error_span = span.unwrap_or(tok.span)
        self.sink.report(make_diag(
            code,
            Severity::SevError,
            msg,
            error_span,
            DiagnosticContext::ParseError { token: tok.value, expected: none }
        ))
        self.error_count = self.error_count + 1
        if (self.error_count >= MAX_ERRORS) {
            __ring_raise_fail("Too many parse errors")
        }
    }

    fn error(mut self, msg: Str) -> Never {
        let tok = self.peek()
        self.report_error(E0103, msg, some(tok.span))
        __ring_raise_fail(msg)
    }

    // ============================================================
    // Program
    // ============================================================

    pub fn parse_program(mut self) -> Program {
        let start = self.current_span_start()
        let mut uses: List<UseDecl> = []
        let mut decls: List<Decl> = []
        let mut decls_started = false

        while !self.at_end() {
            if self.check(TokenKind::TkError) { self.advance(); continue }

            if self.check(TokenKind::TkUse) {
                if decls_started {
                    self.report_error(E0706, "Use declaration must appear before other declarations", some(self.peek().span))
                }
                let use_result: UseDecl? = some(self.parse_use_decl(false)) catch { _ => none }
                match use_result {
                    some(ud) => uses.push(ud),
                    none => {
                        while !self.at_end() {
                            if is_decl_start(self.peek().kind) { break }
                            self.advance()
                        }
                    }
                }
                continue
            }

            if self.check(TokenKind::TkPub) {
                let save_pos = self.pos
                let save_errors = self.error_count
                let sink_checkpoint = self.sink.save()
                self.advance()
                if self.check(TokenKind::TkUse) {
                    if decls_started {
                        self.report_error(E0706, "Use declaration must appear before other declarations", some(self.tokens.get(save_pos).unwrap_or(self.peek()).span))
                    }
                    let pub_use_result: UseDecl? = some(self.parse_use_decl(true)) catch { _ => none }
                    match pub_use_result {
                        some(ud) => uses.push(ud),
                        none => {
                            while !self.at_end() {
                                if is_decl_start(self.peek().kind) { break }
                                self.advance()
                            }
                        }
                    }
                    continue
                }
                self.pos = save_pos
                self.error_count = save_errors
                self.sink.restore(sink_checkpoint)
            }

            decls_started = true
            let maybe_decl: Decl? = self.parse_decl() catch { _ => none }
            match maybe_decl {
                some(decl) => decls.push(decl),
                none => {
                    while !self.at_end() {
                        if is_decl_start(self.peek().kind) { break }
                        self.advance()
                    }
                }
            }
        }
        let end = self.current_span_start()
        Program { uses: uses, decls: decls, span: self.make_span(start, end) }
    }

    // ============================================================
    // Statements
    // ============================================================

    pub fn parse_stmt(mut self) -> Stmt {
        let start = self.current_span_start()

        if self.check(TokenKind::TkLet) {
            // Check for "let mut x = ..." pattern — parse as mutable binding
            if self.peek_at(1).kind == TokenKind::TkMut {
                let bind_start = self.current_span_start()
                self.advance()  // consume 'let'
                self.advance()  // consume 'mut'
                return self.parse_binding_body(true, bind_start)
            }
            let saved_pos = self.pos
            self.advance()
            if self.check(TokenKind::TkLParen) {
                let pattern = self.parse_pattern()
                self.expect(TokenKind::TkEq)
                let init = self.parse_expr()
                self.try_consume(TokenKind::TkSemi)
                let end = self.current_span_start()
                return Stmt::LetDestructure { pattern: pattern, init: init, span: self.make_span(start, end) }
            }
            self.pos = saved_pos
            return self.parse_binding_stmt(false)
        }
        if self.check(TokenKind::TkReturn) {
            return self.parse_return_stmt()
        }
        if self.check(TokenKind::TkIf) {
            let saved_pos = self.pos
            self.advance()
            if self.check(TokenKind::TkLet) {
                return self.parse_if_let_stmt(start)
            }
            self.pos = saved_pos
        }
        if self.check(TokenKind::TkWhile) {
            return self.parse_while_stmt()
        }
        if self.check(TokenKind::TkLoop) {
            return self.parse_loop_stmt()
        }
        if self.check(TokenKind::TkFor) {
            return self.parse_for_in_stmt()
        }
        if self.check(TokenKind::TkBreak) {
            return self.parse_break_stmt()
        }
        if self.check(TokenKind::TkContinue) {
            return self.parse_continue_stmt()
        }

        if self.check(TokenKind::TkTry) {
            self.report_error(E0101, "`try` is a reserved keyword; use `expr catch { pattern => handler }` for error handling", some(self.peek().span))
            self.advance()
            // Skip a block body if present so recovery can continue
            if self.check(TokenKind::TkLBrace) {
                self.advance()
                let mut depth = 1
                while depth > 0 && self.pos < self.tokens.len() - 1 {
                    if self.check(TokenKind::TkLBrace) {
                        depth = depth + 1
                    } else if self.check(TokenKind::TkRBrace) {
                        depth = depth - 1
                    }
                    self.advance()
                }
            }
            let end = self.current_span_start()
            return Stmt::ExprStmt { expr: Expr::IntLit { value: 0, span: self.make_span(start, end) }, has_semi: false, span: self.make_span(start, end) }
        }

        let expr = self.parse_expr()

        if self.check(TokenKind::TkEq) || self.check(TokenKind::TkPlusEq) || self.check(TokenKind::TkMinusEq) || self.check(TokenKind::TkStarEq) || self.check(TokenKind::TkSlashEq) || self.check(TokenKind::TkPercentEq) {
            let op_tok = self.advance()
            let value_expr = self.parse_expr()
            self.try_consume(TokenKind::TkSemi)
            let end = self.current_span_start()

            let mut value = value_expr
            if op_tok.kind == TokenKind::TkPlusEq {
                value = Expr::BinOp { op: BinOp::Add, left: expr, right: value_expr, span: expr_span(value_expr) }
            } else if op_tok.kind == TokenKind::TkMinusEq {
                value = Expr::BinOp { op: BinOp::Sub, left: expr, right: value_expr, span: expr_span(value_expr) }
            } else if op_tok.kind == TokenKind::TkStarEq {
                value = Expr::BinOp { op: BinOp::Mul, left: expr, right: value_expr, span: expr_span(value_expr) }
            } else if op_tok.kind == TokenKind::TkSlashEq {
                value = Expr::BinOp { op: BinOp::Div, left: expr, right: value_expr, span: expr_span(value_expr) }
            } else if op_tok.kind == TokenKind::TkPercentEq {
                value = Expr::BinOp { op: BinOp::Mod, left: expr, right: value_expr, span: expr_span(value_expr) }
            }

            return Stmt::Assign { target: expr, value: value, span: self.make_span(start, end) }
        }

        let has_semi = self.try_consume(TokenKind::TkSemi)
        let end = self.current_span_start()
        Stmt::ExprStmt { expr: expr, has_semi: has_semi, span: self.make_span(start, end) }
    }

    fn parse_while_stmt(mut self) -> Stmt {
        let start = self.current_span_start()
        self.expect(TokenKind::TkWhile)
        let condition = self.parse_expr_no_struct()
        let body = self.parse_block_expr()
        Stmt::While { condition: condition, body: body, span: self.make_span(start, expr_span(body).end) }
    }

    fn parse_loop_stmt(mut self) -> Stmt {
        let start = self.current_span_start()
        self.expect(TokenKind::TkLoop)
        let body = self.parse_block_expr()
        let condition = Expr::BoolLit { value: true, span: self.make_span(start, start) }
        Stmt::While { condition: condition, body: body, span: self.make_span(start, expr_span(body).end) }
    }

    fn parse_for_in_stmt(mut self) -> Stmt {
        let start = self.current_span_start()
        self.expect(TokenKind::TkFor)

        let mut binding = ""
        let mut binding_span = span_zero()
        let mut destructure: DestructureBinding? = none

        if self.check(TokenKind::TkLParen) {
            self.advance()
            let mut names: List<Str> = []
            let mut spans: List<Span> = []
            let first = self.expect(TokenKind::TkIdent)
            names.push(first.value)
            spans.push(first.span)
            while self.try_consume(TokenKind::TkComma) {
                if self.check(TokenKind::TkRParen) { break }
                let tok = self.expect(TokenKind::TkIdent)
                names.push(tok.value)
                spans.push(tok.span)
            }
            self.expect(TokenKind::TkRParen)
            binding = names.first().unwrap_or("")
            binding_span = spans.first().unwrap_or(span_zero())
            if names.len() > 1 {
                destructure = some(DestructureBinding { names: names, spans: spans })
            }
        } else {
            let name_tok = self.expect(TokenKind::TkIdent)
            binding = name_tok.value
            binding_span = name_tok.span
        }

        self.expect(TokenKind::TkIn)
        let iterable = self.parse_expr_no_struct()
        let body = self.parse_block_expr()
        Stmt::ForIn {
            binding: binding,
            binding_span: binding_span,
            destructure: destructure,
            iterable: iterable,
            body: body,
            span: self.make_span(start, expr_span(body).end)
        }
    }

    fn parse_break_stmt(mut self) -> Stmt {
        let start = self.current_span_start()
        self.expect(TokenKind::TkBreak)
        self.try_consume(TokenKind::TkSemi)
        let end = self.current_span_start()
        Stmt::Break { span: self.make_span(start, end) }
    }

    fn parse_continue_stmt(mut self) -> Stmt {
        let start = self.current_span_start()
        self.expect(TokenKind::TkContinue)
        self.try_consume(TokenKind::TkSemi)
        let end = self.current_span_start()
        Stmt::Continue { span: self.make_span(start, end) }
    }

    fn parse_if_let_stmt(mut self, start: Position) -> Stmt {
        self.expect(TokenKind::TkLet)
        let pattern = self.parse_pattern()
        self.expect(TokenKind::TkEq)
        let expr = self.parse_expr()
        let then_block = self.parse_block_expr()
        let mut else_block: Expr? = none
        if self.try_consume(TokenKind::TkElse) {
            else_block = some(self.parse_block_expr())
        }
        let end_pos = match else_block {
            some(eb) => expr_span(eb).end,
            none => expr_span(then_block).end
        }
        Stmt::IfLet {
            pattern: pattern,
            expr: expr,
            then_block: then_block,
            else_block: else_block,
            span: self.make_span(start, end_pos)
        }
    }

    fn parse_binding_stmt(mut self, mutable: Bool) -> Stmt {
        let start = self.current_span_start()
        self.expect(TokenKind::TkLet)
        self.parse_binding_body(mutable, start)
    }

    fn parse_binding_body(mut self, mutable: Bool, start: Position) -> Stmt {
        let name_tok = self.expect(TokenKind::TkIdent)
        let name = name_tok.value
        let name_span = name_tok.span
        let mut type_annotation: TypeExpr? = none
        if self.try_consume(TokenKind::TkColon) {
            type_annotation = some(self.parse_type_expr())
        }
        self.expect(TokenKind::TkEq)
        let init = self.parse_expr()
        self.try_consume(TokenKind::TkSemi)
        let end = self.current_span_start()
        let span = self.make_span(start, end)
        if mutable {
            Stmt::Var { name: name, name_span: name_span, type_annotation: type_annotation, init: init, span: span }
        } else {
            Stmt::Let { name: name, name_span: name_span, type_annotation: type_annotation, init: init, span: span }
        }
    }

    fn parse_return_stmt(mut self) -> Stmt {
        let start = self.current_span_start()
        self.expect(TokenKind::TkReturn)
        let mut value: Expr? = none
        if !self.check(TokenKind::TkSemi) && !self.check(TokenKind::TkRBrace) && !self.at_end() {
            value = some(self.parse_expr())
        }
        self.try_consume(TokenKind::TkSemi)
        let end = self.current_span_start()
        Stmt::Return { value: value, span: self.make_span(start, end) }
    }

    fn parse_return_expr(mut self) -> Expr {
        let start = self.current_span_start()
        self.expect(TokenKind::TkReturn)
        let mut value: Expr? = none
        // In match arm expression position, the return value ends before
        // '}' (end of match / block), ',' (arm separator), or EOF.
        if !self.check(TokenKind::TkRBrace) && !self.check(TokenKind::TkComma) && !self.at_end() {
            value = some(self.parse_expr())
        }
        let end = self.current_span_start()
        Expr::ReturnExpr { value: value, span: self.make_span(start, end) }
    }

    // ============================================================
    // Block expression
    // ============================================================

    pub fn parse_block_expr(mut self) -> Expr {
        let start = self.current_span_start()
        self.expect(TokenKind::TkLBrace)
        let mut stmts: List<Stmt> = []
        let mut tail: Expr? = none

        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            let stmt = self.parse_stmt()

            if self.check(TokenKind::TkRBrace) {
                match stmt {
                    ExprStmt { expr: e, has_semi: hs, .. } => {
                        if !hs { tail = some(e) }
                        else { stmts.push(stmt) }
                    },
                    _ => stmts.push(stmt)
                }
            } else {
                stmts.push(stmt)
            }
        }

        let rbrace = self.expect(TokenKind::TkRBrace)
        Expr::Block { stmts: stmts, tail: tail, span: self.make_span(start, rbrace.span.end) }
    }

    // ============================================================
    // Unsafe block expression
    // ============================================================

    fn parse_unsafe_expr(mut self) -> Expr {
        let start = self.current_span_start()
        self.expect(TokenKind::TkUnsafe)
        let body = self.parse_block_expr()
        Expr::UnsafeBlock { body: body, span: self.make_span(start, expr_span(body).end) }
    }

    // ============================================================
    // Declarations
    // ============================================================

    fn parse_use_decl(mut self, is_pub: Bool) -> UseDecl {
        let start = self.current_span_start()
        self.expect(TokenKind::TkUse)

        let mut segments: List<Str> = []
        let path_start = self.current_span_start()

        // Support super / self as path first segment
        if self.check(TokenKind::TkSuper) {
            segments.push("super")
            let _ = self.advance()
        } else if self.check(TokenKind::TkIdent) && self.peek().value == "self" && self.peek_at(1).kind == TokenKind::TkColonColon {
            segments.push("self")
            let _ = self.advance()
        } else {
            segments.push(self.expect(TokenKind::TkIdent).value)
        }

        while self.check(TokenKind::TkColonColon) {
            self.advance()
            if self.check(TokenKind::TkLBrace) { break }
            // Intermediate segments may also be super (super::super::xxx)
            if self.check(TokenKind::TkSuper) {
                segments.push("super")
                let _ = self.advance()
            } else {
                segments.push(self.expect(TokenKind::TkIdent).value)
            }
        }

        let path_end = self.current_span_start()
        let mut path = UsePath { segments: segments, span: self.make_span(path_start, path_end) }
        let mut imports = UseImport::Module
        let mut alias: Str? = none

        if self.check(TokenKind::TkLBrace) {
            self.advance()
            let mut names: List<NamedImport> = []
            while !self.check(TokenKind::TkRBrace) && !self.at_end() {
                let name_start = self.current_span_start()
                let name = self.expect(TokenKind::TkIdent).value
                let mut name_alias: Str? = none
                if self.try_consume(TokenKind::TkAs) {
                    name_alias = some(self.expect(TokenKind::TkIdent).value)
                }
                let name_end = self.current_span_start()
                names.push(NamedImport { name: name, alias: name_alias, span: self.make_span(name_start, name_end) })
                if !self.try_consume(TokenKind::TkComma) { break }
            }
            self.expect(TokenKind::TkRBrace)
            imports = UseImport::NamedItems { names: names }
        } else if self.check(TokenKind::TkAs) {
            self.advance()
            alias = some(self.expect(TokenKind::TkIdent).value)
            imports = UseImport::Module
        } else if segments.len() > 1 {
            let imported_name = segments.pop().unwrap_or("")
            path = UsePath { segments: segments, span: self.make_span(path_start, path_end) }
            let name_span = self.make_span(path_start, path_end)
            imports = UseImport::NamedItems { names: [NamedImport { name: imported_name, alias: none, span: name_span }] }
        }

        let end = self.current_span_start()
        UseDecl {
            path: path,
            imports: imports,
            alias: alias,
            is_pub: is_pub,
            span: self.make_span(start, end)
        }
    }

    fn parse_mod_block(mut self, is_pub: Bool) -> Decl {
        let start = self.current_span_start()
        self.expect(TokenKind::TkMod)
        let name = self.expect(TokenKind::TkIdent).value

        // Parse optional requires clause: mod name requires { effects } { ... }
        let mut required_effects: List<EffectExpr>? = none
        if self.check(TokenKind::TkRequires) {
            self.advance()
            required_effects = some(self.parse_effect_list())
        }

        self.expect(TokenKind::TkLBrace)
        let mut uses: List<UseDecl> = []
        let mut decls: List<Decl> = []
        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            // Parse use declarations inside mod blocks
            if self.check(TokenKind::TkUse) {
                let use_result: UseDecl? = some(self.parse_use_decl(false)) catch { _ => none }
                match use_result {
                    some(ud) => uses.push(ud),
                    none => {
                        while !self.at_end() {
                            if is_decl_start(self.peek().kind) || self.check(TokenKind::TkUse) || self.check(TokenKind::TkRBrace) { break }
                            self.advance()
                        }
                    }
                }
                continue
            }
            if self.check(TokenKind::TkPub) && self.peek_at(1).kind == TokenKind::TkUse {
                self.advance()
                let use_result: UseDecl? = some(self.parse_use_decl(true)) catch { _ => none }
                match use_result {
                    some(ud) => uses.push(ud),
                    none => {
                        while !self.at_end() {
                            if is_decl_start(self.peek().kind) || self.check(TokenKind::TkRBrace) { break }
                            self.advance()
                        }
                    }
                }
                continue
            }
            let maybe_decl: Decl? = self.parse_decl() catch { _ => none }
            match maybe_decl {
                some(decl) => decls.push(decl),
                none => {
                    while !self.at_end() {
                        if is_decl_start(self.peek().kind) || self.check(TokenKind::TkRBrace) { break }
                        self.advance()
                    }
                }
            }
        }
        let rbrace = self.expect(TokenKind::TkRBrace)
        Decl::ModBlock { name: name, uses: uses, decls: decls, required_effects: required_effects, is_pub: is_pub, span: self.make_span(start, rbrace.span.end) }
    }

    fn parse_decl(mut self) -> Decl? {
        // The declaration range includes every prefix token (`@derive`, then
        // optional `pub`) rather than beginning at `struct` / `enum`.
        let decl_start = self.current_span_start()
        let mut derive_attrs: List<DeriveAttribute> = []
        while self.check(TokenKind::TkAt) {
            let attr_start = self.peek().span.start
            self.advance()
            let attribute = self.expect(TokenKind::TkIdent)
            if attribute.value != "derive" {
                self.error("Unknown declaration attribute '@${attribute.value}'")
            }
            self.expect(TokenKind::TkLParen)
            if self.check(TokenKind::TkRParen) {
                self.error("@derive requires at least one trait name")
            }
            let mut trait_names: List<Str> = [self.parse_qualified_ident()]
            while self.try_consume(TokenKind::TkComma) {
                if self.check(TokenKind::TkRParen) { break }
                trait_names.push(self.parse_qualified_ident())
            }
            let rparen = self.expect(TokenKind::TkRParen)
            let attr_span = self.make_span(attr_start, rparen.span.end)
            for trait_name in trait_names {
                derive_attrs.push(DeriveAttribute {
                    trait_name: trait_name,
                    span: attr_span
                })
            }
        }
        let is_pub = self.try_consume(TokenKind::TkPub)
        let tok = self.peek()
        if derive_attrs.len() > 0 && tok.kind != TokenKind::TkStruct && tok.kind != TokenKind::TkEnum {
            let attr_span = match derive_attrs.get(0) {
                some(attr) => attr.span,
                none => tok.span
            }
            self.report_error(E0101, "@derive is only valid on struct or enum declarations", some(attr_span))
            return none
        }

        match tok.kind {
            TkMod => some(self.parse_mod_block(is_pub)),
            TkFn => some(self.parse_fn_decl(is_pub, false)),
            TkStruct => some(self.parse_struct_decl(decl_start, is_pub, derive_attrs)),
            TkEnum => some(self.parse_enum_decl(decl_start, is_pub, derive_attrs)),
            TkImpl => some(self.parse_impl_decl()),
            TkEffect => some(self.parse_effect_decl(is_pub)),
            TkTest => some(self.parse_test_decl()),
            TkTrait => some(self.parse_trait_decl(is_pub)),
            TkExtern => some(self.parse_extern_decl(is_pub)),
            TkConst => some(self.parse_const_decl(is_pub)),
            TkIdent => {
                if tok.value == "type" { return some(self.parse_type_alias_decl(is_pub)) }
                self.report_error(E0101, "Expected declaration, got '${tok.value}' (${token_kind_value(tok.kind)})", some(tok.span))
                none
            },
            _ => {
                self.report_error(E0101, "Expected declaration, got '${tok.value}' (${token_kind_value(tok.kind)})", some(tok.span))
                none
            }
        }
    }

    // Parse a braced effect list: { effect1, effect2<T>, ... }
    fn parse_effect_list(mut self) -> List<EffectExpr> {
        self.expect(TokenKind::TkLBrace)
        let mut effects: List<EffectExpr> = []
        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            let estart = self.current_span_start()
            // Accept 'mut' and 'unsafe' keywords as effect names
            let mut ename = ""
            if self.check(TokenKind::TkMut) {
                ename = self.advance().value
            } else if self.check(TokenKind::TkUnsafe) {
                ename = self.advance().value
            } else {
                ename = self.expect(TokenKind::TkIdent).value
                // Support qualified paths: mod::effect or mod::submod::effect
                while self.check(TokenKind::TkColonColon) {
                    self.advance()
                    let next = self.expect(TokenKind::TkIdent).value
                    ename = "${ename}::${next}"
                }
            }
            let mut type_args: List<TypeExpr> = []
            if self.check(TokenKind::TkLt) {
                self.advance()
                while !self.check(TokenKind::TkGt) && !self.at_end() {
                    type_args.push(self.parse_type_expr())
                    if !self.check(TokenKind::TkGt) {
                        self.expect(TokenKind::TkComma)
                    }
                }
                self.expect(TokenKind::TkGt)
            }
            let eend = self.current_span_start()
            effects.push(EffectExpr { name: ename, type_args: type_args, span: self.make_span(estart, eend) })
            if !self.check(TokenKind::TkRBrace) {
                self.expect(TokenKind::TkComma)
            }
        }
        self.expect(TokenKind::TkRBrace)
        effects
    }

    fn parse_effect_annotation(mut self) -> List<EffectExpr> {
        self.expect(TokenKind::TkWith)
        self.parse_effect_list()
    }

    fn parse_fn_decl(mut self, is_pub: Bool, body_optional: Bool) -> Decl {
        let start = self.current_span_start()
        self.expect(TokenKind::TkFn)
        let name = self.expect(TokenKind::TkIdent).value
        let type_params = self.parse_type_params()
        self.expect(TokenKind::TkLParen)
        let params = self.parse_params()
        self.expect(TokenKind::TkRParen)
        let mut return_type: TypeExpr? = none
        if self.try_consume(TokenKind::TkArrow) {
            return_type = some(self.parse_type_expr())
        }
        // Parse effect annotation: with { effect1, effect2<T> }
        let mut declared_effects: List<EffectExpr>? = none
        if self.check(TokenKind::TkWith) {
            declared_effects = some(self.parse_effect_annotation())
        }
        let mut body = Expr::Block { stmts: [], tail: none, span: span_zero() }
        let mut is_abstract_val = false
        if body_optional && !self.check(TokenKind::TkLBrace) {
            let pos = self.current_span_start()
            body = Expr::Block { stmts: [], tail: none, span: self.make_span(pos, pos) }
            is_abstract_val = true
        } else {
            body = self.parse_block_expr()
        }
        Decl::Fn {
            name: name,
            type_params: type_params,
            params: params,
            return_type: return_type,
            declared_effects: declared_effects,
            body: body,
            is_pub: is_pub,
            is_abstract: is_abstract_val,
            span: self.make_span(start, expr_span(body).end)
        }
    }

    fn parse_const_decl(mut self, is_pub: Bool) -> Decl {
        let start = self.current_span_start()
        self.expect(TokenKind::TkConst)
        let name = self.expect(TokenKind::TkIdent).value
        let mut type_annotation: TypeExpr? = none
        if self.try_consume(TokenKind::TkColon) {
            type_annotation = some(self.parse_type_expr())
        }
        self.expect(TokenKind::TkEq)
        let init = self.parse_expr()
        Decl::Const { name: name, type_annotation: type_annotation, init: init, is_pub: is_pub, span: self.make_span(start, expr_span(init).end) }
    }

    fn parse_extern_decl(mut self, is_pub: Bool) -> Decl {
        let start = self.current_span_start()
        self.expect(TokenKind::TkExtern)
        if self.check(TokenKind::TkIdent) && self.peek().value == "type" {
            return self.parse_extern_type_decl_body(is_pub, start)
        }
        self.parse_extern_fn_decl_body(is_pub, start)
    }

    fn parse_extern_fn_decl_body(mut self, is_pub: Bool, start: Position) -> Decl {
        self.expect(TokenKind::TkFn)
        let name = self.expect(TokenKind::TkIdent).value
        let type_params = self.parse_type_params()
        self.expect(TokenKind::TkLParen)
        let params = self.parse_params()
        let rparen = self.expect(TokenKind::TkRParen)
        let mut last_end = rparen.span.end
        let mut return_type: TypeExpr? = none
        if self.try_consume(TokenKind::TkArrow) {
            let rt = self.parse_type_expr()
            return_type = some(rt)
            last_end = type_expr_span(rt).end
        }
        // Parse effect annotation: with { effect1, effect2<T> }
        let mut declared_effects: List<EffectExpr>? = none
        if self.check(TokenKind::TkWith) {
            declared_effects = some(self.parse_effect_annotation())
            // parse_effect_annotation ends after consuming '}', use current_span_start as approximation
            last_end = self.current_span_start()
        }
        Decl::ExternFn {
            name: name,
            type_params: type_params,
            params: params,
            return_type: return_type,
            declared_effects: declared_effects,
            is_pub: is_pub,
            span: self.make_span(start, last_end)
        }
    }

    fn parse_extern_type_decl_body(mut self, is_pub: Bool, start: Position) -> Decl {
        self.advance()
        let name = self.expect(TokenKind::TkIdent).value
        let type_params = self.parse_type_params()
        let end = self.current_span_start()
        Decl::ExternType {
            name: name,
            type_params: type_params,
            is_pub: is_pub,
            span: self.make_span(start, end)
        }
    }

    fn parse_type_alias_decl(mut self, is_pub: Bool) -> Decl {
        let start = self.current_span_start()
        self.advance()
        let name = self.expect(TokenKind::TkIdent).value
        let type_params = self.parse_type_params()
        self.expect(TokenKind::TkEq)
        let type_expr = self.parse_type_expr()
        let end = self.current_span_start()
        Decl::TypeAlias {
            name: name,
            type_params: type_params,
            type_expr: type_expr,
            is_pub: is_pub,
            span: self.make_span(start, end)
        }
    }

    fn parse_struct_decl(mut self, start: Position, is_pub: Bool, derive_attrs: List<DeriveAttribute>) -> Decl {
        self.expect(TokenKind::TkStruct)
        let name = self.expect(TokenKind::TkIdent).value
        let type_params = self.parse_type_params()
        self.expect(TokenKind::TkLBrace)
        let mut fields: List<StructFieldDecl> = []
        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            let field_start = self.current_span_start()
            let field_pub = self.try_consume(TokenKind::TkPub)
            let field_name = self.expect(TokenKind::TkIdent).value
            self.expect(TokenKind::TkColon)
            let type_annotation = self.parse_type_expr()
            if self.check(TokenKind::TkWhere) {
                let where_span = self.peek().span
                self.sink.report(make_diag(W0002, Severity::SevWarning,
                    "refinement 'where' clause is parsed but not enforced; it is a documentation-only annotation until refinement types are implemented",
                    where_span,
                    DiagnosticContext::OtherContext { detail: some("where clause parsed but not enforced") }))
                self.advance()
                let mut depth = 0
                while !self.at_end() {
                    if depth == 0 && (self.check(TokenKind::TkComma) || self.check(TokenKind::TkRBrace)) { break }
                    if self.check(TokenKind::TkLParen) || self.check(TokenKind::TkLBrace) || self.check(TokenKind::TkLBracket) {
                        depth = depth + 1
                    }
                    if self.check(TokenKind::TkRParen) || self.check(TokenKind::TkRBrace) || self.check(TokenKind::TkRBracket) {
                        depth = depth - 1
                    }
                    if depth < 0 { break }
                    self.advance()
                }
            }
            let field_end = self.current_span_start()
            fields.push(StructFieldDecl {
                name: field_name,
                type_annotation: type_annotation,
                is_pub: field_pub,
                span: self.make_span(field_start, field_end)
            })
            self.try_consume(TokenKind::TkComma)
        }
        let rbrace = self.expect(TokenKind::TkRBrace)
        Decl::Struct {
            name: name,
            type_params: type_params,
            fields: fields,
            derive_attrs: derive_attrs,
            is_pub: is_pub,
            span: self.make_span(start, rbrace.span.end)
        }
    }

    fn parse_enum_decl(mut self, start: Position, is_pub: Bool, derive_attrs: List<DeriveAttribute>) -> Decl {
        self.expect(TokenKind::TkEnum)
        let name = self.expect(TokenKind::TkIdent).value
        let type_params = self.parse_type_params()
        self.expect(TokenKind::TkLBrace)
        let mut variants: List<EnumVariantDecl> = []
        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            let v_start = self.current_span_start()
            let v_name = self.expect(TokenKind::TkIdent).value
            let mut v_fields: List<TypeExpr> = []
            let mut named_fields: List<NamedEnumField>? = none
            if self.try_consume(TokenKind::TkLParen) {
                if self.check(TokenKind::TkRParen) {
                    // Reject empty parentheses — use bare name instead
                    let rp_span = self.peek().span
                    self.report_error(E0104, "empty parentheses on enum variant '${v_name}' — use bare name instead", some(rp_span))
                    let _rp = self.advance()  // consume ')'
                } else {
                    v_fields.push(self.parse_type_expr())
                    while self.try_consume(TokenKind::TkComma) {
                        if self.check(TokenKind::TkRParen) { break }
                        v_fields.push(self.parse_type_expr())
                    }
                    let _rp = self.expect(TokenKind::TkRParen)
                }
            } else if self.check(TokenKind::TkLBrace) {
                self.advance()
                let mut nf: List<NamedEnumField> = []
                while !self.check(TokenKind::TkRBrace) && !self.at_end() {
                    let f_start = self.current_span_start()
                    let f_name = self.expect(TokenKind::TkIdent).value
                    self.expect(TokenKind::TkColon)
                    let f_type = self.parse_type_expr()
                    let f_end = self.current_span_start()
                    nf.push(NamedEnumField { name: f_name, type_expr: f_type, span: self.make_span(f_start, f_end) })
                    self.try_consume(TokenKind::TkComma)
                }
                self.expect(TokenKind::TkRBrace)
                named_fields = some(nf)
            }
            let v_end = self.current_span_start()
            variants.push(EnumVariantDecl { name: v_name, fields: v_fields, named_fields: named_fields, span: self.make_span(v_start, v_end) })
            self.try_consume(TokenKind::TkComma)
        }
        let rbrace = self.expect(TokenKind::TkRBrace)
        Decl::Enum {
            name: name,
            type_params: type_params,
            variants: variants,
            derive_attrs: derive_attrs,
            is_pub: is_pub,
            span: self.make_span(start, rbrace.span.end)
        }
    }

    fn parse_impl_decl(mut self) -> Decl {
        let start = self.current_span_start()
        self.expect(TokenKind::TkImpl)
        let type_params = self.parse_type_params()
        let first_name = self.parse_qualified_ident()

        let mut target_type = first_name
        let mut trait_name: Str? = none
        if self.check(TokenKind::TkFor) {
            self.advance()
            trait_name = some(first_name)
            target_type = self.parse_qualified_ident()
            // Consume and validate optional type arguments on target type (e.g., ListIterator<T>)
            // These are redundant since the impl's own type_params bind the variables.
            // Each arg must be a type variable declared in the impl's type_params.
            self.validate_target_type_args(type_params)
        }

        self.expect(TokenKind::TkLBrace)
        let mut methods: List<Decl> = []
        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            // Check for delegate before consuming pub
            if self.check(TokenKind::TkIdent) && self.peek().value == "delegate" {
                let d_start = self.current_span_start()
                self.advance()   // consume "delegate"
                let d_field = self.expect(TokenKind::TkIdent).value
                self.expect(TokenKind::TkColon)
                let mut d_traits: List<Str> = []
                d_traits.push(self.expect(TokenKind::TkIdent).value)
                while self.try_consume(TokenKind::TkComma) {
                    d_traits.push(self.expect(TokenKind::TkIdent).value)
                }
                let d_end = self.current_span_start()
                methods.push(Decl::Delegate { field: d_field, trait_names: d_traits, span: self.make_span(d_start, d_end) })
                continue
            }
            let m_pub = self.try_consume(TokenKind::TkPub)
            // Check for associated type: `type Name = TypeExpr`
            if self.check(TokenKind::TkIdent) && self.peek().value == "type" {
                methods.push(self.parse_assoc_type_decl(m_pub))
            } else if self.check(TokenKind::TkExtern) {
                let m_start = self.current_span_start()
                self.expect(TokenKind::TkExtern)
                methods.push(self.parse_extern_fn_decl_body(m_pub, m_start))
            } else {
                methods.push(self.parse_fn_decl(m_pub, false))
            }
        }
        let rbrace = self.expect(TokenKind::TkRBrace)
        Decl::Impl {
            target_type: target_type,
            type_params: type_params,
            trait_name: trait_name,
            methods: methods,
            span: self.make_span(start, rbrace.span.end)
        }
    }

    fn parse_effect_alias_decl(mut self, is_pub: Bool, start: Position) -> Decl {
        // 'effect alias' has been consumed; now parse: Name<T> = { effects }
        let name = self.expect(TokenKind::TkIdent).value
        let type_params = self.parse_type_params()
        self.expect(TokenKind::TkEq)
        let effects = self.parse_effect_list()
        let end = self.current_span_start()
        Decl::EffectAlias {
            name: name,
            type_params: type_params,
            effects: effects,
            is_pub: is_pub,
            span: self.make_span(start, end)
        }
    }

    fn parse_effect_decl(mut self, is_pub: Bool) -> Decl {
        let start = self.current_span_start()
        self.expect(TokenKind::TkEffect)
        let name = self.expect(TokenKind::TkIdent).value
        if name == "alias" {
            return self.parse_effect_alias_decl(is_pub, start)
        }
        let type_params = self.parse_type_params()
        self.expect(TokenKind::TkLBrace)
        let mut ops: List<EffectOpDecl> = []
        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            let op_start = self.current_span_start()
            self.expect(TokenKind::TkFn)
            let op_name = self.expect(TokenKind::TkIdent).value
            self.expect(TokenKind::TkLParen)
            let params = self.parse_params()
            self.expect(TokenKind::TkRParen)
            self.expect(TokenKind::TkArrow)
            let return_type = self.parse_type_expr()
            let mut op_body: Expr? = none
            if self.check(TokenKind::TkLBrace) {
                op_body = some(self.parse_block_expr())
            }
            let op_end = self.current_span_start()
            ops.push(EffectOpDecl { name: op_name, params: params, return_type: return_type, body: op_body, span: self.make_span(op_start, op_end) })
            self.try_consume(TokenKind::TkComma)
            self.try_consume(TokenKind::TkSemi)
        }
        let rbrace = self.expect(TokenKind::TkRBrace)
        Decl::Effect {
            name: name,
            type_params: type_params,
            ops: ops,
            is_pub: is_pub,
            span: self.make_span(start, rbrace.span.end)
        }
    }

    fn parse_test_decl(mut self) -> Decl {
        let start = self.current_span_start()
        self.expect(TokenKind::TkTest)
        let desc_tok = self.expect(TokenKind::TkStringLit)
        let body = self.parse_block_expr()
        Decl::Test { description: desc_tok.value, body: body, span: self.make_span(start, expr_span(body).end) }
    }

    fn parse_assoc_type_decl(mut self, is_pub: Bool) -> Decl {
        let start = self.current_span_start()
        self.advance()  // consume 'type' keyword (TkIdent with value "type")
        let name = self.expect(TokenKind::TkIdent).value
        // Optional bounds: `: Trait1 + Trait2`
        let mut bounds: List<TypeBound> = []
        if self.try_consume(TokenKind::TkColon) {
            bounds.push(self.parse_type_bound())
            while self.check(TokenKind::TkPlus) {
                self.advance()
                bounds.push(self.parse_type_bound())
            }
        }
        // Optional value: `= TypeExpr`
        let mut value: TypeExpr? = none
        if self.try_consume(TokenKind::TkEq) {
            value = some(self.parse_type_expr())
        }
        let end = self.current_span_start()
        Decl::AssocType { name: name, bounds: bounds, value: value, is_pub: is_pub, span: self.make_span(start, end) }
    }

    fn parse_trait_decl(mut self, is_pub: Bool) -> Decl {
        let start = self.current_span_start()
        self.expect(TokenKind::TkTrait)
        let name = self.expect(TokenKind::TkIdent).value
        let type_params = self.parse_type_params()
        let mut supertraits: List<TypeBound> = []
        if self.try_consume(TokenKind::TkColon) {
            supertraits.push(self.parse_type_bound())
            while self.check(TokenKind::TkPlus) {
                self.advance()
                supertraits.push(self.parse_type_bound())
            }
        }
        self.expect(TokenKind::TkLBrace)
        let mut methods: List<Decl> = []
        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            let m_pub = self.try_consume(TokenKind::TkPub)
            // Check for associated type declaration: `type Name`
            if self.check(TokenKind::TkIdent) && self.peek().value == "type" {
                methods.push(self.parse_assoc_type_decl(m_pub))
            } else {
                methods.push(self.parse_fn_decl(m_pub, true))
            }
        }
        let rbrace = self.expect(TokenKind::TkRBrace)
        Decl::Trait {
            name: name,
            type_params: type_params,
            supertraits: supertraits,
            methods: methods,
            is_pub: is_pub,
            span: self.make_span(start, rbrace.span.end)
        }
    }

    // ============================================================
    // Expressions — Pratt Parsing
    // ============================================================

    pub fn parse_expr(mut self) -> Expr {
        self.parse_expr_bp(PREC_NONE, true)
    }

    fn parse_expr_no_struct(mut self) -> Expr {
        self.parse_expr_bp(PREC_NONE, false)
    }

    pub fn parse_expr_bp(mut self, min_prec: Int, allow_struct_lit: Bool) -> Expr {
        let mut left = self.parse_prefix(allow_struct_lit)
        let mut last_was_comparison = false

        while true {
            let tok = self.peek()
            let prec = infix_precedence(tok.kind)
            if prec <= min_prec { break }

            if self.check(TokenKind::TkCatch) {
                left = self.parse_catch_expr(left)
                last_was_comparison = false
            } else if self.check(TokenKind::TkDot) {
                left = self.parse_dot_expr(left)
                last_was_comparison = false
            } else if self.check(TokenKind::TkLParen) {
                if tok.span.start.line > expr_span(left).end.line { break }
                left = self.parse_call_expr(left)
                last_was_comparison = false
            } else if self.check(TokenKind::TkLBracket) {
                if tok.span.start.line > expr_span(left).end.line { break }
                left = self.parse_index_expr(left)
                last_was_comparison = false
            } else if self.check(TokenKind::TkDotDot) || self.check(TokenKind::TkDotDotEq) {
                let inclusive = self.check(TokenKind::TkDotDotEq)
                self.advance()
                let right = self.parse_expr_bp(prec, allow_struct_lit)
                let span = self.make_span(expr_span(left).start, expr_span(right).end)
                left = Expr::Range { start: left, end: right, inclusive: inclusive, span: span }
                last_was_comparison = false
            } else {
                let is_comparison = prec == PREC_EQUALITY || prec == PREC_COMPARE
                if is_comparison && last_was_comparison {
                    self.error("Comparison operators are non-associative: cannot chain '${tok.value}' after another comparison")
                }
                self.advance()
                let right = self.parse_expr_bp(prec, allow_struct_lit)
                let span = self.make_span(expr_span(left).start, expr_span(right).end)
                left = Expr::BinOp { op: str_to_binop(tok.value), left: left, right: right, span: span }
                last_was_comparison = is_comparison
            }
        }

        left
    }

    fn parse_prefix(mut self, allow_struct_lit: Bool) -> Expr {
        let tok = self.peek()
        let start = self.current_span_start()

        if self.check(TokenKind::TkMinus) || self.check(TokenKind::TkBang) {
            self.advance()
            let operand = self.parse_expr_bp(PREC_UNARY, allow_struct_lit)
            return Expr::UnaryOp { op: str_to_unaryop(tok.value), operand: operand, span: self.make_span(start, expr_span(operand).end) }
        }
if self.check(TokenKind::TkIntLit) {
            self.advance()
            return Expr::IntLit { value: parse_int(tok.value).unwrap_or(0), span: tok.span }
        }
        if self.check(TokenKind::TkFloatLit) {
            self.advance()
            return Expr::FloatLit { value: parse_float(tok.value).unwrap_or(0.0), span: tok.span }
        }
        if self.check(TokenKind::TkStringLit) {
            self.advance()
            return Expr::StrLit { value: tok.value, span: tok.span }
        }
        if self.check(TokenKind::TkRawStringLit) {
            self.advance()
            return Expr::StrLit { value: tok.value, span: tok.span }
        }
        if self.check(TokenKind::TkTrue) {
            self.advance()
            return Expr::BoolLit { value: true, span: tok.span }
        }
        if self.check(TokenKind::TkFalse) {
            self.advance()
            return Expr::BoolLit { value: false, span: tok.span }
        }
        if self.check(TokenKind::TkStringInterpStart) {
            return self.parse_string_interp()
        }
        if self.check(TokenKind::TkUnsafe) {
            return self.parse_unsafe_expr()
        }
        if self.check(TokenKind::TkLBrace) {
            return self.parse_block_expr()
        }
        if self.check(TokenKind::TkIf) {
            return self.parse_if_expr()
        }
        if self.check(TokenKind::TkMatch) {
            return self.parse_match_expr()
        }
        if self.check(TokenKind::TkHandle) {
            return self.parse_handle_expr()
        }
        if self.check(TokenKind::TkFn) {
            return self.parse_lambda_expr()
        }
        if self.check(TokenKind::TkLBracket) {
            self.advance()
            let mut elements: List<Expr> = []
            if !self.check(TokenKind::TkRBracket) {
                elements.push(self.parse_expr())
                while self.check(TokenKind::TkComma) {
                    self.advance()
                    if self.check(TokenKind::TkRBracket) { break }
                    elements.push(self.parse_expr())
                }
            }
            let end_tok = self.expect(TokenKind::TkRBracket)
            return Expr::ListLit { elements: elements, span: self.make_span(start, end_tok.span.end) }
        }
        if self.check(TokenKind::TkLParen) {
            self.advance()
            // () — unit literal (0-element tuple)
            if self.check(TokenKind::TkRParen) {
                let end_tok = self.advance()
                return Expr::TupleLit { elements: [], span: self.make_span(start, end_tok.span.end) }
            }
            let first = self.parse_expr()
            if self.check(TokenKind::TkComma) {
                self.advance()
                let mut elements = [first]
                if !self.check(TokenKind::TkRParen) {
                    elements.push(self.parse_expr())
                    while self.check(TokenKind::TkComma) {
                        self.advance()
                        if self.check(TokenKind::TkRParen) { break }
                        elements.push(self.parse_expr())
                    }
                }
                let end_tok = self.expect(TokenKind::TkRParen)
                return Expr::TupleLit { elements: elements, span: self.make_span(start, end_tok.span.end) }
            }
            self.expect(TokenKind::TkRParen)
            return first
        }
        // super::name — relative path expression access
        if self.check(TokenKind::TkSuper) {
            self.advance()
            self.expect(TokenKind::TkColonColon)
            // Support super::super::... chained
            let mut qualifier_parts: List<Str> = ["super"]
            while self.check(TokenKind::TkSuper) {
                qualifier_parts.push("super")
                self.advance()
                self.expect(TokenKind::TkColonColon)
            }
            let member_tok = self.expect(TokenKind::TkIdent)
            let member_name = member_tok.value
            let qualifier_str = qualifier_parts.join("::")

            if allow_struct_lit && is_uppercase(member_name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkLBrace) {
                return self.parse_struct_literal(member_name, start, some(qualifier_str))
            }

            return Expr::Ident { name: member_name, qualifier: some(qualifier_str), span: self.make_span(start, member_tok.span.end) }
        }
        if self.check(TokenKind::TkIdent) {
            self.advance()
            let name = tok.value
            if is_uppercase(name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkColonColon) {
                self.advance()
                let variant_tok = self.expect(TokenKind::TkIdent)
                let variant_name = variant_tok.value

                if allow_struct_lit && is_uppercase(variant_name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkLBrace) {
                    return self.parse_struct_literal(variant_name, start, some(name))
                }

                return Expr::Ident { name: variant_name, qualifier: some(name), span: self.make_span(start, variant_tok.span.end) }
            }

            // Module-qualified access: mod::submod::...::member (lowercase qualifier chain)
            // Also handles self::member for relative paths
            if !is_uppercase(name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkColonColon) {
                let mut qualifier_parts: List<Str> = [name]
                let mut member_tok = tok
                let mut member_name = name
                // Consume chains of lowercase::lowercase::... to build the qualifier
                while self.check(TokenKind::TkColonColon) {
                    self.advance()
                    member_tok = self.expect(TokenKind::TkIdent)
                    member_name = member_tok.value
                    if !is_uppercase(member_name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkColonColon) {
                        // Another mod segment, continue building qualifier
                        qualifier_parts.push(member_name)
                    } else {
                        // Final member (uppercase type/enum or lowercase function/const)
                        break
                    }
                }
                let qualifier_str = qualifier_parts.join("::")

                // Check for Enum::Variant pattern: qualifier::Enum::Variant
                if is_uppercase(member_name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkColonColon) {
                    self.advance()
                    let variant_tok = self.expect(TokenKind::TkIdent)
                    let variant_name = variant_tok.value
                    let full_qualifier = "${qualifier_str}::${member_name}"

                    if allow_struct_lit && is_uppercase(variant_name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkLBrace) {
                        return self.parse_struct_literal(variant_name, start, some(full_qualifier))
                    }

                    return Expr::Ident { name: variant_name, qualifier: some(full_qualifier), span: self.make_span(start, variant_tok.span.end) }
                }

                if allow_struct_lit && is_uppercase(member_name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkLBrace) {
                    return self.parse_struct_literal(member_name, start, some(qualifier_str))
                }

                return Expr::Ident { name: member_name, qualifier: some(qualifier_str), span: self.make_span(start, member_tok.span.end) }
            }

            if allow_struct_lit && is_uppercase(name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkLBrace) {
                return self.parse_struct_literal(name, start, none)
            }
            return Expr::Ident { name: name, qualifier: none, span: tok.span }
        }

        self.error("Unexpected token '${tok.value}' (${token_kind_value(tok.kind)}) in expression")
    }

    // ============================================================
    // Postfix: dot (field access / method call)
    // ============================================================

    fn parse_dot_expr(mut self, left: Expr) -> Expr {
        self.advance()
        let mut name = ""
        let mut name_end = self.current_span_start()
        // Handle float literal after dot: e.g. `t.0.1` lexes as dot + float "0.1"
        // Split into chained tuple field accesses
        if self.check(TokenKind::TkFloatLit) {
            let tok = self.advance()
            let parts = tok.value.split(".")
            let mut result = left
            for part in parts {
                result = Expr::FieldAccess { receiver: result, field: part, span: self.make_span(expr_span(left).start, tok.span.end) }
            }
            return result
        }
        if self.check(TokenKind::TkIntLit) {
            let tok = self.advance()
            name = tok.value
            name_end = tok.span.end
        } else {
            let tok = self.expect(TokenKind::TkIdent)
            name = tok.value
            name_end = tok.span.end
        }

        if self.check(TokenKind::TkLParen) {
            self.advance()
            let args = self.parse_arg_list()
            let rparen = self.expect(TokenKind::TkRParen)
            return Expr::MethodCall {
                receiver: left,
                method: name,
                args: args,
                type_args: [],
                span: self.make_span(expr_span(left).start, rparen.span.end)
            }
        }

        Expr::FieldAccess { receiver: left, field: name, span: self.make_span(expr_span(left).start, name_end) }
    }

    // ============================================================
    // Index expression: receiver[index]
    // ============================================================

    fn parse_index_expr(mut self, receiver: Expr) -> Expr {
        self.advance() // consume [
        let index = self.parse_expr()
        let end_tok = self.expect(TokenKind::TkRBracket)
        let span = self.make_span(expr_span(receiver).start, end_tok.span.end)
        Expr::IndexExpr { receiver: receiver, index: index, span: span }
    }

    // ============================================================
    // Call expression
    // ============================================================

    fn parse_call_expr(mut self, left: Expr) -> Expr {
        self.advance()
        let args = self.parse_arg_list()
        let rparen = self.expect(TokenKind::TkRParen)
        Expr::Call { callee: left, args: args, type_args: [], span: self.make_span(expr_span(left).start, rparen.span.end) }
    }

    fn parse_arg_list(mut self) -> List<Expr> {
        let mut args: List<Expr> = []
        if self.check(TokenKind::TkRParen) { return args }
        args.push(self.parse_expr())
        while self.try_consume(TokenKind::TkComma) {
            if self.check(TokenKind::TkRParen) { break }
            args.push(self.parse_expr())
        }
        args
    }

    // ============================================================
    // Catch expression
    // ============================================================

    fn parse_catch_expr(mut self, left: Expr) -> Expr {
        self.advance()
        self.expect(TokenKind::TkLBrace)
        let mut arms: List<MatchArm> = []
        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            arms.push(self.parse_match_arm())
            self.try_consume(TokenKind::TkComma)
        }
        let end_tok = self.expect(TokenKind::TkRBrace)
        let span = self.make_span(expr_span(left).start, end_tok.span.end)
        Expr::CatchExpr { expr: left, arms: arms, span: span }
    }

    // ============================================================
    // String interpolation
    // ============================================================

    fn parse_string_interp(mut self) -> Expr {
        let start_tok = self.advance()
        let mut parts: List<StringInterpPart> = []
        let mut last_end = start_tok.span.end

        if start_tok.value.len() > 0 {
            parts.push(StringInterpPart::LitPart(start_tok.value))
        }

        parts.push(StringInterpPart::ExprPart(self.parse_expr()))

        while true {
            let tok = self.peek()
            if self.check(TokenKind::TkStringInterpMiddle) {
                self.advance()
                last_end = tok.span.end
                if tok.value.len() > 0 {
                    parts.push(StringInterpPart::LitPart(tok.value))
                }
                parts.push(StringInterpPart::ExprPart(self.parse_expr()))
            } else if self.check(TokenKind::TkStringInterpEnd) {
                self.advance()
                last_end = tok.span.end
                if tok.value.len() > 0 {
                    parts.push(StringInterpPart::LitPart(tok.value))
                }
                break
            } else {
                break
            }
        }

        Expr::StringInterp { parts: parts, span: self.make_span(start_tok.span.start, last_end) }
    }

    // ============================================================
    // If expression
    // ============================================================

    pub fn parse_if_expr(mut self) -> Expr {
        let start = self.current_span_start()
        self.expect(TokenKind::TkIf)

        // Try parsing condition; on failure, skip to '{' and use a dummy
        let cond_result: Expr? = some(self.parse_expr_no_struct()) catch { _ => none }
        let condition = match cond_result {
            some(c) => c,
            none => {
                self.skip_to_recovery_point([TokenKind::TkLBrace])
                dummy_expr()
            }
        }

        // Try parsing then branch; on failure, skip to 'else' or next decl
        let then_result: Expr? = some(self.parse_block_expr()) catch { _ => none }
        let then_branch = match then_result {
            some(t) => t,
            none => {
                self.skip_to_recovery_point([TokenKind::TkElse])
                Expr::Block { stmts: [], tail: none, span: self.make_span(start, self.current_span_start()) }
            }
        }

        let mut else_branch: Expr? = none
        if self.try_consume(TokenKind::TkElse) {
            if self.check(TokenKind::TkIf) {
                let else_result: Expr? = some(self.parse_if_expr()) catch { _ => none }
                match else_result {
                    some(e) => { else_branch = some(e) },
                    none => {
                        self.skip_to_recovery_point([])
                    }
                }
            } else {
                let else_result: Expr? = some(self.parse_block_expr()) catch { _ => none }
                match else_result {
                    some(e) => { else_branch = some(e) },
                    none => {
                        self.skip_to_recovery_point([])
                    }
                }
            }
        }
        let end_pos = match else_branch {
            some(eb) => expr_span(eb).end,
            none => expr_span(then_branch).end
        }
        Expr::IfExpr { condition: condition, then_branch: then_branch, else_branch: else_branch, span: self.make_span(start, end_pos) }
    }

    // ============================================================
    // Match expression
    // ============================================================

    fn parse_match_expr(mut self) -> Expr {
        let start = self.current_span_start()
        self.expect(TokenKind::TkMatch)
        let scrutinee = self.parse_expr_no_struct()
        self.expect(TokenKind::TkLBrace)
        let mut arms: List<MatchArm> = []
        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            let arm_result: MatchArm? = some(self.parse_match_arm()) catch { _ => none }
            match arm_result {
                some(arm) => arms.push(arm),
                none => {
                    // Skip to next comma (arm separator), or closing brace
                    self.skip_to_recovery_point([TokenKind::TkComma])
                }
            }
            self.try_consume(TokenKind::TkComma)
        }
        let rbrace = self.expect(TokenKind::TkRBrace)
        Expr::MatchExpr { scrutinee: scrutinee, arms: arms, span: self.make_span(start, rbrace.span.end) }
    }

    fn parse_match_arm(mut self) -> MatchArm {
        let start = self.current_span_start()
        let mut pattern = self.parse_pattern()

        // Or-pattern: pat1 | pat2 | ... => body
        if self.check(TokenKind::TkPipe) {
            let mut patterns: List<Pattern> = [pattern]
            while self.try_consume(TokenKind::TkPipe) {
                patterns.push(self.parse_pattern())
            }
            let end = pattern_span(patterns.get(patterns.len() - 1).unwrap())
            pattern = Pattern::OrPattern { patterns: patterns, span: self.make_span(start, end.end) }
        }

        let mut guard: Expr? = none
        if self.check(TokenKind::TkIf) {
            self.advance()
            guard = some(self.parse_expr())
        }
        self.expect(TokenKind::TkFatArrow)
        let body = if self.check(TokenKind::TkReturn) {
            self.parse_return_expr()
        } else {
            self.parse_expr()
        }
        MatchArm { pattern: pattern, guard: guard, body: body, span: self.make_span(start, expr_span(body).end) }
    }

    // ============================================================
    // Patterns
    // ============================================================

    pub fn parse_pattern(mut self) -> Pattern {
        let tok = self.peek()
        let start = self.current_span_start()

        if self.check(TokenKind::TkIdent) && tok.value == "_" {
            self.advance()
            return Pattern::Wildcard { span: tok.span }
        }

        // Negative numeric literal patterns: -1, -3.14
        if self.check(TokenKind::TkMinus) {
            let next = self.peek_at(1)
            if next.kind == TokenKind::TkIntLit {
                self.advance()  // consume '-'
                self.advance()  // consume int literal
                return Pattern::Literal { value: LiteralValue::IntVal(0 - parse_int(next.value).unwrap_or(0)), span: self.make_span(start, next.span.end) }
            }
            if next.kind == TokenKind::TkFloatLit {
                self.advance()  // consume '-'
                self.advance()  // consume float literal
                return Pattern::Literal { value: LiteralValue::FloatVal(0.0 - parse_float(next.value).unwrap_or(0.0)), span: self.make_span(start, next.span.end) }
            }
        }

        if self.check(TokenKind::TkIntLit) {
            self.advance()
            return Pattern::Literal { value: LiteralValue::IntVal(parse_int(tok.value).unwrap_or(0)), span: tok.span }
        }
        if self.check(TokenKind::TkFloatLit) {
            self.advance()
            return Pattern::Literal { value: LiteralValue::FloatVal(parse_float(tok.value).unwrap_or(0.0)), span: tok.span }
        }
        if self.check(TokenKind::TkStringLit) {
            self.advance()
            return Pattern::Literal { value: LiteralValue::StrVal(tok.value), span: tok.span }
        }
        if self.check(TokenKind::TkTrue) {
            self.advance()
            return Pattern::Literal { value: LiteralValue::BoolVal(true), span: tok.span }
        }
        if self.check(TokenKind::TkFalse) {
            self.advance()
            return Pattern::Literal { value: LiteralValue::BoolVal(false), span: tok.span }
        }

        if self.check(TokenKind::TkIdent) {
            self.advance()
            let mut name = tok.value
            let mut qualifier: Str? = none

            // Module-qualified enum pattern: mod::submod::...::Enum::Variant(...)
            if !is_uppercase(name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkColonColon) {
                let mut qual_parts: List<Str> = [name]
                let mut next_name = name
                // Consume chains of lowercase segments
                while self.check(TokenKind::TkColonColon) {
                    self.advance()
                    let next_tok = self.expect(TokenKind::TkIdent)
                    next_name = next_tok.value
                    if !is_uppercase(next_name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkColonColon) {
                        qual_parts.push(next_name)
                    } else {
                        break
                    }
                }
                let qual_str = qual_parts.join("::")
                if is_uppercase(next_name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkColonColon) {
                    self.advance()
                    let variant_tok = self.expect(TokenKind::TkIdent)
                    qualifier = some("${qual_str}::${next_name}")
                    name = variant_tok.value
                } else {
                    qualifier = some(qual_str)
                    name = next_name
                }
            }

            // Enum::Variant pattern
            if is_uppercase(name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkColonColon) {
                self.advance()
                let variant_tok = self.expect(TokenKind::TkIdent)
                qualifier = some(match qualifier { some(q) => "${q}::${name}", none => name })
                name = variant_tok.value
            }

            if self.check(TokenKind::TkLParen) {
                self.advance()
                let mut fields: List<Pattern> = []
                if !self.check(TokenKind::TkRParen) {
                    fields.push(self.parse_pattern())
                    while self.try_consume(TokenKind::TkComma) {
                        if self.check(TokenKind::TkRParen) { break }
                        fields.push(self.parse_pattern())
                    }
                }
                let rparen = self.expect(TokenKind::TkRParen)
                return Pattern::Constructor { name: name, qualifier: qualifier, fields: fields, span: self.make_span(start, rparen.span.end) }
            }

            if self.check(TokenKind::TkLBrace) && is_uppercase(name.char_at(0).unwrap_or("")) {
                self.advance()
                let mut named_fields: List<NamedPatternField> = []
                let mut rest = false
                while !self.check(TokenKind::TkRBrace) && !self.at_end() {
                    if self.check(TokenKind::TkDotDot) {
                        self.advance()
                        rest = true
                        self.try_consume(TokenKind::TkComma)
                        break
                    }
                    let f_start = self.current_span_start()
                    let f_tok = self.expect(TokenKind::TkIdent)
                    let f_name = f_tok.value
                    let mut pat = Pattern::Binding { name: f_name, span: f_tok.span }
                    if self.try_consume(TokenKind::TkColon) {
                        pat = self.parse_pattern()
                    }
                    let f_end = self.current_span_start()
                    named_fields.push(NamedPatternField { name: f_name, pattern: pat, span: self.make_span(f_start, f_end) })
                    self.try_consume(TokenKind::TkComma)
                }
                let rbrace = self.expect(TokenKind::TkRBrace)
                return Pattern::NamedConstructor { name: name, qualifier: qualifier, fields: named_fields, rest: rest, span: self.make_span(start, rbrace.span.end) }
            }

            if qualifier.is_some() {
                return Pattern::Constructor { name: name, qualifier: qualifier, fields: [], span: self.make_span(start, self.current_span_start()) }
            }

            return Pattern::Binding { name: name, span: tok.span }
        }

        if self.check(TokenKind::TkLParen) {
            self.advance()
            let first = self.parse_pattern()
            if !self.check(TokenKind::TkComma) {
                self.error("Expected ',' in tuple pattern - single-element tuple patterns not supported")
            }
            self.advance()
            let mut elements = [first]
            if !self.check(TokenKind::TkRParen) {
                elements.push(self.parse_pattern())
                while self.try_consume(TokenKind::TkComma) {
                    if self.check(TokenKind::TkRParen) { break }
                    elements.push(self.parse_pattern())
                }
            }
            let end_tok = self.expect(TokenKind::TkRParen)
            return Pattern::TuplePattern { elements: elements, span: self.make_span(start, end_tok.span.end) }
        }

        self.error("Unexpected token '${tok.value}' in pattern")
    }

    // ============================================================
    // Handle expression
    // ============================================================

    fn parse_handle_expr(mut self) -> Expr {
        let start = self.current_span_start()
        self.expect(TokenKind::TkHandle)
        let body = self.parse_block_expr()
        self.expect(TokenKind::TkWith)
        self.expect(TokenKind::TkLBrace)
        let mut handlers: List<EffectHandler> = []
        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            let handler_result: EffectHandler? = some(self.parse_effect_handler()) catch { _ => none }
            match handler_result {
                some(h) => handlers.push(h),
                none => {
                    // Skip to next comma (handler separator), or closing brace
                    self.skip_to_recovery_point([TokenKind::TkComma])
                }
            }
            self.try_consume(TokenKind::TkComma)
        }
        let rbrace = self.expect(TokenKind::TkRBrace)
        Expr::HandleExpr { body: body, handlers: handlers, span: self.make_span(start, rbrace.span.end) }
    }

    fn parse_effect_handler(mut self) -> EffectHandler {
        let start = self.current_span_start()
        let mut effect_name = self.expect(TokenKind::TkIdent).value
        // Support qualified paths: mod::effect or mod::submod::effect
        while self.check(TokenKind::TkColonColon) {
            self.advance()
            let next = self.expect(TokenKind::TkIdent).value
            effect_name = "${effect_name}::${next}"
        }
        self.expect(TokenKind::TkDot)
        let op_name = self.expect(TokenKind::TkIdent).value
        self.expect(TokenKind::TkLParen)
        let params = self.parse_params()
        self.expect(TokenKind::TkRParen)
        self.expect(TokenKind::TkFatArrow)
        let body = self.parse_expr()
        EffectHandler { effect_name: effect_name, op_name: op_name, params: params, resume_name: none, body: body, span: self.make_span(start, expr_span(body).end) }
    }

    // ============================================================
    // Lambda expression
    // ============================================================

    fn parse_lambda_expr(mut self) -> Expr {
        let start = self.current_span_start()
        self.expect(TokenKind::TkFn)
        self.expect(TokenKind::TkLParen)
        let params = self.parse_params()
        self.expect(TokenKind::TkRParen)
        let mut return_type: TypeExpr? = none
        if self.try_consume(TokenKind::TkArrow) {
            return_type = some(self.parse_type_expr())
        }
        let body = self.parse_block_expr()
        Expr::Lambda { params: params, return_type: return_type, body: body, span: self.make_span(start, expr_span(body).end) }
    }

    // ============================================================
    // Struct literal
    // ============================================================

    fn parse_struct_literal(mut self, name: Str, start: Position, qualifier: Str?) -> Expr {
        self.expect(TokenKind::TkLBrace)
        let mut fields: List<StructFieldInit> = []
        let mut spread: Expr? = none
        if self.check(TokenKind::TkDotDot) {
            self.advance()
            spread = some(self.parse_expr())
            self.try_consume(TokenKind::TkComma)
        }
        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            let f_start = self.current_span_start()
            let f_tok = self.expect(TokenKind::TkIdent)
            let f_name = f_tok.value
            let mut f_value = Expr::Ident { name: f_name, qualifier: none, span: f_tok.span }
            if self.try_consume(TokenKind::TkColon) {
                f_value = self.parse_expr()
            }
            let f_end = expr_span(f_value).end
            fields.push(StructFieldInit { name: f_name, value: f_value, span: self.make_span(f_start, f_end) })
            self.try_consume(TokenKind::TkComma)
        }
        let rbrace = self.expect(TokenKind::TkRBrace)
        Expr::StructLit {
            name: name,
            qualifier: qualifier,
            type_args: [],
            fields: fields,
            spread: spread,
            span: self.make_span(start, rbrace.span.end)
        }
    }

    // ============================================================
    // Type Expressions
    // ============================================================

    pub fn try_parse_type_args(mut self) -> List<TypeExpr> {
        if !self.check(TokenKind::TkLt) { return [] }
        let save_pos = self.pos
        let save_errors = self.error_count
        let sink_checkpoint = self.sink.save()
        self.advance()
        let mut args: List<TypeExpr> = []
        args.push(self.parse_type_expr())
        while self.try_consume(TokenKind::TkComma) {
            args.push(self.parse_type_expr())
        }
        if !self.check(TokenKind::TkGt) {
            self.pos = save_pos
            self.error_count = save_errors
            self.sink.restore(sink_checkpoint)
            return []
        }
        self.advance()
        args
    }

    pub fn parse_type_expr(mut self) -> TypeExpr {
        let start = self.current_span_start()

        if self.check(TokenKind::TkLBrace) {
            return self.parse_record_type_expr()
        }

        if self.check(TokenKind::TkFn) {
            self.advance()
            self.expect(TokenKind::TkLParen)
            let mut params: List<TypeExpr> = []
            if !self.check(TokenKind::TkRParen) {
                params.push(self.parse_type_expr())
                while self.try_consume(TokenKind::TkComma) {
                    if self.check(TokenKind::TkRParen) { break }
                    params.push(self.parse_type_expr())
                }
            }
            self.expect(TokenKind::TkRParen)
            self.expect(TokenKind::TkArrow)
            let return_type = self.parse_type_expr()
            let mut fn_end = type_expr_span(return_type).end
            let mut fn_effects: List<EffectExpr> = []
            if self.check(TokenKind::TkWith) {
                fn_effects = self.parse_effect_annotation()
                // parse_effect_annotation ends after consuming '}', use current_span_start as approximation
                fn_end = self.current_span_start()
            }
            return TypeExpr::FnType { params: params, return_type: return_type, effects: fn_effects, span: self.make_span(start, fn_end) }
        }

        if self.check(TokenKind::TkLParen) {
            self.advance()
            let first = self.parse_type_expr()
            if self.check(TokenKind::TkComma) {
                self.advance()
                let mut elements = [first]
                if !self.check(TokenKind::TkRParen) {
                    elements.push(self.parse_type_expr())
                    while self.check(TokenKind::TkComma) {
                        self.advance()
                        if self.check(TokenKind::TkRParen) { break }
                        elements.push(self.parse_type_expr())
                    }
                }
                let end_tok = self.expect(TokenKind::TkRParen)
                let mut result = TypeExpr::TupleType { elements: elements, span: self.make_span(start, end_tok.span.end) }
                if self.try_consume(TokenKind::TkQuestion) {
                    let opt_end = self.current_span_start()
                    result = TypeExpr::OptionType { inner: result, span: self.make_span(start, opt_end) }
                }
                return result
            }
            self.expect(TokenKind::TkRParen)
            return first
        }

        if self.check(TokenKind::TkSuper) {
            self.advance()
            self.expect(TokenKind::TkColonColon)
            let mut qualifier_parts: List<Str> = ["super"]
            while self.check(TokenKind::TkSuper) {
                qualifier_parts.push("super")
                self.advance()
                self.expect(TokenKind::TkColonColon)
            }
            let type_name = self.expect(TokenKind::TkIdent).value
            let type_args = self.try_parse_type_args()
            let end = self.current_span_start()
            let mut result: TypeExpr = TypeExpr::Named { name: type_name, qualifier: some(qualifier_parts.join("::")), type_args: type_args, span: self.make_span(start, end) }
            if self.try_consume(TokenKind::TkQuestion) {
                let opt_end = self.current_span_start()
                result = TypeExpr::OptionType { inner: result, span: self.make_span(start, opt_end) }
            }
            return result
        }

        let name = self.expect(TokenKind::TkIdent).value
        let mut qualifier: Str? = none
        let mut actual_name = name

        if self.check(TokenKind::TkColonColon) {
            // Support multi-level: mod::submod::...::Type
            let mut qual_parts: List<Str> = [name]
            while self.check(TokenKind::TkColonColon) {
                self.advance()
                let member_tok = self.expect(TokenKind::TkIdent)
                let member_name = member_tok.value
                if !is_uppercase(member_name.char_at(0).unwrap_or("")) && self.check(TokenKind::TkColonColon) {
                    // Another lowercase mod segment
                    qual_parts.push(member_name)
                } else {
                    // Final segment (the type name)
                    actual_name = member_name
                    break
                }
            }
            qualifier = some(qual_parts.join("::"))
        }

        let type_args = self.try_parse_type_args()

        let end = self.current_span_start()
        let mut result: TypeExpr = TypeExpr::Named { name: actual_name, qualifier: qualifier, type_args: type_args, span: self.make_span(start, end) }

        if self.try_consume(TokenKind::TkQuestion) {
            let opt_end = self.current_span_start()
            result = TypeExpr::OptionType { inner: result, span: self.make_span(start, opt_end) }
        }

        result
    }

    fn parse_record_type_expr(mut self) -> TypeExpr {
        let start = self.current_span_start()
        self.expect(TokenKind::TkLBrace)
        let mut fields: List<RecordTypeField> = []
        let mut rest: Str? = none

        while !self.check(TokenKind::TkRBrace) && !self.at_end() {
            if self.check(TokenKind::TkDotDot) {
                self.advance()
                rest = some(self.expect(TokenKind::TkIdent).value)
                self.try_consume(TokenKind::TkComma)
                break
            }

            let field_start = self.current_span_start()
            let field_name = self.expect(TokenKind::TkIdent).value
            self.expect(TokenKind::TkColon)
            let field_type = self.parse_type_expr()
            let field_end = self.current_span_start()
            fields.push(RecordTypeField { name: field_name, ty: field_type, span: self.make_span(field_start, field_end) })

            if !self.try_consume(TokenKind::TkComma) { break }
        }

        let rbrace = self.expect(TokenKind::TkRBrace)
        TypeExpr::RecordType { fields: fields, rest: rest, span: self.make_span(start, rbrace.span.end) }
    }

    // ============================================================
    // Qualified ident: parses "Ident" or "mod::submod::Ident"
    // ============================================================

    fn parse_qualified_ident(mut self) -> Str {
        let name = self.expect(TokenKind::TkIdent).value
        if !self.check(TokenKind::TkColonColon) {
            return name
        }
        // Build qualified path: first_segment::...::FinalSegment
        let mut parts: List<Str> = [name]
        while self.check(TokenKind::TkColonColon) {
            self.advance()
            let segment = self.expect(TokenKind::TkIdent).value
            parts.push(segment)
            // If the segment starts uppercase, it's the final type/trait name
            if is_uppercase(segment.char_at(0).unwrap_or("")) {
                break
            }
            // lowercase segment: could be another mod level, continue if :: follows
        }
        parts.join("::")
    }

    // ============================================================
    // Validate target type arguments: consume <T, U, ...> if present,
    // checking each arg is a type variable declared in the impl's type_params.
    // Used in impl Trait for Type<T> where <T> on the target type is redundant.
    // ============================================================

    fn validate_target_type_args(mut self, type_params: List<TypeParam>) {
        if !self.check(TokenKind::TkLt) { return }
        self.advance()
        while !self.check(TokenKind::TkGt) && !self.at_end() {
            let arg_tok = self.peek()
            if arg_tok.kind == TokenKind::TkIdent {
                let arg_name = arg_tok.value
                let mut found = false
                for tp in type_params {
                    if tp.name == arg_name {
                        found = true
                    }
                }
                if !found {
                    self.report_error(E0105, "type argument '${arg_name}' in target type is not a type parameter declared on the impl; expected one of the impl's type parameters", some(arg_tok.span))
                }
                self.advance()
            } else {
                self.report_error(E0105, "expected type parameter name in target type arguments, got '${arg_tok.value}'", some(arg_tok.span))
                self.advance()
            }
            self.try_consume(TokenKind::TkComma)
        }
        if self.check(TokenKind::TkGt) { self.advance() }
    }

    // ============================================================
    // Type Params: <T, U: Constraint>
    // ============================================================

    pub fn parse_type_params(mut self) -> List<TypeParam> {
        if !self.check(TokenKind::TkLt) { return [] }
        self.advance()
        let mut params: List<TypeParam> = []
        while !self.check(TokenKind::TkGt) && !self.at_end() {
            let tp_start = self.current_span_start()
            let name = self.expect(TokenKind::TkIdent).value
            let mut bounds: List<TypeBound> = []
            if self.try_consume(TokenKind::TkColon) {
                bounds.push(self.parse_type_bound())
                while self.check(TokenKind::TkPlus) {
                    self.advance()
                    bounds.push(self.parse_type_bound())
                }
            }
            let tp_end = self.current_span_start()
            params.push(TypeParam { name: name, bounds: bounds, span: self.make_span(tp_start, tp_end) })
            self.try_consume(TokenKind::TkComma)
        }
        self.expect(TokenKind::TkGt)
        params
    }

    pub fn parse_type_bound(mut self) -> TypeBound {
        let start = self.current_span_start()
        let trait_name = self.expect(TokenKind::TkIdent).value
        let mut type_args: List<TypeExpr> = []
        let mut assoc_constraints: List<AssocConstraint> = []
        // Parse optional <...> with type args or assoc constraints (Name = Type)
        if self.check(TokenKind::TkLt) {
            let save_pos = self.pos
            let save_errors = self.error_count
            let sink_checkpoint = self.sink.save()
            self.advance()
            while !self.check(TokenKind::TkGt) && !self.at_end() {
                // Check for assoc constraint: Ident =
                if self.check(TokenKind::TkIdent) && self.peek_at(1).kind == TokenKind::TkEq {
                    let ac_start = self.current_span_start()
                    let ac_name = self.advance().value
                    self.advance()  // consume '='
                    let ac_ty = self.parse_type_expr()
                    let ac_end = self.current_span_start()
                    assoc_constraints.push(AssocConstraint { name: ac_name, ty: ac_ty, span: self.make_span(ac_start, ac_end) })
                } else {
                    type_args.push(self.parse_type_expr())
                }
                if !self.check(TokenKind::TkGt) {
                    self.try_consume(TokenKind::TkComma)
                }
            }
            if !self.check(TokenKind::TkGt) {
                // Rollback on failure
                self.pos = save_pos
                self.error_count = save_errors
                self.sink.restore(sink_checkpoint)
                type_args = []
                assoc_constraints = []
            } else {
                let _ = self.advance()
            }
        }
        let end = self.current_span_start()
        TypeBound { trait_name: trait_name, type_args: type_args, assoc_constraints: assoc_constraints, span: self.make_span(start, end) }
    }

    // ============================================================
    // Parameters
    // ============================================================

    pub fn parse_params(mut self) -> List<Param> {
        let mut params: List<Param> = []
        if self.check(TokenKind::TkRParen) { return params }
        params.push(self.parse_param())
        while self.try_consume(TokenKind::TkComma) {
            if self.check(TokenKind::TkRParen) { break }
            params.push(self.parse_param())
        }
        // Validate: non-default params must not follow default params
        let mut seen_default = false
        for p in params {
            match p.default_value {
                some(_) => { seen_default = true },
                none => {
                    if seen_default {
                        self.sink.report(make_diag(
                            E0106,
                            Severity::SevError,
                            "Non-default parameter '${p.name}' after default parameter",
                            p.span,
                            DiagnosticContext::ParseError { token: p.name, expected: none }
                        ))
                    }
                }
            }
        }
        params
    }

    pub fn parse_param(mut self) -> Param {
        let start = self.current_span_start()
        let mut is_mutable = false
        if self.check(TokenKind::TkMut) {
            self.advance()
            is_mutable = true
        }
        let name = self.expect(TokenKind::TkIdent).value
        let mut type_annotation: TypeExpr? = none
        if self.try_consume(TokenKind::TkColon) {
            type_annotation = some(self.parse_type_expr())
        }
        let mut default_value: Expr? = none
        if self.try_consume(TokenKind::TkEq) {
            default_value = some(self.parse_expr())
        }
        let end = self.current_span_start()
        Param { name: name, is_mutable: is_mutable, type_annotation: type_annotation, default_value: default_value, span: self.make_span(start, end) }
    }
}
