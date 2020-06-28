{-# LANGUAGE ConstraintKinds, FlexibleContexts #-}
{-# LANGUAGE RecordWildCards, QuasiQuotes, LambdaCase #-}

module Toy.Language.Solver.QueryInterp(solveDef) where

import qualified Data.HashMap.Strict as HM
import Control.Conditional
import Control.Monad.State.Strict
import Data.Foldable
import Data.String.Interpolate
import Z3.Monad

import Toy.Language.EnvironmentUtils
import Toy.Language.Solver.Types
import Toy.Language.Syntax

newtype Z3Var = Z3Var { getZ3Var :: AST } deriving (Show)

newtype ConvertState = ConvertState { variables :: HM.HashMap VarName Z3Var } deriving (Show)

type MonadConvert m = (MonadZ3 m, MonadState ConvertState m)

solveDef :: FunSig -> QFunDef -> IO (SolveRes, VCFunDef SolveRes)
solveDef funSig funDef = evalZ3 $ do
  (intrAssertions, qTerm) <- evalStateT buildAsts $ ConvertState mempty
  assert $ getIntrinsicAssertions intrAssertions
  sTerm <- solveQTerm qTerm
  pure (isAllCorrect $ query <$> sTerm, funDef { funBody = sTerm })
  where
    args = fst $ funTypesMapping funSig funDef
    term = funBody funDef
    refTerm = refAnn <$> term
    buildAsts = do
      initArgVars args
      initRefVars refTerm
      intrAssertions <- mkIntrinsicAssertions refTerm
      qTerm <- convertQTerm term
      pure (intrAssertions, qTerm)

initArgVars :: MonadConvert m => ArgTypes -> m ()
initArgVars = mapM_ $ \(varName, ty) -> createVar ty varName

initRefVars :: MonadConvert m => RefAnnTerm -> m ()
initRefVars = mapM_ $ \RefAnn { .. } -> createVar tyAnn $ subjectVar intrinsic

newtype IntrinsicAssertions = IntrinsicAssertions { getIntrinsicAssertions :: AST }

mkIntrinsicAssertions :: MonadConvert m => RefAnnTerm -> m IntrinsicAssertions
mkIntrinsicAssertions term = fmap IntrinsicAssertions $ mapM (convertRefinement . intrinsic) term >>= mkAnd'

convertQTerm :: MonadConvert m => QTerm -> m (VCTerm AST)
convertQTerm = onVCTerm convertQuery

convertQuery :: MonadConvert m => Query -> m AST
convertQuery (q1 :& q2) = join $ (\a b -> mkAnd [a, b]) <$> convertQuery q1 <*> convertQuery q2
convertQuery (antecedent :=> consequent) = do
  -- TODO find a better way
  v' <- createVar (TyBase $ RefinedBaseTy TInt trueRefinement) $ subjectVar antecedent
  antecedent' <- convertRefinement antecedent
  consequent' <- convertRefinement consequent
  implication <- mkImplies antecedent' consequent'
  vApp <- toApp $ getZ3Var v'
  mkForallConst [] [vApp] implication

solveQTerm :: MonadZ3 m => VCTerm AST -> m (VCTerm SolveRes)
solveQTerm = onVCTerm $ \queryAST -> local $ do
  assert =<< mkNot queryAST
  convertZ3Result . invert <$> check
  where
    invert Sat = Unsat
    invert Unsat = Sat
    invert Undef = Undef

convertRefinement :: MonadConvert m => Refinement -> m AST
convertRefinement Refinement { .. } = mapM (convertTerm . getARTerm) conjuncts >>= mkAnd'
  where
    convertTerm = \case
      TName _ varName -> getZ3Var <$> getVar varName
      TInteger _ n -> mkIntNum n
      TBinOp _ t1 op t2 -> join $ convertBinOp op <$> convertTerm t1 <*> convertTerm t2
      TApp {} -> error "fun app at refinement level unsupported yet" -- TODO
      TIfThenElse { .. } -> do
        tthenCond' <- convertTerm tcond
        tthen' <- convertTerm tthen

        telseCond' <- mkNot tthenCond'
        telse' <- convertTerm telse

        thenBranch <- mkImplies tthenCond' tthen'
        elseBranch <- mkImplies telseCond' telse'

        mkAnd [thenBranch, elseBranch]
    convertBinOp = \case
      BinOpPlus -> \a b -> mkAdd [a, b]
      BinOpMinus -> \a b -> mkAdd [a, b]
      BinOpLt -> mkLt
      BinOpLeq -> mkLe
      BinOpEq -> mkEq
      BinOpNEq -> \a b -> mkEq a b >>= mkNot
      BinOpGt -> mkGt
      BinOpGeq -> mkGe

createVar :: MonadConvert m => Ty -> VarName -> m Z3Var
createVar ty varName = do
  ifM (gets $ HM.member varName . variables)
    (error [i|#{getName varName} has already been instantiated|])
    (pure ())
  z3var <- Z3Var <$> mkFreshTypedVar ty (getName varName)
  modify' $ \cs -> cs { variables = HM.insert varName z3var $ variables cs }
  pure z3var
  where
    mkFreshTypedVar (TyBase rbty) = case baseType rbty of
                                         TInt -> mkFreshIntVar
                                         TBool -> mkFreshBoolVar
                                         TIntList -> error "TODO TIntList unsupported" -- TODO
    mkFreshTypedVar TyArrow {} = \name -> mkStringSymbol name >>= mkUninterpretedSort >>= mkFreshConst name

getVar :: MonadConvert m => VarName -> m Z3Var
getVar varName = gets $ (HM.! varName) . variables

mkAnd' :: (Foldable t, MonadZ3 m) => t AST -> m AST
mkAnd' = mk . toList
  where
    mk [] = mkTrue
    mk [x] = pure x
    mk xs = mkAnd xs
