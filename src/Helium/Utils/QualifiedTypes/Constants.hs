module Helium.Utils.QualifiedTypes.Constants where

import Top.Types

---------------------------------------------------------
-- Qualified base types which are defined in LvmLang.core
     
constants = ["Int", "Char", "String", "Float", "Bool"]

{-Since we use qualified types now, all references to intType, charType, stringType, floatType and boolType should be changed to these-}
intQualType, charQualType, stringQualType, floatQualType, boolQualType :: Tp
intQualType    = TCon "Int"
charQualType   = TCon "Char"
stringQualType = TCon "String"
floatQualType  = TCon "Float"
boolQualType   = TCon "Bool"
