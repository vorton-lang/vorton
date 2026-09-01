use crate::ast::*;
use crate::diagnostic::{Diagnostic, push_diagnostic, sort_diagnostics};
use crate::lexer::{Token, TokenKind};
use crate::source::SourceFile;

pub(crate) fn parse(source: &SourceFile, tokens: &[Token]) -> Result<Program, Vec<Diagnostic>> {
    let mut parser = Parser::new(source, tokens);
    let program = parser.parse_program();
    sort_diagnostics(&mut parser.diagnostics);
    match program {
        Some(program) if parser.diagnostics.is_empty() => Ok(program),
        _ => Err(parser.diagnostics),
    }
}

struct Parser<'a> {
    source: &'a SourceFile,
    tokens: &'a [Token],
    position: usize,
    diagnostics: Vec<Diagnostic>,
}

impl<'a> Parser<'a> {
    fn new(source: &'a SourceFile, tokens: &'a [Token]) -> Self {
        Self {
            source,
            tokens,
            position: 0,
            diagnostics: Vec::new(),
        }
    }

    fn parse_program(&mut self) -> Option<Program> {
        let mut uses = Vec::new();
        let mut declarations = Vec::new();
        let mut declarations_started = false;
        while !self.at(TokenKind::Eof) {
            if self.at(TokenKind::Error) {
                self.unexpected("valid token");
                return None;
            } else if self.at(TokenKind::Requires) {
                self.reject_file_requires();
                return None;
            } else if self.is_use_start() {
                if declarations_started {
                    self.report(Diagnostic::parse(
                        "E0706",
                        "Use declaration must appear before other declarations",
                        self.peek().span,
                        self.peek().value.clone(),
                    ));
                    return None;
                }
                uses.push(self.parse_use_decl()?);
            } else {
                declarations_started = true;
                declarations.push(self.parse_decl()?);
            }
        }
        Some(Program {
            source: self.source.id(),
            uses,
            declarations,
            span: self.source.span(0, self.source.len()),
        })
    }

    fn reject_file_requires(&mut self) {
        let token = self.advance();
        self.report(
            Diagnostic::parse(
                "E0101",
                "File-level 'requires' is not part of the canonical 0.1 surface",
                token.span,
                token.value,
            )
            .with_suggestion(
                "Remove the file header; capability policy is defined separately",
                None,
            ),
        );
    }

    fn is_use_start(&self) -> bool {
        self.at(TokenKind::Use)
            || (self.at(TokenKind::Pub) && self.peek_n(1).kind == TokenKind::Use)
    }

    fn parse_use_decl(&mut self) -> Option<UseDecl> {
        let start = self.peek().span.start as usize;
        let visibility = self.parse_visibility();
        self.expect(TokenKind::Use)?;
        let path = self.parse_path(true)?;
        let has_group_separator = self
            .tokens
            .get(self.position.saturating_sub(1))
            .is_some_and(|token| token.kind == TokenKind::ColonColon);
        let kind = if self.at(TokenKind::LeftBrace) {
            if !has_group_separator {
                self.report(Diagnostic::parse(
                    "E0101",
                    "A grouped use requires '::' before '{'",
                    self.peek().span,
                    "{",
                ));
                return None;
            }
            self.advance();
            let mut items = Vec::new();
            if self.at(TokenKind::RightBrace) {
                self.report(Diagnostic::parse(
                    "E0101",
                    "A named use list must contain at least one item",
                    self.peek().span,
                    "}",
                ));
                return None;
            }
            while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
                let item_start = self.peek().span.start as usize;
                let name = self.expect_name()?;
                let alias = if self.consume(TokenKind::As).is_some() {
                    Some(self.expect_name()?)
                } else {
                    None
                };
                let item_end = alias.as_ref().map_or(name.span.end, |value| value.span.end);
                items.push(UseItem {
                    name,
                    alias,
                    span: self.source.span(item_start, item_end as usize),
                });
                if self.consume(TokenKind::Comma).is_none() {
                    break;
                }
            }
            self.expect(TokenKind::RightBrace)?;
            UseKind::NamedItems(items)
        } else if self.consume(TokenKind::As).is_some() {
            UseKind::PathAlias(self.expect_name()?)
        } else {
            UseKind::Bare
        };
        self.forbid_trailing_declaration_semicolon()?;
        Some(UseDecl {
            visibility,
            path,
            kind,
            span: self.source.span(start, self.previous_end()),
        })
    }

    fn parse_decl(&mut self) -> Option<Decl> {
        if self.at(TokenKind::At) {
            self.reject_attribute();
            return None;
        }
        let visibility = self.parse_visibility();
        if self.at(TokenKind::At) {
            self.reject_attribute();
            return None;
        }
        let token = self.peek().clone();
        match token.kind {
            TokenKind::Fn => self.parse_function_decl(visibility).map(Decl::Function),
            TokenKind::Struct => self.parse_struct_decl(visibility).map(Decl::Struct),
            TokenKind::Enum => self.parse_enum_decl(visibility).map(Decl::Enum),
            TokenKind::Trait => self.parse_trait_decl(visibility).map(Decl::Trait),
            TokenKind::Impl => {
                if visibility.public {
                    self.invalid_visibility(&visibility, "impl blocks do not have visibility");
                    return None;
                }
                self.parse_impl_decl().map(Decl::Impl)
            }
            TokenKind::Effect => self.parse_effect_decl(visibility),
            TokenKind::Extern => self.parse_extern_decl(visibility),
            TokenKind::Test => self.parse_test_decl(visibility).map(Decl::Test),
            TokenKind::Const => self.parse_const_decl(visibility).map(Decl::Const),
            TokenKind::Mod => self.parse_module_decl(visibility).map(Decl::Module),
            TokenKind::Identifier if token.value == "type" => {
                self.parse_type_alias_decl(visibility).map(Decl::TypeAlias)
            }
            _ => {
                self.report(Diagnostic::parse(
                    "E0101",
                    format!("Expected declaration, found '{}'", token.value),
                    token.span,
                    token.value,
                ));
                None
            }
        }
    }

    fn reject_attribute(&mut self) {
        let at = self.advance();
        let mut end = at.span.end as usize;
        let name = if self.at(TokenKind::Identifier) {
            let token = self.advance();
            end = token.span.end as usize;
            token.value
        } else {
            String::new()
        };
        let label = if name.is_empty() {
            "Attributes".to_owned()
        } else {
            format!("Attribute '@{name}'")
        };
        self.report(
            Diagnostic::parse(
                "E0101",
                format!("{label} is not part of the canonical 0.1 surface"),
                self.source.span(at.span.start as usize, end),
                format!("@{name}"),
            )
            .with_suggestion("Use ordinary explicit declarations and impl blocks", None),
        );
    }

    fn parse_function_decl(&mut self, visibility: Visibility) -> Option<FunctionDecl> {
        let start = visibility
            .span
            .map_or(self.peek().span.start as usize, |span| span.start as usize);
        self.expect(TokenKind::Fn)?;
        let name = self.expect_name()?;
        let type_params = self.parse_type_params()?;
        self.expect(TokenKind::LeftParen)?;
        let params = self.parse_params()?;
        self.expect(TokenKind::RightParen)?;
        let return_type = if self.consume(TokenKind::Arrow).is_some() {
            Some(self.parse_type_expr()?)
        } else {
            None
        };
        let effects = self.parse_optional_effect_annotation()?;
        let body = self.parse_block_expr()?;
        let span = self.source.span(start, body.span().end as usize);
        Some(FunctionDecl {
            visibility,
            name,
            type_params,
            params,
            return_type,
            effects,
            body,
            span,
        })
    }

    fn parse_struct_decl(&mut self, visibility: Visibility) -> Option<StructDecl> {
        let start = visibility
            .span
            .map_or(self.peek().span.start as usize, |span| span.start as usize);
        self.expect(TokenKind::Struct)?;
        let name = self.expect_name()?;
        let type_params = self.parse_type_params()?;
        self.expect(TokenKind::LeftBrace)?;
        let mut fields = Vec::new();
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            let field_start = self.peek().span.start as usize;
            let field_visibility = self.parse_visibility();
            let field_name = self.expect_name()?;
            self.expect(TokenKind::Colon)?;
            let ty = self.parse_type_expr()?;
            if self.at(TokenKind::Where) {
                self.reject_where_clause();
                return None;
            }
            let end = ty.span().end as usize;
            fields.push(StructField {
                visibility: field_visibility,
                name: field_name,
                ty,
                span: self.source.span(field_start, end),
            });
            self.consume(TokenKind::Comma);
        }
        let close = self.expect(TokenKind::RightBrace)?;
        Some(StructDecl {
            visibility,
            name,
            type_params,
            fields,
            span: self.source.span(start, close.span.end as usize),
        })
    }

    fn parse_enum_decl(&mut self, visibility: Visibility) -> Option<EnumDecl> {
        let start = visibility
            .span
            .map_or(self.peek().span.start as usize, |span| span.start as usize);
        self.expect(TokenKind::Enum)?;
        let name = self.expect_name()?;
        let type_params = self.parse_type_params()?;
        self.expect(TokenKind::LeftBrace)?;
        let mut variants = Vec::new();
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            let variant_start = self.peek().span.start as usize;
            let variant_name = self.expect_name()?;
            let fields = if self.consume(TokenKind::LeftParen).is_some() {
                if self.at(TokenKind::RightParen) {
                    let close = self.advance();
                    self.report(
                        Diagnostic::parse(
                            "E0104",
                            "Empty parentheses on an enum variant are not allowed",
                            close.span,
                            close.value,
                        )
                        .with_suggestion("Remove the parentheses from the unit variant", None),
                    );
                    return None;
                } else {
                    let mut values = Vec::new();
                    loop {
                        values.push(self.parse_type_expr()?);
                        if self.consume(TokenKind::Comma).is_none()
                            || self.at(TokenKind::RightParen)
                        {
                            break;
                        }
                    }
                    self.expect(TokenKind::RightParen)?;
                    VariantFields::Positional(values)
                }
            } else if self.consume(TokenKind::LeftBrace).is_some() {
                if self.at(TokenKind::RightBrace) {
                    self.report(
                        Diagnostic::parse(
                            "E0101",
                            "Named enum variants require at least one field; use a bare name for a unit variant",
                            self.peek().span,
                            self.peek().value.clone(),
                        )
                        .with_suggestion("Remove the empty braces", None),
                    );
                    return None;
                }
                let mut values = Vec::new();
                while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
                    let field_start = self.peek().span.start as usize;
                    let field_name = self.expect_name()?;
                    self.expect(TokenKind::Colon)?;
                    let ty = self.parse_type_expr()?;
                    let end = ty.span().end as usize;
                    values.push(NamedTypeField {
                        name: field_name,
                        ty,
                        span: self.source.span(field_start, end),
                    });
                    if self.consume(TokenKind::Comma).is_none() {
                        break;
                    }
                }
                self.expect(TokenKind::RightBrace)?;
                VariantFields::Named(values)
            } else {
                VariantFields::Unit
            };
            let end = self.previous_end();
            variants.push(EnumVariant {
                name: variant_name,
                fields,
                span: self.source.span(variant_start, end),
            });
            self.consume(TokenKind::Comma);
        }
        let close = self.expect(TokenKind::RightBrace)?;
        Some(EnumDecl {
            visibility,
            name,
            type_params,
            variants,
            span: self.source.span(start, close.span.end as usize),
        })
    }

    fn parse_trait_decl(&mut self, visibility: Visibility) -> Option<TraitDecl> {
        let start = visibility
            .span
            .map_or(self.peek().span.start as usize, |span| span.start as usize);
        self.expect(TokenKind::Trait)?;
        let name = self.expect_name()?;
        let type_params = self.parse_type_params()?;
        let mut supertraits = Vec::new();
        if self.consume(TokenKind::Colon).is_some() {
            loop {
                supertraits.push(self.parse_type_bound()?);
                if self.consume(TokenKind::Plus).is_none() {
                    break;
                }
            }
        }
        self.expect(TokenKind::LeftBrace)?;
        let mut members = Vec::new();
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            let member_visibility = self.parse_visibility();
            if member_visibility.public {
                self.invalid_visibility(
                    &member_visibility,
                    "trait members inherit the trait visibility",
                );
                return None;
            }
            if self.at_contextual("type") {
                members.push(TraitMember::AssociatedType(
                    self.parse_associated_type(member_visibility)?,
                ));
            } else if self.at(TokenKind::Fn) {
                let signature = self.parse_function_signature()?;
                if self.at(TokenKind::LeftBrace) {
                    let body_span = self.peek().span;
                    self.report(
                        Diagnostic::parse(
                            "E0101",
                            "Trait method bodies are not supported in Vorton 0.1",
                            body_span,
                            "{",
                        )
                        .with_suggestion("Move the body to each explicit trait impl", None),
                    );
                    return None;
                }
                self.consume(TokenKind::Semicolon);
                members.push(TraitMember::Method(signature));
            } else {
                self.unexpected("trait member");
                return None;
            }
        }
        let close = self.expect(TokenKind::RightBrace)?;
        Some(TraitDecl {
            visibility,
            name,
            type_params,
            supertraits,
            members,
            span: self.source.span(start, close.span.end as usize),
        })
    }

    fn parse_function_signature(&mut self) -> Option<FunctionSignature> {
        let start = self.expect(TokenKind::Fn)?.span.start as usize;
        let name = self.expect_name()?;
        let type_params = self.parse_type_params()?;
        self.expect(TokenKind::LeftParen)?;
        let params = self.parse_params()?;
        self.expect(TokenKind::RightParen)?;
        let return_type = if self.consume(TokenKind::Arrow).is_some() {
            Some(self.parse_type_expr()?)
        } else {
            None
        };
        let effects = self.parse_optional_effect_annotation()?;
        Some(FunctionSignature {
            name,
            type_params,
            params,
            return_type,
            effects,
            span: self.source.span(start, self.previous_end()),
        })
    }

    fn parse_impl_decl(&mut self) -> Option<ImplDecl> {
        let start = self.expect(TokenKind::Impl)?.span.start as usize;
        let type_params = self.parse_type_params()?;
        let first = self.parse_type_expr()?;
        if !matches!(first, TypeExpr::Named { .. }) {
            self.report(Diagnostic::parse(
                "E0101",
                "Impl trait and target must be named types",
                first.span(),
                "impl type",
            ));
            return None;
        }
        let kind = if self.consume(TokenKind::For).is_some() {
            let target = self.parse_type_expr()?;
            if !matches!(target, TypeExpr::Named { .. }) {
                self.report(Diagnostic::parse(
                    "E0101",
                    "Impl trait and target must be named types",
                    target.span(),
                    "impl type",
                ));
                return None;
            }
            ImplKind::Trait {
                trait_path: first,
                target,
            }
        } else {
            ImplKind::Inherent { target: first }
        };
        let trait_impl = matches!(kind, ImplKind::Trait { .. });
        self.expect(TokenKind::LeftBrace)?;
        let mut members = Vec::new();
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            if self.at_contextual("delegate") {
                let token = self.advance();
                self.report(
                    Diagnostic::parse(
                        "E0101",
                        "'delegate' is not part of Vorton 0.1",
                        token.span,
                        token.value,
                    )
                    .with_suggestion("Write explicit forwarding methods", None),
                );
                return None;
            }
            let member_visibility = self.parse_visibility();
            if trait_impl && member_visibility.public {
                self.invalid_visibility(
                    &member_visibility,
                    "trait impl members inherit trait visibility",
                );
                return None;
            }
            if self.at(TokenKind::Extern) {
                self.reject_impl_extern();
                return None;
            } else if self.at_contextual("type") {
                members.push(ImplMember::AssociatedType(
                    self.parse_associated_type(member_visibility)?,
                ));
            } else if self.at(TokenKind::Fn) {
                members.push(ImplMember::Method(
                    self.parse_function_decl(member_visibility)?,
                ));
            } else {
                self.unexpected("impl member");
                return None;
            }
        }
        let close = self.expect(TokenKind::RightBrace)?;
        Some(ImplDecl {
            type_params,
            kind,
            members,
            span: self.source.span(start, close.span.end as usize),
        })
    }

    fn reject_impl_extern(&mut self) {
        let token = self.advance();
        self.report(
            Diagnostic::parse(
                "E0101",
                "Impl-member extern functions are not part of Vorton 0.1",
                token.span,
                token.value,
            )
            .with_suggestion(
                "Declare a top-level extern function and call it from an ordinary method",
                None,
            ),
        );
    }

    fn parse_effect_decl(&mut self, visibility: Visibility) -> Option<Decl> {
        let start = visibility
            .span
            .map_or(self.peek().span.start as usize, |span| span.start as usize);
        self.expect(TokenKind::Effect)?;
        if self.at_contextual("alias") {
            self.advance();
            let name = self.expect_name()?;
            let type_params = self.parse_type_params()?;
            self.expect(TokenKind::Equal)?;
            let effects = self.parse_effect_set()?;
            self.forbid_trailing_declaration_semicolon()?;
            return Some(Decl::EffectAlias(EffectAliasDecl {
                visibility,
                name,
                type_params,
                span: self.source.span(start, effects.span.end as usize),
                effects,
            }));
        }
        let name = self.expect_name()?;
        let type_params = self.parse_type_params()?;
        self.expect(TokenKind::LeftBrace)?;
        let mut operations = Vec::new();
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            let op_start = self.peek().span.start as usize;
            self.expect(TokenKind::Fn)?;
            let op_name = self.expect_name()?;
            self.expect(TokenKind::LeftParen)?;
            let params = self.parse_params()?;
            self.expect(TokenKind::RightParen)?;
            self.expect(TokenKind::Arrow)?;
            let return_type = self.parse_type_expr()?;
            if self.at(TokenKind::LeftBrace) {
                let body_span = self.peek().span;
                self.report(
                    Diagnostic::parse(
                        "E0101",
                        "Effect operation bodies are not supported in Vorton 0.1",
                        body_span,
                        "{",
                    )
                    .with_suggestion(
                        "Provide the operation with an explicit handle expression",
                        None,
                    ),
                );
                return None;
            }
            if self.at_any(&[TokenKind::Semicolon, TokenKind::Comma]) {
                self.advance();
                if self.at_any(&[TokenKind::Semicolon, TokenKind::Comma]) {
                    let token = self.peek().clone();
                    self.report(Diagnostic::parse(
                        "E0101",
                        "An effect operation accepts at most one trailing separator",
                        token.span,
                        token.value,
                    ));
                    return None;
                }
            }
            operations.push(EffectOperation {
                name: op_name,
                params,
                return_type,
                span: self.source.span(op_start, self.previous_end()),
            });
        }
        let close = self.expect(TokenKind::RightBrace)?;
        Some(Decl::Effect(EffectDecl {
            visibility,
            name,
            type_params,
            operations,
            span: self.source.span(start, close.span.end as usize),
        }))
    }

    fn parse_extern_decl(&mut self, visibility: Visibility) -> Option<Decl> {
        let start = visibility
            .span
            .map_or(self.peek().span.start as usize, |span| span.start as usize);
        self.expect(TokenKind::Extern)?;
        if self.at_contextual("type") {
            self.advance();
            let name = self.expect_name()?;
            let type_params = self.parse_type_params()?;
            self.forbid_trailing_declaration_semicolon()?;
            return Some(Decl::ExternType(ExternTypeDecl {
                visibility,
                name,
                type_params,
                span: self.source.span(start, self.previous_end()),
            }));
        }
        self.expect(TokenKind::Fn)?;
        let name = self.expect_name()?;
        let type_params = self.parse_type_params()?;
        self.expect(TokenKind::LeftParen)?;
        let params = self.parse_params()?;
        self.expect(TokenKind::RightParen)?;
        let return_type = if self.consume(TokenKind::Arrow).is_some() {
            Some(self.parse_type_expr()?)
        } else {
            None
        };
        let effects = self.parse_optional_effect_annotation()?;
        self.forbid_trailing_declaration_semicolon()?;
        Some(Decl::ExternFunction(ExternFunctionDecl {
            visibility,
            name,
            type_params,
            params,
            return_type,
            effects,
            span: self.source.span(start, self.previous_end()),
        }))
    }

    fn parse_type_alias_decl(&mut self, visibility: Visibility) -> Option<TypeAliasDecl> {
        let start = visibility
            .span
            .map_or(self.peek().span.start as usize, |span| span.start as usize);
        self.advance();
        let name = self.expect_name()?;
        let type_params = self.parse_type_params()?;
        self.expect(TokenKind::Equal)?;
        let ty = self.parse_type_expr()?;
        if self.at(TokenKind::Where) {
            self.reject_where_clause();
            return None;
        }
        self.forbid_trailing_declaration_semicolon()?;
        Some(TypeAliasDecl {
            visibility,
            name,
            type_params,
            span: self
                .source
                .span(start, self.previous_end().max(ty.span().end as usize)),
            ty,
        })
    }

    fn parse_associated_type(&mut self, visibility: Visibility) -> Option<AssociatedTypeDecl> {
        let start = visibility
            .span
            .map_or(self.peek().span.start as usize, |span| span.start as usize);
        self.advance();
        let name = self.expect_name()?;
        let mut bounds = Vec::new();
        if self.consume(TokenKind::Colon).is_some() {
            loop {
                bounds.push(self.parse_type_bound()?);
                if self.consume(TokenKind::Plus).is_none() {
                    break;
                }
            }
        }
        let value = if self.consume(TokenKind::Equal).is_some() {
            Some(self.parse_type_expr()?)
        } else {
            None
        };
        self.consume(TokenKind::Semicolon);
        Some(AssociatedTypeDecl {
            visibility,
            name,
            bounds,
            value,
            span: self.source.span(start, self.previous_end()),
        })
    }

    fn parse_test_decl(&mut self, visibility: Visibility) -> Option<TestDecl> {
        let start = visibility
            .span
            .map_or(self.peek().span.start as usize, |span| span.start as usize);
        self.expect(TokenKind::Test)?;
        let description = self.expect(TokenKind::String)?;
        let body = self.parse_block_expr()?;
        Some(TestDecl {
            visibility,
            description: description.value,
            description_span: description.span,
            span: self.source.span(start, body.span().end as usize),
            body,
        })
    }

    fn parse_const_decl(&mut self, visibility: Visibility) -> Option<ConstDecl> {
        let start = visibility
            .span
            .map_or(self.peek().span.start as usize, |span| span.start as usize);
        self.expect(TokenKind::Const)?;
        let name = self.expect_name()?;
        let type_annotation = if self.consume(TokenKind::Colon).is_some() {
            Some(self.parse_type_expr()?)
        } else {
            None
        };
        self.expect(TokenKind::Equal)?;
        let value = self.parse_expr()?;
        self.forbid_trailing_declaration_semicolon()?;
        Some(ConstDecl {
            visibility,
            name,
            type_annotation,
            span: self
                .source
                .span(start, self.previous_end().max(value.span().end as usize)),
            value,
        })
    }

    fn parse_module_decl(&mut self, visibility: Visibility) -> Option<ModuleDecl> {
        let start = visibility
            .span
            .map_or(self.peek().span.start as usize, |span| span.start as usize);
        self.expect(TokenKind::Mod)?;
        let name = self.expect_name()?;
        let requires = if self.consume(TokenKind::Requires).is_some() {
            Some(self.parse_effect_set()?)
        } else {
            None
        };
        self.expect(TokenKind::LeftBrace)?;
        let mut uses = Vec::new();
        let mut declarations = Vec::new();
        let mut declarations_started = false;
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            if self.is_use_start() {
                if declarations_started {
                    self.report(Diagnostic::parse(
                        "E0706",
                        "Use declaration must appear before other declarations",
                        self.peek().span,
                        self.peek().value.clone(),
                    ));
                    return None;
                }
                uses.push(self.parse_use_decl()?);
            } else {
                declarations_started = true;
                declarations.push(self.parse_decl()?);
            }
        }
        let close = self.expect(TokenKind::RightBrace)?;
        Some(ModuleDecl {
            visibility,
            name,
            requires,
            uses,
            declarations,
            span: self.source.span(start, close.span.end as usize),
        })
    }

    fn parse_visibility(&mut self) -> Visibility {
        if let Some(token) = self.consume(TokenKind::Pub) {
            Visibility {
                public: true,
                span: Some(token.span),
            }
        } else {
            Visibility::private()
        }
    }

    fn invalid_visibility(&mut self, visibility: &Visibility, reason: &str) {
        if let Some(span) = visibility.span {
            self.report(
                Diagnostic::parse("E0101", format!("Invalid 'pub': {reason}"), span, "pub")
                    .with_suggestion("Remove 'pub'", Some(String::new())),
            );
        }
    }

    fn reject_where_clause(&mut self) {
        if !self.at(TokenKind::Where) {
            return;
        }
        let token = self.advance();
        self.report(
            Diagnostic::parse(
                "E0101",
                "Refinement 'where' clauses are not part of Vorton 0.1",
                token.span,
                token.value,
            )
            .with_suggestion("Remove the clause", None),
        );
    }

    fn forbid_trailing_declaration_semicolon(&mut self) -> Option<()> {
        if let Some(token) = self.consume(TokenKind::Semicolon) {
            self.report(
                Diagnostic::parse(
                    "E0101",
                    "This declaration does not accept a trailing ';'",
                    token.span,
                    token.value,
                )
                .with_suggestion("Remove the trailing semicolon", None),
            );
            None
        } else {
            Some(())
        }
    }

    fn parse_params(&mut self) -> Option<Vec<Param>> {
        let mut params = Vec::new();
        while !self.at(TokenKind::RightParen) && !self.at(TokenKind::Eof) {
            let start = self.peek().span.start as usize;
            let mutable = self.consume(TokenKind::Mut).is_some();
            let name = self.expect_name()?;
            let type_annotation = if self.consume(TokenKind::Colon).is_some() {
                Some(self.parse_type_expr()?)
            } else {
                None
            };
            if self.at(TokenKind::Where) {
                self.reject_where_clause();
                return None;
            }
            if self.at(TokenKind::Equal) {
                let token = self.advance();
                self.report(
                    Diagnostic::parse(
                        "E0101",
                        "Default parameters are not part of Vorton 0.1",
                        token.span,
                        token.value,
                    )
                    .with_suggestion("Define an explicit wrapper function", None),
                );
                return None;
            }
            let end = self.previous_end().max(name.span.end as usize);
            params.push(Param {
                mutable,
                name,
                type_annotation,
                span: self.source.span(start, end),
            });
            if self.consume(TokenKind::Comma).is_none() {
                break;
            }
        }
        Some(params)
    }

    fn parse_statement(&mut self) -> Option<Stmt> {
        match self.peek().kind {
            TokenKind::Let => self.parse_let_statement(),
            TokenKind::Return => self.parse_return_statement(),
            TokenKind::If if self.peek_n(1).kind == TokenKind::Let => self.parse_if_let_statement(),
            TokenKind::While => self.parse_while_statement(),
            TokenKind::Loop => self.parse_loop_statement(),
            TokenKind::For => self.parse_for_statement(),
            TokenKind::Break => {
                let token = self.advance();
                self.consume(TokenKind::Semicolon);
                Some(Stmt::Break {
                    span: self
                        .source
                        .span(token.span.start as usize, self.previous_end()),
                })
            }
            TokenKind::Continue => {
                let token = self.advance();
                self.consume(TokenKind::Semicolon);
                Some(Stmt::Continue {
                    span: self
                        .source
                        .span(token.span.start as usize, self.previous_end()),
                })
            }
            TokenKind::Try => {
                self.reject_try();
                None
            }
            _ => self.parse_expression_or_assignment_statement(),
        }
    }

    fn parse_let_statement(&mut self) -> Option<Stmt> {
        let start = self.expect(TokenKind::Let)?.span.start as usize;
        let mutable = self.consume(TokenKind::Mut).is_some();
        let pattern = self.parse_let_pattern(mutable)?;
        let type_annotation = if self.consume(TokenKind::Colon).is_some() {
            if matches!(pattern, Pattern::Tuple { .. }) {
                self.report(Diagnostic::parse(
                    "E0101",
                    "Tuple destructuring bindings do not accept a single type annotation",
                    self.tokens[self.position - 1].span,
                    ":",
                ));
                return None;
            }
            Some(self.parse_type_expr()?)
        } else {
            None
        };
        if self.at(TokenKind::Where) {
            self.reject_where_clause();
            return None;
        }
        self.expect(TokenKind::Equal)?;
        let value = self.parse_expr()?;
        self.consume(TokenKind::Semicolon);
        Some(Stmt::Let {
            mutable,
            pattern,
            type_annotation,
            value,
            span: self.source.span(start, self.previous_end()),
        })
    }

    fn parse_let_pattern(&mut self, mutable: bool) -> Option<Pattern> {
        if self.at(TokenKind::LeftParen) {
            if mutable {
                self.report(Diagnostic::parse(
                    "E0101",
                    "'let mut' requires one binding name",
                    self.peek().span,
                    "(",
                ));
                return None;
            }
            let pattern = self.parse_pattern_atom()?;
            if !matches!(pattern, Pattern::Tuple { .. }) {
                self.report(Diagnostic::parse(
                    "E0101",
                    "Let destructuring only accepts a tuple pattern",
                    pattern.span(),
                    "pattern",
                ));
                return None;
            }
            return Some(pattern);
        }

        let name = self.expect_name()?;
        if name.text == "_" {
            Some(Pattern::Wildcard { span: name.span })
        } else {
            Some(Pattern::Name {
                span: name.span,
                name,
            })
        }
    }

    fn parse_return_statement(&mut self) -> Option<Stmt> {
        let start_token = self.expect(TokenKind::Return)?;
        let value = if self.at_any(&[TokenKind::Semicolon, TokenKind::RightBrace, TokenKind::Eof]) {
            None
        } else {
            Some(self.parse_expr()?)
        };
        self.consume(TokenKind::Semicolon);
        Some(Stmt::Return {
            value,
            span: self
                .source
                .span(start_token.span.start as usize, self.previous_end()),
        })
    }

    fn parse_if_let_statement(&mut self) -> Option<Stmt> {
        let start = self.expect(TokenKind::If)?.span.start as usize;
        self.expect(TokenKind::Let)?;
        let pattern = self.parse_pattern()?;
        self.expect(TokenKind::Equal)?;
        let value = self.parse_expr_with_named_literals(false)?;
        let then_block = self.parse_block_expr()?;
        let else_block = if self.consume(TokenKind::Else).is_some() {
            Some(self.parse_block_expr()?)
        } else {
            None
        };
        let end = else_block
            .as_ref()
            .map_or(then_block.span().end, |value| value.span().end);
        Some(Stmt::IfLet {
            pattern,
            value,
            then_block,
            else_block,
            span: self.source.span(start, end as usize),
        })
    }

    fn parse_while_statement(&mut self) -> Option<Stmt> {
        let start = self.expect(TokenKind::While)?.span.start as usize;
        let condition = self.parse_expr_with_named_literals(false)?;
        let body = self.parse_block_expr()?;
        Some(Stmt::While {
            condition,
            span: self.source.span(start, body.span().end as usize),
            body,
        })
    }

    fn parse_loop_statement(&mut self) -> Option<Stmt> {
        let start = self.expect(TokenKind::Loop)?.span.start as usize;
        let body = self.parse_block_expr()?;
        Some(Stmt::Loop {
            span: self.source.span(start, body.span().end as usize),
            body,
        })
    }

    fn parse_for_statement(&mut self) -> Option<Stmt> {
        let start = self.expect(TokenKind::For)?.span.start as usize;
        let binding = if let Some(open) = self.consume(TokenKind::LeftParen) {
            let mut names = Vec::new();
            names.push(self.expect_name()?);
            while self.consume(TokenKind::Comma).is_some() {
                if self.at(TokenKind::RightParen) {
                    break;
                }
                names.push(self.expect_name()?);
            }
            let close = self.expect(TokenKind::RightParen)?;
            if names.len() < 2 {
                self.report(Diagnostic::parse(
                    "E0101",
                    "For tuple bindings require at least two names",
                    open.span.join(close.span),
                    "()",
                ));
                return None;
            }
            ForBinding::Tuple(names, open.span.join(close.span))
        } else {
            ForBinding::Name(self.expect_name()?)
        };
        self.expect(TokenKind::In)?;
        let iterable = self.parse_expr_with_named_literals(false)?;
        let body = self.parse_block_expr()?;
        Some(Stmt::For {
            binding,
            iterable,
            span: self.source.span(start, body.span().end as usize),
            body,
        })
    }

    fn parse_expression_or_assignment_statement(&mut self) -> Option<Stmt> {
        let expression = self.parse_expr()?;
        let start = expression.span().start as usize;
        let op = match self.peek().kind {
            TokenKind::Equal => Some(AssignOp::Assign),
            TokenKind::PlusEqual => Some(AssignOp::AddAssign),
            TokenKind::MinusEqual => Some(AssignOp::SubtractAssign),
            TokenKind::StarEqual => Some(AssignOp::MultiplyAssign),
            TokenKind::SlashEqual => Some(AssignOp::DivideAssign),
            TokenKind::PercentEqual => Some(AssignOp::RemainderAssign),
            _ => None,
        };
        if let Some(op) = op {
            self.advance();
            let value = self.parse_expr()?;
            self.consume(TokenKind::Semicolon);
            if !is_assignment_target(&expression) {
                self.report(Diagnostic::parse(
                    "E0101",
                    "Assignment target must be a binding or named field path",
                    expression.span(),
                    "assignment target",
                ));
                return None;
            }
            return Some(Stmt::Assign {
                target: expression,
                op,
                value,
                span: self.source.span(start, self.previous_end()),
            });
        }
        let has_semicolon = self.consume(TokenKind::Semicolon).is_some();
        let end = if has_semicolon {
            self.previous_end()
        } else {
            expression.span().end as usize
        };
        Some(Stmt::Expression {
            expression,
            has_semicolon,
            span: self.source.span(start, end),
        })
    }

    fn parse_block_expr(&mut self) -> Option<Expr> {
        let open = self.expect(TokenKind::LeftBrace)?;
        let mut statements = Vec::new();
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            statements.push(self.parse_statement()?);
        }
        let close = self.expect(TokenKind::RightBrace)?;
        let tail = if matches!(
            statements.last(),
            Some(Stmt::Expression {
                has_semicolon: false,
                ..
            })
        ) {
            match statements.pop().expect("last element exists") {
                Stmt::Expression { expression, .. } => Some(Box::new(expression)),
                _ => unreachable!(),
            }
        } else {
            None
        };
        Some(Expr::Block {
            statements,
            tail,
            span: open.span.join(close.span),
        })
    }

    fn reject_try(&mut self) {
        let token = self.advance();
        self.report(
            Diagnostic::parse(
                "E0101",
                "'try' is reserved; use a catch expression",
                token.span,
                token.value,
            )
            .with_suggestion("Use `expression catch { pattern => handler }`", None),
        );
    }

    fn parse_expr(&mut self) -> Option<Expr> {
        self.parse_expr_with_named_literals(true)
    }

    fn parse_expr_with_named_literals(&mut self, allow_named_literals: bool) -> Option<Expr> {
        self.parse_expr_bp(0, allow_named_literals)
    }

    fn parse_expr_bp(&mut self, minimum: u8, allow_named_literals: bool) -> Option<Expr> {
        // Pratt invariant: a larger precedence binds tighter. Recursing with
        // the current precedence makes every binary level left-associative;
        // comparison chaining is rejected explicitly below.
        let mut left = self.parse_prefix(allow_named_literals)?;
        let mut saw_comparison = false;
        loop {
            if self.at(TokenKind::Question) {
                let token = self.advance();
                self.report(
                    Diagnostic::parse(
                        "E0101",
                        "Postfix '?' is not part of Vorton 0.1",
                        token.span,
                        token.value,
                    )
                    .with_suggestion("Use Option methods or an explicit catch expression", None),
                );
                return None;
            }
            if self.at(TokenKind::Dot) && 10 > minimum {
                left = self.parse_dot_expression(left)?;
                saw_comparison = false;
                continue;
            }
            if self.at(TokenKind::LeftParen) && 10 > minimum {
                if !self.call_parenthesis_is_same_line(left.span().end) {
                    break;
                }
                left = self.parse_call_expression(left)?;
                saw_comparison = false;
                continue;
            }
            if self.at(TokenKind::LeftBracket) && 10 > minimum {
                let start = left.span().start as usize;
                self.advance();
                let index = self.parse_expr()?;
                let close = self.expect(TokenKind::RightBracket)?;
                left = Expr::Index {
                    receiver: Box::new(left),
                    index: Box::new(index),
                    span: self.source.span(start, close.span.end as usize),
                };
                saw_comparison = false;
                continue;
            }
            if self.at(TokenKind::Catch) && 1 > minimum {
                left = self.parse_catch_expression(left)?;
                saw_comparison = false;
                continue;
            }
            let Some((precedence, operation)) = self.binary_operation(self.peek().kind) else {
                break;
            };
            if precedence <= minimum {
                break;
            }
            let comparison = matches!(
                operation,
                BinaryOp::Equal
                    | BinaryOp::NotEqual
                    | BinaryOp::Less
                    | BinaryOp::LessEqual
                    | BinaryOp::Greater
                    | BinaryOp::GreaterEqual
            );
            if comparison && saw_comparison {
                let token = self.peek().clone();
                self.report(Diagnostic::parse(
                    "E0101",
                    "Comparison operators are non-associative",
                    token.span,
                    token.value,
                ));
                return None;
            }
            let operator = self.advance();
            if matches!(operator.kind, TokenKind::DotDot | TokenKind::DotDotEqual) {
                let right = self.parse_expr_bp(precedence, allow_named_literals)?;
                let span = left.span().join(right.span());
                left = Expr::Range {
                    start: Box::new(left),
                    end: Box::new(right),
                    inclusive: operator.kind == TokenKind::DotDotEqual,
                    span,
                };
            } else {
                let right = self.parse_expr_bp(precedence, allow_named_literals)?;
                let span = left.span().join(right.span());
                left = Expr::Binary {
                    op: operation,
                    left: Box::new(left),
                    right: Box::new(right),
                    span,
                };
            }
            saw_comparison = comparison;
        }
        Some(left)
    }

    fn binary_operation(&self, kind: TokenKind) -> Option<(u8, BinaryOp)> {
        Some(match kind {
            TokenKind::PipePipe => (2, BinaryOp::Or),
            TokenKind::AmpAmp => (3, BinaryOp::And),
            TokenKind::EqualEqual => (4, BinaryOp::Equal),
            TokenKind::BangEqual => (4, BinaryOp::NotEqual),
            TokenKind::Less => (5, BinaryOp::Less),
            TokenKind::LessEqual => (5, BinaryOp::LessEqual),
            TokenKind::Greater => (5, BinaryOp::Greater),
            TokenKind::GreaterEqual => (5, BinaryOp::GreaterEqual),
            TokenKind::DotDot | TokenKind::DotDotEqual => (6, BinaryOp::Add),
            TokenKind::Plus => (7, BinaryOp::Add),
            TokenKind::Minus => (7, BinaryOp::Subtract),
            TokenKind::Star => (8, BinaryOp::Multiply),
            TokenKind::Slash => (8, BinaryOp::Divide),
            TokenKind::Percent => (8, BinaryOp::Remainder),
            _ => return None,
        })
    }

    fn parse_prefix(&mut self, allow_named_literals: bool) -> Option<Expr> {
        let token = self.peek().clone();
        match token.kind {
            TokenKind::Minus | TokenKind::Bang => {
                self.advance();
                let operand = self.parse_expr_bp(9, allow_named_literals)?;
                let op = if token.kind == TokenKind::Minus {
                    UnaryOp::Negate
                } else {
                    UnaryOp::Not
                };
                Some(Expr::Unary {
                    op,
                    span: token.span.join(operand.span()),
                    operand: Box::new(operand),
                })
            }
            TokenKind::Integer => {
                self.advance();
                Some(Expr::Integer {
                    lexeme: token.value,
                    span: token.span,
                })
            }
            TokenKind::Float => {
                self.advance();
                Some(Expr::Float {
                    lexeme: token.value,
                    span: token.span,
                })
            }
            TokenKind::String => {
                self.advance();
                Some(Expr::String {
                    value: token.value,
                    span: token.span,
                })
            }
            TokenKind::RawString => {
                self.advance();
                Some(Expr::RawString {
                    value: token.value,
                    span: token.span,
                })
            }
            TokenKind::InterpolationStart => self.parse_interpolated_string(),
            TokenKind::True | TokenKind::False => {
                self.advance();
                Some(Expr::Boolean {
                    value: token.kind == TokenKind::True,
                    span: token.span,
                })
            }
            TokenKind::LeftParen => self.parse_parenthesized_or_tuple_expr(),
            TokenKind::LeftBracket => self.parse_list_expr(),
            TokenKind::LeftBrace => self.parse_block_expr(),
            TokenKind::If => self.parse_if_expression(),
            TokenKind::Match => self.parse_match_expression(),
            TokenKind::Handle => self.parse_handle_expression(),
            TokenKind::Fn => self.parse_lambda_expression(),
            TokenKind::Unsafe => {
                let start = self.advance();
                let body = self.parse_block_expr()?;
                Some(Expr::Unsafe {
                    span: start.span.join(body.span()),
                    body: Box::new(body),
                })
            }
            TokenKind::Try => {
                self.reject_try();
                None
            }
            TokenKind::Identifier | TokenKind::Super => {
                let path = self.parse_path(false)?;
                if allow_named_literals
                    && self.path_may_name_literal(&path)
                    && self.at(TokenKind::LeftBrace)
                {
                    self.parse_named_literal(path)
                } else {
                    let span = path.span;
                    Some(Expr::Path { path, span })
                }
            }
            _ => {
                self.unexpected("expression");
                None
            }
        }
    }

    fn parse_parenthesized_or_tuple_expr(&mut self) -> Option<Expr> {
        let open = self.expect(TokenKind::LeftParen)?;
        if let Some(close) = self.consume(TokenKind::RightParen) {
            return Some(Expr::Unit {
                span: open.span.join(close.span),
            });
        }
        let first = self.parse_expr()?;
        if self.consume(TokenKind::Comma).is_some() {
            let mut elements = vec![first];
            if self.at(TokenKind::RightParen) {
                let close = self.advance();
                self.report(Diagnostic::parse(
                    "E0101",
                    "Single-element tuples are not supported",
                    open.span.join(close.span),
                    "(value,)",
                ));
                return None;
            }
            loop {
                elements.push(self.parse_expr()?);
                if self.consume(TokenKind::Comma).is_none() || self.at(TokenKind::RightParen) {
                    break;
                }
            }
            let close = self.expect(TokenKind::RightParen)?;
            Some(Expr::Tuple {
                elements,
                span: open.span.join(close.span),
            })
        } else {
            let close = self.expect(TokenKind::RightParen)?;
            Some(Expr::Parenthesized {
                inner: Box::new(first),
                span: open.span.join(close.span),
            })
        }
    }

    fn parse_list_expr(&mut self) -> Option<Expr> {
        let open = self.expect(TokenKind::LeftBracket)?;
        let mut elements = Vec::new();
        while !self.at(TokenKind::RightBracket) && !self.at(TokenKind::Eof) {
            elements.push(self.parse_expr()?);
            if self.consume(TokenKind::Comma).is_none() {
                break;
            }
        }
        let close = self.expect(TokenKind::RightBracket)?;
        Some(Expr::List {
            elements,
            span: open.span.join(close.span),
        })
    }

    fn parse_call_expression(&mut self, callee: Expr) -> Option<Expr> {
        let start = callee.span().start as usize;
        self.expect(TokenKind::LeftParen)?;
        let args = self.parse_argument_list()?;
        let close = self.expect(TokenKind::RightParen)?;
        Some(Expr::Call {
            callee: Box::new(callee),
            args,
            span: self.source.span(start, close.span.end as usize),
        })
    }

    fn parse_argument_list(&mut self) -> Option<Vec<Expr>> {
        let mut args = Vec::new();
        while !self.at(TokenKind::RightParen) && !self.at(TokenKind::Eof) {
            args.push(self.parse_expr()?);
            if self.consume(TokenKind::Comma).is_none() {
                break;
            }
        }
        Some(args)
    }

    fn parse_dot_expression(&mut self, receiver: Expr) -> Option<Expr> {
        let start = receiver.span().start as usize;
        self.expect(TokenKind::Dot)?;
        let token = self.peek().clone();
        if token.kind == TokenKind::Float {
            self.advance();
            let mut value = receiver;
            let mut offset = token.span.start as usize;
            for part in token.value.split('.') {
                let part_span = self.source.span(offset, offset + part.len());
                let span = self.source.span(start, part_span.end as usize);
                value = Expr::TupleFieldAccess {
                    receiver: Box::new(value),
                    index: part.to_owned(),
                    index_span: part_span,
                    span,
                };
                offset += part.len() + 1;
            }
            return Some(value);
        }
        if token.kind == TokenKind::Integer {
            self.advance();
            return Some(Expr::TupleFieldAccess {
                receiver: Box::new(receiver),
                index: token.value,
                index_span: token.span,
                span: self.source.span(start, token.span.end as usize),
            });
        }
        let field = self.expect_name()?;
        if self.call_parenthesis_is_same_line(field.span.end) {
            self.advance();
            let args = self.parse_argument_list()?;
            let close = self.expect(TokenKind::RightParen)?;
            Some(Expr::MethodCall {
                receiver: Box::new(receiver),
                method: field,
                args,
                span: self.source.span(start, close.span.end as usize),
            })
        } else {
            let end = field.span.end as usize;
            Some(Expr::FieldAccess {
                receiver: Box::new(receiver),
                field,
                span: self.source.span(start, end),
            })
        }
    }

    fn parse_named_literal(&mut self, path: Path) -> Option<Expr> {
        let start = path.span.start as usize;
        self.expect(TokenKind::LeftBrace)?;
        let spread = if self.consume(TokenKind::DotDot).is_some() {
            let value = self.parse_expr()?;
            if self.consume(TokenKind::Comma).is_none() && !self.at(TokenKind::RightBrace) {
                self.expected(TokenKind::Comma);
                return None;
            }
            Some(Box::new(value))
        } else {
            None
        };
        let mut fields = Vec::new();
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            let field_start = self.peek().span.start as usize;
            let name = self.expect_name()?;
            let (value, shorthand) = if self.consume(TokenKind::Colon).is_some() {
                (self.parse_expr()?, false)
            } else {
                let value_path = Path {
                    segments: vec![name.clone()],
                    span: name.span,
                };
                (
                    Expr::Path {
                        path: value_path,
                        span: name.span,
                    },
                    true,
                )
            };
            let end = value.span().end as usize;
            fields.push(FieldInit {
                name,
                value,
                shorthand,
                span: self.source.span(field_start, end),
            });
            if self.consume(TokenKind::Comma).is_none() {
                break;
            }
        }
        let close = self.expect(TokenKind::RightBrace)?;
        Some(Expr::NamedLiteral {
            path,
            spread,
            fields,
            span: self.source.span(start, close.span.end as usize),
        })
    }

    fn call_parenthesis_is_same_line(&self, callee_end: u32) -> bool {
        self.at(TokenKind::LeftParen)
            && self.source.line_index(callee_end) == self.source.line_index(self.peek().span.start)
    }

    fn path_may_name_literal(&self, path: &Path) -> bool {
        path.segments
            .last()
            .and_then(|value| value.text.chars().next())
            .is_some_and(|value| value.is_ascii_uppercase())
    }

    fn parse_interpolated_string(&mut self) -> Option<Expr> {
        let start = self.expect(TokenKind::InterpolationStart)?;
        let mut parts = Vec::new();
        if !start.value.is_empty() {
            parts.push(StringPart::Text {
                value: start.value,
                span: start.span,
            });
        }
        loop {
            let expression = self.parse_expr()?;
            parts.push(StringPart::Expression(expression));
            let segment = if self.at(TokenKind::InterpolationMiddle)
                || self.at(TokenKind::InterpolationEnd)
            {
                self.advance()
            } else {
                self.unexpected("string interpolation continuation");
                return None;
            };
            if !segment.value.is_empty() {
                parts.push(StringPart::Text {
                    value: segment.value.clone(),
                    span: segment.span,
                });
            }
            if segment.kind == TokenKind::InterpolationEnd {
                return Some(Expr::InterpolatedString {
                    parts,
                    span: start.span.join(segment.span),
                });
            }
        }
    }

    fn parse_if_expression(&mut self) -> Option<Expr> {
        let start = self.expect(TokenKind::If)?.span.start as usize;
        let condition = self.parse_expr_with_named_literals(false)?;
        let then_branch = self.parse_block_expr()?;
        let else_branch = if self.consume(TokenKind::Else).is_some() {
            if self.at(TokenKind::If) {
                Some(Box::new(self.parse_if_expression()?))
            } else {
                Some(Box::new(self.parse_block_expr()?))
            }
        } else {
            None
        };
        let end = else_branch
            .as_ref()
            .map_or(then_branch.span().end, |value| value.span().end);
        Some(Expr::If {
            condition: Box::new(condition),
            then_branch: Box::new(then_branch),
            else_branch,
            span: self.source.span(start, end as usize),
        })
    }

    fn parse_match_expression(&mut self) -> Option<Expr> {
        let start = self.expect(TokenKind::Match)?.span.start as usize;
        let scrutinee = self.parse_expr_with_named_literals(false)?;
        self.expect(TokenKind::LeftBrace)?;
        let mut arms = Vec::new();
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            arms.push(self.parse_match_arm()?);
            self.consume(TokenKind::Comma);
        }
        let close = self.expect(TokenKind::RightBrace)?;
        Some(Expr::Match {
            scrutinee: Box::new(scrutinee),
            arms,
            span: self.source.span(start, close.span.end as usize),
        })
    }

    fn parse_match_arm(&mut self) -> Option<MatchArm> {
        let start = self.peek().span.start as usize;
        let pattern = self.parse_or_pattern()?;
        let guard = if self.consume(TokenKind::If).is_some() {
            Some(self.parse_expr()?)
        } else {
            None
        };
        self.expect(TokenKind::FatArrow)?;
        let body = self.parse_arm_body()?;
        Some(MatchArm {
            pattern,
            guard,
            span: self.source.span(start, body.span().end as usize),
            body,
        })
    }

    fn parse_arm_body(&mut self) -> Option<Expr> {
        if self.at(TokenKind::Return) {
            self.parse_return_expression()
        } else {
            self.parse_expr()
        }
    }

    fn parse_catch_expression(&mut self, expression: Expr) -> Option<Expr> {
        let start = expression.span().start as usize;
        self.expect(TokenKind::Catch)?;
        self.expect(TokenKind::LeftBrace)?;
        let mut arms = Vec::new();
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            arms.push(self.parse_match_arm()?);
            self.consume(TokenKind::Comma);
        }
        let close = self.expect(TokenKind::RightBrace)?;
        Some(Expr::Catch {
            expression: Box::new(expression),
            arms,
            span: self.source.span(start, close.span.end as usize),
        })
    }

    fn parse_handle_expression(&mut self) -> Option<Expr> {
        let start = self.expect(TokenKind::Handle)?.span.start as usize;
        let body = self.parse_block_expr()?;
        self.expect(TokenKind::With)?;
        self.expect(TokenKind::LeftBrace)?;
        let mut handlers = Vec::new();
        if self.at(TokenKind::RightBrace) {
            self.report(Diagnostic::parse(
                "E0101",
                "A handle expression must provide at least one handler",
                self.peek().span,
                "}",
            ));
            return None;
        }
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            handlers.push(self.parse_effect_handler()?);
            if self.at(TokenKind::RightBrace) {
                break;
            }
            self.expect(TokenKind::Comma)?;
        }
        let close = self.expect(TokenKind::RightBrace)?;
        Some(Expr::Handle {
            body: Box::new(body),
            handlers,
            span: self.source.span(start, close.span.end as usize),
        })
    }

    fn parse_effect_handler(&mut self) -> Option<EffectHandler> {
        let start = self.peek().span.start as usize;
        let effect = self.parse_path(false)?;
        self.expect(TokenKind::Dot)?;
        let operation = self.expect_name()?;
        self.expect(TokenKind::LeftParen)?;
        let params = self.parse_params()?;
        self.expect(TokenKind::RightParen)?;
        self.expect(TokenKind::FatArrow)?;
        let body = self.parse_expr()?;
        Some(EffectHandler {
            effect,
            operation,
            params,
            span: self.source.span(start, body.span().end as usize),
            body,
        })
    }

    fn parse_lambda_expression(&mut self) -> Option<Expr> {
        let start = self.expect(TokenKind::Fn)?.span.start as usize;
        self.expect(TokenKind::LeftParen)?;
        let params = self.parse_params()?;
        self.expect(TokenKind::RightParen)?;
        let return_type = if self.consume(TokenKind::Arrow).is_some() {
            Some(self.parse_type_expr()?)
        } else {
            None
        };
        let body = self.parse_block_expr()?;
        Some(Expr::Lambda {
            params,
            return_type,
            span: self.source.span(start, body.span().end as usize),
            body: Box::new(body),
        })
    }

    fn parse_return_expression(&mut self) -> Option<Expr> {
        let token = self.expect(TokenKind::Return)?;
        let value = if self.at_any(&[
            TokenKind::Comma,
            TokenKind::RightBrace,
            TokenKind::Semicolon,
            TokenKind::Eof,
        ]) {
            None
        } else {
            Some(Box::new(self.parse_expr()?))
        };
        let end = value
            .as_ref()
            .map_or(token.span.end, |value| value.span().end);
        Some(Expr::Return {
            value,
            span: self.source.span(token.span.start as usize, end as usize),
        })
    }

    fn parse_pattern(&mut self) -> Option<Pattern> {
        self.parse_pattern_atom()
    }

    fn parse_or_pattern(&mut self) -> Option<Pattern> {
        let first = self.parse_pattern_atom()?;
        if !self.at(TokenKind::Pipe) {
            return Some(first);
        }
        let start = first.span().start as usize;
        let mut alternatives = vec![first];
        while self.consume(TokenKind::Pipe).is_some() {
            alternatives.push(self.parse_pattern_atom()?);
        }
        let end = alternatives
            .last()
            .expect("non-empty alternatives")
            .span()
            .end as usize;
        Some(Pattern::Or {
            alternatives,
            span: self.source.span(start, end),
        })
    }

    fn parse_pattern_atom(&mut self) -> Option<Pattern> {
        let token = self.peek().clone();
        if token.kind == TokenKind::Identifier && token.value == "_" {
            self.advance();
            return Some(Pattern::Wildcard { span: token.span });
        }
        if token.kind == TokenKind::Minus
            && matches!(self.peek_n(1).kind, TokenKind::Integer | TokenKind::Float)
        {
            let start = self.advance();
            let number = self.advance();
            let lexeme = format!("-{}", number.value);
            let literal = if number.kind == TokenKind::Integer {
                PatternLiteral::Integer(lexeme)
            } else {
                PatternLiteral::Float(lexeme)
            };
            return Some(Pattern::Literal {
                literal,
                span: start.span.join(number.span),
            });
        }
        match token.kind {
            TokenKind::Integer => {
                self.advance();
                return Some(Pattern::Literal {
                    literal: PatternLiteral::Integer(token.value),
                    span: token.span,
                });
            }
            TokenKind::Float => {
                self.advance();
                return Some(Pattern::Literal {
                    literal: PatternLiteral::Float(token.value),
                    span: token.span,
                });
            }
            TokenKind::String => {
                self.advance();
                return Some(Pattern::Literal {
                    literal: PatternLiteral::String(token.value),
                    span: token.span,
                });
            }
            TokenKind::RawString => {
                self.advance();
                self.report(Diagnostic::parse(
                    "E0101",
                    "Raw string literals are not supported in patterns",
                    token.span,
                    token.value,
                ));
                return None;
            }
            TokenKind::True | TokenKind::False => {
                self.advance();
                return Some(Pattern::Literal {
                    literal: PatternLiteral::Boolean(token.kind == TokenKind::True),
                    span: token.span,
                });
            }
            TokenKind::LeftParen => {
                let open = self.advance();
                let first = self.parse_pattern_atom()?;
                if self.consume(TokenKind::Comma).is_none() {
                    self.report(Diagnostic::parse("E0101", "Parenthesized patterns are not supported; tuple patterns require at least two elements", open.span, "("));
                    return None;
                }
                let mut elements = vec![first];
                if self.at(TokenKind::RightParen) {
                    self.report(Diagnostic::parse(
                        "E0101",
                        "Single-element tuple patterns are not supported",
                        open.span,
                        "(",
                    ));
                    return None;
                }
                loop {
                    elements.push(self.parse_pattern_atom()?);
                    if self.consume(TokenKind::Comma).is_none() || self.at(TokenKind::RightParen) {
                        break;
                    }
                }
                let close = self.expect(TokenKind::RightParen)?;
                return Some(Pattern::Tuple {
                    elements,
                    span: open.span.join(close.span),
                });
            }
            TokenKind::Identifier | TokenKind::Super => {}
            _ => {
                self.unexpected("pattern");
                return None;
            }
        }
        let path = self.parse_path(false)?;
        if self.consume(TokenKind::LeftParen).is_some() {
            if self.at(TokenKind::RightParen) {
                self.report(
                    Diagnostic::parse(
                        "E0101",
                        "Positional constructor patterns require at least one field; use the bare name for a unit pattern",
                        self.peek().span,
                        self.peek().value.clone(),
                    )
                    .with_suggestion("Remove the empty parentheses", None),
                );
                return None;
            }
            let mut fields = Vec::new();
            while !self.at(TokenKind::RightParen) && !self.at(TokenKind::Eof) {
                fields.push(self.parse_pattern_atom()?);
                if self.consume(TokenKind::Comma).is_none() {
                    break;
                }
            }
            let close = self.expect(TokenKind::RightParen)?;
            return Some(Pattern::Constructor {
                span: path.span.join(close.span),
                path,
                fields,
            });
        }
        if self.consume(TokenKind::LeftBrace).is_some() {
            let mut fields = Vec::new();
            let mut rest = None;
            while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
                if let Some(token) = self.consume(TokenKind::DotDot) {
                    rest = Some(token.span);
                    self.consume(TokenKind::Comma);
                    break;
                }
                let start = self.peek().span.start as usize;
                let name = self.expect_name()?;
                let (pattern, shorthand) = if self.consume(TokenKind::Colon).is_some() {
                    (self.parse_pattern_atom()?, false)
                } else if name.text == "_" {
                    (Pattern::Wildcard { span: name.span }, true)
                } else {
                    (
                        Pattern::Name {
                            name: name.clone(),
                            span: name.span,
                        },
                        true,
                    )
                };
                let end = pattern.span().end as usize;
                fields.push(NamedPatternField {
                    name,
                    pattern,
                    shorthand,
                    span: self.source.span(start, end),
                });
                if self.consume(TokenKind::Comma).is_none() {
                    break;
                }
            }
            let close = self.expect(TokenKind::RightBrace)?;
            return Some(Pattern::NamedConstructor {
                span: path.span.join(close.span),
                path,
                fields,
                rest,
            });
        }
        if path.segments.len() == 1 {
            let name = path.segments.into_iter().next().expect("one segment");
            Some(Pattern::Name {
                span: name.span,
                name,
            })
        } else {
            let span = path.span;
            Some(Pattern::Constructor {
                path,
                fields: Vec::new(),
                span,
            })
        }
    }

    fn parse_type_expr(&mut self) -> Option<TypeExpr> {
        let value = self.parse_type_atom()?;
        if self.at(TokenKind::Question) {
            let token = self.advance();
            self.report(
                Diagnostic::parse(
                    "E0101",
                    "Type suffix '?' is not part of Vorton 0.1; use Option<T>",
                    token.span,
                    token.value,
                )
                .with_suggestion("Write the type as `Option<T>`", None),
            );
            return None;
        }
        // Preserve the successfully parsed canonical prefix; rejected suffixes
        // never create AST variants or documentation-only carriers.
        Some(value)
    }

    fn parse_type_atom(&mut self) -> Option<TypeExpr> {
        let token = self.peek().clone();
        match token.kind {
            TokenKind::Fn => {
                let start = self.advance();
                self.expect(TokenKind::LeftParen)?;
                let mut params = Vec::new();
                while !self.at(TokenKind::RightParen) && !self.at(TokenKind::Eof) {
                    params.push(self.parse_type_expr()?);
                    if self.consume(TokenKind::Comma).is_none() {
                        break;
                    }
                }
                self.expect(TokenKind::RightParen)?;
                self.expect(TokenKind::Arrow)?;
                let return_type = self.parse_type_expr()?;
                let effects = self.parse_optional_effect_annotation()?;
                let end = effects
                    .as_ref()
                    .map_or(return_type.span().end, |value| value.span.end);
                Some(TypeExpr::Function {
                    params,
                    return_type: Box::new(return_type),
                    effects,
                    span: self.source.span(start.span.start as usize, end as usize),
                })
            }
            TokenKind::LeftParen => {
                let open = self.advance();
                let first = self.parse_type_expr()?;
                if self.consume(TokenKind::Comma).is_some() {
                    if self.at(TokenKind::RightParen) {
                        self.report(Diagnostic::parse(
                            "E0101",
                            "Single-element tuple types are not supported",
                            open.span,
                            "(",
                        ));
                        return None;
                    }
                    let mut elements = vec![first];
                    loop {
                        elements.push(self.parse_type_expr()?);
                        if self.consume(TokenKind::Comma).is_none()
                            || self.at(TokenKind::RightParen)
                        {
                            break;
                        }
                    }
                    let close = self.expect(TokenKind::RightParen)?;
                    Some(TypeExpr::Tuple {
                        elements,
                        span: open.span.join(close.span),
                    })
                } else {
                    let close = self.expect(TokenKind::RightParen)?;
                    Some(TypeExpr::Parenthesized {
                        inner: Box::new(first),
                        span: open.span.join(close.span),
                    })
                }
            }
            TokenKind::LeftBrace => self.parse_record_type(),
            TokenKind::Impl => {
                let invalid = self.advance();
                self.report(Diagnostic::parse("E0101", "Return-position 'impl Trait' and opaque type syntax are not part of Vorton 0.1", invalid.span, invalid.value));
                None
            }
            TokenKind::Identifier | TokenKind::Super => {
                let path = self.parse_path(false)?;
                let type_args = self.parse_type_arguments()?;
                let end = self.previous_end() as u32;
                Some(TypeExpr::Named {
                    span: self.source.span(path.span.start as usize, end as usize),
                    path,
                    type_args,
                })
            }
            _ => {
                self.unexpected("type expression");
                None
            }
        }
    }

    fn parse_record_type(&mut self) -> Option<TypeExpr> {
        let open = self.expect(TokenKind::LeftBrace)?;
        let mut fields = Vec::new();
        let mut rest = None;
        if self.at(TokenKind::RightBrace) {
            self.report(Diagnostic::parse(
                "E0101",
                "A record type must declare at least one named field",
                self.peek().span,
                "}",
            ));
            return None;
        }
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            if self.at(TokenKind::DotDot) {
                if fields.is_empty() {
                    let token = self.peek().clone();
                    self.report(Diagnostic::parse(
                        "E0101",
                        "A record type must declare at least one named field",
                        token.span,
                        token.value,
                    ));
                    return None;
                }
                self.advance();
                rest = Some(self.expect_name()?);
                self.consume(TokenKind::Comma);
                break;
            }
            let start = self.peek().span.start as usize;
            let name = self.expect_name()?;
            self.expect(TokenKind::Colon)?;
            let ty = self.parse_type_expr()?;
            let end = ty.span().end as usize;
            fields.push(NamedTypeField {
                name,
                ty,
                span: self.source.span(start, end),
            });
            if self.consume(TokenKind::Comma).is_none() {
                break;
            }
        }
        let close = self.expect(TokenKind::RightBrace)?;
        Some(TypeExpr::Record {
            fields,
            rest,
            span: open.span.join(close.span),
        })
    }

    fn parse_type_arguments(&mut self) -> Option<Vec<TypeExpr>> {
        if self.consume(TokenKind::Less).is_none() {
            return Some(Vec::new());
        }
        let mut values = Vec::new();
        if self.at(TokenKind::Greater) {
            self.report(Diagnostic::parse(
                "E0101",
                "Type arguments cannot be empty",
                self.peek().span,
                ">",
            ));
            return None;
        }
        while !self.at(TokenKind::Greater) && !self.at(TokenKind::Eof) {
            values.push(self.parse_type_expr()?);
            if self.consume(TokenKind::Comma).is_none() {
                break;
            }
        }
        self.expect(TokenKind::Greater)?;
        Some(values)
    }

    fn parse_type_params(&mut self) -> Option<Vec<TypeParam>> {
        if self.consume(TokenKind::Less).is_none() {
            return Some(Vec::new());
        }
        let mut values = Vec::new();
        if self.at(TokenKind::Greater) {
            self.report(Diagnostic::parse(
                "E0101",
                "Type parameters cannot be empty",
                self.peek().span,
                ">",
            ));
            return None;
        }
        while !self.at(TokenKind::Greater) && !self.at(TokenKind::Eof) {
            let start = self.peek().span.start as usize;
            let name = self.expect_name()?;
            let mut bounds = Vec::new();
            if self.consume(TokenKind::Colon).is_some() {
                loop {
                    bounds.push(self.parse_type_bound()?);
                    if self.consume(TokenKind::Plus).is_none() {
                        break;
                    }
                }
            }
            values.push(TypeParam {
                name,
                bounds,
                span: self.source.span(start, self.previous_end()),
            });
            if self.consume(TokenKind::Comma).is_none() {
                break;
            }
        }
        self.expect(TokenKind::Greater)?;
        Some(values)
    }

    fn parse_type_bound(&mut self) -> Option<TypeBound> {
        let path = self.parse_path(false)?;
        let start = path.span.start as usize;
        let mut type_args = Vec::new();
        let mut associated = Vec::new();
        if self.consume(TokenKind::Less).is_some() {
            if self.at(TokenKind::Greater) {
                let token = self.advance();
                self.report(Diagnostic::parse(
                    "E0101",
                    "Type bound arguments cannot be empty",
                    token.span,
                    token.value,
                ));
                return None;
            }
            while !self.at(TokenKind::Greater) && !self.at(TokenKind::Eof) {
                if self.at(TokenKind::Identifier) && self.peek_n(1).kind == TokenKind::Equal {
                    let item_start = self.peek().span.start as usize;
                    let name = self.expect_name()?;
                    self.expect(TokenKind::Equal)?;
                    let ty = self.parse_type_expr()?;
                    associated.push(AssociatedConstraint {
                        name,
                        span: self.source.span(item_start, ty.span().end as usize),
                        ty,
                    });
                } else {
                    type_args.push(self.parse_type_expr()?);
                }
                if self.consume(TokenKind::Comma).is_none() {
                    break;
                }
            }
            self.expect(TokenKind::Greater)?;
        }
        Some(TypeBound {
            path,
            type_args,
            associated,
            span: self.source.span(start, self.previous_end()),
        })
    }

    fn parse_optional_effect_annotation(&mut self) -> Option<Option<EffectSet>> {
        if self.consume(TokenKind::With).is_some() {
            Some(Some(self.parse_effect_set()?))
        } else {
            Some(None)
        }
    }

    fn parse_effect_set(&mut self) -> Option<EffectSet> {
        let open = self.expect(TokenKind::LeftBrace)?;
        let mut effects = Vec::new();
        while !self.at(TokenKind::RightBrace) && !self.at(TokenKind::Eof) {
            let start = self.peek().span.start as usize;
            let name = if self.at(TokenKind::Mut) {
                let token = self.advance();
                EffectName::Mutation(Name {
                    text: token.value,
                    span: token.span,
                })
            } else if self.at(TokenKind::Unsafe) {
                let token = self.advance();
                EffectName::Unsafe(Name {
                    text: token.value,
                    span: token.span,
                })
            } else {
                EffectName::Path(self.parse_path(false)?)
            };
            let type_args = self.parse_type_arguments()?;
            effects.push(EffectExpr {
                name,
                type_args,
                span: self.source.span(start, self.previous_end()),
            });
            if self.consume(TokenKind::Comma).is_none() {
                break;
            }
        }
        let close = self.expect(TokenKind::RightBrace)?;
        Some(EffectSet {
            effects,
            span: open.span.join(close.span),
        })
    }

    fn parse_path(&mut self, stop_before_group: bool) -> Option<Path> {
        let first = self.expect_path_segment()?;
        let start = first.span.start as usize;
        let mut segments = vec![first];
        while self.at(TokenKind::ColonColon) {
            if stop_before_group && self.peek_n(1).kind == TokenKind::LeftBrace {
                self.advance();
                break;
            }
            self.advance();
            segments.push(self.expect_path_segment()?);
        }
        let end = segments.last().expect("path has one segment").span.end as usize;
        Some(Path {
            segments,
            span: self.source.span(start, end),
        })
    }

    fn expect_path_segment(&mut self) -> Option<Name> {
        if self.at(TokenKind::Identifier) || self.at(TokenKind::Super) {
            let token = self.advance();
            Some(Name {
                text: token.value,
                span: token.span,
            })
        } else {
            self.expected(TokenKind::Identifier);
            None
        }
    }

    fn expect_name(&mut self) -> Option<Name> {
        if self.at(TokenKind::Identifier) {
            let token = self.advance();
            Some(Name {
                text: token.value,
                span: token.span,
            })
        } else {
            self.expected(TokenKind::Identifier);
            None
        }
    }

    fn unexpected(&mut self, expected: &str) {
        let token = self.peek().clone();
        self.report(Diagnostic::parse(
            "E0101",
            format!("Expected {expected}, found '{}'", token.value),
            token.span,
            token.value,
        ));
    }

    fn expected(&mut self, expected: TokenKind) {
        let token = self.peek().clone();
        self.report(
            Diagnostic::parse(
                "E0103",
                format!(
                    "Expected '{}', found '{}'",
                    expected.spelling(),
                    token.value
                ),
                token.span,
                token.value,
            )
            .with_expected([expected.spelling()]),
        );
    }

    fn report(&mut self, diagnostic: Diagnostic) {
        if self.diagnostics.is_empty() {
            push_diagnostic(&mut self.diagnostics, diagnostic);
        }
    }

    fn previous_end(&self) -> usize {
        self.tokens
            .get(self.position.saturating_sub(1))
            .map_or(0, |token| token.span.end as usize)
    }

    fn at_contextual(&self, value: &str) -> bool {
        self.at(TokenKind::Identifier) && self.peek().value == value
    }

    fn at_any(&self, kinds: &[TokenKind]) -> bool {
        kinds.contains(&self.peek().kind)
    }

    fn at(&self, kind: TokenKind) -> bool {
        self.peek().kind == kind
    }

    fn peek(&self) -> &Token {
        self.peek_n(0)
    }

    fn peek_n(&self, offset: usize) -> &Token {
        self.tokens
            .get(self.position + offset)
            .unwrap_or_else(|| self.tokens.last().expect("lexer always emits EOF"))
    }

    fn advance(&mut self) -> Token {
        let token = self.peek().clone();
        if self.position < self.tokens.len() {
            self.position += 1;
        }
        token
    }

    fn consume(&mut self, kind: TokenKind) -> Option<Token> {
        if self.at(kind) {
            Some(self.advance())
        } else {
            None
        }
    }

    fn expect(&mut self, kind: TokenKind) -> Option<Token> {
        if self.at(kind) {
            Some(self.advance())
        } else {
            self.expected(kind);
            None
        }
    }
}

fn is_assignment_target(expression: &Expr) -> bool {
    match expression {
        Expr::Path { path, .. } => path.segments.len() == 1,
        Expr::FieldAccess { receiver, .. } => is_assignment_target(receiver),
        _ => false,
    }
}
