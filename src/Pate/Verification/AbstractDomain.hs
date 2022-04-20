{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Pate.Verification.AbstractDomain
  ( AbstractDomain
  , AbstractDomainBody(..)
  , AbsRange(..)
  , getAbsDomainVals
  , applyAbsDomainVals
  ) where

import           Control.Monad ( forM, unless )
import qualified Control.Monad.IO.Class as IO
import qualified Control.Monad.Writer as CMW

import           Data.Functor.Const
import qualified Data.Set as S
import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.Some
import           Data.Parameterized.Classes
import qualified Data.BitVector.Sized as BV
import qualified Data.Parameterized.TraversableFC as TFC

import qualified What4.Utils.AbstractDomains as WAbs
import qualified What4.Interface as W4
import qualified What4.Expr.Builder as W4B
import qualified What4.Symbol as W4S

import qualified Lang.Crucible.LLVM.MemModel as CLM
import qualified Lang.Crucible.Simulator as CS
import qualified Lang.Crucible.Types as CT

import qualified Data.Macaw.CFG.Core as MC
import qualified Data.Macaw.CFG as MM
import qualified Data.Macaw.Symbolic as MS
import qualified Data.Macaw.Types as MT

import qualified Pate.Arch as PA
import qualified Pate.Binary as PB
import qualified Pate.SimulatorRegisters as PSR
import qualified Pate.Equivalence as PE
import qualified Pate.Equivalence.EquivalenceDomain as PED
import qualified Pate.MemCell as PMC
import qualified Pate.PatchPair as PPa
import qualified Pate.SimState as PS
import qualified Pate.Memory.MemTrace as MT
import qualified Pate.Register.Traversal as PRt

-- | Defining abstract domains which propagate forwards during strongest
-- postcondition analysis.
-- The critical domain information is the equality domain (a 'PED.EquivalenceDomain'
-- indicating which memory locations are equivalent between the original and patched programs)
-- Additional information constraining viable values is also stored independently for each
-- program in 'AbstractDomainVals'

type AbstractDomain sym arch = PS.SimSpec sym arch (AbstractDomainBody sym arch)

data AbstractDomainBody sym arch where
  AbstractDomainBody ::
    { absDomEq :: PED.EquivalenceDomain sym arch
      -- ^ specifies which locations are equal between the original vs. patched programs
    , absDomVals :: PPa.PatchPair (AbstractDomainVals sym arch)
      -- ^ specifies independent constraints on the values for the original and patched programs
    } -> AbstractDomainBody sym arch


data AbsRange (tp :: W4.BaseType) where
  AbsIntConstant :: Integer -> AbsRange W4.BaseIntegerType
  AbsBVConstant :: 1 W4.<= w => W4.NatRepr w -> BV.BV w -> AbsRange (W4.BaseBVType w)
  AbsBoolConstant :: Bool -> AbsRange W4.BaseBoolType
  AbsUnconstrained :: W4.BaseTypeRepr tp -> AbsRange tp

absRangeRepr :: AbsRange tp -> W4.BaseTypeRepr tp
absRangeRepr r = case r of
  AbsIntConstant{} -> W4.BaseIntegerRepr
  AbsBVConstant w _ -> W4.BaseBVRepr w
  AbsBoolConstant{} -> W4.BaseBoolRepr
  AbsUnconstrained repr -> repr


instance TestEquality AbsRange where
  testEquality r1 r2 = case (r1, r2) of
    (AbsIntConstant i1, AbsIntConstant i2) | i1 == i2 -> Just Refl
    (AbsBVConstant w1 bv1, AbsBVConstant w2 bv2)
      | Just Refl <- testEquality w1 w2, bv1 == bv2 -> Just Refl
    (AbsBoolConstant b1, AbsBoolConstant b2) | b1 == b2 -> Just Refl
    (AbsUnconstrained repr1, AbsUnconstrained repr2) -> testEquality repr1 repr2
    _ -> Nothing

instance Eq (AbsRange tp) where
  r1 == r2 = case testEquality r1 r2 of
    Just Refl -> True
    Nothing -> False

-- | Combine abstract ranges. Currently ranges only specify equality, and so when combining
-- they either agree on the same value, or they collapse to an unconstrained value
combineAbsRanges :: AbsRange tp -> AbsRange tp -> AbsRange tp
combineAbsRanges r1 r2 = if r1 == r2 then r1 else AbsUnconstrained (absRangeRepr r1)

data MacawAbstractValue sym (tp :: MT.Type) where
  MacawAbstractValue ::
      { macawAbsVal :: Ctx.Assignment AbsRange (PSR.CrucBaseTypes (MS.ToCrucibleType tp))
      }
      -> MacawAbstractValue sym tp
  deriving Eq

data MemAbstractValue sym w where
  MemAbstractValue :: (MacawAbstractValue sym (MT.BVType (8 W4.* w))) -> MemAbstractValue sym w

data AbstractDomainVals sym arch (bin :: PB.WhichBinary) where
  AbstractDomainVals ::
    { absRegVals :: MM.RegState (MM.ArchReg arch) (MacawAbstractValue sym)
    , absMemVals :: MapF.MapF (PMC.MemCell sym arch) (MemAbstractValue sym)
    } -> AbstractDomainVals sym arch bin
  -- | A "bottom" domain is maximally constrained and can never be satisfied
  AbstractDomainValsBottom :: AbstractDomainVals sym arch bin
  -- | A "top" domain contains no information and is trivially satisfied
  AbstractDomainValsTop :: AbstractDomainVals sym arch bin  
  

combineAbsVals ::
  MacawAbstractValue sym tp ->
  MacawAbstractValue sym tp ->
  MacawAbstractValue sym tp
combineAbsVals abs1 abs2 = MacawAbstractValue $
  Ctx.zipWith combineAbsRanges (macawAbsVal abs1) (macawAbsVal abs2)

isUnconstrained ::
  MacawAbstractValue sym tp -> Bool
isUnconstrained absv = TFC.foldrFC (\v b -> b && case v of { AbsUnconstrained{} -> True; _ -> False} ) True (macawAbsVal absv)


getAbsVal ::
  Monad m =>
  IO.MonadIO m =>
  W4.IsExprBuilder sym =>
  sym ->
  (forall tp'. W4.SymExpr sym tp' -> m (AbsRange tp')) ->
  PSR.MacawRegEntry sym tp ->
  m (MacawAbstractValue sym tp)
getAbsVal sym f e = case PSR.macawRegRepr e of
  CLM.LLVMPointerRepr{} -> do
    CLM.LLVMPointer region offset <- return $ PSR.macawRegValue e
    regAbs <- (IO.liftIO $ W4.natToInteger sym region) >>= f
    offsetAbs <- f offset
    return $ MacawAbstractValue (Ctx.Empty Ctx.:> regAbs Ctx.:> offsetAbs)
  CT.BoolRepr -> do
    bAbs <- f (PSR.macawRegValue e)
    return $ MacawAbstractValue (Ctx.Empty Ctx.:> bAbs)
  CT.StructRepr Ctx.Empty -> return $ MacawAbstractValue Ctx.Empty
  _ -> error "getAbsVal: unexpected type for abstract domain"

-- FIXME: clagged from Widening module
data RelaxLocs sym arch =
  RelaxLocs
    (S.Set (Some (MM.ArchReg arch)))
    (S.Set (Some (PMC.MemCell sym arch)))

instance (OrdF (W4.SymExpr sym), PA.ValidArch arch) => Semigroup (RelaxLocs sym arch) where
  (RelaxLocs r1 m1) <> (RelaxLocs r2 m2) = RelaxLocs (r1 <> r2) (m1 <> m2)

instance (OrdF (W4.SymExpr sym), PA.ValidArch arch) => Monoid (RelaxLocs sym arch) where
  mempty = RelaxLocs mempty mempty

-- | From the result of symbolic execution (in 'PS.SimOutput') we extract any abstract domain
-- information that we can establish for the registers, memory reads and memory writes
getAbsDomainVals ::
  forall sym arch bin m.
  Monad m =>
  IO.MonadIO m =>
  W4.IsSymExprBuilder sym =>
  PA.ValidArch arch =>
  sym ->
  AbstractDomainVals sym arch bin {- ^ existing abstract domain that this is augmenting -} ->
  (forall tp. W4.SymExpr sym tp -> m (AbsRange tp)) ->
  PS.SimOutput sym arch bin ->
  m (AbstractDomainVals sym arch bin, RelaxLocs sym arch)
getAbsDomainVals sym prev f stOut = case prev of
  AbstractDomainValsTop -> return (AbstractDomainValsTop, mempty)
  -- for a "bottom" domain we look at the simulator output to find any writes in order
  -- to construct a less constrained domain
  AbstractDomainValsBottom -> do
    foots <- fmap S.toList $ IO.liftIO $ MT.traceFootprint sym (PS.simOutMem stOut)
    let cells = map (\(MT.MemFootprint ptr w _dir _cond end) -> Some (PMC.MemCell ptr w end)) foots
    memVals <- fmap MapF.fromList $ forM cells $ \(Some cell) -> do
      absVal <- getMemAbsVal cell
      return (MapF.Pair cell absVal)
    regVals <- MM.traverseRegsWith (\_ v ->  getAbsVal sym f v) (PS.simOutRegs stOut)
    let locs = RelaxLocs (S.fromList $ MM.archRegs) (S.fromList $ MapF.keys memVals)
    return (AbstractDomainVals regVals memVals, locs)
  -- if we have a previous domain, we need to check that the new values agree with
  -- the previous ones, and drop/merge any overlapping domains
  AbstractDomainVals{} -> CMW.runWriterT $ do
    memVals <- MapF.traverseMaybeWithKey relaxMemVal (absMemVals prev)
    regVals <- PRt.zipWithRegStatesM (absRegVals prev) (PS.simOutRegs stOut) relaxRegVal
    return $ AbstractDomainVals regVals memVals

  where
    getMemAbsVal ::
      PMC.MemCell sym arch w ->
      m (MemAbstractValue sym w)
    getMemAbsVal cell = do
      val <- IO.liftIO $ PMC.readMemCell sym (MT.memState $ PS.simOutMem stOut) cell
      MemAbstractValue <$> getAbsVal sym f (PSR.ptrToEntry val)

    relaxMemVal ::
      PMC.MemCell sym arch w ->
      MemAbstractValue sym w ->
      CMW.WriterT (RelaxLocs sym arch) m (Maybe (MemAbstractValue sym w))
    relaxMemVal cell (MemAbstractValue absValPrev) = do
      MemAbstractValue absValNew <- CMW.lift $ getMemAbsVal cell
      let absValCombined = combineAbsVals absValNew absValPrev
      unless (absValCombined == absValPrev) $ CMW.tell (RelaxLocs mempty (S.singleton (Some cell)))
      case isUnconstrained absValCombined of
        True -> return Nothing
        False -> return $ Just $ MemAbstractValue absValCombined
        
    relaxRegVal ::
      MM.ArchReg arch tp ->
      MacawAbstractValue sym tp {- ^ previous abstract value -} ->
      PSR.MacawRegEntry sym tp ->
      CMW.WriterT (RelaxLocs sym arch) m (MacawAbstractValue sym tp)
    relaxRegVal reg absValPrev v = do
      absValNew <- CMW.lift $ getAbsVal sym f v
      let absValCombined = combineAbsVals absValNew absValPrev
      unless (absValCombined == absValPrev) $ CMW.tell (RelaxLocs (S.singleton (Some reg)) mempty)
      return absValCombined

applyAbsRange ::
  W4.IsSymExprBuilder sym =>
  sym ->
  W4.SymExpr sym tp ->
  AbsRange tp ->
  IO (PS.AssumptionFrame sym)
applyAbsRange sym e rng = case rng of
  AbsIntConstant i -> do
    i' <- W4.intLit sym i
    return $ PS.exprBinding e i'
  AbsBVConstant w bv -> do
    bv' <- W4.bvLit sym w bv
    return $ PS.exprBinding e bv'
  AbsBoolConstant True -> return $ PS.exprBinding e (W4.truePred sym)
  AbsBoolConstant False -> return $ PS.exprBinding e (W4.falsePred sym)
  AbsUnconstrained{} -> return mempty

applyAbsDomainVal ::
  W4.IsSymExprBuilder sym =>
  sym ->
  PSR.MacawRegEntry sym tp ->
  MacawAbstractValue sym tp ->
  IO (PS.AssumptionFrame sym)
applyAbsDomainVal sym e (MacawAbstractValue absVal) = case PSR.macawRegRepr e of
  CLM.LLVMPointerRepr{} -> do
    CLM.LLVMPointer region offset <- return $ PSR.macawRegValue e
    (Ctx.Empty Ctx.:> regAbs Ctx.:> offsetAbs) <- return $ absVal
    regionInt <- W4.natToInteger sym region
    regFrame <- applyAbsRange sym regionInt regAbs
    offFrame <- applyAbsRange sym offset offsetAbs
    return $ regFrame <> offFrame
  CT.BoolRepr -> do
    b <- return $ PSR.macawRegValue e
    (Ctx.Empty Ctx.:> bAbs) <- return $ absVal
    applyAbsRange sym b bAbs
  CT.StructRepr Ctx.Empty -> return mempty
  _ -> error "applyAbsDomainVal: unexpected type for abstract domain"


-- | Construct an 'PS.AssumptionFrame' asserting
-- that the values in the given initial state
-- ('PS.SimInput') are necessarily in the given abstract domain
applyAbsDomainVals ::
  forall sym arch bin.
  W4.IsSymExprBuilder sym =>
  MapF.OrdF (W4.SymExpr sym) =>
  MC.RegisterInfo (MC.ArchReg arch) =>
  sym ->
  PS.SimInput sym arch bin ->
  AbstractDomainVals sym arch bin ->
  IO (PS.AssumptionFrame sym)
applyAbsDomainVals sym stIn vals = do
  memFrame <- MapF.foldrMWithKey getCell mempty (absMemVals vals)
  regFrame <- fmap PRt.collapse $ PRt.zipWithRegStatesM (PS.simInRegs stIn) (absRegVals vals) $ \_ val absVal ->
    Const <$> applyAbsDomainVal sym val absVal
  return $ memFrame <> regFrame
  where
    getCell ::
      PMC.MemCell sym arch w ->
      MemAbstractValue sym w ->
      PS.AssumptionFrame sym ->
      IO (PS.AssumptionFrame sym)
    getCell cell (MemAbstractValue absVal) frame = do
      val <- IO.liftIO $ PMC.readMemCell sym (MT.memState $ PS.simInMem stIn) cell
      frame' <- applyAbsDomainVal sym (PSR.ptrToEntry val) absVal
      return $ frame <> frame'

    
