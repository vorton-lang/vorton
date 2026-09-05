use crate::ast::*;
use crate::diagnostic::{ExpectedToken, FrontendDiagnostic};
use crate::lexer::{Tag, Token, TokenKind};

pub(crate) fn parse(
    tokens: Vec<Token>,
    source_length: usize,
) -> Result<Program, FrontendDiagnostic> {
    Parser { tokens, index: 0 }.parse_program(source_length)
}

struct Parser {
    tokens: Vec<Token>,
    index: usize,
}

impl Parser {
    fn parse_program(&mut self, source_length: usize) -> Result<Program, FrontendDiagnostic> {
        let requires = if self.at(Tag::Requires) {
            Some(self.parse_file_requires()?)
        } else {
            None
        };
        let mut uses = Vec::new();
        while self.at_use_declaration() {
            uses.push(self.parse_use_declaration()?);
        }
        let mut declarations = Vec::new();
        while !self.at(Tag::Eof) {
            declarations.push(self.parse_declaration(Tag::Eof)?);
        }
        self.expect(Tag::Eof)?;
        Ok(Program {
            span: Span::new(0, source_length),
            requires,
            uses,
            declarations,
        })
    }

    fn parse_file_requires(&mut self) -> Result<FileRequires, FrontendDiagnostic> {
        let start = self.expect(Tag::Requires)?.span.start;
        let effects = self.parse_effect_set()?;
        let end = self.expect(Tag::Semicolon)?.span.end;
        Ok(FileRequires {
            span: Span::new(start, end),
            effects,
        })
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
            Some(UseSuffix::Items {
                span: Span::new(suffix_start, end),
                items,
            })
        } else {
            None
        };
        let end = self.expect(Tag::Semicolon)?.span.end;
        Ok(UseDeclaration {
            span: Span::new(start, end),
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
        let signature = self.parse_function_signature()?;
        let body = self.parse_block()?;
        Ok(FunctionDeclaration {
            name: signature.name,
            type_parameters: signature.type_parameters,
            parameters: signature.parameters,
            return_type: signature.return_type,
            effects: signature.effects,
            body,
        })
    }

    fn parse_function_signature(&mut self) -> Result<FunctionSignature, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let type_parameters = self.parse_type_parameters()?;
        let parameters = self.parse_named_parameters()?;
        let return_type = if self.eat(Tag::Arrow).is_some() {
            Some(self.parse_type_expr()?)
        } else {
            None
        };
        let effects = if self.eat(Tag::With).is_some() {
            Some(self.parse_effect_set()?)
        } else {
            None
        };
        Ok(FunctionSignature {
            name,
            type_parameters,
            parameters,
            return_type,
            effects,
        })
    }

    fn parse_named_parameters(&mut self) -> Result<Vec<NamedParameter>, FrontendDiagnostic> {
        self.expect(Tag::LParen)?;
        let mut parameters = Vec::new();
        if !self.at(Tag::RParen) {
            loop {
                let start = self.current().span.start;
                let name = self.expect_identifier()?;
                let annotation = if self.eat(Tag::Colon).is_some() {
                    let annotation_start = self.previous_span().start;
                    let mode = self.parse_parameter_mode();
                    let ty = self.parse_type_expr()?;
                    Some(ParameterType {
                        span: Span::new(annotation_start, ty.span.end),
                        mode,
                        ty,
                    })
                } else {
                    None
                };
                let end = annotation
                    .as_ref()
                    .map_or(name.span.end, |item| item.span.end);
                parameters.push(NamedParameter {
                    span: Span::new(start, end),
                    name,
                    annotation,
                });
                if self.eat(Tag::Comma).is_none() || self.at(Tag::RParen) {
                    break;
                }
            }
        }
        self.expect(Tag::RParen)?;
        Ok(parameters)
    }

    fn parse_parameter_mode(&mut self) -> Option<Spanned<ParameterMode>> {
        let (kind, token) = if self.at(Tag::Mut) {
            (ParameterMode::Mut, self.bump())
        } else if self.at(Tag::Move) {
            (ParameterMode::Move, self.bump())
        } else {
            return None;
        };
        Some(Spanned::new(kind, token.span))
    }

    fn parse_struct_declaration(&mut self) -> Result<StructDeclaration, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let type_parameters = self.parse_type_parameters()?;
        self.expect(Tag::LBrace)?;
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
            self.expect(Tag::LBrace)?;
            let mut members = Vec::new();
            while !self.at(Tag::RBrace) {
                members.push(self.parse_impl_member(false)?);
            }
            self.expect(Tag::RBrace)?;
            Ok(DeclarationKind::TraitImpl(TraitImplDeclaration {
                type_parameters,
                trait_type: first_type,
                target,
                members,
            }))
        } else {
            self.expect(Tag::LBrace)?;
            let mut members = Vec::new();
            while !self.at(Tag::RBrace) {
                members.push(self.parse_impl_member(true)?);
            }
            self.expect(Tag::RBrace)?;
            Ok(DeclarationKind::InherentImpl(InherentImplDeclaration {
                type_parameters,
                target: first_type,
                members,
            }))
        }
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
            ImplMemberKind::AssociatedType(self.parse_associated_type_value()?)
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

    fn parse_associated_type_value(&mut self) -> Result<AssociatedTypeValue, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        self.expect(Tag::Equal)?;
        let value = self.parse_type_expr()?;
        self.expect(Tag::Semicolon)?;
        Ok(AssociatedTypeValue { name, value })
    }

    fn parse_trait_declaration(&mut self) -> Result<TraitDeclaration, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let type_parameters = self.parse_type_parameters()?;
        let mut supertraits = Vec::new();
        if self.eat(Tag::Colon).is_some() {
            supertraits.push(self.parse_named_type()?);
            while self.eat(Tag::Plus).is_some() {
                supertraits.push(self.parse_named_type()?);
            }
        }
        self.expect(Tag::LBrace)?;
        let mut members = Vec::new();
        while !self.at(Tag::RBrace) {
            let start = self.current().span.start;
            let kind = if self.eat(Tag::Fn).is_some() {
                let signature = self.parse_function_signature()?;
                self.expect(Tag::Semicolon)?;
                TraitMemberKind::Method(signature)
            } else if self.at_contextual("type") {
                self.bump();
                let associated = self.parse_trait_associated_type()?;
                TraitMemberKind::AssociatedType(associated)
            } else {
                return Err(self.unexpected(vec![
                    Tag::Fn.expected(),
                    ExpectedToken::Fixed("type".to_owned()),
                ]));
            };
            members.push(Spanned::new(kind, Span::new(start, self.previous_end())));
        }
        self.expect(Tag::RBrace)?;
        Ok(TraitDeclaration {
            name,
            type_parameters,
            supertraits,
            members,
        })
    }

    fn parse_trait_associated_type(&mut self) -> Result<TraitAssociatedType, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let mut bounds = Vec::new();
        if self.eat(Tag::Colon).is_some() {
            bounds.push(self.parse_named_type()?);
            while self.eat(Tag::Plus).is_some() {
                bounds.push(self.parse_named_type()?);
            }
        }
        let default = if self.eat(Tag::Equal).is_some() {
            Some(self.parse_type_expr()?)
        } else {
            None
        };
        self.expect(Tag::Semicolon)?;
        Ok(TraitAssociatedType {
            name,
            bounds,
            default,
        })
    }

    fn parse_effect_declaration(&mut self) -> Result<EffectDeclaration, FrontendDiagnostic> {
        let name = self.expect_identifier()?;
        let type_parameters = self.parse_type_parameters()?;
        self.expect(Tag::LBrace)?;
        let mut operations = Vec::new();
        while !self.at(Tag::RBrace) {
            let start = self.expect(Tag::Fn)?.span.start;
            let operation_name = self.expect_identifier()?;
            let parameters = self.parse_named_parameters()?;
            self.expect(Tag::Arrow)?;
            let return_type = self.parse_type_expr()?;
            let end = self.expect(Tag::Semicolon)?.span.end;
            operations.push(EffectOperation {
                span: Span::new(start, end),
                name: operation_name,
                parameters,
                return_type,
            });
        }
        self.expect(Tag::RBrace)?;
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
        self.expect(Tag::Semicolon)?;
        Ok(EffectAliasDeclaration {
            name,
            type_parameters,
            effects,
        })
    }

    fn parse_extern_declaration(&mut self) -> Result<ExternDeclaration, FrontendDiagnostic> {
        if self.eat(Tag::Fn).is_some() {
            let signature = self.parse_function_signature()?;
            self.expect(Tag::Semicolon)?;
            Ok(ExternDeclaration::Function(signature))
        } else if self.at_contextual("type") {
            self.bump();
            let name = self.expect_identifier()?;
            let type_parameters = self.parse_type_parameters()?;
            self.expect(Tag::Semicolon)?;
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
        self.expect(Tag::Semicolon)?;
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
        self.expect(Tag::Semicolon)?;
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
        let mut uses = Vec::new();
        while self.at_use_declaration() {
            uses.push(self.parse_use_declaration()?);
        }
        let mut declarations = Vec::new();
        while !self.at(Tag::RBrace) {
            declarations.push(self.parse_declaration(Tag::RBrace)?);
        }
        self.expect(Tag::RBrace)?;
        Ok(ModuleDeclaration {
            name,
            requires,
            uses,
            declarations,
        })
    }

    fn parse_type_parameters(&mut self) -> Result<Vec<TypeParameter>, FrontendDiagnostic> {
        if self.eat(Tag::Less).is_none() {
            return Ok(Vec::new());
        }
        let mut parameters = Vec::new();
        loop {
            let start = self.current().span.start;
            let name = self.expect_identifier()?;
            let mut bounds = Vec::new();
            if self.eat(Tag::Colon).is_some() {
                bounds.push(self.parse_named_type()?);
                while self.eat(Tag::Plus).is_some() {
                    bounds.push(self.parse_named_type()?);
                }
            }
            let end = bounds.last().map_or(name.span.end, |bound| bound.span.end);
            parameters.push(TypeParameter {
                span: Span::new(start, end),
                name,
                bounds,
            });
            if self.eat(Tag::Comma).is_none() || self.at(Tag::Greater) {
                break;
            }
        }
        self.expect(Tag::Greater)?;
        Ok(parameters)
    }

    fn parse_type_expr(&mut self) -> Result<TypeExpr, FrontendDiagnostic> {
        match self.current_tag() {
            Tag::Fn => self.parse_function_type(),
            Tag::LParen => self.parse_tuple_type(),
            Tag::LBrace => self.parse_record_type(),
            Tag::Ident | Tag::Super => {
                let named = self.parse_named_type()?;
                Ok(Spanned::new(TypeKind::Named(named.kind), named.span))
            }
            _ => Err(self.unexpected(type_expectations())),
        }
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
        Ok(arguments)
    }

    fn parse_function_type(&mut self) -> Result<TypeExpr, FrontendDiagnostic> {
        let start = self.expect(Tag::Fn)?.span.start;
        self.expect(Tag::LParen)?;
        let mut parameters = Vec::new();
        if !self.at(Tag::RParen) {
            loop {
                let parameter_start = self.current().span.start;
                let mode = self.parse_parameter_mode();
                let ty = self.parse_type_expr()?;
                parameters.push(FunctionTypeParameter {
                    span: Span::new(parameter_start, ty.span.end),
                    mode,
                    ty,
                });
                if self.eat(Tag::Comma).is_none() || self.at(Tag::RParen) {
                    break;
                }
            }
        }
        self.expect(Tag::RParen)?;
        self.expect(Tag::Arrow)?;
        let return_type = Box::new(self.parse_type_expr()?);
        let effects = if self.eat(Tag::With).is_some() {
            Some(self.parse_effect_set()?)
        } else {
            None
        };
        let end = effects
            .as_ref()
            .map_or(return_type.span.end, |effects| effects.span.end);
        Ok(Spanned::new(
            TypeKind::Function(FunctionType {
                parameters,
                return_type,
                effects,
            }),
            Span::new(start, end),
        ))
    }

    fn parse_tuple_type(&mut self) -> Result<TypeExpr, FrontendDiagnostic> {
        let start = self.expect(Tag::LParen)?.span.start;
        let first = self.parse_type_expr()?;
        self.expect(Tag::Comma)?;
        let second = self.parse_type_expr()?;
        let mut elements = vec![first, second];
        while self.eat(Tag::Comma).is_some() && !self.at(Tag::RParen) {
            elements.push(self.parse_type_expr()?);
        }
        let end = self.expect(Tag::RParen)?.span.end;
        Ok(Spanned::new(
            TypeKind::Tuple(elements),
            Span::new(start, end),
        ))
    }

    fn parse_record_type(&mut self) -> Result<TypeExpr, FrontendDiagnostic> {
        let start = self.expect(Tag::LBrace)?.span.start;
        let mut fields = vec![self.parse_named_field()?];
        let mut rest = None;
        while self.eat(Tag::Comma).is_some() {
            if self.at(Tag::RBrace) {
                break;
            }
            if self.eat(Tag::DotDot).is_some() {
                rest = Some(self.expect_identifier()?);
                self.eat(Tag::Comma);
                break;
            }
            fields.push(self.parse_named_field()?);
        }
        let end = self.expect(Tag::RBrace)?.span.end;
        Ok(Spanned::new(
            TypeKind::Record(RecordType { fields, rest }),
            Span::new(start, end),
        ))
    }

    fn parse_effect_set(&mut self) -> Result<EffectSet, FrontendDiagnostic> {
        let start = self.expect(Tag::LBrace)?.span.start;
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
        Ok(EffectSet {
            span: Span::new(start, end),
            effects,
        })
    }

    fn parse_effect_expr(&mut self) -> Result<EffectExpr, FrontendDiagnostic> {
        let start = self.current().span.start;
        let kind = if self.eat(Tag::Mut).is_some() {
            EffectKind::Mutation {
                arguments: self.parse_effect_arguments()?,
            }
        } else if self.eat(Tag::Unsafe).is_some() {
            EffectKind::Unsafe
        } else if self.at(Tag::Ident) || self.at(Tag::Super) {
            let path = self.parse_path(false)?;
            EffectKind::Named {
                path,
                arguments: self.parse_effect_arguments()?,
            }
        } else {
            return Err(self.unexpected(vec![
                Tag::Ident.expected(),
                Tag::Super.expected(),
                Tag::Mut.expected(),
                Tag::Unsafe.expected(),
            ]));
        };
        Ok(Spanned::new(kind, Span::new(start, self.previous_end())))
    }

    fn parse_effect_arguments(&mut self) -> Result<Vec<TypeExpr>, FrontendDiagnostic> {
        if self.eat(Tag::Less).is_none() {
            return Ok(Vec::new());
        }
        let mut arguments = vec![self.parse_type_expr()?];
        while self.eat(Tag::Comma).is_some() && !self.at(Tag::Greater) {
            arguments.push(self.parse_type_expr()?);
        }
        self.expect(Tag::Greater)?;
        Ok(arguments)
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
        let mut expression = self.parse_logic_or(allow_named_construction)?;
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

    fn parse_logic_or(&mut self, allow_named: bool) -> Result<Expr, FrontendDiagnostic> {
        let mut expression = self.parse_logic_and(allow_named)?;
        while let Some(operator) = self.eat(Tag::OrOr) {
            let right = self.parse_logic_and(allow_named)?;
            expression = make_binary(expression, operator.span, BinaryOperator::LogicOr, right);
        }
        Ok(expression)
    }

    fn parse_logic_and(&mut self, allow_named: bool) -> Result<Expr, FrontendDiagnostic> {
        let mut expression = self.parse_equality(allow_named)?;
        while let Some(operator) = self.eat(Tag::AndAnd) {
            let right = self.parse_equality(allow_named)?;
            expression = make_binary(expression, operator.span, BinaryOperator::LogicAnd, right);
        }
        Ok(expression)
    }

    fn parse_equality(&mut self, allow_named: bool) -> Result<Expr, FrontendDiagnostic> {
        let expression = self.parse_comparison(allow_named)?;
        let (operator, kind) = if let Some(operator) = self.eat(Tag::EqualEqual) {
            (operator, BinaryOperator::Equal)
        } else if let Some(operator) = self.eat(Tag::BangEqual) {
            (operator, BinaryOperator::NotEqual)
        } else {
            return Ok(expression);
        };
        let right = self.parse_comparison(allow_named)?;
        Ok(make_binary(expression, operator.span, kind, right))
    }

    fn parse_comparison(&mut self, allow_named: bool) -> Result<Expr, FrontendDiagnostic> {
        let expression = self.parse_range(allow_named)?;
        let (operator, kind) = if let Some(operator) = self.eat(Tag::Less) {
            (operator, BinaryOperator::Less)
        } else if let Some(operator) = self.eat(Tag::Greater) {
            (operator, BinaryOperator::Greater)
        } else if let Some(operator) = self.eat(Tag::LessEqual) {
            (operator, BinaryOperator::LessEqual)
        } else if let Some(operator) = self.eat(Tag::GreaterEqual) {
            (operator, BinaryOperator::GreaterEqual)
        } else {
            return Ok(expression);
        };
        let right = self.parse_range(allow_named)?;
        Ok(make_binary(expression, operator.span, kind, right))
    }

    fn parse_range(&mut self, allow_named: bool) -> Result<Expr, FrontendDiagnostic> {
        let mut expression = self.parse_additive(allow_named)?;
        loop {
            let (operator, kind) = if let Some(operator) = self.eat(Tag::DotDot) {
                (operator, BinaryOperator::RangeExclusive)
            } else if let Some(operator) = self.eat(Tag::DotDotEqual) {
                (operator, BinaryOperator::RangeInclusive)
            } else {
                break;
            };
            let right = self.parse_additive(allow_named)?;
            expression = make_binary(expression, operator.span, kind, right);
        }
        Ok(expression)
    }

    fn parse_additive(&mut self, allow_named: bool) -> Result<Expr, FrontendDiagnostic> {
        let mut expression = self.parse_multiplicative(allow_named)?;
        loop {
            let (operator, kind) = if let Some(operator) = self.eat(Tag::Plus) {
                (operator, BinaryOperator::Add)
            } else if let Some(operator) = self.eat(Tag::Minus) {
                (operator, BinaryOperator::Subtract)
            } else {
                break;
            };
            let right = self.parse_multiplicative(allow_named)?;
            expression = make_binary(expression, operator.span, kind, right);
        }
        Ok(expression)
    }

    fn parse_multiplicative(&mut self, allow_named: bool) -> Result<Expr, FrontendDiagnostic> {
        let mut expression = self.parse_unary(allow_named)?;
        loop {
            let (operator, kind) = if let Some(operator) = self.eat(Tag::Star) {
                (operator, BinaryOperator::Multiply)
            } else if let Some(operator) = self.eat(Tag::Slash) {
                (operator, BinaryOperator::Divide)
            } else if let Some(operator) = self.eat(Tag::Percent) {
                (operator, BinaryOperator::Remainder)
            } else {
                break;
            };
            let right = self.parse_unary(allow_named)?;
            expression = make_binary(expression, operator.span, kind, right);
        }
        Ok(expression)
    }

    fn parse_unary(&mut self, allow_named: bool) -> Result<Expr, FrontendDiagnostic> {
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
        let mut expression = self.parse_primary(allow_named)?;
        loop {
            if let Some(question) = self.eat(Tag::Question) {
                let span = Span::new(expression.span.start, question.span.end);
                expression = Spanned::new(ExprKind::Propagate(Box::new(expression)), span);
                continue;
            }
            if self.at(Tag::LParen) {
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
            if self.eat(Tag::LBracket).is_some() {
                let index = self.parse_expr()?;
                let end = self.expect(Tag::RBracket)?.span.end;
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
                    let token = self.bump();
                    let TokenKind::Integer(value) = token.kind else {
                        unreachable!("tag and token kind disagree")
                    };
                    let span = Span::new(expression.span.start, token.span.end);
                    expression = Spanned::new(
                        ExprKind::TupleField {
                            receiver: Box::new(expression),
                            index: StringValue {
                                span: token.span,
                                value,
                            },
                        },
                        span,
                    );
                } else {
                    let name = self.expect_identifier()?;
                    if self.at(Tag::LParen) {
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
            break;
        }
        Ok(expression)
    }

    fn parse_call_arguments(&mut self) -> Result<(Vec<CallArgument>, usize), FrontendDiagnostic> {
        self.expect(Tag::LParen)?;
        let mut arguments = Vec::new();
        if !self.at(Tag::RParen) {
            loop {
                if self.at(Tag::Mut) || self.at(Tag::Move) {
                    let start = self.current().span.start;
                    let mode = self
                        .parse_parameter_mode()
                        .expect("mode tag was checked before parsing");
                    let place = self.parse_place_expr()?;
                    arguments.push(CallArgument::Mode {
                        span: Span::new(start, place.span.end),
                        mode,
                        place,
                    });
                } else {
                    arguments.push(CallArgument::Expression(self.parse_expr()?));
                }
                if self.eat(Tag::Comma).is_none() || self.at(Tag::RParen) {
                    break;
                }
            }
        }
        let end = self.expect(Tag::RParen)?.span.end;
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
                if allow_named && self.at(Tag::LBrace) {
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
            return Ok(Spanned::new(
                ExprKind::InterpolatedString(parts),
                Span::new(start, end),
            ));
        }
    }

    fn parse_named_construct(&mut self, path: Path) -> Result<Expr, FrontendDiagnostic> {
        let start = path.span.start;
        self.expect(Tag::LBrace)?;
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
        Ok(Spanned::new(
            ExprKind::List(elements),
            Span::new(start, end),
        ))
    }

    fn parse_parenthesized_or_tuple(&mut self) -> Result<Expr, FrontendDiagnostic> {
        let start = self.expect(Tag::LParen)?.span.start;
        if let Some(close) = self.eat(Tag::RParen) {
            return Ok(Spanned::new(
                ExprKind::Unit,
                Span::new(start, close.span.end),
            ));
        }
        let first = self.parse_expr()?;
        if self.eat(Tag::Comma).is_none() {
            let end = self.expect(Tag::RParen)?.span.end;
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
        let scrutinee = self.parse_control_head()?;
        let (arms, body_span) = self.parse_match_body()?;
        Ok(Spanned::new(
            ExprKind::Match {
                scrutinee: Box::new(scrutinee),
                arms,
            },
            Span::new(start, body_span.end),
        ))
    }

    fn parse_match_body(&mut self) -> Result<(Vec<MatchArm>, Span), FrontendDiagnostic> {
        let start = self.expect(Tag::LBrace)?.span.start;
        let mut arms = Vec::new();
        while !self.at(Tag::RBrace) {
            let arm_start = self.current().span.start;
            let pattern = self.parse_or_pattern()?;
            let guard = if self.eat(Tag::If).is_some() {
                Some(self.parse_expr()?)
            } else {
                None
            };
            self.expect(Tag::FatArrow)?;
            let body = self.parse_expr()?;
            let mut end = body.span.end;
            if let Some(comma) = self.eat(Tag::Comma) {
                end = comma.span.end;
            }
            arms.push(MatchArm {
                span: Span::new(arm_start, end),
                pattern,
                guard,
                body,
            });
        }
        let end = self.expect(Tag::RBrace)?.span.end;
        Ok((arms, Span::new(start, end)))
    }

    fn parse_handle_expression(&mut self) -> Result<Expr, FrontendDiagnostic> {
        let start = self.expect(Tag::Handle)?.span.start;
        let body = self.parse_block()?;
        self.expect(Tag::With)?;
        let (handlers, handler_span) = self.parse_handler_body()?;
        Ok(Spanned::new(
            ExprKind::Handle { body, handlers },
            Span::new(start, handler_span.end),
        ))
    }

    fn parse_handler_body(&mut self) -> Result<(Vec<Handler>, Span), FrontendDiagnostic> {
        let start = self.expect(Tag::LBrace)?.span.start;
        let mut handlers = Vec::new();
        while !self.at(Tag::RBrace) {
            let handler_start = self.current().span.start;
            let effect = self.parse_path(false)?;
            self.expect(Tag::Dot)?;
            let operation = self.expect_identifier()?;
            let parameters = self.parse_named_parameters()?;
            self.expect(Tag::FatArrow)?;
            let body = self.parse_expr()?;
            let mut end = body.span.end;
            if let Some(comma) = self.eat(Tag::Comma) {
                end = comma.span.end;
            }
            handlers.push(Handler {
                span: Span::new(handler_start, end),
                effect,
                operation,
                parameters,
                body,
            });
        }
        let end = self.expect(Tag::RBrace)?.span.end;
        Ok((handlers, Span::new(start, end)))
    }

    fn parse_closure_expression(&mut self) -> Result<Expr, FrontendDiagnostic> {
        let start = self.expect(Tag::Fn)?.span.start;
        let captures = if self.at(Tag::LBracket) {
            Some(self.parse_capture_list()?)
        } else {
            None
        };
        let parameters = self.parse_named_parameters()?;
        let return_type = if self.eat(Tag::Arrow).is_some() {
            Some(self.parse_type_expr()?)
        } else {
            None
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
                captures,
                parameters,
                return_type,
                effects,
                body,
            }),
            Span::new(start, end),
        ))
    }

    fn parse_capture_list(&mut self) -> Result<CaptureList, FrontendDiagnostic> {
        let start = self.expect(Tag::LBracket)?.span.start;
        let mut captures = Vec::new();
        if !self.at(Tag::RBracket) {
            loop {
                let capture_start = self.current().span.start;
                let mode = self.parse_parameter_mode();
                let name = self.expect_identifier()?;
                let annotation = if self.eat(Tag::Colon).is_some() {
                    Some(self.parse_type_expr()?)
                } else {
                    None
                };
                let end = annotation.as_ref().map_or(name.span.end, |ty| ty.span.end);
                captures.push(CaptureParameter {
                    span: Span::new(capture_start, end),
                    mode,
                    name,
                    annotation,
                });
                if self.eat(Tag::Comma).is_none() || self.at(Tag::RBracket) {
                    break;
                }
            }
        }
        let end = self.expect(Tag::RBracket)?.span.end;
        Ok(CaptureList {
            span: Span::new(start, end),
            captures,
        })
    }

    fn parse_unsafe_expression(&mut self) -> Result<Expr, FrontendDiagnostic> {
        let start = self.expect(Tag::Unsafe)?.span.start;
        let body = self.parse_block()?;
        let end = body.span.end;
        Ok(Spanned::new(ExprKind::Unsafe(body), Span::new(start, end)))
    }

    fn parse_block(&mut self) -> Result<Block, FrontendDiagnostic> {
        let start = self.expect(Tag::LBrace)?.span.start;
        let mut statements = Vec::new();
        let mut tail = None;
        while !self.at(Tag::RBrace) {
            if self.at(Tag::Eof) {
                return Err(self.unexpected(vec![Tag::RBrace.expected()]));
            }
            if self.at(Tag::Let) {
                statements.push(self.parse_let_statement()?);
                continue;
            }
            if self.at(Tag::Return) {
                statements.push(self.parse_return_statement()?);
                continue;
            }
            if self.at(Tag::Break) {
                statements.push(self.parse_keyword_statement(Tag::Break, StatementKind::Break)?);
                continue;
            }
            if self.at(Tag::Continue) {
                statements
                    .push(self.parse_keyword_statement(Tag::Continue, StatementKind::Continue)?);
                continue;
            }
            if self.at(Tag::If) && self.nth_tag(1) == Tag::Let {
                statements.push(self.parse_if_let_statement()?);
                continue;
            }
            if self.at(Tag::While) {
                statements.push(self.parse_while_statement()?);
                continue;
            }
            if self.at(Tag::For) {
                statements.push(self.parse_for_statement()?);
                continue;
            }
            if self.at(Tag::Loop) {
                statements.push(self.parse_loop_statement()?);
                continue;
            }
            if self.at_assignment_start() {
                statements.push(self.parse_assignment_statement()?);
                continue;
            }

            let expression = self.parse_expr()?;
            if let Some(semicolon) = self.eat(Tag::Semicolon) {
                statements.push(Statement {
                    span: Span::new(expression.span.start, semicolon.span.end),
                    kind: StatementKind::Expression(expression),
                    terminator: StatementTerminator::Explicit(semicolon.span),
                });
            } else if self.at(Tag::RBrace) {
                tail = Some(Box::new(expression));
                break;
            } else if expression_with_block(&expression.kind) {
                statements.push(Statement {
                    span: expression.span,
                    kind: StatementKind::Expression(expression),
                    terminator: StatementTerminator::Implicit,
                });
            } else {
                return Err(
                    self.unexpected(vec![Tag::Semicolon.expected(), Tag::RBrace.expected()])
                );
            }
        }
        let end = self.expect(Tag::RBrace)?.span.end;
        Ok(Block {
            span: Span::new(start, end),
            statements,
            tail,
        })
    }

    fn parse_let_statement(&mut self) -> Result<Statement, FrontendDiagnostic> {
        let start = self.expect(Tag::Let)?.span.start;
        let binding = if let Some(mutable) = self.eat(Tag::Mut) {
            let name = self.expect_identifier()?;
            let annotation = if self.eat(Tag::Colon).is_some() {
                Some(self.parse_type_expr()?)
            } else {
                None
            };
            LetBinding::Name {
                name,
                mutable: Some(mutable.span),
                annotation,
            }
        } else if self.at(Tag::LParen) {
            LetBinding::Tuple(self.parse_pattern()?)
        } else {
            let name = self.expect_identifier()?;
            let annotation = if self.eat(Tag::Colon).is_some() {
                Some(self.parse_type_expr()?)
            } else {
                None
            };
            LetBinding::Name {
                name,
                mutable: None,
                annotation,
            }
        };
        self.expect(Tag::Equal)?;
        let value = self.parse_expr()?;
        let semicolon = self.expect(Tag::Semicolon)?;
        Ok(Statement {
            span: Span::new(start, semicolon.span.end),
            kind: StatementKind::Let { binding, value },
            terminator: StatementTerminator::Explicit(semicolon.span),
        })
    }

    fn parse_return_statement(&mut self) -> Result<Statement, FrontendDiagnostic> {
        let start = self.expect(Tag::Return)?.span.start;
        let value = if self.at(Tag::Semicolon) {
            None
        } else {
            Some(self.parse_expr()?)
        };
        let semicolon = self.expect(Tag::Semicolon)?;
        Ok(Statement {
            span: Span::new(start, semicolon.span.end),
            kind: StatementKind::Return(value),
            terminator: StatementTerminator::Explicit(semicolon.span),
        })
    }

    fn parse_keyword_statement(
        &mut self,
        keyword: Tag,
        kind: StatementKind,
    ) -> Result<Statement, FrontendDiagnostic> {
        let start = self.expect(keyword)?.span.start;
        let semicolon = self.expect(Tag::Semicolon)?;
        Ok(Statement {
            span: Span::new(start, semicolon.span.end),
            kind,
            terminator: StatementTerminator::Explicit(semicolon.span),
        })
    }

    fn parse_if_let_statement(&mut self) -> Result<Statement, FrontendDiagnostic> {
        let start = self.expect(Tag::If)?.span.start;
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
        Ok(Statement {
            span: Span::new(start, self.previous_end()),
            kind: StatementKind::IfLet {
                pattern,
                value,
                then_branch,
                else_branch,
            },
            terminator: StatementTerminator::Implicit,
        })
    }

    fn parse_while_statement(&mut self) -> Result<Statement, FrontendDiagnostic> {
        let start = self.expect(Tag::While)?.span.start;
        let condition = self.parse_control_head()?;
        let body = self.parse_block()?;
        Ok(Statement {
            span: Span::new(start, body.span.end),
            kind: StatementKind::While { condition, body },
            terminator: StatementTerminator::Implicit,
        })
    }

    fn parse_for_statement(&mut self) -> Result<Statement, FrontendDiagnostic> {
        let start = self.expect(Tag::For)?.span.start;
        let binding = if self.eat(Tag::LParen).is_some() {
            let tuple_start = self.previous_span().start;
            let first = self.expect_identifier()?;
            self.expect(Tag::Comma)?;
            let second = self.expect_identifier()?;
            let mut names = vec![first, second];
            while self.eat(Tag::Comma).is_some() && !self.at(Tag::RParen) {
                names.push(self.expect_identifier()?);
            }
            let tuple_end = self.expect(Tag::RParen)?.span.end;
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
        Ok(Statement {
            span: Span::new(start, body.span.end),
            kind: StatementKind::For {
                binding,
                iterable,
                body,
            },
            terminator: StatementTerminator::Implicit,
        })
    }

    fn parse_loop_statement(&mut self) -> Result<Statement, FrontendDiagnostic> {
        let start = self.expect(Tag::Loop)?.span.start;
        let body = self.parse_block()?;
        Ok(Statement {
            span: Span::new(start, body.span.end),
            kind: StatementKind::Loop(body),
            terminator: StatementTerminator::Implicit,
        })
    }

    fn at_assignment_start(&self) -> bool {
        if self.current_tag() != Tag::Ident {
            return false;
        }
        let mut distance = 1;
        while self.nth_tag(distance) == Tag::Dot && self.nth_tag(distance + 1) == Tag::Ident {
            distance += 2;
        }
        matches!(
            self.nth_tag(distance),
            Tag::Equal
                | Tag::PlusEqual
                | Tag::MinusEqual
                | Tag::StarEqual
                | Tag::SlashEqual
                | Tag::PercentEqual
        )
    }

    fn parse_assignment_statement(&mut self) -> Result<Statement, FrontendDiagnostic> {
        let start = self.current().span.start;
        let target = self.parse_place_expr()?;
        let operator_token = self.bump();
        let operator = match operator_token.kind.tag() {
            Tag::Equal => AssignmentOperator::Assign,
            Tag::PlusEqual => AssignmentOperator::AddAssign,
            Tag::MinusEqual => AssignmentOperator::SubtractAssign,
            Tag::StarEqual => AssignmentOperator::MultiplyAssign,
            Tag::SlashEqual => AssignmentOperator::DivideAssign,
            Tag::PercentEqual => AssignmentOperator::RemainderAssign,
            _ => unreachable!("assignment lookahead and parser disagree"),
        };
        let value = self.parse_expr()?;
        let semicolon = self.expect(Tag::Semicolon)?;
        Ok(Statement {
            span: Span::new(start, semicolon.span.end),
            kind: StatementKind::Assignment {
                target,
                operator: Spanned::new(operator, operator_token.span),
                value,
            },
            terminator: StatementTerminator::Explicit(semicolon.span),
        })
    }

    fn parse_place_expr(&mut self) -> Result<PlaceExpr, FrontendDiagnostic> {
        let root = self.expect_identifier()?;
        let start = root.span.start;
        let mut fields = Vec::new();
        while self.at(Tag::Dot) && self.nth_tag(1) == Tag::Ident {
            self.bump();
            fields.push(self.expect_identifier()?);
        }
        let end = fields.last().map_or(root.span.end, |field| field.span.end);
        Ok(PlaceExpr {
            span: Span::new(start, end),
            root,
            fields,
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
            let mut patterns = vec![self.parse_pattern()?];
            while self.eat(Tag::Comma).is_some() && !self.at(Tag::RParen) {
                patterns.push(self.parse_pattern()?);
            }
            self.expect(Tag::RParen)?;
            Some(PatternFields::Positional(patterns))
        } else if self.eat(Tag::LBrace).is_some() {
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
        let first = self.parse_pattern()?;
        self.expect(Tag::Comma)?;
        let second = self.parse_pattern()?;
        let mut patterns = vec![first, second];
        while self.eat(Tag::Comma).is_some() && !self.at(Tag::RParen) {
            patterns.push(self.parse_pattern()?);
        }
        let end = self.expect(Tag::RParen)?.span.end;
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

    fn previous_span(&self) -> Span {
        self.tokens[self.index - 1].span
    }

    fn previous_end(&self) -> usize {
        self.previous_span().end
    }
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
        Tag::Fn.expected(),
        Tag::LParen.expected(),
        Tag::LBrace.expected(),
    ]
}

fn expression_expectations() -> Vec<ExpectedToken> {
    vec![
        Tag::Minus.expected(),
        Tag::Bang.expected(),
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

fn expression_with_block(kind: &ExprKind) -> bool {
    matches!(
        kind,
        ExprKind::Block(_)
            | ExprKind::If { .. }
            | ExprKind::Match { .. }
            | ExprKind::Handle { .. }
            | ExprKind::Unsafe(_)
            | ExprKind::Catch { .. }
    )
}
