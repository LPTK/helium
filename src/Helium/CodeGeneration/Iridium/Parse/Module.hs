module Helium.CodeGeneration.Iridium.Parse.Module (parseModule, parseModuleIO, parseFunctionType) where

import Lvm.Common.Id(Id)
import Helium.CodeGeneration.Iridium.Parse.Parser
import Helium.CodeGeneration.Iridium.Parse.Type
import Helium.CodeGeneration.Iridium.Parse.Custom
import Helium.CodeGeneration.Iridium.Parse.Instruction
import Helium.CodeGeneration.Iridium.Parse.Method
import Helium.CodeGeneration.Iridium.Data
import Helium.CodeGeneration.Iridium.Type
import System.Exit

pCustomDeclaration :: Parser CustomDeclaration
pCustomDeclaration = CustomDeclaration <$ pToken ':' <* pWhitespace <*> pDeclKind

pDataTypeConstructorDeclaration :: Parser (Declaration DataTypeConstructorDeclaration)
pDataTypeConstructorDeclaration = pDeclaration f
  where
    f "constructor" decl = (decl . DataTypeConstructorDeclaration) <$> pArguments pType
    f _ _ = pError "expected constructor declaration"

pDataType :: Parser DataType
pDataType = do
  pWhitespace
  pToken '{'
  pWhitespace
  c <- lookahead
  if c == '}' then do
    pChar
    return $ DataType []
  else
    DataType <$> pSome pDataTypeConstructorDeclaration pSep
  where
    pSep :: Parser Bool
    pSep = do
      pWhitespace
      c <- lookahead
      if c == '}' then do
        pChar
        return False
      else
        return True

pTypeSynonym :: Parser TypeSynonym
pTypeSynonym = do
  pWhitespace
  pToken '='
  pWhitespace
  pToken '{'
  pWhitespace
  tp <- pCoreType
  pToken '}'
  return $ TypeSynonym tp

pDeclaration :: (String -> (forall a . a -> Declaration a) -> Parser b) -> Parser b
pDeclaration f = do
  customs <- pCustoms
  (vis, mod, key) <- pDeclarationVisibilityOriginAndKeyword
  pToken '@'
  name <- pId
  f key (Declaration name vis mod customs)

pDeclarationVisibilityOriginAndKeyword :: Parser (Visibility, Maybe Id, String)
pDeclarationVisibilityOriginAndKeyword = do
  key <- pKeyword
  if key == "export_as" then do
    pToken '@'
    exportedName <- pId
    pWhitespace
    key' <- pKeyword
    pOriginAndKeyword (ExportedAs exportedName) key'
  else
    pOriginAndKeyword Private key
  where
    pOriginAndKeyword :: Visibility -> String -> Parser (Visibility, Maybe Id, String)
    pOriginAndKeyword vis "from" = do
      mod <- pId
      pWhitespace
      key <- pKeyword
      return (vis, Just mod, key)
    pOriginAndKeyword vis key = return (vis, Nothing, key)

pModule :: Parser Module
pModule = do
  pSymbol "module"
  pWhitespace
  name <- pId
  pWhitespace
  pSymbol "import"
  pWhitespace
  dependencies <- pArguments pId
  pWhitespace
  let emptyModule = Module name dependencies [] [] [] [] []
  decls <- pSome pModuleDeclaration (not <$ pWhitespace <*> isEndOfFile)
  return $ foldr (\f m -> f m) emptyModule decls

pModuleDeclaration :: Parser (Module -> Module)
pModuleDeclaration = pDeclaration f
  where
    f :: String -> (forall a . a -> Declaration a) -> Parser (Module -> Module)
    f "custom" decl = addCustom . decl <$> pCustomDeclaration
    f "data" decl = addDataType . decl <$> pDataType
    f "type" decl = addTypeSynonym . decl <$> pTypeSynonym
    f "declare" decl = addAbstract . decl <$> pAbstractMethod
    f "define" decl = addMethod . decl <$> pMethod
    f keyword _ = pError $ "Unknown declaration keyword: " ++ keyword

parseModule :: String -> Either ParseError Module
parseModule = parse pModule

parseModuleIO :: FilePath -> String -> IO Module
parseModuleIO fullName contents =
  case parseModule contents of
    Left err -> do
      putStrLn $ "Failed to parse Iridium file " ++ show fullName
      print err
      exitWith (ExitFailure 1)
    Right ir -> return ir

parseFunctionType :: String -> Either ParseError FunctionType
parseFunctionType = parse pFunctionType

addCustom :: Declaration CustomDeclaration -> Module -> Module
addCustom c m = m{ moduleCustoms = c : moduleCustoms m }

addDataType :: Declaration DataType -> Module -> Module
addDataType d m = m{ moduleDataTypes = d : moduleDataTypes m }

addAbstract :: Declaration AbstractMethod -> Module -> Module
addAbstract a m = m{ moduleAbstractMethods = a : moduleAbstractMethods m }

addMethod :: Declaration Method -> Module -> Module
addMethod f m = m{ moduleMethods = f : moduleMethods m }

addTypeSynonym :: Declaration TypeSynonym -> Module -> Module
addTypeSynonym ts m = m { moduleTypeSynonyms = ts : moduleTypeSynonyms m }