use crate::ast::*;
use crate::diagnostic::{ExpectedToken, FrontendDiagnostic, LayoutDiagnosticKind};
use crate::lexer::{Tag, Token, TokenKind};

pub(crate) fn parse(
    tokens: Vec<Token>,
    source_length: usize,
) -> Result<Program, FrontendDiagnostic> {
    let mut parser = Parser {
        tokens,
        index: 0,
        newlines: true,
        at_item_start: true,
        layout_error: None,
        depth: 0,
    };
    let result = parser.parse_program(source_length);
    let program = match parser.layout_error.take() {
        None => result,
        Some(layout) => match result {
            Err(error) if error.span.start < layout.span.start => Err(error),
            _ => Err(layout),
        },
    }?;
    match crate::depth::too_deep(&program) {
        None => Ok(program),
        Some(span) => Err(FrontendDiagnostic::too_deep(span)),
    }
}

struct Parser {
    tokens: Vec<Token>,
    index: usize,
    /// Whether line breaks end items in the innermost construct, which holds
    /// inside statement sequences but not inside `()`, `[]` or field lists.
    newlines: bool,
    /// Whether the current token starts a new item of a statement sequence.
    at_item_start: bool,
    /// The first line break that continued an item it should have ended.
    layout_error: Option<FrontendDiagnostic>,
    /// How many expressions, types, patterns and blocks enclose the current
    /// token, which is at most the depth of the tree being built.
    depth: usize,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ParameterContext {
    /// Named functions, methods and trait methods: types required, receiver allowed.
    Function,
    /// `extern fn` and effect operations: types required, no receiver.
    Fixed,
    /// Closures: types optional.
    Closure,
    /// Effect handlers: types optional, no modes.
    Handler,
}

impl Parser {
    /// Parses one level of nesting with `parse`. Source that nests deeper
    /// than the spec allows is rejected before the recursion grows further.
    fn nested<T>(
        &mut self,
        parse: impl FnOnce(&mut Self) -> Result<T, FrontendDiagnostic>,
    ) -> Result<T, FrontendDiagnostic> {
        if self.depth >= crate::depth::MAX_NESTING {
            return Err(FrontendDiagnostic::too_deep(self.current().span));
        }
        self.depth += 1;
        let result = parse(self);
        self.depth -= 1;
        result
    }

    fn parse_program(&mut self, source_length: usize) -> Result<Program, FrontendDiagnostic> {
        self.at_item_start = true;
        let requires = if self.at(Tag::Requires) {
            let requires = self.parse_file_requires()?;
            self.end_item(Tag::Eof, Tag::Semicolon)?;
            Some(requires)
        } else {
            None
        };
        let uses = self.parse_use_declarations(Tag::Eof)?;
        let mut items = Vec::new();
        loop {
            self.at_item_start = true;
            if self.at(Tag::Eof) {
                break;
            }
            items.push(self.parse_declaration(Tag::Eof)?);
            self.end_item(Tag::Eof, Tag::Semicolon)?;
        }
        self.expect(Tag::Eof)?;
        Ok(Program {
            span: Span::new(0, source_length),
            requires,
            uses,
            items,
        })
    }

    /// Checks the separator after one item of a statement sequence and
    /// consumes it when it is an explicit `separator` token.
    fn end_item(&mut self, closer: Tag, separator: Tag) -> Result<(), FrontendDiagnostic> {
        if self.at(closer) || self.current().newline_before {
            return Ok(());
        }
        if self.at(separator) {
            let token = self.bump();
            if self.at(closer) || self.current().newline_before {
                return Err(FrontendDiagnostic::layout(
                    token.span,
                    LayoutDiagnosticKind::TrailingSeparator,
                ));
            }
            return Ok(());
        }
        Err(FrontendDiagnostic::layout(
            self.current().span,
            LayoutDiagnosticKind::MissingSeparator,
        ))
    }

    fn parse_file_requires(&mut self) -> Result<FileRequires, FrontendDiagnostic> {
        let start = self.expect(Tag::Requires)?.span.start;
        let effects = self.parse_effect_set()?;
        Ok(FileRequires {
            span: Span::new(start, effects.span.end),
            effects,
        })
    }

    fn parse_use_declarations(
        &mut self,
        closer: Tag,
    ) -> Result<Vec<UseDeclaration>, FrontendDiagnostic> {
        let mut uses = Vec::new();
        loop {
            self.at_item_start = true;
            if !self.at_use_declaration() {
                return Ok(uses);
            }
            uses.push(self.parse_use_declaration()?);
            self.end_item(closer, Tag::Semicolon)?;
        }
    }

    fn at_use_declaration(&self) -> bool {
        self.at(Tag::Use) || (self.at(Tag::Pub) && self.nth_tag(1) == Tag::Use)
    }

    fn parse_use_declaration(&mut self) -> Result<UseDeclaration, FrontendDiagnostic> {
        let start = self.current().span.start;
        let visibility = self.parse_visibility();
        self.expect(Tag::Use)?;
        let path = self.parse_path(true)?;
        let suffix = if self.eat(Tag::As).is_some() {
            Some(UseSuffix::Alias(self.expect_identifier()?))
        } else if self.at(Tag::ColonColon) && self.nth_tag(1) == Tag::LBrace {
            let suffix_start = self.bump().span.start;
            self.expect(Tag::LBrace)?;
            let saved = self.enter(false);
            let mut items = Vec::new();
            if !self.at(Tag::RBrace) {
                loop {
                    let item_start = self.current().span.start;
                    let name = self.expect_identifier()?;
                    let alias = if self.eat(Tag::As).is_some() {
                        Some(self.expect_identifier()?)
                    } else {
                        None
                    };
                    let item_end = alias.as_ref().map_or(name.span.end, |alias| alias.span.end);
                    items.push(UseItem {
                        span: Span::new(item_start, item_end),
                        name,
                        alias,
                    });
                    if self.eat(Tag::Comma).is_none() || self.at(Tag::RBrace) {
                        break;
                    }
                }
            }
            let end = self.expect(Tag::RBrace)?.span.end;
            self.newlines = saved;
            Some(UseSuffix::Items {
                span: Span::new(suffix_start, end),
                items,
            })
        } else {
            None
        };
        Ok(UseDeclaration {
            span: Span::new(start, self.previous_end()),
            visibility,
            path,
            suffix,
        })
    }

    fn parse_declaration(&mut self, enclosing_end: Tag) -> Result<Declaration, FrontendDiagnostic> {
        let start = self.current().span.start;
        if self.eat(Tag::Impl).is_some() {
            let kind = self.parse_impl_declaration()?;
            return Ok(Spanned::new(kind, Span::new(start, self.previous_end())));
        }

        let visibility = self.parse_visibility();
        let has_visibility = visibility.is_some();
        let kind = match self.current_tag() {
            Tag::Fn => {
                self.bump();
                DeclarationKind::Function(Declared {
                    visibility,
                    item: self.parse_function_declaration()?,
                })
            }
            Tag::Struct => {
                self.bump();
                DeclarationKind::Struct(Declared {
                    visibility,
                    item: self.parse_struct_declaration()?,
                })
            }
            Tag::Enum => {
                self.bump();
                DeclarationKind::Enum(Declared {
                    visibility,
                    item: self.parse_enum_declaration()?,
                })
            }
            Tag::Trait => {
                self.bump();
                DeclarationKind::Trait(Declared {
                    visibility,
                    item: self.parse_trait_declaration()?,
                })
            }
            Tag::Effect => {
                self.bump();
                if self.at_contextual("alias") && self.nth_tag(1) == Tag::Ident {
                    self.bump();
                    DeclarationKind::EffectAlias(Declared {
                        visibility,
                        item: self.parse_effect_alias_declaration()?,
                    })
                } else {
                    DeclarationKind::Effect(Declared {
                        visibility,
                        item: self.parse_effect_declaration()?,
                    })
                }
            }
            Tag::Extern => {
                self.bump();
                DeclarationKind::Extern(Declared {
                    visibility,
                    item: self.parse_extern_declaration()?,
                })
            }
            Tag::Const => {
                self.bump();
                DeclarationKind::Const(Declared {
                    visibility,
                    item: self.parse_const_declaration()?,
                })
            }
            Tag::Mod => {
                self.bump();
                DeclarationKind::Module(Declared {
                    visibility,
                    item: self.parse_module_declaration()?,
                })
            }
            Tag::Ident if self.at_contextual("type") => {
                self.bump();
                DeclarationKind::TypeAlias(Declared {
                    visibility,
                    item: self.parse_type_alias_declaration()?,
                })
            }
            _ => {
                return Err(self.unexpected(declaration_expectations(
                    !has_visibility,
                    (!has_visibility).then_some(enclosing_end),
                )));
            }
        };
        Ok(Spanned::new(kind, Span::new(start, self.previous_end())))
    }

    fn parse_visibility(&mut self) -> Option<Visibility> {
        self.eat(Tag::Pub)
            .map(|token| Visibility { span: token.span })
    }

    fn parse_function_declaration(&mut self) -> Result<FunctionDeclaration, FrontendDiagnostic> {
        let signature = self.parse_function_signature(ParameterContext::Function)?;
        let body = self.parse_block()?;
        Ok(FunctionDeclaration { signature, body })
    }

    fn parse_function_signature(
        &mut self,
        context: ParameterContext,
    ) -> Result<FunctionSignature, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let (type_parameters, effect_parameters) = self.parse_callable_parameters()?;
        let parameters = self.parse_parameters(context)?;
        let (return_borrow, return_type) = if self.eat(Tag::Arrow).is_some() {
            (self.parse_borrow(), Some(self.parse_type_expr()?))
        } else {
            (None, None)
        };
        let effects = if self.eat(Tag::With).is_some() {
            Some(self.parse_effect_set()?)
        } else {
            None
        };
        Ok(FunctionSignature {
            name,
            type_parameters,
            effect_parameters,
            parameters,
            return_borrow,
            return_type,
            effects,
        })
    }

    fn parse_parameters(
        &mut self,
        context: ParameterContext,
    ) -> Result<Vec<Parameter>, FrontendDiagnostic> {
        self.expect(Tag::LParen)?;
        let saved = self.enter(false);
        let mut parameters = Vec::new();
        if !self.at(Tag::RParen) {
            loop {
                let receiver = parameters.is_empty() && context == ParameterContext::Function;
                parameters.push(self.parse_parameter(context, receiver)?);
                if self.eat(Tag::Comma).is_none() || self.at(Tag::RParen) {
                    break;
                }
            }
        }
        self.expect(Tag::RParen)?;
        self.newlines = saved;
        Ok(parameters)
    }

    fn parse_parameter(
        &mut self,
        context: ParameterContext,
        receiver: bool,
    ) -> Result<Parameter, FrontendDiagnostic> {
        let start = self.current().span.start;
        if receiver && self.at(Tag::Amp) {
            let borrow = self.parse_borrow();
            if !self.at_contextual("self") {
                return Err(self.unexpected(vec![ExpectedToken::Fixed("self".to_owned())]));
            }
            let name = self.expect_identifier()?;
            return Ok(Parameter {
                span: Span::new(start, name.span.end),
                mutable: None,
                name,
                borrow,
                ty: None,
            });
        }
        let mutable = if matches!(
            context,
            ParameterContext::Function | ParameterContext::Closure
        ) {
            self.eat(Tag::Mut).map(|keyword| keyword.span)
        } else {
            None
        };
        let name = self.expect_identifier()?;
        if receiver && name.text == "self" {
            return Ok(Parameter {
                span: Span::new(start, name.span.end),
                mutable,
                name,
                borrow: None,
                ty: None,
            });
        }
        if self.eat(Tag::Colon).is_some() {
            let borrow = if context == ParameterContext::Handler {
                None
            } else {
                self.parse_borrow()
            };
            let ty = self.parse_type_expr()?;
            return Ok(Parameter {
                span: Span::new(start, ty.span.end),
                mutable,
                name,
                borrow,
                ty: Some(ty),
            });
        }
        if matches!(
            context,
            ParameterContext::Closure | ParameterContext::Handler
        ) {
            return Ok(Parameter {
                span: Span::new(start, name.span.end),
                mutable,
                name,
                borrow: None,
                ty: None,
            });
        }
        Err(self.unexpected(vec![Tag::Colon.expected()]))
    }

    /// `&` or `&mut`, if present.
    fn parse_borrow(&mut self) -> Option<Spanned<BorrowKind>> {
        let ampersand = self.eat(Tag::Amp)?;
        Some(match self.eat(Tag::Mut) {
            Some(keyword) => Spanned::new(
                BorrowKind::Mutable,
                Span::new(ampersand.span.start, keyword.span.end),
            ),
            None => Spanned::new(BorrowKind::Shared, ampersand.span),
        })
    }

    fn parse_struct_declaration(&mut self) -> Result<StructDeclaration, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let type_parameters = self.parse_type_parameters()?;
        self.expect(Tag::LBrace)?;
        let saved = self.enter(false);
        let mut fields = Vec::new();
        if !self.at(Tag::RBrace) {
            loop {
                let start = self.current().span.start;
                let visibility = self.parse_visibility();
                let field_name = self.expect_identifier()?;
                self.expect(Tag::Colon)?;
                let ty = self.parse_type_expr()?;
                fields.push(StructField {
                    span: Span::new(start, ty.span.end),
                    visibility,
                    name: field_name,
                    ty,
                });
                if self.eat(Tag::Comma).is_none() || self.at(Tag::RBrace) {
                    break;
                }
            }
        }
        self.expect(Tag::RBrace)?;
        self.newlines = saved;
        Ok(StructDeclaration {
            name,
            type_parameters,
            fields,
        })
    }

    fn parse_enum_declaration(&mut self) -> Result<EnumDeclaration, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let type_parameters = self.parse_type_parameters()?;
        self.expect(Tag::LBrace)?;
        let saved = self.enter(false);
        let mut variants = Vec::new();
        if !self.at(Tag::RBrace) {
            loop {
                let start = self.current().span.start;
                let variant_name = self.expect_identifier()?;
                let fields = if self.eat(Tag::LParen).is_some() {
                    let mut values = vec![self.parse_type_expr()?];
                    while self.eat(Tag::Comma).is_some() && !self.at(Tag::RParen) {
                        values.push(self.parse_type_expr()?);
                    }
                    self.expect(Tag::RParen)?;
                    VariantFields::Positional(values)
                } else if self.eat(Tag::LBrace).is_some() {
                    let mut values = Vec::new();
                    if !self.at(Tag::RBrace) {
                        loop {
                            values.push(self.parse_named_field()?);
                            if self.eat(Tag::Comma).is_none() || self.at(Tag::RBrace) {
                                break;
                            }
                        }
                    }
                    self.expect(Tag::RBrace)?;
                    VariantFields::Named(values)
                } else {
                    VariantFields::Unit
                };
                variants.push(EnumVariant {
                    span: Span::new(start, self.previous_end()),
                    name: variant_name,
                    fields,
                });
                if self.eat(Tag::Comma).is_none() || self.at(Tag::RBrace) {
                    break;
                }
            }
        }
        self.expect(Tag::RBrace)?;
        self.newlines = saved;
        Ok(EnumDeclaration {
            name,
            type_parameters,
            variants,
        })
    }

    fn parse_named_field(&mut self) -> Result<NamedField, FrontendDiagnostic> {
        let start = self.current().span.start;
        let name = self.expect_identifier()?;
        self.expect(Tag::Colon)?;
        let ty = self.parse_type_expr()?;
        Ok(NamedField {
            span: Span::new(start, ty.span.end),
            name,
            ty,
        })
    }

    fn parse_impl_declaration(&mut self) -> Result<DeclarationKind, FrontendDiagnostic> {
        let type_parameters = self.parse_type_parameters()?;
        let first_type = self.parse_named_type()?;
        if self.eat(Tag::For).is_some() {
            let target = self.parse_named_type()?;
            let where_clause = if self.at(Tag::Where) {
                Some(self.parse_where_clause()?)
            } else {
                None
            };
            let members = self.parse_impl_members(false)?;
            Ok(DeclarationKind::TraitImpl(TraitImplDeclaration {
                type_parameters,
                trait_type: first_type,
                target,
                where_clause,
                members,
            }))
        } else {
            let members = self.parse_impl_members(true)?;
            Ok(DeclarationKind::InherentImpl(InherentImplDeclaration {
                type_parameters,
                target: first_type,
                members,
            }))
        }
    }

    fn parse_impl_members(
        &mut self,
        inherent: bool,
    ) -> Result<Vec<ImplMember>, FrontendDiagnostic> {
        self.expect(Tag::LBrace)?;
        let saved = self.enter(true);
        let mut members = Vec::new();
        loop {
            self.at_item_start = true;
            if self.at(Tag::RBrace) {
                break;
            }
            members.push(self.parse_impl_member(inherent)?);
            self.end_item(Tag::RBrace, Tag::Semicolon)?;
        }
        self.expect(Tag::RBrace)?;
        self.newlines = saved;
        Ok(members)
    }

    fn parse_where_clause(&mut self) -> Result<WhereClause, FrontendDiagnostic> {
        let keyword = self.expect(Tag::Where)?;
        let mut predicates = Vec::new();
        loop {
            let start = self.current().span.start;
            let subject = self.parse_type_expr()?;
            self.expect(Tag::Colon)?;
            let bounds = self.parse_bounds()?;
            let end = bounds.last().expect("where predicate has a bound").span.end;
            predicates.push(WherePredicate {
                span: Span::new(start, end),
                subject,
                bounds,
            });
            if self.eat(Tag::Comma).is_none() || self.at(Tag::LBrace) {
                break;
            }
        }
        Ok(WhereClause {
            span: Span::new(keyword.span.start, self.previous_end()),
            keyword_span: keyword.span,
            predicates,
        })
    }

    fn parse_bounds(&mut self) -> Result<Vec<NamedType>, FrontendDiagnostic> {
        let mut bounds = vec![self.parse_named_type()?];
        while self.eat(Tag::Plus).is_some() {
            bounds.push(self.parse_named_type()?);
        }
        Ok(bounds)
    }

    fn parse_impl_member(&mut self, inherent: bool) -> Result<ImplMember, FrontendDiagnostic> {
        let start = self.current().span.start;
        let visibility = if inherent {
            self.parse_visibility()
        } else {
            None
        };
        let kind = if self.eat(Tag::Fn).is_some() {
            ImplMemberKind::Function(self.parse_function_declaration()?)
        } else if self.at_contextual("type") {
            self.bump();
            let name = self.expect_identifier()?;
            self.expect(Tag::Equal)?;
            let value = self.parse_type_expr()?;
            ImplMemberKind::AssociatedType(AssociatedTypeValue { name, value })
        } else {
            return Err(self.unexpected(vec![
                Tag::Fn.expected(),
                ExpectedToken::Fixed("type".to_owned()),
            ]));
        };
        Ok(ImplMember {
            span: Span::new(start, self.previous_end()),
            visibility,
            kind,
        })
    }

    fn parse_trait_declaration(&mut self) -> Result<TraitDeclaration, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let type_parameters = self.parse_type_parameters()?;
        let supertraits = if self.eat(Tag::Colon).is_some() {
            self.parse_bounds()?
        } else {
            Vec::new()
        };
        self.expect(Tag::LBrace)?;
        let saved = self.enter(true);
        let mut members = Vec::new();
        loop {
            self.at_item_start = true;
            if self.at(Tag::RBrace) {
                break;
            }
            let start = self.current().span.start;
            let kind = if self.eat(Tag::Fn).is_some() {
                TraitMemberKind::Method(self.parse_function_signature(ParameterContext::Function)?)
            } else if self.at_contextual("type") {
                self.bump();
                let name = self.expect_identifier()?;
                let bounds = if self.eat(Tag::Colon).is_some() {
                    self.parse_bounds()?
                } else {
                    Vec::new()
                };
                let default = if self.eat(Tag::Equal).is_some() {
                    Some(self.parse_type_expr()?)
                } else {
                    None
                };
                TraitMemberKind::AssociatedType(TraitAssociatedType {
                    name,
                    bounds,
                    default,
                })
            } else {
                return Err(self.unexpected(vec![
                    Tag::Fn.expected(),
                    ExpectedToken::Fixed("type".to_owned()),
                    Tag::RBrace.expected(),
                ]));
            };
            members.push(Spanned::new(kind, Span::new(start, self.previous_end())));
            self.end_item(Tag::RBrace, Tag::Semicolon)?;
        }
        self.expect(Tag::RBrace)?;
        self.newlines = saved;
        Ok(TraitDeclaration {
            name,
            type_parameters,
            supertraits,
            members,
        })
    }

    fn parse_effect_declaration(&mut self) -> Result<EffectDeclaration, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let type_parameters = self.parse_type_parameters()?;
        self.expect(Tag::LBrace)?;
        let saved = self.enter(true);
        let mut operations = Vec::new();
        loop {
            self.at_item_start = true;
            if self.at(Tag::RBrace) {
                break;
            }
            let start = self.expect(Tag::Fn)?.span.start;
            let operation_name = self.expect_identifier()?;
            let parameters = self.parse_parameters(ParameterContext::Fixed)?;
            self.expect(Tag::Arrow)?;
            let return_type = self.parse_type_expr()?;
            operations.push(EffectOperation {
                span: Span::new(start, return_type.span.end),
                name: operation_name,
                parameters,
                return_type,
            });
            self.end_item(Tag::RBrace, Tag::Semicolon)?;
        }
        self.expect(Tag::RBrace)?;
        self.newlines = saved;
        Ok(EffectDeclaration {
            name,
            type_parameters,
            operations,
        })
    }

    fn parse_effect_alias_declaration(
        &mut self,
    ) -> Result<EffectAliasDeclaration, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let type_parameters = self.parse_type_parameters()?;
        self.expect(Tag::Equal)?;
        let effects = self.parse_effect_set()?;
        Ok(EffectAliasDeclaration {
            name,
            type_parameters,
            effects,
        })
    }

    fn parse_extern_declaration(&mut self) -> Result<ExternDeclaration, FrontendDiagnostic> {
        if self.eat(Tag::Fn).is_some() {
            let signature = self.parse_function_signature(ParameterContext::Fixed)?;
            if signature.effects.is_none() {
                return Err(self.unexpected(vec![Tag::With.expected()]));
            }
            Ok(ExternDeclaration::Function(Box::new(signature)))
        } else if self.at_contextual("type") {
            self.bump();
            let name = self.expect_identifier()?;
            let type_parameters = self.parse_type_parameters()?;
            Ok(ExternDeclaration::Type {
                name,
                type_parameters,
            })
        } else {
            Err(self.unexpected(vec![
                Tag::Fn.expected(),
                ExpectedToken::Fixed("type".to_owned()),
            ]))
        }
    }

    fn parse_type_alias_declaration(&mut self) -> Result<TypeAliasDeclaration, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let type_parameters = self.parse_type_parameters()?;
        self.expect(Tag::Equal)?;
        let value = self.parse_type_expr()?;
        Ok(TypeAliasDeclaration {
            name,
            type_parameters,
            value,
        })
    }

    fn parse_const_declaration(&mut self) -> Result<ConstDeclaration, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let annotation = if self.eat(Tag::Colon).is_some() {
            Some(self.parse_type_expr()?)
        } else {
            None
        };
        self.expect(Tag::Equal)?;
        let value = self.parse_expr()?;
        Ok(ConstDeclaration {
            name,
            annotation,
            value,
        })
    }

    fn parse_module_declaration(&mut self) -> Result<ModuleDeclaration, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let requires = if self.eat(Tag::Requires).is_some() {
            Some(self.parse_effect_set()?)
        } else {
            None
        };
        self.expect(Tag::LBrace)?;
        let saved = self.enter(true);
        let uses = self.parse_use_declarations(Tag::RBrace)?;
        let mut items = Vec::new();
        loop {
            self.at_item_start = true;
            if self.at(Tag::RBrace) {
                break;
            }
            items.push(self.parse_declaration(Tag::RBrace)?);
            self.end_item(Tag::RBrace, Tag::Semicolon)?;
        }
        self.expect(Tag::RBrace)?;
        self.newlines = saved;
        Ok(ModuleDeclaration {
            name,
            requires,
            uses,
            items,
        })
    }

    fn parse_type_parameters(&mut self) -> Result<Vec<TypeParameter>, FrontendDiagnostic> {
        if self.eat(Tag::Less).is_none() {
            return Ok(Vec::new());
        }
        let saved = self.enter(false);
        let mut parameters = Vec::new();
        loop {
            parameters.push(self.parse_type_parameter()?);
            if self.eat(Tag::Comma).is_none() || self.at(Tag::Greater) {
                break;
            }
        }
        self.expect(Tag::Greater)?;
        self.newlines = saved;
        Ok(parameters)
    }

    fn parse_callable_parameters(
        &mut self,
    ) -> Result<(Vec<TypeParameter>, Vec<EffectParameter>), FrontendDiagnostic> {
        if self.eat(Tag::Less).is_none() {
            return Ok((Vec::new(), Vec::new()));
        }
        let saved = self.enter(false);
        let mut type_parameters = Vec::new();
        let mut effect_parameters = Vec::new();
        let mut saw_effect = false;
        loop {
            if self.at(Tag::Effect) {
                saw_effect = true;
                let start = self.bump().span.start;
                let name = self.expect_identifier()?;
                effect_parameters.push(EffectParameter {
                    span: Span::new(start, name.span.end),
                    name,
                });
            } else if saw_effect {
                return Err(self.unexpected(vec![Tag::Effect.expected()]));
            } else {
                type_parameters.push(self.parse_type_parameter()?);
            }
            if self.eat(Tag::Comma).is_none() || self.at(Tag::Greater) {
                break;
            }
        }
        self.expect(Tag::Greater)?;
        self.newlines = saved;
        Ok((type_parameters, effect_parameters))
    }

    fn parse_type_parameter(&mut self) -> Result<TypeParameter, FrontendDiagnostic> {
        let start = self.current().span.start;
        let name = self.expect_identifier()?;
        let bounds = if self.eat(Tag::Colon).is_some() {
            self.parse_bounds()?
        } else {
            Vec::new()
        };
        let end = bounds.last().map_or(name.span.end, |bound| bound.span.end);
        Ok(TypeParameter {
            span: Span::new(start, end),
            name,
            bounds,
        })
    }

    fn parse_type_expr(&mut self) -> Result<TypeExpr, FrontendDiagnostic> {
        self.nested(Self::parse_type_level)
    }

    fn parse_type_level(&mut self) -> Result<TypeExpr, FrontendDiagnostic> {
        match self.current_tag() {
            Tag::LParen => self.parse_parenthesized_type(),
            Tag::Fn => self.parse_function_type(),
            Tag::Ident | Tag::Super => {
                let named = self.parse_named_type()?;
                Ok(Spanned::new(TypeKind::Named(named.kind), named.span))
            }
            _ => Err(self.unexpected(type_expectations())),
        }
    }

    fn parse_function_type(&mut self) -> Result<TypeExpr, FrontendDiagnostic> {
        let start = self.expect(Tag::Fn)?.span.start;
        self.expect(Tag::LParen)?;
        let saved = self.enter(false);
        let mut parameters = Vec::new();
        if !self.at(Tag::RParen) {
            loop {
                let parameter_start = self.current().span.start;
                let borrow = self.parse_borrow();
                let ty = self.parse_type_expr()?;
                parameters.push(FunctionTypeParameter {
                    span: Span::new(parameter_start, ty.span.end),
                    borrow,
                    ty,
                });
                if self.eat(Tag::Comma).is_none() || self.at(Tag::RParen) {
                    break;
                }
            }
        }
        self.expect(Tag::RParen)?;
        self.newlines = saved;
        let (return_borrow, return_type) = if self.eat(Tag::Arrow).is_some() {
            (self.parse_borrow(), Some(Box::new(self.parse_type_expr()?)))
        } else {
            (None, None)
        };
        let effects = if self.eat(Tag::With).is_some() {
            Some(self.parse_effect_set()?)
        } else {
            None
        };
        Ok(Spanned::new(
            TypeKind::Function(FunctionType {
                parameters,
                return_borrow,
                return_type,
                effects,
            }),
            Span::new(start, self.previous_end()),
        ))
    }

    fn parse_named_type(&mut self) -> Result<NamedType, FrontendDiagnostic> {
        let path = self.parse_path(false)?;
        let start = path.span.start;
        let path_end = path.span.end;
        let arguments = self.parse_type_arguments()?;
        let end = if arguments.is_empty() {
            path_end
        } else {
            self.previous_end()
        };
        Ok(Spanned::new(
            NamedTypeKind { path, arguments },
            Span::new(start, end),
        ))
    }

    fn parse_type_arguments(&mut self) -> Result<Vec<TypeArgument>, FrontendDiagnostic> {
        if self.eat(Tag::Less).is_none() {
            return Ok(Vec::new());
        }
        let saved = self.enter(false);
        let mut arguments = Vec::new();
        loop {
            if self.at(Tag::Ident) && self.nth_tag(1) == Tag::Equal {
                let start = self.current().span.start;
                let name = self.expect_identifier()?;
                self.expect(Tag::Equal)?;
                let value = self.parse_type_expr()?;
                arguments.push(TypeArgument::AssociatedType {
                    span: Span::new(start, value.span.end),
                    name,
                    value,
                });
            } else {
                arguments.push(TypeArgument::Type(self.parse_type_expr()?));
            }
            if self.eat(Tag::Comma).is_none() || self.at(Tag::Greater) {
                break;
            }
        }
        self.expect(Tag::Greater)?;
        self.newlines = saved;
        Ok(arguments)
    }

    fn parse_parenthesized_type(&mut self) -> Result<TypeExpr, FrontendDiagnostic> {
        let start = self.expect(Tag::LParen)?.span.start;
        let saved = self.enter(false);
        let first = self.parse_type_expr()?;
        if self.eat(Tag::Comma).is_none() {
            let end = self.expect(Tag::RParen)?.span.end;
            self.newlines = saved;
            return Ok(Spanned::new(
                TypeKind::Grouped(Box::new(first)),
                Span::new(start, end),
            ));
        }
        let second = self.parse_type_expr()?;
        let mut elements = vec![first, second];
        while self.eat(Tag::Comma).is_some() && !self.at(Tag::RParen) {
            elements.push(self.parse_type_expr()?);
        }
        let end = self.expect(Tag::RParen)?.span.end;
        self.newlines = saved;
        Ok(Spanned::new(
            TypeKind::Tuple(elements),
            Span::new(start, end),
        ))
    }

    fn parse_effect_set(&mut self) -> Result<EffectSet, FrontendDiagnostic> {
        let start = self.expect(Tag::LBrace)?.span.start;
        let saved = self.enter(false);
        let mut effects = Vec::new();
        if !self.at(Tag::RBrace) {
            loop {
                effects.push(self.parse_effect_expr()?);
                if self.eat(Tag::Comma).is_none() || self.at(Tag::RBrace) {
                    break;
                }
            }
        }
        let end = self.expect(Tag::RBrace)?.span.end;
        self.newlines = saved;
        Ok(EffectSet {
            span: Span::new(start, end),
            effects,
        })
    }

    fn parse_effect_expr(&mut self) -> Result<EffectExpr, FrontendDiagnostic> {
        let start = self.current().span.start;
        let kind = if self.eat(Tag::Unsafe).is_some() {
            EffectKind::Unsafe
        } else if self.at(Tag::Ident) || self.at(Tag::Super) {
            let path = self.parse_path(false)?;
            let (arguments, effect_arguments) = self.parse_effect_application_arguments()?;
            EffectKind::Named {
                path,
                arguments,
                effect_arguments,
            }
        } else {
            return Err(self.unexpected(vec![
                Tag::Ident.expected(),
                Tag::Super.expected(),
                Tag::Unsafe.expected(),
            ]));
        };
        Ok(Spanned::new(kind, Span::new(start, self.previous_end())))
    }

    fn parse_effect_application_arguments(
        &mut self,
    ) -> Result<(Vec<TypeExpr>, Vec<EffectRowArgument>), FrontendDiagnostic> {
        if self.eat(Tag::Less).is_none() {
            return Ok((Vec::new(), Vec::new()));
        }
        let saved = self.enter(false);
        let mut arguments = vec![self.parse_type_expr()?];
        let mut effect_arguments = Vec::new();
        let mut saw_effect = false;
        while self.eat(Tag::Comma).is_some() && !self.at(Tag::Greater) {
            if let Some(effect) = self.eat(Tag::Effect) {
                saw_effect = true;
                let effects = self.parse_effect_set()?;
                effect_arguments.push(EffectRowArgument {
                    span: Span::new(effect.span.start, effects.span.end),
                    effects,
                });
            } else if saw_effect {
                return Err(self.unexpected(vec![Tag::Effect.expected(), Tag::Greater.expected()]));
            } else {
                arguments.push(self.parse_type_expr()?);
            }
        }
        self.expect(Tag::Greater)?;
        self.newlines = saved;
        Ok((arguments, effect_arguments))
    }

    fn parse_path(&mut self, stop_before_use_items: bool) -> Result<Path, FrontendDiagnostic> {
        let start = self.current().span.start;
        let mut segments = vec![self.parse_path_segment()?];
        while self.at(Tag::ColonColon) {
            if stop_before_use_items && self.nth_tag(1) == Tag::LBrace {
                break;
            }
            self.bump();
            segments.push(self.parse_path_segment()?);
        }
        Ok(Path {
            span: Span::new(start, self.previous_end()),
            segments,
        })
    }

    fn parse_path_segment(&mut self) -> Result<PathSegment, FrontendDiagnostic> {
        if let Some(token) = self.eat(Tag::Super) {
            Ok(PathSegment::Super(token.span))
        } else if self.at(Tag::Ident) {
            Ok(PathSegment::Identifier(self.expect_identifier()?))
        } else {
            Err(self.unexpected(vec![Tag::Ident.expected(), Tag::Super.expected()]))
        }
    }

    fn parse_expr(&mut self) -> Result<Expr, FrontendDiagnostic> {
        self.parse_expr_with_named_construction(true)
    }

    fn parse_control_head(&mut self) -> Result<Expr, FrontendDiagnostic> {
        self.parse_expr_with_named_construction(false)
    }

    fn parse_expr_with_named_construction(
        &mut self,
        allow_named_construction: bool,
    ) -> Result<Expr, FrontendDiagnostic> {
        let mut expression = self.parse_binary(allow_named_construction, 1)?;
        while self.eat(Tag::Catch).is_some() {
            let (arms, body_span) = self.parse_match_body()?;
            let span = Span::new(expression.span.start, body_span.end);
            expression = Spanned::new(
                ExprKind::Catch {
                    expression: Box::new(expression),
                    arms,
                },
                span,
            );
        }
        Ok(expression)
    }

    fn parse_binary(
        &mut self,
        allow_named: bool,
        min_precedence: u8,
    ) -> Result<Expr, FrontendDiagnostic> {
        // Descend only for an actual operator, rather than retaining every
        // precedence level on the stack around each nested primary expression.
        let mut expression = self.parse_unary(allow_named)?;
        let mut max_precedence = u8::MAX;
        while let Some((kind, precedence)) = binary_operator(self.current_tag()) {
            if precedence < min_precedence || precedence > max_precedence || self.line_break_here()
            {
                break;
            }
            let operator = self.bump();
            let right = self.parse_binary(allow_named, precedence + 1)?;
            expression = make_binary(expression, operator.span, kind, right);
            // Leave a disallowed chain for the enclosing production's normal
            // diagnostic. Its operators cannot be consumed by a lower level.
            max_precedence = if matches!(
                kind,
                BinaryOperator::Equal
                    | BinaryOperator::NotEqual
                    | BinaryOperator::Less
                    | BinaryOperator::Greater
                    | BinaryOperator::LessEqual
                    | BinaryOperator::GreaterEqual
                    | BinaryOperator::RangeExclusive
                    | BinaryOperator::RangeInclusive
            ) {
                precedence - 1
            } else {
                precedence
            };
        }
        // `&` only borrows; after an operand on the same line it is a mistaken
        // binary operator, most likely meant as `&&`.
        if self.at(Tag::Amp) && !self.line_break_here() {
            return Err(self.unexpected(vec![Tag::AndAnd.expected()]));
        }
        Ok(expression)
    }

    fn parse_unary(&mut self, allow_named: bool) -> Result<Expr, FrontendDiagnostic> {
        self.nested(|parser| parser.parse_unary_level(allow_named))
    }

    fn parse_unary_level(&mut self, allow_named: bool) -> Result<Expr, FrontendDiagnostic> {
        if let Some(borrow) = self.parse_borrow() {
            let operand = self.parse_unary(allow_named)?;
            let span = Span::new(borrow.span.start, operand.span.end);
            return Ok(Spanned::new(
                ExprKind::Borrow {
                    kind: borrow,
                    operand: Box::new(operand),
                },
                span,
            ));
        }
        let (operator, kind) = if let Some(operator) = self.eat(Tag::Minus) {
            (operator, UnaryOperator::Negate)
        } else if let Some(operator) = self.eat(Tag::Bang) {
            (operator, UnaryOperator::Not)
        } else {
            return self.parse_postfix(allow_named);
        };
        let operand = self.parse_unary(allow_named)?;
        let span = Span::new(operator.span.start, operand.span.end);
        Ok(Spanned::new(
            ExprKind::Unary {
                operator: Spanned::new(kind, operator.span),
                operand: Box::new(operand),
            },
            span,
        ))
    }

    fn parse_postfix(&mut self, allow_named: bool) -> Result<Expr, FrontendDiagnostic> {
        // Keep the postfix loop's temporaries out of the recursive primary path.
        let expression = self.parse_primary(allow_named)?;
        self.parse_postfix_tail(expression)
    }

    fn parse_postfix_tail(&mut self, mut expression: Expr) -> Result<Expr, FrontendDiagnostic> {
        loop {
            if self.at(Tag::LParen) && !self.line_break_here() {
                let (arguments, end) = self.parse_call_arguments()?;
                let span = Span::new(expression.span.start, end);
                expression = Spanned::new(
                    ExprKind::Call {
                        callee: Box::new(expression),
                        arguments,
                    },
                    span,
                );
                continue;
            }
            if self.at(Tag::LBracket) && !self.line_break_here() {
                let (index, end) = self.parse_index()?;
                let span = Span::new(expression.span.start, end);
                expression = Spanned::new(
                    ExprKind::Index {
                        receiver: Box::new(expression),
                        index: Box::new(index),
                    },
                    span,
                );
                continue;
            }
            if self.eat(Tag::Dot).is_some() {
                if self.at(Tag::Integer) {
                    let index = self.expect_integer()?;
                    let span = Span::new(expression.span.start, index.span.end);
                    expression = Spanned::new(
                        ExprKind::TupleField {
                            receiver: Box::new(expression),
                            index,
                        },
                        span,
                    );
                } else {
                    let name = self.expect_identifier()?;
                    if self.at(Tag::LParen) && !self.line_break_here() {
                        let (arguments, end) = self.parse_call_arguments()?;
                        let span = Span::new(expression.span.start, end);
                        expression = Spanned::new(
                            ExprKind::MethodCall {
                                receiver: Box::new(expression),
                                method: name,
                                arguments,
                            },
                            span,
                        );
                    } else {
                        let span = Span::new(expression.span.start, name.span.end);
                        expression = Spanned::new(
                            ExprKind::Field {
                                receiver: Box::new(expression),
                                name,
                            },
                            span,
                        );
                    }
                }
                continue;
            }
            return Ok(expression);
        }
    }

    fn parse_index(&mut self) -> Result<(Expr, usize), FrontendDiagnostic> {
        self.expect(Tag::LBracket)?;
        let saved = self.enter(false);
        let index = self.parse_expr()?;
        let end = self.expect(Tag::RBracket)?.span.end;
        self.newlines = saved;
        Ok((index, end))
    }

    fn parse_call_arguments(&mut self) -> Result<(Vec<Expr>, usize), FrontendDiagnostic> {
        self.expect(Tag::LParen)?;
        let saved = self.enter(false);
        let mut arguments = Vec::new();
        if !self.at(Tag::RParen) {
            loop {
                arguments.push(self.parse_expr()?);
                if self.eat(Tag::Comma).is_none() || self.at(Tag::RParen) {
                    break;
                }
            }
        }
        let end = self.expect(Tag::RParen)?.span.end;
        self.newlines = saved;
        Ok((arguments, end))
    }

    fn parse_primary(&mut self, allow_named: bool) -> Result<Expr, FrontendDiagnostic> {
        let token = self.current().clone();
        match token.kind {
            TokenKind::Integer(value) => {
                self.bump();
                Ok(Spanned::new(ExprKind::Integer(value), token.span))
            }
            TokenKind::Float(value) => {
                self.bump();
                Ok(Spanned::new(ExprKind::Float(value), token.span))
            }
            TokenKind::String(value) => {
                self.bump();
                Ok(Spanned::new(ExprKind::String(value), token.span))
            }
            TokenKind::RawString(value, delimiter) => {
                self.bump();
                Ok(Spanned::new(
                    ExprKind::RawString { value, delimiter },
                    token.span,
                ))
            }
            TokenKind::InterpolationStart(_) => self.parse_interpolated_string(),
            TokenKind::True | TokenKind::False => {
                self.bump();
                Ok(Spanned::new(
                    ExprKind::Boolean(token.kind.tag() == Tag::True),
                    token.span,
                ))
            }
            TokenKind::Ident(_) | TokenKind::Super => {
                let path = self.parse_path(false)?;
                if allow_named && self.at(Tag::LBrace) && !self.line_break_here() {
                    self.parse_named_construct(path)
                } else {
                    let span = path.span;
                    Ok(Spanned::new(ExprKind::Path(path), span))
                }
            }
            TokenKind::LBracket => self.parse_list_literal(),
            TokenKind::LParen => self.parse_parenthesized_or_tuple(),
            TokenKind::LBrace => {
                let block = self.parse_block()?;
                let span = block.span;
                Ok(Spanned::new(ExprKind::Block(block), span))
            }
            TokenKind::If => self.parse_if_expression(),
            TokenKind::Match => self.parse_match_expression(),
            TokenKind::Handle => self.parse_handle_expression(),
            TokenKind::Fn => self.parse_closure_expression(),
            TokenKind::Unsafe => self.parse_unsafe_expression(),
            _ => Err(self.unexpected(expression_expectations())),
        }
    }

    fn parse_interpolated_string(&mut self) -> Result<Expr, FrontendDiagnostic> {
        let start_token = self.expect(Tag::InterpolationStart)?;
        let TokenKind::InterpolationStart(value) = start_token.kind else {
            unreachable!("tag and token kind disagree")
        };
        let start = start_token.span.start;
        let saved = self.enter(false);
        let mut parts = vec![InterpolationPart::String(StringValue {
            span: start_token.span,
            value,
        })];
        loop {
            parts.push(InterpolationPart::Expression(Box::new(self.parse_expr()?)));
            if self.at(Tag::InterpolationMiddle) {
                let token = self.bump();
                let TokenKind::InterpolationMiddle(value) = token.kind else {
                    unreachable!("tag and token kind disagree")
                };
                parts.push(InterpolationPart::String(StringValue {
                    span: token.span,
                    value,
                }));
                continue;
            }
            if !self.at(Tag::InterpolationEnd) {
                return Err(self.unexpected(vec![
                    Tag::InterpolationMiddle.expected(),
                    Tag::InterpolationEnd.expected(),
                ]));
            }
            let token = self.bump();
            let TokenKind::InterpolationEnd(value) = token.kind else {
                unreachable!("tag and token kind disagree")
            };
            let end = token.span.end;
            parts.push(InterpolationPart::String(StringValue {
                span: token.span,
                value,
            }));
            self.newlines = saved;
            return Ok(Spanned::new(
                ExprKind::InterpolatedString(parts),
                Span::new(start, end),
            ));
        }
    }

    fn parse_named_construct(&mut self, path: Path) -> Result<Expr, FrontendDiagnostic> {
        let start = path.span.start;
        self.expect(Tag::LBrace)?;
        let saved = self.enter(false);
        let mut entries = Vec::new();
        if self.eat(Tag::DotDot).is_some() {
            let entry_start = self.previous_span().start;
            let value = self.parse_expr()?;
            entries.push(ConstructEntry {
                span: Span::new(entry_start, value.span.end),
                kind: ConstructEntryKind::Spread(value),
            });
            if self.eat(Tag::Comma).is_some() && !self.at(Tag::RBrace) {
                loop {
                    entries.push(self.parse_construct_field()?);
                    if self.eat(Tag::Comma).is_none() || self.at(Tag::RBrace) {
                        break;
                    }
                }
            }
        } else if !self.at(Tag::RBrace) {
            loop {
                entries.push(self.parse_construct_field()?);
                if self.eat(Tag::Comma).is_none() || self.at(Tag::RBrace) {
                    break;
                }
            }
        }
        let end = self.expect(Tag::RBrace)?.span.end;
        self.newlines = saved;
        Ok(Spanned::new(
            ExprKind::NamedConstruct { path, entries },
            Span::new(start, end),
        ))
    }

    fn parse_construct_field(&mut self) -> Result<ConstructEntry, FrontendDiagnostic> {
        let start = self.current().span.start;
        let name = self.expect_identifier()?;
        let value = if self.eat(Tag::Colon).is_some() {
            Some(self.parse_expr()?)
        } else {
            None
        };
        let end = value.as_ref().map_or(name.span.end, |value| value.span.end);
        Ok(ConstructEntry {
            span: Span::new(start, end),
            kind: ConstructEntryKind::Field { name, value },
        })
    }

    fn parse_list_literal(&mut self) -> Result<Expr, FrontendDiagnostic> {
        let start = self.expect(Tag::LBracket)?.span.start;
        let saved = self.enter(false);
        let mut elements = Vec::new();
        if !self.at(Tag::RBracket) {
            loop {
                elements.push(self.parse_expr()?);
                if self.eat(Tag::Comma).is_none() || self.at(Tag::RBracket) {
                    break;
                }
            }
        }
        let end = self.expect(Tag::RBracket)?.span.end;
        self.newlines = saved;
        Ok(Spanned::new(
            ExprKind::List(elements),
            Span::new(start, end),
        ))
    }

    fn parse_parenthesized_or_tuple(&mut self) -> Result<Expr, FrontendDiagnostic> {
        let start = self.expect(Tag::LParen)?.span.start;
        let saved = self.enter(false);
        if let Some(close) = self.eat(Tag::RParen) {
            self.newlines = saved;
            return Ok(Spanned::new(
                ExprKind::Unit,
                Span::new(start, close.span.end),
            ));
        }
        let first = self.parse_expr()?;
        if self.eat(Tag::Comma).is_none() {
            let end = self.expect(Tag::RParen)?.span.end;
            self.newlines = saved;
            return Ok(Spanned::new(
                ExprKind::Parenthesized(Box::new(first)),
                Span::new(start, end),
            ));
        }
        let second = self.parse_expr()?;
        let mut elements = vec![first, second];
        while self.eat(Tag::Comma).is_some() && !self.at(Tag::RParen) {
            elements.push(self.parse_expr()?);
        }
        let end = self.expect(Tag::RParen)?.span.end;
        self.newlines = saved;
        Ok(Spanned::new(
            ExprKind::Tuple(elements),
            Span::new(start, end),
        ))
    }

    fn parse_if_expression(&mut self) -> Result<Expr, FrontendDiagnostic> {
        let start = self.expect(Tag::If)?.span.start;
        let condition = self.parse_control_head()?;
        let then_branch = self.parse_block()?;
        let else_branch = if self.eat(Tag::Else).is_some() {
            if self.at(Tag::If) {
                Some(Box::new(self.parse_if_expression()?))
            } else {
                let block = self.parse_block()?;
                let span = block.span;
                Some(Box::new(Spanned::new(ExprKind::Block(block), span)))
            }
        } else {
            None
        };
        let end = else_branch
            .as_ref()
            .map_or(then_branch.span.end, |branch| branch.span.end);
        Ok(Spanned::new(
            ExprKind::If {
                condition: Box::new(condition),
                then_branch,
                else_branch,
            },
            Span::new(start, end),
        ))
    }

    fn parse_match_expression(&mut self) -> Result<Expr, FrontendDiagnostic> {
        let start = self.expect(Tag::Match)?.span.start;
        let scrutinee = Box::new(self.parse_control_head()?);
        let (arms, body_span) = self.parse_match_body()?;
        Ok(Spanned::new(
            ExprKind::Match { scrutinee, arms },
            Span::new(start, body_span.end),
        ))
    }

    fn parse_match_body(&mut self) -> Result<(Vec<MatchArm>, Span), FrontendDiagnostic> {
        let start = self.expect(Tag::LBrace)?.span.start;
        let saved = self.enter(true);
        let mut arms = Vec::new();
        loop {
            self.at_item_start = true;
            if self.at(Tag::RBrace) {
                break;
            }
            let arm_start = self.current().span.start;
            let pattern = self.parse_or_pattern()?;
            let guard = if self.eat(Tag::If).is_some() {
                Some(self.parse_expr()?)
            } else {
                None
            };
            self.expect(Tag::FatArrow)?;
            let body = self.parse_expr()?;
            arms.push(MatchArm {
                span: Span::new(arm_start, body.span.end),
                pattern,
                guard,
                body,
            });
            self.end_item(Tag::RBrace, Tag::Comma)?;
        }
        let end = self.expect(Tag::RBrace)?.span.end;
        self.newlines = saved;
        Ok((arms, Span::new(start, end)))
    }

    fn parse_handle_expression(&mut self) -> Result<Expr, FrontendDiagnostic> {
        let start = self.expect(Tag::Handle)?.span.start;
        let body = self.parse_block()?;
        self.expect(Tag::With)?;
        self.expect(Tag::LBrace)?;
        let saved = self.enter(true);
        let mut handlers = Vec::new();
        loop {
            self.at_item_start = true;
            if self.at(Tag::RBrace) {
                break;
            }
            let handler_start = self.current().span.start;
            let effect = self.parse_path(false)?;
            self.expect(Tag::Dot)?;
            let operation = self.expect_identifier()?;
            let parameters = self.parse_parameters(ParameterContext::Handler)?;
            self.expect(Tag::FatArrow)?;
            let body = self.parse_expr()?;
            handlers.push(Handler {
                span: Span::new(handler_start, body.span.end),
                effect,
                operation,
                parameters,
                body,
            });
            self.end_item(Tag::RBrace, Tag::Comma)?;
        }
        let end = self.expect(Tag::RBrace)?.span.end;
        self.newlines = saved;
        Ok(Spanned::new(
            ExprKind::Handle { body, handlers },
            Span::new(start, end),
        ))
    }

    fn parse_closure_expression(&mut self) -> Result<Expr, FrontendDiagnostic> {
        let start = self.expect(Tag::Fn)?.span.start;
        let parameters = self.parse_parameters(ParameterContext::Closure)?;
        let (return_borrow, return_type) = if self.eat(Tag::Arrow).is_some() {
            (self.parse_borrow(), Some(Box::new(self.parse_type_expr()?)))
        } else {
            (None, None)
        };
        let effects = if self.eat(Tag::With).is_some() {
            Some(self.parse_effect_set()?)
        } else {
            None
        };
        let body = self.parse_block()?;
        let end = body.span.end;
        Ok(Spanned::new(
            ExprKind::Closure(ClosureExpression {
                parameters,
                return_borrow,
                return_type,
                effects,
                body,
            }),
            Span::new(start, end),
        ))
    }

    fn parse_unsafe_expression(&mut self) -> Result<Expr, FrontendDiagnostic> {
        let start = self.expect(Tag::Unsafe)?.span.start;
        let body = self.parse_block()?;
        let end = body.span.end;
        Ok(Spanned::new(ExprKind::Unsafe(body), Span::new(start, end)))
    }

    fn parse_block(&mut self) -> Result<Block, FrontendDiagnostic> {
        self.nested(Self::parse_block_level)
    }

    fn parse_block_level(&mut self) -> Result<Block, FrontendDiagnostic> {
        let start = self.expect(Tag::LBrace)?.span.start;
        let saved = self.enter(true);
        let mut statements = Vec::new();
        loop {
            self.at_item_start = true;
            if self.at(Tag::RBrace) {
                break;
            }
            if self.at(Tag::Eof) {
                return Err(self.unexpected(vec![Tag::RBrace.expected()]));
            }
            // Keep the keyword statements' temporaries out of the recursive
            // expression path.
            let statement = if self.at_keyword_statement() {
                self.parse_keyword_statement()?
            } else {
                self.parse_expression_statement()?
            };
            statements.push(statement);
            self.end_item(Tag::RBrace, Tag::Semicolon)?;
        }
        let end = self.expect(Tag::RBrace)?.span.end;
        self.newlines = saved;
        let tail = take_tail(&mut statements);
        Ok(Block {
            span: Span::new(start, end),
            statements,
            tail,
        })
    }

    fn at_keyword_statement(&self) -> bool {
        match self.current_tag() {
            Tag::Let
            | Tag::Return
            | Tag::Break
            | Tag::Continue
            | Tag::While
            | Tag::For
            | Tag::Loop => true,
            Tag::If => self.nth_tag(1) == Tag::Let,
            _ => false,
        }
    }

    fn parse_expression_statement(&mut self) -> Result<Statement, FrontendDiagnostic> {
        let start = self.current().span.start;
        let expression = self.parse_expr()?;
        let kind = match assignment_operator(self.current_tag()) {
            Some(operator) => self.parse_assignment(expression, operator)?,
            None => StatementKind::Expression(expression),
        };
        Ok(Spanned::new(kind, Span::new(start, self.previous_end())))
    }

    fn parse_assignment(
        &mut self,
        target: Expr,
        operator: AssignmentOperator,
    ) -> Result<StatementKind, FrontendDiagnostic> {
        let operator_token = self.bump();
        let target = expression_place(target)?;
        let value = self.parse_expr()?;
        Ok(StatementKind::Assignment {
            target,
            operator: Spanned::new(operator, operator_token.span),
            value,
        })
    }

    fn parse_keyword_statement(&mut self) -> Result<Statement, FrontendDiagnostic> {
        let start = self.current().span.start;
        let kind = match self.current_tag() {
            Tag::Let => self.parse_let_statement()?,
            Tag::Return => {
                self.bump();
                let value = if self.at_item_end() {
                    None
                } else {
                    Some(self.parse_expr()?)
                };
                StatementKind::Return(value)
            }
            Tag::Break => {
                self.bump();
                StatementKind::Break
            }
            Tag::Continue => {
                self.bump();
                StatementKind::Continue
            }
            Tag::If if self.nth_tag(1) == Tag::Let => self.parse_if_let_statement()?,
            Tag::While => {
                self.bump();
                let condition = self.parse_control_head()?;
                let body = self.parse_block()?;
                StatementKind::While { condition, body }
            }
            Tag::For => self.parse_for_statement()?,
            Tag::Loop => {
                self.bump();
                StatementKind::Loop(self.parse_block()?)
            }
            _ => unreachable!("only keyword statements reach this parser"),
        };
        Ok(Spanned::new(kind, Span::new(start, self.previous_end())))
    }

    fn parse_let_statement(&mut self) -> Result<StatementKind, FrontendDiagnostic> {
        self.expect(Tag::Let)?;
        let binding = if self.at(Tag::LParen) {
            LetBinding::Tuple(self.parse_pattern()?)
        } else {
            let mutable = self.eat(Tag::Mut).map(|keyword| keyword.span);
            let name = self.expect_identifier()?;
            let (annotation_borrow, annotation) = if self.eat(Tag::Colon).is_some() {
                (self.parse_borrow(), Some(self.parse_type_expr()?))
            } else {
                (None, None)
            };
            LetBinding::Name {
                name,
                mutable,
                annotation_borrow,
                annotation,
            }
        };
        self.expect(Tag::Equal)?;
        let value = self.parse_expr()?;
        Ok(StatementKind::Let { binding, value })
    }

    fn parse_if_let_statement(&mut self) -> Result<StatementKind, FrontendDiagnostic> {
        self.expect(Tag::If)?;
        self.expect(Tag::Let)?;
        let pattern = self.parse_pattern()?;
        self.expect(Tag::Equal)?;
        let value = self.parse_control_head()?;
        let then_branch = self.parse_block()?;
        let else_branch = if self.eat(Tag::Else).is_some() {
            Some(self.parse_block()?)
        } else {
            None
        };
        Ok(StatementKind::IfLet {
            pattern,
            value,
            then_branch,
            else_branch,
        })
    }

    fn parse_for_statement(&mut self) -> Result<StatementKind, FrontendDiagnostic> {
        self.expect(Tag::For)?;
        let binding = if self.eat(Tag::LParen).is_some() {
            let tuple_start = self.previous_span().start;
            let saved = self.enter(false);
            let first = self.expect_identifier()?;
            self.expect(Tag::Comma)?;
            let second = self.expect_identifier()?;
            let mut names = vec![first, second];
            while self.eat(Tag::Comma).is_some() && !self.at(Tag::RParen) {
                names.push(self.expect_identifier()?);
            }
            let tuple_end = self.expect(Tag::RParen)?.span.end;
            self.newlines = saved;
            ForBinding::Tuple {
                span: Span::new(tuple_start, tuple_end),
                names,
            }
        } else {
            ForBinding::Name(self.expect_identifier()?)
        };
        self.expect(Tag::In)?;
        let iterable = self.parse_control_head()?;
        let body = self.parse_block()?;
        Ok(StatementKind::For {
            binding,
            iterable,
            body,
        })
    }

    fn parse_or_pattern(&mut self) -> Result<OrPattern, FrontendDiagnostic> {
        let first = self.parse_pattern()?;
        let start = first.span.start;
        let mut alternatives = vec![first];
        while self.eat(Tag::Pipe).is_some() {
            alternatives.push(self.parse_pattern()?);
        }
        let end = alternatives.last().expect("pattern is nonempty").span.end;
        Ok(OrPattern {
            span: Span::new(start, end),
            alternatives,
        })
    }

    fn parse_pattern(&mut self) -> Result<Pattern, FrontendDiagnostic> {
        self.nested(Self::parse_pattern_level)
    }

    fn parse_pattern_level(&mut self) -> Result<Pattern, FrontendDiagnostic> {
        let token = self.current().clone();
        match token.kind {
            TokenKind::Ident(ref text)
                if text == "_"
                    && !matches!(self.nth_tag(1), Tag::ColonColon | Tag::LParen | Tag::LBrace) =>
            {
                self.bump();
                Ok(Spanned::new(PatternKind::Wildcard, token.span))
            }
            TokenKind::Integer(value) => {
                self.bump();
                Ok(Spanned::new(PatternKind::Integer(value), token.span))
            }
            TokenKind::Float(value) => {
                self.bump();
                Ok(Spanned::new(PatternKind::Float(value), token.span))
            }
            TokenKind::String(value) => {
                self.bump();
                Ok(Spanned::new(PatternKind::String(value), token.span))
            }
            TokenKind::True | TokenKind::False => {
                self.bump();
                Ok(Spanned::new(
                    PatternKind::Boolean(token.kind.tag() == Tag::True),
                    token.span,
                ))
            }
            TokenKind::Ident(_) | TokenKind::Super => self.parse_path_pattern(),
            TokenKind::LParen => self.parse_tuple_pattern(),
            _ => Err(self.unexpected(pattern_expectations())),
        }
    }

    fn parse_path_pattern(&mut self) -> Result<Pattern, FrontendDiagnostic> {
        let path = self.parse_path(false)?;
        let start = path.span.start;
        let fields = if self.eat(Tag::LParen).is_some() {
            let saved = self.enter(false);
            let mut patterns = vec![self.parse_pattern()?];
            while self.eat(Tag::Comma).is_some() && !self.at(Tag::RParen) {
                patterns.push(self.parse_pattern()?);
            }
            self.expect(Tag::RParen)?;
            self.newlines = saved;
            Some(PatternFields::Positional(patterns))
        } else if self.at(Tag::LBrace) && !self.line_break_here() {
            self.bump();
            let saved = self.enter(false);
            let mut named_fields = Vec::new();
            let mut rest = None;
            if self.eat(Tag::DotDot).is_some() {
                rest = Some(self.previous_span());
                self.eat(Tag::Comma);
            } else if !self.at(Tag::RBrace) {
                loop {
                    let field_start = self.current().span.start;
                    let name = self.expect_identifier()?;
                    let pattern = if self.eat(Tag::Colon).is_some() {
                        Some(self.parse_pattern()?)
                    } else {
                        None
                    };
                    let field_end = pattern.as_ref().map_or(name.span.end, |item| item.span.end);
                    named_fields.push(NamedPatternField {
                        span: Span::new(field_start, field_end),
                        name,
                        pattern,
                    });
                    if self.eat(Tag::Comma).is_none() {
                        break;
                    }
                    if self.eat(Tag::DotDot).is_some() {
                        rest = Some(self.previous_span());
                        self.eat(Tag::Comma);
                        break;
                    }
                    if self.at(Tag::RBrace) {
                        break;
                    }
                }
            }
            self.expect(Tag::RBrace)?;
            self.newlines = saved;
            Some(PatternFields::Named {
                fields: named_fields,
                rest,
            })
        } else {
            None
        };
        Ok(Spanned::new(
            PatternKind::Path { path, fields },
            Span::new(start, self.previous_end()),
        ))
    }

    fn parse_tuple_pattern(&mut self) -> Result<Pattern, FrontendDiagnostic> {
        let start = self.expect(Tag::LParen)?.span.start;
        let saved = self.enter(false);
        let first = self.parse_pattern()?;
        self.expect(Tag::Comma)?;
        let second = self.parse_pattern()?;
        let mut patterns = vec![first, second];
        while self.eat(Tag::Comma).is_some() && !self.at(Tag::RParen) {
            patterns.push(self.parse_pattern()?);
        }
        let end = self.expect(Tag::RParen)?.span.end;
        self.newlines = saved;
        Ok(Spanned::new(
            PatternKind::Tuple(patterns),
            Span::new(start, end),
        ))
    }

    fn expect_identifier(&mut self) -> Result<Identifier, FrontendDiagnostic> {
        let token = self.expect(Tag::Ident)?;
        let TokenKind::Ident(text) = token.kind else {
            unreachable!("tag and token kind disagree")
        };
        Ok(Identifier {
            text,
            span: token.span,
        })
    }

    fn expect_integer(&mut self) -> Result<StringValue, FrontendDiagnostic> {
        let token = self.expect(Tag::Integer)?;
        let TokenKind::Integer(value) = token.kind else {
            unreachable!("tag and token kind disagree")
        };
        Ok(StringValue {
            span: token.span,
            value,
        })
    }

    /// Enters a construct where line breaks are or are not significant and
    /// returns the previous setting, which the construct restores at its end.
    fn enter(&mut self, newlines: bool) -> bool {
        std::mem::replace(&mut self.newlines, newlines)
    }

    /// Whether a significant line break separates the current token from the
    /// previous one, so the current token cannot continue an expression.
    fn line_break_here(&self) -> bool {
        self.newlines && self.current().newline_before
    }

    /// Whether the current item ends before the current token, which is how
    /// `return` without a value is recognized.
    fn at_item_end(&self) -> bool {
        matches!(
            self.current_tag(),
            Tag::RBrace | Tag::Semicolon | Tag::Comma | Tag::Eof
        ) || self.line_break_here()
    }

    fn at_contextual(&self, spelling: &str) -> bool {
        matches!(&self.current().kind, TokenKind::Ident(text) if text == spelling)
    }

    fn at(&self, tag: Tag) -> bool {
        self.current_tag() == tag
    }

    fn current_tag(&self) -> Tag {
        self.current().kind.tag()
    }

    fn nth_tag(&self, distance: usize) -> Tag {
        self.tokens
            .get(self.index + distance)
            .map_or(Tag::Eof, |token| token.kind.tag())
    }

    fn current(&self) -> &Token {
        &self.tokens[self.index]
    }

    fn bump(&mut self) -> Token {
        let token = self.current().clone();
        if self.newlines
            && token.newline_before
            && !self.at_item_start
            && self.layout_error.is_none()
            && !continues_line(self.previous_tag(), token.kind.tag())
        {
            self.layout_error = Some(FrontendDiagnostic::layout(
                token.span,
                LayoutDiagnosticKind::UnexpectedLineBreak,
            ));
        }
        self.at_item_start = false;
        if token.kind.tag() != Tag::Eof {
            self.index += 1;
        }
        token
    }

    fn eat(&mut self, tag: Tag) -> Option<Token> {
        self.at(tag).then(|| self.bump())
    }

    fn expect(&mut self, tag: Tag) -> Result<Token, FrontendDiagnostic> {
        if self.at(tag) {
            Ok(self.bump())
        } else {
            Err(self.unexpected(vec![tag.expected()]))
        }
    }

    fn unexpected(&self, expected: Vec<ExpectedToken>) -> FrontendDiagnostic {
        FrontendDiagnostic::unexpected(self.current().span, self.current_tag().found(), expected)
    }

    fn previous_tag(&self) -> Tag {
        self.index
            .checked_sub(1)
            .map_or(Tag::Eof, |index| self.tokens[index].kind.tag())
    }

    fn previous_span(&self) -> Span {
        self.tokens[self.index - 1].span
    }

    fn previous_end(&self) -> usize {
        self.previous_span().end
    }
}

/// Whether a line break between `previous` and `next` continues the current
/// item: the previous line ends with an operator or opening delimiter, or the
/// next line starts with a token that can only continue an item.
fn continues_line(previous: Tag, next: Tag) -> bool {
    matches!(
        next,
        Tag::Dot | Tag::Else | Tag::Catch | Tag::With | Tag::RParen | Tag::RBracket | Tag::RBrace
    ) || matches!(
        previous,
        Tag::Plus
            | Tag::Minus
            | Tag::Star
            | Tag::Slash
            | Tag::Percent
            | Tag::EqualEqual
            | Tag::BangEqual
            | Tag::Less
            | Tag::Greater
            | Tag::LessEqual
            | Tag::GreaterEqual
            | Tag::AndAnd
            | Tag::OrOr
            | Tag::Bang
            | Tag::Pipe
            | Tag::Amp
            | Tag::Equal
            | Tag::PlusEqual
            | Tag::MinusEqual
            | Tag::StarEqual
            | Tag::SlashEqual
            | Tag::PercentEqual
            | Tag::DotDot
            | Tag::DotDotEqual
            | Tag::Dot
            | Tag::ColonColon
            | Tag::Arrow
            | Tag::FatArrow
            | Tag::Comma
            | Tag::Colon
            | Tag::LParen
            | Tag::LBracket
            | Tag::LBrace
    )
}

/// Moves a final expression statement into the block tail.
fn take_tail(statements: &mut Vec<Statement>) -> Option<Box<Expr>> {
    if !matches!(
        statements.last(),
        Some(Spanned {
            kind: StatementKind::Expression(_),
            ..
        })
    ) {
        return None;
    }
    let Some(Spanned {
        kind: StatementKind::Expression(expression),
        ..
    }) = statements.pop()
    else {
        unreachable!("the last statement was checked")
    };
    Some(Box::new(expression))
}

/// Converts a parsed assignment target into a place, or reports that it is not
/// a local name followed by field, tuple-field and index projections.
fn expression_place(expression: Expr) -> Result<PlaceExpr, FrontendDiagnostic> {
    let span = expression.span;
    let mut projections = Vec::new();
    let mut current = expression;
    loop {
        match current.kind {
            ExprKind::Path(path) if path.segments.len() == 1 => {
                let Some(PathSegment::Identifier(root)) = path.segments.into_iter().next() else {
                    break;
                };
                projections.reverse();
                return Ok(PlaceExpr {
                    span,
                    root,
                    projections,
                });
            }
            ExprKind::Field { receiver, name } => {
                projections.push(PlaceProjection::Field(name));
                current = *receiver;
            }
            ExprKind::TupleField { receiver, index } => {
                projections.push(PlaceProjection::TupleField(index));
                current = *receiver;
            }
            ExprKind::Index { receiver, index } => {
                projections.push(PlaceProjection::Index(index));
                current = *receiver;
            }
            _ => break,
        }
    }
    Err(FrontendDiagnostic::expected_place(span))
}

fn assignment_operator(tag: Tag) -> Option<AssignmentOperator> {
    Some(match tag {
        Tag::Equal => AssignmentOperator::Assign,
        Tag::PlusEqual => AssignmentOperator::AddAssign,
        Tag::MinusEqual => AssignmentOperator::SubtractAssign,
        Tag::StarEqual => AssignmentOperator::MultiplyAssign,
        Tag::SlashEqual => AssignmentOperator::DivideAssign,
        Tag::PercentEqual => AssignmentOperator::RemainderAssign,
        _ => return None,
    })
}

fn declaration_expectations(
    allow_visibility: bool,
    enclosing_end: Option<Tag>,
) -> Vec<ExpectedToken> {
    let mut expected = vec![
        Tag::Fn.expected(),
        Tag::Struct.expected(),
        Tag::Enum.expected(),
        Tag::Impl.expected(),
        Tag::Trait.expected(),
        Tag::Effect.expected(),
        Tag::Extern.expected(),
        Tag::Const.expected(),
        Tag::Mod.expected(),
        ExpectedToken::Fixed("type".to_owned()),
    ];
    if allow_visibility {
        expected.push(Tag::Pub.expected());
    } else {
        expected.retain(|item| item != &Tag::Impl.expected());
    }
    if let Some(end) = enclosing_end {
        expected.push(end.expected());
    }
    expected
}

fn type_expectations() -> Vec<ExpectedToken> {
    vec![
        Tag::Ident.expected(),
        Tag::Super.expected(),
        Tag::LParen.expected(),
        Tag::Fn.expected(),
    ]
}

fn expression_expectations() -> Vec<ExpectedToken> {
    vec![
        Tag::Minus.expected(),
        Tag::Bang.expected(),
        Tag::Amp.expected(),
        Tag::Integer.expected(),
        Tag::Float.expected(),
        Tag::String.expected(),
        Tag::RawString.expected(),
        Tag::InterpolationStart.expected(),
        Tag::True.expected(),
        Tag::False.expected(),
        Tag::Ident.expected(),
        Tag::Super.expected(),
        Tag::LBracket.expected(),
        Tag::LParen.expected(),
        Tag::LBrace.expected(),
        Tag::If.expected(),
        Tag::Match.expected(),
        Tag::Handle.expected(),
        Tag::Fn.expected(),
        Tag::Unsafe.expected(),
    ]
}

fn pattern_expectations() -> Vec<ExpectedToken> {
    vec![
        Tag::Integer.expected(),
        Tag::Float.expected(),
        Tag::String.expected(),
        Tag::True.expected(),
        Tag::False.expected(),
        Tag::Ident.expected(),
        Tag::Super.expected(),
        Tag::LParen.expected(),
    ]
}

fn binary_operator(tag: Tag) -> Option<(BinaryOperator, u8)> {
    Some(match tag {
        Tag::OrOr => (BinaryOperator::LogicOr, 1),
        Tag::AndAnd => (BinaryOperator::LogicAnd, 2),
        Tag::EqualEqual => (BinaryOperator::Equal, 3),
        Tag::BangEqual => (BinaryOperator::NotEqual, 3),
        Tag::Less => (BinaryOperator::Less, 4),
        Tag::Greater => (BinaryOperator::Greater, 4),
        Tag::LessEqual => (BinaryOperator::LessEqual, 4),
        Tag::GreaterEqual => (BinaryOperator::GreaterEqual, 4),
        Tag::DotDot => (BinaryOperator::RangeExclusive, 5),
        Tag::DotDotEqual => (BinaryOperator::RangeInclusive, 5),
        Tag::Plus => (BinaryOperator::Add, 6),
        Tag::Minus => (BinaryOperator::Subtract, 6),
        Tag::Star => (BinaryOperator::Multiply, 7),
        Tag::Slash => (BinaryOperator::Divide, 7),
        Tag::Percent => (BinaryOperator::Remainder, 7),
        _ => return None,
    })
}

fn make_binary(left: Expr, operator_span: Span, operator: BinaryOperator, right: Expr) -> Expr {
    let span = Span::new(left.span.start, right.span.end);
    Spanned::new(
        ExprKind::Binary {
            left: Box::new(left),
            operator: Spanned::new(operator, operator_span),
            right: Box::new(right),
        },
        span,
    )
}
