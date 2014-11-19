{-# LANGUAGE RecordWildCards, OverloadedStrings #-}
module Insomnia.SurfaceSyntax.Parse (parseFile) where

import Control.Applicative
import Control.Monad (guard)

import Data.Char (isUpper, isLower)
import Data.Functor.Identity (Identity(..))
import Data.Text (Text)
import qualified Data.Text.IO as T
import Data.Ratio ((%), Rational)

import qualified Text.Parsec.Text as TPT
import Text.Parsec.Char (char, letter, alphaNum, oneOf)
import Text.Parsec.Combinator (eof, sepBy1, between)
import Text.Parsec.Error (ParseError)
import qualified Text.Parsec.Token as Tok hiding (makeTokenParser)
import qualified Text.Parsec.Indentation.Token as Tok
import Text.Parsec.Token (GenLanguageDef(..))
import Text.Parsec.Prim (Parsec, (<?>), try, parse, parseTest)
import Text.Parsec.Expr
import Text.Parsec.Indentation (IndentStream, mkIndentStream,
                                IndentationRel(..), localTokenMode, absoluteIndentation,
                                localIndentation,
                                infIndentation)
import Text.Parsec.Indentation.Char (CharIndentStream, mkCharIndentStream)

import Data.Format (Format(..), WrapShow(..))

import Insomnia.SurfaceSyntax.Syntax
import Insomnia.SurfaceSyntax.FixityParser (Fixity(..), Assoc(..))

newtype FormatParseError = FormatParseError ParseError

instance Format FormatParseError where
  format (FormatParseError pe) = format (WrapShow pe)

--

type InsomniaStream = IndentStream (CharIndentStream Text)

type Parser = Parsec InsomniaStream () 

----------------------------------------

insomniaLang :: GenLanguageDef InsomniaStream () Identity
insomniaLang = Tok.makeIndentLanguageDef $ LanguageDef {
  commentStart = "{-"
  , commentEnd = "-}"
  , commentLine = "--"
  , nestedComments = True
  , identStart = letter <|> char '_'
  , identLetter = alphaNum <|> char '_'
  , opStart = oneOf ":!#$%&*+./<=>?@\\^|-~"
  , opLetter = oneOf ":!#$%&*+./<=>?@\\^|-~"
  , reservedNames = ["model",
                     "forall", "∀",
                     "⋆", "∷",
                     "infix", "infixr", "infixl",
                     "assume",
                     "data", "type", "enum",
                     "val", "fun", "sig",
                     "let", "in", "case", "of",
                     "λ", "_"
                     ]
  , reservedOpNames = ["\\", "::", ".", "~", "=", "*", "|"]
  , caseSensitive = True
  }

Tok.TokenParser {braces = _, ..} = Tok.makeTokenParser insomniaLang

-- For braces, the leading brace opens a scope where the next production can be in any column, and
-- the closing brace likewise.
-- For example:
--     foo = {
--  stuff
--     }
-- 
braces = between (localIndentation Any $ symbol "{") (localIndentation Any $ symbol "}") . localIndentation Any

exactly :: (Show a, Eq a) => Parser a -> a -> Parser ()
exactly p x = (p >>= \x' -> guard (x == x')) <?> show x

----------------------------------------

classify :: Parser ()
classify = reservedOp "::" <|> reserved "∷"

variableIdentifier :: Parser Ident
variableIdentifier = try $ do
  i <- identifier
  let c = head i
  guard (isLower c || c == '_')
  return i

variableOrPrefixInfixIdentifier :: Parser Ident
variableOrPrefixInfixIdentifier =
  try (parens operator)
  <|> variableIdentifier

modelIdentifier :: Parser Ident
modelIdentifier = tyconIdentifier

modelTypeIdentifier :: Parser Ident
modelTypeIdentifier = tyconIdentifier

tyconIdentifier :: Parser Ident
tyconIdentifier = try $ do
  i <- identifier
  let c = head i
  guard (isUpper c)
  return i

infixIdent :: Parser Ident
infixIdent = operator

-- | @qualifiedName p@ is a parser that parses
-- a sequence of Initial-uppercase identifiers separated by "." with no
-- intervening whitespace followed by @p@.  For example "X.Y.Z.<p>"
qualifiedName :: Parser a -> Parser ([String], a)
qualifiedName p =
  let components = do
        c <- (Left <$> try (component <* char '.'))
             <|> (Right <$> p)
        case c of
          Left s -> do 
            (ss, x) <- components
            return (s:ss, x)
          Right x -> return ([], x)
      component = do
        c <- identStart insomniaLang
        guard (isUpper c)
        cs <- many (identLetter insomniaLang)
        return (c:cs)
  in lexeme $ components

qualifiedInfixIdent :: Parser QualifiedIdent
qualifiedInfixIdent =
  (mkQualifiedIdent <$> qualifiedName infixIdent)
  <?> "(possibly qualified) infix identifier"
  where
    mkQualifiedIdent (path, ident) = QId path ident

-- | X.Y.<op> where <op> is a symbolic operator
infixConId :: Parser Con
infixConId =
  Con <$> qualifiedInfixIdent

-- | X.Y.Z -- all components initial-uppercase
conId :: Parser Con
conId = (Con . mkQId) <$> qualifiedName tyconIdentifier
  where
    mkQId (path,ident) = QId path ident


-- | X.Y.Z.v -- all components except the last are initial-uppsercase
qvarId :: Parser QVar
qvarId = (QVar . mkQId) <$> qualifiedName variableIdentifier
  where
    mkQId (path,ident) = QId path ident

varId :: Parser Var
varId = Var <$> variableIdentifier

tvarId :: Parser TyVar
tvarId = TyVar <$> variableIdentifier

modelId :: Parser QualifiedIdent
modelId = mkQId <$> qualifiedName modelIdentifier
  where mkQId = uncurry QId

----------------------------------------
    
parseFile :: FilePath -> IO (Either FormatParseError Toplevel)
parseFile fp = do
  txt <- T.readFile fp
  let s = mkIndentStream 0 infIndentation True Gt $ mkCharIndentStream txt
  return (either (Left . FormatParseError) Right $ parse toplevel fp s)

----------------------------------------

toplevel :: Parser Toplevel
toplevel = Toplevel <$> (whiteSpace *> (localIndentation Any $ many (absoluteIndentation toplevelItem)) <* finish)
  where
    finish = localTokenMode (const Any) eof

toplevelItem :: Parser ToplevelItem
toplevelItem =
  (toplevelModel <?> "toplevel model definition")
  <|> (toplevelModelType <?> "toplevel model type definition")

toplevelModel :: Parser ToplevelItem
toplevelModel =
  ToplevelModel
  <$> (try (reserved "model" *> modelIdentifier))
  <*> optional (classify *> (IdentMT <$> modelTypeIdentifier))
  <*> ((reservedOp "=" *> modelExpr)
       <|> literalModelShorthand)
  where
    literalModelShorthand = modelLiteral

toplevelModelType :: Parser ToplevelItem
toplevelModelType =
  ToplevelModelType
  <$> (try (reserved "model" *> reserved "type" *> modelTypeIdentifier))
  <*> braces (SigMT <$> signature)

signature :: Parser Signature
signature =
  Sig <$> localIndentation Ge (many $ absoluteIndentation sigDecl)

sigDecl :: Parser SigDecl
sigDecl =
  submodelSig
  <|> valueSig
  <|> typeSig
  <|> fixitySig

submodelSig :: Parser SigDecl
submodelSig =
  SubmodelSig
  <$> (reserved "model" *> modelIdentifier)
  <* classify
  <*> modelTypeExpr

valueSig :: Parser SigDecl
valueSig =
  ValueSig
  <$> (reserved "sig" *> variableOrPrefixInfixIdentifier)
  <* classify
  <*> typeExpr

typeSig :: Parser SigDecl
typeSig =
  mkTypeSig
  <$> (manifestTypeSigDecl <$> (dataDefn <|> enumDefn)
       <|> abstractDeclOrAliasDefn)
  where
    mkTypeSig (ident, tySigDecl) = TypeSig ident tySigDecl

    manifestTypeSigDecl (ident, td) = (ident, ManifestTypeSigDecl td)

    abstractDeclOrAliasDefn =
      abstractOrAlias
      <$> (reserved "type" *> tyconIdentifier)
      <*> ((Left <$> (classify *> kindExpr))
           <|> (Right <$> ((,)
                           <$> many kindedTVar
                           <* reservedOp "="
                           <*> typeExpr)))

    abstractOrAlias ident (Left k) =
      (ident, AbstractTypeSigDecl k)
    abstractOrAlias ident (Right (tvks, ty)) =
      (ident, AliasTypeSigDecl (TypeAlias tvks ty))

fixitySig :: Parser SigDecl
fixitySig =
  mkFixitySig <$> fixity
  where
    mkFixitySig (ident, f) = FixitySig ident f

fixity :: Parser (Ident, Fixity)
fixity =
  mkFixity
  <$> fixityKW
  <*> operator
  <*> fixprecedence
  where
    mkFixity assc ident prec = (ident, Fixity assc prec)

    fixityKW = (reserved "infix" *> pure AssocNone)
               <|> (reserved "infixl" *> pure AssocLeft)
               <|> (reserved "infixr" *> pure AssocRight)
    fixprecedence =
      mkRational <$> integer <*> optional (exactly operator "/" *> integer)
      
    mkRational :: Integer -> Maybe Integer -> Rational
    mkRational num (Just denom) = num % denom
    mkRational num Nothing = num % 1

    

modelTypeExpr :: Parser ModelType
modelTypeExpr =
  (IdentMT <$> modelTypeIdentifier <?> "model type identifier")
  <|> (SigMT <$> braces signature <?> "model signature in braces")


modelLiteral :: Parser ModelExpr
modelLiteral =
  (ModelStruct . Model) <$> braces (localIndentation Ge $ many $ absoluteIndentation decl)

modelExpr :: Parser ModelExpr
modelExpr =
  (modelLiteral <?> "braced model definition")
  <|> (modelAssume <?> "model postulate (\"assume\")")
  <|> (nestedModel <?> "model sealed with a signature")
  <|> (modelPath <?> "qualified model name")
  where
    modelAssume =  (ModelAssume . IdentMT)
                   <$> (reserved "assume" *> modelTypeIdentifier)
    nestedModel = parens (mkNestedModelExpr
                          <$> modelExpr
                          <*> optional (classify *> modelTypeExpr))
    modelPath = ModelId <$> modelId

    mkNestedModelExpr modExpr Nothing = modExpr
    mkNestedModelExpr modExpr (Just modTy) = ModelSeal modExpr modTy


decl :: Parser Decl
decl = (valueDecl <?> "value declaration")
       <|> (fixityDecl <?> "fixity declaration")
       <|> (typeDefn <?> "type definition")
       <|> (typeAliasDefn <?> "type alias definition")
       <|> (modelDefn <?> "submodel definition")

fixityDecl :: Parser Decl
fixityDecl = uncurry FixityDecl <$> fixity

valueDecl :: Parser Decl
valueDecl =
  mkValueDecl <$> ((funDecl <?> "function definition")
                 <|> (valueSigDecl <?> "function signature")
                 <|> (valOrSampleDecl <?> "defined or sampled value"))
  where
    mkValueDecl (fld, d) = ValueDecl fld d

typeDefn :: Parser Decl
typeDefn =
  mkTypeDefn <$> ((dataDefn <?> "algebraic data type definition")
                  <|> (enumDefn <?> "enumeration declaration"))
  where
    mkTypeDefn (fld, d) = TypeDefn fld d

typeAliasDefn :: Parser Decl
typeAliasDefn =
  mkTypeAliasDefn
  <$> (reserved "type" *> tyconIdentifier)
  <*> many kindedTVar
  <* reservedOp "="
  <*> typeExpr
  where
    mkTypeAliasDefn fld tyvars ty =
      TypeAliasDefn fld (TypeAlias tyvars ty)


modelDefn :: Parser Decl
modelDefn =
  mkModelDefn <$> (reserved "model" *> modelIdentifier)
  <*> optional (classify *> modelTypeIdentifier)
  <*> modelExpr
  where
    mkModelDefn modIdent maybeSigId content =
      let
        m = case maybeSigId of
          Nothing -> content
          Just msigId -> ModelSeal content (IdentMT msigId)
      in SubmodelDefn modIdent m

funDecl :: Parser (Ident, ValueDecl)
funDecl =
  mkFunDecl
  <$> (reserved "fun" *> variableOrPrefixInfixIdentifier)
  <*> (some annVar)
  <*> (reservedOp "=" *> expr)
  where
    mkFunDecl f xs e =(f, FunDecl (mkLams xs e))

-- | Make a sequence of nested lambdas
mkLams :: [(Ident, Maybe Type)] -> Expr -> Expr
mkLams [] _ = error "cannot have lambda with no variables"
mkLams [(v, mty)] e = Lam v mty e
mkLams ((v, mty):vs) e = Lam v mty (mkLams vs e)

valueSigDecl :: Parser (Ident, ValueDecl)
valueSigDecl =
  mkSigDecl
  <$> (reserved "sig" *> variableOrPrefixInfixIdentifier)
  <* classify
  <*> typeExpr
  where
    mkSigDecl f ty = (f, SigDecl ty)

valOrSampleDecl :: Parser (Ident, ValueDecl)
valOrSampleDecl =
  mkValOrSampleDecl
  <$> (reserved "val" *> variableOrPrefixInfixIdentifier)
  <*> ((pure ValDecl <* reservedOp "=")
       <|> (pure SampleDecl <* reservedOp "~"))
  <*> expr
  where
    mkValOrSampleDecl v maker e = (v, maker e)


dataDefn :: Parser (Ident, TypeDefn)
dataDefn = mkDataDefn
           <$> (reserved "data" *> tyconIdentifier)
           <*> many (kindedTVar)
           <*> (reservedOp "="
                *> sepBy1 constructorDef (reservedOp "|"))
  where
    mkDataDefn nm tyvars cons = (nm, DataTD $ DataDefn tyvars cons)

enumDefn :: Parser (Ident, TypeDefn)
enumDefn = mkEnumDefn
           <$> (reserved "enum" *> tyconIdentifier)
           <*> natural
  where
    mkEnumDefn nm card = (nm, EnumTD card)

constructorDef :: Parser ConstructorDef
constructorDef =
  ConstructorDef
  <$> tyconIdentifier
  <*> many (atomicTy <$> typeAtom)
  where
    atomicTy atm = TPhrase [atm]

kindedTVar :: Parser KindedTVar
kindedTVar =
  parens ((,) <$> tvarId
          <*> (classify *> kindExpr))

kindExpr :: Parser Kind
kindExpr = buildExpressionParser table kindFactor
  where
    kindFactor = parens kindExpr
                 <|> pure KType <* starKW

    table =
      [
        [Infix arrK AssocRight]
      ]

    arrK = arrowKW *> pure KArr
    
    starKW = reservedOp "*" <|> reservedOp "⋆"
    arrowKW = reservedOp "->" <|> reserved "→"

typeAtom :: Parser TypeAtom
typeAtom =
  (TV <$> tvarId)
  <|> (TC <$> try (conId <|> infixConId))
  <|> (TEnclosed <$> tforall <*> pure Nothing)
  <|> (TRecord <$> recordRow)
  <|> parens (TEnclosed <$> typeExpr
              <*> optional (classify *> kindExpr))

recordRow :: Parser Row
recordRow =
  Row <$> (braces (semiSep labeledType))
  where
    labeledType = (,) <$> label <* classify <*> typeExpr

label :: Parser Label
label = Label <$> variableIdentifier

typeExpr :: Parser Type
typeExpr =
  TPhrase <$> many typeAtom

tforall :: Parser Type
tforall = mkForall
          <$> (forallKW *> some kindedTVar)
          <*> (reservedOp "." *> typeExpr)
  where
    mkForall [] ty = ty
    mkForall ((v,k):vks) ty =
      TForall v k (mkForall vks ty)

    forallKW = reserved "forall" <|> reserved "∀"

annVar :: Parser (Ident, Maybe Type)
annVar = (unannotated <$> variableIdentifier)
         <|> parens (annotated
                     <$> variableIdentifier
                     <*> (classify *> typeExpr))
         <?> "var or (var :: ty)"
  where
    unannotated v = (v, Nothing)
    annotated v ty = (v, Just ty)

expr :: Parser Expr
expr =
  (lamExpr <?> "lambda expression")
  <|> (caseExpr <?> "case expression")
  <|> (letExpr <?> "let expression")
  <|> (Phrase <$> some exprAtom)

exprNotationIdentifier :: Parser (Notation Identifier)
exprNotationIdentifier =
  (PrefixN . V <$> varId)
  <|> ((InfixN . V . Var) <$> infixIdent)
  <|> ((InfixN . Q . QVar) <$> try qualifiedInfixIdent)
  <|> (PrefixN . Q <$> try qvarId)
  <|> (PrefixN . C <$> try conId)

exprAtom :: Parser ExprAtom
exprAtom =
  (I <$> exprNotationIdentifier)
  <|> (L <$> literal)
  <|> recordExpression
  <|> parens (Enclosed <$> expr
              <*> optional (classify *> typeExpr))

recordExpression :: Parser ExprAtom
recordExpression =
  Record <$> braces (commaSep labeledAssignExpr)
  where
    labeledAssignExpr = (,) <$> label <* reservedOp "=" <*> expr

literal :: Parser Literal
literal = RealL <$> try float
          <|> IntL <$> try integer
          <?> "literal double or integer"

lamExpr :: Parser Expr
lamExpr = fail "unimplemented lamExpr"

caseExpr :: Parser Expr
caseExpr = Case
           <$> (reserved "case" *> expr)
           <*> (reserved "of" *> (eClauses <|> iClauses))
  where
    -- explicit braces
    eClauses = braces (semiSep clause)
    -- implicit indentation
    iClauses = localIndentation Gt $ many $ absoluteIndentation clause
  
letExpr :: Parser Expr
letExpr = Let
          <$> (reserved "let" *> (eBindings <|> iBindings))
          <*> (reserved "in"  *> expr)
          <?> "let expression"
  where
    eBindings = braces (semiSep binding)
    iBindings = localIndentation Gt (many $ absoluteIndentation binding)
    
clause :: Parser Clause
clause = (Clause
          <$> simplePattern
          <*> (exactly operator "->" *> expr))
         <?> "case expression clause"
  where
    simplePattern = mkPattern <$> patternAtom
    mkPattern pa = PhraseP [pa]

patternAtom :: Parser PatternAtom
patternAtom =
  ((pure WildcardP <* reserved "_") <?> "wildcard pattern")
  <|> ((ConP <$> ((PrefixN <$> conId)
                  <|> (InfixN . Con <$> qualifiedInfixIdent)))
       <?> "constructor pattern")
  <|> (VarP <$> varId <?> "variable pattern")
  <|> recordPattern
  <|> parens (EnclosedP <$> pattern)

recordPattern :: Parser PatternAtom
recordPattern =
  RecordP <$> braces (commaSep labeledPattern)
  where
    labeledPattern = (,) <$> label <* reservedOp "=" <*> pattern

pattern :: Parser Pattern
pattern = PhraseP <$> some patternAtom

binding :: Parser Binding
binding = (tabulatedFunB <?> "tabulated function definition")
          <|> (simpleBinding <?> "var = expr or var ~ expr")

simpleBinding :: Parser Binding
simpleBinding = mkBinding
          <$> annVar
          <*> bindingOperator
          <*> expr
  where
    bindingOperator = (pure SampleB <* reservedOp "~")
                      <|> (pure ValB <* reservedOp "=")
    mkBinding (v, _ty) op e = op v e -- TODO: use the type

tabulatedFunB :: Parser Binding
tabulatedFunB =
  reserved "forall"
  *> (mkTabB
      <$> some annVar
      <* reserved "in"
      <*> variableIdentifier
      <*> some tabSelector
      <* reservedOp "~"
      <*> expr)
  where
    mkTabB avs y sels e =
      TabB avs [TabulatedFun y $ TabSample sels e]

tabSelector :: Parser TabSelector
tabSelector = (TabIndex <$> variableIdentifier)