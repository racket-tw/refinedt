{-# LANGUAGE RecordWildCards #-}

module Toy.Language.EnvironmentUtils where

import qualified Data.HashMap.Strict as HM
import Control.Applicative
import Control.Arrow

import Toy.Language.Syntax.Decls
import Toy.Language.Syntax.Types

type ArgTypes = [(VarName, Ty)]

type Var2Ty = HM.HashMap VarName Ty

annotateFunTypes :: FunSig -> FunDef -> (ArgTypes, RefinedBaseTy)
annotateFunTypes sig def = (arg2type, resType)
  where
    (argTypes, resType) = splitTypes sig
    arg2type = zip (funArgs def) argTypes

    splitTypes = go . funTy
      where
        go (TyBase rbTy) = ([], rbTy)
        go (TyArrow ArrowTy { .. }) = first (domTy :) $ go codTy

buildVarsMap :: Monad m => (VarName -> Ty -> m a) -> ArgTypes -> m (HM.HashMap VarName a)
buildVarsMap f args = HM.fromList <$> mapM sequence [ (var, f var ty) | (var, ty) <- args ]

buildCombinedMapping :: Monad m => [FunSig] -> ArgTypes -> (VarName -> Ty -> m a) -> m (HM.HashMap VarName a)
buildCombinedMapping sigs args f = liftA2 (<>) (buildVarsMap f args) (buildVarsMap f sigs')
  where
    sigs' = [ (VarName funName, funTy) | FunSig { .. } <- sigs ]

buildTypesMapping :: Monad m => [FunSig] -> ArgTypes -> m Var2Ty
buildTypesMapping sigs args = buildCombinedMapping sigs args $ \_ ty -> pure ty
