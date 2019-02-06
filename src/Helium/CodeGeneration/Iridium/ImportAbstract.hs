module Helium.CodeGeneration.Iridium.ImportAbstract (toAbstractModule) where

import Data.Maybe(mapMaybe, catMaybes)
import Helium.CodeGeneration.Iridium.Data
import Helium.CodeGeneration.Iridium.Type
import Lvm.Common.Id (Id, idFromString)
import qualified Lvm.Core.Module as Core

toAbstractModule :: Module -> Core.Module v
toAbstractModule (Module name _ customs datas abstracts methods) = Core.Module name 0 0
  $ mapMaybe convertCustom customs
  ++ (datas >>= convertData)
  ++ mapMaybe convertMethod methods
  ++ mapMaybe convertAbstractMethod abstracts

convertCustom :: Declaration CustomDeclaration -> Maybe (Core.Decl v)
convertCustom (Declaration _ (ExportedAs name) mod customs (CustomDeclaration kind)) = Just $
  Core.DeclCustom name (toAccess name mod) kind customs
convertCustom _ = Nothing

convertData :: Declaration DataType -> [Core.Decl v]
convertData (Declaration _ (ExportedAs name) mod customs (DataType cons)) =
  Core.DeclCustom name (toAccess name mod) (Core.DeclKindCustom $ idFromString "data") customs
  : catMaybes (zipWith convertConstructor cons [0..])
convertData _ = []

convertConstructor :: Declaration DataTypeConstructorDeclaration -> Int -> Maybe (Core.Decl v)
convertConstructor (Declaration _ (ExportedAs name) mod customs (DataTypeConstructorDeclaration fields)) tag = Just $
  Core.DeclCon name (toAccess name mod) (length fields) tag customs
convertConstructor _ _ = Nothing

convertMethod :: Declaration Method -> Maybe (Core.Decl v)
convertMethod (Declaration _ (ExportedAs name) mod customs (Method args _ _ _ _)) = Just $
  Core.DeclAbstract name (toAccess name mod) (length args) customs
convertMethod _ = Nothing

convertAbstractMethod :: Declaration AbstractMethod -> Maybe (Core.Decl v)
convertAbstractMethod (Declaration _ (ExportedAs name) mod customs (AbstractMethod (FunctionType args _) _)) = Just $
  Core.DeclAbstract name (toAccess name mod) (length args) customs
convertAbstractMethod _ = Nothing

toAccess :: Id -> Maybe Id -> Core.Access
toAccess _ Nothing = Core.Defined True
toAccess name (Just mod) = Core.Imported True mod name Core.DeclKindValue 0 0
