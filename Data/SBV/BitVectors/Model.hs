-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.BitVectors.Model
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Instance declarations for our symbolic world
-----------------------------------------------------------------------------

{-# OPTIONS_GHC -fno-warn-orphans   #-}
{-# LANGUAGE CPP                    #-}
{-# LANGUAGE TypeSynonymInstances   #-}
{-# LANGUAGE BangPatterns           #-}
{-# LANGUAGE PatternGuards          #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE Rank2Types             #-}

module Data.SBV.BitVectors.Model (
    Mergeable(..), EqSymbolic(..), OrdSymbolic(..), SDivisible(..), Uninterpreted(..), SIntegral
  , ite, iteLazy, sBranch, sAssert, sAssertCont, sbvTestBit, sbvPopCount, setBitTo
  , sbvShiftLeft, sbvShiftRight, sbvRotateLeft, sbvRotateRight, sbvSignedShiftArithRight, (.^)
  , allEqual, allDifferent, inRange, sElem, oneIf, blastBE, blastLE, fullAdder, fullMultiplier
  , lsb, msb, genVar, genVar_, forall, forall_, exists, exists_
  , constrain, pConstrain, sBool, sBools, sWord8, sWord8s, sWord16, sWord16s, sWord32
  , sWord32s, sWord64, sWord64s, sInt8, sInt8s, sInt16, sInt16s, sInt32, sInt32s, sInt64
  , sInt64s, sInteger, sIntegers, sReal, sReals, sFloat, sFloats, sDouble, sDoubles, slet
  , sIntegerToSReal, fpToSReal, sRealToSFloat, sRealToSDouble
  , sWord32ToSFloat, sWord64ToSDouble, sFloatToSWord32, sDoubleToSWord64, blastSFloat, blastSDouble
  , fusedMA, liftFPPredicate
  , liftQRem, liftDMod, symbolicMergeWithKind
  , genLiteral, genFromCW, genMkSymVar
  , reduceInPathCondition
  )
  where

import Control.Monad   (when, liftM)

import Data.Array      (Array, Ix, listArray, elems, bounds, rangeSize)
import Data.Bits       (Bits(..))
import Data.Int        (Int8, Int16, Int32, Int64)
import Data.List       (genericLength, genericIndex, genericTake, unzip4, unzip5, unzip6, unzip7, intercalate)
import Data.Maybe      (fromMaybe)
import Data.Word       (Word8, Word16, Word32, Word64)

import Data.Binary.IEEE754 (wordToFloat, wordToDouble, floatToWord, doubleToWord)

import qualified Data.Map as M

import qualified Control.Exception as C

import Test.QuickCheck                           (Testable(..), Arbitrary(..))
import qualified Test.QuickCheck         as QC   (whenFail)
import qualified Test.QuickCheck.Monadic as QC   (monadicIO, run)
import System.Random

import Data.SBV.BitVectors.AlgReals
import Data.SBV.BitVectors.Data
import Data.SBV.Utils.Boolean

import Data.SBV.Provers.Prover (isSBranchFeasibleInState, isConditionSatisfiable, isVacuous, prove, defaultSMTCfg)
import Data.SBV.SMT.SMT (SafeResult(..), SatResult(..), ThmResult, getModelDictionary)

import Data.SBV.BitVectors.Symbolic
import Data.SBV.BitVectors.Operations

-- | Newer versions of GHC (Starting with 7.8 I think), distinguishes between FiniteBits and Bits classes.
-- We should really use FiniteBitSize for SBV which would make things better. In the interim, just work
-- around pesky warnings..
ghcBitSize :: Bits a => a -> Int
#if __GLASGOW_HASKELL__ >= 708
ghcBitSize x = maybe (error "SBV.ghcBitSize: Unexpected non-finite usage!") id (bitSizeMaybe x)
#else
ghcBitSize = bitSize
#endif

mkSymOpSC :: (SW -> SW -> Maybe SW) -> Op -> State -> Kind -> SW -> SW -> IO SW
mkSymOpSC shortCut op st k a b = maybe (newExpr st k (SBVApp op [a, b])) return (shortCut a b)

mkSymOp :: Op -> State -> Kind -> SW -> SW -> IO SW
mkSymOp = mkSymOpSC (const (const Nothing))

-- Symbolic-Word class instances

-- | Generate a finite symbolic bitvector, named
genVar :: (Random a, SymWord a) => Maybe Quantifier -> Kind -> String -> Symbolic (SBV a)
genVar q k = mkSymSBV q k . Just

-- | Generate a finite symbolic bitvector, unnamed
genVar_ :: (Random a, SymWord a) => Maybe Quantifier -> Kind -> Symbolic (SBV a)
genVar_ q k = mkSymSBV q k Nothing

-- | Generate a finite constant bitvector
genLiteral :: Integral a => Kind -> a -> SBV b
genLiteral k = SBV . SVal k . Left . mkConstCW k

-- | Convert a constant to an integral value
genFromCW :: Integral a => CW -> a
genFromCW (CW _ (CWInteger x)) = fromInteger x
genFromCW c                    = error $ "genFromCW: Unsupported non-integral value: " ++ show c

-- | Generically make a symbolic var
genMkSymVar :: (Random a, SymWord a) => Kind -> Maybe Quantifier -> Maybe String -> Symbolic (SBV a)
genMkSymVar k mbq Nothing  = genVar_ mbq k
genMkSymVar k mbq (Just s) = genVar  mbq k s

instance SymWord Bool where
  mkSymWord  = genMkSymVar KBool
  literal x  = SBV (svBool x)
  fromCW     = cwToBool

instance SymWord Word8 where
  mkSymWord  = genMkSymVar (KBounded False 8)
  literal    = genLiteral  (KBounded False 8)
  fromCW     = genFromCW

instance SymWord Int8 where
  mkSymWord  = genMkSymVar (KBounded True 8)
  literal    = genLiteral  (KBounded True 8)
  fromCW     = genFromCW

instance SymWord Word16 where
  mkSymWord  = genMkSymVar (KBounded False 16)
  literal    = genLiteral  (KBounded False 16)
  fromCW     = genFromCW

instance SymWord Int16 where
  mkSymWord  = genMkSymVar (KBounded True 16)
  literal    = genLiteral  (KBounded True 16)
  fromCW     = genFromCW

instance SymWord Word32 where
  mkSymWord  = genMkSymVar (KBounded False 32)
  literal    = genLiteral  (KBounded False 32)
  fromCW     = genFromCW

instance SymWord Int32 where
  mkSymWord  = genMkSymVar (KBounded True 32)
  literal    = genLiteral  (KBounded True 32)
  fromCW     = genFromCW

instance SymWord Word64 where
  mkSymWord  = genMkSymVar (KBounded False 64)
  literal    = genLiteral  (KBounded False 64)
  fromCW     = genFromCW

instance SymWord Int64 where
  mkSymWord  = genMkSymVar (KBounded True 64)
  literal    = genLiteral  (KBounded True 64)
  fromCW     = genFromCW

instance SymWord Integer where
  mkSymWord  = genMkSymVar KUnbounded
  literal    = SBV . SVal KUnbounded . Left . mkConstCW KUnbounded
  fromCW     = genFromCW

instance SymWord AlgReal where
  mkSymWord  = genMkSymVar KReal
  literal    = SBV . SVal KReal . Left . CW KReal . CWAlgReal
  fromCW (CW _ (CWAlgReal a)) = a
  fromCW c                    = error $ "SymWord.AlgReal: Unexpected non-real value: " ++ show c
  -- AlgReal needs its own definition of isConcretely
  -- to make sure we avoid using unimplementable Haskell functions
  isConcretely (SBV (SVal KReal (Left (CW KReal (CWAlgReal v))))) p
     | isExactRational v = p v
  isConcretely _ _       = False

instance SymWord Float where
  mkSymWord  = genMkSymVar KFloat
  literal    = SBV . SVal KFloat . Left . CW KFloat . CWFloat
  fromCW (CW _ (CWFloat a)) = a
  fromCW c                  = error $ "SymWord.Float: Unexpected non-float value: " ++ show c
  -- For Float, we conservatively return 'False' for isConcretely. The reason is that
  -- this function is used for optimizations when only one of the argument is concrete,
  -- and in the presence of NaN's it would be incorrect to do any optimization
  isConcretely _ _ = False

instance SymWord Double where
  mkSymWord  = genMkSymVar KDouble
  literal    = SBV . SVal KDouble . Left . CW KDouble . CWDouble
  fromCW (CW _ (CWDouble a)) = a
  fromCW c                   = error $ "SymWord.Double: Unexpected non-double value: " ++ show c
  -- For Double, we conservatively return 'False' for isConcretely. The reason is that
  -- this function is used for optimizations when only one of the argument is concrete,
  -- and in the presence of NaN's it would be incorrect to do any optimization
  isConcretely _ _ = False

------------------------------------------------------------------------------------
-- * Smart constructors for creating symbolic values. These are not strictly
-- necessary, as they are mere aliases for 'symbolic' and 'symbolics', but 
-- they nonetheless make programming easier.
------------------------------------------------------------------------------------
-- | Declare an 'SBool'
sBool :: String -> Symbolic SBool
sBool = symbolic

-- | Declare a list of 'SBool's
sBools :: [String] -> Symbolic [SBool]
sBools = symbolics

-- | Declare an 'SWord8'
sWord8 :: String -> Symbolic SWord8
sWord8 = symbolic

-- | Declare a list of 'SWord8's
sWord8s :: [String] -> Symbolic [SWord8]
sWord8s = symbolics

-- | Declare an 'SWord16'
sWord16 :: String -> Symbolic SWord16
sWord16 = symbolic

-- | Declare a list of 'SWord16's
sWord16s :: [String] -> Symbolic [SWord16]
sWord16s = symbolics

-- | Declare an 'SWord32'
sWord32 :: String -> Symbolic SWord32
sWord32 = symbolic

-- | Declare a list of 'SWord32's
sWord32s :: [String] -> Symbolic [SWord32]
sWord32s = symbolics

-- | Declare an 'SWord64'
sWord64 :: String -> Symbolic SWord64
sWord64 = symbolic

-- | Declare a list of 'SWord64's
sWord64s :: [String] -> Symbolic [SWord64]
sWord64s = symbolics

-- | Declare an 'SInt8'
sInt8 :: String -> Symbolic SInt8
sInt8 = symbolic

-- | Declare a list of 'SInt8's
sInt8s :: [String] -> Symbolic [SInt8]
sInt8s = symbolics

-- | Declare an 'SInt16'
sInt16 :: String -> Symbolic SInt16
sInt16 = symbolic

-- | Declare a list of 'SInt16's
sInt16s :: [String] -> Symbolic [SInt16]
sInt16s = symbolics

-- | Declare an 'SInt32'
sInt32 :: String -> Symbolic SInt32
sInt32 = symbolic

-- | Declare a list of 'SInt32's
sInt32s :: [String] -> Symbolic [SInt32]
sInt32s = symbolics

-- | Declare an 'SInt64'
sInt64 :: String -> Symbolic SInt64
sInt64 = symbolic

-- | Declare a list of 'SInt64's
sInt64s :: [String] -> Symbolic [SInt64]
sInt64s = symbolics

-- | Declare an 'SInteger'
sInteger:: String -> Symbolic SInteger
sInteger = symbolic

-- | Declare a list of 'SInteger's
sIntegers :: [String] -> Symbolic [SInteger]
sIntegers = symbolics

-- | Declare an 'SReal'
sReal:: String -> Symbolic SReal
sReal = symbolic

-- | Declare a list of 'SReal's
sReals :: [String] -> Symbolic [SReal]
sReals = symbolics

-- | Declare an 'SFloat'
sFloat :: String -> Symbolic SFloat
sFloat = symbolic

-- | Declare a list of 'SFloat's
sFloats :: [String] -> Symbolic [SFloat]
sFloats = symbolics

-- | Declare an 'SDouble'
sDouble :: String -> Symbolic SDouble
sDouble = symbolic

-- | Declare a list of 'SDouble's
sDoubles :: [String] -> Symbolic [SDouble]
sDoubles = symbolics

-- | Promote an SInteger to an SReal
sIntegerToSReal :: SInteger -> SReal
sIntegerToSReal x
  | Just i <- unliteral x = literal $ fromInteger i
  | True                  = SBV (SVal KReal (Right (cache y)))
  where y st = do xsw <- sbvToSW st x
                  newExpr st KReal (SBVApp (Uninterpreted "to_real") [xsw])

-- | Promote an SFloat/SDouble to an SReal
fpToSReal :: (Real a, Floating a, SymWord a) => SBV a -> SReal
fpToSReal x
  | Just i <- unliteral x = literal $ fromRational $ toRational i
  | True                  = SBV (SVal KReal (Right (cache y)))
  where y st = do xsw <- sbvToSW st x
                  newExpr st KReal (SBVApp (Uninterpreted "fp.to_real") [xsw])

-- | Promote (demote really) an SReal to an SFloat.
--
-- NB: This function doesn't work on concrete values at the Haskell
-- level since we have no easy way of honoring the rounding-mode given.
sRealToSFloat :: SRoundingMode -> SReal -> SFloat
sRealToSFloat rm x = SBV (SVal KFloat (Right (cache y)))
  where y st = do swm <- sbvToSW st rm
                  xsw <- sbvToSW st x
                  newExpr st KFloat (SBVApp (FPRound "(_ to_fp 8 24)") [swm, xsw])

-- | Promote (demote really) an SReal to an SDouble.
--
-- NB: This function doesn't work on concrete values at the Haskell
-- level since we have no easy way of honoring the rounding-mode given.
sRealToSDouble :: SRoundingMode -> SReal -> SFloat
sRealToSDouble rm x = SBV (SVal KFloat (Right (cache y)))
  where y st = do swm <- sbvToSW st rm
                  xsw <- sbvToSW st x
                  newExpr st KDouble (SBVApp (FPRound "(_ to_fp 11 53)") [swm, xsw])

-- | Reinterpret a 32-bit word as an 'SFloat'.
sWord32ToSFloat :: SWord32 -> SFloat
sWord32ToSFloat x
    | Just w <- unliteral x = literal (wordToFloat w)
    | True                  = SBV (SVal KFloat (Right (cache y)))
   where y st = do xsw <- sbvToSW st x
                   newExpr st KFloat (SBVApp (FPRound "(_ to_fp 8 24)") [xsw])

-- | Reinterpret a 64-bit word as an 'SDouble'. Note that this function does not
-- directly work on concrete values, since IEEE754 NaN values are not unique, and
-- thus do not directly map to SDouble
sWord64ToSDouble :: SWord64 -> SDouble
sWord64ToSDouble x
    | Just w <- unliteral x = literal (wordToDouble w)
    | True                  = SBV (SVal KDouble (Right (cache y)))
   where y st = do xsw <- sbvToSW st x
                   newExpr st KDouble (SBVApp (FPRound "(_ to_fp 11 53)") [xsw])

-- | Relationally assert the equivalence between an 'SFloat' and an 'SWord32', when the bit-pattern
-- is interpreted as either type. Useful when analyzing components of a floating point number. Note
-- that this cannot be written as a function, since IEEE754 NaN values are not unique. That is,
-- given a float, there isn't a unique sign/mantissa/exponent that we can match it to.
--
-- The use case would be code of the form:
--
-- @
--     do w <- free_
--        constrain $ sFloatToSWord32 f w
--        ...
-- @
--
-- At which point the variable @w@ can be used to access the bits of the float 'f'.
sFloatToSWord32 :: SFloat -> SWord32 -> SBool
sFloatToSWord32 fVal wVal
  | Just f <- unliteral fVal, not (isNaN f) = wVal .== literal (floatToWord f)
  | True                                    = result `is` fVal
 where result   = sWord32ToSFloat wVal
       a `is` b = (checkNaN a &&& checkNaN b) ||| (a .== b)
       checkNaN = liftFPPredicate "fp.isNaN" isNaN

-- | Relationally assert the equivalence between an 'SDouble' and an 'SWord64', when the bit-pattern
-- is interpreted as either type. See the comments for 'sFloatToSWord32' for details.
sDoubleToSWord64 :: SDouble -> SWord64 -> SBool
sDoubleToSWord64 fVal wVal
  | Just f <- unliteral fVal, not (isNaN f) = wVal .== literal (doubleToWord f)
  | True                                    = result `is` fVal
 where result   = sWord64ToSDouble wVal
       a `is` b = (checkNaN a &&& checkNaN b) ||| (a .== b)
       checkNaN = liftFPPredicate "fp.isNaN" isNaN

-- | Relationally extract the sign\/exponent\/mantissa of a single-precision float. Due to the
-- non-unique representation of NaN's, we have to do this function relationally, much like
-- 'sFloatToSWord32'.
blastSFloat :: SFloat -> (SBool, [SBool], [SBool]) -> SBool
blastSFloat fVal (s, expt, mant)
  | length expt /= 8 || length mant /= 23  = error "SBV.blastSFloat: Need 8-bit expt and 23 bit mantissa"
  | True                                   = sFloatToSWord32 fVal wVal
 where bits = s : expt ++ mant
       wVal = sum [ite b (2^c) 0 | (b, c) <- zip bits (reverse [(0::Word32) .. 31])]

-- | Relationally extract the sign\/exponent\/mantissa of a double-precision float. Due to the
-- non-unique representation of NaN's, we have to do this function relationally, much like
-- 'sDoubleToSWord64'.
blastSDouble :: SDouble -> (SBool, [SBool], [SBool]) -> SBool
blastSDouble fVal (s, expt, mant)
  | length expt /= 11 || length mant /= 52 = error "SBV.blastSDouble: Need 11-bit expt and 52 bit mantissa"
  | True                                   = sDoubleToSWord64 fVal wVal
 where bits = s : expt ++ mant
       wVal = sum [ite b (2^c) 0 | (b, c) <- zip bits (reverse [(0::Word64) .. 63])]

-- | Symbolic Equality. Note that we can't use Haskell's 'Eq' class since Haskell insists on returning Bool
-- Comparing symbolic values will necessarily return a symbolic value.
--
-- Minimal complete definition: '.=='
infix 4 .==, ./=
class EqSymbolic a where
  (.==), (./=) :: a -> a -> SBool
  -- minimal complete definition: .==
  x ./= y = bnot (x .== y)

-- | Symbolic Comparisons. Similar to 'Eq', we cannot implement Haskell's 'Ord' class
-- since there is no way to return an 'Ordering' value from a symbolic comparison.
-- Furthermore, 'OrdSymbolic' requires 'Mergeable' to implement if-then-else, for the
-- benefit of implementing symbolic versions of 'max' and 'min' functions.
--
-- Minimal complete definition: '.<'
infix 4 .<, .<=, .>, .>=
class (Mergeable a, EqSymbolic a) => OrdSymbolic a where
  (.<), (.<=), (.>), (.>=) :: a -> a -> SBool
  smin, smax :: a -> a -> a
  -- minimal complete definition: .<
  a .<= b    = a .< b ||| a .== b
  a .>  b    = b .<  a
  a .>= b    = b .<= a
  a `smin` b = ite (a .<= b) a b
  a `smax` b = ite (a .<= b) b a

{- We can't have a generic instance of the form:

instance Eq a => EqSymbolic a where
  x .== y = if x == y then true else false

even if we're willing to allow Flexible/undecidable instances..
This is because if we allow this it would imply EqSymbolic (SBV a);
since (SBV a) has to be Eq as it must be a Num. But this wouldn't be
the right choice obviously; as the Eq instance is bogus for SBV
for natural reasons..
-}

instance EqSymbolic (SBV a) where
  SBV x .== SBV y = SBV (svEqual x y)
  SBV x ./= SBV y = SBV (svNotEqual x y)

instance SymWord a => OrdSymbolic (SBV a) where
  SBV x .<  SBV y = SBV (svLessThan x y)
  SBV x .<= SBV y = SBV (svLessEq x y)
  SBV x .>  SBV y = SBV (svGreaterThan x y)
  SBV x .>= SBV y = SBV (svGreaterEq x y)

-- Bool
instance EqSymbolic Bool where
  x .== y = if x == y then true else false

-- Lists
instance EqSymbolic a => EqSymbolic [a] where
  []     .== []     = true
  (x:xs) .== (y:ys) = x .== y &&& xs .== ys
  _      .== _      = false

instance OrdSymbolic a => OrdSymbolic [a] where
  []     .< []     = false
  []     .< _      = true
  _      .< []     = false
  (x:xs) .< (y:ys) = x .< y ||| (x .== y &&& xs .< ys)

-- Maybe
instance EqSymbolic a => EqSymbolic (Maybe a) where
  Nothing .== Nothing = true
  Just a  .== Just b  = a .== b
  _       .== _       = false

instance (OrdSymbolic a) => OrdSymbolic (Maybe a) where
  Nothing .<  Nothing = false
  Nothing .<  _       = true
  Just _  .<  Nothing = false
  Just a  .<  Just b  = a .< b

-- Either
instance (EqSymbolic a, EqSymbolic b) => EqSymbolic (Either a b) where
  Left a  .== Left b  = a .== b
  Right a .== Right b = a .== b
  _       .== _       = false

instance (OrdSymbolic a, OrdSymbolic b) => OrdSymbolic (Either a b) where
  Left a  .< Left b  = a .< b
  Left _  .< Right _ = true
  Right _ .< Left _  = false
  Right a .< Right b = a .< b

-- 2-Tuple
instance (EqSymbolic a, EqSymbolic b) => EqSymbolic (a, b) where
  (a0, b0) .== (a1, b1) = a0 .== a1 &&& b0 .== b1

instance (OrdSymbolic a, OrdSymbolic b) => OrdSymbolic (a, b) where
  (a0, b0) .< (a1, b1) = a0 .< a1 ||| (a0 .== a1 &&& b0 .< b1)

-- 3-Tuple
instance (EqSymbolic a, EqSymbolic b, EqSymbolic c) => EqSymbolic (a, b, c) where
  (a0, b0, c0) .== (a1, b1, c1) = (a0, b0) .== (a1, b1) &&& c0 .== c1

instance (OrdSymbolic a, OrdSymbolic b, OrdSymbolic c) => OrdSymbolic (a, b, c) where
  (a0, b0, c0) .< (a1, b1, c1) = (a0, b0) .< (a1, b1) ||| ((a0, b0) .== (a1, b1) &&& c0 .< c1)

-- 4-Tuple
instance (EqSymbolic a, EqSymbolic b, EqSymbolic c, EqSymbolic d) => EqSymbolic (a, b, c, d) where
  (a0, b0, c0, d0) .== (a1, b1, c1, d1) = (a0, b0, c0) .== (a1, b1, c1) &&& d0 .== d1

instance (OrdSymbolic a, OrdSymbolic b, OrdSymbolic c, OrdSymbolic d) => OrdSymbolic (a, b, c, d) where
  (a0, b0, c0, d0) .< (a1, b1, c1, d1) = (a0, b0, c0) .< (a1, b1, c1) ||| ((a0, b0, c0) .== (a1, b1, c1) &&& d0 .< d1)

-- 5-Tuple
instance (EqSymbolic a, EqSymbolic b, EqSymbolic c, EqSymbolic d, EqSymbolic e) => EqSymbolic (a, b, c, d, e) where
  (a0, b0, c0, d0, e0) .== (a1, b1, c1, d1, e1) = (a0, b0, c0, d0) .== (a1, b1, c1, d1) &&& e0 .== e1

instance (OrdSymbolic a, OrdSymbolic b, OrdSymbolic c, OrdSymbolic d, OrdSymbolic e) => OrdSymbolic (a, b, c, d, e) where
  (a0, b0, c0, d0, e0) .< (a1, b1, c1, d1, e1) = (a0, b0, c0, d0) .< (a1, b1, c1, d1) ||| ((a0, b0, c0, d0) .== (a1, b1, c1, d1) &&& e0 .< e1)

-- 6-Tuple
instance (EqSymbolic a, EqSymbolic b, EqSymbolic c, EqSymbolic d, EqSymbolic e, EqSymbolic f) => EqSymbolic (a, b, c, d, e, f) where
  (a0, b0, c0, d0, e0, f0) .== (a1, b1, c1, d1, e1, f1) = (a0, b0, c0, d0, e0) .== (a1, b1, c1, d1, e1) &&& f0 .== f1

instance (OrdSymbolic a, OrdSymbolic b, OrdSymbolic c, OrdSymbolic d, OrdSymbolic e, OrdSymbolic f) => OrdSymbolic (a, b, c, d, e, f) where
  (a0, b0, c0, d0, e0, f0) .< (a1, b1, c1, d1, e1, f1) =    (a0, b0, c0, d0, e0) .<  (a1, b1, c1, d1, e1)
                                                       ||| ((a0, b0, c0, d0, e0) .== (a1, b1, c1, d1, e1) &&& f0 .< f1)

-- 7-Tuple
instance (EqSymbolic a, EqSymbolic b, EqSymbolic c, EqSymbolic d, EqSymbolic e, EqSymbolic f, EqSymbolic g) => EqSymbolic (a, b, c, d, e, f, g) where
  (a0, b0, c0, d0, e0, f0, g0) .== (a1, b1, c1, d1, e1, f1, g1) = (a0, b0, c0, d0, e0, f0) .== (a1, b1, c1, d1, e1, f1) &&& g0 .== g1

instance (OrdSymbolic a, OrdSymbolic b, OrdSymbolic c, OrdSymbolic d, OrdSymbolic e, OrdSymbolic f, OrdSymbolic g) => OrdSymbolic (a, b, c, d, e, f, g) where
  (a0, b0, c0, d0, e0, f0, g0) .< (a1, b1, c1, d1, e1, f1, g1) =    (a0, b0, c0, d0, e0, f0) .<  (a1, b1, c1, d1, e1, f1)
                                                               ||| ((a0, b0, c0, d0, e0, f0) .== (a1, b1, c1, d1, e1, f1) &&& g0 .< g1)

-- | Symbolic Numbers. This is a simple class that simply incorporates all number like
-- base types together, simplifying writing polymorphic type-signatures that work for all
-- symbolic numbers, such as 'SWord8', 'SInt8' etc. For instance, we can write a generic
-- list-minimum function as follows:
--
-- @
--    mm :: SIntegral a => [SBV a] -> SBV a
--    mm = foldr1 (\a b -> ite (a .<= b) a b)
-- @
--
-- It is similar to the standard 'Integral' class, except ranging over symbolic instances.
class (SymWord a, Num a, Bits a) => SIntegral a

-- 'SIntegral' Instances, including all possible variants except 'Bool', since booleans
-- are not numbers.
instance SIntegral Word8
instance SIntegral Word16
instance SIntegral Word32
instance SIntegral Word64
instance SIntegral Int8
instance SIntegral Int16
instance SIntegral Int32
instance SIntegral Int64
instance SIntegral Integer

-- Boolean combinators
instance Boolean SBool where
  true  = literal True
  false = literal False
  bnot (SBV b) = SBV (svNot b)
  SBV a &&& SBV b = SBV (svLAnd a b)
  SBV a ||| SBV b = SBV (svLOr a b)
  SBV a <+> SBV b = SBV (svLOr (svLAnd (a) (svNot b)) (svLAnd (svNot a) (b)))

-- | Returns (symbolic) true if all the elements of the given list are different.
allDifferent :: EqSymbolic a => [a] -> SBool
allDifferent (x:xs@(_:_)) = bAll (x ./=) xs &&& allDifferent xs
allDifferent _            = true

-- | Returns (symbolic) true if all the elements of the given list are the same.
allEqual :: EqSymbolic a => [a] -> SBool
allEqual (x:xs@(_:_))     = bAll (x .==) xs
allEqual _                = true

-- | Returns (symbolic) true if the argument is in range
inRange :: OrdSymbolic a => a -> (a, a) -> SBool
inRange x (y, z) = x .>= y &&& x .<= z

-- | Symbolic membership test
sElem :: EqSymbolic a => a -> [a] -> SBool
sElem x xs = bAny (.== x) xs

-- | Returns 1 if the boolean is true, otherwise 0.
oneIf :: (Num a, SymWord a) => SBool -> SBV a
oneIf t = ite t 1 0

-- | Predicate for optimizing word operations like (+) and (*).
isConcreteZero :: SBV a -> Bool
isConcreteZero (SBV (SVal _     (Left (CW _     (CWInteger n))))) = n == 0
isConcreteZero (SBV (SVal KReal (Left (CW KReal (CWAlgReal v))))) = isExactRational v && v == 0
isConcreteZero _                                                  = False

-- | Predicate for optimizing word operations like (+) and (*).
isConcreteOne :: SBV a -> Bool
isConcreteOne (SBV (SVal _     (Left (CW _     (CWInteger 1))))) = True
isConcreteOne (SBV (SVal KReal (Left (CW KReal (CWAlgReal v))))) = isExactRational v && v == 1
isConcreteOne _                                                  = False

-- Num instance for symbolic words.
instance (Ord a, Num a, SymWord a) => Num (SBV a) where
  fromInteger = literal . fromIntegral
  SBV x + SBV y = SBV (svPlus x y)
  SBV x * SBV y = SBV (svTimes x y)
  SBV x - SBV y = SBV (svMinus x y)
  -- Abs is problematic for floating point, due to -0; case, so we carefully shuttle it down
  -- to the solver to avoid the can of worms. (Alternative would be to do an if-then-else here.)
  abs (SBV x) = SBV (svAbs x)
  signum a
    | hasSign a = ite (a .<  z) (-i) (ite (a .== z) z i)
    | True      = ite (a ./= z) i    z
    where z = genLiteral (kindOf a) (0::Integer)
          i = genLiteral (kindOf a) (1::Integer)
  -- negate is tricky because on double/float -0 is different than 0; so we
  -- just cannot rely on its default definition; which would be 0-0, which is not -0!
  negate (SBV x) = SBV (svUNeg x)

-- | Symbolic exponentiation using bit blasting and repeated squaring.
--
-- N.B. The exponent must be unsigned. Signed exponents will be rejected.
(.^) :: (Mergeable b, Num b, SIntegral e) => b -> SBV e -> b
b .^ e | isSigned e = error "(.^): exponentiation only works with unsigned exponents"
       | True       = product $ zipWith (\use n -> ite use n 1)
                                        (blastLE e)
                                        (iterate (\x -> x*x) b)

instance (SymWord a, Fractional a) => Fractional (SBV a) where
  fromRational = literal . fromRational
  SBV x / SBV y = SBV (svDivide x y)

-- | Define Floating instance on SBV's; only for base types that are already floating; i.e., SFloat and SDouble
-- Note that most of the fields are "undefined" for symbolic values, we add methods as they are supported by SMTLib.
-- Currently, the only symbolicly available function in this class is sqrt.
instance (SymWord a, Fractional a, Floating a) => Floating (SBV a) where
    pi      = literal pi
    exp     = lift1FNS "exp"     exp
    log     = lift1FNS "log"     log
    sqrt    = lift1F   sqrt      smtLibSquareRoot
    sin     = lift1FNS "sin"     sin
    cos     = lift1FNS "cos"     cos
    tan     = lift1FNS "tan"     tan
    asin    = lift1FNS "asin"    asin
    acos    = lift1FNS "acos"    acos
    atan    = lift1FNS "atan"    atan
    sinh    = lift1FNS "sinh"    sinh
    cosh    = lift1FNS "cosh"    cosh
    tanh    = lift1FNS "tanh"    tanh
    asinh   = lift1FNS "asinh"   asinh
    acosh   = lift1FNS "acosh"   acosh
    atanh   = lift1FNS "atanh"   atanh
    (**)    = lift2FNS "**"      (**)
    logBase = lift2FNS "logBase" logBase

-- | Lift an FP predicate as defined by SMT-Lib to the world of SFloat and SDoubles.
liftFPPredicate :: (Floating a, SymWord a) => String -> (a -> Bool) -> SBV a -> SBool
liftFPPredicate nm f a
   | Just v <- unliteral a = literal $ f v
   | True                  = SBV $ SVal KBool $ Right $ cache r
   where r st = do swa <- sbvToSW st a
                   newExpr st KBool (SBVApp (Uninterpreted nm) [swa])

-- | Fused-multiply add. @fusedMA a b c = a * b + c@, for double and floating point values.
-- Note that a 'fusedMA' call will *never* be concrete, even if all the arguments are constants; since
-- we cannot guarantee the precision requirements, which is the whole reason why 'fusedMA' exists in the
-- first place. (NB. 'fusedMA' only rounds once, even though it does two operations, and hence the extra
-- precision.)
fusedMA :: (SymWord a, Floating a) => SBV a -> SBV a -> SBV a -> SBV a
fusedMA a b c = SBV $ SVal k $ Right $ cache r
  where k = kindOf a
        r st = do swa <- sbvToSW st a
                  swb <- sbvToSW st b
                  swc <- sbvToSW st c
                  newExpr st k (SBVApp smtLibFusedMA [swa, swb, swc])

-- | Lift a float/double unary function, using a corresponding function in SMT-lib. We piggy-back on the uninterpreted
-- function mechanism here, as it essentially is the same as introducing this as a new function.
lift1F :: (SymWord a, Floating a) => (a -> a) -> Op -> SBV a -> SBV a
lift1F f smtOp sv
  | Just v <- unliteral sv = literal $ f v
  | True                   = SBV $ SVal k $ Right $ cache c
  where k = kindOf sv
        c st = do swa <- sbvToSW st sv
                  newExpr st k (SBVApp smtOp [swa])

-- | Lift a float/double unary function, only over constants
lift1FNS :: (SymWord a, Floating a) => String -> (a -> a) -> SBV a -> SBV a
lift1FNS nm f sv
  | Just v <- unliteral sv = literal $ f v
  | True                   = error $ "SBV." ++ nm ++ ": not supported for symbolic values of type " ++ show (kindOf sv)

-- | Lift a float/double binary function, only over constants
lift2FNS :: (SymWord a, Floating a) => String -> (a -> a -> a) -> SBV a -> SBV a -> SBV a
lift2FNS nm f sv1 sv2
  | Just v1 <- unliteral sv1
  , Just v2 <- unliteral sv2 = literal $ f v1 v2
  | True                     = error $ "SBV." ++ nm ++ ": not supported for symbolic values of type " ++ show (kindOf sv1)

-- NB. In the optimizations below, use of -1 is valid as
-- -1 has all bits set to True for both signed and unsigned values
instance (Num a, Bits a, SymWord a) => Bits (SBV a) where
  SBV x .&. SBV y = SBV (svAnd x y)
  SBV x .|. SBV y = SBV (svOr x y)
  SBV x `xor` SBV y = SBV (svXOr x y)
  complement (SBV x) = SBV (svNot x)
  bitSize  x = intSizeOf x
#if __GLASGOW_HASKELL__ >= 708
  bitSizeMaybe x = Just $ intSizeOf x
#endif
  isSigned x = hasSign x
  bit i      = 1 `shiftL` i
  setBit        x i = x .|. genLiteral (kindOf x) (bit i :: Integer)
  clearBit      x i = x .&. genLiteral (kindOf x) (complement (bit i) :: Integer)
  complementBit x i = x `xor` genLiteral (kindOf x) (bit i :: Integer)
  shiftL  (SBV x) i = SBV (svShl x i)
  shiftR  (SBV x) i = SBV (svShr x i)
  rotateL (SBV x) i = SBV (svRol x i)
  rotateR (SBV x) i = SBV (svRor x i)
  -- NB. testBit is *not* implementable on non-concrete symbolic words
  x `testBit` i
    | SBV (SVal _ (Left (CW _ (CWInteger n)))) <- x = testBit n i
    | True                 = error $ "SBV.testBit: Called on symbolic value: " ++ show x ++ ". Use sbvTestBit instead."
  -- NB. popCount is *not* implementable on non-concrete symbolic words
  popCount x
    | SBV (SVal _ (Left (CW (KBounded _ w) (CWInteger n)))) <- x = popCount (n .&. (bit w - 1))
    | True                                                       = error $ "SBV.popCount: Called on symbolic value: " ++ show x ++ ". Use sbvPopCount instead."

-- | Replacement for 'testBit'. Since 'testBit' requires a 'Bool' to be returned,
-- we cannot implement it for symbolic words. Index 0 is the least-significant bit.
sbvTestBit :: (Num a, Bits a, SymWord a) => SBV a -> Int -> SBool
sbvTestBit (SBV x) i = SBV (svTestBit x i)

-- | Replacement for 'popCount'. Since 'popCount' returns an 'Int', we cannot implement
-- it for symbolic words. Here, we return an 'SWord8', which can overflow when used on
-- quantities that have more than 255 bits. Currently, that's only the 'SInteger' type
-- that SBV supports, all other types are safe. Even with 'SInteger', this will only
-- overflow if there are at least 256-bits set in the number, and the smallest such
-- number is 2^256-1, which is a pretty darn big number to worry about for practical
-- purposes. In any case, we do not support 'sbvPopCount' for unbounded symbolic integers,
-- as the only possible implementation wouldn't symbolically terminate. So the only overflow
-- issue is with really-really large concrete 'SInteger' values.
sbvPopCount :: (Num a, Bits a, SymWord a) => SBV a -> SWord8
sbvPopCount x
  | isReal x          = error "SBV.sbvPopCount: Called on a real value"
  | isConcrete x      = go 0 x
  | not (isBounded x) = error "SBV.sbvPopCount: Called on an infinite precision symbolic value"
  | True              = sum [ite b 1 0 | b <- blastLE x]
  where -- concrete case
        go !c 0 = c
        go !c w = go (c+1) (w .&. (w-1))

-- | Generalization of 'setBit' based on a symbolic boolean. Note that 'setBit' and
-- 'clearBit' are still available on Symbolic words, this operation comes handy when
-- the condition to set/clear happens to be symbolic.
setBitTo :: (Num a, Bits a, SymWord a) => SBV a -> Int -> SBool -> SBV a
setBitTo x i b = ite b (setBit x i) (clearBit x i)

-- | Generalization of 'shiftL', when the shift-amount is symbolic. Since Haskell's
-- 'shiftL' only takes an 'Int' as the shift amount, it cannot be used when we have
-- a symbolic amount to shift with. The shift amount must be an unsigned quantity.
sbvShiftLeft :: (SIntegral a, SIntegral b) => SBV a -> SBV b -> SBV a
sbvShiftLeft x i
  | isSigned i = error "sbvShiftLeft: shift amount should be unsigned"
  | True       = select [x `shiftL` k | k <- [0 .. ghcBitSize x - 1]] z i
  where z = genLiteral (kindOf x) (0::Integer)

-- | Generalization of 'shiftR', when the shift-amount is symbolic. Since Haskell's
-- 'shiftR' only takes an 'Int' as the shift amount, it cannot be used when we have
-- a symbolic amount to shift with. The shift amount must be an unsigned quantity.
--
-- NB. If the shiftee is signed, then this is an arithmetic shift; otherwise it's logical,
-- following the usual Haskell convention. See 'sbvSignedShiftArithRight' for a variant
-- that explicitly uses the msb as the sign bit, even for unsigned underlying types.
sbvShiftRight :: (SIntegral a, SIntegral b) => SBV a -> SBV b -> SBV a
sbvShiftRight x i
  | isSigned i = error "sbvShiftRight: shift amount should be unsigned"
  | True       = select [x `shiftR` k | k <- [0 .. ghcBitSize x - 1]] z i
  where z = genLiteral (kindOf x) (0::Integer)

-- | Arithmetic shift-right with a symbolic unsigned shift amount. This is equivalent
-- to 'sbvShiftRight' when the argument is signed. However, if the argument is unsigned,
-- then it explicitly treats its msb as a sign-bit, and uses it as the bit that
-- gets shifted in. Useful when using the underlying unsigned bit representation to implement
-- custom signed operations. Note that there is no direct Haskell analogue of this function.
sbvSignedShiftArithRight:: (SIntegral a, SIntegral b) => SBV a -> SBV b -> SBV a
sbvSignedShiftArithRight x i
  | isSigned i = error "sbvSignedShiftArithRight: shift amount should be unsigned"
  | isSigned x = sbvShiftRight x i
  | True       = ite (msb x)
                     (complement (sbvShiftRight (complement x) i))
                     (sbvShiftRight x i)

-- | Generalization of 'rotateL', when the shift-amount is symbolic. Since Haskell's
-- 'rotateL' only takes an 'Int' as the shift amount, it cannot be used when we have
-- a symbolic amount to shift with. The shift amount must be an unsigned quantity.
sbvRotateLeft :: (SIntegral a, SIntegral b, SDivisible (SBV b)) => SBV a -> SBV b -> SBV a
sbvRotateLeft x i
  | isSigned i             = error "sbvRotateLeft: rotation amount should be unsigned"
  | bit si <= toInteger sx = select [x `rotateL` k | k <- [0 .. bit si - 1]] z i         -- wrap-around not possible
  | True                   = select [x `rotateL` k | k <- [0 .. sx     - 1]] z (i `sRem` n)
    where sx = ghcBitSize x
          si = ghcBitSize i
          z = genLiteral (kindOf x) (0::Integer)
          n = genLiteral (kindOf i) (toInteger sx)

-- | Generalization of 'rotateR', when the shift-amount is symbolic. Since Haskell's
-- 'rotateR' only takes an 'Int' as the shift amount, it cannot be used when we have
-- a symbolic amount to shift with. The shift amount must be an unsigned quantity.
sbvRotateRight :: (SIntegral a, SIntegral b, SDivisible (SBV b)) => SBV a -> SBV b -> SBV a
sbvRotateRight x i
  | isSigned i             = error "sbvRotateRight: rotation amount should be unsigned"
  | bit si <= toInteger sx = select [x `rotateR` k | k <- [0 .. bit si - 1]] z i         -- wrap-around not possible
  | True                   = select [x `rotateR` k | k <- [0 .. sx     - 1]] z (i `sRem` n)
    where sx = ghcBitSize x
          si = ghcBitSize i
          z = genLiteral (kindOf x) (0::Integer)
          n = genLiteral (kindOf i) (toInteger sx)

-- | Full adder. Returns the carry-out from the addition.
--
-- N.B. Only works for unsigned types. Signed arguments will be rejected.
fullAdder :: SIntegral a => SBV a -> SBV a -> (SBool, SBV a)
fullAdder a b
  | isSigned a = error "fullAdder: only works on unsigned numbers"
  | True       = (a .> s ||| b .> s, s)
  where s = a + b

-- | Full multiplier: Returns both the high-order and the low-order bits in a tuple,
-- thus fully accounting for the overflow.
--
-- N.B. Only works for unsigned types. Signed arguments will be rejected.
--
-- N.B. The higher-order bits are determined using a simple shift-add multiplier,
-- thus involving bit-blasting. It'd be naive to expect SMT solvers to deal efficiently
-- with properties involving this function, at least with the current state of the art.
fullMultiplier :: SIntegral a => SBV a -> SBV a -> (SBV a, SBV a)
fullMultiplier a b
  | isSigned a = error "fullMultiplier: only works on unsigned numbers"
  | True       = (go (ghcBitSize a) 0 a, a*b)
  where go 0 p _ = p
        go n p x = let (c, p')  = ite (lsb x) (fullAdder p b) (false, p)
                       (o, p'') = shiftIn c p'
                       (_, x')  = shiftIn o x
                   in go (n-1) p'' x'
        shiftIn k v = (lsb v, mask .|. (v `shiftR` 1))
           where mask = ite k (bit (ghcBitSize v - 1)) 0

-- | Little-endian blasting of a word into its bits. Also see the 'FromBits' class.
blastLE :: (Num a, Bits a, SymWord a) => SBV a -> [SBool]
blastLE x
 | isReal x          = error "SBV.blastLE: Called on a real value"
 | not (isBounded x) = error "SBV.blastLE: Called on an infinite precision value"
 | True              = map (sbvTestBit x) [0 .. intSizeOf x - 1]

-- | Big-endian blasting of a word into its bits. Also see the 'FromBits' class.
blastBE :: (Num a, Bits a, SymWord a) => SBV a -> [SBool]
blastBE = reverse . blastLE

-- | Least significant bit of a word, always stored at index 0.
lsb :: (Num a, Bits a, SymWord a) => SBV a -> SBool
lsb x = sbvTestBit x 0

-- | Most significant bit of a word, always stored at the last position.
msb :: (Num a, Bits a, SymWord a) => SBV a -> SBool
msb x
 | isReal x          = error "SBV.msb: Called on a real value"
 | not (isBounded x) = error "SBV.msb: Called on an infinite precision value"
 | True              = sbvTestBit x (intSizeOf x - 1)

-- Enum instance. These instances are suitable for use with concrete values,
-- and will be less useful for symbolic values around. Note that `fromEnum` requires
-- a concrete argument for obvious reasons. Other variants (succ, pred, [x..]) etc are similarly
-- limited. While symbolic variants can be defined for many of these, they will just diverge
-- as final sizes cannot be determined statically.
instance (Show a, Bounded a, Integral a, Num a, SymWord a) => Enum (SBV a) where
  succ x
    | v == (maxBound :: a) = error $ "Enum.succ{" ++ showType x ++ "}: tried to take `succ' of maxBound"
    | True                 = fromIntegral $ v + 1
    where v = enumCvt "succ" x
  pred x
    | v == (minBound :: a) = error $ "Enum.pred{" ++ showType x ++ "}: tried to take `pred' of minBound"
    | True                 = fromIntegral $ v - 1
    where v = enumCvt "pred" x
  toEnum x
    | xi < fromIntegral (minBound :: a) || xi > fromIntegral (maxBound :: a)
    = error $ "Enum.toEnum{" ++ showType r ++ "}: " ++ show x ++ " is out-of-bounds " ++ show (minBound :: a, maxBound :: a)
    | True
    = r
    where xi :: Integer
          xi = fromIntegral x
          r  :: SBV a
          r  = fromIntegral x
  fromEnum x
     | r < fromIntegral (minBound :: Int) || r > fromIntegral (maxBound :: Int)
     = error $ "Enum.fromEnum{" ++ showType x ++ "}:  value " ++ show r ++ " is outside of Int's bounds " ++ show (minBound :: Int, maxBound :: Int)
     | True
     = fromIntegral r
    where r :: Integer
          r = enumCvt "fromEnum" x
  enumFrom x = map fromIntegral [xi .. fromIntegral (maxBound :: a)]
     where xi :: Integer
           xi = enumCvt "enumFrom" x
  enumFromThen x y
     | yi >= xi  = map fromIntegral [xi, yi .. fromIntegral (maxBound :: a)]
     | True      = map fromIntegral [xi, yi .. fromIntegral (minBound :: a)]
       where xi, yi :: Integer
             xi = enumCvt "enumFromThen.x" x
             yi = enumCvt "enumFromThen.y" y
  enumFromThenTo x y z = map fromIntegral [xi, yi .. zi]
       where xi, yi, zi :: Integer
             xi = enumCvt "enumFromThenTo.x" x
             yi = enumCvt "enumFromThenTo.y" y
             zi = enumCvt "enumFromThenTo.z" z

-- | Helper function for use in enum operations
enumCvt :: (SymWord a, Integral a, Num b) => String -> SBV a -> b
enumCvt w x = case unliteral x of
                Nothing -> error $ "Enum." ++ w ++ "{" ++ showType x ++ "}: Called on symbolic value " ++ show x
                Just v  -> fromIntegral v

-- | The 'SDivisible' class captures the essence of division.
-- Unfortunately we cannot use Haskell's 'Integral' class since the 'Real'
-- and 'Enum' superclasses are not implementable for symbolic bit-vectors.
-- However, 'quotRem' and 'divMod' makes perfect sense, and the 'SDivisible' class captures
-- this operation. One issue is how division by 0 behaves. The verification
-- technology requires total functions, and there are several design choices
-- here. We follow Isabelle/HOL approach of assigning the value 0 for division
-- by 0. Therefore, we impose the following law:
--
--     @ x `sQuotRem` 0 = (0, x) @
--     @ x `sDivMod`  0 = (0, x) @
--
-- Note that our instances implement this law even when @x@ is @0@ itself.
--
-- NB. 'quot' truncates toward zero, while 'div' truncates toward negative infinity.
--
-- Minimal complete definition: 'sQuotRem', 'sDivMod'
class SDivisible a where
  sQuotRem :: a -> a -> (a, a)
  sDivMod  :: a -> a -> (a, a)
  sQuot    :: a -> a -> a
  sRem     :: a -> a -> a
  sDiv     :: a -> a -> a
  sMod     :: a -> a -> a

  x `sQuot` y = fst $ x `sQuotRem` y
  x `sRem`  y = snd $ x `sQuotRem` y
  x `sDiv`  y = fst $ x `sDivMod`  y
  x `sMod`  y = snd $ x `sDivMod`  y

instance SDivisible Word64 where
  sQuotRem x 0 = (0, x)
  sQuotRem x y = x `quotRem` y
  sDivMod  x 0 = (0, x)
  sDivMod  x y = x `divMod` y

instance SDivisible Int64 where
  sQuotRem x 0 = (0, x)
  sQuotRem x y = x `quotRem` y
  sDivMod  x 0 = (0, x)
  sDivMod  x y = x `divMod` y

instance SDivisible Word32 where
  sQuotRem x 0 = (0, x)
  sQuotRem x y = x `quotRem` y
  sDivMod  x 0 = (0, x)
  sDivMod  x y = x `divMod` y

instance SDivisible Int32 where
  sQuotRem x 0 = (0, x)
  sQuotRem x y = x `quotRem` y
  sDivMod  x 0 = (0, x)
  sDivMod  x y = x `divMod` y

instance SDivisible Word16 where
  sQuotRem x 0 = (0, x)
  sQuotRem x y = x `quotRem` y
  sDivMod  x 0 = (0, x)
  sDivMod  x y = x `divMod` y

instance SDivisible Int16 where
  sQuotRem x 0 = (0, x)
  sQuotRem x y = x `quotRem` y
  sDivMod  x 0 = (0, x)
  sDivMod  x y = x `divMod` y

instance SDivisible Word8 where
  sQuotRem x 0 = (0, x)
  sQuotRem x y = x `quotRem` y
  sDivMod  x 0 = (0, x)
  sDivMod  x y = x `divMod` y

instance SDivisible Int8 where
  sQuotRem x 0 = (0, x)
  sQuotRem x y = x `quotRem` y
  sDivMod  x 0 = (0, x)
  sDivMod  x y = x `divMod` y

instance SDivisible Integer where
  sQuotRem x 0 = (0, x)
  sQuotRem x y = x `quotRem` y
  sDivMod  x 0 = (0, x)
  sDivMod  x y = x `divMod` y

instance SDivisible CW where
  sQuotRem a b
    | CWInteger x <- cwVal a, CWInteger y <- cwVal b
    = let (r1, r2) = sQuotRem x y in (normCW a{ cwVal = CWInteger r1 }, normCW b{ cwVal = CWInteger r2 })
  sQuotRem a b = error $ "SBV.sQuotRem: impossible, unexpected args received: " ++ show (a, b)
  sDivMod a b
    | CWInteger x <- cwVal a, CWInteger y <- cwVal b
    = let (r1, r2) = sDivMod x y in (normCW a { cwVal = CWInteger r1 }, normCW b { cwVal = CWInteger r2 })
  sDivMod a b = error $ "SBV.sDivMod: impossible, unexpected args received: " ++ show (a, b)

instance SDivisible SWord64 where
  sQuotRem = liftQRem
  sDivMod  = liftDMod

instance SDivisible SInt64 where
  sQuotRem = liftQRem
  sDivMod  = liftDMod

instance SDivisible SWord32 where
  sQuotRem = liftQRem
  sDivMod  = liftDMod

instance SDivisible SInt32 where
  sQuotRem = liftQRem
  sDivMod  = liftDMod

instance SDivisible SWord16 where
  sQuotRem = liftQRem
  sDivMod  = liftDMod

instance SDivisible SInt16 where
  sQuotRem = liftQRem
  sDivMod  = liftDMod

instance SDivisible SWord8 where
  sQuotRem = liftQRem
  sDivMod  = liftDMod

instance SDivisible SInt8 where
  sQuotRem = liftQRem
  sDivMod  = liftDMod

-- | Lift 'QRem' to symbolic words. Division by 0 is defined s.t. @x/0 = 0@; which
-- holds even when @x@ is @0@ itself.
liftQRem :: (SymWord a, Num a, SDivisible a) => SBV a -> SBV a -> (SBV a, SBV a)
liftQRem x y
  | isConcreteZero x
  = (x, x)
  | isConcreteOne y
  = (x, z)
{-------------------------------
 - N.B. The seemingly innocuous variant when y == -1 only holds if the type is signed;
 - and also is problematic around the minBound.. So, we refrain from that optimization
  | isConcreteOnes y
  = (-x, z)
--------------------------------}
  | True
  = ite (y .== z) (z, x) (qr x y)
  where qr (SBV (SVal sgnsz (Left a))) (SBV (SVal _ (Left b))) = let (q, r) = sQuotRem a b in (SBV (SVal sgnsz (Left q)), SBV (SVal sgnsz (Left r)))
        qr a@(SBV (SVal sgnsz _))      b                       = (SBV (SVal sgnsz (Right (cache (mk Quot)))), SBV (SVal sgnsz (Right (cache (mk Rem)))))
                where mk o st = do sw1 <- sbvToSW st a
                                   sw2 <- sbvToSW st b
                                   mkSymOp o st sgnsz sw1 sw2
        z = genLiteral (kindOf x) (0::Integer)

-- | Lift 'QMod' to symbolic words. Division by 0 is defined s.t. @x/0 = 0@; which
-- holds even when @x@ is @0@ itself. Essentially, this is conversion from quotRem
-- (truncate to 0) to divMod (truncate towards negative infinity)
liftDMod :: (SymWord a, Num a, SDivisible a, SDivisible (SBV a)) => SBV a -> SBV a -> (SBV a, SBV a)
liftDMod x y
  | isConcreteZero x
  = (x, x)
  | isConcreteOne y
  = (x, z)
{-------------------------------
 - N.B. The seemingly innocuous variant when y == -1 only holds if the type is signed;
 - and also is problematic around the minBound.. So, we refrain from that optimization
  | isConcreteOnes y
  = (-x, z)
--------------------------------}
  | True
  = ite (y .== z) (z, x) $ ite (signum r .== negate (signum y)) (q-i, r+y) qr
 where qr@(q, r) = x `sQuotRem` y
       z = genLiteral (kindOf x) (0::Integer)
       i = genLiteral (kindOf x) (1::Integer)

-- SInteger instance for quotRem/divMod are tricky!
-- SMT-Lib only has Euclidean operations, but Haskell
-- uses "truncate to 0" for quotRem, and "truncate to negative infinity" for divMod.
-- So, we cannot just use the above liftings directly.
instance SDivisible SInteger where
  sDivMod = liftDMod
  sQuotRem x y
    | not (isSymbolic x || isSymbolic y)
    = liftQRem x y
    | True
    = ite (y .== 0) (0, x) (qE+i, rE-i*y)
    where (qE, rE) = liftQRem x y   -- for integers, this is euclidean due to SMTLib semantics
          i = ite (x .>= 0 ||| rE .== 0) 0
            $ ite (y .>  0)              1 (-1)

-- Quickcheck interface

-- The Arbitrary instance for SFunArray returns an array initialized
-- to an arbitrary element
instance (SymWord b, Arbitrary b) => Arbitrary (SFunArray a b) where
  arbitrary = arbitrary >>= \r -> return $ SFunArray (const r)

instance (SymWord a, Arbitrary a) => Arbitrary (SBV a) where
  arbitrary = liftM literal arbitrary

-- |  Symbolic conditionals are modeled by the 'Mergeable' class, describing
-- how to merge the results of an if-then-else call with a symbolic test. SBV
-- provides all basic types as instances of this class, so users only need
-- to declare instances for custom data-types of their programs as needed.
--
-- The function 'select' is a total-indexing function out of a list of choices
-- with a default value, simulating array/list indexing. It's an n-way generalization
-- of the 'ite' function.
--
-- Minimal complete definition: 'symbolicMerge'
class Mergeable a where
   -- | Merge two values based on the condition. The first argument states
   -- whether we force the then-and-else branches before the merging, at the
   -- word level. This is an efficiency concern; one that we'd rather not
   -- make but unfortunately necessary for getting symbolic simulation
   -- working efficiently.
   symbolicMerge :: Bool -> SBool -> a -> a -> a
   -- | Total indexing operation. @select xs default index@ is intuitively
   -- the same as @xs !! index@, except it evaluates to @default@ if @index@
   -- overflows
   select :: (SymWord b, Num b) => [a] -> a -> SBV b -> a
   -- NB. Earlier implementation of select used the binary-search trick
   -- on the index to chop down the search space. While that is a good trick
   -- in general, it doesn't work for SBV since we do not have any notion of
   -- "concrete" subwords: If an index is symbolic, then all its bits are
   -- symbolic as well. So, the binary search only pays off only if the indexed
   -- list is really humongous, which is not very common in general. (Also,
   -- for the case when the list is bit-vectors, we use SMT tables anyhow.)
   select xs err ind
    | isReal   ind = error "SBV.select: unsupported real valued select/index expression"
    | isFloat  ind = error "SBV.select: unsupported float valued select/index expression"
    | isDouble ind = error "SBV.select: unsupported double valued select/index expression"
    | hasSign  ind = ite (ind .< 0) err (walk xs ind err)
    | True         =                     walk xs ind err
    where walk []     _ acc = acc
          walk (e:es) i acc = walk es (i-1) (ite (i .== 0) e acc)


-- | If-then-else. This is by definition 'symbolicMerge' with both
-- branches forced. This is typically the desired behavior, but also
-- see 'iteLazy' should you need more laziness.
ite :: Mergeable a => SBool -> a -> a -> a
ite t a b
  | Just r <- unliteral t = if r then a else b
  | True                  = symbolicMerge True t a b

-- | A Lazy version of ite, which does not force its arguments. This might
-- cause issues for symbolic simulation with large thunks around, so use with
-- care.
iteLazy :: Mergeable a => SBool -> a -> a -> a
iteLazy t a b
  | Just r <- unliteral t = if r then a else b
  | True                  = symbolicMerge False t a b

-- | Branch on a condition, much like 'ite'. The exception is that SBV will
-- check to make sure if the test condition is feasible by making an external
-- call to the SMT solver. Note that this can be expensive, thus we shall use
-- a time-out value ('sBranchTimeOut'). There might be zero, one, or two such
-- external calls per 'sBranch' call:
--
--    - If condition is statically known to be True/False: 0 calls
--           - In this case, we simply constant fold..
--
--    - If condition is determined to be unsatisfiable   : 1 call
--           - In this case, we know then-branch is infeasible, so just take the else-branch
--
--    - If condition is determined to be satisfable      : 2 calls
--           - In this case, we know then-branch is feasible, but we still have to check if the else-branch is
--
-- In summary, 'sBranch' calls can be expensive, but they can help with the so-called symbolic-termination
-- problem. See "Data.SBV.Examples.Misc.SBranch" for an example.
sBranch :: Mergeable a => SBool -> a -> a -> a
sBranch t a b
  | Just r <- unliteral c = if r then a else b
  | True                  = symbolicMerge False c a b
  where c = reduceInPathCondition t

-- | Symbolic assert. Check that the given boolean condition is always true in the given path.
-- Otherwise symbolic simulation will stop with a run-time error.
sAssert :: Mergeable a => String -> SBool -> a -> a
sAssert msg = sAssertCont msg defCont
  where defCont _   Nothing   = C.throw (SafeAlwaysFails  msg)
        defCont cfg (Just md) = C.throw (SafeFailsInModel msg cfg (SMTModel (M.toList md) [] []))

-- | Symbolic assert with a programmable continuation. Check that the given boolean condition is always true in the given path.
-- Otherwise symbolic simulation will transfer the failing model to the given continuation. The
-- continuation takes the @SMTConfig@, and a possible model: If it receives @Nothing@, then it means that the condition
-- fails for all assignments to inputs. Otherwise, it'll receive @Just@ a dictionary that maps the
-- input variables to the appropriate @CW@ values that exhibit the failure. Note that the continuation
-- has no option but to display the result in some fashion and call error, due to its restricted type.
sAssertCont :: Mergeable a => String -> (forall b. SMTConfig -> Maybe (M.Map String CW) -> b) -> SBool -> a -> a
sAssertCont msg cont t a
  | Just r <- unliteral t = if r then a else cont defaultSMTCfg Nothing
  | True                  = symbolicMerge False cond a (die ["SBV.error: Internal-error, cannot happen: Reached false branch in checked s-Assert."])
  where k     = kindOf t
        cond  = SBV $ SVal k $ Right $ cache c
        die m = error $ intercalate "\n" $ ("Assertion failure: " ++ show msg) : m
        c st  = do let pc  = getPathCondition st
                       chk = pc &&& bnot t
                   mbModel <- isConditionSatisfiable st chk
                   case mbModel of
                     Just (r@(SatResult (Satisfiable cfg _))) -> cont cfg $ Just $ getModelDictionary r
                     _                                        -> return trueSW

-- | Merge two symbolic values, at kind @k@, possibly @force@'ing the branches to make
-- sure they do not evaluate to the same result. This should only be used for internal purposes;
-- as default definitions provided should suffice in many cases. (i.e., End users should
-- only need to define 'symbolicMerge' when needed; which should be rare to start with.)
symbolicMergeWithKind :: Kind -> Bool -> SBool -> SBV a -> SBV a -> SBV a
symbolicMergeWithKind k force (SBV t) (SBV a) (SBV b) = SBV (svSymbolicMerge k force t a b)

instance SymWord a => Mergeable (SBV a) where
    symbolicMerge force t x y
    -- Carefully use the kindOf instance to avoid strictness issues.
       | force = symbolicMergeWithKind (kindOf x)                True  t x y
       | True  = symbolicMergeWithKind (kindOf (undefined :: a)) False t x y
    -- Custom version of select that translates to SMT-Lib tables at the base type of words
    select xs err ind
      | SBV (SVal _ (Left c)) <- ind = case cwVal c of
                                         CWInteger i -> if i < 0 || i >= genericLength xs
                                                        then err
                                                        else xs `genericIndex` i
                                         _           -> error $ "SBV.select: unsupported " ++ show (kindOf ind) ++ " valued select/index expression"
    select xsOrig err ind = xs `seq` SBV (SVal kElt (Right (cache r)))
      where kInd = kindOf ind
            kElt = kindOf err
            -- Based on the index size, we need to limit the elements. For instance if the index is 8 bits, but there
            -- are 257 elements, that last element will never be used and we can chop it of..
            xs   = case kindOf ind of
                     KBounded False i -> genericTake ((2::Integer) ^ (fromIntegral i     :: Integer)) xsOrig
                     KBounded True  i -> genericTake ((2::Integer) ^ (fromIntegral (i-1) :: Integer)) xsOrig
                     KUnbounded       -> xsOrig
                     _                -> error $ "SBV.select: unsupported " ++ show (kindOf ind) ++ " valued select/index expression"
            r st  = do sws <- mapM (sbvToSW st) xs
                       swe <- sbvToSW st err
                       if all (== swe) sws  -- off-chance that all elts are the same
                          then return swe
                          else do idx <- getTableIndex st kInd kElt sws
                                  swi <- sbvToSW st ind
                                  let len = length xs
                                  -- NB. No need to worry here that the index might be < 0; as the SMTLib translation takes care of that automatically
                                  newExpr st kElt (SBVApp (LkUp (idx, kInd, kElt, len) swi swe) [])

-- Unit
instance Mergeable () where
   symbolicMerge _ _ _ _ = ()
   select _ _ _ = ()

-- Mergeable instances for List/Maybe/Either/Array are useful, but can
-- throw exceptions if there is no structural matching of the results
-- It's a question whether we should really keep them..

-- Lists
instance Mergeable a => Mergeable [a] where
  symbolicMerge f t xs ys
    | lxs == lys = zipWith (symbolicMerge f t) xs ys
    | True       = error $ "SBV.Mergeable.List: No least-upper-bound for lists of differing size " ++ show (lxs, lys)
    where (lxs, lys) = (length xs, length ys)

-- Maybe
instance Mergeable a => Mergeable (Maybe a) where
  symbolicMerge _ _ Nothing  Nothing  = Nothing
  symbolicMerge f t (Just a) (Just b) = Just $ symbolicMerge f t a b
  symbolicMerge _ _ a b = error $ "SBV.Mergeable.Maybe: No least-upper-bound for " ++ show (k a, k b)
      where k Nothing = "Nothing"
            k _       = "Just"

-- Either
instance (Mergeable a, Mergeable b) => Mergeable (Either a b) where
  symbolicMerge f t (Left a)  (Left b)  = Left  $ symbolicMerge f t a b
  symbolicMerge f t (Right a) (Right b) = Right $ symbolicMerge f t a b
  symbolicMerge _ _ a b = error $ "SBV.Mergeable.Either: No least-upper-bound for " ++ show (k a, k b)
     where k (Left _)  = "Left"
           k (Right _) = "Right"

-- Arrays
instance (Ix a, Mergeable b) => Mergeable (Array a b) where
  symbolicMerge f t a b
    | ba == bb = listArray ba (zipWith (symbolicMerge f t) (elems a) (elems b))
    | True     = error $ "SBV.Mergeable.Array: No least-upper-bound for rangeSizes" ++ show (k ba, k bb)
    where [ba, bb] = map bounds [a, b]
          k = rangeSize

-- Functions
instance Mergeable b => Mergeable (a -> b) where
  symbolicMerge f t g h x = symbolicMerge f t (g x) (h x)
  {- Following definition, while correct, is utterly inefficient. Since the
     application is delayed, this hangs on to the inner list and all the
     impending merges, even when ind is concrete. Thus, it's much better to
     simply use the default definition for the function case.
  -}
  -- select xs err ind = \x -> select (map ($ x) xs) (err x) ind

-- 2-Tuple
instance (Mergeable a, Mergeable b) => Mergeable (a, b) where
  symbolicMerge f t (i0, i1) (j0, j1) = (i i0 j0, i i1 j1)
    where i a b = symbolicMerge f t a b
  select xs (err1, err2) ind = (select as err1 ind, select bs err2 ind)
    where (as, bs) = unzip xs

-- 3-Tuple
instance (Mergeable a, Mergeable b, Mergeable c) => Mergeable (a, b, c) where
  symbolicMerge f t (i0, i1, i2) (j0, j1, j2) = (i i0 j0, i i1 j1, i i2 j2)
    where i a b = symbolicMerge f t a b
  select xs (err1, err2, err3) ind = (select as err1 ind, select bs err2 ind, select cs err3 ind)
    where (as, bs, cs) = unzip3 xs

-- 4-Tuple
instance (Mergeable a, Mergeable b, Mergeable c, Mergeable d) => Mergeable (a, b, c, d) where
  symbolicMerge f t (i0, i1, i2, i3) (j0, j1, j2, j3) = (i i0 j0, i i1 j1, i i2 j2, i i3 j3)
    where i a b = symbolicMerge f t a b
  select xs (err1, err2, err3, err4) ind = (select as err1 ind, select bs err2 ind, select cs err3 ind, select ds err4 ind)
    where (as, bs, cs, ds) = unzip4 xs

-- 5-Tuple
instance (Mergeable a, Mergeable b, Mergeable c, Mergeable d, Mergeable e) => Mergeable (a, b, c, d, e) where
  symbolicMerge f t (i0, i1, i2, i3, i4) (j0, j1, j2, j3, j4) = (i i0 j0, i i1 j1, i i2 j2, i i3 j3, i i4 j4)
    where i a b = symbolicMerge f t a b
  select xs (err1, err2, err3, err4, err5) ind = (select as err1 ind, select bs err2 ind, select cs err3 ind, select ds err4 ind, select es err5 ind)
    where (as, bs, cs, ds, es) = unzip5 xs

-- 6-Tuple
instance (Mergeable a, Mergeable b, Mergeable c, Mergeable d, Mergeable e, Mergeable f) => Mergeable (a, b, c, d, e, f) where
  symbolicMerge f t (i0, i1, i2, i3, i4, i5) (j0, j1, j2, j3, j4, j5) = (i i0 j0, i i1 j1, i i2 j2, i i3 j3, i i4 j4, i i5 j5)
    where i a b = symbolicMerge f t a b
  select xs (err1, err2, err3, err4, err5, err6) ind = (select as err1 ind, select bs err2 ind, select cs err3 ind, select ds err4 ind, select es err5 ind, select fs err6 ind)
    where (as, bs, cs, ds, es, fs) = unzip6 xs

-- 7-Tuple
instance (Mergeable a, Mergeable b, Mergeable c, Mergeable d, Mergeable e, Mergeable f, Mergeable g) => Mergeable (a, b, c, d, e, f, g) where
  symbolicMerge f t (i0, i1, i2, i3, i4, i5, i6) (j0, j1, j2, j3, j4, j5, j6) = (i i0 j0, i i1 j1, i i2 j2, i i3 j3, i i4 j4, i i5 j5, i i6 j6)
    where i a b = symbolicMerge f t a b
  select xs (err1, err2, err3, err4, err5, err6, err7) ind = (select as err1 ind, select bs err2 ind, select cs err3 ind, select ds err4 ind, select es err5 ind, select fs err6 ind, select gs err7 ind)
    where (as, bs, cs, ds, es, fs, gs) = unzip7 xs

-- Bounded instances
instance (SymWord a, Bounded a) => Bounded (SBV a) where
  minBound = literal minBound
  maxBound = literal maxBound

-- Arrays

-- SArrays are both "EqSymbolic" and "Mergeable"
instance EqSymbolic (SArray a b) where
  (SArray a) .== (SArray b) = SBV (eqSArr a b)

-- When merging arrays; we'll ignore the force argument. This is arguably
-- the right thing to do as we've too many things and likely we want to keep it efficient.
instance SymWord b => Mergeable (SArray a b) where
  symbolicMerge _ = mergeArrays

-- SFunArrays are only "Mergeable". Although a brute
-- force equality can be defined, any non-toy instance
-- will suffer from efficiency issues; so we don't define it
instance SymArray SFunArray where
  newArray _                                  = newArray_ -- the name is irrelevant in this case
  newArray_     mbiVal                        = declNewSFunArray mbiVal
  readArray     (SFunArray f)                 = f
  resetArray    (SFunArray _) a               = SFunArray $ const a
  writeArray    (SFunArray f) a b             = SFunArray (\a' -> ite (a .== a') b (f a'))
  mergeArrays t (SFunArray g)   (SFunArray h) = SFunArray (\x -> ite t (g x) (h x))

-- When merging arrays; we'll ignore the force argument. This is arguably
-- the right thing to do as we've too many things and likely we want to keep it efficient.
instance SymWord b => Mergeable (SFunArray a b) where
  symbolicMerge _ = mergeArrays

-- | Uninterpreted constants and functions. An uninterpreted constant is
-- a value that is indexed by its name. The only property the prover assumes
-- about these values are that they are equivalent to themselves; i.e., (for
-- functions) they return the same results when applied to same arguments.
-- We support uninterpreted-functions as a general means of black-box'ing
-- operations that are /irrelevant/ for the purposes of the proof; i.e., when
-- the proofs can be performed without any knowledge about the function itself.
--
-- Minimal complete definition: 'sbvUninterpret'. However, most instances in
-- practice are already provided by SBV, so end-users should not need to define their
-- own instances.
class Uninterpreted a where
  -- | Uninterpret a value, receiving an object that can be used instead. Use this version
  -- when you do not need to add an axiom about this value.
  uninterpret :: String -> a
  -- | Uninterpret a value, only for the purposes of code-generation. For execution
  -- and verification the value is used as is. For code-generation, the alternate
  -- definition is used. This is useful when we want to take advantage of native
  -- libraries on the target languages.
  cgUninterpret :: String -> [String] -> a -> a
  -- | Most generalized form of uninterpretation, this function should not be needed
  -- by end-user-code, but is rather useful for the library development.
  sbvUninterpret :: Maybe ([String], a) -> String -> a

  -- minimal complete definition: 'sbvUninterpret'
  uninterpret             = sbvUninterpret Nothing
  cgUninterpret nm code v = sbvUninterpret (Just (code, v)) nm

-- Plain constants
instance HasKind a => Uninterpreted (SBV a) where
  sbvUninterpret mbCgData nm
     | Just (_, v) <- mbCgData = v
     | True                    = SBV $ SVal ka $ Right $ cache result
    where ka = kindOf (undefined :: a)
          result st | Just (_, v) <- mbCgData, inProofMode st = sbvToSW st v
                    | True = do newUninterpreted st nm (SBVType [ka]) (fst `fmap` mbCgData)
                                newExpr st ka $ SBVApp (Uninterpreted nm) []

-- Functions of one argument
instance (SymWord b, HasKind a) => Uninterpreted (SBV b -> SBV a) where
  sbvUninterpret mbCgData nm = f
    where f arg0
           | Just (_, v) <- mbCgData, isConcrete arg0
           = v arg0
           | True
           = SBV $ SVal ka $ Right $ cache result
           where ka = kindOf (undefined :: a)
                 kb = kindOf (undefined :: b)
                 result st | Just (_, v) <- mbCgData, inProofMode st = sbvToSW st (v arg0)
                           | True = do newUninterpreted st nm (SBVType [kb, ka]) (fst `fmap` mbCgData)
                                       sw0 <- sbvToSW st arg0
                                       mapM_ forceSWArg [sw0]
                                       newExpr st ka $ SBVApp (Uninterpreted nm) [sw0]

-- Functions of two arguments
instance (SymWord c, SymWord b, HasKind a) => Uninterpreted (SBV c -> SBV b -> SBV a) where
  sbvUninterpret mbCgData nm = f
    where f arg0 arg1
           | Just (_, v) <- mbCgData, isConcrete arg0, isConcrete arg1
           = v arg0 arg1
           | True
           = SBV $ SVal ka $ Right $ cache result
           where ka = kindOf (undefined :: a)
                 kb = kindOf (undefined :: b)
                 kc = kindOf (undefined :: c)
                 result st | Just (_, v) <- mbCgData, inProofMode st = sbvToSW st (v arg0 arg1)
                           | True = do newUninterpreted st nm (SBVType [kc, kb, ka]) (fst `fmap` mbCgData)
                                       sw0 <- sbvToSW st arg0
                                       sw1 <- sbvToSW st arg1
                                       mapM_ forceSWArg [sw0, sw1]
                                       newExpr st ka $ SBVApp (Uninterpreted nm) [sw0, sw1]

-- Functions of three arguments
instance (SymWord d, SymWord c, SymWord b, HasKind a) => Uninterpreted (SBV d -> SBV c -> SBV b -> SBV a) where
  sbvUninterpret mbCgData nm = f
    where f arg0 arg1 arg2
           | Just (_, v) <- mbCgData, isConcrete arg0, isConcrete arg1, isConcrete arg2
           = v arg0 arg1 arg2
           | True
           = SBV $ SVal ka $ Right $ cache result
           where ka = kindOf (undefined :: a)
                 kb = kindOf (undefined :: b)
                 kc = kindOf (undefined :: c)
                 kd = kindOf (undefined :: d)
                 result st | Just (_, v) <- mbCgData, inProofMode st = sbvToSW st (v arg0 arg1 arg2)
                           | True = do newUninterpreted st nm (SBVType [kd, kc, kb, ka]) (fst `fmap` mbCgData)
                                       sw0 <- sbvToSW st arg0
                                       sw1 <- sbvToSW st arg1
                                       sw2 <- sbvToSW st arg2
                                       mapM_ forceSWArg [sw0, sw1, sw2]
                                       newExpr st ka $ SBVApp (Uninterpreted nm) [sw0, sw1, sw2]

-- Functions of four arguments
instance (SymWord e, SymWord d, SymWord c, SymWord b, HasKind a) => Uninterpreted (SBV e -> SBV d -> SBV c -> SBV b -> SBV a) where
  sbvUninterpret mbCgData nm = f
    where f arg0 arg1 arg2 arg3
           | Just (_, v) <- mbCgData, isConcrete arg0, isConcrete arg1, isConcrete arg2, isConcrete arg3
           = v arg0 arg1 arg2 arg3
           | True
           = SBV $ SVal ka $ Right $ cache result
           where ka = kindOf (undefined :: a)
                 kb = kindOf (undefined :: b)
                 kc = kindOf (undefined :: c)
                 kd = kindOf (undefined :: d)
                 ke = kindOf (undefined :: e)
                 result st | Just (_, v) <- mbCgData, inProofMode st = sbvToSW st (v arg0 arg1 arg2 arg3)
                           | True = do newUninterpreted st nm (SBVType [ke, kd, kc, kb, ka]) (fst `fmap` mbCgData)
                                       sw0 <- sbvToSW st arg0
                                       sw1 <- sbvToSW st arg1
                                       sw2 <- sbvToSW st arg2
                                       sw3 <- sbvToSW st arg3
                                       mapM_ forceSWArg [sw0, sw1, sw2, sw3]
                                       newExpr st ka $ SBVApp (Uninterpreted nm) [sw0, sw1, sw2, sw3]

-- Functions of five arguments
instance (SymWord f, SymWord e, SymWord d, SymWord c, SymWord b, HasKind a) => Uninterpreted (SBV f -> SBV e -> SBV d -> SBV c -> SBV b -> SBV a) where
  sbvUninterpret mbCgData nm = f
    where f arg0 arg1 arg2 arg3 arg4
           | Just (_, v) <- mbCgData, isConcrete arg0, isConcrete arg1, isConcrete arg2, isConcrete arg3, isConcrete arg4
           = v arg0 arg1 arg2 arg3 arg4
           | True
           = SBV $ SVal ka $ Right $ cache result
           where ka = kindOf (undefined :: a)
                 kb = kindOf (undefined :: b)
                 kc = kindOf (undefined :: c)
                 kd = kindOf (undefined :: d)
                 ke = kindOf (undefined :: e)
                 kf = kindOf (undefined :: f)
                 result st | Just (_, v) <- mbCgData, inProofMode st = sbvToSW st (v arg0 arg1 arg2 arg3 arg4)
                           | True = do newUninterpreted st nm (SBVType [kf, ke, kd, kc, kb, ka]) (fst `fmap` mbCgData)
                                       sw0 <- sbvToSW st arg0
                                       sw1 <- sbvToSW st arg1
                                       sw2 <- sbvToSW st arg2
                                       sw3 <- sbvToSW st arg3
                                       sw4 <- sbvToSW st arg4
                                       mapM_ forceSWArg [sw0, sw1, sw2, sw3, sw4]
                                       newExpr st ka $ SBVApp (Uninterpreted nm) [sw0, sw1, sw2, sw3, sw4]

-- Functions of six arguments
instance (SymWord g, SymWord f, SymWord e, SymWord d, SymWord c, SymWord b, HasKind a) => Uninterpreted (SBV g -> SBV f -> SBV e -> SBV d -> SBV c -> SBV b -> SBV a) where
  sbvUninterpret mbCgData nm = f
    where f arg0 arg1 arg2 arg3 arg4 arg5
           | Just (_, v) <- mbCgData, isConcrete arg0, isConcrete arg1, isConcrete arg2, isConcrete arg3, isConcrete arg4, isConcrete arg5
           = v arg0 arg1 arg2 arg3 arg4 arg5
           | True
           = SBV $ SVal ka $ Right $ cache result
           where ka = kindOf (undefined :: a)
                 kb = kindOf (undefined :: b)
                 kc = kindOf (undefined :: c)
                 kd = kindOf (undefined :: d)
                 ke = kindOf (undefined :: e)
                 kf = kindOf (undefined :: f)
                 kg = kindOf (undefined :: g)
                 result st | Just (_, v) <- mbCgData, inProofMode st = sbvToSW st (v arg0 arg1 arg2 arg3 arg4 arg5)
                           | True = do newUninterpreted st nm (SBVType [kg, kf, ke, kd, kc, kb, ka]) (fst `fmap` mbCgData)
                                       sw0 <- sbvToSW st arg0
                                       sw1 <- sbvToSW st arg1
                                       sw2 <- sbvToSW st arg2
                                       sw3 <- sbvToSW st arg3
                                       sw4 <- sbvToSW st arg4
                                       sw5 <- sbvToSW st arg5
                                       mapM_ forceSWArg [sw0, sw1, sw2, sw3, sw4, sw5]
                                       newExpr st ka $ SBVApp (Uninterpreted nm) [sw0, sw1, sw2, sw3, sw4, sw5]

-- Functions of seven arguments
instance (SymWord h, SymWord g, SymWord f, SymWord e, SymWord d, SymWord c, SymWord b, HasKind a)
            => Uninterpreted (SBV h -> SBV g -> SBV f -> SBV e -> SBV d -> SBV c -> SBV b -> SBV a) where
  sbvUninterpret mbCgData nm = f
    where f arg0 arg1 arg2 arg3 arg4 arg5 arg6
           | Just (_, v) <- mbCgData, isConcrete arg0, isConcrete arg1, isConcrete arg2, isConcrete arg3, isConcrete arg4, isConcrete arg5, isConcrete arg6
           = v arg0 arg1 arg2 arg3 arg4 arg5 arg6
           | True
           = SBV $ SVal ka $ Right $ cache result
           where ka = kindOf (undefined :: a)
                 kb = kindOf (undefined :: b)
                 kc = kindOf (undefined :: c)
                 kd = kindOf (undefined :: d)
                 ke = kindOf (undefined :: e)
                 kf = kindOf (undefined :: f)
                 kg = kindOf (undefined :: g)
                 kh = kindOf (undefined :: h)
                 result st | Just (_, v) <- mbCgData, inProofMode st = sbvToSW st (v arg0 arg1 arg2 arg3 arg4 arg5 arg6)
                           | True = do newUninterpreted st nm (SBVType [kh, kg, kf, ke, kd, kc, kb, ka]) (fst `fmap` mbCgData)
                                       sw0 <- sbvToSW st arg0
                                       sw1 <- sbvToSW st arg1
                                       sw2 <- sbvToSW st arg2
                                       sw3 <- sbvToSW st arg3
                                       sw4 <- sbvToSW st arg4
                                       sw5 <- sbvToSW st arg5
                                       sw6 <- sbvToSW st arg6
                                       mapM_ forceSWArg [sw0, sw1, sw2, sw3, sw4, sw5, sw6]
                                       newExpr st ka $ SBVApp (Uninterpreted nm) [sw0, sw1, sw2, sw3, sw4, sw5, sw6]

-- Uncurried functions of two arguments
instance (SymWord c, SymWord b, HasKind a) => Uninterpreted ((SBV c, SBV b) -> SBV a) where
  sbvUninterpret mbCgData nm = let f = sbvUninterpret (uc2 `fmap` mbCgData) nm in uncurry f
    where uc2 (cs, fn) = (cs, curry fn)

-- Uncurried functions of three arguments
instance (SymWord d, SymWord c, SymWord b, HasKind a) => Uninterpreted ((SBV d, SBV c, SBV b) -> SBV a) where
  sbvUninterpret mbCgData nm = let f = sbvUninterpret (uc3 `fmap` mbCgData) nm in \(arg0, arg1, arg2) -> f arg0 arg1 arg2
    where uc3 (cs, fn) = (cs, \a b c -> fn (a, b, c))

-- Uncurried functions of four arguments
instance (SymWord e, SymWord d, SymWord c, SymWord b, HasKind a)
            => Uninterpreted ((SBV e, SBV d, SBV c, SBV b) -> SBV a) where
  sbvUninterpret mbCgData nm = let f = sbvUninterpret (uc4 `fmap` mbCgData) nm in \(arg0, arg1, arg2, arg3) -> f arg0 arg1 arg2 arg3
    where uc4 (cs, fn) = (cs, \a b c d -> fn (a, b, c, d))

-- Uncurried functions of five arguments
instance (SymWord f, SymWord e, SymWord d, SymWord c, SymWord b, HasKind a)
            => Uninterpreted ((SBV f, SBV e, SBV d, SBV c, SBV b) -> SBV a) where
  sbvUninterpret mbCgData nm = let f = sbvUninterpret (uc5 `fmap` mbCgData) nm in \(arg0, arg1, arg2, arg3, arg4) -> f arg0 arg1 arg2 arg3 arg4
    where uc5 (cs, fn) = (cs, \a b c d e -> fn (a, b, c, d, e))

-- Uncurried functions of six arguments
instance (SymWord g, SymWord f, SymWord e, SymWord d, SymWord c, SymWord b, HasKind a)
            => Uninterpreted ((SBV g, SBV f, SBV e, SBV d, SBV c, SBV b) -> SBV a) where
  sbvUninterpret mbCgData nm = let f = sbvUninterpret (uc6 `fmap` mbCgData) nm in \(arg0, arg1, arg2, arg3, arg4, arg5) -> f arg0 arg1 arg2 arg3 arg4 arg5
    where uc6 (cs, fn) = (cs, \a b c d e f -> fn (a, b, c, d, e, f))

-- Uncurried functions of seven arguments
instance (SymWord h, SymWord g, SymWord f, SymWord e, SymWord d, SymWord c, SymWord b, HasKind a)
            => Uninterpreted ((SBV h, SBV g, SBV f, SBV e, SBV d, SBV c, SBV b) -> SBV a) where
  sbvUninterpret mbCgData nm = let f = sbvUninterpret (uc7 `fmap` mbCgData) nm in \(arg0, arg1, arg2, arg3, arg4, arg5, arg6) -> f arg0 arg1 arg2 arg3 arg4 arg5 arg6
    where uc7 (cs, fn) = (cs, \a b c d e f g -> fn (a, b, c, d, e, f, g))

-- | Adding arbitrary constraints. When adding constraints, one has to be careful about
-- making sure they are not inconsistent. The function 'isVacuous' can be use for this purpose.
-- Here is an example. Consider the following predicate:
--
-- >>> let pred = do { x <- forall "x"; constrain $ x .< x; return $ x .>= (5 :: SWord8) }
--
-- This predicate asserts that all 8-bit values are larger than 5, subject to the constraint that the
-- values considered satisfy @x .< x@, i.e., they are less than themselves. Since there are no values that
-- satisfy this constraint, the proof will pass vacuously:
--
-- >>> prove pred
-- Q.E.D.
--
-- We can use 'isVacuous' to make sure to see that the pass was vacuous:
--
-- >>> isVacuous pred
-- True
--
-- While the above example is trivial, things can get complicated if there are multiple constraints with
-- non-straightforward relations; so if constraints are used one should make sure to check the predicate
-- is not vacuously true. Here's an example that is not vacuous:
--
--  >>> let pred' = do { x <- forall "x"; constrain $ x .> 6; return $ x .>= (5 :: SWord8) }
--
-- This time the proof passes as expected:
--
--  >>> prove pred'
--  Q.E.D.
--
-- And the proof is not vacuous:
--
--  >>> isVacuous pred'
--  False
constrain :: SBool -> Symbolic ()
constrain c = addConstraint Nothing c (bnot c)

-- | Adding a probabilistic constraint. The 'Double' argument is the probability
-- threshold. Probabilistic constraints are useful for 'genTest' and 'quickCheck'
-- calls where we restrict our attention to /interesting/ parts of the input domain.
pConstrain :: Double -> SBool -> Symbolic ()
pConstrain t c = addConstraint (Just t) c (bnot c)

-- | Boolean symbolic reduction. See if we can reduce a boolean condition to true/false
-- using the path context information, by making external calls to the SMT solvers. Used in the
-- implementation of 'sBranch'.
reduceInPathCondition :: SBool -> SBool
reduceInPathCondition b
  | isConcrete b = b -- No reduction is needed, already a concrete value
  | True         = SBV $ SVal k $ Right $ cache c
  where k    = kindOf b
        c st = do -- Now that we know our boolean is not obviously true/false. Need to make an external
                  -- call to the SMT solver to see if we can prove it is necessarily one of those
                  let pc = getPathCondition st
                  satTrue <- isSBranchFeasibleInState st "then" (pc &&& b)
                  if not satTrue
                     then return falseSW          -- condition is not satisfiable; so it must be necessarily False.
                     else do satFalse <- isSBranchFeasibleInState st "else" (pc &&& bnot b)
                             if not satFalse      -- negation of the condition is not satisfiable; so it must be necessarily True.
                                then return trueSW
                                else sbvToSW st b -- condition is not necessarily always True/False. So, keep symbolic.

-- Quickcheck interface on symbolic-booleans..
instance Testable SBool where
  property (SBV (SVal _ (Left b))) = property (cwToBool b)
  property s                       = error $ "Cannot quick-check in the presence of uninterpreted constants! (" ++ show s ++ ")"

instance Testable (Symbolic SBool) where
  property m = QC.whenFail (putStrLn msg) $ QC.monadicIO test
    where runOnce g = do (r, Result _ tvals _ _ cs _ _ _ _ _ cstrs _) <- runSymbolic' (Concrete g) m
                         let cval = fromMaybe (error "Cannot quick-check in the presence of uninterpeted constants!") . (`lookup` cs)
                             cond = all (cwToBool . cval) cstrs
                         when (isSymbolic r) $ error $ "Cannot quick-check in the presence of uninterpreted constants! (" ++ show r ++ ")"
                         if cond then if r `isConcretely` id
                                         then return False
                                         else do putStrLn $ complain tvals
                                                 return True
                                 else runOnce g -- cstrs failed, go again
          test = do die <- QC.run $ newStdGen >>= runOnce
                    when die $ fail "Falsifiable"
          msg = "*** SBV: See the custom counter example reported above."
          complain []     = "*** SBV Counter Example: Predicate contains no universally quantified variables."
          complain qcInfo = intercalate "\n" $ "*** SBV Counter Example:" : map (("  " ++) . info) qcInfo
            where maxLen = maximum (0:[length s | (s, _) <- qcInfo])
                  shN s = s ++ replicate (maxLen - length s) ' '
                  info (n, cw) = shN n ++ " = " ++ show cw

-- | Explicit sharing combinator. The SBV library has internal caching/hash-consing mechanisms
-- built in, based on Andy Gill's type-safe obervable sharing technique (see: <http://ittc.ku.edu/~andygill/paper.php?label=DSLExtract09>).
-- However, there might be times where being explicit on the sharing can help, especially in experimental code. The 'slet' combinator
-- ensures that its first argument is computed once and passed on to its continuation, explicitly indicating the intent of sharing. Most
-- use cases of the SBV library should simply use Haskell's @let@ construct for this purpose.
slet :: forall a b. (HasKind a, HasKind b) => SBV a -> (SBV a -> SBV b) -> SBV b
slet x f = SBV $ SVal k $ Right $ cache r
    where k    = kindOf (undefined :: b)
          r st = do xsw <- sbvToSW st x
                    let xsbv = SBV $ SVal (kindOf x) (Right (cache (const (return xsw))))
                        res  = f xsbv
                    sbvToSW st res

-- We use 'isVacuous' and 'prove' only for the "test" section in this file, and GHC complains about that. So, this shuts it up.
__unused :: a
__unused = error "__unused" (isVacuous :: SBool -> IO Bool) (prove :: SBool -> IO ThmResult)

{-# ANN module   ("HLint: ignore Reduce duplication" :: String)#-}
{-# ANN module   ("HLint: ignore Eta reduce" :: String)        #-}
