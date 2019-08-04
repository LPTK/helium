module Helium.CodeGeneration.Iridium.ImportAbstract (toAbstractModule) where

import Data.Maybe(mapMaybe, catMaybes)
import Helium.CodeGeneration.Iridium.Data
import Helium.CodeGeneration.Iridium.Type
import Lvm.Common.Id (Id, idFromString)
import qualified Lvm.Core.Module as Core
import qualified Lvm.Core.Type as Core

toAbstractModule :: Module -> Core.Module v
toAbstractModule (Module name _ customs datas synonyms abstracts methods) = Core.Module name 0 0
  $ mapMaybe convertCustom customs
  ++ (datas >>= convertData)
  ++ mapMaybe convertMethod methods
  ++ mapMaybe convertAbstractMethod abstracts
  ++ mapMaybe convertTypeSynonym synonyms

convertCustom :: Declaration CustomDeclaration -> Maybe (Core.Decl v)
convertCustom (Declaration _ (ExportedAs name) mod customs (CustomDeclaration kind)) = Just $
  Core.DeclCustom name (toAccess name mod) kind customs
convertCustom _ = Nothing

convertData :: Declaration DataType -> [Core.Decl v]
convertData (Declaration _ (ExportedAs name) mod customs (DataType cons)) =
  Core.DeclCustom name (toAccess name mod) (Core.DeclKindCustom $ idFromString "data") customs
  : catMaybes (map convertConstructor cons)
convertData _ = []

convertConstructor :: Declaration DataTypeConstructorDeclaration -> Maybe (Core.Decl v)
convertConstructor (Declaration _ (ExportedAs name) mod customs (DataTypeConstructorDeclaration tp)) = Just $
  Core.DeclCon name (toAccess name mod) tp customs
convertConstructor _ = Nothing

convertMethod :: Declaration Method -> Maybe (Core.Decl v)
convertMethod (Declaration _ (ExportedAs name) mod customs method) = Just $
  Core.DeclAbstract name (toAccess name mod) (methodArity method) (methodType method) customs
convertMethod _ = Nothing

convertAbstractMethod :: Declaration AbstractMethod -> Maybe (Core.Decl v)
convertAbstractMethod (Declaration _ (ExportedAs name) mod customs (AbstractMethod arity tp _)) = Just $
  Core.DeclAbstract name (toAccess name mod) arity tp customs
convertAbstractMethod _ = Nothing

convertTypeSynonym :: Declaration TypeSynonym -> Maybe (Core.Decl v)
convertTypeSynonym d@(Declaration _ (ExportedAs name) mod customs (TypeSynonym tp)) = Just $
  Core.DeclTypeSynonym name (toAccess name mod) tp customs
convertTypeSynonym _ = Nothing

toAccess :: Id -> Maybe Id -> Core.Access
toAccess _ Nothing = Core.Defined True
toAccess name (Just mod) = Core.Imported True mod name Core.DeclKindValue 0 0