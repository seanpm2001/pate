{-|
Module           : What4.ExprHelpers
Copyright        : (c) Galois, Inc 2020
Maintainer       : Daniel Matichuk <dmatichuk@galois.com>

Helper functions for manipulating What4 expressions
-}

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE IncoherentInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE MultiWayIf #-}

module What4.ExprHelpers (
    iteM
  , impM
  , andM
  , orM
  , allPreds
  , anyPred
  , ExprBindings
  , mergeBindings
  , applyExprBindings
  , applyExprBindings'
  , VarBindCache
  , freshVarBindCache
  , rewriteSubExprs
  , rewriteSubExprs'
  , mapExprPtr
  , freshPtr
  , freshPtrBytes
  , ExprFilter(..)
  , getIsBoundFilter
  , BoundVarBinding(..)
  , groundToConcrete
  , fixMux
  , ExprSet
  , getPredAtoms
  , abstractOver
  , resolveConcreteLookups
  , minimalPredAtoms
  , expandMuxEquality
  , simplifyBVOps
  , simplifyConjuncts
  , boundVars
  , setProgramLoc
  , idxCacheEvalWriter
  , Tagged
  , natToIntegerPure
  ) where

import           GHC.TypeNats
import           Unsafe.Coerce -- for mulMono axiom

import           Control.Applicative
import           Control.Monad.Except
import qualified Control.Monad.IO.Class as IO
import           Control.Monad.ST ( RealWorld, stToIO )
import qualified Control.Monad.Writer as CMW
import qualified Control.Monad.State as CMS

import           Data.Foldable (foldlM, foldrM)
import qualified Data.BitVector.Sized as BVS
import qualified Data.HashTable.ST.Basic as H
import           Data.Word (Word64)
import           Data.Set (Set)
import qualified Data.Set as S
import           Data.List ( foldl' )
import           Data.List.NonEmpty (NonEmpty(..))

import qualified Data.Parameterized.Nonce as N
import           Data.Parameterized.Some
import           Data.Parameterized.Classes
import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.TraversableFC as TFC
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.Map ( Pair(..) )

import qualified Lang.Crucible.CFG.Core as CC
import qualified Lang.Crucible.LLVM.MemModel as CLM

import qualified What4.Expr.Builder as W4B
import qualified What4.ProgramLoc as W4PL
import qualified What4.Expr.GroundEval as W4G
import qualified What4.Expr.WeightedSum as WSum
import qualified What4.Interface as W4
import qualified What4.Concrete as W4C
import qualified What4.SemiRing as SR
import qualified What4.Expr.BoolMap as BM
import qualified What4.Symbol as WS

import           Data.Parameterized.SetF (SetF)
import qualified Data.Parameterized.SetF as SetF


-- FIXME: this is a workaround for the fact that 'natToInteger' from What4.Interface
-- is in the IO monad, but doesn't need to be.
natToIntegerPure ::
  W4.IsExprBuilder sym => sym -> W4.SymNat sym -> W4.SymInteger sym
natToIntegerPure _sym n = unsafeCoerce n

iteM ::
  W4.IsExprBuilder sym =>
  IO.MonadIO m =>
  sym ->
  m (W4.Pred sym) ->
  m (W4.SymExpr sym tp) ->
  m (W4.SymExpr sym tp) ->
  m (W4.SymExpr sym tp)
iteM sym p fT fF = do
  p' <- p
  case W4.asConstantPred p' of
    Just True -> fT
    Just False -> fF
    Nothing -> do
      fT' <- fT
      fF' <- fF
      IO.liftIO $ W4.baseTypeIte sym p' fT' fF'

impM ::
  W4.IsExprBuilder sym =>
  IO.MonadIO m =>
  sym ->
  m (W4.Pred sym) ->
  m (W4.Pred sym) ->
  m (W4.Pred sym)
impM sym pPre pPost = do
  pPre' <- pPre
  case W4.asConstantPred pPre' of
    Just True -> pPost
    Just False -> return $ W4.truePred sym
    _ -> do
      pPost' <- pPost
      IO.liftIO $ W4.impliesPred sym pPre' pPost'

andM ::
  W4.IsExprBuilder sym =>
  IO.MonadIO m =>
  sym ->
  m (W4.Pred sym) ->
  m (W4.Pred sym) ->
  m (W4.Pred sym)
andM sym p1 p2 = do
  p1' <- p1
  case W4.asConstantPred p1' of
    Just True -> p2
    Just False -> return $ W4.falsePred sym
    _ -> do
      p2' <- p2
      IO.liftIO $ W4.andPred sym p1' p2'


orM ::
  W4.IsExprBuilder sym =>
  IO.MonadIO m =>
  sym ->
  m (W4.Pred sym) ->
  m (W4.Pred sym) ->
  m (W4.Pred sym)
orM sym p1 p2 = do
  p1' <- p1
  case W4.asConstantPred p1' of
    Just True -> return $ W4.truePred sym
    Just False -> p2
    _ -> do
      p2' <- p2
      IO.liftIO $ W4.orPred sym p1' p2'

allPreds ::
  W4.IsExprBuilder sym =>
  sym ->
  [W4.Pred sym] ->
  IO (W4.Pred sym)
allPreds sym preds = foldr (\p -> andM sym (return p)) (return $ W4.truePred sym) preds

anyPred ::
  W4.IsExprBuilder sym =>
  sym ->
  [W4.Pred sym] ->
  IO (W4.Pred sym)
anyPred sym preds = foldr (\p -> orM sym (return p)) (return $ W4.falsePred sym) preds


-- | A variable binding environment used internally by 'rewriteSubExprs', associating
-- sub-expressions which have been replaced by variables
newtype VarBinds sym = VarBinds (MapF.MapF (W4.SymExpr sym) (SetF (W4.BoundVar sym)))

instance (OrdF (W4.BoundVar sym), OrdF (W4.SymExpr sym)) => Semigroup (VarBinds sym) where
  (VarBinds v1) <> (VarBinds v2) = VarBinds $
    MapF.mergeWithKey (\_ bvs1 bvs2 -> Just (bvs1 <> bvs2)) id id v1 v2

instance (OrdF (W4.BoundVar sym), OrdF (W4.SymExpr sym)) => Monoid (VarBinds sym) where
  mempty = VarBinds MapF.empty

toAssignmentPair ::
  [Pair f g] ->
  Pair (Ctx.Assignment f) (Ctx.Assignment g)
toAssignmentPair [] = Pair Ctx.empty Ctx.empty
toAssignmentPair ((Pair a1 a2):xs) | Pair a1' a2' <- toAssignmentPair xs =
  Pair (a1' Ctx.:> a1) (a2' Ctx.:> a2)

flattenVarBinds ::
  forall sym t solver fs.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  VarBinds sym ->
  [Pair (W4.BoundVar sym) (W4.SymExpr sym)]
flattenVarBinds (VarBinds binds) = concat $ map go (MapF.toList binds)
  where
    go :: Pair (W4.SymExpr sym) (SetF (W4.BoundVar sym)) -> [Pair (W4.BoundVar sym) (W4.SymExpr sym)]
    go (Pair e bvs) = map (\bv -> Pair bv e) $ SetF.toList bvs

toBindings ::
  forall sym t solver fs.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  VarBinds sym ->
  Pair (Ctx.Assignment (W4.BoundVar sym)) (Ctx.Assignment (W4.SymExpr sym))
toBindings varBinds = toAssignmentPair (flattenVarBinds varBinds)

-- | Traverse an expression and rewrite any sub-expressions according to the given
-- replacement function, rebuilding as necessary. If a replacement occurs, the resulting
-- sub-expression is not traversed any further.
rewriteSubExprs ::
  forall sym t solver fs tp.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  (forall tp'. W4B.Expr t tp' -> Maybe (W4B.Expr t tp')) ->
  W4B.Expr t tp ->
  IO (W4B.Expr t tp)
rewriteSubExprs sym f e = do
  cache <- freshVarBindCache
  rewriteSubExprs' sym cache f e

data VarBindCache sym where
  VarBindCache :: sym ~ W4B.ExprBuilder t solver fs => W4B.IdxCache t (Tagged (VarBinds sym) (W4B.Expr t)) -> VarBindCache sym

freshVarBindCache ::
  forall sym t solver fs.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  IO (VarBindCache sym)
freshVarBindCache = VarBindCache <$> W4B.newIdxCache

rewriteSubExprs' ::
  forall sym tp.
  sym ->
  VarBindCache sym ->
  (forall tp'. W4.SymExpr sym tp' -> Maybe (W4.SymExpr sym tp')) ->
  W4.SymExpr sym tp ->
  IO (W4.SymExpr sym tp)
rewriteSubExprs' sym (VarBindCache cache) = rewriteSubExprs'' sym cache

rewriteSubExprs'' ::
  forall sym t solver fs tp.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  W4B.IdxCache t (Tagged (VarBinds sym) (W4B.Expr t))  ->
  (forall tp'. W4B.Expr t tp' -> Maybe (W4B.Expr t tp')) ->
  W4B.Expr t tp ->
  IO (W4B.Expr t tp)
rewriteSubExprs'' sym cache f e_outer = do
  -- During this recursive descent, we find any sub-expressions which need to be rewritten
  -- and perform an in-place replacement with a bound variable, and track that replacement
  -- in the 'VarBinds' environment.
  -- i.e. given a map which takes 'x -> a' and 'z -> b', we would replace 'x + z' with 'bv_0 + bv_1' and
  -- record that 'a -> bv_0' and 'b -> bv_1'.
  let
    go :: forall tp'. W4B.Expr t tp' -> CMW.WriterT (VarBinds sym) IO (W4B.Expr t tp')
    go e = idxCacheEvalWriter cache e $ case f e of
      Just e' -> do
        bv <- IO.liftIO $ W4.freshBoundVar sym W4.emptySymbol (W4.exprType e')
        CMW.tell $ VarBinds $ MapF.singleton e' (SetF.singleton bv)
        return $ W4.varExpr sym bv
      Nothing -> case e of
        W4B.AppExpr a0 -> do
          a0' <- W4B.traverseApp go (W4B.appExprApp a0)
          if (W4B.appExprApp a0) == a0' then return e
          else IO.liftIO $ W4B.sbMakeExpr sym a0'
        W4B.NonceAppExpr a0 -> do
          a0' <- TFC.traverseFC go (W4B.nonceExprApp a0)
          if (W4B.nonceExprApp a0) == a0' then return e
          else IO.liftIO $ W4B.sbNonceExpr sym a0'
        _ -> return e
  (e', binds) <- CMW.runWriterT (go e_outer)
  -- Now we take our rewritten expression and use it to construct a function application.
  -- i.e. we define 'f(bv_0, bv_1) := bv_0 + bv_1', and then return 'f(a, b)', unfolding in-place.
  -- This ensures that the What4 expression builder correctly re-establishes any invariants it requires
  -- after rebinding.
  Pair vars vals <- return $ toBindings binds
  fn <- W4.definedFn sym W4.emptySymbol vars e' W4.AlwaysUnfold
  W4.applySymFn sym fn vals >>= fixMux sym

-- | An expression binding environment. When applied to an expression 'e'
-- with 'applyExprBindings', each sub-expression of 'e' is recursively inspected
-- and rebound if it appears in the environment.
-- Note that this does not apply iteratively, once a sub-expression has been rebound the result
-- is not traversed further. This implicitly assumes that
-- the expressions used for the domain do not appear anywhere in the range.
type ExprBindings sym = MapF.MapF (W4.SymExpr sym) (W4.SymExpr sym)

-- | Merge two 'ExprBindings' together.
-- Throws a runtime exception if there are any clashes between the environments
-- (i.e. each environment binds an expression to different values)
mergeBindings ::
  OrdF (W4.SymExpr sym) =>
  sym ->
  ExprBindings sym ->
  ExprBindings sym ->
  IO (ExprBindings sym)
mergeBindings _sym binds1 binds2 =
  MapF.mergeWithKeyM (\_ e1 e2 -> case testEquality e1 e2 of
                         Just _ -> return $ Just e1
                         Nothing -> fail "mergeBindings: unexpected variable clash")
    return
    return
    binds1
    binds2

-- | Rewrite the sub-expressions of an expression according to the given binding environment.
applyExprBindings ::
  forall sym t solver fs tp.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  ExprBindings sym ->
  W4B.Expr t tp ->
  IO (W4B.Expr t tp)
applyExprBindings sym binds = rewriteSubExprs sym (\e' -> MapF.lookup e' binds)

applyExprBindings' ::
  forall sym tp.
  OrdF (W4.SymExpr sym) =>
  sym ->
  VarBindCache sym ->
  ExprBindings sym ->
  W4.SymExpr sym tp ->
  IO (W4.SymExpr sym tp)
applyExprBindings' sym cache binds = rewriteSubExprs' sym cache (\e' -> MapF.lookup e' binds)

mapExprPtr ::
  forall sym m w.
  W4.IsExprBuilder sym =>
  IO.MonadIO m =>
  sym ->
  (forall tp. W4.SymExpr sym tp -> m (W4.SymExpr sym tp)) ->
  CLM.LLVMPtr sym w ->
  m (CLM.LLVMPtr sym w)
mapExprPtr sym f (CLM.LLVMPointer reg off) = do
  regInt <- (IO.liftIO $ W4.natToInteger sym reg) >>= f
  reg' <- IO.liftIO $ W4.integerToNat sym regInt
  off' <- f off
  return $ CLM.LLVMPointer reg' off'

freshPtrBytes ::
  W4.IsSymExprBuilder sym =>
  1 <= w =>
  sym ->
  String ->
  W4.NatRepr w ->
  IO (CLM.LLVMPtr sym (8 W4.* w))
freshPtrBytes sym name w
  | bvwidth <- W4.natMultiply (W4.knownNat @8) w
  , W4.LeqProof <- mulMono (W4.knownNat @8) w
  = freshPtr sym name bvwidth

freshPtr ::
  W4.IsSymExprBuilder sym =>
  1 <= w =>
  sym ->
  String ->
  W4.NatRepr w ->
  IO (CLM.LLVMPtr sym w)
freshPtr sym name w = do
  off <- W4.freshConstant sym (WS.safeSymbol (name ++ "_offset")) (W4.BaseBVRepr w)
  reg <- W4.freshNat sym (WS.safeSymbol (name ++ "_region"))
  return $ CLM.LLVMPointer reg off


mulMono :: forall p q x w. (1 <= x, 1 <= w) => p x -> q w -> W4.LeqProof 1 (x W4.* w)
mulMono _x w = unsafeCoerce (W4.leqRefl w)


-- Clagged from What4.Builder
type BoundVarMap t = H.HashTable RealWorld Word64 (Set (Some (W4B.ExprBoundVar t)))

boundVarsMap :: W4B.Expr t tp -> IO (BoundVarMap t)
boundVarsMap e0 = do
  visited <- stToIO $ H.new
  _ <- boundVars' visited e0
  return visited

cacheExec :: (Eq k, CC.Hashable k) => H.HashTable RealWorld k r -> k -> IO r -> IO r
cacheExec h k m = do
  mr <- stToIO $ H.lookup h k
  case mr of
    Just r -> return r
    Nothing -> do
      r <- m
      stToIO $ H.insert h k r
      return r

boundVars' :: BoundVarMap t
           -> W4B.Expr t tp
           -> IO (Set (Some (W4B.ExprBoundVar t)))
boundVars' visited (W4B.AppExpr e) = do
  let idx = N.indexValue (W4B.appExprId e)
  cacheExec visited idx $ do
    sums <- sequence (TFC.toListFC (boundVars' visited) (W4B.appExprApp e))
    return $ foldl' S.union S.empty sums
boundVars' visited (W4B.NonceAppExpr e) = do
  let idx = N.indexValue (W4B.nonceExprId e)
  cacheExec visited idx $ do
    sums <- sequence (TFC.toListFC (boundVars' visited) (W4B.nonceExprApp e))
    return $ foldl' S.union S.empty sums
boundVars' visited (W4B.BoundVarExpr v) = do
      let idx = N.indexValue (W4B.bvarId v)
      cacheExec visited idx $
        return (S.singleton (Some v))
boundVars' _ (W4B.SemiRingLiteral{}) = return S.empty
boundVars' _ (W4B.BoolExpr{}) = return S.empty
boundVars' _ (W4B.StringExpr{}) = return S.empty
boundVars' _ (W4B.FloatExpr {}) = return S.empty
-- End Clag

boundVars :: W4B.Expr t tp -> IO (Set (Some (W4B.ExprBoundVar t)))
boundVars e0 = do
  visited <- stToIO $ H.new
  boundVars' visited e0

newtype ExprFilter sym = ExprFilter (forall tp'. W4.SymExpr sym tp' -> IO Bool)

-- | Return an 'ExprFilter' that is filters expressions which are bound variables
-- that appear somewhere in the given expression.
getIsBoundFilter ::
  sym ~ (W4B.ExprBuilder t solver fs) =>
  -- | source expression potentially containing bound variables
  W4.SymExpr sym tp ->
  IO (ExprFilter sym)
getIsBoundFilter expr = do
  bvs <- liftIO $ boundVarsMap expr
  return $ ExprFilter $ \bv -> do
    case bv of
      W4B.BoundVarExpr bv' -> do
        let idx = N.indexValue (W4B.bvarId bv')
        stToIO $ H.lookup bvs idx >>= \case
          Just bvs' -> return $ S.member (Some bv') bvs'
          _ -> return False
      _ -> return False


newtype BoundVarBinding sym = BoundVarBinding (forall tp'. W4.BoundVar sym tp' -> IO (Maybe (W4.SymExpr sym tp')))

-- | Simplify 'ite (eq y x) y x' into 'x'
fixMux ::
  forall sym t solver fs tp.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  W4B.Expr t tp ->
  IO (W4B.Expr t tp)
fixMux sym e = do
  cache <- W4B.newIdxCache
  fixMux' sym cache e

fixMux' ::
  forall sym t solver fs tp.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  W4B.IdxCache t (W4B.Expr t) ->
  W4B.Expr t tp ->
  IO (W4B.Expr t tp)
fixMux' sym cache e_outer = do
  let
    go :: forall tp'. W4B.Expr t tp' -> IO (W4B.Expr t tp')
    go e = W4B.idxCacheEval cache e $ case e of
      W4B.AppExpr a0
        | (W4B.BaseIte _ _ cond eT eF) <- W4B.appExprApp a0
        , Just (W4B.BaseEq _ eT' eF') <- W4B.asApp cond
        , Just W4.Refl <- W4.testEquality eT eT'
        , Just W4.Refl <- W4.testEquality eF eF'
        -> go eF
      W4B.AppExpr a0
         | (W4B.BaseIte _ _ cond eT eF) <- W4B.appExprApp a0
         -> do
             eT' <- go eT
             eF' <- go eF
             if | Just (W4B.BaseIte _ _ cond2 eT2 _) <- W4B.asApp eT'
                , cond == cond2 -> W4.baseTypeIte sym cond eT2 eF'
                | Just (W4B.BaseIte _ _ cond2 _ eF2) <- W4B.asApp eF'
                , cond == cond2 ->  W4.baseTypeIte sym cond eT' eF2
                | eT' == eT, eF' == eF -> return e
                | otherwise -> W4.baseTypeIte sym cond eT' eF'
      W4B.AppExpr a0
         | W4B.BaseIte _ _ cond eT eF <- W4B.appExprApp a0
         , Just (W4B.BaseIte _ _ cond2 eT2 _) <- W4B.asApp eT
         , cond == cond2
         -> go =<< W4.baseTypeIte sym cond eT2 eF
      W4B.AppExpr a0
         | (W4B.BaseIte _ _ cond eT eF) <- W4B.appExprApp a0
         , Just (W4B.BaseIte _ _ cond2 _ eF2) <- W4B.asApp eF
         , cond == cond2
         -> go =<< W4.baseTypeIte sym cond eT eF2
      W4B.AppExpr a0 -> do
        a0' <- W4B.traverseApp go (W4B.appExprApp a0)
        if (W4B.appExprApp a0) == a0' then return e
        else W4B.sbMakeExpr sym a0'
      W4B.NonceAppExpr a0 -> do
        a0' <- TFC.traverseFC go (W4B.nonceExprApp a0)
        if (W4B.nonceExprApp a0) == a0' then return e
        else W4B.sbNonceExpr sym a0'
      _ -> return e
  go e_outer


groundToConcrete ::
  W4.BaseTypeRepr tp ->
  W4G.GroundValue tp ->
  Maybe (W4C.ConcreteVal tp)
groundToConcrete repr gv = case repr of
  W4.BaseBoolRepr -> return $ W4C.ConcreteBool gv
  W4.BaseBVRepr w -> return $ W4C.ConcreteBV w gv
  W4.BaseIntegerRepr -> return $ W4C.ConcreteInteger gv
  W4.BaseStructRepr srepr -> do
    let
      go (W4G.GVW gv') repr' = groundToConcrete repr' gv'
    W4C.ConcreteStruct <$> Ctx.zipWithM go gv srepr
  _ -> fail "Unsupported ground value"

type ExprSet sym = SetF (W4.SymExpr sym)

type PredSet sym = ExprSet sym W4.BaseBoolType

-- | Get the atomic predicates which appear anywhere in the given predicate.
-- TODO: does not consider all possible predicate constructors.
getPredAtoms ::
  forall sym t solver fs.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  W4.Pred sym ->
  IO (PredSet sym)
getPredAtoms sym e_outer = do
  cache <- W4B.newIdxCache
  let    
    muxes ::
      forall tp1.
      W4.SymExpr sym tp1 ->
      (W4.SymExpr sym tp1 -> IO (PredSet sym)) ->
      IO (PredSet sym)
    muxes e f = case W4B.asApp e of
      Just (W4B.BaseIte _ _ cond eT eF) -> do
        condAtoms <- go cond
        eTAtoms <- muxes eT f 
        eFAtoms <- muxes eF f
        return $ condAtoms <> eTAtoms <> eFAtoms
      _ -> f e

    muxes2 ::
      forall tp1 tp2.
      W4.SymExpr sym tp1 ->
      W4.SymExpr sym tp2 ->
      (W4.SymExpr sym tp1 -> W4.SymExpr sym tp2 -> IO (PredSet sym)) ->
      IO (PredSet sym)
    muxes2 e1 e2 f = muxes e1 (\e1' -> muxes e2 (f e1'))

    liftPred ::
      forall tp1 tp2.
      (sym -> W4.SymExpr sym tp1 -> W4.SymExpr sym tp2 -> IO (W4.Pred sym)) ->
      (W4.SymExpr sym tp1 -> W4.SymExpr sym tp2 -> IO (PredSet sym))
    liftPred f e1 e2 = SetF.singleton <$> f sym e1 e2
      
    binOp ::
      forall tp1 tp2.
      (W4.SymExpr sym tp1 -> W4.SymExpr sym tp2 -> IO (PredSet sym)) ->
      W4.SymExpr sym tp1 ->
      W4.SymExpr sym tp2 ->
      IO (PredSet sym)
    binOp f e1 e2 = muxes2 e1 e2 $ \e1' e2' -> do
      e1Atoms <- go e1'
      e2Atoms <- go e2'
      leafAtoms <- f e1' e2'
      return $ leafAtoms <> e1Atoms <> e2Atoms

    unOp ::
      forall tp1.
      (W4.SymExpr sym tp1 -> IO (PredSet sym)) ->
      W4.SymExpr sym tp1 ->
      IO (PredSet sym)
    unOp f e1 = muxes e1 $ \e1' -> do
      e1Atoms <- go e1'
      leafAtoms <- f e1'
      return $ e1Atoms <> leafAtoms
  
    go :: forall tp'. W4.SymExpr sym tp' -> IO (PredSet sym)
    go p_inner = muxes p_inner $ \p -> fmap getConst $ W4B.idxCacheEval cache p $ do
      setProgramLoc sym p
      case p of
        W4B.AppExpr a0 -> case W4B.appExprApp a0 of
           W4B.BaseEq _ e1 e2 -> Const <$> binOp (liftPred W4.isEq) e1 e2 
           W4B.BVUlt e1 e2 -> Const <$> binOp (liftPred W4.bvUlt) e1 e2 
           W4B.BVSlt e1 e2 -> Const <$> binOp (liftPred W4.bvSlt) e1 e2
           W4B.SemiRingLe SR.OrderedSemiRingIntegerRepr e1 e2 -> Const <$> binOp (liftPred W4.intLe) e1 e2
           W4B.SemiRingLe SR.OrderedSemiRingRealRepr e1 e2 -> Const <$> binOp (liftPred W4.realLe) e1 e2
           W4B.BVTestBit n e -> Const <$> unOp (\e' -> SetF.singleton <$> W4.testBitBV sym n e') e
           _ -> TFC.foldrMFC acc mempty (W4B.appExprApp a0)
        W4B.NonceAppExpr a0 -> TFC.foldrMFC acc mempty (W4B.nonceExprApp a0)
        _ -> return $ mempty

    acc :: forall tp1 tp2. W4.SymExpr sym tp1 -> Const (PredSet sym) tp2 -> IO (Const (PredSet sym) tp2)
    acc p (Const exprs) = do
      exprs' <- go p
      return $ Const $ exprs <> exprs'

  go e_outer


-- | Lambda abstraction: given a term @a@ and a term @e@ which contains @a@,
-- generate a function @f(x) = e[a/x]@.
abstractOver ::
  forall sym t solver fs tp1 tp2.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  -- | subterm
  W4.SymExpr sym tp1 ->
  -- | outer term
  W4.SymExpr sym tp2 ->
  IO (W4.SymFn sym (Ctx.EmptyCtx Ctx.::> tp1) tp2)
abstractOver sym sub outer = do
  sub_bv <- W4.freshBoundVar sym W4.emptySymbol (W4.exprType sub)
  cache <- W4B.newIdxCache
  let
    go :: forall tp'. W4.SymExpr sym tp' -> IO (W4.SymExpr sym tp')
    go e
      | Just Refl <- testEquality (W4.exprType e) (W4.exprType sub), e == sub
         = return $ W4.varExpr sym sub_bv
    go e = W4B.idxCacheEval cache e $ do
      setProgramLoc sym e
      case e of
        W4B.AppExpr a0 -> do
          a0' <- W4B.traverseApp go (W4B.appExprApp a0)
          if (W4B.appExprApp a0) == a0' then return e
          else W4B.sbMakeExpr sym a0'
        W4B.NonceAppExpr a0 -> do
          a0' <- TFC.traverseFC go (W4B.nonceExprApp a0)
          if (W4B.nonceExprApp a0) == a0' then return e
          else W4B.sbNonceExpr sym a0'
        _ -> return e
  outer_abs <- go outer
  W4.definedFn sym W4.emptySymbol (Ctx.empty Ctx.:> sub_bv) outer_abs W4.AlwaysUnfold

-- | Resolve array lookups across array updates which are known to not alias.
-- i.e. @select (update arr A V) B --> select arr B@ given that @f(A, B) = Just False@ (i.e.
-- they are statically known to be inequivalent according to the given testing function)
resolveConcreteLookups ::
  forall m sym t solver fs tp.
  IO.MonadIO m =>
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  (forall tp'. W4.SymExpr sym tp' -> W4.SymExpr sym tp' -> m (Maybe Bool)) ->
  W4.SymExpr sym tp ->
  m (W4.SymExpr sym tp)
resolveConcreteLookups sym f e_outer = do
  cache <- W4B.newIdxCache
  let
    andPred ::
      forall (tp' :: W4.BaseType).
      Const (Maybe Bool) tp' ->
      Maybe Bool ->
      Maybe Bool
    andPred (Const p) (Just b) = case p of
      Just b' -> Just (b && b')
      Nothing -> Nothing
    andPred _ Nothing = Nothing
    
    resolveArr ::
      forall idx idx1 idx2 tp'.
      idx ~ (idx1 Ctx.::> idx2) =>
      W4.SymExpr sym (W4.BaseArrayType idx tp') ->
      Ctx.Assignment (W4.SymExpr sym) idx ->
      m (W4.SymExpr sym tp')
    resolveArr arr_base idx_base = do
      arr <- go arr_base
      idx <- TFC.traverseFC go idx_base
      val <- liftIO $ W4.arrayLookup sym arr idx
      case arr of
        W4B.AppExpr a0 -> case W4B.appExprApp a0 of
          W4B.UpdateArray _ _ arr' idx' upd_val -> do
            eqIdx <- Ctx.zipWithM (\e1 e2 -> Const <$> f e1 e2) idx idx'
            case TFC.foldrFC andPred (Just True) eqIdx of
              Just True -> return $ upd_val
              Just False -> resolveArr arr' idx
              _ -> return val
          W4B.SelectArray _ arr' idx' -> do
            arr'' <- resolveArr arr' idx'
            case arr'' == arr of
              True -> return val
              False -> resolveArr arr'' idx
          _ -> return val
        _ -> return val
    
    go :: forall tp'. W4.SymExpr sym tp' -> m (W4.SymExpr sym tp')
    go e = W4B.idxCacheEval cache e $ do
      setProgramLoc sym e
      case e of
        W4B.AppExpr a0 -> case W4B.appExprApp a0 of
          W4B.SelectArray _ arr idx -> resolveArr arr idx
          app -> do
            a0' <- W4B.traverseApp go app
            if (W4B.appExprApp a0) == a0' then return e
            else liftIO $ W4B.sbMakeExpr sym a0'
        W4B.NonceAppExpr a0 -> do
          a0' <- TFC.traverseFC go (W4B.nonceExprApp a0)
          if (W4B.nonceExprApp a0) == a0' then return e
          else liftIO $ W4B.sbNonceExpr sym a0'
        _ -> return e
  go e_outer

-- TODO: it's unclear if What4's existing abstract domains are
-- precise enough to capture what we need here
leadingZeros ::
  forall sym t solver fs w1.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  W4.SymBV sym w1 ->
  Integer
leadingZeros bv_outer = go bv_outer
  where
    go :: forall w. W4.SymBV sym w -> Integer
    go bv =
      let W4.BaseBVRepr w_large = W4.exprType bv
      in case W4B.asApp bv of
        Just (W4B.BVZext _ bv')
          | W4.BaseBVRepr w_small <- W4.exprType bv'
          , zlead <- go bv'
          , cexti <- (W4.intValue w_large) - (W4.intValue w_small)
          -> cexti + zlead
        Just (W4B.BVShl _ bv' shift)
          | Just cshift <- W4.asBV shift
          , zlead <- leadingZeros bv'
          -> max 0 (zlead - (BVS.asUnsigned cshift))
        Just (W4B.BVLshr _ bv' shift)
          | Just cshift <- W4.asBV shift
          , zlead <- leadingZeros bv'
          -> zlead + (BVS.asUnsigned cshift)
        Just (W4B.SemiRingSum s) | SR.SemiRingBVRepr SR.BVArithRepr _ <- WSum.sumRepr s ->
          let
            allzeros = W4.intValue w_large

            doAdd i1 i2 | i1 == allzeros = i2
            doAdd i1 i2 | i2 == allzeros = i1
            doAdd i1 i2 = max 0 ((min i1 i2) -1)

            doMul coef bv' = case BVS.asUnsigned coef of
              1 -> go bv'
              _ -> 0

            doConst c = BVS.asUnsigned (BVS.clz w_large c)
          in WSum.eval doAdd doMul doConst s
        Just (W4B.SemiRingSum s) | SR.SemiRingBVRepr SR.BVBitsRepr _ <- WSum.sumRepr s ->
          let
             doAdd i1 i2 = min i1 i2
             doMul coef bv' = max (doConst coef) (leadingZeros bv')
             doConst c = BVS.asUnsigned (BVS.clz w_large c)

           in WSum.eval doAdd doMul doConst s

        Just (W4B.BVSelect idx n bv')
          | 0 <- W4.intValue idx
          , zlead <- go bv'
          -> max 0 (zlead - (W4.intValue n))
        _ -> case W4.asBV bv of
          Just cbv -> BVS.asUnsigned (BVS.clz w_large cbv)
          Nothing -> 0

-- | (ite P A B) == (ite P' A' B') --> (P && P' && A == A') || (P && not(P') && A == B') ...
expandMuxEquality ::
  forall sym t solver fs tp.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  W4.SymExpr sym tp ->
  IO (W4.SymExpr sym tp)
expandMuxEquality sym outer = do
  cache <- W4B.newIdxCache
  let
    expandIte ::
      forall tp'.
      W4.Pred sym ->
      W4.SymExpr sym tp' ->
      W4.SymExpr sym tp' ->
      W4.SymExpr sym tp' ->
      IO (W4.Pred sym)
    expandIte cond eT eF that = do
      eT_eq <- W4.isEq sym that eT
      eF_eq <- W4.isEq sym that eF
      eT_case <- W4.andPred sym cond eT_eq
      notCond <- W4.notPred sym cond
      eF_case <- W4.andPred sym notCond eF_eq
      W4.orPred sym eT_case eF_case

    go :: forall tp'. W4.SymExpr sym tp' -> IO (W4.SymExpr sym tp')
    go e = W4B.idxCacheEval cache e $ do
      setProgramLoc sym e
      case e of
        W4B.AppExpr a0 -> case W4B.appExprApp a0 of
          W4B.BaseEq _ lhs rhs
            | Just (W4B.BaseIte _ _ cond eT eF) <- W4B.asApp rhs
            -> expandIte cond eT eF lhs >>= go
          W4B.BaseEq _ lhs rhs
            | Just (W4B.BaseIte _ _ cond eT eF) <- W4B.asApp lhs
            -> expandIte cond eT eF rhs >>= go
          app -> do
            a0' <- W4B.traverseApp go app
            if app == a0' then return e
            else W4B.sbMakeExpr sym a0' >>= go
        W4B.NonceAppExpr a0 -> do
          a0' <- TFC.traverseFC go (W4B.nonceExprApp a0)
          if (W4B.nonceExprApp a0) == a0' then return e
          else W4B.sbNonceExpr sym a0' >>= go
        _ -> return e
  go outer

-- | Simplification cases for 'simplifyBVOps'
simplifyBVOpInner ::
  forall sym t solver fs tp.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  -- | Recursive call to outer simplification function
  (forall tp'. W4.SymExpr sym tp' -> IO (W4.SymExpr sym tp')) ->
  W4B.App (W4B.Expr t) tp ->
  Maybe (IO (W4.SymExpr sym tp))
simplifyBVOpInner sym go app = case app of
  W4B.BVConcat w u v -> do
      W4B.BVSelect upper n bv <- W4B.asApp u
      W4B.BVSelect lower n' bv' <- W4B.asApp v
      Refl <- testEquality bv bv'
      W4.BaseBVRepr bv_w <- return $ W4.exprType bv
      Refl <- testEquality upper (W4.addNat lower n')
      total <- return $ W4.addNat n n'
      W4.LeqProof <- W4.testLeq (W4.addNat lower total) bv_w
      return $ W4.bvSelect sym lower total bv >>= go
    <|> do
      u' <- W4.asBV u
      0 <- return $ BVS.asUnsigned u'
      W4.BaseBVRepr v_w <- return $ W4.exprType v
      W4.LeqProof <- W4.testLeq (W4.incNat v_w) w
      return $ W4.bvZext sym w v >>= go
    <|> do
      v' <- W4.asBV v
      0 <- return $ BVS.asUnsigned v'
      W4.BaseBVRepr u_w <- return $ W4.exprType u
      W4.BaseBVRepr v_w <- return $ W4.exprType v
      W4.LeqProof <- W4.testLeq (W4.incNat u_w) w
      return $ do
        shift <- W4.bvLit sym w (BVS.mkBV w (W4.intValue v_w))
        bv <- W4.bvZext sym w u
        W4.bvShl sym bv shift >>= go

  --   ((Zext z a) << n) >> n) == a given n <= z
  W4B.BVLshr _ bv shift -> do
    W4B.BVShl _ bv' shift' <- W4B.asApp bv
    Refl <- testEquality shift shift'
    cshift <- W4.asBV shift
    zlead <- return $ leadingZeros bv'
    True <- return $ BVS.asUnsigned cshift <= zlead
    return $ go bv'

  W4B.BVZext w_outer bv -> do
    W4B.BVZext _ bv' <- W4B.asApp bv
    W4.BaseBVRepr bv_w <- return $ W4.exprType bv'
    W4.LeqProof <- W4.testLeq (W4.incNat bv_w) w_outer
    return $ W4.bvZext sym w_outer bv' >>= go

  W4B.BVSext w bv -> do
    True <- return $ 0 < leadingZeros bv
    return $ W4.bvZext sym w bv >>= go

  W4B.BVSelect idx n bv -> do
      W4B.BVShl _ bv' shift <- W4B.asApp bv
      cshift <- W4.asBV shift
      True <- return $ BVS.asUnsigned cshift <= BVS.asUnsigned (BVS.maxUnsigned n)
      return $ do
          shift' <- W4.bvLit sym n (BVS.mkBV n (BVS.asUnsigned cshift))
          bv'' <- W4.bvSelect sym idx n bv'
          W4.bvShl sym bv'' shift' >>= go
    <|> do
     -- select 0 16 (bvXor (bvAnd 0xffff var)) --> select 0 16 var
      Refl <- testEquality idx (W4.knownNat @0)
      W4B.SemiRingSum s <- W4B.asApp bv
      SR.SemiRingBVRepr SR.BVBitsRepr w_large <- return $ WSum.sumRepr s
      W4.LeqProof <- W4.testLeq (W4.incNat n) w_large
      one_small <- return $ BVS.zext w_large (SR.one (SR.SemiRingBVRepr SR.BVBitsRepr n))
      (coeff, var) <- WSum.asWeightedVar s
      True <- return $ one_small == coeff
      return $ W4.bvSelect sym idx n var >>= go
     -- push selection into bit operations
    <|> do
      W4B.SemiRingSum s <- W4B.asApp bv
      SR.SemiRingBVRepr SR.BVBitsRepr w <- return $ WSum.sumRepr s
      let
        doAdd bv1 bv2 = W4.bvXorBits sym bv1 bv2

        doMul coef bv' = do
          coef_bv <- W4.bvLit sym w coef
          coef_bv' <- W4.bvSelect sym idx n coef_bv
          bv'' <- W4.bvSelect sym idx n bv' >>= go
          W4.bvAndBits sym coef_bv' bv''

        doConst c = W4.bvLit sym w c >>= W4.bvSelect sym idx n

      return $ WSum.evalM doAdd doMul doConst s
     -- push selection into sums
    <|> do
      W4B.SemiRingSum s <- W4B.asApp bv
      SR.SemiRingBVRepr SR.BVArithRepr w <- return $ WSum.sumRepr s
      let
        doAdd bv1 bv2 = W4.bvAdd sym bv1 bv2

        doMul coef bv' = do
          coef_bv <- W4.bvLit sym w coef
          bv'' <- W4.bvMul sym coef_bv bv' >>= go
          W4.bvSelect sym idx n bv''

        doConst c = W4.bvLit sym w c >>= W4.bvSelect sym idx n
      return $ WSum.evalM doAdd doMul doConst s
    <|> do
      W4B.BVOrBits _ s <- W4B.asApp bv
      (b:bs) <- return $ W4B.bvOrToList s
      return $ do
        let doOr bv1 bv2 = do
              bv2' <- W4.bvSelect sym idx n bv2 >>= go
              W4.bvOrBits sym bv1 bv2'
        b' <- W4.bvSelect sym idx n b >>= go
        foldM doOr b' bs
    <|> do
      W4B.BaseIte _ _ cond bv1 bv2 <- W4B.asApp bv
      return $ do
        bv1' <- W4.bvSelect sym idx n bv1 >>= go
        bv2' <- W4.bvSelect sym idx n bv2 >>= go
        cond' <- go cond
        W4.baseTypeIte sym cond' bv1' bv2'
  W4B.BaseEq _ lhs rhs -> do
      W4.BaseBVRepr lhs_w <- return $ W4.exprType lhs
      lhs_lz <- return $ leadingZeros lhs
      rhs_lz <- return $ leadingZeros rhs
      lz <- return $ min lhs_lz rhs_lz
      True <- return $ 0 < lz
      Some top <- W4.someNat ((W4.intValue lhs_w) - lz)
      W4.LeqProof <- W4.isPosNat top
      W4.LeqProof <- W4.testLeq top lhs_w
      return $ do
        lhs' <- W4.bvSelect sym (W4.knownNat @0) top lhs
        rhs' <- W4.bvSelect sym (W4.knownNat @0) top rhs
        W4.isEq sym lhs' rhs' >>= go
    <|> do
      W4.BaseBVRepr lhs_w <- return $ W4.exprType lhs
      lhs_lz <- return $ leadingZeros lhs
      True <- return $ 0 < lhs_lz
      W4B.BVSext _ rhs' <- W4B.asApp rhs
      W4.BaseBVRepr rhs_w <- return $ W4.exprType rhs'
      diff <- return $ (W4.intValue lhs_w - W4.intValue rhs_w)
      True <- return $ diff < lhs_lz
    -- TODO: provable
      W4.LeqProof <- W4.testLeq rhs_w lhs_w
      return $ do
        lhs' <- W4.bvSelect sym (W4.knownNat @0) rhs_w lhs
        W4.isEq sym lhs' rhs' >>= go
  _ -> Nothing

-- | Deep simplification of bitvector operations by removing redundant
-- shifts, pushing slices through arithmetic operations, and dropping
-- zero-extensions where possible.
simplifyBVOps ::
  forall sym t solver fs tp.
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  W4.SymExpr sym tp ->
  IO (W4.SymExpr sym tp)
simplifyBVOps sym outer = do
  cache <- W4B.newIdxCache
  let
    else_ :: forall tp'. W4.SymExpr sym tp' -> IO (W4.SymExpr sym tp')
    else_ e = case e of
      W4B.AppExpr a0 -> do
        a0' <- W4B.traverseApp go (W4B.appExprApp a0)
        if (W4B.appExprApp a0) == a0' then return e
        else W4B.sbMakeExpr sym a0' >>= go
      W4B.NonceAppExpr a0 -> do
        a0' <- TFC.traverseFC go (W4B.nonceExprApp a0)
        if (W4B.nonceExprApp a0) == a0' then return e
        else W4B.sbNonceExpr sym a0' >>= go
      _ -> return e      
    
    go :: forall tp'. W4.SymExpr sym tp' -> IO (W4.SymExpr sym tp')
    go e = W4B.idxCacheEval cache e $ do
      setProgramLoc sym e
      case e of
        W4B.AppExpr a0 -> case simplifyBVOpInner sym go (W4B.appExprApp a0) of
          Just go' -> go'
          Nothing -> else_ e
        _ -> else_ e
  go outer

-- | Simplify the given predicate by deciding which atoms are logically necessary
-- according to the given provability function.
--
-- Starting with @p@, for each atom @a@ in @p@ and intermediate result @p'@, either:
--   * if @p'[a/true] == p'[a/false]: return @p'[a/true]@
--   * if @a@ is provable: return @p'[a/true]@
--   * if @a@ is disprovable: return @p'[a/false]@
--   * if @p' --> a@ is provable: return @a && p'[a/true]@
--   * if @p' --> not(a)@ is provable: return @not(a) && p'[a/false]@
--   * otherwise, return @p'@
minimalPredAtoms ::
  forall m sym t solver fs.
  IO.MonadIO m =>
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  -- | decision for the provability of a predicate
  (W4.Pred sym -> m Bool) ->
  W4.Pred sym ->
  m (W4.Pred sym)
minimalPredAtoms sym provable p_outer = do
  let
    applyAtom :: W4.Pred sym -> W4.Pred sym -> m (W4.Pred sym)
    applyAtom p' atom = do
      notAtom <- liftIO $ W4.notPred sym atom
      p_fn <- liftIO $ abstractOver sym atom p'
      p_fn_true <- liftIO $ W4.applySymFn sym p_fn (Ctx.empty Ctx.:> W4.truePred sym)
      p_fn_false <- liftIO $ W4.applySymFn sym p_fn (Ctx.empty Ctx.:> W4.falsePred sym)
      indep <- liftIO $ W4.isEq sym p_fn_true p_fn_false

      trueCase <- liftIO $ W4.orPred sym atom indep
      implies_atom <- liftIO $ W4.impliesPred sym p' atom
      implies_notAtom <- liftIO $ W4.impliesPred sym p' notAtom
      
      provable trueCase >>= \case
        True -> return p_fn_true
        False -> provable notAtom >>= \case
          True -> return p_fn_false
          False -> provable implies_atom >>= \case
            True -> liftIO $ W4.andPred sym atom p_fn_true
            False -> provable implies_notAtom >>= \case
              True -> liftIO $ W4.andPred sym notAtom p_fn_false
              False -> return p'

  atoms <- liftIO $ getPredAtoms sym p_outer
  CMS.foldM applyAtom p_outer (SetF.toList atoms)

data ConjunctFoldDir = ConjunctFoldRight | ConjunctFoldLeft

simplifyConjuncts ::
  forall m sym t solver fs.
  IO.MonadIO m =>
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  -- | decision for the provability of a predicate
  (W4.Pred sym -> m Bool) ->
  W4.Pred sym ->
  m (W4.Pred sym)
simplifyConjuncts sym provable p_outer = do
  cache <- W4B.newIdxCache
  let
    go :: ConjunctFoldDir -> W4.Pred sym -> W4.Pred sym -> m (W4.Pred sym)
    go foldDir asms p = W4B.idxCacheEval cache p $ do
      setProgramLoc sym p
      case W4B.asApp p of
        Just (W4B.ConjPred bm) -> do
          let
            eval' :: (W4.Pred sym, BM.Polarity) -> m (W4.Pred sym)
            eval' (x, BM.Positive) = return x
            eval' (x, BM.Negative) = liftIO $ W4.notPred sym x

            eval :: (W4.Pred sym, W4.Pred sym) -> (W4.Pred sym, BM.Polarity) -> m (W4.Pred sym, W4.Pred sym)
            eval (asms', p') atom = do
              atom' <- eval' atom
              test <- liftIO $ W4.impliesPred sym asms' atom'
              provable test >>= \case
                True -> return $ (asms', p')
                False -> do
                  atom'' <- go foldDir asms' atom'
                  p'' <- liftIO $ W4.andPred sym p' atom''
                  asms'' <- liftIO $ W4.andPred sym asms' p''
                  return (asms'', p'')
          case BM.viewBoolMap bm of
            BM.BoolMapUnit -> return $ W4.truePred sym
            BM.BoolMapDualUnit -> return $ W4.falsePred sym
            BM.BoolMapTerms (t:|ts) -> case foldDir of
              ConjunctFoldRight -> snd <$> foldrM (\a b -> eval b a) (asms, W4.truePred sym) (t:ts)
              ConjunctFoldLeft ->  snd <$> foldlM eval (asms, W4.truePred sym) (t:ts)

        Just (W4B.NotPred p') -> do
          p'' <- go foldDir asms p'
          if p' == p'' then return p
            else liftIO $ W4.notPred sym p''
        _ -> return p
  p <- go ConjunctFoldRight (W4.truePred sym) p_outer
  go ConjunctFoldLeft (W4.truePred sym) p


setProgramLoc ::
  forall m sym t solver fs tp.
  IO.MonadIO m =>
  sym ~ (W4B.ExprBuilder t solver fs) =>
  sym ->
  W4.SymExpr sym tp ->
  m ()
setProgramLoc sym e = case W4PL.plSourceLoc (W4B.exprLoc e) of
  W4PL.InternalPos -> return ()
  _ -> liftIO $ W4.setCurrentProgramLoc sym (W4B.exprLoc e)

data Tagged w f tp where
  Tagged :: w -> f tp -> Tagged w f tp

-- | Cached evaluation that retains auxiliary results
idxCacheEvalWriter ::
  MonadIO m =>
  CMW.MonadWriter w m =>
  W4B.IdxCache t (Tagged w f) ->
  W4B.Expr t tp ->
  m (f tp) ->
  m (f tp)
idxCacheEvalWriter cache e f = do
  Tagged w result <- W4B.idxCacheEval cache e $ do
    (result, w) <- CMW.listen $ f
    return $ Tagged w result
  CMW.tell w
  return result
