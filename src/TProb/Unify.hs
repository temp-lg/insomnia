{-# LANGUAGE
      MultiParamTypeClasses,
      FlexibleInstances,
      FlexibleContexts,
      UndecidableInstances,
      ScopedTypeVariables,
      DeriveDataTypeable,
      DeriveGeneric,
      FunctionalDependencies,
      TemplateHaskell
  #-}
-- needs UndecidableInstances for the mtl classes.

-- | Somewhat generic implementation of first order unification.
-- The @'UnificationT' u@ monad transformer can add unification of
-- unification variables @'UVar' u@ that occur somewhere within a @u@.
-- In general the type @u@ (and perhaps others) will have to be instances
-- of @'Unifiable (UVar u) u@.
--
-- Note: We don't try to restrict the @UVar u@ values from escaping from the
-- unification monad via Haskell's typesystem, but you will get poor results
-- if they do so.  Caveat emptor!
module TProb.Unify
       (
         -- * Unification variables
         UVar
       , Partial(..)
       , HasUVars(..)
         -- * Terms subject to unification
       , Unifiable(..)
         -- * Unification monad class
       , MonadUnify(..)
       , MonadUnificationExcept(..)
         -- * The result of completely solving a unification subproblem.
       , UnificationResult(..)
       , UnificationFailure(..)
         -- * Unification monad transformer
       , UnificationT
       , evalUnificationT
       ) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Lens
import Control.Monad (when, liftM)
import Control.Monad.Trans.Class
import Control.Monad.Trans.State.Strict (StateT)
import qualified Control.Monad.Trans.State.Strict as St
import qualified Data.Map as M
import qualified Data.Text as T
import Data.Monoid (Monoid(..))

import qualified Control.Monad.Reader.Class as Reader
import qualified Control.Monad.Error.Class as Error

import Data.Typeable (Typeable)
import GHC.Generics (Generic)

import qualified Unbound.Generics.LocallyNameless as U

-- | An unknown value of type @u@ to be discovered via unification.
newtype UVar u = UVar Int
             deriving (Eq, Ord, Typeable, Generic)

instance Show (UVar u) where
  showsPrec _ (UVar i) = showString "⁇" . shows i
  
succUVar :: UVar u -> UVar u
succUVar (UVar i) = UVar $! i + 1

instance U.Alpha (UVar u)
  

newtype UnificationT u m b = UnificationT { ificationT :: StateT (S u) m b }

data UnificationResult u b =
  UOkay b
  | UFail (UnificationFailure u)

data UnificationFailure u =
  CircularityOccurs !(UVar u) !u -- CircularityOccurs x e means x wants to unify with e which contains some subterm that is unified with x.
  | Unsimplifiable !T.Text -- Simplification of a constraint x =?= y failed, for some x and y.

instance Show u => Show (UnificationFailure u) where
  showsPrec _ (CircularityOccurs uv t) =
    showString "occurs check failed: the variable "
    . shows uv . showString " occurs in " . shows t
  showsPrec _ (Unsimplifiable txt) =
    showString "simplification failed to unify"
    . (if T.null txt then id else showString " because "
                                  . showString (T.unpack txt))

data S u = S {
  _nextFreshId :: UVar u
  , _collectedConstraints :: M.Map (UVar u) u --  invariant: no cycles
  }

$(makeLenses ''S)

class (Functor m, Monad m) => MonadUnify u m | m -> u where
  unconstrained :: m (UVar u)
  solveUnification :: m b -> m (UnificationResult u b)
  (-?=) :: (Partial u, Unifiable u m u) => (UVar u) -> u -> m ()

-- | Types that are instances of partial may contain a unification
-- variable as one of their immediate constructors.
class Partial u where
  _UVar :: Prism' u (UVar u)

isUVar :: Partial u => u -> Maybe (UVar u)
isUVar t = t ^? _UVar

injectUVar :: Partial u => UVar u -> u
injectUVar v = v^.re _UVar
  
class HasUVars u b where
  allUVars :: Traversal' b u

-- | Types @b@ that are unifiable with by solving for UVars that stand for
-- their @u@ subterms
class (MonadUnificationExcept u m, HasUVars u b)
      => Unifiable u m b | m -> u where
  -- | traverse every unification variable in b.
  (=?=) :: b -> b -> m ()

instance HasUVars u b => HasUVars u [b] where
  allUVars f [] = pure []
  allUVars f (b:bs) = (:) <$> allUVars f b <*> allUVars f bs

instance Unifiable u m b => Unifiable u m [b] where
  [] =?= [] = return ()
  (b1:bs1) =?= (b2:bs2) = do
    b1 =?= b2
    bs1 =?= bs2
  bs1 =?= bs2 = throwUnificationFailure (Unsimplifiable (T.pack "could not unifiy lists of different length"))

class Monad m => MonadUnificationExcept u m | m -> u where
  throwUnificationFailure :: UnificationFailure u -> m a

instance Functor m => Functor (UnificationT a m) where
  fmap f = UnificationT . fmap f . ificationT

instance (Functor m, Monad m) => Applicative (UnificationT a m) where
  pure = UnificationT . pure
  umf <*> umx = UnificationT (ificationT umf <*> ificationT umx)

instance Monad m => Monad (UnificationT a m) where
  return = UnificationT . return
  umx >>= umf = UnificationT $ 
    ificationT umx >>= \ x -> ificationT (umf x)

instance U.LFresh m => U.LFresh (UnificationT u m) where
  lfresh = UnificationT . U.lfresh
  avoid ns = UnificationT . U.avoid ns . ificationT
  getAvoids = UnificationT U.getAvoids

instance MonadTrans (UnificationT u) where
  lift = UnificationT . lift

instance Reader.MonadReader r m => Reader.MonadReader r (UnificationT u m) where
  ask = UnificationT Reader.ask
  local f = UnificationT . Reader.local f . ificationT
  reader = UnificationT . Reader.reader

instance Error.MonadError e m => Error.MonadError e (UnificationT u m) where
  throwError = UnificationT . Error.throwError
  catchError uma handler = UnificationT (ificationT uma
                                         `Error.catchError`
                                         (ificationT . handler))

instance (MonadUnificationExcept u m)
         => MonadUnificationExcept u (UnificationT u m) where
  throwUnificationFailure = UnificationT . lift . throwUnificationFailure

instance (Functor m, MonadUnificationExcept u m)
         => MonadUnify u (UnificationT u m) where
  unconstrained = instUnconstrained
  solveUnification = instSolveUnification
  (-?=) = addConstraintUVar

-- if we ever need to delay solving some constraints, this would be
-- the place to force them.
instSolveUnification :: Monad m => UnificationT u m b -> UnificationT u m (UnificationResult u b)
instSolveUnification comp = liftM UOkay comp

                            
instUnconstrained :: Monad m => UnificationT u m (UVar u)
instUnconstrained = UnificationT $ nextFreshId <<%= succUVar

addConstraintUVar :: (Partial u, Unifiable u (UnificationT u m) u, Functor m,
                      MonadUnificationExcept u m)
                     => UVar u -> u -> UnificationT u m ()
addConstraintUVar v t_ = do
  t <- applyCurrentSubstitution t_
  occursCheck v t
  t2 <- applyCurrentSubstitution (injectUVar v)
  case isUVar t2 of
    Just v' | v == v' -> return ()
    _ -> t =?= t2
  UnificationT $ collectedConstraints . at v ?= t

applyCurrentSubstitution :: (Partial u, Unifiable u (UnificationT u m) u, Functor m, Monad m)
                            => u -> UnificationT u m u
applyCurrentSubstitution = traverseOf allUVars replace
  where
    replace :: (Partial u, Unifiable u (UnificationT u m) u, Functor m, Monad m)
               => u -> UnificationT u m u
    replace t0 =
      case t0^?_UVar of
        Nothing -> return t0
        Just u -> do
          mt_ <- UnificationT $ use $ collectedConstraints . at u
          case mt_ of
            Nothing -> return t0
            Just t -> applyCurrentSubstitution t
      
occursCheck :: (Partial u, Unifiable u (UnificationT u m) u, MonadUnificationExcept u m)
               => UVar u -> u -> UnificationT u m ()
occursCheck v t =
  let isV t2 = (t2^?_UVar) == Just v
  in
   when (anyOf allUVars isV t) $ do
     throwUnificationFailure (CircularityOccurs v t)
  

evalUnificationT :: Monad m => UnificationT u m a -> m a
evalUnificationT comp =
  St.evalStateT (ificationT comp) initialS

initialS :: S u
initialS =
  S {
    _nextFreshId = UVar 0
    , _collectedConstraints = mempty
    }
           