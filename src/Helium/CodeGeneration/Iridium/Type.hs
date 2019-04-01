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
  , FloatPrecision(..), EvaluationState(..), evaluationState, typeFromFunctionType
  , Core.TypeEnvironment(..), Core.typeNormalizeHead, Core.typeEqual, typeIsStrict
  , PrimitiveType(..)
  , typeRealWorld, typeUnsafePtr, typeTrampoline, typeInt, typeChar, typeFloat, functionTypeArity
  ) where

import Lvm.Common.Id(Id, stringFromId, idFromString)
import Data.List(intercalate)
import Data.Either(isRight)
import Lvm.Core.Type
import Helium.CodeGeneration.Core.TypeEnvironment as Core

typeRealWorld, typeUnsafePtr, typeTrampoline, typeInt, typeChar, typeFloat :: Type
typeRealWorld = TCon $ TConDataType $ idFromString "$RealWorld"
typeUnsafePtr = TCon $ TConDataType $ idFromString "$UnsafePtr"
typeTrampoline = TCon $ TConDataType $ idFromString "$Trampoline"
typeInt = TCon $ TConDataType $ idFromString "Int"
typeChar = TCon $ TConDataType $ idFromString "Char"
typeFloat = TCon $ TConDataType $ idFromString "Float"

data PrimitiveType
  = TypeAny -- ^ Any value, possibly a non-evaluated thunk. Supertype of TypeAnyThunk and TypeAnyWHNF.
  | TypeAnyThunk -- ^ A thunk, not in WHNF
  | TypeAnyWHNF

  -- Subtypes of TypeAnyWHNF
  | TypeInt
  | TypeFloat FloatPrecision
  | TypeRealWorld
  | TypeDataType !Id
  | TypeTuple !Int
  | TypeFunction -- ^ Pointer to a function or a thunk in WHNF (partially applied function)
  | TypeGlobalFunction FunctionType -- ^ A global function

  -- Types used for the runtime
  | TypeUnsafePtr
  deriving (Eq, Ord)

data FloatPrecision = Float32 | Float64 deriving (Eq, Ord)

data EvaluationState = Unevaluated | EvaluationUnknown | Evaluated deriving (Show, Eq, Ord)

evaluationState :: PrimitiveType -> EvaluationState
evaluationState TypeAny = EvaluationUnknown
evaluationState TypeAnyThunk = Unevaluated
evaluationState _ = Evaluated

data FunctionType = FunctionType { functionArguments :: ![Either Quantor Type], functionReturnType :: !Type }
  deriving (Eq, Ord)

typeFromFunctionType :: FunctionType -> Type
typeFromFunctionType (FunctionType args ret) = foldr addArg ret args
  where
    addArg (Left quantor) = TForall quantor KStar
    addArg (Right tp) = TAp $ TAp (TCon $ TConFun) tp

extractFunctionTypeNoSynonyms :: Type -> FunctionType
extractFunctionTypeNoSynonyms (TForall quantor _ tp) = FunctionType (Left quantor : args) ret
  where
    FunctionType args ret = extractFunctionTypeNoSynonyms tp
extractFunctionTypeNoSynonyms (TAp (TAp (TCon TConFun) tArg) tReturn) = FunctionType (Right tArg : args) ret
  where
    FunctionType args ret = extractFunctionTypeNoSynonyms tReturn
extractFunctionTypeNoSynonyms tp = FunctionType [] tp

extractFunctionTypeWithArity :: TypeEnvironment -> Int -> Type -> FunctionType
extractFunctionTypeWithArity _ 0 tp = FunctionType [] tp
extractFunctionTypeWithArity env arity tp = case typeNormalizeHead env tp of
  (TForall quantor _ tp') ->
    let FunctionType args ret = extractFunctionTypeWithArity env arity tp'
    in FunctionType (Left quantor : args) ret
  (TAp (TAp (TCon TConFun) tArg) tReturn) ->
    let FunctionType args ret = extractFunctionTypeWithArity env (arity - 1) tReturn
    in FunctionType (Right tArg : args) ret
  _ -> error "extractFunctionTypeWithArity: expected function type or forall type"

applyWithArity :: Int -> Type -> Type
applyWithArity 0 tp = tp
applyWithArity n (TAp (TAp (TCon TConFun) _) tp) = applyWithArity (n - 1) tp
applyWithArity _ tp = error ("Expected function type, got `" ++ showType [] tp ++ "' instead")

functionTypeArity :: FunctionType -> Int
functionTypeArity (FunctionType args _) = length $ filter isRight args
