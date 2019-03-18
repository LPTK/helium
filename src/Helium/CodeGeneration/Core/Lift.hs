{-| Module      :  Lift
    License     :  GPL

    Maintainer  :  helium@cs.uu.nl
    Stability   :  experimental
    Portability :  portable
-}

-- Lift lambdas and non-strict let declarations to toplevel.
-- Transforms the program such that all non-strict let declarations have a function application as binding.
-- We do so by adding new toplevel functions for those let declarations.
-- Furthermore we apply lambda lifting; all lambda expressions will be moved to toplevel declarations.
--
-- Before:
-- foo z =
--   let x = (let! y = f z in f y)
--   in f x
-- After:
-- ''x.1'' z = let! y = f z in f y
-- foo z = let x = ''x.1'' z in f x
--
-- Assumes that the AST is normalized, ie. the Normalize pass should be executed before.

module Helium.CodeGeneration.Core.Lift (coreLift) where

import Lvm.Common.Id
import Lvm.Common.IdSet
import Lvm.Common.IdMap
import Lvm.Core.Expr
import Lvm.Core.Type
import Lvm.Core.Utils

import Data.Maybe (catMaybes)

type Env = IdMap Id

coreLift :: NameSupply -> CoreModule -> CoreModule
coreLift supply (Module name major minor decls) = Module name major minor decls'
  where
    decls' = concat $ mapWithSupply liftExprInDecl supply decls

boundVar :: Bind -> Variable
boundVar (Bind var _) = var

liftExprInDecl :: NameSupply -> CoreDecl -> ([CoreDecl])
liftExprInDecl supply (DeclValue name access enc expr customs) = DeclValue name access enc expr' customs : decls
  where
    (expr', decls) = liftExprIgnoreLambdas supply [] expr emptyMap
liftExprInDecl _ decl = [decl]

liftExprIgnoreLambdas :: NameSupply -> [Variable] -> Expr -> Env -> (Expr, [CoreDecl])
liftExprIgnoreLambdas supply scope (Lam x expr) env = (Lam x expr', decls)
  where
    (expr', decls) = liftExprIgnoreLambdas supply (x : scope) expr env
liftExprIgnoreLambdas supply scope (Forall x k expr) env = (Forall x k expr', decls)
  where
    -- We should also keep track of all type variables which are in scope
    (expr', decls) = liftExprIgnoreLambdas supply scope expr env
liftExprIgnoreLambdas supply scope expr env = liftExpr supply scope expr env

liftExpr :: NameSupply -> [Variable] -> Expr -> Env -> (Expr, [CoreDecl])
liftExpr supply scope (Let (Strict b) e) env =
  ( case b' of
    Nothing -> e'
    Just bind -> Let (Strict bind) e'
  , decls1 ++ decls2
  )
  where
    (supply1, supply2) = splitNameSupply supply
    (b', decls1, envMap) = strictBind supply1 scope b env
    scope' = case b' of
      Nothing -> scope
      Just _ -> boundVar b : scope
    (e', decls2) = liftExpr supply2 (scope') e (envMap env)
liftExpr supply scope (Let (NonRec b) e) env =
  ( case b' of
      Nothing -> e'
      Just bind -> Let (NonRec bind) e'
  , decls1 ++ decls2
  )
  where
    (supply1, supply2) = splitNameSupply supply
    (b', decls1, envMap) = lazyBind False supply1 scope b env
    scope' = case b' of
      Nothing -> scope
      Just _ -> boundVar b : scope
    (e', decls2) = liftExpr supply2 scope' e (envMap env)
liftExpr supply scope (Let (Rec bs) e) env = (Let (Rec $ catMaybes bs') e', concat decls1 ++ decls2)
  where
    scope' = map boundVar bs ++ scope
    (supply1, supply2) = splitNameSupply supply
    (bs', decls1, envMaps) = unzip3 $ mapWithSupply (\s b -> lazyBind True s scope' b env) supply1 bs
    (e', decls2) = liftExpr supply2 scope' e (foldr id env envMaps)
liftExpr supply scope (Match name alts) env = (Match (rename env name) alts', concat decls)
  where
    (alts', decls) = unzip $ mapWithSupply (\s a -> liftAlt s scope a env) supply alts
-- Convert `\x -> expr` to `let y = \x -> expr in y
liftExpr supply scope expr@(Lam _ _) env = liftExpr supply' scope (Let (NonRec bind) (Var name)) env
  where
    (name, supply') = freshId supply
    bind = Bind (Variable name TAny) expr
liftExpr supply scope (Forall x k expr) env = (Forall x k expr', decls)
  where
    -- TODO: Add type variable to scope
    (expr', decls) = liftExpr supply scope expr env
liftExpr supply scope (ApType expr t) env = (ApType expr' t, decls)
  where
    (expr', decls) = liftExpr supply scope expr env
-- After normalization the other expression constructors cannot have let bindings
-- as subexpressions, so we do not have to lift here. We do need to rename variables used in `expr`,
-- if they are mapped in `env`.
liftExpr supply scope expr env = (renameInSimpleExpr env expr, [])

-- Renames according to Env. Works on expressions consisting of Ap, Var, Con and Lit nodes.
renameInSimpleExpr :: Env -> Expr -> Expr
renameInSimpleExpr env (Var name) = Var $ rename env name
renameInSimpleExpr env (Ap e1 e2) = Ap (renameInSimpleExpr env e1) (renameInSimpleExpr env e2)
renameInSimpleExpr env (ApType e t) = ApType (renameInSimpleExpr env e) t
renameInSimpleExpr env e@(Con _) = e
renameInSimpleExpr env e@(Lit _) = e

rename :: Env -> Id -> Id
rename env name = case lookupMap name env of
  Nothing -> name
  Just name' -> rename env name'

isQuantifiedLambda :: Expr -> Bool
isQuantifiedLambda (Forall _ _ expr) = isQuantifiedLambda expr
isQuantifiedLambda (Lam _ _) = True
isQuantifiedLambda _ = False

strictBind :: NameSupply -> [Variable] -> Bind -> Env -> (Maybe Bind, [CoreDecl], Env -> Env)
strictBind supply scope b@(Bind _ expr) env
  | isQuantifiedLambda expr = lazyBind False supply scope b env
strictBind supply scope (Bind var expr) env = (Just $ Bind var expr', decls, id)
  where
    (expr', decls) = liftExpr supply scope expr env

lazyBind :: Bool -> NameSupply -> [Variable] -> Bind -> Env -> (Maybe Bind, [CoreDecl], Env -> Env)
lazyBind isRec supply scope b@(Bind var@(Variable x t) expr) env
  -- Expression can already be put in a thunk, don't need to change anything.
  | isValidThunk expr = (Just (Bind var $ renameInSimpleExpr env expr), [], id)
  -- Do not construct a Bind if the value is placed in a toplevel value which is not a Lambda
  | null scope = (Nothing, decl : decls, insertMap x name)
  | otherwise = (Just $ Bind var ap, decl : decls, id)
  where
    ap = foldl (\e (Variable arg _) -> Ap e (Var arg)) (Var name) scope
    (name, supply') = freshId supply
    (supply1, supply2) = splitNameSupply supply'
    argNames :: [(Variable, Variable)]
    argNames = mapWithSupply (\s var@(Variable arg t) -> let (arg', _) = freshIdFromId arg s in (var, Variable arg' t)) supply1 scope
    env' = foldr (\(Variable arg _, Variable arg' _) -> insertMap arg arg') env argNames
    (expr', decls) = liftExprIgnoreLambdas supply2 (map snd argNames) expr env'
    value = foldr (Lam . snd) expr' argNames
    decl :: CoreDecl
    decl = DeclValue
      { declName = name
      , declAccess = Defined False
      , declType = typeFunction (map variableType scope) t
      , valueValue = value
      , declCustoms = []
      }

liftAlt :: NameSupply -> [Variable] -> Alt -> Env -> (Alt, [CoreDecl])
liftAlt supply scope (Alt pat expr) env = (Alt pat expr', decls)
  where
    (expr', decls) = liftExpr supply (map (\x -> Variable x TAny) newVars ++ scope) expr env
    newVars = case pat of
      PatCon _ _ ids -> ids
      _ -> []

isValidThunk :: Expr -> Bool
isValidThunk (Ap _ _) = True
isValidThunk (Forall _ _ e) = isValidThunk e
isValidThunk (ApType e _) = isValidThunk e
isValidThunk _ = False