{-# LANGUAGE OverloadedStrings, ViewPatterns, FlexibleContexts #-}
-- | Infer the natural signature of a module by typechecking its constituents.
--
module Insomnia.Typecheck.Module (inferModuleExpr, extendDCtx) where

import Prelude hiding (mapM_)

import Control.Applicative ((<$>))
import Control.Lens
import Control.Monad.Reader.Class (MonadReader(..))

import Data.Monoid (Monoid(..), (<>), Endo(..))
import qualified Data.Set as S

import qualified Unbound.Generics.LocallyNameless as U

import Insomnia.Common.Stochasticity
import Insomnia.Common.ModuleKind
import Insomnia.Identifier (Path(..), Field)
import Insomnia.Types (Kind(..), TypeConstructor(..), TypePath(..),
                       TyVar, Type(..),
                       freshUVarT,
                       transformEveryTypeM, TraverseTypes(..),
                       tForalls)
import Insomnia.Expr (Var, Expr, TabulatedFun, TraverseExprs(..),
                      Function(..), Generalization(..), PrenexCoercion(..))
import Insomnia.ModuleType (ModuleTypeNF(..),
                            SigV(..))
import Insomnia.Module
import Insomnia.Pretty (Pretty, PrettyShort(..))

import Insomnia.Unify (UVar,
                       uvarClassifier,
                       Unifiable(..),
                       MonadCheckpointUnification(..),
                       (-?=),
                       applyCurrentSubstitution,
                       solveUnification,
                       UnificationResult(..))

import Insomnia.Typecheck.Env
import Insomnia.Typecheck.Type (checkType)
import Insomnia.Typecheck.Expr (checkExpr, checkTabulatedFunction)
import Insomnia.Typecheck.TypeDefn (checkTypeDefn,
                                    checkTypeAlias,
                                    extendTypeDefnCtx,
                                    extendTypeAliasCtx)
import Insomnia.Typecheck.ModuleType (checkModuleType, extendModuleCtxFunctorArgs)
import Insomnia.Typecheck.Selfify (selfifySignature)
import Insomnia.Typecheck.ClarifySignature (clarifySignatureNF)
import Insomnia.Typecheck.ExtendModuleCtx (extendModuleCtxNF)
import Insomnia.Typecheck.LookupModuleSigPath (lookupModuleSigPath)
import Insomnia.Typecheck.ConstructImportDefinitions (constructImportDefinitions)
import Insomnia.Typecheck.MayAscribe (mayAscribeNF)
import Insomnia.Typecheck.NaturalSignature (naturalSignature, naturalSignatureModuleExpr)
import Insomnia.Typecheck.FunctorApplication (checkFunctorApplication)
import {-# SOURCE #-} Insomnia.Typecheck.ObservationClause (checkObservationClauses)

-- | Infer the signature of the given module expression
inferModuleExpr :: Path -> ModuleExpr -> TC (ModuleExpr, ModuleTypeNF)
inferModuleExpr pmod (ModuleStruct mk mdl) = do
  mdl' <- checkModule pmod (stochasticityForModule mk) mdl return
            <??@ "while checking " <> formatErr mk <> " " <> formatErr pmod
  msig <- naturalSignature mdl'
  return (ModuleStruct mk mdl', SigMTNF (SigV msig mk))
inferModuleExpr pmod (ModuleSeal mdl mtypeSealed) = do
  (mdl', mtnfInferred) <- inferModuleExpr pmod mdl
  (mtypeSealed', mtnfSealed) <- checkModuleType mtypeSealed
                                <??@ ("while checking sealing signature of " <> formatErr pmod)
  mtnfSealed' <- mayAscribeNF mtnfInferred mtnfSealed
                 <??@ ("while checking validity of signature sealing to "
                       <> formatErr pmod)
  return (ModuleSeal mdl' mtypeSealed', mtnfSealed')
inferModuleExpr pmod (ModuleAssume moduleType) = do
  (moduleType', sigV) <- checkModuleType moduleType
                         <??@ ("while checking postulated signature of "
                               <> formatErr pmod)
  return (ModuleAssume moduleType', sigV)
inferModuleExpr pmod (ModuleId modPathRHS) = do
  sigV <- lookupModuleSigPath modPathRHS
          <??@ ("while checking the definition of " <> formatErr pmod)
  sigV' <- clarifySignatureNF modPathRHS sigV
  return (ModuleId modPathRHS, sigV')
inferModuleExpr pmod (ModuleApp pfun pargs) = do
  sigNF <- checkFunctorApplication pfun pargs
           <??@ ("while checking functor application definiing " <> formatErr pmod)
  return (ModuleApp pfun pargs, sigNF)
inferModuleExpr pmod (ModuleFun bnd) =
  U.lunbind bnd $ \(teleArgs, body) ->
  extendModuleCtxFunctorArgs teleArgs $ \teleArgs' teleArgsNF -> do
    bodyName <- U.lfresh (U.s2n "<functor body>")
    (body', bodyNF) <- inferModuleExpr (IdP bodyName) body
                       <??@ ("while checking the body of functor " <> formatErr pmod)
    return (ModuleFun $ U.bind teleArgs' body',
            FunMTNF $ U.bind teleArgsNF bodyNF)
inferModuleExpr pmod (ModelLocal modHidden body mty) = do
     (mty', mtnfAscribed) <- checkModuleType mty
     (mdl, sig) <- checkModule pmod RandomVariable modHidden $ \modHidden' -> do
       (body', mtnfInferred) <- inferModuleExpr pmod body 
                                <??@ ("while checking the body of local model "<> formatErr pmod)
       mtnfAscribed' <- mayAscribeNF mtnfInferred mtnfAscribed
                      <??@ ("while checking validity of signature ascription to body of local model in "
                            <> formatErr pmod)
       sigAscribed <- case mtnfAscribed' of
                      SigMTNF (SigV s ModelMK) -> return s
                      SigMTNF (SigV s ModuleMK) ->
                        typeError ("local model " <> formatErr pmod
                                   <> " is ascribed a module type " <> formatErr s
                                   <> ", not a model type")
                      FunMTNF {} -> typeError ("local model " <> formatErr pmod
                                               <> " is ascribed a functor type ")
       return (ModelLocal modHidden' body' mty', (SigMTNF (SigV sigAscribed ModelMK)))
     return (mdl, sig)
inferModuleExpr pmod (ModelObserve mdle obss) = do
  (mdle', mtnf) <- inferModuleExpr pmod mdle
                   <??@ "while checking model of observation " <> formatErr pmod
  mdlSig <- case mtnf of
    FunMTNF {} -> typeError ("expected a model, but got a functor when "
                             <> "checking an observation " <> formatErr pmod)
    (SigMTNF (SigV mdlSig ModelMK)) -> return mdlSig
    (SigMTNF (SigV _ ModuleMK)) -> typeError ("expected a model, but got a module when"
                                              <> "checking an observation " <> formatErr pmod)
  obss' <- checkObservationClauses pmod mdlSig obss
  return (ModelObserve mdle' obss', mtnf)
inferModuleExpr pmod (ModuleUnpack e msig) = do
  (msig', mtnf) <- checkModuleType msig
           <??@ ("while checking ascribed signature for unpack module from expression in "
                 <> formatErr pmod)
  let mt = TPack msig'
  res <- solveUnification $ do
    checkExpr e mt
      <??@ ("while checking expression to unpack at " <> formatErr pmod)
  case res of
    UOkay e_ -> return (ModuleUnpack e_ msig', mtnf)
    UFail err -> typeError ("when checking unpacked expression " <> formatErr err)

-- | After checking a declaration we get one or more declarations out
-- (for example if we inferred a signature for a value binding that did not have one).
type CheckedDecl = Endo [Decl]

singleCheckedDecl :: Decl -> CheckedDecl
singleCheckedDecl d = Endo (d :)


-- | Typecheck the contents of a module.
checkModule :: Path -> Stochasticity -> Module -> (Module -> TC r) -> TC r
checkModule pmod stoch (Module ds) =
  \kont ->
   go ds $ \cd ->
   kont (Module $ checkedDeclToDecls cd)
  where
    checkedDeclToDecls :: CheckedDecl -> [Decl]
    checkedDeclToDecls = flip appEndo mempty
    go :: [Decl] -> (CheckedDecl -> TC r) -> TC r
    go [] kont = kont mempty
    go (decl:decls) kont = do
      decl' <- checkDecl pmod stoch decl
      extendDCtx pmod decl' $
        go decls $ \decls' ->
        kont (decl' <> decls')

checkDecl :: Path -> Stochasticity -> Decl -> TC CheckedDecl
checkDecl pmod stoch d =
  checkDecl' pmod stoch d
  <??@ "while checking " <> formatErr (PrettyShort d)

-- | Given the path to the module, check the declarations.
checkDecl' :: Path -> Stochasticity -> Decl -> TC CheckedDecl
checkDecl' pmod stoch d =
  case d of
    TypeDefn fld td -> do
      let dcon = TCGlobal (TypePath pmod fld)
      guardDuplicateDConDecl dcon
      (td', _) <- checkTypeDefn (TCLocal $ U.s2n fld) td
      return $ singleCheckedDecl $ TypeDefn fld td'
    ImportDecl impPath ->
      checkImportDecl pmod stoch impPath
    TypeAliasDefn fld alias -> do
      let dcon = TCGlobal (TypePath pmod fld)
      guardDuplicateDConDecl dcon
      (alias', _) <- checkTypeAlias alias
      return $ singleCheckedDecl $ TypeAliasDefn fld alias'
    ValueDecl fld vd ->
      let v = U.s2n fld
      in checkedValueDecl fld <$> checkValueDecl fld v vd
    SubmoduleDefn fld moduleExpr -> do
      (moduleExpr', _sig) <- inferModuleExpr (ProjP pmod fld) moduleExpr
      return $ singleCheckedDecl $ SubmoduleDefn fld moduleExpr'
    SampleModuleDefn fld moduleExpr -> do
      modExprId <- U.lfresh (U.s2n "<sampled model>")
      let modExprPath = IdP modExprId
      (moduleExpr', sigV) <- inferModuleExpr modExprPath moduleExpr
      case sigV of
        (SigMTNF (SigV _sig ModelMK)) -> return ()
        (SigMTNF (SigV _sig ModuleMK)) ->
          typeError ("submodule " <> formatErr (ProjP pmod fld)
                     <> " is sampled from a module, not a model")
        (FunMTNF {}) ->
          typeError ("submodule " <> formatErr (ProjP pmod fld)
                     <> " is sampled from a functor, not a model")
      return $ singleCheckedDecl $ SampleModuleDefn fld moduleExpr'

type CheckedValueDecl = Endo [ValueDecl]

checkImportDecl :: Path -> Stochasticity -> Path -> TC CheckedDecl
checkImportDecl pmod stoch impPath = do
  impSigV <- lookupModuleSigPath impPath
  case impSigV of
   (SigMTNF (SigV msig ModuleMK)) -> do
     selfSig <- selfifySignature impPath msig
                <??@ ("while importing " <> formatErr impPath
                      <> " into " <> formatErr pmod)
     importDefns <- constructImportDefinitions selfSig stoch
     return importDefns
   (SigMTNF (SigV _ ModelMK)) ->
     typeError ("cannot import model " <> formatErr impPath <> " into "
                <> (case stoch of
                     RandomVariable -> " model "
                     DeterministicParam -> " module ")
                <> formatErr pmod)
   (FunMTNF {}) -> 
     typeError ("cannot import functor " <> formatErr impPath <> " into "
                <> (case stoch of
                     RandomVariable -> " model "
                     DeterministicParam -> " module ")
                <> formatErr pmod)
                

checkedValueDecl :: Field -> CheckedValueDecl -> CheckedDecl
checkedValueDecl fld cd =
  -- hack
  let vds = appEndo cd []
  in Endo (map (ValueDecl fld) vds ++)
  

singleCheckedValueDecl :: ValueDecl -> CheckedValueDecl
singleCheckedValueDecl vd = Endo (vd :)



checkValueDecl :: Field -> Var -> ValueDecl -> TC CheckedValueDecl
checkValueDecl fld v vd =
  case vd of
    SigDecl stoch t -> do
      guardDuplicateValueDecl v
      singleCheckedValueDecl <$> checkSigDecl stoch t
    FunDecl fun -> do
      msig <- lookupLocal v
      ensureNoDefn v
      U.avoid [U.AnyName v] $ checkFunDecl fld msig fun
    ValDecl e -> do
      msig <- lookupLocal v
      ensureNoDefn v
      U.avoid [U.AnyName v] $ checkValDecl fld msig e
    SampleDecl e -> do
      msig <- lookupLocal v
      ensureNoDefn v
      U.avoid [U.AnyName v] $ checkSampleDecl fld msig e
    ParameterDecl e -> do
      msig <- lookupLocal v
      ensureNoDefn v
      U.avoid [U.AnyName v] $ checkParameterDecl fld msig e
    TabulatedSampleDecl tf -> do
      msig <- lookupLocal v
      ensureNoDefn v
      U.avoid [U.AnyName v] $ checkTabulatedSampleDecl v msig tf

checkSigDecl :: Stochasticity -> Type -> TC ValueDecl
checkSigDecl stoch t = do
  t' <- checkType t KType
  return $ SigDecl stoch t'

ensureParameter :: Pretty what => what -> Stochasticity -> TC ()
ensureParameter what stoch =
  case stoch of
   DeterministicParam -> return ()
   RandomVariable ->
     typeError ("Expected " <> formatErr what
                <> " to be a parameter, but it was declared as a random variable")

ensureRandomVariable :: Pretty what => what -> Stochasticity -> TC ()
ensureRandomVariable what stoch =
  case stoch of
   RandomVariable -> return ()
   DeterministicParam ->
     typeError ("Expected " <> formatErr what
                <> " to be a random variable, but it was declared as a parameter")

ensureExpStochasticity :: Pretty what => Stochasticity -> what -> Stochasticity -> TC ()
ensureExpStochasticity want =
  case want of
   RandomVariable -> ensureRandomVariable
   DeterministicParam -> ensureParameter

checkFunDecl :: Field -> Maybe Type -> Function -> TC CheckedValueDecl
checkFunDecl fname mty_ (Function eg) = do
  e <- case eg of
    Left e -> return e
    Right {} -> typeError ("internal error - did not expect a function with a generalization annotation")
  res <- solveUnification $ do
    (ecls, tinf) <- openAbstract mty_ $ \tvks mty -> do
      ((e_, tu), us) <- listenUnconstrainedUVars $ do
        tu <- freshUVarT KType
        case mty of
         Just ty -> tu =?= ty
         Nothing -> return ()
        e_ <- checkExpr e tu
        return (e_, tu)
      skolemize (S.toList us) $ \tvks' -> do
        tinf <- applyCurrentSubstitution tu
        e' <- transformEveryTypeM applyCurrentSubstitution e_
        let ecls = U.bind (tvks ++ tvks') e'
        return (ecls, tForalls tvks' tinf)
    let
      g = Generalization ecls (PrenexMono tinf)
      funDecl = singleCheckedValueDecl $ FunDecl (Function $ Right g)
    sigDecl <- case mty_ of
          Just _ -> return mempty
          Nothing -> do
            return $ singleCheckedValueDecl $ SigDecl DeterministicParam tinf
    return (sigDecl <> funDecl)
  case res of
    UOkay ans -> return ans
    UFail err -> typeError ("when checking " <> formatErr fname
                            <> formatErr err)

skolemize :: [UVar Kind Type] -> ([(TyVar, Kind)] -> TC res) -> TC res
skolemize [] kont = kont []
skolemize (u:us) kont = do
  tv <- U.lfresh (U.s2n "χ")
  let k = u^.uvarClassifier
  u -?= (TV tv) -- unify the unification var with the new skolem constant
  U.avoid [U.AnyName tv]
    $ extendTyVarCtx tv k
    $ skolemize us (\tvks -> kont $ (tv,k):tvks)

-- Note that for values, unlike functions we don't generalize
checkValDecl :: Field -> Maybe Type -> Expr -> TC CheckedValueDecl
checkValDecl fld _mty _e = do
  typeError ("internal error - unexpected val decl "
             <> "(should've been translated away to a SampleDecl) while checking "
             <> formatErr fld)
  -- res <- solveUnification $ do
  --   tu <- freshUVarT KType
  --   case mty of
  --     Just ty -> tu =?= ty
  --     Nothing -> return ()
  --   e' <- checkExpr e tu
  --   let
  --     valDecl = singleCheckedValueDecl $ ValDecl e'
  --   sigDecl <- case mty_ of
  --         Just _ -> return mempty
  --         Nothing -> do
  --           tinf <- applyCurrentSubstitution tu
  --           -- by this point, if val decls are always parameters, "val x = e" inside models
  --           -- was turned into "val x ~ ireturn e" (ie a SampleDecl).
  --           return $ singleCheckedValueDecl $ SigDecl DeterministicParam tinf
  --   return (sigDecl <> valDecl)
  -- case res of
  --   UOkay ans -> return ans
  --   UFail err -> typeError ("when checking "<> formatErr fld
  --                           <> formatErr err)

checkSampleDecl :: Field -> Maybe Type -> Expr -> TC CheckedValueDecl
checkSampleDecl fld mty e = do
  res <- solveUnification $ do
    tu <- freshUVarT KType
    case mty of
      Just ty -> tu =?= ty
      Nothing -> return ()
    e_ <- checkExpr e (distT tu)
    e' <- transformEveryTypeM applyCurrentSubstitution e_
    let
      sampleDecl = singleCheckedValueDecl $ SampleDecl e'
    sigDecl <- case mty of
          Just _ -> return mempty
          Nothing -> do
            tinf <- applyCurrentSubstitution tu
            return $ singleCheckedValueDecl $ SigDecl RandomVariable tinf
    return (sigDecl <> sampleDecl)
  case res of
    UOkay ans -> return ans
    UFail err -> typeError ("when checking " <> formatErr fld
                            <> formatErr err)

checkParameterDecl :: Field -> Maybe Type -> Expr -> TC CheckedValueDecl
checkParameterDecl fld mty e = do
  res <- solveUnification $ do
    tu <- freshUVarT KType
    case mty of
     Just ty -> tu =?= ty
     Nothing -> return ()
    e_ <- checkExpr e tu
    e' <- transformEveryTypeM applyCurrentSubstitution e_
    let
      paramDecl = singleCheckedValueDecl $ ParameterDecl e'
    sigDecl <- case mty of
          Just _ -> return mempty
          Nothing -> do
            tinf <- applyCurrentSubstitution tu
            return $ singleCheckedValueDecl $ SigDecl DeterministicParam tinf
    return (sigDecl <> paramDecl)
  case res of
   UOkay ans -> return ans
   UFail err -> typeError ("when checking " <> formatErr fld
                           <> formatErr err)

checkTabulatedSampleDecl :: Var -> Maybe Type -> TabulatedFun -> TC CheckedValueDecl
checkTabulatedSampleDecl v mty tf = do
   checkTabulatedFunction v tf $ \tf' tyInferred -> do
     sigDecl <- case mty of
                 Just tySpec -> do
                   (tySpec =?= tyInferred)
                     <??@ ("while checking tabulated function definition " <> formatErr v)
                   return mempty
                 Nothing -> do
                   tinf <- applyCurrentSubstitution tyInferred
                   return $ singleCheckedValueDecl $ SigDecl RandomVariable tinf
     tf'' <- do
       x <- traverseExprs (transformEveryTypeM applyCurrentSubstitution) tf'
       y <- traverseTypes applyCurrentSubstitution (x :: TabulatedFun)
       return y
     let
       tabFunDecl = singleCheckedValueDecl $ TabulatedSampleDecl tf''
     return (sigDecl <> tabFunDecl)

-- | Given a type ∀ α1∷K1 ⋯ αN∷KN . τ, freshen αᵢ and add them to the
-- local type context in the given continuation which is passed
-- τ[αfresh/α]
openAbstract :: Maybe Type -> ([(TyVar, Kind)] -> Maybe Type -> TC a) -> TC a
openAbstract Nothing kont = kont [] Nothing
openAbstract (Just ty) kont =
  openAbstract' ty (\tvks ty' -> kont tvks (Just ty'))

openAbstract' :: Type -> ([(TyVar, Kind)] -> Type -> TC a) -> TC a
openAbstract' ty kont =
  case ty of
    TForall bnd -> U.lunbind bnd $ \ (tvk@(tv,k), ty') ->
      extendTyVarCtx tv k $ openAbstract' ty' (\tvks -> kont (tvk:tvks)) 
    _ -> kont [] ty


guardDuplicateValueDecl :: Var -> TC ()
guardDuplicateValueDecl v = do
  msig <- view (envLocals . at v)
  mdef <- view (envGlobalDefns . at v)
  case (msig, mdef) of
    (Nothing, Nothing) -> return ()
    (Just _, _) -> typeError (formatErr v <> " already has a type signature")
    (_, Just _) -> typeError (formatErr v <> " already has a definition")

-- | Extend the environment by incorporating the given declaration.
extendDCtx :: Path -> CheckedDecl -> TC a -> TC a
extendDCtx pmod cd = go (appEndo cd mempty)
  where
    go :: [Decl] -> TC a -> TC a
    go [] m = m
    go (d:ds) m = extendDCtxSingle pmod d $ go ds m

extendDCtxSingle :: Path -> Decl -> TC a -> TC a
extendDCtxSingle pmod d kont =
  case d of
    ValueDecl fld vd -> extendValueDeclCtx pmod fld vd kont
    TypeDefn fld td -> do
      let shortIdent = U.s2n fld
      extendTypeDefnCtx (TCLocal shortIdent) td kont
    TypeAliasDefn fld alias -> do
      let shortIdent = U.s2n fld
      extendTypeAliasCtx (TCLocal shortIdent) alias kont
    ImportDecl {} ->
      error ("internal error: extendDCtxSingle did not expect an ImportDecl.")
    SubmoduleDefn fld moduleExpr -> do
      let shortIdent = U.s2n fld
      subSigNF <- naturalSignatureModuleExpr moduleExpr
      extendModuleCtxNF (IdP shortIdent) subSigNF kont
    SampleModuleDefn fld moduleExpr -> do
      let shortIdent = U.s2n fld
      subSigNF <- naturalSignatureModuleExpr moduleExpr
      case subSigNF of
       (SigMTNF (SigV subSig ModelMK)) ->
         -- sample a model, get a module
         let subModSigNF = SigMTNF (SigV subSig ModuleMK)
         in extendModuleCtxNF (IdP shortIdent) subModSigNF kont
       (SigMTNF (SigV _subSig ModuleMK)) ->
         typeError ("expected a model on RHS of module sampling, but got a module, when defining "
                    <> formatErr shortIdent
                    <> " in " <> formatErr pmod)
       (FunMTNF {}) ->
         typeError ("expected a model on RHS of module sampling, but got a functor, when defining "
                    <> formatErr shortIdent
                    <> " in " <> formatErr pmod)

extendValueDeclCtx :: Path -> Field -> ValueDecl -> TC a -> TC a
extendValueDeclCtx _pmod fld vd kont =
  let v = U.s2n fld :: Var
  in case vd of
    SigDecl _stoch t -> extendSigDeclCtx v t kont
    FunDecl _e -> extendValueDefinitionCtx v kont
    ValDecl _e -> extendValueDefinitionCtx v kont
    SampleDecl _e -> extendValueDefinitionCtx v kont
    ParameterDecl _e -> extendValueDefinitionCtx v kont
    TabulatedSampleDecl _tf -> extendValueDefinitionCtx v kont

-- | @extendSigDecl fld qvar ty decls checkRest@ adds the global
-- binding of @qvar@ to type @ty@, and replaces any free appearances
-- of @fld@ by @qvar@ in @decls@ before checking them using
-- @checkRest@.
extendSigDeclCtx :: Var
                    -> Type
                    -> TC a
                    -> TC a
extendSigDeclCtx v t kont =
  local (envLocals . at v ?~ t)
  . U.avoid [U.AnyName v]
  $ kont
