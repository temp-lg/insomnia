{-# LANGUAGE ViewPatterns,
      FlexibleContexts, FlexibleInstances, TypeSynonymInstances
  #-}
module Insomnia.ToF.Module where

import Control.Applicative ((<$>))
import Control.Lens
import Control.Monad.Reader
import Control.Monad.Except (MonadError(..))
import Data.Monoid (Monoid(..), (<>), Endo(..))
import qualified Data.Map as M

import qualified Unbound.Generics.LocallyNameless as U

import qualified FOmega.Syntax as F
import qualified FOmega.SemanticSig as F
import qualified FOmega.MatchSigs as F
import qualified FOmega.SubSig as F

import Insomnia.Common.ModuleKind
import Insomnia.Common.Telescope
import Insomnia.Identifier
import Insomnia.Types
import Insomnia.TypeDefn
import Insomnia.ValueConstructor
import Insomnia.ModuleType
import Insomnia.Module
import Insomnia.Expr

import Insomnia.ToF.Env
import Insomnia.ToF.Summary
import Insomnia.ToF.Type
import Insomnia.ToF.Expr
import Insomnia.ToF.ModuleType
import Insomnia.ToF.Builtins

---------------------------------------- Modules

-- The translation of moduleExpr takes a 'Maybe Path' which is the name
-- of the module provided that it is defined at the toplevel, or else a simple structure
--  within another named module.   This is a (gross) hack so that we can write things like
--
-- @@@
--   module Foo {
--     module Bar = assume { sig x : ... }
--  }
-- @@@
--
-- And try to find "Foo.Bar.x" in the list of known builtin primitives.
--
moduleExpr :: ToF m => Maybe Path -> ModuleExpr -> m (F.AbstractSig, F.Term)
moduleExpr modPath mdl_ =
  case mdl_ of
   ModuleStruct mk mdl -> do
     ans@(sigStr, m) <- structure modPath mk mdl
     case mk of
       ModuleMK -> return ans
       ModelMK -> let sig = F.ModelSem sigStr
                      s = F.AbstractSig $ U.bind [] sig
                  in return (s, m)
   ModuleSeal me mt -> sealing me mt
   ModuleAssume mty -> moduleAssume modPath mty
   ModuleId p -> do
     (sig, m) <- modulePath p
     return (F.AbstractSig $ U.bind [] sig, m)
   ModuleFun bnd ->
     U.lunbind bnd $ \(tele, bodyMe) ->
     moduleFunctor tele bodyMe
   ModuleApp pfun pargs -> moduleApp pfun pargs
   ModelLocal lcl bdy mt ->
     modelLocal lcl bdy mt
   ModelObserve mdl obss ->
     modelObserve mdl obss
   ModuleUnpack e modTy ->
     moduleUnpack e modTy

moduleAssume :: ToF m
                => Maybe Path
                -> ModuleType
                -> m (F.AbstractSig, F.Term)
moduleAssume modPath_ modTy = do
  case looksLikeBuiltin modPath_ modTy of
   Just builtins -> makeBuiltinsModule builtins
   Nothing -> do
     absSig <- moduleType modTy
     ty <- F.embedAbstractSig absSig
     return (absSig, F.Assume ty)

structure :: ToF m
             => Maybe Path
             -> ModuleKind
             -> Module
             -> m (F.AbstractSig, F.Term)
structure modPath mk (Module decls) = do
  declarations modPath mk decls $ \(summary@(tvks,sig), fields, termHole) -> do
    let semSig = F.ModSem sig
    ty <- F.embedSemanticSig semSig
    let r = F.Record fields
        m = retMK mk $ F.packs (map (F.TV . fst) tvks) r (tvks, ty)
    return (mkAbstractModuleSig summary, appEndo termHole m)
  where
    retMK :: ModuleKind -> F.Term -> F.Term
    retMK ModuleMK = id
    retMK ModelMK = F.Return
    
-- | 〚let { decls } in M : S〛 Unlike the F-ing modules calculus
-- where "let B in M" is explained as "{ B ; X = M}.X", because we're
-- in a monadic language in the model fragment, this is a primitive
-- construct.  Suppose 〚 {decls} 〛 = e₁ : Dist ∃αs.Σ₁  and 〚S〛= ∃βs.Σ₂
-- and 〚Γ,αs,X:Σ₁⊢ M[X.ℓs/ℓs]〛= e₂ : Dist ∃γs.Σ₃ then
-- the local module translates as:
--
--   let Y ~ e₁ in unpack αs,X = Y in
--   let Z ~ e₂ in unpack γs,W = Z in
--   return (pack τs (f W) as ∃βs.Σ₂)
--
-- where αs,γs⊢ Σ₃ ≤ ∃βs.Σ₂ ↑ τs ⇝ f is the signature sealing coercion;
-- all the locals are fresh; and the [X.ℓs/ℓs] means to put in
-- projections from X for all the declarations in decls that appear in
-- e₂
--
-- The big picture is: we have two "monads", the distribution monad
-- and the existential packing "monad", so we use the elim forms to
-- take them both apart, and then return/pack the resulting modules.
modelLocal :: ToF m => Module -> ModuleExpr -> ModuleType -> m (F.AbstractSig, F.Term)
modelLocal lcl_ body_ mt_ = do
  ascribedSig <- moduleType mt_
  let (Module lclDecls) = lcl_
  declarations Nothing ModelMK lclDecls $ \(_lclSummary, _lclFields, lclTermHole) -> do
    (F.AbstractSig bodySigBnd, bodyTerm) <- moduleExpr Nothing body_
    U.lunbind bodySigBnd $ \(gammas,bodySig) -> do
      (taus, coer) <- do
        (sig2, taus) <- F.matchSubst bodySig ascribedSig
        coercion <- F.sigSubtyping bodySig sig2
        return (taus, coercion)
      z <- U.lfresh (U.string2Name "z")
      w <- U.lfresh (U.string2Name "w")
      packsAnnotation <- do
        let (F.AbstractSig bnd) = ascribedSig
        U.lunbind bnd $ \ (betas, s) -> do
          ty <- F.embedSemanticSig s
          return (betas, ty)
      let
        finalOut = F.packs taus (F.applyCoercion coer (F.V w)) packsAnnotation
      unpackedGammas <- F.unpacks (map fst gammas) w (F.V z) $ finalOut
      let
        withE2 = F.Let $ U.bind (z, U.embed bodyTerm) unpackedGammas
        localTerm = appEndo lclTermHole withE2
      return (ascribedSig, localTerm)

-- | In the F-ing modules paper, (M:>S) is syntactic sugar, and only
-- (X :> S) is primitive.  But if we expand out the sugar and apply
-- some commuting conversions, we get something in nice form and we
-- choose to implement that nice form.
--
--    
--  〚(M :> S)〛 = 〚({ X = M ; X' = (X :> S) }.X')〛
--    = unpack (αs, y) = 〚{ X = M ; X' = (X :> S)}〛in pack (αs, y.lX')
--    = unpack (αs, y) = (unpack (βs, z1) = 〚M〛in unpack (γs, z2) = 〚(X :> S)〛[z1 / X] in pack (βs++γs, { lX = z1 ; lX' = z2 })) in pack (αs, y.lX')
--    = unpack (βs, z1) = 〚M〛in unpack (γs, z2) = 〚(X :> S)〛[z1/X] in unpack (αs,y) = pack (βs++γs, { lX = X ; lX' = z2 }) in pack (αs, y.lX')
--    = unpack (βs, z1) = 〚M〛 in unpack (γs, z2) = 〚(X :> S)〛[z1/X] in pack (βs++γs, z2)
--    = unpack (βs, z1) = 〚M〛 in unpack (γs, z2) = pack (τs, f z1) in pack (βs++γs, z2) where Σ₁ ≤ Ξ ↑ τs ⇝ f where Σ₁ is the type of z1 and Ξ is 〚S〛
--    = unpack (βs, z1) = 〚M〛 in pack (βs++τs, f z1)
--
-- In other words, elaborate M and S and construct the coercion f and
-- discover the sealed types τs, then pack anything that M abstracted
-- together with anything that S seals.  (The one missing bit is the
-- type annotation on the "pack" term, but it's easy.  Suppose Ξ is
-- ∃δs.Σ₂, then the result has type ∃βs,δs.Σ₂)
sealing :: ToF m => ModuleExpr -> ModuleType -> m (F.AbstractSig, F.Term)
sealing me mt = do
  xi@(F.AbstractSig xiBnd) <- moduleType mt
  (F.AbstractSig sigBnd, m) <- moduleExpr Nothing me
  U.lunbind sigBnd $ \(betas, sigma) -> do
    (taus, coer) <- do
      (sig2, taus) <- F.matchSubst sigma xi
      coercion <- F.sigSubtyping sigma sig2
      return (taus, coercion)
    z1 <- U.lfresh (U.s2n "z")
    let
      packedTys = (map (F.TV . fst) betas)
                  ++ taus
    (xi', bdy) <- U.lunbind xiBnd $ \(deltas,sigma2) -> do
      sigma2emb <- F.embedSemanticSig sigma2
      let bdy = F.packs packedTys (F.applyCoercion coer $ F.V z1) (betas++deltas, sigma2emb)
          xi' = F.AbstractSig $ U.bind (betas++deltas) sigma2
      return (xi', bdy)
    term <- F.unpacks (map fst betas) z1 m bdy
    return (xi', term)

-- | (X1 : S1, ... Xn : Sn) -> { ... Xs ... }
-- translates to    Λα1s,...αns.λX1:Σ1,...,Xn:Σn. mbody : ∀αs.Σ1→⋯Σn→Ξ
-- where 〚Si〛= ∃αi.Σi and 〚{... Xs ... }〛= mbody : Ξ
moduleFunctor :: ToF m
                 => (Telescope (FunctorArgument ModuleType))
                 -> ModuleExpr
                 -> m (F.AbstractSig, F.Term)
moduleFunctor teleArgs bodyMe =
  withFunctorArguments teleArgs $ \(tvks, argSigs) -> do
    (resultAbs, mbody) <- moduleExpr Nothing bodyMe
    let funSig = F.SemanticFunctor (map snd argSigs) resultAbs
        s = F.FunctorSem $ U.bind tvks funSig
    args <- forM argSigs $ \(v,argSig) -> do
      argTy <- F.embedSemanticSig argSig
      return (v, argTy)
    let fnc = F.pLams' tvks $ F.lams args mbody
    return (F.AbstractSig $ U.bind [] s,
            fnc)

-- | p (p1, .... pn) becomes  m [τ1s,…,τNs] (f1 m1) ⋯ (fn mn) : Ξ[τs/αs]
-- where 〚p〛 = m : ∀αs.Σ1′→⋯→Σn′→Ξ and 〚pi〛 = mi : Σi  and (Σ1,…,Σn)≤∃αs.(Σ1′,…,Σn′) ↑ τs ⇝ fs
moduleApp :: ToF m
             => Path
             -> [Path]
             -> m (F.AbstractSig, F.Term)
moduleApp pfn pargs = do
  (semFn, mfn) <- modulePath pfn
  (argSigs, margs) <- mapAndUnzipM modulePath pargs
  case semFn of
   F.FunctorSem bnd ->
     U.lunbind bnd $ \(tvks, F.SemanticFunctor paramSigs sigResult) -> do
       let alphas = map fst tvks
       (paramSigs', taus) <- F.matchSubsts argSigs (alphas, paramSigs)
       coercions <- zipWithM F.sigSubtyping argSigs paramSigs'
       let
         m = (F.pApps mfn taus) `F.apps` (zipWith F.applyCoercion coercions margs)
         s = U.substs (zip alphas taus) sigResult
       return (s, m)
   _ -> throwError "internal failure: ToF.moduleApp expected a functor"

modelObserve :: ToF m
                => ModuleExpr
                -> [ObservationClause]
                -> m (F.AbstractSig, F.Term)
modelObserve me obss = do
  -- 〚M' = observe M where f is Q〛
  --
  --  Suppose 〚M〛: Dist {fs : τs} where f : {gs : σs}
  --     and  〚Q〛: {gs : σs}
  -- 
  --  let
  --    prior = 〚M〛
  --    obs = 〚Q〛
  --    kernel = λ x : {fs : τs} . x.f
  --  in posterior [{fs:τs}] [{gs:σs}] kernel obs prior
  -- 
  (sig, prior) <- moduleExpr Nothing me
  disttp <- F.embedAbstractSig sig
  sigTps <- case disttp of
    F.TExist {} -> throwError "internal error: ToF.modelObserve of an observed model with abstract types"
    F.TDist (F.TRecord sigTps) -> return sigTps
    _ -> throwError "internal error: ToF.modelObserve expected to see a distribution over models"
  hole <- observationClauses sigTps obss
  let posterior = hole prior
  return (sig, posterior)
    
observationClauses :: ToF m
                      => [(F.Field, F.Type)]
                      -> [ObservationClause]
                      -> m (F.Term -> F.Term)
observationClauses _sig [] = return id
observationClauses sigTp (obs:obss) = do
  holeInner <- observationClause sigTp obs
  holeOuter <- observationClauses sigTp obss
  return (holeOuter . holeInner)

-- | observationClause {fs : τs} "where f is Q" ≙ λprior . posterior kernel mobs prior
-- where kernel = "λx:{fs:τs} . x.f"
--   and mobs = 〚Q〛
observationClause :: ToF m
                     => [(F.Field, F.Type)]
                     -> ObservationClause
                     -> m (F.Term -> F.Term)
observationClause sigTp (ObservationClause f obsMe) = do
  (_, mobs) <- moduleExpr Nothing obsMe
  let recordTp = F.TRecord sigTp
  projTp <- case F.selectField sigTp (F.FUser f) of
    Just (F.TDist t) -> return t
    Just _ -> throwError ("internal error: expected the model to have a submodel " ++ show f
                          ++ ", but it's not even a distribution")
    Nothing -> throwError ("internal error: expected model to have a submodel " ++ show f)
  let
    kernel = let
      vx = U.s2n "x"
      x = F.V vx
      in F.Lam $ U.bind (vx, U.embed recordTp) $
         F.Proj x (F.FUser f)
    term = \prior ->
      F.apps (F.pApps (F.V $ U.s2n "__BOOT.posterior")
              [ recordTp , projTp ])
      [ kernel
      , mobs
      , prior
      ]
  return term

moduleUnpack :: ToF m => Expr -> ModuleType -> m (F.AbstractSig, F.Term)
moduleUnpack e modTy = do
  m <- expr e
  absSig <- moduleType modTy
  return (absSig, m)


-- | Translation declarations.
-- This is a bit different from how F-ing modules does it in order to avoid producing quite so many
-- administrative redices, at the expense of being slightly more complex.
--
-- So the idea is that each declaration is going to produce two
-- things: A term with a hole and a description of the extra variable
-- bindings that it introduces in the scope of the hole.
--
-- For example, a type alias "type β = τ" will produce the term
--    let xβ = ↓[τ] in •   and the description {user field β : [τ]} ⇝ {user field β = xβ}
-- The idea is that the "SigSummary" part of the description is the abstract semantic signature of the
-- final structure in which this declaration appears, and the field↦term part is the record value that
-- will be produced.
--
-- For nested submodules we'll have to do a bit more work in order to
-- extrude the scope of the existential variables (ie, the term with
-- the hole is an "unpacks" instead of a "let"), but it's the same
-- idea.
--
-- For value bindings we go in two steps: the signature (which was inserted by the type checker if omitted)
-- just extends the SigSummary, while the actual definition extends the record.
-- TODO: (This gets mutually recursive functions wrong.  Need a letrec form in fomega)
declarations :: ToF m
                => Maybe Path
                -> ModuleKind
                -> [Decl]
                -> (ModSummary -> m ans)
                -> m ans
declarations _ _mk [] kont = kont mempty 
declarations modPath mk (d:ds) kont = let
  kont1 out1 = declarations modPath mk ds $ \outs -> kont $ out1 <> outs
  in case d of
      ValueDecl f vd -> valueDecl mk f vd kont1
      SubmoduleDefn f me -> submoduleDefn modPath mk f me kont1
      SampleModuleDefn f me -> do
        when (mk /= ModelMK) $
          throwError "internal error: ToF.declarations SampleModuleDecl in a module"
        sampleModuleDefn f me kont1
      TypeAliasDefn f al -> typeAliasDefn mk f al kont1
      ImportDecl {} ->
        throwError "internal error: ToF.declarations ImportDecl should have been desugared by the Insomnia typechecker"
        {- importDecl p kont1 -}
      TypeDefn f td -> typeDefn f (U.s2n f) td kont1

typeAliasDefn :: ToF m
                 => ModuleKind
                 -> Field
                 -> TypeAlias
                 -> (ModSummary -> m ans)
                 -> m ans
typeAliasDefn _mk f (ManifestTypeAlias bnd) kont =
  U.lunbind bnd $ \ (tvks, rhs) -> do
    (tlam, tK) <- withTyVars tvks $ \tvks' -> do
      (rhs', kcod) <- type' rhs
      return (F.tLams tvks' rhs', F.kArrs (map snd tvks') kcod)
    let tsig = F.TypeSem tlam tK
        tc = U.s2n f :: TyConName
        xc = U.s2n f :: F.Var
    mr <- F.typeSemTerm tlam tK
    let
      mhole = Endo $ F.Let . U.bind (xc, U.embed mr)
      thisOne = ((mempty, [(F.FUser f, tsig)]),
                 [(F.FUser f, F.V xc)],
                 mhole)
    local (tyConEnv %~ M.insert tc tsig) $
      kont thisOne
typeAliasDefn _mk f (DataCopyTypeAlias (TypePath pdefn fdefn) defn) kont = do
  -- Add a new name for an existing generative type.  Since the
  -- abstract type variable is already in scope (since it was lifted
  -- out to scope over all the modules where the type is visible), we
  -- just need to alias the original type's datatype variable, and to
  -- add all the constructors to the environment.
  --
  --  ie, suppose we had:
  --    module M { data D = D1 | D2 }
  --    module N { datatype D = data M.D }
  --    module P { ... N.D1 ... }
  --  we will get
  --   unpack δ, M = { ... } in
  --   let N = { D = M.D } in
  --   let P = { ... N.D.dataIn.D1  ... }   where N.D has a type that mentions δ
  let rootLookup modId = do
        ma <- view (modEnv . at modId)
        case ma of
         Nothing -> throwError "unexpected failure in ToF.typeAliasDefn - unbound module identifier"
         Just (sig, x) -> return (sig, F.V x)
  (dataSig, mpath) <- followUserPathAnything rootLookup (ProjP pdefn fdefn)
  let tc = U.s2n f :: TyConName
      xc = U.s2n f :: F.Var
  -- map each constructor to a projection from the the corresponding
  -- constructor field of the defining datatype.
  conVs <- case defn of
   EnumDefn {} -> return mempty
   DataDefn bnd ->
     U.lunbind bnd $ \(_tvks, cdefs) ->
       return $ flip map cdefs $ \(ConstructorDef cname _) ->
         let fcon = F.FCon (U.name2String cname)
         in  (cname, (xc, fcon))
  let mhole = Endo (F.Let . U.bind (xc, U.embed mpath))
      thisOne = ((mempty, [(F.FUser f, dataSig)]), [(F.FUser f, F.V xc)], mhole)
      conEnv = M.fromList conVs
  local (tyConEnv %~ M.insert tc dataSig)
    $ local (valConEnv %~ M.union conEnv)
    $ kont thisOne

submoduleDefn :: ToF m
                 => Maybe Path
                 -> ModuleKind
                 -> Field
                 -> ModuleExpr
                 -> ((SigSummary, [(F.Field, F.Term)], Endo F.Term) -> m ans)
                 -> m ans
submoduleDefn modPath _mk f me kont = do
  let modId = U.s2n f
  (F.AbstractSig bnd, msub) <- moduleExpr (flip ProjP f <$> modPath) me
  U.lunbind bnd $ \(tvks, modsig) -> do
    xv <- U.lfresh (U.s2n f)
    U.avoid [U.AnyName xv] $ local (modEnv %~ M.insert modId (modsig, xv)) $ do
      let tvs = map fst tvks
      (munp, avd) <- F.unpacksM tvs xv
      let m = Endo $ munp msub
          thisOne = ((tvks, [(F.FUser f, modsig)]),
                     [(F.FUser f, F.V xv)],
                     m)
      U.avoid avd $ kont thisOne

sampleModuleDefn :: ToF m
                    => Field
                    -> ModuleExpr
                    -> (ModSummary -> m ans)
                    -> m ans
sampleModuleDefn f me kont = do
  let modId = U.s2n f
  (F.AbstractSig bndMdl, msub) <- moduleExpr Nothing me
  bnd <- U.lunbind bndMdl $ \(tvNull, semMdl) ->
    case (tvNull, semMdl) of
     ([], F.ModelSem (F.AbstractSig bnd)) -> return bnd
     _ -> throwError "internal error: ToF.sampleModelDefn expected a model with no applicative tyvars"
  U.lunbind bnd $ \(tvks, modSig) -> do
    let xv = U.s2n f
    local (modEnv %~ M.insert modId (modSig, xv)) $ do
      (munp, avd) <- F.unpacksM (map fst tvks) xv
      let m = Endo $ F.LetSample . U.bind (xv, U.embed msub) . munp (F.V xv)
          thisOne = ((tvks, [(F.FUser f, modSig)]),
                     [(F.FUser f, F.V xv)],
                     m)
      U.avoid avd $ kont thisOne

valueDecl :: ToF m
             => ModuleKind
             -> Field
             -> ValueDecl
             -> (ModSummary -> m ans)
             -> m ans
valueDecl mk f vd kont =
  let v = U.s2n f :: Var
  in case vd of
   SigDecl _stoch ty -> do
     (ty', _k) <- type' ty
     let vsig = F.ValSem ty'
         xv = U.s2n f :: F.Var
     let thisOne = ((mempty, [(F.FUser f, vsig)]),
                    mempty,
                    mempty)
     local (valEnv %~ M.insert v (xv, StructureTermVar vsig))
       $ U.avoid [U.AnyName v]
       $ kont thisOne
   FunDecl (Function eg) -> do
     g <- case eg of
       Left {} -> throwError "internal error: expected annotated function"
       Right g -> return g
     mt <- view (valEnv . at v)
     (xv, semTy, _ty) <- case mt of
       Just (xv, StructureTermVar sem) -> do
         semTy <- F.embedSemanticSig sem
         ty <- matchSemValRecord sem
         return (xv, semTy, ty)
       _ -> throwError "internal error: ToF.valueDecl FunDecl did not find type declaration for field"
     m <- -- tyVarsAbstract ty $ \_tvks _ty' ->
       generalize g $ \tvks _prenex e -> do
       m_ <- expr e
       return $ F.pLams tvks m_
     let
       mr = F.valSemTerm m
       mhole = Endo $ F.LetRec . U.bind (U.rec [(xv, U.embed semTy, U.embed mr)])
       thisOne = (mempty,
                  [(F.FUser f, F.V xv)],
                  mhole)
     kont thisOne
   SampleDecl e -> do
     when (mk /= ModelMK) $
       throwError "internal error: ToF.valueDecl SampleDecl in a module"
     simpleValueBinding F.LetSample f v e kont
   ParameterDecl e -> do
     when (mk /= ModuleMK) $
       throwError "internal error: ToF.valueDecl ParameterDecl in a model"
     simpleValueBinding F.Let f v e kont
   ValDecl {} -> throwError ("internal error: unexpected ValDecl in ToF.valueDecl;"
                      ++" Insomnia typechecker should have converted into a SampleDecl or a ParameterDecl")
   TabulatedSampleDecl tabfun -> do
     when (mk /= ModelMK) $
       throwError "internal error: ToF.valueDecl TabulatedSampleDecl in a module"
     tabledSampleDecl f v tabfun kont
   
simpleValueBinding :: ToF m
                      => (U.Bind (F.Var, U.Embed F.Term) F.Term -> F.Term)
                      -> Field
                      -> Var
                      -> Expr
                      -> (ModSummary -> m ans)
                      -> m ans
simpleValueBinding mkValueBinding f v e kont = do
  mt <- view (valEnv . at v)
  (xv, _prov) <- case mt of
    Nothing -> throwError "internal error: ToF.valueDecl SampleDecl did not find and type declaration for field"
    Just xty -> return xty
  m <- expr e
  let
    mhole body =
      mkValueBinding $ U.bind (xv, U.embed m)
      $ F.Let $ U.bind (xv, U.embed $ F.valSemTerm $ F.V xv)
      $ body
    thisOne = (mempty,
               [(F.FUser f, F.V xv)],
               Endo mhole)
  kont thisOne

tabledSampleDecl :: ToF m
                    => Field
                    -> Var
                    -> TabulatedFun
                    -> (ModSummary -> m ans)
                    -> m ans
tabledSampleDecl f v tf kont = do
  (v', mhole) <- letTabFun v tf (\v' mhole -> return (v', mhole))
  let
    mval = F.Let . U.bind (v', U.embed $ F.valSemTerm $ F.V v')
    thisOne = (mempty,
               [(F.FUser f, F.V v')],
               Endo mhole <> Endo mval)
  kont thisOne



generalize :: (U.Alpha a, ToF m) =>
              Generalization a -> ([(F.TyVar, F.Kind)] -> PrenexCoercion -> a -> m r) -> m r
generalize (Generalization bnd prenexCoercion) kont =
  U.lunbind bnd $ \(tvks, body) ->
  withTyVars tvks $ \tvks' ->
  kont tvks' prenexCoercion body

matchSemValRecord :: MonadError String m => F.SemanticSig -> m F.Type
matchSemValRecord (F.ValSem t) = return t
matchSemValRecord _ = throwError "internal error: expected a semantic object of a value binding"

tyVarsAbstract :: ToF m => F.Type -> ([(F.TyVar, F.Kind)] -> F.Type -> m r) -> m r
tyVarsAbstract t_ kont_ = tyVarsAbstract' t_ (\tvks -> kont_ (appEndo tvks []))
  where
    tyVarsAbstract' :: ToF m => F.Type -> (Endo [(F.TyVar, F.Kind)] -> F.Type -> m r) -> m r
    tyVarsAbstract' t kont =
      case t of
       F.TForall bnd ->
         U.lunbind bnd $ \((tv', U.unembed -> k), t') -> do
           let tv = (U.s2n $ U.name2String tv') :: TyVar
           id {- U.avoid [U.AnyName tv] -}
             $ local (tyVarEnv %~ M.insert tv (tv', k))
             $ tyVarsAbstract' t' $ \tvks t'' ->
             kont (Endo ((tv', k):) <> tvks) t''
       _ -> kont mempty t
             

modulePath :: ToF m => Path
              -> m (F.SemanticSig, F.Term)
modulePath = let
  rootLookup modId = do
    ma <- view (modEnv . at modId)
    case ma of
     Nothing -> throwError "unexpected failure in ToF.modulePath - unbound module identifier"
     Just (sig, x) -> return (sig, F.V x)
  in
   followUserPathAnything rootLookup



