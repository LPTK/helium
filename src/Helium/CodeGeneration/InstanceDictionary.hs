module Helium.CodeGeneration.InstanceDictionary where

import Lvm.Core.Expr 
import Lvm.Core.Module

import Lvm.Common.Id 
import Lvm.Common.Byte

import Helium.CodeGeneration.CoreUtils
import Helium.ModuleSystem.ImportEnvironment
import Helium.Syntax.UHA_Syntax
import Helium.Syntax.UHA_Utils
import Helium.Utils.Utils

import Top.Types

import qualified Data.Map as M


constructFunctionMap :: ImportEnvironment -> Int -> Name -> [(Name, Int)]
constructFunctionMap env nrOfSupers name = 
    let 
        err = error "Invalid class name" 
        f :: (Name, a, b, c) -> Name
        f (n, _, _, _) = n 
        mapF = map f . snd
    in zip (maybe err mapF  $ M.lookup name (classMemberEnvironment env)) [nrOfSupers..]


--returns for every function in a class the function that retrieves that class from a dictionary
classFunctions :: ImportEnvironment -> String -> [(Name, Int)] -> [CoreDecl]
classFunctions importEnv className combinedNames = map superDict superclasses ++ map classFunction combinedNames
        where
            superclasses = zip (maybe [] fst (M.lookup className $ classEnvironment importEnv)) [0..]
            superDict :: (String, Int) -> CoreDecl
            superDict (superName, label) =
                let dictParam = idFromString "dict"
                    val = DeclValue 
                        { declName    = idFromString $ "$get" ++ superName ++ "$" ++ className
                        , declAccess  = public
                        , valueEnc    = Nothing
                        , valueValue  = Lam dictParam (Ap (Ap (Var dictParam) (Lit (LitInt label))) (Var dictParam))
                        , declCustoms = [custom "type" ("Dict$" ++ className ++" -> Dict$" ++ superName)]
                        }
                in val
            classFunction :: (Name, Int) -> CoreDecl
            classFunction (name, label) = 
                let dictParam = idFromString "dict"
                    val = DeclValue 
                        { declName    = idFromString $ getNameName name
                        , declAccess  = public
                        , valueEnc    = Nothing
                        , valueValue  = Lam dictParam (Ap (Ap (Var dictParam) (Lit (LitInt label))) (Var dictParam))
                        , declCustoms = toplevelType name importEnv True
                        }
                in val
         
combineDeclIndex :: [(Name, Int)] -> [(Name, CoreDecl)] -> [(Int, Name, Maybe CoreDecl)]
combineDeclIndex ls [] = map (\(n, l) -> (l, n, Nothing)) ls
combineDeclIndex [] _ = error "Inconsistent mapping"
combineDeclIndex names decls = map (\(name, label) -> (label, name, lookup name decls)) names

--returns a dictionary with specific implementations for every instance
constructDictionary :: [String] -> [(Name, Int)] -> [(Name, CoreDecl)] -> Name -> String  -> CoreDecl
constructDictionary superClasses combinedNames whereDecls className insName = let 
            
            val = DeclValue 
                { declName    = idFromString ("$dict" ++ getNameName className ++ "$" ++ insName)
                , declAccess  = public
                , valueEnc    = Nothing
                , valueValue  = getFunc
                , declCustoms = [ custom "type" ("Dict" ++ getNameName className ++ "$" ++ insName) ] 
                }
            in val
        where 
            functions = combineDeclIndex combinedNames whereDecls
            idP = idFromString "index"
            getFunc = Lam idP (Match idP makeAlts)
            makeAlts :: Alts
            makeAlts = zipWith makeAltD superClasses [0..] ++ map (\(l, n, mc) -> makeAltF l n mc) functions
            makeAltD :: String -> Int -> Alt
            makeAltD cName label = Alt (PatLit (LitInt label)) (Lam (idFromString "_") $ Var (idFromString ("$dict" ++ cName ++ "$" ++ insName)))
            makeAltF :: Int -> Name -> Maybe CoreDecl -> Alt
            makeAltF label name fdecl = let 
                            undefinedFunc = (Var $ idFromString ("default$" ++ getNameName className ++ "$" ++ getNameName name))
                            func = maybe undefinedFunc getCoreValue fdecl
                            pat = PatLit (LitInt label)
                            in Alt pat func


getCoreName :: CoreDecl -> String 
getCoreName cd = stringFromId $ declName cd

getCoreValue :: CoreDecl -> Expr 
getCoreValue = valueValue

constructClassMemberCustomDecl :: Maybe (Names, [(Name, TpScheme, Bool, HasDefault)]) -> [Custom]
constructClassMemberCustomDecl Nothing =  internalError "InstanceDictionary" "constructClassMemberCustomDecl" "Unknown class" 
constructClassMemberCustomDecl (Just (typevars, members)) = typeVarsDecl : map functionToCustom members
                        where
                            typeVarsDecl :: Custom
                            typeVarsDecl = CustomDecl 
                                (DeclKindCustom $ idFromString "ClassTypeVariables")
                                (map (CustomName . idFromString . getNameName) typevars)
                            functionToCustom :: (Name, TpScheme, Bool, HasDefault) -> Custom
                            functionToCustom (name, tps, _, _) = CustomDecl 
                                (DeclKindCustom $ idFromString "Function") 
                                [
                                    CustomName $ idFromString $ getNameName name, 
                                    CustomBytes $ bytesFromString $ show tps
                                ]

convertDictionaries :: ImportEnvironment -> Name -> [Name] -> [(Name, CoreDecl)] -> [CoreDecl]
convertDictionaries importEnv className functions defaults = map makeFunction functions
            where
                constructName :: Name -> String
                constructName fname = "default$" ++ getNameName className ++ "$" ++ getNameName fname
                makeFunction :: Name -> CoreDecl
                makeFunction fname = 
                    let 
                        updateName :: CoreDecl -> CoreDecl
                        updateName fdecl = fdecl{
                            declName = idFromString $ constructName fname
                        }
                        fDefault :: CoreDecl
                        fDefault = DeclValue
                            { declName    = idFromString $ constructName fname
                            , declAccess  = public 
                            , valueEnc    = Nothing
                            , valueValue  = Var $ idFromString "undefined"
                            , declCustoms = toplevelType fname importEnv True
                            }
                    in maybe fDefault updateName (lookup fname defaults)
                

                            