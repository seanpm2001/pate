{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}

-- must come after TypeFamilies, see also https://gitlab.haskell.org/ghc/ghc/issues/18006
{-# LANGUAGE NoMonoLocalBinds #-}

module Pate.Verification
  ( verifyPairs
  , mkIPEquivalence
  ) where

import           Prelude hiding ( fail )

import           GHC.Stack
import           Data.Typeable
import           Data.Bits
import           Control.Monad.Trans.Except
import           Control.Monad.Trans.Maybe
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Exception

import           Control.Applicative
import           Control.Lens hiding ( op, pre )
import           Control.Monad.Except
import           Control.Monad.IO.Class ( liftIO )
import           Control.Monad.ST
import           Control.Monad.Writer as MW

import qualified Data.BitVector.Sized as BVS
import           Data.Foldable
import           Data.Functor.Compose
import qualified Data.IntervalMap as IM
import           Data.List
import           Data.Maybe (catMaybes)
import qualified Data.Map as M
import           Data.Word (Word64)
import           Data.Set (Set)
import qualified Data.Set as S
import           Data.String
import qualified Data.Time as TM
import           Data.Type.Equality (testEquality)
import           GHC.TypeLits
import qualified Lumberjack as LJ
import           System.IO
import qualified Data.HashTable.ST.Basic as H

import qualified Data.Macaw.BinaryLoader as MBL
import qualified Data.Macaw.CFG as MM
import qualified Data.Macaw.Discovery as MD

import qualified Data.Macaw.Symbolic as MS
import qualified Data.Macaw.Types as MM


import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.Nonce as N
import           Data.Parameterized.Some
import qualified Data.Parameterized.TraversableFC as TFC
import qualified Data.Parameterized.TraversableF as TF
import qualified Data.Parameterized.Map as MapF


import qualified Lang.Crucible.Backend as CB
import qualified Lang.Crucible.Backend.Online as CBO
import qualified Lang.Crucible.CFG.Core as CC
import qualified Lang.Crucible.FunctionHandle as CFH
import qualified Lang.Crucible.LLVM.MemModel as CLM
import qualified Lang.Crucible.Simulator as CS
import qualified Lang.Crucible.Simulator.GlobalState as CGS

import qualified What4.Expr.Builder as W4B
import qualified What4.SemiRing as SR

import qualified What4.Expr.GroundEval as W4G
import qualified What4.Interface as W4
import qualified What4.Partial as W4P
import qualified What4.ProblemFeatures as W4PF
import qualified What4.ProgramLoc as W4L
import qualified What4.Protocol.Online as W4O
--import qualified What4.Protocol.SMTWriter as W4O
import qualified What4.SatResult as W4R
--import qualified What4.Protocol.SMTLib2 as SMT2

import qualified Pate.Binary as PB
import qualified Pate.Event as PE
import           Pate.Types
import           Pate.Monad
import qualified Pate.Memory.MemTrace as MT

import qualified What4.Config as W4C
import qualified Data.Text as T

verifyPairs ::
  forall arch.
  ValidArch arch =>
  LJ.LogAction IO (PE.Event arch) ->
  PB.LoadedELF arch ->
  PB.LoadedELF arch ->
  BlockMapping arch ->
  DiscoveryConfig ->
  [PatchPair arch] ->
  ExceptT (EquivalenceError arch) IO Bool
verifyPairs logAction elf elf' blockMap dcfg pPairs = do
  Some gen <- liftIO . stToIO $ N.newSTNonceGenerator
  vals <- case MS.genArchVals (Proxy @MT.MemTraceK) (Proxy @arch) of
    Nothing -> throwError $ equivalenceError UnsupportedArchitecture
    Just vs -> pure vs
  ha <- liftIO CFH.newHandleAllocator
  (oMain, oPfm)  <- runDiscovery elf
  (pMain, pPfm) <- runDiscovery elf'

  liftIO $ LJ.writeLog logAction (PE.LoadedBinaries (elf, oPfm) (elf', pPfm))

  Some gen' <- liftIO N.newIONonceGenerator
  let pfeats = W4PF.useBitvectors .|. W4PF.useSymbolicArrays .|. W4PF.useIntegerArithmetic .|. W4PF.useStructs
  CBO.withYicesOnlineBackend W4B.FloatRealRepr gen' CBO.NoUnsatFeatures pfeats $ \sym -> do
    let cfg = W4.getConfiguration sym
    pathSetter <- liftIO $ W4C.getOptionSetting CBO.solverInteractionFile cfg
    [] <- liftIO $ W4C.setOpt pathSetter (T.pack "./solver.out")
    proc <- liftIO $ CBO.withSolverProcess sym (fail "invalid") return

    
    eval <- lift (MS.withArchEval vals sym pure)
    model <- lift (MT.mkMemTraceVar @arch ha)
    evar <- lift (MT.mkExitClassVar @arch ha)
    pvar <- lift (MT.mkReturnIPVar @arch ha)

    -- FIXME: we should be able to lift this from the ELF, and it may differ between
    -- binaries
    stackRegion <- liftIO $ W4.natLit sym 1
    let
      exts = MT.macawTraceExtensions eval model evar pvar (trivialGlobalMap @_ @arch)

      oCtx = BinaryContext
        { binary = PB.loadedBinary elf
        , parsedFunctionMap = oPfm
        , binEntry = oMain
        }
      rCtx = BinaryContext
        { binary = PB.loadedBinary elf'
        , parsedFunctionMap = pPfm
        , binEntry = pMain
        }
      ctxt = EquivalenceContext
        { nonces = gen
        , handles = ha
        , exprBuilder = sym
        , originalCtx = oCtx
        , rewrittenCtx = rCtx
        
        }
      env = EquivEnv
        { envSym = sym
        , envProc = proc
        , envWhichBinary = Nothing
        , envCtx = ctxt
        , envArchVals = vals
        , envExtensions = exts
        , envStackRegion = stackRegion
        , envMemTraceVar = model
        , envExitClassVar = evar
        , envReturnIPVar = pvar
        , envBlockMapping = buildBlockMap pPairs blockMap
        , envLogger = logAction
        , envDiscoveryCfg = dcfg
        , envFreeVars = []
        }

    liftIO $ do
      putStr "\n"
      stats <- runVerificationLoop env pPairs
      liftIO . putStr $ ppEquivalenceStatistics stats
      return $ equivSuccess stats

data RegisterCase arch tp where
  RegIP :: RegisterCase arch (MM.BVType (MM.ArchAddrWidth arch))
  RegSP :: RegisterCase arch (MM.BVType (MM.ArchAddrWidth arch))
  RegG :: RegisterCase arch tp

registerCase ::
  forall arch tp.
  ValidArch arch =>
  MM.ArchReg arch tp ->
  RegisterCase arch tp
registerCase r = case testEquality r (MM.ip_reg @(MM.ArchReg arch)) of
  Just Refl -> RegIP
  _ -> case testEquality r (MM.sp_reg @(MM.ArchReg arch)) of
    Just Refl -> RegSP
    _ -> RegG

exactRegisterEquivalence ::
  forall sym arch.
  Maybe (PatchPair arch) ->
  SimState sym arch Original ->
  SimState sym arch Patched ->
  EquivM sym arch (M.Map (Some (MM.ArchReg arch)) (W4.Pred sym))
exactRegisterEquivalence mpPair stO stP = do
  fmap M.fromList $ MW.execWriterT $ MM.traverseRegsWith_ (\r preO -> equivWriter $ do
    let
      preP = (simRegs stP)^. MM.boundValue r    
    case registerCase r of
      RegIP -> case mpPair of
        Just pPair -> do
          p <- ipValidPred pPair stO stP
          return $ [(Some r, p)]
        Nothing -> return $ []
      RegSP -> do
        p <- spValidPred stO stP
        return $ [(Some r, p)]
      RegG -> do
        regEq <- equalValues preO preP
        return [(Some r, regEq)]
    ) (simRegs stO)

topLevelRegisterEquivalence ::
  forall sym arch.
  SimState sym arch Original ->
  SimState sym arch Patched ->
  EquivM sym arch (M.Map (Some (MM.ArchReg arch)) (W4.Pred sym))
topLevelRegisterEquivalence stO stP = do
  case toc_reg @arch of
    Just r -> do
      let
        preO = (simRegs stO)^. MM.boundValue r
        preP = (simRegs stP)^. MM.boundValue r
      regEq <- equalValues preO preP
      return $ M.singleton (Some r) regEq
    Nothing -> return M.empty

exactEquivalenceSpec ::
  Maybe (PatchPair arch) ->
  EquivM sym arch (EquivRelationSpec sym arch)
exactEquivalenceSpec mpPair = withSym $ \sym -> do
  withFreshVars $ \stO stP -> do
    regsEq <- exactRegisterEquivalence mpPair stO stP
    return $ (W4.truePred sym, EquivRelationEqMem (W4.truePred sym) regsEq)

topLevelEquivalenceSpec ::
  EquivM sym arch (EquivRelationSpec sym arch)
topLevelEquivalenceSpec = withSym $ \sym -> do
  withFreshVars $ \stO stP -> do
    regsEq <- topLevelRegisterEquivalence stO stP
    return $ (W4.truePred sym, EquivRelationEqMem (W4.truePred sym) regsEq)

-- | Verify equivalence of the given pairs, as well as any
-- resulting pairs that emerge
runVerificationLoop ::
  forall sym arch.
  EquivEnv sym arch ->
  [PatchPair arch] ->
  IO EquivalenceStatistics
runVerificationLoop env pPairs = do
  let
    st = EquivState
          { stOpenTriples = M.empty
          , stProvenTriples = M.empty
          , stSimResults = M.empty
          , stFailedTriples = M.empty
          }
  result <- runExceptT $ runEquivM env st doVerify
  case result of
    Left err -> withValidEnv env $ error (show err)
    Right r -> return r

  where
    doVerify :: EquivM sym arch EquivalenceStatistics
    doVerify = do
      pPairs' <- (asks $ cfgPairMain . envDiscoveryCfg) >>= \case
        True -> do
          mainO <- asks $ binEntry . originalCtx . envCtx
          mainP <- asks $ binEntry . rewrittenCtx . envCtx
          blkO <- mkConcreteBlock BlockEntryInitFunction <$> segOffToAddr mainO
          blkP <- mkConcreteBlock BlockEntryInitFunction <$> segOffToAddr mainP
          let pPair = PatchPair blkO blkP
          return $ pPair : pPairs
        False -> return pPairs
      forM_ pPairs' $ \pPair -> do
        precond <- exactEquivalenceSpec (Just pPair)
        postcond <- topLevelEquivalenceSpec
        
        modify $ \st -> st { stOpenTriples = M.insertWith (++) pPair [(precond, postcond)] (stOpenTriples st) }
      checkLoop mempty

    popMap pPair = M.insertLookupWithKey (\_ [] trips -> drop 1 trips) pPair []

    -- | Keep checking for open block pairs
    checkLoop :: EquivalenceStatistics -> EquivM sym arch EquivalenceStatistics
    checkLoop stats = do
      openTriples <- gets stOpenTriples
      case M.keys openTriples of
        (pPair : _) -> case popMap pPair openTriples of
          (Just ((precond, postcond) : _), openTriples') -> do
            stats' <- go pPair precond postcond
            modify $ \st -> st { stOpenTriples = openTriples' }
            checkLoop (stats' <> stats)
          _ -> do
            modify $ \st -> st { stOpenTriples = M.delete pPair (stOpenTriples st) }
            checkLoop stats
        _ -> return stats

    go ::
      PatchPair arch ->
      EquivRelationSpec sym arch ->
      EquivRelationSpec sym arch ->
      EquivM sym arch EquivalenceStatistics
    go pPair precond postcond = do
      
      result <- manifestError $ checkEquivalence pPair precond postcond
      case result of
        Left _ -> modify $ \st -> st { stFailedTriples = M.insertWith (++) pPair [(precond, postcond)] (stFailedTriples st) }
        Right _ -> modify $ \st -> st { stProvenTriples = M.insertWith (++) pPair [(precond, postcond)] (stProvenTriples st) }
      printResult result
      normResult <- return $ case result of
        Left err | InequivalentError _ <- errEquivError err -> EquivalenceStatistics 1 0 0
        Left _ -> EquivalenceStatistics 1 0 1
        Right _ -> EquivalenceStatistics 1 1 0
      return normResult


printPreamble :: PatchPair arch -> EquivM sym arch ()
printPreamble pPair = liftIO $ putStr $ ""
    ++ "Checking equivalence of "
    ++ ppBlock (pOrig pPair)
    ++ " and "
    ++ ppBlock (pPatched pPair)
    ++ " (" ++ ppBlockEntry (concreteBlockEntry (pOrig pPair)) ++ ") "
    ++ ": "

ppBlockEntry :: BlockEntryKind arch -> String
ppBlockEntry be = case be of
  BlockEntryInitFunction -> "function entry point"
  BlockEntryPostFunction -> "intermediate function point"
  BlockEntryPostArch -> "intermediate function point (after syscall)"
  BlockEntryJump -> "unknown program point"

printResult :: Either (EquivalenceError arch) () -> EquivM sym arch ()
printResult (Left err) = liftIO $ putStr . ppEquivalenceError $ err
printResult (Right ()) = liftIO $ putStr "✓\n"


freshSimVars ::
  forall bin sym arch.
  EquivM sym arch (SimVars sym arch bin)
freshSimVars = do
  (memtrace, memtraceVar) <- withSymIO $ \sym -> MT.initMemTraceVar sym (MM.addrWidthRepr (Proxy @(MM.ArchAddrWidth arch)))
  regs <- MM.mkRegStateM unconstrainedRegister
  return $ SimVars memtraceVar regs (SimState memtrace (MM.mapRegsWith (\_ -> macawVarEntry) regs))

getGlobals ::
  forall sym arch bin.
  SimInput sym arch bin ->
  EquivM sym arch (CS.SymGlobalState sym)
getGlobals simInput = do
  env <- ask
  ret <- withSymIO $ MT.initRetAddr @_ @arch
  eclass <- withSymIO $ MT.initExitClass
  withValid $ return $
      CGS.insertGlobal (envMemTraceVar env) (simInMem simInput)
    $ CGS.insertGlobal (envReturnIPVar env) ret
    $ CGS.insertGlobal (envExitClassVar env) eclass
    $ CGS.emptyGlobals  

collapseEqRel ::
  SimBundle sym arch ->
  EquivRelation sym arch ->
  EquivM sym arch (StatePred sym arch)
collapseEqRel _ (EquivRelationPred stPred) = return stPred
collapseEqRel bundle (EquivRelationEqMem asm regsEq) = withSym $ \sym -> do
  memEq <- fmap (M.fromList . catMaybes) $ forM (S.toList $ simFootprints bundle) $ \foot@(MT.MemFootprint ptr _w dir _cond) -> do
    case dir of
      MT.Write -> do
        p <- liftIO $ MT.equalAt sym (\res -> MT.llvmPtrEq sym (MT.resOVal res) (MT.resPVal res))
          (simOutMem $ simOutO bundle) (simOutMem $ simOutP bundle) foot
        return $ Just (ArchPtr ptr, p)
      MT.Read -> return Nothing
  liftIO $ implyExpr sym asm $ StatePred regsEq memEq


ipValidPred ::
  forall sym arch.
  PatchPair arch ->
  SimState sym arch Original ->
  SimState sym arch Patched ->
  EquivM sym arch (W4.Pred sym)
ipValidPred pPair stO stP = withSymIO $ \sym -> do
  let
    regsO = simRegs stO
    regsP = simRegs stP
  ptrO <- concreteToLLVM sym $ concreteAddress $ (pOrig pPair)
  eqO <- MT.llvmPtrEq sym ptrO (macawRegValue $ regsO ^. MM.boundValue (MM.ip_reg @(MM.ArchReg arch)))

  ptrP <- concreteToLLVM sym $ concreteAddress $ (pPatched pPair)
  eqP <- MT.llvmPtrEq sym ptrP (macawRegValue $ regsP ^. MM.boundValue (MM.ip_reg @(MM.ArchReg arch)))
  W4.andPred sym eqO eqP

spValidPred ::
  forall sym arch.
  SimState sym arch Original ->
  SimState sym arch Patched ->
  EquivM sym arch (W4.Pred sym)
spValidPred stO stP = withSym $ \sym -> do
  let
    regsO = simRegs stO
    regsP = simRegs stP
    CLM.LLVMPointer regionO offO = (macawRegValue $ regsO ^. MM.boundValue (MM.sp_reg @(MM.ArchReg arch)))
    CLM.LLVMPointer regionP offP = (macawRegValue $ regsP ^. MM.boundValue (MM.sp_reg @(MM.ArchReg arch)))
  stackRegion <- asks envStackRegion
  preds <- liftIO $ do
    eqO <-  W4.isEq sym regionO stackRegion
    eqP <- W4.isEq sym regionP stackRegion
    eqOffs <- W4.isEq sym offO offP
    return [eqOffs, eqO, eqP]
  allPreds preds
  
allPreds ::
  [W4.Pred sym] ->
  EquivM sym arch (W4.Pred sym)
allPreds preds = withSymIO $ \sym -> foldM (W4.andPred sym) (W4.truePred sym) preds

eqRelPrecond ::
  forall sym arch.
  PatchPair arch ->
  SimState sym arch Original ->
  SimState sym arch Patched ->
  EquivRelation sym arch ->
  EquivM sym arch (W4.Pred sym)
eqRelPrecond pPair stO stP = \case
  EquivRelationEqMem asm regsEqMap -> withSym $ \sym -> do
    let
      memO = simMem stO
      memP = simMem stP

    memEq <- liftIO $ W4.isEq sym (MT.memArr memO) (MT.memArr memP)
    regsEq <- liftIO $ foldM (W4.andPred sym) (W4.truePred sym) (M.elems regsEqMap)

    eqIPs <- ipValidPred pPair stO stP
    validSp <- spValidPred stO stP

    eqRels <- allPreds [memEq, regsEq, eqIPs, validSp]
    liftIO $ W4.impliesPred sym asm eqRels
  EquivRelationPred stPred -> flattenStatePred stPred
  
flattenStatePred ::
  StatePred sym arch ->
  EquivM sym arch (W4.Pred sym)
flattenStatePred stPred = withSymIO $ \sym -> do
  foldM (W4.andPred sym) (W4.truePred sym) ((M.elems (predRegs stPred)) ++ (M.elems (predMem stPred)))

-- bindFunctionFrames ::
--   FunctionFrame sym arch bin ->
--   FunctionFrame sym arch bin ->
--   EquivM sym arch (FunctionFrame sym arch bin)
-- bindFunctionFrames fn1 fn2 = withSym $ \sym -> do
--   -- reads from fn2 that are written by fn1 are "shadowed" and we can safely drop them
--   let
--     regReads r = do      
--       read2 <- (predRegs $ fnReads fn2) r
--       write1 <- (predRegs $ fnWrites fn1) r
--       notWrite <- W4.notPred sym write1
--       read2Shadowed <- W4.impliesPred sym notWrite read2
--       W4.orPred sym read1 read2Shadowed
--     memReads ptr = do    
--       read2 <- (predMem $ fnReads fn2) ptr
--       write1 <- (predMem $ fnWrites fn1) ptr
--       notWrite <- W4.notPred sym write1
--       read2Shadowed <- W4.impliesPred sym notWrite read2
--       W4.orPred sym read1 read2Shadowed      

--     regWrites r = do
--       write1 <- (predRegs $ fnWrites fn1) r
--       write2 <- (predRegs $ fnWrites fn2) r
--       W4.orPred sym write1 write2
--     memWrites ptr = do
--       write1 <- (predMem $ fnWrites fn1) ptr
--       write2 <- (predMem $ fnWrites fn2) r ptr
--       W4.orPred sym write1 write2
      
--   return $
--     FunctionFrame
--       { fnReads = StatePred regReads memReads
--       , fnWrites = StatePred regWrites memWrites
--       }


evalStatePredReg ::
  StatePred sym arch ->
  MM.ArchReg arch tp ->
  EquivM sym arch (W4.Pred sym)
evalStatePredReg stPred reg = case M.lookup (Some reg) (predRegs stPred) of
  Just p -> return p
  Nothing -> withSym $ \sym -> return $ W4.truePred sym

evalStatePredMem ::
  StatePred sym arch ->
  CLM.LLVMPtr sym (MM.ArchAddrWidth arch) ->
  EquivM sym arch (W4.Pred sym)
evalStatePredMem stPred ptr = case M.lookup (ArchPtr ptr) (predMem stPred) of
  Just p -> return p
  Nothing -> withSym $ \sym -> return $ W4.truePred sym

andStatePreds ::
  StatePred sym arch ->
  StatePred sym arch ->
  EquivM sym arch (StatePred sym arch)
andStatePreds pred1 pred2 = do
  let
    regsMap1 = fmap mkPred (predRegs pred1)
    regsMap2 = fmap mkPred (predRegs pred2)
  regs <- sequenceA $ M.unionWith mergePreds regsMap1 regsMap2
  let
    memMap1 = fmap mkPred (predMem pred1)
    memMap2 = fmap mkPred (predMem pred2)
  mem <- sequenceA $ M.unionWith mergePreds memMap1 memMap2
  return $ StatePred regs mem
  where
    mkPred ::
      W4.Pred sym ->
      EquivM sym arch (W4.Pred sym)
    mkPred = return
    
    mergePreds ::
      EquivM sym arch (W4.Pred sym) -> 
      EquivM sym arch (W4.Pred sym) ->
      EquivM sym arch (W4.Pred sym)
    mergePreds p1 p2 = do
      p1' <- p1
      p2' <- p2
      withSymIO $ \sym -> W4.andPred sym p1' p2'

checkEquivalence ::
  PatchPair arch ->
  EquivRelationSpec sym arch ->
  EquivRelationSpec sym arch ->
  EquivM sym arch ()
checkEquivalence pPair initPrecondEqSpec postcond = withSym $ \sym -> do
  withValid @() $ liftIO $ W4B.startCaching sym
  
  genPrecondSpec <- provePostcondition pPair S.empty postcond
  
  void $ withSimSpec initPrecondEqSpec $ \stO stP initPrecondEq -> do
    initPrecond <- eqRelPrecond pPair stO stP initPrecondEq
    
    genPrecond <- liftIO $ bindSpec sym stO stP genPrecondSpec
    genPrecondFlat <- flattenStatePred genPrecond

    check <- liftIO $ W4.impliesPred sym initPrecond genPrecondFlat
    notCheck <- liftIO $ W4.notPred sym check
    
    checkSatisfiableWithModel "check" notCheck $ \case
        W4R.Sat _ -> throwHere ImpossibleEquivalence
        W4R.Unsat _ -> return ()
        W4R.Unknown -> throwHere InconclusiveSAT
  return ()

withAssumption ::
  ExprImplyable sym f =>
  W4.Pred sym ->
  EquivM sym arch f ->
  EquivM sym arch f
withAssumption asm f = withSym $ \sym -> do
  fr <- liftIO $ CB.pushAssumptionFrame sym
  addAssumption asm "withAssumption"
  a <- f
  _ <- liftIO $ CB.popAssumptionFrame sym fr
  liftIO $ implyExpr sym asm a

withSimBundle ::
  ExprMappable sym f =>
  PatchPair arch ->
  (SimBundle sym arch -> EquivM sym arch f) ->
  EquivM sym arch (SimSpec sym arch f)
withSimBundle pPair f = withSym $ \sym -> do
  results <- gets stSimResults 
  bundleSpec <- case M.lookup pPair results of
    Just bundleSpec -> return bundleSpec    
    Nothing -> do
      bundleSpec <- withFreshVars $ \stO stP -> do
        let
          simInO_ = SimInput stO (pOrig pPair)
          simInP_ = SimInput stP (pPatched pPair)
        ipValid <- ipValidPred pPair stO stP
        spValid <- spValidPred stO stP
        addAssumption ipValid "ipValid"
        addAssumption spValid "spValid"
        asm' <- allPreds [ipValid, spValid]
        simOutO_ <- simulate simInO_
        simOutP_ <- simulate simInP_
        footO <- liftIO $ MT.traceFootprint sym (MT.memSeq $ simOutMem $ simOutO_)
        footP <- liftIO $ MT.traceFootprint sym (MT.memSeq $ simOutMem $ simOutP_)
        return $ (asm', SimBundle simInO_ simInP_ simOutO_ simOutP_ (S.union footO footP))
      modify $ \st -> st { stSimResults = M.insert pPair bundleSpec (stSimResults st) }
      return bundleSpec
  withSimSpec bundleSpec $ \_ _ bundle -> f bundle

withSimSpec ::
  ExprMappable sym f =>
  SimSpec sym arch f ->
  (SimState sym arch Original -> SimState sym arch Patched -> f -> EquivM sym arch g) ->
  EquivM sym arch (SimSpec sym arch g)
withSimSpec spec f = withSym $ \sym -> do
  withFreshVars $ \stO stP -> do
    (asm, body) <- liftIO $ bindSpec' sym stO stP spec
    addAssumption asm "withSimSpec"
    result <- f stO stP body
    return $ (asm, result)

withFreshVars ::
  (SimState sym arch Original -> SimState sym arch Patched -> EquivM sym arch (W4.Pred sym, f)) ->
  EquivM sym arch (SimSpec sym arch f)
withFreshVars f = do
  varsO <- freshSimVars @Original
  varsP <- freshSimVars @Patched
  withSimVars varsO varsP $ do
    (asm, result) <- f (simVarState varsO) (simVarState varsP)
    return $ SimSpec varsO varsP asm result

-- FIXME: what4 bug fails to correctly emit axioms for Natural numbers for bound variables
initVar :: W4.BoundVar sym tp -> EquivM sym arch ()
initVar bv = withSym $ \sym -> case W4.exprType (W4.varExpr sym bv) of
  W4.BaseNatRepr -> withValid $ do
    let e = W4.varExpr sym bv
    zero <- liftIO $ W4.natLit sym 0    
    isPos <- liftIO $ W4B.sbMakeExpr sym $ W4B.SemiRingLe SR.OrderedSemiRingNatRepr zero e
    addAssumption isPos "natural numbers are positive"
  _ -> return ()

withSimVars ::
  SimVars sym arch Original ->
  SimVars sym arch Patched ->
  EquivM sym arch a ->
  EquivM sym arch a
withSimVars varsO varsP f = withProc $ \proc -> withSym $ \sym -> do
  let
    flatO = flatVars varsO
    flatP = flatVars varsP
    vars = flatO ++ flatP

  fr <- liftIO $ CB.pushAssumptionFrame sym
  a <- W4O.inNewFrameWithVars proc vars $ do
    mapM_ (\(Some var) -> initVar var) vars
    f
  _ <- liftIO $ CB.popAssumptionFrame sym fr
  return a

getFootprints ::
  SimBundle sym arch ->
  EquivM sym arch (MemFootprints sym arch)
getFootprints bundle = withSym $ \sym -> do
  footO <- liftIO $ MT.traceFootprint sym (MT.memSeq $ simOutMem $ simOutO bundle)
  footP <- liftIO $ MT.traceFootprint sym (MT.memSeq $ simOutMem $ simOutP bundle)
  return $ S.union footO footP

asMemCond ::
  ValidSym sym =>
  W4.Pred sym ->
  MT.MemOpCondition sym
asMemCond cond = case W4.asConstantPred cond of
  Just True -> MT.Unconditional
  _ -> MT.Conditional cond

addCondFootprint ::
  W4.Pred sym ->
  MT.MemFootprint sym ptrW ->
  EquivM sym arch (Maybe (MT.MemFootprint sym ptrW))
addCondFootprint condPred (MT.MemFootprint ptr w dir cond) = withSym $ \sym -> do
  condPred' <- memOpCondition cond
  condPred'' <- liftIO $ W4.andPred sym condPred condPred'
  case W4.asConstantPred condPred'' of
    Just False -> return Nothing
    _ -> return $ Just $ MT.MemFootprint ptr w dir (asMemCond condPred'')

addCondFootprints ::
  W4.Pred sym ->
  MemFootprints sym arch ->
  EquivM sym arch (MemFootprints sym arch)
addCondFootprints p foots = (S.fromList . catMaybes) <$> mapM (addCondFootprint p) (S.toList foots)

mergeFootprints ::
  MemFootprints sym arch ->
  MemFootprints sym arch ->
  EquivM sym arch (MemFootprints sym arch)
mergeFootprints foot1 foot2 = return $ S.union foot1 foot2

provePostcondition ::
  PatchPair arch ->
  MemFootprints sym arch ->
  EquivRelationSpec sym arch ->
  EquivM sym arch (StatePredSpec sym arch)
provePostcondition pPair footPrintsPre equivPostSpec = withSym $ \sym -> do
  printPreamble pPair
  liftIO $ putStr "\n"
  withSimBundle pPair $ \bundle -> provePostcondition' bundle equivPostSpec

asEqRelSpec ::
  StatePredSpec sym arch ->
  EquivRelationSpec sym arch
asEqRelSpec stPredSpec = stPredSpec { specBody = EquivRelationPred (specBody stPredSpec) }

-- | Prove that a postcondition holds for a function pair starting at
-- this address
provePostcondition' ::
  SimBundle sym arch ->
  EquivRelationSpec sym arch ->
  EquivM sym arch (StatePred sym arch)
provePostcondition' bundle equivPostSpec = withSym $ \sym -> do
  -- FIXME: we need fresh variables every time, so we can't actually
  -- use cached results currently 
  pairs <- discoverPairs bundle

  (cases, preconds) <- fmap unzip $ forM pairs $ \(blktO, blktP) -> do
    matches <- matchesBlockTarget bundle blktO blktP
    precond <- withAssumption matches $ do
      let
        blkO = targetCall blktO
        blkP = targetCall blktP
        pPair = PatchPair blkO blkP
      case (targetReturn blktO, targetReturn blktP) of
        (Just blkRetO, Just blkRetP) -> do

          precond <- withSimBundle pPair $ \bundleCall -> do
            -- equivalence condition for when this function returns
            let footPrints = S.union (simFootprints bundle) (simFootprints bundleCall) 
            precond <- provePostcondition (PatchPair blkRetO blkRetP) footPrints equivPostSpec

            case (concreteBlockEntry blkO, concreteBlockEntry blkP) of
              (BlockEntryPostArch, BlockEntryPostArch) -> do
                regsEq <- exactRegisterEquivalence Nothing (simInState $ simInO bundle) (simInState $ simInP bundle)
                return $ EquivRelationEqMem (W4.truePred sym) regsEq
              (entryO, entryP) | entryO == entryP -> do
                printPreamble pPair
                -- equivalence condition for calling this function
                EquivRelationPred <$> provePostcondition' bundleCall (asEqRelSpec precond)
              _ -> throwHere $ BlockExitMismatch


          -- equivalence condition for the function entry
          liftIO $ putStrLn "Checking exit to function call.."
          proveLocalPostcondition bundle precond

        (Nothing, Nothing) -> do
          precond <- provePostcondition (PatchPair blkO blkP) (simFootprints bundle) equivPostSpec
          proveLocalPostcondition bundle (asEqRelSpec precond)
        _ -> throwHere $ BlockExitMismatch
    return (matches, precond)
  isExitReturn <- matchingExits bundle MT.ExitReturn

  precondReturn <- isPredSat isExitReturn >>= \case
    True -> do
      liftIO $ putStrLn "Checking exit return.."
      withAssumption isExitReturn $ 
        proveLocalPostcondition bundle equivPostSpec
    False -> return $ trivialPred

  isExitUnknown <- matchingExits bundle MT.ExitUnknown
  precondUnknown <- isPredSat isExitUnknown >>= \case
    True -> do
      liftIO $ putStrLn "Checking exit unknown.."
      exactEq <- exactEquivalenceSpec Nothing
      withAssumption isExitUnknown $ 
        proveLocalPostcondition bundle exactEq
    False -> return $ trivialPred

  liftIO $ putStrLn "Confirming totality.."
  checkCasesTotal bundle (isExitReturn:isExitUnknown:cases)
  foldM andStatePreds trivialPred (precondReturn:precondUnknown:preconds)

matchingExits ::
  SimBundle sym arch ->
  MT.ExitCase ->
  EquivM sym arch (W4.Pred sym)
matchingExits bundle ecase = withSym $ \sym -> do
  case1 <- liftIO $ MT.isExitCase sym (simOutExit $ simOutO bundle) ecase
  case2 <- liftIO $ MT.isExitCase sym (simOutExit $ simOutP bundle) ecase
  liftIO $ W4.andPred sym case1 case2  

trivialPred :: StatePred sym arch
trivialPred = StatePred M.empty M.empty

-- | Ensure that the given predicates completely describe all possibilities
checkCasesTotal ::
  SimBundle sym arch ->
  [W4.Pred sym] ->
  EquivM sym arch ()
checkCasesTotal bundle cases = withSym $ \sym -> do
  somecase <- liftIO $ foldM (W4.orPred sym) (W4.falsePred sym) cases
  notSomeCase <- liftIO $ W4.notPred sym somecase
  checkSatisfiableWithModel "checkCasesTotal" notSomeCase $ \case
    W4R.Sat fn -> do
      liftIO $ putStrLn $ "cases not total"
      throwInequivalenceResult InvalidCallPair trivialPred bundle fn (\_ -> return ())
    W4R.Unsat _ -> return ()
    W4R.Unknown -> throwHere InconclusiveSAT

-- | From a given model, return a symbolic predicate
-- that equates all values that the model deems equivalent
getEquivalentReads ::
  forall sym arch.
  SymGroundEvalFn sym ->
  SimBundle sym arch ->
  EquivM sym arch (StatePred sym arch)
getEquivalentReads fn bundle = do
  regsEq <- MW.execWriterT $ MM.traverseRegsWith_ (\r preO -> equivWriter $ do
    let
      preP = (simInRegs $ simInP bundle) ^. MM.boundValue r
    case registerCase r of
      -- IP equivalence is checked elsewhere, so we don't want to bake it into the precondition
      RegIP -> return []
      RegSP -> do
        validSp <- spValidPred inStO inStP
        return [(Some r, validSp)]
      RegG -> do
        eqVals <- equalValues preO preP
        execGroundFn fn eqVals >>= \case
          True -> do
            liftIO $ putStrLn $ CC.showF r
            return [(Some r, eqVals)]
          False -> return []
    ) (simInRegs $ simInO bundle)
  memsEq <- catMaybes <$> mapM checkFootprint (S.toList $ simFootprints bundle)
  return $ StatePred (M.fromList regsEq) (M.fromList memsEq)
  where
    inStO = simInState $ simInO bundle
    inStP = simInState $ simInP bundle
    
    oMem = simInMem $ simInO bundle
    pMem = simInMem $ simInP bundle

    checkFootprint ::
      MT.MemFootprint sym (MM.ArchAddrWidth arch) ->
      EquivM sym arch (Maybe (ArchPtr sym arch, W4.Pred sym))
    checkFootprint (MT.MemFootprint ptr w MT.Read cond) = withSym $ \sym -> do
      let repr = MM.BVMemRepr w MM.BigEndian
      cond' <- memOpCondition cond
      execGroundFn fn cond' >>= \case
        True -> do
          val1 <- liftIO $ MT.readMemArr sym oMem ptr repr
          val2 <- liftIO $ MT.readMemArr sym pMem ptr repr
          valsEq <- liftIO $ MT.llvmPtrEq sym val1 val2
          execGroundFn fn valsEq >>= \case
            True -> return $ Just (ArchPtr ptr, valsEq)
            False -> return Nothing
        False -> return Nothing
    checkFootprint _ = return Nothing


liftFilterMacaw ::
  (forall tp'. W4.SymExpr sym tp' -> IO Bool) ->
  MacawRegEntry sym tp -> EquivM sym arch Bool
liftFilterMacaw f entry = do
  case macawRegRepr entry of
    CLM.LLVMPointerRepr{} -> liftIO $ do
      let CLM.LLVMPointer reg off = macawRegValue entry
      reg' <- f reg
      off' <- f off
      return $ reg' || off'
    repr -> throwHere $ UnsupportedRegisterType (Some repr)

minimizePrecondition ::
  SimBundle sym arch ->
  W4.Pred sym ->
  StatePred sym arch ->
  EquivM sym arch (StatePred sym arch)
minimizePrecondition bundle goal precond = do
  ExprFilter isBoundInGoal <- getIsBoundFilter goal
  let
    regsO = simRegs $ simInState $ simInO bundle
    regsP = simRegs $ simInState $ simInP bundle
    
  regs' <- fmap (M.fromAscList . catMaybes) $ forM (M.toAscList (predRegs precond)) $ \(Some reg, p) -> do
    let
      valO = regsO ^. MM.boundValue reg
      valP = regsP ^. MM.boundValue reg
    isInO <- liftFilterMacaw isBoundInGoal valO
    isInP <- liftFilterMacaw isBoundInGoal valP      
    case isInO || isInP of
      True -> do
        return $ Just (Some reg, p)
      False -> return Nothing
  return $ precond { predRegs = regs' }

isPredSat ::
  W4.Pred sym ->
  EquivM sym arch Bool
isPredSat p = case W4.asConstantPred p of
  Just b -> return b
  Nothing -> checkSatisfiableWithModel "check" p $ \case
    W4R.Sat _ -> return True
    W4R.Unsat _ -> return False
    W4R.Unknown -> throwHere InconclusiveSAT

validInitState ::
  SimBundle sym arch ->
  EquivM sym arch (W4.Pred sym)
validInitState bundle = withSym $ \sym -> do
  let
    stO = simInState $ simInO bundle
    stP = simInState $ simInP bundle
  ipValid <- ipValidPred (simPair bundle) stO stP
  spValid <- spValidPred stO stP
  liftIO $ W4.andPred sym ipValid spValid

-- | Prove a local postcondition for a single block slice
proveLocalPostcondition ::
  SimBundle sym arch ->
  StatePredSpec sym arch ->
  EquivM sym arch (StatePred sym arch)
proveLocalPostcondition bundle equivPostSpec = withSym $ \sym -> do
  --isPredSat asm >>= \case
  --  True -> return ()
  --  False -> throwHere AssumedFalse
  
  equivPost <- liftIO $ bindSpec sym (simOutState $ simOutO bundle) (simOutState $ simOutP bundle) equivPostSpec
  postcond <- collapseEqRel bundle equivPost

  validExits <- liftIO $ do
    let
      MT.ExitClassifyImpl exitO = simOutExit $ simOutO bundle
      MT.ExitClassifyImpl exitP = simOutExit $ simOutP bundle
    W4.isEq sym exitO exitP

  flatPostcond <- flattenStatePred postcond
  fullPostcond <- liftIO $ W4.andPred sym flatPostcond validExits

  meqInputs <- checkSatisfiableWithModel "check" fullPostcond $ \case
      W4R.Sat fn -> do
        Just <$> getEquivalentReads fn bundle
      -- if we cannot possibly satisfy this postcondition then these functions
      -- are certainly not equivalent
      W4R.Unsat _ -> return Nothing
      W4R.Unknown -> throwHere InconclusiveSAT
  
  eqInputs <- case meqInputs of
    Just eqInputs -> return eqInputs
    Nothing -> do
      liftIO $ putStrLn $ "Block diverge completely"
      precond <- exactEquivalence (simInO bundle) (simInP bundle)
      checks <- liftIO $ W4.impliesPred sym precond fullPostcond
      notChecks <- liftIO $ W4.notPred sym checks

      checkSatisfiableWithModel "check" notChecks $ \case
        W4R.Sat fn -> do
          throwInequivalenceResult PostRelationUnsat postcond bundle fn (\_ -> return ())
        W4R.Unsat _ -> throwHere ImpossibleEquivalence
        W4R.Unknown -> throwHere InconclusiveSAT

  --minEqInputs <- minimizePrecondition bundle fullPostcond eqInputs
  flatEqReads <- flattenStatePred eqInputs

  checks <- liftIO $ W4.impliesPred sym flatEqReads fullPostcond
  notChecks <- liftIO $ W4.notPred sym checks
  CC.Some (Compose opbs) <- lookupBlocks blkO
  let oBlocks = PE.Blocks (concreteAddress blkO) opbs
  CC.Some (Compose ppbs) <- lookupBlocks blkP
  let pBlocks = PE.Blocks (concreteAddress blkP) ppbs

  startedAt <- liftIO TM.getCurrentTime
  checkSatisfiableWithModel "check" notChecks $ \satRes -> do        
    finishedBy <- liftIO TM.getCurrentTime
    let duration = TM.diffUTCTime finishedBy startedAt

    case satRes of
      W4R.Unsat _ -> do
        emitEvent (PE.CheckedEquivalence oBlocks pBlocks PE.Equivalent duration)
        return ()
      W4R.Unknown -> do
        emitEvent (PE.CheckedEquivalence oBlocks pBlocks PE.Inconclusive duration)
        throwHere InconclusiveSAT
      W4R.Sat fn -> do
        liftIO $ putStrLn $ "postcondition did not verify"
        let emit ir = emitEvent (PE.CheckedEquivalence oBlocks pBlocks (PE.Inequivalent ir) duration)
        throwInequivalenceResult InvalidPostState postcond bundle fn emit
  return eqInputs
  where
    blkO = simInBlock $ simInO bundle
    blkP = simInBlock $ simInP bundle
     

isIPAligned ::
  forall sym arch.
  CLM.LLVMPtr sym (MM.ArchAddrWidth arch) ->
  EquivM sym arch (W4.Pred sym)
isIPAligned (CLM.LLVMPointer _blk offset)
  | bits <- MM.memWidthNatRepr @(MM.ArchAddrWidth arch) = withSymIO $ \sym -> do
    lowbits <- W4.bvSelect sym (W4.knownNat :: W4.NatRepr 0) bits offset
    W4.bvEq sym lowbits =<< W4.bvLit sym bits (BVS.zero bits)


equivWriter :: EquivM_ sym arch [a] -> MW.WriterT [a] (EquivM_ sym arch) ()
equivWriter f = MW.WriterT (f >>= \a -> return ((), a))

-- Clagged from What4.Builder
type BoundVarMap t = H.HashTable RealWorld Word64 (Set (Some (W4B.ExprBoundVar t)))

boundVars :: W4B.Expr t tp -> IO (BoundVarMap t)
boundVars e0 = do
  visited <- stToIO $ H.new
  _ <- boundVars' visited e0
  return visited

cache :: (Eq k, CC.Hashable k) => H.HashTable RealWorld k r -> k -> IO r -> IO r
cache h k m = do
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
  cache visited idx $ do
    sums <- sequence (TFC.toListFC (boundVars' visited) (W4B.appExprApp e))
    return $ foldl' S.union S.empty sums
boundVars' visited (W4B.NonceAppExpr e) = do
  let idx = N.indexValue (W4B.nonceExprId e)
  cache visited idx $ do
    sums <- sequence (TFC.toListFC (boundVars' visited) (W4B.nonceExprApp e))
    return $ foldl' S.union S.empty sums
boundVars' visited (W4B.BoundVarExpr v)
  | W4B.QuantifierVarKind <- W4B.bvarKind v = do
      let idx = N.indexValue (W4B.bvarId v)
      cache visited idx $
        return (S.singleton (Some v))
boundVars' _ _ = return S.empty
-- End Clag

newtype ExprFilter sym = ExprFilter (forall tp'. W4.SymExpr sym tp' -> IO Bool)

getIsBoundFilter ::
  W4.SymExpr sym tp ->
  EquivM sym arch (ExprFilter sym)
getIsBoundFilter expr = withValid $ do
  bvs <- liftIO $ boundVars expr
  return $ ExprFilter $ \bv -> do
    case bv of
      W4B.BoundVarExpr bv' -> do
        let idx = N.indexValue (W4B.bvarId bv')
        stToIO $ H.lookup bvs idx >>= \case
          Just bvs' -> return $ S.member (Some bv') bvs'
          _ -> return False
      _ -> return False


equivMaybeT :: MaybeT (EquivM_ sym arch) a -> EquivM_ sym arch Bool
equivMaybeT f = runMaybeT f >>= \case
  Just _ -> return True
  _ -> return False

liftMaybeT :: EquivM_ sym arch Bool -> MaybeT (EquivM_ sym arch) ()
liftMaybeT f = MaybeT (f >>= \b -> return $ if b then Just () else Nothing)


equalValues ::
  MacawRegEntry sym tp ->
  MacawRegEntry sym tp' ->
  EquivM sym arch (W4.Pred sym)
equalValues entry1 entry2 = withSymIO $ \sym -> equalValuesIO sym entry1 entry2

equalValuesIO ::
  W4.IsExprBuilder sym ->
  sym ->
  MacawRegEntry sym tp ->
  MacawRegEntry sym tp' ->
  IO (W4.Pred sym)
equalValuesIO sym entry1 entry2 = case (macawRegRepr entry1, macawRegRepr entry2) of
  (CLM.LLVMPointerRepr w1, CLM.LLVMPointerRepr w2) ->
    case testEquality w1 w2 of
      Just Refl -> liftIO $ MT.llvmPtrEq sym (macawRegValue entry1) (macawRegValue entry2)
      Nothing -> return $ W4.falsePred sym
  _ -> fail "equalValues: unsupported type"

isBoundInEntry ::
  forall sym arch tp tp'.
  MM.ArchReg arch tp ->
  MacawRegEntry sym tp ->
  MM.ArchReg arch tp' ->
  MacawRegEntry sym tp' ->
  EquivM sym arch Bool
isBoundInEntry preReg preEntry postReg postEntry =
  case testEquality preReg postReg of
    Just Refl -> (W4.asConstantPred <$> equalValues preEntry postEntry) >>= \case
      Just True -> return False
      _ -> boundIn
    _ -> boundIn
  where
    boundIn :: EquivM sym arch Bool
    boundIn =
      case (macawRegRepr preEntry, macawRegRepr postEntry) of
        (CLM.LLVMPointerRepr{}, CLM.LLVMPointerRepr{}) -> equivMaybeT $ do
          let
            CLM.LLVMPointer preRegion preOffset = macawRegValue preEntry
            CLM.LLVMPointer postRegion postOffset = macawRegValue postEntry
          ExprFilter isBoundInPostOff <- lift $ getIsBoundFilter postOffset
          ExprFilter isBoundInPostReg <- lift $ getIsBoundFilter postRegion
          
          liftMaybeT $ liftIO $ isBoundInPostOff preOffset
          liftMaybeT $ liftIO $ isBoundInPostOff preRegion
          liftMaybeT $ liftIO $ isBoundInPostReg preOffset
          liftMaybeT $ liftIO $ isBoundInPostReg preRegion
        _ -> return False   

isBoundInResult ::
  MM.ArchReg arch tp ->
  MacawRegEntry sym tp ->
  SimOutput sym arch bin ->
  EquivM sym arch Bool
isBoundInResult preReg preEntry result = do
  equivMaybeT $ MM.traverseRegsWith_ (\postReg postEntry -> do
    liftMaybeT $ isBoundInEntry preReg preEntry postReg postEntry) (simOutRegs result)

-- getSimPrecond :: forall sym arch.
--   SimBundle sym arch ->
--   EquivM sym arch (W4.Pred sym)
-- getSimPrecond bundle = do
--   ipEq <- mkIPEquivalence
  
--   ipsAligned <- MW.execWriterT $ MM.traverseRegsWith_ (\r preO -> equivWriter $ do
--     let
--       preP = (resultPreRegs resultP) ^. MM.boundValue r    
--     case funCallIP r of
--       Just Refl -> do
--         alignedO <- isIPAligned (macawRegValue preO)
--         alignedP <- isIPAligned (macawRegValue preP)
--         return [alignedO, alignedP]
--       _ -> return []
--     ) (resultPreRegs resultO)

--   regsEquiv <- MW.execWriterT $ MM.traverseRegsWith_ (\r preO -> equivWriter $ do
--     let preP = (resultPreRegs resultP) ^. MM.boundValue r
--     isBoundO <- isBoundInResult r preO resultO
--     isBoundP <- isBoundInResult r preP resultP
--     case isBoundO || isBoundP of
--       True -> do
--         case funCallIP r of
--           Just Refl -> do
--             eqIps <- liftIO $ ipEq (macawRegValue preO) (macawRegValue preP)
--             return [eqIps]
--           _ -> do
--             valEq <- equalValues  preO preP
--             return [valEq]
--       False -> return []
--     ) (resultPreRegs resultO)

--   -- given the reads from the result, assert equivalence on their
--   -- initial values
--   let
--     oPreMem' = (resultPreMem resultO) { MT.memSeq =  MT.memSeq $ resultMem resultO }
--     pPreMem' = (resultPreMem resultP) { MT.memSeq =  MT.memSeq $ resultMem resultP }

--   eqRel <- mkPtrEq resultO resultP
--   eqInit <- withSymIO $ \sym ->  MT.equivOps sym (eqReads sym eqRel) oPreMem' pPreMem'

--   let preconds = [eqInit] ++ ipsAligned ++ regsEquiv

--   withSymIO $ \sym -> foldM (W4.andPred sym) (W4.truePred sym) preconds




throwInequivalenceResult ::
  forall sym arch a.
  InequivalenceReason ->
  StatePred sym arch ->
  SimBundle sym arch ->
  SymGroundEvalFn sym ->
  (InequivalenceResult arch -> EquivM sym arch ()) ->
  EquivM sym arch a
throwInequivalenceResult defaultReason stPred bundle fn@(SymGroundEvalFn fn') emit = do
  ecaseO <- liftIO $ MT.groundExitCase fn' (simOutExit $ simOutO $ bundle)
  ecaseP <- liftIO $ MT.groundExitCase fn' (simOutExit $ simOutP $ bundle)
  
  memdiff <- groundTraceDiff fn stPred bundle
  regdiff <- MM.traverseRegsWith
    (\r preO -> do
        let
          preP = preRegsP ^. MM.boundValue r
          postO = postRegsO ^. MM.boundValue r
          postP = postRegsP ^. MM.boundValue r
        equivE <- evalStatePredReg stPred r
        d <- mkRegisterDiff fn r preO preP postO postP equivE
        return d
    ) preRegsO
    
  retO <- groundReturnPtr fn (simOutReturn $ simOutO bundle)
  retP <- groundReturnPtr fn (simOutReturn $ simOutP bundle)

  let reason =
        if isMemoryDifferent memdiff then InequivalentMemory
        else if areRegistersDifferent regdiff then InequivalentRegisters
        else defaultReason
  let ir = InequivalentResults memdiff (ecaseO, ecaseP) regdiff (retO, retP) reason
  emit ir
  throwHere $ InequivalentError ir
  where
    preRegsO = simInRegs $ simInO bundle
    preRegsP = simInRegs $ simInP bundle

    postRegsO = simOutRegs $ simOutO bundle
    postRegsP = simOutRegs $ simOutP bundle
    
    simResult = simOutO bundle
    simResult' = simOutP bundle

isMemoryDifferent :: forall arch. MemTraceDiff arch -> Bool
isMemoryDifferent diffs = any (not . mIsValid) diffs

areRegistersDifferent :: forall arch. MM.RegState (MM.ArchReg arch) (RegisterDiff arch) -> Bool
areRegistersDifferent regs = case MM.traverseRegsWith_ go regs of
  Just () -> False
  Nothing -> True
  where
    go :: forall tp. MM.ArchReg arch tp -> RegisterDiff arch tp -> Maybe ()
    go _ diff = if rPostEquivalent diff then Just () else Nothing


data PtrEquivCheck sym arch where
  PtrEquivCheck ::
    (forall w.
      MT.MemOpResult sym (MM.ArchAddrWidth arch) w ->
      IO (W4.Pred sym)) ->
    PtrEquivCheck sym arch

_isArchPtr ::
  forall arch sym w.
  ValidSym sym =>
  ValidArch arch =>
  CLM.LLVMPtr sym w -> Maybe (MM.ArchAddrWidth arch :~: w)
_isArchPtr ptr =
  let
    (_, off) = CLM.llvmPointerView ptr
  in testEquality (MM.memWidthNatRepr @(MM.ArchAddrWidth arch)) (W4.bvWidth off)


-- TODO: this equality check might need to do more mapping of the
-- returned pointers to handle indirect jumps
mkPtrEq ::
  forall sym arch.
  SimBundle sym arch ->
  EquivM sym arch (PtrEquivCheck sym arch)
mkPtrEq _ = withSymIO $ \sym -> do
  return $ PtrEquivCheck $ \res -> MT.llvmPtrEq sym (MT.resOVal res) (MT.resPVal res)


-- eqReads ::
--   ValidSym sym =>
--   sym ->
--   PtrEquivCheck sym arch ->
--   MT.MemOpDirection ->
--   MT.MemOpResult sym (MM.ArchAddrWidth arch) w ->
--   IO (W4.Pred sym)
-- eqReads sym (PtrEquivCheck eqRel) MT.Read result = do
--   p <- eqRel result
--   notshadowed <- W4.notPred sym shadowed
--   W4.impliesPred sym notshadowed p
-- eqReads sym _ _ _ = return $ W4.truePred sym

-- eqWrites ::
--   ValidSym sym =>
--   sym ->
--   PtrEquivCheck sym arch ->
--   MT.MemOpDirection ->
--   MT.MemOpResult sym (MM.ArchAddrWidth arch) w ->
--   IO (W4.Pred sym)
-- eqWrites _sym (PtrEquivCheck eqRel) MT.Write result = eqRel result
-- eqWrites sym _ _ _ = return $ W4.truePred sym

baseEquivRelation ::
  Maybe (PatchPair arch) ->
  EquivM sym arch (EquivRelation sym arch)
baseEquivRelation mpPair = withSym $ \sym -> do
  stackRegion <- asks envStackRegion
  let
    isStackStamp stamp = do
      let CLM.LLVMPointer region _ = stampPtr stamp
      W4.isEq sym region stackRegion
      
    regsEq r vO vP =
      case registerCase r of
        RegIP -> case mpPair of
          Just pPair -> do
            ptrO <- concreteToLLVM sym $ concreteAddress $ (pOrig pPair)
            ptrP <- concreteToLLVM sym $ concreteAddress $ (pPatched pPair)
            
            eqO <- MT.llvmPtrEq sym ptrO (macawRegValue vO)
            eqP <- MT.llvmPtrEq sym ptrO (macawRegValue vP)
            W4.andPred eqO eqP
          Nothing -> return $ W4.truePred sym
        RegSP -> do
          let
            CLM.LLVMPointer regionO offO = macawRegValue vO
            CLM.LLVMPointer regionP offP = macawRegValue vP
          eqO <-  W4.isEq sym regionO stackRegion
          eqP <- W4.isEq sym regionP stackRegion
          eqOffs <- W4.isEq sym offO offP
          validRegs <- W4.andPred sym eqO eqP
          W4.andPred sym eqOffs validRegs
        RegG -> equalValuesIO sym v1 v2
    stackEq stamp vO vP = do
      isStack <- isStackStamp stamp
      eqPtr <- MT.llvmPtrEq sym vO vP
      W4.impliesPred sym isStack eqPtr
    memEq stamp vO vP = do
      isNotStack <- W4.notPred sym =<< isStackStamp stamp
      eqPtr <- MT.llvmPtrEq sym vO vP
      W4.impliesPred sym isNotStack eqPtr
  return $ EquivRelation regsEq stackEq memEq

footPrintStamps ::
  MemFootprints sym arch ->
  EquivM sym arch ([(MemStamp sym arch, W4.Pred)], [(MemStamp sym arch, W4.Pred)])
footPrintStamps foots = withSym $ \sym -> do
  (reads, writes) <- fmap unzip $ forM (S.toList foots) $ \(MT.MemFootprint ptr w dir cond) ->  do
    cond' <- liftIO $ MT.getCond sym cond
    let stamp = MemStamp ptr w
    case dir of
      MT.Read -> return $ (Just (stamp, cond'), Nothing)
      MT.Write -> return $ (Nothing, Just (stamp, cond'))
  return $ (catMaybes reads, catMaybes writes)

evalEquivRelation ::
  SimState sym arch Original ->
  SimState sym arch Patched ->
  EquivRelation sym arch ->
  EquivM sym arch (W4.Pred sym)
evalEquivRelation stO stP eqRel = do
  footO <- liftIO $ MT.traceFootprint sym (MT.memSeq $ simMem stO)
  footP <- liftIO $ MT.traceFootprint sym (MT.memSeq $ simMem stP)
  (_, writes) <- footPrintStamps $ S.union footO footP
  regsEq <- MW.execWriterT $ MM.traverseRegsWith_ (\r vO -> equivWriter $ do
    let
      vP = (simRegs st) ^. MM.boundValue r
    p <- eqRelRegs eqRel r vO vP
    return $ [p]
    ) (simRegs st)
  
  memEq <- forM writes $ \(stamp@(MemStamp ptr w), cond) -> liftIO $ do
    let repr = MM.BVMemRepr w MM.BigEndian
    val1 <- MT.readMemArr sym (simMem stO) ptr repr
    val2 <- MT.readMemArr sym (simMem stP) ptr repr
    stackEq <- eqRelStack eqRel stamp val1 val2
    memEq <- eqRelMem eqRel stamp val1 val2
    bothEq <- W4.andPred sym stackEq memEq
    W4.impliesPred sym cond bothEq

  allPred (regsEq ++ memEq)

exactEquivalence ::
  SimInput sym arch Original ->
  SimInput sym arch Patched ->
  EquivM sym arch (W4.Pred sym)
exactEquivalence inO inP = withSym $ \sym -> do
  regsEqMap <- exactRegisterEquivalence Nothing (simInState inO) (simInState inP)
  regsEq <- liftIO $ foldM (W4.andPred sym) (W4.truePred sym) (M.elems regsEqMap)
  memEq <- liftIO $ W4.isEq sym (MT.memArr (simInMem inO)) (MT.memArr (simInMem inP))
  liftIO $ W4.andPred sym regsEq memEq


-- | Add additional patch pairs by pairing up function exit points
discoverPairs ::
  forall sym arch.
  SimBundle sym arch ->
  EquivM sym arch [(BlockTarget arch Original, BlockTarget arch Patched)]
discoverPairs bundle = do
  precond <- exactEquivalence (simInO bundle) (simInP bundle)
  
  blksO <- getSubBlocks (simInBlock $ simInO $ bundle)
  blksP <- getSubBlocks (simInBlock $ simInP $ bundle)

  let
    allCalls = [ (blkO, blkP)
               | blkO <- blksO
               , blkP <- blksP
               , compatibleTargets blkO blkP]

  
  validTargets <- fmap catMaybes $
    forM allCalls $ \(blktO, blktP) -> do
      matches <- matchesBlockTarget bundle blktO blktP
      check <- withSymIO $ \sym -> W4.andPred sym precond matches
      checkSatisfiableWithModel "check" check $ \case
          W4R.Sat _ -> return $ Just $ (blktO, blktP)
          W4R.Unsat _ -> return Nothing
          W4R.Unknown -> throwHere InconclusiveSAT

  return validTargets

matchesBlockTarget ::
  SimBundle sym arch ->
  BlockTarget arch Original ->
  BlockTarget arch Patched ->
  EquivM sym arch (W4.Pred sym)
matchesBlockTarget bundle blktO blktP = withSymIO $ \sym -> do
  -- true when the resulting IPs call the given block targets
  ptrO <- concreteToLLVM sym (concreteAddress $ targetCall blktO)
  ptrP <- concreteToLLVM sym (concreteAddress $ targetCall blktP)

  eqO <- MT.llvmPtrEq sym ptrO (macawRegValue ipO)
  eqP <- MT.llvmPtrEq sym ptrP (macawRegValue ipP)
  eqCall <- W4.andPred sym eqO eqP

  -- true when the resulting return IPs match the given block return addresses
  targetRetO <- targetReturnPtr sym blktO
  targetRetP <- targetReturnPtr sym blktP

  eqRetO <- liftPartialRel sym (MT.llvmPtrEq sym) retO targetRetO
  eqRetP <- liftPartialRel sym (MT.llvmPtrEq sym) retP targetRetP
  eqRet <-  W4.andPred sym eqRetO eqRetP
  W4.andPred sym eqCall eqRet
  where
    regsO = simOutRegs $ simOutO bundle
    regsP = simOutRegs $ simOutP bundle
    
    ipO = regsO ^. MM.curIP
    ipP = regsP ^. MM.curIP

    retO = simOutReturn $ simOutO bundle
    retP = simOutReturn $ simOutP bundle


addAssumption ::
  W4.Pred sym ->
  String ->
  EquivM sym arch ()
addAssumption p msg = withSymIO $ \sym -> do
  here <- W4.getCurrentProgramLoc sym
  CB.addAssumption sym (CB.LabeledPred p (CB.AssumptionReason here msg))  

-- matchTraces :: forall sym arch.
--   PatchPair arch ->
--   SimResultPair sym arch ->
--   EquivM sym arch ()
-- matchTraces _ result = do
--   binCtxO <- asks $ originalCtx . envCtx
--   binCtxP <- asks $ rewrittenCtx . envCtx

  
--   CC.Some (Compose opbs) <- lookupBlocks (parsedFunctionMap binCtxO) rBlock
--   let oBlocks = PE.Blocks (concreteAddress rBlock) opbs
--   CC.Some (Compose ppbs) <- lookupBlocks (parsedFunctionMap binCtxP) rBlock'
--   let pBlocks = PE.Blocks (concreteAddress rBlock') ppbs

--   -- FIXME: shouldn't actually need this
--   regEq <- mkRegEquivCheck (simResultO result) (simResultP result) 

--   allResults <- gets stSimResults
--   forM_ (simResultTargets result) $ \(blktO, blktP) -> do
--     let pair = PatchPair (targetCall blktO) (targetCall blktP)
--     case M.lookup pair allResults of
--       Just result' -> inFrame $ do
--         -- match up pre and post states
       
--         bindResults (simResultO result) (simResultO result')
--         bindResults (simResultP result) (simResultP result')
--         -- assume that we exited here
--         exitHere <- matchesBlockTarget (simResultO result) (simResultP result) blktO blktP
--         addAssumption exitHere "matchesBlockTarget"
        
--         validExits <- withSymIO $ \sym -> do
--           let
--             MT.ExitClassifyImpl exitO = resultExit (simResultO result)
--             MT.ExitClassifyImpl exitP = resultExit (simResultP result)
--           W4.isEq sym exitO exitP

--         notChecks <- withSymIO $ \sym -> do
--           checks <- W4.andPred sym validExits (simResultPrecond result')
--           W4.notPred sym checks

        
--         startedAt <- liftIO TM.getCurrentTime
--         checkSatisfiableWithModel satResultDescription notChecks $ \satRes -> do        
--           finishedBy <- liftIO TM.getCurrentTime
--           let duration = TM.diffUTCTime finishedBy startedAt
          
--           case satRes of
--             W4R.Unsat _ -> do
--               emitEvent (PE.CheckedEquivalence oBlocks pBlocks PE.Equivalent duration)
--               return ()
--             W4R.Unknown -> do
--               emitEvent (PE.CheckedEquivalence oBlocks pBlocks PE.Inconclusive duration)
--               throwHere InconclusiveSAT
--             W4R.Sat fn -> do
--               let emit ir = emitEvent (PE.CheckedEquivalence oBlocks pBlocks (PE.Inequivalent ir) duration)
--               throwInequivalenceResult InvalidPostState regEq result fn emit        
          
--       _ -> throwHere $ MissingPatchPairResult pair
  
--   -- FIXME: we need to check that all the checked pairs cover all possible exits
  

--   -- notValidCall <- withSymIO $ \sym -> do
--   --   let addTarget e p (blktO, blktP) = do
--   --         case validExit e (concreteBlockEntry (targetCall blktO)) of
--   --           True -> do
--   --             matches <- matchesBlockTarget sym blktO blktP
--   --             W4.orPred sym matches p
--   --           False -> return p
--   --   validCall <- MT.exitCases sym (resultExit simResult) $ \ecase -> do
--   --     case ecase of
--   --       -- TODO: we need to assert that the stored return address in the stack
--   --       -- initially satisfies the IP equivalence relation in order to prove
--   --       -- that this return satisfies it
--   --       MT.ExitReturn -> return $ W4.truePred sym
--   --       -- TODO: It's not clear how to calculate a valid jump pair for
--   --       -- arbitrary jumps if we don't have any statically valid targets
--   --       MT.ExitUnknown | [] <- allCalls -> return $ W4.truePred sym

--   --       _ -> foldM (addTarget ecase) (W4.falsePred sym) validTargets

--   --   W4.notPred sym validCall

--   -- -- FIXME: Stream results out from this SAT check
--   -- checkSatisfiableWithModel "check" notValidCall $ \case
--   --   W4R.Unsat _ -> return ()
--   --   W4R.Sat fn -> throwInequivalenceResult InvalidCallPair regEq result fn (\_ -> return ())
--   --   W4R.Unknown -> throwHere InconclusiveSAT


--   where
--     simResult = simResultO result
--     simResult' = simResultP result
    
--     regsO = resultRegs simResult
--     regsP = resultRegs simResult'
    
--     ipO = regsO ^. MM.curIP
--     ipP = regsP ^. MM.curIP

--     retO = resultReturn simResult
--     retP = resultReturn simResult'

--     rBlock = resultBlock simResult
--     rBlock' = resultBlock simResult'
--     satResultDescription = ""
--       ++ "equivalence of the blocks at " ++ show (concreteAddress rBlock) ++ " in the original binary "
--       ++ "and at " ++ show (concreteAddress rBlock') ++ " in the rewritten binary"


-- | Lift an equivalence relation over two partial expressions
liftPartialRel ::
  CB.IsSymInterface sym =>
  sym ->
  (a -> a -> IO (W4.Pred sym)) ->
  W4P.PartExpr (W4.Pred sym) a ->
  W4P.PartExpr (W4.Pred sym) a ->
  IO (W4.Pred sym)
liftPartialRel sym rel (W4P.PE p1 e1) (W4P.PE p2 e2) = do
  eqPreds <- W4.isEq sym p1 p2
  bothConds <- W4.andPred sym p1 p2
  rel' <- rel e1 e2
  justCase <- W4.impliesPred sym bothConds rel'
  W4.andPred sym eqPreds justCase
liftPartialRel sym _ W4P.Unassigned W4P.Unassigned = return $ W4.truePred sym
liftPartialRel sym _ W4P.Unassigned (W4P.PE p2 _) = W4.notPred sym p2
liftPartialRel sym _ (W4P.PE p1 _) W4P.Unassigned = W4.notPred sym p1

validExit :: MT.ExitCase -> BlockEntryKind arch -> Bool
validExit ecase blkK = case (ecase, blkK) of
  (MT.ExitCall, BlockEntryInitFunction) -> True
  (MT.ExitArch, BlockEntryPostArch) -> True
  (MT.ExitUnknown, BlockEntryJump) -> True
  _ -> False

allTargets ::
  (BlockTarget arch Original, BlockTarget arch Patched) -> [PatchPair arch]
allTargets (BlockTarget blkO mrblkO, BlockTarget blkP mrblkP) =
  [PatchPair blkO blkP] ++
    case (mrblkO, mrblkP) of
      (Just rblkO, Just rblkP) -> [PatchPair rblkO rblkP]
      _ -> []

-- | True for a pair of original and patched block targets that represent a valid pair of
-- jumps
compatibleTargets ::
  BlockTarget arch Original ->
  BlockTarget arch Patched ->
  Bool
compatibleTargets blkt1 blkt2 =
  concreteBlockEntry (targetCall blkt1) == concreteBlockEntry (targetCall blkt2) &&
  case (targetReturn blkt1, targetReturn blkt2) of
    (Just blk1, Just blk2) -> concreteBlockEntry blk1 == concreteBlockEntry blk2
    (Nothing, Nothing) -> True
    _ -> False

evalCFG ::
  CS.SymGlobalState sym ->
  CS.RegMap sym tp ->
  CC.CFG (MS.MacawExt arch) blocks tp (MS.ArchRegStruct arch) ->
  EquivM sym arch (CS.ExecResult (MS.MacawSimulatorState sym) sym (MS.MacawExt arch) (CS.RegEntry sym (MS.ArchRegStruct arch)))
evalCFG globals regs cfg = do
  archRepr <- archStructRepr
  initCtx <- initSimContext
  liftIO $ id
    . CS.executeCrucible []
    . CS.InitialState initCtx globals CS.defaultAbortHandler archRepr
    . CS.runOverrideSim archRepr
    $ CS.regValue <$> CS.callCFG cfg regs

initSimContext ::
  EquivM sym arch (CS.SimContext (MS.MacawSimulatorState sym) sym (MS.MacawExt arch))
initSimContext = withValid $ withSym $ \sym -> do
  exts <- asks envExtensions
  ha <- asks $ handles . envCtx
  return $
    CS.initSimContext
    sym
    MT.memTraceIntrinsicTypes
    ha
    stderr
    CFH.emptyHandleMap
    exts
    MS.MacawSimulatorState



simulate ::
  forall sym arch bin.
  KnownBinary bin =>
  SimInput sym arch bin ->
  EquivM sym arch (SimOutput sym arch bin)
simulate simInput = withBinary @bin $ do
  -- rBlock/rb for renovate-style block, mBlocks/mbs for macaw-style blocks
  CC.SomeCFG cfg <- do
    CC.Some (Compose pbs_) <- lookupBlocks (simInBlock simInput)
    let pb:pbs = sortOn MD.pblockAddr pbs_
        -- There's a slight hack here.
        --
        -- The core problem we're dealing with here is that renovate blocks
        -- can have multiple basic blocks; and almost always do in the
        -- rewritten binary. We want to stitch them together in the right
        -- way, and part of that means deciding whether basic block
        -- terminators are things we should "follow" to their target to
        -- continue symbolically executing or not. Normally any block
        -- terminator that goes to another basic block in the same renovate
        -- block is one we want to keep symbolically executing through.
        --
        -- BUT if there is an actual self-contained loop within a single
        -- renovate block, we want to avoid trying to symbolically execute
        -- that forever, so we'd like to pick some of the edges in the
        -- "block X can jump to block Y" graph that break all the cycles,
        -- and mark all of those as terminal for the purposes of CFG
        -- creation.
        --
        -- Instead of doing a careful analysis of that graph, we adopt the
        -- following heuristic: kill any edges that point to the entry
        -- point of the renovate block, and symbolically execute through
        -- all the others. This catches at the very least any
        -- single-basic-block loops in the original binary and in most
        -- cases even their transformed version in the rewritten binary. If
        -- we ever kill such an edge, we have certainly broken a cycle; but
        -- cycles could appear in other ways that we don't catch.
        --
        -- This heuristic is reflected in the code like this: when deciding
        -- if a jump should be killed, we compare jump targets to a
        -- collection of "internal" addresses, and kill it if the target
        -- isn't in that collection. Then we omit the entry point's address
        -- from that collection, so that jumps to it are considered terminal.

        -- Multiple ParsedBlocks may have the same address, so the delete
        -- is really needed.
        internalAddrs = S.delete (MD.pblockAddr pb) $ S.fromList [MD.pblockAddr b | b <- pbs]
        (terminal_, nonTerminal) = partition isTerminalBlock pbs
        terminal = [pb | isTerminalBlock pb] ++ terminal_
        killEdges =
          concatMap (backJumps internalAddrs) (pb : pbs) ++
          concatMap (externalTransitions internalAddrs) (pb:pbs)
    fns <- archFuns
    ha <- asks $ handles . envCtx
    liftIO $ MS.mkBlockSliceCFG fns ha (W4L.OtherPos . fromString . show) pb nonTerminal terminal killEdges
  let preRegs = simInRegs simInput
  preRegsAsn <- regStateToAsn preRegs
  archRepr <- archStructRepr
  let regs = CS.assignReg archRepr preRegsAsn CS.emptyRegMap
  globals <- getGlobals simInput
  cres <- evalCFG globals regs cfg
  (postRegs, memTrace, jumpClass, returnIP) <- getGPValueAndTrace cres
  return $ SimOutput (SimState memTrace postRegs) jumpClass returnIP

execGroundFn ::
  HasCallStack =>
  SymGroundEvalFn sym  -> 
  W4.SymExpr sym tp -> 
  EquivM sym arch (W4G.GroundValue tp)  
execGroundFn gfn e =
  (liftIO $ try (execGroundFnIO gfn e)) >>= \case
    Left (_ :: ArithException) -> throwHere $ InvalidSMTModel
    Right a -> return a

archStructRepr :: forall sym arch. EquivM sym arch (CC.TypeRepr (MS.ArchRegStruct arch))
archStructRepr = do
  archFs <- archFuns
  return $ CC.StructRepr $ MS.crucArchRegTypes archFs

memOpCondition :: MT.MemOpCondition sym -> EquivM sym arch (W4.Pred sym)
memOpCondition = \case
  MT.Unconditional -> withSymIO $ \sym -> return $ W4.truePred sym
  MT.Conditional p -> return p

checkSatisfiableWithModel ::
  String ->
  W4.Pred sym ->
  (W4R.SatResult (SymGroundEvalFn sym) () -> EquivM sym arch a) ->
  EquivM sym arch a
checkSatisfiableWithModel desc p k = withProc $ \proc -> do
  let mkResult r = W4R.traverseSatResult (pure . SymGroundEvalFn) pure r
  runInIO1 (mkResult >=> k) $ W4O.checkSatisfiableWithModel proc desc p

isTerminalBlock :: MD.ParsedBlock arch ids -> Bool
isTerminalBlock pb = case MD.pblockTermStmt pb of
  MD.ParsedCall{} -> True
  MD.PLTStub{} -> True
  MD.ParsedJump{} -> False
  MD.ParsedBranch{} -> False
  MD.ParsedLookupTable{} -> False
  MD.ParsedReturn{} -> False
  MD.ParsedArchTermStmt{} -> True -- TODO: think harder about this
  MD.ParsedTranslateError{} -> True
  MD.ClassifyFailure{} -> True

-- FIXME: this is hardly rigorous
-- | Kill back jumps within the function
backJumps ::
  Set (MM.ArchSegmentOff arch) ->
  MD.ParsedBlock arch ids ->
  [(MM.ArchSegmentOff arch, MM.ArchSegmentOff arch)]
backJumps internalAddrs pb =
  [ (MD.pblockAddr pb, tgt)
  | tgt <- case MD.pblockTermStmt pb of
     MD.ParsedJump _ tgt -> [tgt]
     MD.ParsedBranch _ _ tgt tgt' -> [tgt, tgt']
     MD.ParsedLookupTable _ _ tgts -> toList tgts
     _ -> []
  , tgt < MD.pblockAddr pb
  , tgt `S.member` internalAddrs
  ]


externalTransitions ::
  Set (MM.ArchSegmentOff arch) ->
  MD.ParsedBlock arch ids ->
  [(MM.ArchSegmentOff arch, MM.ArchSegmentOff arch)]
externalTransitions internalAddrs pb =
  [ (MD.pblockAddr pb, tgt)
  | tgt <- case MD.pblockTermStmt pb of
      MD.ParsedCall{} -> []
      MD.PLTStub{} -> []
      MD.ParsedJump _ tgt -> [tgt]
      MD.ParsedBranch _ _ tgt tgt' -> [tgt, tgt']
      MD.ParsedLookupTable _ _ tgts -> toList tgts
      MD.ParsedReturn{} -> []
      MD.ParsedArchTermStmt{} -> [] -- TODO: think harder about this
      MD.ParsedTranslateError{} -> []
      MD.ClassifyFailure{} -> []
  , tgt `S.notMember` internalAddrs
  ]

-- | True if this register can be assumed equivalent at the start of
-- a block
-- FIXME: Stack pointers need not be equal in general
-- preStableReg ::
--   forall arch tp.
--   ValidArch arch =>
--   ConcreteBlock arch ->
--   MM.ArchReg arch tp ->
--   Bool
-- preStableReg _ reg | Just _ <- testEquality reg (MM.sp_reg @(MM.ArchReg arch)) = True
-- preStableReg blk reg = case concreteBlockEntry blk of
--   BlockEntryInitFunction -> funCallArg reg || funCallStable reg
--   BlockEntryPostFunction -> funCallRet reg || funCallStable reg
--   -- FIXME: not entirely true, needs proper dependency analysis
--   BlockEntryPostArch -> funCallStable reg
--   BlockEntryJump -> True  

mkRegisterDiff ::
  SymGroundEvalFn sym ->
  MM.ArchReg arch tp ->
  MacawRegEntry sym tp ->
  -- ^ original prestate
  MacawRegEntry sym tp ->
  -- ^ patched prestate
  MacawRegEntry sym tp ->
  -- ^ original post state
  MacawRegEntry sym tp ->
  -- ^ patched post state
  W4.Pred sym ->
  EquivM sym arch (RegisterDiff arch tp)
mkRegisterDiff fn reg preO preP postO postP equivE = do
  pre <- concreteValue fn preO
  pre' <- concreteValue fn preP
  post <- concreteValue fn postO
  post' <- concreteValue fn postP
  equiv <- execGroundFn fn equivE
  
  desc <- liftIO $ ppRegDiff fn postO postP
  pure RegisterDiff
    { rReg = reg
    , rTypeRepr = macawRegRepr preP
    , rPreOriginal = pre
    , rPrePatched = pre'
    , rPostOriginal = post
    , rPostPatched = post'
    , rPostEquivalent = equiv
    , rDiffDescription = desc
    }

concreteValue ::
  SymGroundEvalFn sym ->
  MacawRegEntry sym tp ->
  EquivM sym arch (ConcreteValue (MS.ToCrucibleType tp))
concreteValue fn e
  | CLM.LLVMPointerRepr _ <- macawRegRepr e
  , ptr <- macawRegValue e = do
    groundBV fn ptr
concreteValue _ e = throwHere (UnsupportedRegisterType (Some (macawRegRepr e)))

groundReturnPtr ::
  SymGroundEvalFn sym ->
  CS.RegValue sym (CC.MaybeType (CLM.LLVMPointerType (MM.ArchAddrWidth arch))) ->
  EquivM sym arch (Maybe (GroundLLVMPointer (MM.ArchAddrWidth arch)))
groundReturnPtr fn (W4P.PE p e) = execGroundFn fn p >>= \case
  True -> Just <$> groundLLVMPointer fn e
  False -> return Nothing
groundReturnPtr _ W4P.Unassigned = return Nothing


groundTraceDiff :: forall sym arch.
  SymGroundEvalFn sym ->
  StatePred sym arch ->
  SimBundle sym arch ->
  EquivM sym arch (MemTraceDiff arch)
groundTraceDiff fn stPred bundle = do
  (S.toList . S.fromList . catMaybes) <$> mapM checkFootprint (S.toList $ simFootprints bundle)
  where
    memO = simOutMem $ simOutO bundle
    memP = simOutMem $ simOutP bundle
    preMemO = simInMem $ simInO bundle
    preMemP = simInMem $ simInP bundle
    
    checkFootprint ::
      MT.MemFootprint sym (MM.ArchAddrWidth arch) ->
      EquivM sym arch (Maybe (MemOpDiff arch))
    checkFootprint (MT.MemFootprint ptr w dir cond) = do
      let repr = MM.BVMemRepr w MM.BigEndian
      -- "reads" here are simply the memory pre-state
      (oMem, pMem) <- case dir of
            MT.Read -> return $ (preMemO, preMemP)
            MT.Write -> return $ (memO, memP)
      val1 <- withSymIO $ \sym -> MT.readMemArr sym oMem ptr repr
      val2 <- withSymIO $ \sym -> MT.readMemArr sym pMem ptr repr
      cond' <- memOpCondition cond
      execGroundFn fn cond' >>= \case
        True -> do
          isValid <- evalStatePredMem stPred ptr
          groundIsValid <- execGroundFn fn isValid
          op1  <- groundMemOp fn ptr cond' val1
          op2  <- groundMemOp fn ptr cond' val2
          desc <- liftIO $ ppMemDiff fn ptr val1 val2
          return $ Just $ MemOpDiff { mIsRead = case dir of {MT.Write -> False; _ -> True}
                                    , mOpOriginal = op1
                                    , mOpRewritten = op2
                                    , mIsValid = groundIsValid
                                    , mDesc = desc
                                    }
        False -> return Nothing


groundMemOp ::
  SymGroundEvalFn sym ->
  CLM.LLVMPtr sym (MM.ArchAddrWidth arch) ->
  W4.Pred sym ->
  CLM.LLVMPtr sym w ->
  EquivM sym arch (GroundMemOp arch)
groundMemOp fn addr cond val = liftA3 GroundMemOp
  (groundLLVMPointer fn addr)
  (execGroundFn fn cond)
  (groundBV fn val)

groundBV ::
  SymGroundEvalFn sym ->
  CLM.LLVMPtr sym w ->
  EquivM sym arch (GroundBV w)
groundBV fn (CLM.LLVMPointer reg off) = do
  W4.BaseBVRepr w <- return $ W4.exprType off
  greg <- execGroundFn fn reg
  goff <- execGroundFn fn off
  let gbv = mkGroundBV w greg goff
  return gbv



groundLLVMPointer :: forall sym arch.
  SymGroundEvalFn sym ->
  CLM.LLVMPtr sym (MM.ArchAddrWidth arch) ->
  EquivM sym arch (GroundLLVMPointer (MM.ArchAddrWidth arch))
groundLLVMPointer fn ptr = groundBVAsPointer <$> groundBV fn ptr


trivialGlobalMap :: MS.GlobalMap sym (MT.MemTrace arch) w
trivialGlobalMap _ _ reg off = pure (CLM.LLVMPointer reg off)

-- TODO: What should happen if the Pred sym in a PartialRes in pres or pres' is false?
getGPValueAndTrace ::
  forall sym arch p ext.
  CS.ExecResult p sym ext (CS.RegEntry sym (MS.ArchRegStruct arch)) ->
  EquivM sym arch
    ( MM.RegState (MM.ArchReg arch) (MacawRegEntry sym)
    , MT.MemTraceImpl sym (MM.ArchAddrWidth arch)
    , MT.ExitClassifyImpl sym
    , CS.RegValue sym (CC.MaybeType (CLM.LLVMPointerType (MM.ArchAddrWidth arch)))
    )
getGPValueAndTrace (CS.FinishedResult _ pres) = do
  mem <- asks envMemTraceVar
  eclass <- asks envExitClassVar
  rpv <- asks envReturnIPVar
  case pres ^. CS.partialValue of
    CS.GlobalPair val globs
      | Just mt <- CGS.lookupGlobal mem globs
      , Just jc <- CGS.lookupGlobal eclass globs
      , Just rp <- CGS.lookupGlobal rpv globs -> withValid $ do
        val' <- structToRegState @sym @arch val
        return $ (val', mt, jc, rp)
    _ -> throwError undefined
getGPValueAndTrace (CS.AbortedResult _ ar) = throwHere . SymbolicExecutionFailed . ppAbortedResult $ ar
getGPValueAndTrace (CS.TimeoutResult _) = throwHere (SymbolicExecutionFailed "timeout")


structToRegState :: forall sym arch.
  CS.RegEntry sym (MS.ArchRegStruct arch) ->
  EquivM sym arch (MM.RegState (MM.ArchReg arch) (MacawRegEntry sym))
structToRegState e = do
  archVs <- asks $ envArchVals
  return $ MM.mkRegState (macawRegEntry . MS.lookupReg archVs e)


regStateToAsn :: forall sym arch.
  MM.RegState (MM.ArchReg arch) (MacawRegEntry sym) ->
  EquivM sym arch (Ctx.Assignment (CS.RegValue' sym)  (MS.MacawCrucibleRegTypes arch))
regStateToAsn regs = do
  archFs <- archFuns
  let allRegsAsn = MS.crucGenRegAssignment archFs
  return $ MS.macawAssignToCruc (\(MacawRegEntry _ v) -> CS.RV @sym v) $
    TFC.fmapFC (\r -> regs ^. MM.boundValue r) allRegsAsn

unconstrainedRegister ::
  forall sym arch tp.
  MM.ArchReg arch tp ->
  EquivM sym arch (MacawRegVar sym tp)
unconstrainedRegister reg = do
  archFs <- archFuns
  let
    symbol = MS.crucGenArchRegName archFs reg
    repr = MM.typeRepr reg
  case repr of
    -- -- | Instruction pointers are exactly the start of the block
    -- MM.BVTypeRepr n | Just Refl <- testEquality reg (MM.ip_reg @(MM.ArchReg arch)) ->
    --   withSymIO $ \sym -> do
    --     regVar <- W4.freshBoundVar sym symbol W4.BaseNatRepr
    --     offVar <- W4.freshBoundVar sym symbol (W4.BaseBVRepr n)
    --     ptr <- concreteToLLVM sym $ concreteAddress blk
    --     return $ MacawRegVar (MacawRegEntry (MS.typeToCrucible repr) ptr) (Ctx.empty Ctx.:> regVar Ctx.:> offVar)
    -- -- | Stack pointer is in a unique region
    -- MM.BVTypeRepr n | Just Refl <- testEquality reg (MM.sp_reg @(MM.ArchReg arch)) -> do
    --     stackRegion <- asks envStackRegion
    --     withSymIO $ \sym -> do
    --       regVar <- W4.freshBoundVar sym symbol W4.BaseNatRepr
    --       offVar <- W4.freshBoundVar sym symbol (W4.BaseBVRepr n)
    --       let ptr = CLM.LLVMPointer stackRegion (W4.varExpr sym offVar)
    --       return $ MacawRegVar (MacawRegEntry (MS.typeToCrucible repr) ptr) (Ctx.empty Ctx.:> regVar Ctx.:> offVar)
    MM.BVTypeRepr n -> withSymIO $ \sym -> do
      regVar <- W4.freshBoundVar sym symbol W4.BaseNatRepr
      offVar <- W4.freshBoundVar sym symbol (W4.BaseBVRepr n)
      let ptr = CLM.LLVMPointer (W4.varExpr sym regVar) (W4.varExpr sym offVar)
      return $ MacawRegVar (MacawRegEntry (MS.typeToCrucible repr) ptr) (Ctx.empty Ctx.:> regVar Ctx.:> offVar)
    _ -> throwHere $ UnsupportedRegisterType (Some (MS.typeToCrucible repr))


lookupBlocks ::
  forall sym arch bin.
  KnownBinary bin =>
  ConcreteBlock arch bin ->
  EquivM sym arch (CC.Some (Compose [] (MD.ParsedBlock arch)))
lookupBlocks b = do
  binCtx <- getBinCtx @bin
  let pfm = parsedFunctionMap binCtx
  case M.assocs $ M.unions $ fmap snd $ IM.lookupLE i pfm of
    [(start', CC.Some (ParsedBlockMap pbm))] -> do
      case concreteBlockEntry b of
        BlockEntryInitFunction -> do
          funAddr <- segOffToAddr start'
          when (funAddr /= start) $
            throwHere $ LookupNotAtFunctionStart start
        _ -> return ()
      let result = concat $ IM.elems $ IM.intersecting pbm i
      return $ CC.Some (Compose result)
    blks -> throwHere $ NoUniqueFunctionOwner i (fst <$> blks)
  where
  start@(ConcreteAddress addr) = concreteAddress b
  end = ConcreteAddress (MM.MemAddr (MM.addrBase addr) maxBound)
  i = IM.OpenInterval start end


targetReturnPtr ::
  ValidSym sym =>
  ValidArch arch =>
  sym ->
  BlockTarget arch bin ->
  IO (CS.RegValue sym (CC.MaybeType (CLM.LLVMPointerType (MM.ArchAddrWidth arch))))
targetReturnPtr sym blkt | Just blk <- targetReturn blkt = do
  ptr <- concreteToLLVM sym (concreteAddress blk)
  return $ W4P.justPartExpr sym ptr
targetReturnPtr sym _ = return $ W4P.maybePartExpr sym Nothing


-- | From the given starting point, find all of the accessible
-- blocks
getSubBlocks ::
  forall sym arch bin.
  KnownBinary bin =>
  ConcreteBlock arch bin ->
  EquivM sym arch [BlockTarget arch bin]
getSubBlocks b = do
  pfm <- parsedFunctionMap <$> getBinCtx @bin
  case M.assocs $ M.unions $ fmap snd $ IM.lookupLE i pfm of
    [(_, CC.Some (ParsedBlockMap pbm))] -> do
      let pbs = concat $ IM.elems $ IM.intersecting pbm i
      concat <$> mapM (concreteValidJumpTargets pbs) pbs
    blks -> throwHere $ NoUniqueFunctionOwner i (fst <$> blks)
  where
  start@(ConcreteAddress saddr) = concreteAddress b
  end = ConcreteAddress (MM.MemAddr (MM.addrBase saddr) maxBound)
  i = IM.OpenInterval start end

concreteValidJumpTargets ::
  forall bin sym arch ids.
  KnownBinary bin =>
  ValidArch arch =>
  [MD.ParsedBlock arch ids] ->
  MD.ParsedBlock arch ids ->
  EquivM sym arch [BlockTarget arch bin]
concreteValidJumpTargets allPbs pb = do
  targets <- concreteJumpTargets pb
  thisAddr <- segOffToAddr (MD.pblockAddr pb)
  addrs <- mapM (segOffToAddr . MD.pblockAddr) allPbs
  let
    isTargetExternal btgt = not ((concreteAddress (targetCall btgt)) `elem` addrs)
    isTargetBackJump btgt = (concreteAddress (targetCall btgt)) < thisAddr
    isTargetArch btgt = concreteBlockEntry (targetCall btgt) == BlockEntryPostArch

    isTargetValid btgt = isTargetArch btgt || isTargetExternal btgt || isTargetBackJump btgt
  return $ filter isTargetValid targets

mkConcreteBlock ::
  KnownBinary bin =>
  BlockEntryKind arch ->
  ConcreteAddress arch ->
  ConcreteBlock arch bin
mkConcreteBlock k a = ConcreteBlock a k W4.knownRepr

concreteNextIPs ::
  ValidArch arch =>
  MM.RegState (MM.ArchReg arch) (MM.Value arch ids) ->
  [ConcreteAddress arch]
concreteNextIPs st = concreteValueAddress $ st ^. MM.curIP

concreteValueAddress ::
  MM.Value arch ids (MM.BVType (MM.ArchAddrWidth arch)) ->
  [ConcreteAddress arch]
concreteValueAddress = \case
  MM.RelocatableValue _ addr -> [ConcreteAddress addr]
  MM.AssignedValue (MM.Assignment _ rhs) -> case rhs of
    MM.EvalApp (MM.Mux _ _ b1 b2) -> concreteValueAddress b1 ++ concreteValueAddress b2
    _ -> []
  _ -> []

concreteJumpTargets ::
  forall bin sym arch ids.
  KnownBinary bin =>
  ValidArch arch =>
  MD.ParsedBlock arch ids ->
  EquivM sym arch [BlockTarget arch bin]
concreteJumpTargets pb = case MD.pblockTermStmt pb of
  MD.ParsedCall st ret -> go (concreteNextIPs st) ret

  MD.PLTStub st _ _ -> case MapF.lookup (MM.ip_reg @(MM.ArchReg arch)) st of
    Just addr -> go (concreteValueAddress addr) Nothing
    _ -> return $ []
  MD.ParsedJump _ tgt -> do
    blk <- mkConcreteBlock BlockEntryJump <$> segOffToAddr tgt
    return $ [ BlockTarget blk Nothing ]
  MD.ParsedBranch _ _ t f -> do
    blk_t <- mkConcreteBlock BlockEntryJump <$> segOffToAddr t
    blk_f <- mkConcreteBlock BlockEntryJump <$> segOffToAddr f
    return $ [ BlockTarget blk_t Nothing, BlockTarget blk_f Nothing ]
  MD.ParsedLookupTable st _ _ -> go (concreteNextIPs st) Nothing
  MD.ParsedArchTermStmt _ st ret -> do
    ret_blk <- fmap (mkConcreteBlock BlockEntryPostArch) <$> mapM segOffToAddr ret
    return $ [ BlockTarget (mkConcreteBlock BlockEntryPostArch next) ret_blk
             | next <- (concreteNextIPs st) ]
  _ -> return []
  where
    go ::
      [ConcreteAddress arch] ->
      Maybe (MM.ArchSegmentOff arch) ->
      EquivM sym arch [BlockTarget arch bin]
    go next_ips ret = do
      ret_blk <- fmap (mkConcreteBlock BlockEntryPostFunction) <$> mapM segOffToAddr ret
      return $ [ BlockTarget (mkConcreteBlock BlockEntryInitFunction next) ret_blk | next <- next_ips ]


segOffToAddr ::
  MM.ArchSegmentOff arch ->
  EquivM sym arch (ConcreteAddress arch)
segOffToAddr off = concreteFromAbsolute <$>
  liftMaybe (MM.segoffAsAbsoluteAddr off) (NonConcreteParsedBlockAddress off)

liftMaybe :: Maybe a -> InnerEquivalenceError arch -> EquivM sym arch a
liftMaybe Nothing e = throwHere e
liftMaybe (Just a) _ = pure a

runDiscovery ::
  ValidArch arch =>
  PB.LoadedELF arch ->
  ExceptT (EquivalenceError arch) IO (MM.MemSegmentOff (MM.ArchAddrWidth arch), ParsedFunctionMap arch)
runDiscovery elf = do
  let
    bin = PB.loadedBinary elf
    archInfo = PB.archInfo elf
  entries <- toList <$> MBL.entryPoints bin
  pfm <- goDiscoveryState $
    MD.cfgFromAddrs archInfo (MBL.memoryImage bin) M.empty entries []
  return (head entries, pfm)
  where
  goDiscoveryState ds = id
    . fmap (IM.unionsWith M.union)
    . mapM goSomeDiscoveryFunInfo
    . M.assocs
    $ ds ^. MD.funInfo
  goSomeDiscoveryFunInfo (entrySegOff, CC.Some dfi) = markEntryPoint entrySegOff <$> goDiscoveryFunInfo dfi
  goDiscoveryFunInfo dfi = fmap (ParsedBlockMap . IM.fromListWith (++)) . sequence $
    [ (\addrs -> (addrs, [pb])) <$> archSegmentOffToInterval blockSegOff (MD.blockSize pb)
    | (blockSegOff, pb) <- M.assocs (dfi ^. MD.parsedBlocks)
    ]

archSegmentOffToInterval ::
  (MonadError (EquivalenceError arch) m, MM.MemWidth (MM.ArchAddrWidth arch)) =>
  MM.ArchSegmentOff arch ->
  Int ->
  m (IM.Interval (ConcreteAddress arch))
archSegmentOffToInterval segOff size = case MM.segoffAsAbsoluteAddr segOff of
  Just w -> pure (IM.IntervalCO start (start `addressAddOffset` fromIntegral size))
    where start = concreteFromAbsolute w
  Nothing -> throwError $ equivalenceError $ StrangeBlockAddress segOff

buildBlockMap ::
  [PatchPair arch] ->
  BlockMapping arch ->
  BlockMapping arch
buildBlockMap pairs bm = foldr go bm pairs
  where
    go :: PatchPair arch -> BlockMapping arch -> BlockMapping arch
    go (PatchPair orig patched) (BlockMapping m) =
      BlockMapping $ M.alter (doAddAddr (concreteAddress patched)) (concreteAddress orig) m

-- | Prefer existing entries
doAddAddr ::
  ConcreteAddress arch ->
  Maybe (ConcreteAddress arch) ->
  Maybe (ConcreteAddress arch)
doAddAddr _ (Just addr) = Just addr
doAddAddr addr Nothing = Just addr


getAllPairs :: EquivM sym arch [PatchPair arch]
getAllPairs = do
  open <- gets (M.keys . stOpenTriples)
  failures <- gets (M.keys . stFailedTriples)
  successes <- gets (M.keys  . stProvenTriples)
  return $ open ++ successes ++ failures

getBlockMap :: EquivM sym arch (BlockMapping arch)
getBlockMap = do
  BlockMapping m <- asks envBlockMapping
  pairs <- getAllPairs
  let m' =
        foldr (\(PatchPair o p) ->
                 M.alter (doAddAddr (concreteAddress p)) (concreteAddress o)) m pairs
  return $ BlockMapping m'


mkIPEquivalence ::
  EquivM sym arch (
    CLM.LLVMPtr sym (MM.ArchAddrWidth arch) ->
    CLM.LLVMPtr sym (MM.ArchAddrWidth arch) ->
    IO (W4.Pred sym)
    )
mkIPEquivalence = do
  BlockMapping blockMap <- getBlockMap
  let assocs = filter (\(blkO, blkP) -> blkO /= blkP) $ M.assocs blockMap
  withSymIO $ \sym -> do
    ips <- traverse (concreteToLLVM sym . fst) assocs
    ips' <- traverse (concreteToLLVM sym . snd) assocs
    let [regSS, offSS, regSS', offSS', ipEqSS] = map userSymbol $
          ["orig_reg", "orig_off", "rewrite_reg", "rewrite_off", "related_ips"]
    regionVar  <- W4.freshBoundVar sym regSS  W4.knownRepr
    offsetVar  <- W4.freshBoundVar sym offSS  W4.knownRepr
    regionVar' <- W4.freshBoundVar sym regSS' W4.knownRepr
    offsetVar' <- W4.freshBoundVar sym offSS' W4.knownRepr

    let ipArg  = CLM.LLVMPointer (W4.varExpr sym regionVar ) (W4.varExpr sym offsetVar )
        ipArg' = CLM.LLVMPointer (W4.varExpr sym regionVar') (W4.varExpr sym offsetVar')
        iop <&&> iop' = do
          p  <- iop
          p' <- iop'
          W4.andPred sym p p'
    alternatives <- flipZipWithM ips ips' $ \ip ip' -> MT.llvmPtrEq sym ipArg ip <&&> MT.llvmPtrEq sym ipArg' ip'
    anyAlternative <- foldM (W4.orPred sym) (W4.falsePred sym) alternatives

    tableEntries <- forM ips $ \ip -> MT.llvmPtrEq sym ipArg ip
    isInTable <- foldM (W4.orPred sym) (W4.falsePred sym) tableEntries

    plainEq <- MT.llvmPtrEq sym ipArg ipArg'
    -- only if the first entry is in this table do we consult this table, otherwise
    -- we require actual pointer equality
    body <- W4.baseTypeIte sym isInTable anyAlternative plainEq

    ipEqSymFn <- W4.definedFn sym
      ipEqSS
      (Ctx.empty `Ctx.extend` regionVar `Ctx.extend` offsetVar `Ctx.extend` regionVar' `Ctx.extend` offsetVar')
      body
      W4.AlwaysUnfold

    pure $ \(CLM.LLVMPointer region offset) (CLM.LLVMPointer region' offset') -> W4.applySymFn sym ipEqSymFn
      (Ctx.empty `Ctx.extend` region `Ctx.extend` offset `Ctx.extend` region' `Ctx.extend` offset')


data RegEquivCheck sym arch where
  RegEquivCheck ::
    (forall tp.
      MT.ExitCase ->
      MM.ArchReg arch tp ->
      MacawRegEntry sym tp ->
      MacawRegEntry sym tp ->
      IO (W4.Pred sym)) ->
    RegEquivCheck sym arch

regEntryEquiv ::
  MacawRegEntry sym tp ->
  MacawRegEntry sym tp ->
  EquivM sym arch (W4.Pred sym)
regEntryEquiv (MacawRegEntry repr bv1) (MacawRegEntry _ bv2) = case repr of
  CLM.LLVMPointerRepr _ -> withSymIO $ \sym -> MT.llvmPtrEq sym bv1 bv2
  _ -> throwHere $ UnsupportedRegisterType (Some repr)

-- mkRegEquivCheck ::
--   forall sym arch.
--   SimulationResult sym arch ->
--   SimulationResult sym arch ->
--   EquivM sym arch (RegEquivCheck sym arch)
-- mkRegEquivCheck _simResultO _simResultP = do

--   withSymIO $ \sym -> return $ RegEquivCheck $ \ecase reg (MacawRegEntry repr bvO) (MacawRegEntry _ bvP) -> do
--      -- TODO: Stack pointer need not be equivalent in general, but we need to treat stack-allocated
--     case repr of
--       CLM.LLVMPointerRepr _ -> 
--         case ecase of
--           -- | For registers used for function arguments, we assert equivalence when
--           -- the jump target is known to be a function call
--           MT.ExitCall
--             | funCallArg reg -> MT.llvmPtrEq sym bvO bvP
--           MT.ExitReturn
--             | funCallRet reg -> MT.llvmPtrEq sym bvO bvP

--           -- FIXME: We need to calculate the equivalence condition on functions based on
--           -- how they are used
--           _ | funCallStable reg -> MT.llvmPtrEq sym bvO bvP
--           _ -> return $ W4.truePred sym
--       _ -> error "Unsupported register type"


flipZipWithM :: Monad m => [a] -> [b] -> (a -> b -> m c) -> m [c]
flipZipWithM as bs f = zipWithM f as bs

userSymbol :: String -> W4.SolverSymbol
userSymbol s = case W4.userSymbol s of
  Left err -> error $ "Bad solver symbol:" ++ show err
  Right ss -> ss

concreteToLLVM ::
  ( 
   w ~ MM.ArchAddrWidth arch, MM.MemWidth w, KnownNat w, 1 <= w
  , W4.IsExprBuilder sym
  ) =>
  sym ->
  ConcreteAddress arch ->
  IO (CLM.LLVMPtr sym w)
concreteToLLVM sym c = do
  region <- W4.natLit sym 0
  offset <- W4.bvLit sym W4.knownRepr (BVS.mkBV W4.knownRepr (toInteger (absoluteAddress c)))
  pure (CLM.LLVMPointer region offset)
