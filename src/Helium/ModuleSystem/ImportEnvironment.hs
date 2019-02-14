{-# OPTIONS_GHC -fno-warn-orphans #-}
{-| Module      :  ImportEnvironment
    License     :  GPL

    Maintainer  :  helium@cs.uu.nl
    Stability   :  experimental
    Portability :  portable
-}

module Helium.ModuleSystem.ImportEnvironment where

import Helium.Parser.OperatorTable
import Helium.StaticAnalysis.Messages.Messages () -- instance Show Name
import Helium.StaticAnalysis.Heuristics.RepairHeuristics (Siblings)
import Helium.StaticAnalysis.Directives.TS_CoreSyntax
import Helium.Utils.Utils (internalError)
import Helium.Syntax.UHA_Syntax -- (Name)
import Helium.Syntax.UHA_Utils
import Helium.Syntax.UHA_Range
import Helium.StaticAnalysis.Directives.TS_Syntax
import Helium.StaticAnalysis.Miscellaneous.TypeConversion
import Helium.StaticAnalysis.Miscellaneous.ConstraintInfo
import Helium.StaticAnalysis.Messages.Messages
import Top.Types


import Data.List
import Data.Maybe (catMaybes, isJust, fromJust)
import Data.Function (on)
import Data.Char
import Control.Arrow

import qualified Data.Map as M

type HasDefault = Bool

type TypeEnvironment             = M.Map Name TpScheme {- Type scheme-}
type ValueConstructorEnvironment = M.Map Name (Name, TpScheme) {-Parent, Type scheme-}
type TypeConstructorEnvironment  = M.Map Name (Int, Name) {-Arity, Original qualified name -}
type TypeSynonymEnvironment      = M.Map Name (Int, Tps -> Tp) {-Arity, function-}
type ClassMemberEnvironment      = M.Map Name (Names, [(Name, TpScheme, Bool, HasDefault)]) {-Member, original module-}
type InstanceEnvironment         = M.Map (Name, Tp) (Names, [(String, String)])

type ImportEnvironments = [ImportEnvironment]
data ImportEnvironment  =
     ImportEnvironment { -- types
                         typeConstructors  :: TypeConstructorEnvironment
                       , typeSynonyms      :: TypeSynonymEnvironment
                       , typeEnvironment   :: TypeEnvironment
                         -- values
                       , valueConstructors :: ValueConstructorEnvironment
                       , operatorTable     :: OperatorTable
                         -- type classes
                       , classEnvironment  :: ClassEnvironment
                       , classMemberEnvironment :: ClassMemberEnvironment
                         -- other
                       , instanceEnvironment :: InstanceEnvironment

                       , typingStrategies  :: Core_TypingStrategies
                       }

emptyEnvironment :: ImportEnvironment
emptyEnvironment = ImportEnvironment
   { typeConstructors  = M.empty
   , typeSynonyms      = M.empty
   , typeEnvironment   = M.empty
   , valueConstructors = M.empty
   , operatorTable     = M.empty
   , classEnvironment  = emptyClassEnvironment
   , classMemberEnvironment = M.empty
   , instanceEnvironment = M.empty
   , typingStrategies  = []
   }

addTypeConstructor :: Name -> Int -> ImportEnvironment -> ImportEnvironment
addTypeConstructor name int importenv =
   importenv {typeConstructors = M.insert name int (typeConstructors importenv)}

-- add a type synonym also to the type constructor environment
addTypeSynonym :: Name -> (Int,Tps -> Tp) -> ImportEnvironment -> ImportEnvironment
addTypeSynonym name (arity, function) importenv =
   importenv { typeSynonyms     = M.insert name (arity, function) (typeSynonyms importenv)
             , typeConstructors = M.insert name arity (typeConstructors importenv)
             }

addType :: Name -> TpScheme -> ImportEnvironment -> ImportEnvironment
addType name tpscheme importenv =
   importenv {typeEnvironment = M.insert name tpscheme (typeEnvironment importenv)}

addToTypeEnvironment :: TypeEnvironment -> ImportEnvironment -> ImportEnvironment
addToTypeEnvironment new importenv =
   importenv {typeEnvironment = typeEnvironment importenv `M.union` new} 
   
addValueConstructor :: Name -> TpScheme -> Name -> ImportEnvironment -> ImportEnvironment
addValueConstructor name tpscheme parent importenv = 
   importenv {valueConstructors = M.insert name (parent, tpscheme) (valueConstructors importenv)}

addOperator :: Name -> (Int,Assoc) -> ImportEnvironment -> ImportEnvironment  
addOperator name pair importenv = 
   importenv {operatorTable = M.insert name pair (operatorTable importenv) } 
   
setValueConstructors :: M.Map Name (Name, TpScheme) -> ImportEnvironment -> ImportEnvironment  
setValueConstructors new importenv = importenv {valueConstructors = new} 

setTypeConstructors :: M.Map Name (Int, Name) -> ImportEnvironment -> ImportEnvironment     
setTypeConstructors new importenv = importenv {typeConstructors = new}

setTypeSynonyms :: M.Map Name (Int,Tps -> Tp) -> ImportEnvironment -> ImportEnvironment
setTypeSynonyms new importenv = importenv {typeSynonyms = new}

setTypeEnvironment :: M.Map Name TpScheme -> ImportEnvironment -> ImportEnvironment
setTypeEnvironment new importenv = importenv {typeEnvironment = new}

setOperatorTable :: OperatorTable -> ImportEnvironment -> ImportEnvironment
setOperatorTable new importenv = importenv {operatorTable = new}

getOrderedTypeSynonyms :: ImportEnvironment -> OrderedTypeSynonyms
getOrderedTypeSynonyms importEnvironment =
   let synonyms = let insertIt name = M.insert (show name)
                  in M.foldrWithKey insertIt M.empty (typeSynonyms importEnvironment)
       ordering = fst (getTypeSynonymOrdering synonyms)
   in (ordering, synonyms)

setClassMemberEnvironment :: ClassMemberEnvironment -> ImportEnvironment -> ImportEnvironment
setClassMemberEnvironment new importenv = importenv { classMemberEnvironment = new }

addClassMember :: Name -> (Names, [(Name, TpScheme, Bool, HasDefault)]) -> ImportEnvironment -> ImportEnvironment
addClassMember name members env = 
    let 
        envMember =  setClassMemberEnvironment (M.insert name members (classMemberEnvironment env)) env
        classEnv = classEnvironment envMember
        classEntry =    if M.member (getNameName name) (classEnvironment envMember) then
                            M.insert (getNameName name) ([], []) (classEnvironment envMember)
                        else
                            classEnvironment envMember -- update existing member with superclasses
        envClass = setClassEnvironment classEntry envMember
    in envClass
    

addClassInstance :: String -> String -> ImportEnvironment -> ImportEnvironment
addClassInstance className instanceName env =  
    let
        instancePreds :: (Predicate, Predicates)
        instancePreds = (Predicate className instanceVar, [])
        instanceVar :: Tp
        instanceVar | isUpper (head instanceName) = TCon instanceName
                    | otherwise = TVar 0
        classEnv = classEnvironment env
        nClassEnv   | className `M.member` classEnv = M.update (Just . second (instancePreds:)) className classEnv
                    | otherwise = M.insert className ([], [instancePreds]) classEnv
    in setClassEnvironment (nClassEnv) env

setClassEnvironment :: ClassEnvironment -> ImportEnvironment -> ImportEnvironment
setClassEnvironment new importenv = importenv { classEnvironment = new }

setInstanceEnvironment :: InstanceEnvironment -> ImportEnvironment -> ImportEnvironment
setInstanceEnvironment new importenv = importenv { instanceEnvironment = new }

addTypingStrategies :: Core_TypingStrategies -> ImportEnvironment -> ImportEnvironment
addTypingStrategies new importenv = importenv {typingStrategies = new ++ typingStrategies importenv}

removeTypingStrategies :: ImportEnvironment -> ImportEnvironment
removeTypingStrategies importenv = importenv {typingStrategies = []}

getSiblingGroups :: ImportEnvironment -> [[String]]
getSiblingGroups importenv =
   [ xs | Siblings xs <- typingStrategies importenv ]

getSiblings :: ImportEnvironment -> Siblings
getSiblings importenv =
   let f s = [ (s, ts) | ts <- findTpScheme (nameFromString s) ]
       findTpScheme n = 
          catMaybes [ valueConsTpScheme n
                    , M.lookup n (typeEnvironment   importenv)
                    ]
   in map (concatMap f) (getSiblingGroups importenv)
   where
    valueConsTpScheme n =
        let res = M.lookup n (valueConstructors importenv)
        in maybe Nothing (\(_, scheme) -> Just scheme) res

getNeverDirectives :: ImportEnvironment -> [(Predicate, ConstraintInfo)]
getNeverDirectives importEnv = let
    tps = typingStrategies importEnv
    convertNever :: Core_TypingStrategy -> [(Predicate, ConstraintInfo)]
    convertNever (Never predicateName predicateType message) = let
            predicate = Predicate predicateName predicateType
            info = addProperty (CustomError message) standardConstraintInfo
        in [(predicate, info)]
    convertNever _ = []
    in concatMap convertNever tps

getCloseDirectives :: ImportEnvironment -> [(String, ConstraintInfo)]
getCloseDirectives importEnv = let
    tps = typingStrategies importEnv
    convertClose :: Core_TypingStrategy -> [(String, ConstraintInfo)]
    convertClose (Close name message) = let
            info = addProperty (CustomError message) standardConstraintInfo
        in [(name, info)]
    convertClose _ = []
    in concatMap convertClose tps 

getDisjointDirectives :: ImportEnvironment -> [([String], ConstraintInfo)]
getDisjointDirectives importEnv = let
    tps = typingStrategies importEnv
    convertDisjoint :: Core_TypingStrategy -> [([String], ConstraintInfo)]
    convertDisjoint (Disjoint ns message) = let
            info = addProperty (CustomError message) standardConstraintInfo
        in [(ns, info)]
    convertDisjoint _ = []
    in concatMap convertDisjoint tps 

getDefaultDirectives :: ImportEnvironment -> [((String, Tps), ConstraintInfo)]
getDefaultDirectives importEnv = let
    tps = typingStrategies importEnv
    convertDefault :: Core_TypingStrategy -> [((String, Tps), ConstraintInfo)]
    convertDefault (Default n tps) = let
            info = standardConstraintInfo
        in [((n, tps), info)]
    convertDefault _ = []
    in concatMap convertDefault tps

-- The Value Constuctors are unioned normally (takes left if same). Because it is allowed to create a value constructor, that is also imported. As long as it is not used.
-- But when you do this, it does need to check the type, when declared. Thus the normal union. We assume that the original module is always used as first argument.
combineImportEnvironments :: ImportEnvironment -> ImportEnvironment -> ImportEnvironment
combineImportEnvironments (ImportEnvironment tcs1 tss1 te1 vcs1 ot1 ce1 cm1 ins1 xs1) (ImportEnvironment tcs2 tss2 te2 vcs2 ot2 ce2 cm2 ins2 xs2) =
    insertMissingInstances $ ImportEnvironment
      (tcs1 `exclusiveUnion` tcs2)
      (tss1 `exclusiveUnion` tss2)
      (te1  `exclusiveUnion` te2 )
      (vcs1 `exclusiveUnion` vcs2)
      (ot1  `exclusiveUnion` ot2)
      (M.unionWith combineClassDecls ce1 ce2)
      (cm1 `exclusiveUnion` cm2)
      (ins1 `exclusiveUnion` ins2)
      (xs1 ++ xs2)

insertMissingInstances :: ImportEnvironment -> ImportEnvironment
insertMissingInstances env = setClassEnvironment nClassEnv env
    where
        classEnv = classEnvironment env
        nClassEnv = foldr addMissingInstance classEnv (M.toList $ instanceEnvironment env)
        addMissingInstance :: ((Name, Tp), (Names, [(String, String)])) -> ClassEnvironment -> ClassEnvironment
        addMissingInstance ((className, instanceType), (typeVariables, superClasses)) env = let
                update :: ([String], Instances) -> ([String], Instances)
                update (supers, instances) = let
                        predicate = Predicate (getNameName className) instanceType
                        existingInstance = find (\(p, _) -> p == predicate) instances
                        getTypeVariables :: Tp -> [Tp]
                        getTypeVariables v@(TVar _) = [v]
                        getTypeVariables (TApp t1 t2) = getTypeVariables t1 ++ getTypeVariables t2
                        getTypeVariables _ = []
                        mapping = zip (map getNameName typeVariables) $ getTypeVariables instanceType 
                        pSuperClasses = map (\(c, n) -> Predicate c (fromJust $ lookup n mapping)) superClasses
                        nInstance = (predicate, pSuperClasses)
                        nInstances = 
                            if isJust existingInstance then
                                instances
                            else 
                                nInstance : instances
                    in (supers, nInstances)
            in M.adjust update (getNameName className) env

-- IMPORTANT: the local environment should ALWAYS be the head of the list. Otherwise errors with same named value constructors WILL occur.
combineImportEnvironmentList :: ImportEnvironments -> ImportEnvironment
combineImportEnvironmentList = foldr combineImportEnvironments emptyEnvironment

exclusiveUnion :: Ord key => M.Map key a -> M.Map key a -> M.Map key a
exclusiveUnion m1 m2 =
   let keys = M.keys (M.intersection m1 m2)
       f m  = foldr (M.update (const Nothing)) m keys
   in f m1 `M.union` f m2

containsClass :: ClassEnvironment -> Name -> Bool
containsClass cEnv n = M.member (getNameName n) cEnv
{-
-- Bastiaan:
-- For the moment, this function combines class-environments.
-- The only instances that are added to the standard instances
-- are the derived Show instances (Show has no superclasses).
-- If other instances are added too, then the class environment
-- should be split into a class declaration environment, and an
-- instance environment.-}
combineClassDecls :: ([[Char]],[(Predicate,[Predicate])]) ->
                     ([[Char]],[(Predicate,[Predicate])]) ->
                     ([[Char]],[(Predicate,[Predicate])])
combineClassDecls (super1, inst1) (super2, inst2)
   | super1 == super2 = (super1, nub $ inst1 ++ inst2)
   | otherwise        = internalError "ImportEnvironment.hs" "combineClassDecls" "cannot combine class environments"

-- Bastiaan:
-- Create a class environment from the dictionaries in the import environment
createClassEnvironment :: ImportEnvironment -> ClassEnvironment
createClassEnvironment importenv = 
    let  dicts = map (drop (length dictPrefix) . show) 
               . M.keys 
               . M.filterWithKey isDict 
               $ typeEnvironment importenv
         isDict n _ = dictPrefix `isPrefixOf` show n
         dictPrefix = "$dict"
         -- classes = ["Eq","Num","Ord","Enum","Show"]
         -- TODO: put $ between class name and type in dictionary name
         --  i.e. $dictEq$Int instead of $dictEqInt
         splitDictName ('E':'q':t) = ("Eq", t)
         splitDictName ('N':'u':'m':t) = ("Num", t)
         splitDictName ('O':'r':'d':t) = ("Ord", t)
         splitDictName ('E':'n':'u':'m':t) = ("Enum", t)
         splitDictName ('S':'h':'o':'w':t) = ("Show", t)
         splitDictName x = internalError "ImportEnvironment" "splitDictName" ("illegal dictionary: " ++ show x)
         arity s | s == "()" = 0
                 | isTupleConstructor s = length s - 1
                 | otherwise = fst $ M.findWithDefault
                                  (internalError "ImportEnvironment" "splitDictName" ("unknown type constructor: " ++ show s))                            
                                  (nameFromString s)
                                  (typeConstructors importenv)
         getQualName s | s == "()" = s
                       | isTupleConstructor s = s
                       | isListConstructor s = s
                       | otherwise = getNameName . snd $ M.findWithDefault
                           (internalError "ImportEnvironment" "splitDictName" ("unknown type constructor: " ++ show s))
                           (nameFromString s)
                           (typeConstructors importenv)
         dictTuples = [ (c, makeInstance c (arity t) (getQualName t) ) 
                      | d <- dicts, let (c, t) = splitDictName d 
                      ]
         isListConstructor "[]" = True
         isListConstructor _    = False
         
         classEnv = foldr 
                    (\(className, inst) e -> insertInstance className inst e) 
                    superClassRelation 
                    dictTuples
    in classEnv

superClassRelation :: ClassEnvironment
superClassRelation = M.fromList
   [ ("Num",  ( ["Eq","Show"],   []))
   , ("Enum", ( [],              []))
   , ("Eq" ,  ( [],              []))
   , ("Ord",  ( ["Eq"],          []))
   , ("Show", ( [],              []))
   ]

getInstanceNames :: [ImportEnvironment] -> [(Range, Instance)]
getInstanceNames c = concatMap (map (\x -> (noRange, x)) . snd . snd) $  M.toList $ classEnvironment (combineImportEnvironmentList c)

makeInstance :: String -> Int -> String -> Bool -> Instance
makeInstance className nrOfArgs tp isDict =
   let tps = take nrOfArgs [ TVar i | i <- [0..] ] 
   in ( Predicate className (foldl TApp (TCon tp) tps)
      , [ Predicate className x | x <- tps, isDict ]
      )

-- added for holmes
holmesShowImpEnv :: Module -> ImportEnvironment -> String
holmesShowImpEnv module_ (ImportEnvironment _ _ te _ _ _ _ _ _) =
      concat functions
    where
       localName = getModuleName module_
       functions =
          let (xs, ys) = partition (isIdentifierName . fst) (M.assocs te)
              list     = map (\(n,_) -> getHolmesName localName n) (ys++xs)
          in map (++ ";") list

instance Show ImportEnvironment where
   show (ImportEnvironment tcs tss te vcs ot ce cm ins _) =
      unlines (concat [ fixities
                      , datatypes
                      , typesynonyms
                      , theValueConstructors
                      , functions
                      , classes
                      , classmembers
                      , sinstances
                      ])
    where
       fixities =
          let sorted  = let cmp (name, (priority, associativity)) = (10 - priority, associativity, not (isOperatorName name), name)
                        in sortBy (compare `on` cmp) (M.assocs ot)
              grouped = groupBy ((==) `on` snd) sorted
              list = let f ((name, (priority, associativity)) : rest) =
                            let names  = name : map fst rest
                                prefix = (case associativity of
                                             AssocRight -> "infixr"
                                             AssocLeft  -> "infixl"
                                             AssocNone  -> "infix "
                                         )++" "++ show priority ++ " "
                            in prefix ++ foldr1 (\x y -> x++", "++y) (map showNameAsOperator names)
                         f [] = error "Pattern match failure in ModuleSystem.ImportEnvironment"
                     in map f grouped
          in showWithTitle "Fixity declarations" list

       datatypes =
          let allDatas = filter ((`notElem` M.keys tss). fst) (M.assocs tcs)
              f (n,(i,_))  = unwords ("data" : showNameAsVariable n : take i variableList)
          in showWithTitle "Data types" (showEm f allDatas)

       typesynonyms =
          let f (n,(i,g)) = let tcons =  take i (map TCon variableList)
                            in unwords ("type" : showNameAsVariable n : map show tcons ++ ["=", show (g tcons)])
          in showWithTitle "Type synonyms" (showEm f (M.assocs tss))

       theValueConstructors =
          let f (n,t) = showNameAsVariable n ++ " :: "++show t
          in showWithTitle "Value constructors" (showEm f (M.assocs vcs))

       functions =
          let f (n,t) = showNameAsVariable n ++ " :: "++show t
          in showWithTitle "Functions" (showEm f (M.assocs te))

       classes =
          let f (n, s) = n ++ show s
          in showWithTitle "Classes" (map f (M.assocs ce))

       classmembers =
          let f (c, (tv, fs)) = show c ++ " " ++ show tv ++ " - " ++ intercalate ", " (map (\(n, t, _, b)->show n ++ " :: " ++ show t ++ if b then " has default" else "") fs)
          in showWithTitle "Class members" (showEm f (map (\(c, m)->(c, m)) $ M.assocs cm))

       sinstances =
           let
                f ((className, instanceType),(variables, predicates)) = show className ++ " " ++ show instanceType ++ " - " ++ show variables ++ " <= " ++ show predicates
           in showWithTitle "Instances" (map (f) (M.assocs ins))

       showWithTitle title xs
          | null xs   = []
          | otherwise = (title++":") : map ("   "++) xs

       showEm showf aMap = map showf (part2 ++ part1)
         where
            (part1, part2) = partition (isIdentifierName . fst) aMap

instance Ord Assoc where
  x <= y = let f :: Assoc -> Int
               f AssocLeft  = 0
               f AssocRight = 1
               f AssocNone  = 2
           in f x <= f y
