{-| Module      :  TypeEnvironment
    License     :  GPL

    Maintainer  :  helium@cs.uu.nl
    Stability   :  experimental
    Portability :  portable
-}

-- A type environment for type inference in Core files

module Helium.CodeGeneration.Core.TypeEnvironment where

import Data.Maybe

import Helium.Utils.Utils
import Lvm.Core.Module
import Lvm.Core.Expr
import Lvm.Core.Type
import Lvm.Common.Id
import Lvm.Common.IdMap

import Text.PrettyPrint.Leijen

data TypeEnvironment = TypeEnvironment
  { typeEnvSynonyms :: IdMap Type
  , typeEnvValues :: IdMap Type
  }

typeEnvForModule :: CoreModule -> TypeEnvironment
typeEnvForModule (Module _ _ _ decls) = TypeEnvironment (mapFromList synonyms) (mapFromList values)
  where
    synonyms = [ (name, tp) | DeclTypeSynonym name _ tp _ <- decls ]
    values = mapMaybe findValue decls
    findValue :: CoreDecl -> Maybe (Id, Type)
    findValue decl
      | isValue decl = Just (declName decl, declType decl)
      | otherwise = Nothing
    isValue :: CoreDecl -> Bool
    isValue DeclValue{} = True
    isValue DeclAbstract{} = True
    isValue DeclCon{} = True
    isValue _ = False

typeEnvAddVariable :: Variable -> TypeEnvironment -> TypeEnvironment
typeEnvAddVariable (Variable name tp) env = env{ typeEnvValues = updateMap name tp $ typeEnvValues env }

typeEnvAddVariables :: [Variable] -> TypeEnvironment -> TypeEnvironment
typeEnvAddVariables vars env = foldr typeEnvAddVariable env vars

typeEnvAddBind :: Bind -> TypeEnvironment -> TypeEnvironment
typeEnvAddBind (Bind var _) = typeEnvAddVariable var

typeEnvAddBinds :: Binds -> TypeEnvironment -> TypeEnvironment
typeEnvAddBinds (Strict bind) env = typeEnvAddBind bind env
typeEnvAddBinds (NonRec bind) env = typeEnvAddBind bind env
typeEnvAddBinds (Rec binds) env = foldr typeEnvAddBind env binds

patternVariables :: TypeEnvironment -> Pat -> [Variable]
patternVariables _ (PatCon (ConTuple _) tps ids)
  = (zipWith Variable ids tps)
patternVariables env (PatCon (ConId name) tps ids)
  = findVars ids conType
  where
    conType = typeApplyList (typeOfId env name) tps
    findVars :: [Id] -> Type -> [Variable]
    findVars (x:xs) (TAp (TAp (TCon TConFun) tArg) tReturn)
      = Variable x tArg : findVars xs tReturn
    findVars [] _ = []
    findVars _ tp = internalError "Core.TypeEnvironment" "patternVariables" $ "Expected function type for constructor " ++ show name ++ ", got " ++ showType [] tp
patternVariables _ _ = [] -- Literal or default

typeEnvAddPattern :: Pat -> TypeEnvironment -> TypeEnvironment
typeEnvAddPattern pat env
  = typeEnvAddVariables (patternVariables env pat) env

typeNormalizeHead :: TypeEnvironment -> Type -> Type
typeNormalizeHead env = normalize False
  where
    normalize strict (TAp t1 t2) = case normalize False t1 of
      t1'@(TForall _ _ _) -> normalize strict $ typeApply t1' t2
      t1' ->
        let tp = TAp t1' t2
        in if strict then TStrict tp else tp
    normalize _ (TStrict t1) = normalize True t1
    normalize strict t1@(TCon (TConDataType name)) = case lookupMap name $ typeEnvSynonyms env of
      Just t2 -> normalize strict t2
      Nothing -> if strict then TStrict t1 else t1
    normalize True t1 = TStrict t1
    normalize False t1 = t1

typeOfId :: TypeEnvironment -> Id -> Type
typeOfId env name = case lookupMap name $ typeEnvValues env of
  Just tp -> tp
  Nothing -> internalError "Core.TypeEnvironment" "typeOfId" $ "variable " ++ show name ++ " not found in type environment"

typeOfCoreExpression :: TypeEnvironment -> Expr -> Type

-- Find type of the expression in the Let
typeOfCoreExpression env (Let binds expr)
  = typeOfCoreExpression (typeEnvAddBinds binds env) expr

-- All Alternatives of a Match should have the same return type,
-- so we only have to check the first one.
typeOfCoreExpression env (Match name (Alt pattern expr : _))
  = typeOfCoreExpression env' expr
  where
    env' = typeEnvAddPattern pattern env

-- Expression: e1 e2
-- Resolve the type of e1, which should be a function type.
typeOfCoreExpression env e@(Ap e1 e2) = case typeNotStrict $ typeNormalizeHead env $ typeOfCoreExpression env e1 of
  TAp (TAp (TCon TConFun) _) tReturn -> tReturn
  tp -> internalError "Core.TypeEnvironment" "typeOfCoreExpression" $ "expected a function type in the first argument of a function application, got " ++ showType [] tp ++ " in expression " ++ show (pretty e)

-- Expression: e1 { tp1 }
-- The type of e1 should be of the form `forall x. tp2`. Substitute x with tp1 in tp2.
typeOfCoreExpression env (ApType e1 tp1) = case typeNormalizeHead env $ typeOfCoreExpression env e1 of
  tp@(TForall (Quantor idx _) _ tp2) -> typeSubstitute idx tp1 tp2
  tp -> internalError "Core.TypeEnvironment" "typeOfCoreExpression" $ "typeOfCoreExpression: expected a forall type in the first argument of a function application, got " ++ showType [] tp

-- Expression: \x: t1 -> e
-- If e has type t2, then the lambda has type t1 -> t2
typeOfCoreExpression env (Lam var@(Variable _ tp) expr) =
  typeFunction [tp] $ typeOfCoreExpression env' expr
  where
    env' = typeEnvAddVariable var env

-- Expression: forall x. expr
-- If expr has type t, then the forall expression has type `forall x. t`.
typeOfCoreExpression env (Forall x kind expr) =
  TForall x kind $ typeOfCoreExpression env expr

-- Expression: (,)
-- Type: forall a. forall b. a -> b -> (a, b)
typeOfCoreExpression env (Con (ConTuple arity)) = typeTuple arity

-- Resolve the type of a variable or constructor
typeOfCoreExpression env (Con (ConId x)) = typeOfId env x
typeOfCoreExpression env (Var x) = typeOfId env x

-- Types of literals
typeOfCoreExpression _ (Lit lit) = typeOfLiteral lit

typeTuple :: Int -> Type
typeTuple arity = foldr (\var -> TForall (Quantor var Nothing) KStar) (typeFunction (map TVar vars) tp) vars
  where
    -- Type without quantifications, eg (a, b)
    tp = foldl (\t var -> TAp t $ TVar var) (TCon $ TConTuple arity) vars
    vars = [0 .. arity - 1]

-- Checks type equivalence
typeEqual :: TypeEnvironment -> Type -> Type -> Bool
typeEqual env TAny TAny = True
typeEqual env (TStrict t1) t2 = typeEqual env t1 t2 -- Ignore strictness
typeEqual env t1 (TStrict t2) = typeEqual env t1 t2 -- Ignore strictness
typeEqual env (TVar x1) (TVar x2) = x1 == x2
typeEqual env t1@(TCon _) t2 = typeEqualNoTypeSynonym env (typeNormalizeHead env t1) (typeNormalizeHead env t2)
typeEqual env t1 t2@(TCon _) = typeEqualNoTypeSynonym env (typeNormalizeHead env t1) (typeNormalizeHead env t2)
typeEqual env t1@(TAp _ _) t2 = typeEqualNoTypeSynonym env (typeNormalizeHead env t1) (typeNormalizeHead env t2)
typeEqual env t1 t2@(TAp _ _) = typeEqualNoTypeSynonym env (typeNormalizeHead env t1) (typeNormalizeHead env t2)
typeEqual env (TForall (Quantor x _) _ t1) (TForall (Quantor y _) _ t2) =
  typeEqual env t1 (typeSubstitute y (TVar x) t2)
typeEqual env _ _ = False

-- Checks type equivalence, assuming that there is no synonym at the head of the type
typeEqualNoTypeSynonym :: TypeEnvironment -> Type -> Type -> Bool
typeEqualNoTypeSynonym env (TAp tl1 tl2) (TAp tr1 tr2)
  = typeEqualNoTypeSynonym env tl1 tr1
  && typeEqual env tl2 tr2
typeEqualNoTypeSynonym _ (TAp _ _) _ = False
typeEqualNoTypeSynonym _ _ (TAp _ _) = False
typeEqualNoTypeSynonym _ (TCon c1) (TCon c2) = c1 == c2
typeEqualNoTypeSynonym _ (TCon _) _ = False
typeEqualNoTypeSynonym _ _ (TCon _) = False
typeEqualNoTypeSynonym env t1 t2 = typeEqual env t1 t2

typeOfLiteral :: Literal -> Type
typeOfLiteral (LitInt _ tp) = TCon $ TConDataType $ idFromString $ show tp
typeOfLiteral (LitDouble _) = TCon $ TConDataType $ idFromString "Double"
typeOfLiteral (LitBytes _) = TCon $ TConDataType $ idFromString "String"

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
  TStrict tp' -> extractFunctionTypeWithArity env arity tp'
  TForall quantor _ tp' ->
    let FunctionType args ret = extractFunctionTypeWithArity env arity tp'
    in FunctionType (Left quantor : args) ret
  TAp (TAp (TCon TConFun) tArg) tReturn ->
    let FunctionType args ret = extractFunctionTypeWithArity env (arity - 1) tReturn
    in FunctionType (Right tArg : args) ret
  _ -> error ("extractFunctionTypeWithArity: expected function type or forall type, got " ++ showType [] tp)
