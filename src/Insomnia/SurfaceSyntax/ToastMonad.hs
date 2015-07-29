-- | The "to AST" monad.
--
{-# LANGUAGE RankNTypes,
      MultiParamTypeClasses,
      FlexibleContexts,
      ScopedTypeVariables,
      TemplateHaskell
  #-}
module Insomnia.SurfaceSyntax.ToastMonad (
  -- * Translation Context
  Ctx(..)
  , declaredFixity
  , currentModuleKind
  , toastPositioned
  , toastPositionedC
  , toastNear
    -- * Structure/Signature Name resolution
  , bigIdentSort
  , BigIdentSort(..)
  , addModuleVar
  , addModuleVarC
  , addSignatureVar
  , addSignatureVarC
  , lookupBigIdent
    -- * Translation monads
  , TA
  , YTA
  , CTA (..)
  , ToastError
  , throwToastError
  , throwToastErrorC
    -- * Suspended computation state
  , Suspended
  , ImportFileError (..)
  , feedTA
  , await
  , freshTopRef
  , withTopRefFor_
  , withTopRefForC_
  , tellToplevel
  , listenToplevels
    -- * Monad stacks
  , liftCTA
  , runToAST
  , scopeCTA
  , module Control.Monad.Reader.Class
  ) where

import Control.Applicative
import Control.Lens
import Control.Monad.Error.Class
import Control.Monad.Except
import Control.Monad.Reader.Class
import Control.Monad.Reader
import Control.Monad.State.Class
import Control.Monad.State

import qualified Data.Map as M
import Data.Monoid

import qualified Unbound.Generics.LocallyNameless as U

import Insomnia.Common.ModuleKind

import qualified Insomnia.Identifier as I
import qualified Insomnia.Toplevel as I

import Insomnia.SurfaceSyntax.Syntax
import Insomnia.SurfaceSyntax.SourcePos
import Insomnia.SurfaceSyntax.FixityParser

-- | A "BigIdentSort" classifies "big" idents as to whether they stand
-- for signatures or structures.
data BigIdentSort =
  SignatureBIS I.SigIdentifier
  | StructureBIS I.Identifier
    deriving (Show)

data Ctx = Ctx {_declaredFixity :: M.Map QualifiedIdent Fixity
               , _currentModuleKind :: ModuleKind
               , _bigIdentSort :: M.Map Ident BigIdentSort
               , _currentNearbyPosition :: First SourcePos
               }
         deriving (Show)

$(makeLenses ''Ctx)

data ToastState =
  ToastState { _toprefMapSt :: M.Map FilePath I.TopRef
             , _toprefAccumSt :: Endo [(FilePath, I.TopRef, I.Toplevel)]
             }

$(makeLenses ''ToastState)

instance Monoid ToastState where
  mempty = ToastState mempty mempty
  (ToastState a b) `mappend` (ToastState a' b') = ToastState (a <> a') (b <> b')

-- "To AST" monad is just a reader of some contextual info...
-- (the freshness monad is used to make new Toprefs)
type TA = ReaderT Ctx (StateT ToastState (U.FreshMT YTA))

data ToastError =
  ToastErrorMsg !String !(First SourcePos)

instance Show (ToastError) where
  showsPrec p (ToastErrorMsg msg (First Nothing)) = showsPrec p msg
  showsPrec _ (ToastErrorMsg msg (First (Just posn))) =
    showsPrec 0 posn . showString ": " . showsPrec 0 msg

-- ... except that we can yield mid-computation and ask for an imported file.
--
-- this is a coroutine monad.
data YTA a = 
  DoneTA a
  | FailTA ToastError
  | YieldTA Suspended ImportFileSpec (Either ImportFileError Toplevel -> TA a)

type Suspended = (Ctx, ToastState, Integer)

newtype ImportFileError = ImportFileError { importFileErrorMsg :: String }

instance Functor YTA where
  fmap f (DoneTA x) = DoneTA (f x)
  fmap _ (FailTA e) = FailTA e
  fmap f (YieldTA susp want k) = YieldTA susp want (fmap f . k)

instance Applicative YTA where
  pure = DoneTA 
  (DoneTA f) <*> (DoneTA x) = DoneTA (f x)
  (DoneTA _) <*> (FailTA e) = FailTA e
  (DoneTA f) <*> (YieldTA susp want k) = YieldTA susp want (fmap f . k)
  (FailTA e) <*> _ = FailTA e
  (YieldTA susp want f) <*> m = YieldTA susp want (\i -> f i <*> (lift . lift . lift ) m)

instance Monad YTA where
   return = pure
   fail msg = FailTA (ToastErrorMsg msg mempty)
   DoneTA x >>= k = k x
   FailTA e >>= _ = FailTA e
   YieldTA susp want k >>= k' = YieldTA susp want (\i -> k i >>= (lift . lift . lift . k'))

instance MonadError ToastError YTA where
  throwError = FailTA
  comp `catchError` handler =
    case comp of
    FailTA err -> handler err
    DoneTA ans -> return ans
    YieldTA susp want k -> YieldTA susp want $ \ans -> do
      lOrR <- (Right <$> k ans) `catchError` (return . Left)
      case lOrR of
        Right ans -> return ans
        Left e -> lift . lift . lift $ handler e

-- the CPS version of TA
newtype CTA a = CTA { runCTA :: forall r . (a -> TA r) -> TA r }

instance Monad CTA where
  return x = CTA $ \k -> k x
  m >>= f = CTA $ \k -> runCTA m $ \x -> runCTA (f x) k

instance Applicative CTA where
  pure = return
  mf <*> mx = CTA $ \k -> runCTA mf $ \f -> runCTA mx $ \x -> k (f x)

instance Functor CTA where
  fmap f mx = CTA $ \k -> runCTA mx $ \x -> k (f x)

-- in the CPS version of TA, the Ctx is a state that persists
-- within the continuation.
instance MonadState Ctx CTA where
  state xform = CTA $ \k -> do
    ctx <- ask
    let (x, ctx') = xform ctx
    local (const ctx') $ k x

instance MonadError ToastError CTA where
  throwError e = CTA $ \_k -> throwError e
  catchError comp handler = CTA $ \k -> do
    lOrR <- runCTA comp (return . Right) `catchError` (return . Left)
    case lOrR of
      Left err -> runCTA (handler err) k
      Right ans -> k ans

-- | given a To AST computation and a monadic handler for import requests and an initial context,
-- repeatedly call the handler whenever the To AST computation yields with a request until it returns a final answer.
-- Return that final answer.
feedTA :: forall m a .
          Monad m
          => TA a
          -> (ToastError -> m a)
          -> (ImportFileSpec -> m (Either ImportFileError Toplevel))
          -> Ctx -> m a
feedTA comp onError onImport =
  let
    go :: Suspended -> TA a -> m a
    go (ctx, st, freshness) c =
      case U.contFreshMT (evalStateT (runReaderT c ctx) st) freshness of
       DoneTA ans -> return ans
       FailTA err -> onError err
       YieldTA susp' wanted resume -> do
         reply <- onImport wanted
         go susp' (resume reply)
  in \ctx -> go (ctx, mempty, 0) comp

await :: ImportFileSpec -> TA Toplevel
await want = do
  ctx <- ask
  st <- lift get
  freshness <- lift $ lift (U.FreshMT get)
  lift $ lift $ lift
               $ (YieldTA (ctx,st, freshness) want $ \got ->
                    case got of
                    Left err -> fail (importFileErrorMsg err)
                    Right it -> return it)

tellToplevel :: FilePath -> I.TopRef -> I.Toplevel -> TA ()
tellToplevel fp tr tl =
  let e = Endo $ \l -> (fp, tr, tl) : l
  in lift (toprefAccumSt <>= e)

listenToplevels :: TA a -> TA (a, [I.ToplevelItem])
listenToplevels comp = do
  a <- comp
  e <- use toprefAccumSt
  let its = map (\(fp,tr,tl) -> I.ToplevelImported fp tr tl) $ appEndo e []
  return (a, its)

-- | If the given 'FilePath' has a 'I.TopRef' associated with it,
-- just return it.  Otherwise, run the given computation passing it a
-- fresh 'I.TopRef', and then return the result
withTopRefFor_ :: FilePath -> (I.TopRef -> TA ()) -> TA I.TopRef
withTopRefFor_ fp compNew = do
  mref <- use (toprefMapSt . at fp)
  case mref of
   Nothing -> do
     a <- freshTopRef fp
     toprefMapSt . at fp ?= a
     compNew a
     return a
   Just a -> return a

withTopRefForC_ :: FilePath -> (I.TopRef -> CTA ()) -> CTA I.TopRef
withTopRefForC_ fp compNew =
  CTA $ \k -> do
    r <- withTopRefFor_ fp $ \r ->
      runCTA (compNew r) return
    k r

freshTopRef :: FilePath -> TA I.TopRef
freshTopRef fp = U.fresh (U.s2n $ "^" ++ fp)

liftCTA :: TA a -> CTA a
liftCTA comp = CTA $ \k -> comp >>= k

runToAST :: Ctx -> TA a -> YTA a
runToAST ctx comp = U.runFreshMT (evalStateT (runReaderT comp ctx) mempty)

-- | Run the given CTA subcomputation, but restrict all changes to the 'Ctx' to
-- the extent of the given subcomputation.
scopeCTA :: CTA a -> CTA a
scopeCTA comp = liftCTA (runCTA comp return)

addModuleVarC :: Ident -> I.Identifier -> CTA ()
addModuleVarC ident x =
  CTA $ \k -> addModuleVar ident x (k ())

addModuleVar :: Ident -> I.Identifier -> TA a -> TA a
addModuleVar ident x =
  insertBigIdent ident (StructureBIS x)

insertBigIdent :: Ident -> BigIdentSort -> TA a -> TA a
insertBigIdent ident sort =
  local (bigIdentSort %~ M.insert ident sort)

addSignatureVar :: Ident -> I.SigIdentifier -> TA a -> TA a
addSignatureVar ident x =
  insertBigIdent ident (SignatureBIS x)

addSignatureVarC :: Ident -> I.SigIdentifier -> CTA ()
addSignatureVarC ident x =
  CTA $ \k -> addSignatureVar ident x (k ())

lookupBigIdent :: Ident -> TA (Maybe BigIdentSort)
lookupBigIdent ident = view (bigIdentSort . at ident)

toastPositioned :: (a -> TA b) -> Positioned a -> TA b
toastPositioned f p =
  local (currentNearbyPosition .~ (First $ Just $ view positionedSourcePos p)) $ f (view positioned p)

toastPositionedC :: (a -> CTA b) -> Positioned a -> CTA b
toastPositionedC f p = do
  oldPos <- currentNearbyPosition <<.= (First $ Just $ view positionedSourcePos p)
  x <- f (view positioned p)
  currentNearbyPosition .= oldPos
  return x

throwToastError :: String -> TA a
throwToastError msg = do
  p <- view currentNearbyPosition
  throwError (ToastErrorMsg msg p)

throwToastErrorC :: String -> CTA a
throwToastErrorC = liftCTA . throwToastError

toastNear :: Positioned s -> TA a -> TA a
toastNear p =
  local (currentNearbyPosition .~ (First $ Just $ view positionedSourcePos p))
