{-| Module      :  Type
    License     :  GPL

    Maintainer  :  helium@cs.uu.nl
    Stability   :  experimental
    Portability :  portable
-}

-- Iridium is the intermediate representation (IR) that we use between Core and LLVM. It is an imperative
-- strict language. It features pattern matching.
--
-- A method consists of blocks. The first block of a method is the entry block. Each block takes arguments,
-- the entry block describes the arguments of the method.

module Helium.CodeGeneration.Iridium.Type
  ( typeFromFunctionType, FunctionType(..), extractFunctionTypeNoSynonyms, extractFunctionTypeWithArity
  , Type(..), TypeConstant(..)
  , FloatPrecision(..), Core.TypeEnvironment(..), Core.typeEnvEmpty, Core.typeNormalizeHead, Core.typeEqual, typeIsStrict, typeToStrict
  , typeNotStrict, typeRemoveArgumentStrictness, Core.typeNormalize
  , typeRealWorld, typeUnsafePtr, typeTrampoline, typeRegion, typeInt, typeInt16, typeChar, typeFloat, functionTypeArity
  ) where

import Lvm.Common.Id(Id, stringFromId, idFromString)
import Data.List(intercalate)
import Data.Either(isRight)
import Lvm.Core.Type
import Helium.CodeGeneration.Core.TypeEnvironment as Core

typeRealWorld, typeUnsafePtr, typeTrampoline, typeInt, typeInt16, typeChar, typeFloat :: Type
typeRealWorld = TStrict $ TCon $ TConDataType $ idFromString "$RealWorld"
typeUnsafePtr = TStrict $ TCon $ TConDataType $ idFromString "$UnsafePtr"
typeTrampoline = TStrict $ TCon $ TConDataType $ idFromString "$Trampoline"
typeRegion = TStrict $ TCon $ TConDataType $ idFromString "$Region"
typeInt = TStrict $ TCon $ TConDataType $ idFromString "Int"
typeInt16 = TStrict $ TCon $ TConDataType $ idFromString "Int16"
typeChar = TStrict $ TCon $ TConDataType $ idFromString "Char"
typeFloat = TStrict $ TCon $ TConDataType $ idFromString "Float"

data FloatPrecision = Float32 | Float64 deriving (Eq, Ord)

applyWithArity :: Int -> Type -> Type
applyWithArity 0 tp = tp
applyWithArity n (TAp (TAp (TCon TConFun) _) tp) = applyWithArity (n - 1) tp
applyWithArity _ tp = error ("Expected function type, got `" ++ showType [] tp ++ "' instead")

functionTypeArity :: FunctionType -> Int
functionTypeArity (FunctionType args _) = length $ filter isRight args