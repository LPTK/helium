-- | Module      :  PhaseTypeInferencer
--    License     :  GPL
--
--    Maintainer  :  helium@cs.uu.nl
--    Stability   :  experimental
--    Portability :  portable
module Helium.Main.PhaseTypeInferencer
  ( phaseTypeInferencer,
  )
where

import qualified Data.Map as M
import Helium.Main.Args
import Helium.Main.CompileUtils
import Helium.ModuleSystem.DictionaryEnvironment (DictionaryEnvironment)
import Helium.StaticAnalysis.Inferencers.TypeInferencing (typeInferencing)
--import UHA_Syntax

import Helium.StaticAnalysis.Messages.Information (showInformation)
import Helium.StaticAnalysis.Messages.TypeErrors
import Helium.StaticAnalysis.Messages.Warnings (Warning)
import Helium.StaticAnalysis.Miscellaneous.ConstraintInfo (ConstraintInfo)
import Helium.Syntax.UHA_Utils (NameWithRange)
import System.FilePath.Posix
import Top.Solver (SolveResult)
import Top.Types (TpScheme)

phaseTypeInferencer ::
  String ->
  String ->
  Module ->
  ImportEnvironment ->
  ImportEnvironment ->
  [Option] ->
  Phase TypeError (DictionaryEnvironment, ImportEnvironment, TypeEnvironment, M.Map NameWithRange TpScheme, SolveResult ConstraintInfo, [Warning])
phaseTypeInferencer basedir fullName module_ localEnv completeEnv options = do
  enterNewPhase "Type inferencing" options
  -- 'W' and 'M' are predefined type inference algorithms
  let newOptions =
        ( if AlgorithmW `elem` options
            then filter (/= NoSpreading) . ([TreeWalkInorderTopLastPost, SolverGreedy] ++)
            else id
        )
          . ( if AlgorithmM `elem` options
                then filter (/= NoSpreading) . ([TreeWalkInorderTopFirstPre, SolverGreedy] ++)
                else id
            )
          $ options
      (debugIO, dictionaryEnv, toplevelTypes, allTypeSchemes, solveResult, typeErrors, warnings) =
        typeInferencing newOptions completeEnv module_
      -- add the top-level types (including the inferred types)
      finalEnv = addToTypeEnvironment toplevelTypes completeEnv
  when (containsDOption Type `any` options) debugIO
  -- display name information
  showInformation True options finalEnv
  case typeErrors of
    _ : _ ->
      do
        when (DumpInformationForAllModules `elem` options) $
          putStr (show completeEnv)
        return (Left typeErrors)
    [] ->
      do
        -- Dump information
        when (DumpInformationForAllModules `elem` options) $
          print finalEnv
        when (HFullQualification `elem` options) $
          writeFile
            (combinePathAndFile basedir (dropExtension $ takeFileName fullName) ++ ".fqn")
            (holmesShowImpEnv module_ finalEnv)
        when
          ( DumpInformationForThisModule `elem` options
              && DumpInformationForAllModules `notElem` options
          )
          $ print (addToTypeEnvironment toplevelTypes localEnv)
        return (Right (dictionaryEnv, finalEnv, toplevelTypes, allTypeSchemes, solveResult, warnings))
