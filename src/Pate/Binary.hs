{- Helper functions for loading binaries -}

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


module Pate.Binary
  ( ArchConstraints(..)
  , LoadedELF(..)
  , loadELF
  )
where

import           GHC.TypeLits

import qualified Data.ByteString as BS
import           Data.Proxy

import           Data.Parameterized.Classes

import qualified Data.ElfEdit as E

import qualified Data.Macaw.Symbolic as MS
import qualified Data.Macaw.Memory.ElfLoader as MME
import qualified Data.Macaw.Architecture.Info as MI
import qualified Data.Macaw.CFG as MC
import qualified Data.Macaw.BinaryLoader as MBL

import           Data.ElfEdit ( parseElf, ElfGetResult(..) )

data LoadedELF arch =
  LoadedELF
    { archInfo :: MI.ArchitectureInfo arch
    , loadedBinary :: MBL.LoadedBinary arch (E.Elf (MC.ArchAddrWidth arch))
    }

class
  ( MC.MemWidth (MC.ArchAddrWidth arch)
  , MBL.BinaryLoader arch (E.Elf (MC.ArchAddrWidth arch))
  , E.ElfWidthConstraints (MC.ArchAddrWidth arch)
  , MS.SymArchConstraints arch
  , 16 <= MC.RegAddrWidth (MC.ArchReg arch)
  ) => ArchConstraints arch where
  binArchInfo :: MBL.LoadedBinary arch (E.Elf (MC.ArchAddrWidth arch)) -> MI.ArchitectureInfo arch



loadELF ::
  forall arch.
  ArchConstraints arch =>
  Proxy arch ->
  FilePath ->
  IO (LoadedELF arch)
loadELF _ path = do
  bs <- BS.readFile path
  elf <- doParse bs
  mem <- MBL.loadBinary MME.defaultLoadOptions elf
  return $ LoadedELF
    { archInfo = binArchInfo mem
    , loadedBinary = mem
    }
  where
    archWidthRepr :: MC.AddrWidthRepr (MC.ArchAddrWidth arch)
    archWidthRepr = MC.addrWidthRepr (Proxy @(MC.ArchAddrWidth arch))

    doParse :: BS.ByteString -> IO (E.Elf (MC.ArchAddrWidth arch))
    doParse bs = case parseElf bs of
      ElfHeaderError off msg -> error $ "Error while parsing ELF header at " ++ show off ++ ": " ++ msg
      Elf32Res [] e32 -> return $ getElf e32
      Elf64Res [] e64 -> return $ getElf e64
      Elf32Res errs _ -> error $ "Errors while parsing ELF file: " ++ show errs
      Elf64Res errs _ -> error $ "Errors while parsing ELF file: " ++ show errs
    
      
    getElf :: forall w. MC.MemWidth w => E.Elf w -> E.Elf (MC.ArchAddrWidth arch)
    getElf e = case testEquality (MC.addrWidthRepr e) archWidthRepr of
      Just Refl -> e
      Nothing -> error "Unexpected arch"