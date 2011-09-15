----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.SMT.SMTLib2
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Conversion of symbolic programs to SMTLib format, Using v2 of the standard
-----------------------------------------------------------------------------
{-# LANGUAGE PatternGuards #-}

module Data.SBV.SMT.SMTLib2(cvt, addNonEqConstraints) where

import qualified Data.Foldable as F (toList)
import qualified Data.Map      as M
import Data.List (intercalate, partition)
import Numeric (showHex)

import Data.SBV.BitVectors.Data

tbd :: String -> a
tbd m = error $ "SBV.SMTLib2: Not-yet-supported: " ++ m ++ ". Please report."

addNonEqConstraints :: [(Quantifier, NamedSymVar)] -> [[(String, CW)]] -> SMTLibPgm -> Maybe String
addNonEqConstraints qinps allNonEqConstraints (SMTLibPgm _ (aliasTable, pre, post))
  | null allNonEqConstraints
  = Just $ intercalate "\n" $ pre ++ post
  | null refutedModel
  = Nothing
  | True
  = Just $ intercalate "\n" $ pre
    ++ [ "; --- refuted-models ---" ]
    ++ concatMap nonEqs (map (map intName) nonEqConstraints)
    ++ post
 where refutedModel = concatMap nonEqs (map (map intName) nonEqConstraints)
       intName (s, c)
          | Just sw <- s `lookup` aliasTable = (show sw, c)
          | True                             = (s, c)
       -- with QBVF, we only add top-level existentials to the refuted-models list
       nonEqConstraints = filter (not . null) $ map (filter (\(s, _) -> s `elem` topUnivs)) allNonEqConstraints
       topUnivs = [s | (_, (_, s)) <- takeWhile (\p -> fst p == EX) qinps]

nonEqs :: [(String, CW)] -> [String]
nonEqs []     =  []
nonEqs [sc]   =  ["(assert " ++ nonEq sc ++ ")"]
nonEqs (sc:r) =  ["(assert (or " ++ nonEq sc]
              ++ map (("            " ++) . nonEq) r
              ++ ["        ))"]

nonEq :: (String, CW) -> String
nonEq (s, c) = "(not (= " ++ s ++ " " ++ cvtCW c ++ "))"

cvt :: Bool                                        -- ^ is this a sat problem?
    -> [String]                                    -- ^ extra comments to place on top
    -> [(Quantifier, NamedSymVar)]                 -- ^ inputs
    -> [Either SW (SW, [SW])]                      -- ^ skolemized version inputs
    -> [(SW, CW)]                                  -- ^ constants
    -> [((Int, (Bool, Int), (Bool, Int)), [SW])]   -- ^ auto-generated tables
    -> [(Int, ArrayInfo)]                          -- ^ user specified arrays
    -> [(String, SBVType)]                         -- ^ uninterpreted functions/constants
    -> [(String, [String])]                        -- ^ user given axioms
    -> Pgm                                         -- ^ assignments
    -> SW                                          -- ^ output variable
    -> ([String], [String])
cvt isSat comments _inps skolemInps consts tbls arrs uis axs asgnsSeq out = (pre, [])
  where pre  =  [ "; Automatically generated by SBV. Do not edit." ]
             ++ map ("; " ++) comments
             ++ [ "(set-option :produce-models true)"
                , "; --- literal constants ---"
                ]
             ++ concatMap declConst consts
             ++ [ "; --- skolem constants ---" ]
             ++ [ "(declare-fun " ++ show s ++ " " ++ smtFunType ss s ++ ")" | Right (s, ss) <- skolemInps]
             ++ [ "; --- tables ---" ]
             ++ map declTable tbls
             ++ concat tableConstants
              ++ [ " ; --- arrays ---" ]
              ++ concatMap (declArray (map fst consts) skolemMap) arrs
             ++ [ " ; --- uninterpreted constants ---" ]
             ++ concatMap declUI uis
             ++ [ " ; --- user given axioms ---" ]
             ++ map declAx axs
             ++ [ "; --- formula ---" ]
             ++ [if null foralls
                 then "(assert ; no quantifiers"
                 else "(assert (forall (" ++ intercalate "\n                 "
                                             ["(" ++ show s ++ " " ++ smtType s ++ ")" | s <- foralls] ++ ")"]
             ++ map (letAlign . mkLet) asgns
             ++ map letAlign (if null tableDelayeds then [] else "(and " : tableDelayeds)
             ++ [ letAlign assertOut ++ replicate noOfCloseParens ')' ]
        noOfCloseParens = length asgns + (if null foralls then 1 else 2) + (if null tableDelayeds then 0 else 1)
        (tableConstants, allTableDelayeds) = unzip $ map (genTableData (not (null foralls)) (map fst consts)) tbls
        tableDelayeds = concat allTableDelayeds
        foralls = [s | Left s <- skolemInps]
        letAlign s
          | null foralls = "   " ++ s
          | True         = "            " ++ s
        assertOut | isSat = "(= " ++ show out ++ " #b1)"
                  | True  = "(= " ++ show out ++ " #b0)"
        skolemMap = M.fromList [(s, ss) | Right (s, ss) <- skolemInps, not (null ss)]
        asgns = F.toList asgnsSeq
        mkLet (s, e) = "(let ((" ++ show s ++ " " ++ cvtExp skolemMap e ++ "))"
        declConst (s, c) = [ "(declare-fun " ++ show s ++ " " ++ smtFunType [] s ++ ")"
                           , "(assert (= " ++ show s ++ " " ++ cvtCW c ++ "))"
                           ]

declUI :: (String, SBVType) -> [String]
declUI (i, t) = ["(declare-fun uninterpreted_" ++ i ++ " " ++ cvtType t ++ ")"]

-- NB. We perform no check to as to whether the axiom is meaningful in any way.
declAx :: (String, [String]) -> String
declAx (nm, ls) = (";; -- user given axiom: " ++ nm ++ "\n   ") ++ intercalate "\n" ls

declTable :: ((Int, (Bool, Int), (Bool, Int)), [SW]) -> String
declTable ((i, (_, at), (_, rt)), _elts) = decl
  where t         = "table" ++ show i
        bv sz     = "(_ BitVec " ++ show sz ++ ")"
        decl      = "(declare-fun " ++ t ++ " (" ++ bv at ++ ") " ++ bv rt ++ ")"

genTableData :: Bool -> [SW] -> ((Int, (Bool, Int), (Bool, Int)), [SW]) -> ([String], [String])
genTableData quantified consts ((i, (sa, at), (_, _rt)), elts) = (map snd pre, map snd post)
  where (pre, post) = partition fst (zipWith mkElt elts [(0::Int)..])
        t           = "table" ++ show i
        mkElt x k   = (isReady, wrap ("(= (" ++ t ++ " " ++ idx ++ ") " ++ show x ++ ")"))
          where idx = cvtCW (mkConstCW (sa, at) k)
                isReady = not quantified || x `elem` consts
                wrap s | isReady = "(assert " ++ s ++ ")"
                       | True    = s

-- TODO: Also support the cases when the used SW is not a constant. Rare, but can happen
declArray :: [SW] -> SkolemMap -> (Int, ArrayInfo) -> [String]
declArray consts skolemMap (i, (_, ((_, at), (_, rt)), ctx)) = adecl : ctxInfo
  where nm = "array_" ++ show i
        ssw sw | sw `elem` consts = cvtSW skolemMap sw
               | True             = tbd $ "declArray: Array context with non constant: " ++ show ctx
        adecl = "(declare-fun " ++ nm ++ "() (Array (_ BitVec " ++ show at ++ ") (_ BitVec " ++ show rt ++ ")))"
        ctxInfo = case ctx of
                    ArrayFree Nothing   -> []
                    ArrayFree (Just sw) -> declA sw
                    ArrayReset _ sw     -> declA sw
                    ArrayMutate j a b -> ["(assert (= " ++ nm ++ " (store array_" ++ show j ++ " " ++ ssw a ++ " " ++ ssw b ++ ")))"]
                    ArrayMerge  t j k -> ["(assert (= " ++ nm ++ " (ite (= #b1 " ++ ssw t ++ ") array_" ++ show j ++ " array_" ++ show k ++ ")))"]
        declA sw = let iv = nm ++ "_freeInitializer"
                   in [ "(declare-fun " ++ iv ++ "() (_ BitVec " ++ show at ++ "))"
                      , "(assert (= (select " ++ nm ++ " " ++ iv ++ ") " ++ ssw sw ++ ")"
                      ]

smtType :: SW -> String
smtType s = "(_ BitVec " ++ show (sizeOf s) ++ ")"

smtFunType :: [SW] -> SW -> String
smtFunType ss s = "(" ++ intercalate " " (map smtType ss) ++ ") " ++ smtType s

cvtType :: SBVType -> String
cvtType (SBVType []) = error "SBV.SMT.SMTLib2.cvtType: internal: received an empty type!"
cvtType (SBVType xs) = "(" ++ intercalate " " (map sh body) ++ ") " ++ sh ret
  where (body, ret) = (init xs, last xs)
        sh (_, s)   = "(_ BitVec " ++ show s ++ ")"

type SkolemMap = M.Map SW [SW]

cvtSW :: SkolemMap -> SW -> String
cvtSW skolemMap s
  | Just ss <- s `M.lookup` skolemMap
  = "(" ++ show s ++ concatMap ((" " ++) . show) ss ++ ")"
  | True
  = show s

-- NB. The following works with SMTLib2 since all sizes are multiples of 4 (or just 1, which is specially handled)
hex :: Int -> Integer -> String
hex 1  v = "#b" ++ show v
hex sz v = "#x" ++ pad (sz `div` 4) (showHex v "")
  where pad n s = take (n - length s) (repeat '0') ++ s

cvtCW :: CW -> String
cvtCW x | not (hasSign x) = hex (sizeOf x) (cwVal x)
-- signed numbers (with 2's complement representation) is problematic
-- since there's no way to put a bvneg over a positive number to get minBound..
-- Hence, we punt and use binary notation in that particular case
cvtCW x | cwVal x == least = mkMinBound (sizeOf x)
  where least = negate (2 ^ sizeOf x)
cvtCW x = negIf (w < 0) $ hex (sizeOf x) (abs w)
  where w = cwVal x

negIf :: Bool -> String -> String
negIf True  a = "(bvneg " ++ a ++ ")"
negIf False a = a

-- anamoly at the 2's complement min value! Have to use binary notation here
-- as there is no positive value we can provide to make the bvneg work.. (see above)
mkMinBound :: Int -> String
mkMinBound i = "#b1" ++ take (i-1) (repeat '0')

cvtExp :: SkolemMap -> SBVExpr -> String
cvtExp skolemMap expr = sh expr
  where ssw = cvtSW skolemMap
        sh (SBVApp Ite [a, b, c]) = "(ite (= #b1 " ++ ssw a ++ ") " ++ ssw b ++ " " ++ ssw c ++ ")"
        sh (SBVApp (Rol i) [a])   = rot ssw "rotate_left"  i a
        sh (SBVApp (Ror i) [a])   = rot ssw "rotate_right" i a
        sh (SBVApp (Shl i) [a])   = shft ssw "bvshl"  "bvshl"  i a
        sh (SBVApp (Shr i) [a])   = shft ssw "bvlshr" "bvashr" i a
        sh (SBVApp (LkUp (t, (_, at), _, l) i e) [])
          | needsCheck = "(ite " ++ cond ++ ssw e ++ " " ++ lkUp ++ ")"
          | True       = lkUp
          where needsCheck = (2::Integer)^(at) > (fromIntegral l)
                lkUp = "(table" ++ show t ++ " " ++ show i ++ ")"
                cond
                 | hasSign i = "(or " ++ le0 ++ " " ++ gtl ++ ") "
                 | True      = gtl ++ " "
                (less, leq) = if hasSign i then ("bvslt", "bvsle") else ("bvult", "bvule")
                mkCnst = cvtCW . mkConstCW (hasSign i, sizeOf i)
                le0  = "(" ++ less ++ " " ++ ssw i ++ " " ++ mkCnst 0 ++ ")"
                gtl  = "(" ++ leq  ++ " " ++ mkCnst l ++ " " ++ ssw i ++ ")"
        sh (SBVApp (Extract i j) [a]) = "(extract[" ++ show i ++ ":" ++ show j ++ "] " ++ ssw a ++ ")"
        sh (SBVApp (ArrEq i j) []) = "(ite (= array_" ++ show i ++ " array_" ++ show j ++") #b1 #b0)"
        sh (SBVApp (ArrRead i) [a]) = "(select array_" ++ show i ++ " " ++ ssw a ++ ")"
        sh (SBVApp (Uninterpreted nm) [])   = "uninterpreted_" ++ nm
        sh (SBVApp (Uninterpreted nm) args) = "(uninterpreted_" ++ nm ++ " " ++ intercalate " " (map ssw args) ++ ")"
        sh inp@(SBVApp op args)
          | Just f <- lookup op smtOpTable
          = f (any hasSign args) (map ssw args)
          | True
          = error $ "SBV.SMT.SMTLib2.sh: impossible happened; can't translate: " ++ show inp
          where lift2  o _ [x, y] = "(" ++ o ++ " " ++ x ++ " " ++ y ++ ")"
                lift2  o _ sbvs   = error $ "SBV.SMTLib2.sh.lift2: Unexpected arguments: "   ++ show (o, sbvs)
                lift2B oU oS sgn sbvs
                  | sgn
                  = "(ite " ++ lift2 oS sgn sbvs ++ " #b1 #b0)"
                  | True
                  = "(ite " ++ lift2 oU sgn sbvs ++ " #b1 #b0)"
                lift2N o sgn sbvs = "(bvnot " ++ lift2 o sgn sbvs ++ ")"
                lift1  o _ [x]    = "(" ++ o ++ " " ++ x ++ ")"
                lift1  o _ sbvs   = error $ "SBV.SMT.SMTLib2.sh.lift1: Unexpected arguments: "   ++ show (o, sbvs)
                smtOpTable = [ (Plus,          lift2   "bvadd")
                             , (Minus,         lift2   "bvsub")
                             , (Times,         lift2   "bvmul")
                             , (Quot,          lift2   "bvudiv")
                             , (Rem,           lift2   "bvurem")
                             , (Equal,         lift2   "bvcomp")
                             , (NotEqual,      lift2N  "bvcomp")
                             , (LessThan,      lift2B  "bvult" "bvslt")
                             , (GreaterThan,   lift2B  "bvugt" "bvsgt")
                             , (LessEq,        lift2B  "bvule" "bvsle")
                             , (GreaterEq,     lift2B  "bvuge" "bvsge")
                             , (And,           lift2   "bvand")
                             , (Or,            lift2   "bvor")
                             , (XOr,           lift2   "bvxor")
                             , (Not,           lift1   "bvnot")
                             , (Join,          lift2   "concat")
                             ]

rot :: (SW -> String) -> String -> Int -> SW -> String
rot ssw o c x = "(" ++ o ++ "[" ++ show c ++ "] " ++ ssw x ++ ")"

shft :: (SW -> String) -> String -> String -> Int -> SW -> String
shft ssw oW oS c x = "(" ++ o ++ " " ++ ssw x ++ " " ++ cvtCW c' ++ ")"
   where s  = hasSign x
         c' = mkConstCW (s, sizeOf x) c
         o  = if hasSign x then oS else oW