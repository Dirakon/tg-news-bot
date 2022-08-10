module Evaluate where

import Prelude
import Types
import Data.Array (catMaybes, concat, cons, length, zip)
import Data.Array.NonEmpty (NonEmptyArray, fromArray, uncons)
import Data.Either (Either(..))
import Data.Lazy (Lazy)
import Data.List (filter)
import Data.Map (Map, empty, lookup, singleton, unionWith)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Traversable (sequence, traverse)
import Data.Tuple (Tuple(..))
import Data.Tuple.Nested (tuple2)
import Data.Validation.Semigroup (V(..), invalid)
import Prim.Boolean (False, True)

evaluate :: BotState -> V Errors NonDeterministicEvaluatedExpression
-- TODO: hugely optimize by choosing just one main branch
evaluate state = executeMacro state "Main"

executeMacro :: BotState -> MacroName -> V Errors NonDeterministicEvaluatedExpression
executeMacro state macroName = case lookup macroName state.macros of
  Nothing -> invalid [ "Called macro cannot be found: " <> macroName ]
  Just expression -> do
    -- TODO
    let
      evaluatedExpression = tryEvaluateExpression state.variables state.macros expression
    pure $ []

tryEvaluateExpressionForAllVariables :: NonDeterministicVariableList -> MacroList -> Expression -> NonDeterministicEvaluatedExpression
tryEvaluateExpressionForAllVariables varDeclarations macros expression =
  concat $ catMaybes
    $ do
        deterministicVariableList <- allDeterministicLists varDeclarations
        pure $ tryEvaluateExpression deterministicVariableList macros expression
  where
  allDeterministicLists :: Array NonDeterministicVariableDeclaration -> Array DeterministicVariableDeclaration
  allDeterministicLists varDecs = case fromArray varDecs of
    Nothing -> []
    Just nonEmptyArray -> do
      let
        { head, tail } = uncons nonEmptyArray
      case fromArray tail of
        Nothing -> do
          someFirst <- head
          pure $ someFirst
        Just nonEmptyTail -> do
          someFirst <- head
          someOthers <- allDeterministicLists tail
          pure $ unionWith (\obj1 obj2 -> obj1) someFirst someOthers

-- | Try evaluatation: if variables are not defined, return Nothing
tryEvaluateExpression :: DeterministicVariableDeclaration -> MacroList -> Expression -> Maybe NonDeterministicEvaluatedExpression
tryEvaluateExpression vars macros (Expression exprType _) = case exprType of
  Literal lit -> Just $ [ LeafExpression lit ]
  OneOf expr1 expr2 -> recursiveCall expr1 <> recursiveCall expr2
  -- TODO: lift errors from consolidation to the function signature (V Errors (Maybe EvaluatedExpression)?)
  ConsolidationOf expr1 expr2 -> case sideEffectedConsolidation of
    (Just (V (Right res))) -> Just res
    _ -> Nothing
    where
    sideEffectedConsolidation :: Maybe (V Errors NonDeterministicEvaluatedExpression)
    sideEffectedConsolidation = ado
      evaledExpr1 <- recursiveCall expr1
      evaledExpr2 <- recursiveCall expr2
      in sequence
        $ do
            tuple1 <- evaledExpr1
            tuple2 <- evaledExpr2
            pure $ consolidateEvaluatedExpressions tuple1 tuple2
  TupleOf expressions -> ado
    -- evaluatedExpressions :: Array NonDeterministicEvaluatedExpression  
    evaluatedExpressions <- sequence $ map recursiveCall expressions
    in takeAllCombinations evaluatedExpressions
    where
    -- | [[a,b,c],[d,e,f]] -> [ad,ae,af,bd,be,bf,cd,ce,cf]
    takeAllCombinations :: Array (NonDeterministicEvaluatedExpression) -> NonDeterministicEvaluatedExpression
    takeAllCombinations arr = case fromArray arr of
      Nothing -> []
      Just nonEmptyArray -> do
        let
          { head, tail } = uncons nonEmptyArray
        case fromArray tail of
          Nothing -> do
            someFirst <- head
            pure someFirst
          Just nonEmptyTail -> do
            someFirst <- head
            someOthers <- takeAllCombinations tail
            pure $ TreeExpression (evaluatedExpressionToArray someFirst <> evaluatedExpressionToArray someOthers)
  MacroCall name -> case lookup name macros of
    Nothing -> Nothing
    Just macroExpression -> recursiveCall macroExpression
  VariableCall name -> case lookup name vars of
    Nothing -> Nothing
    Just varExpression -> Just [ varExpression ]
  where
  recursiveCall = tryEvaluateExpression vars macros

variableDefined :: VariableName -> BotState -> Boolean
variableDefined varName state = case lookup varName state.variables of
  Nothing -> false
  Just _ -> true

-- TODO: For OneOf: parallelize and combine 
consolidateEvaluatedExpressions :: DeterministicEvaluatedExpression -> DeterministicEvaluatedExpression -> V Errors DeterministicEvaluatedExpression
consolidateEvaluatedExpressions (TreeExpression tuple1) (TreeExpression tuple2)
  | length tuple1 /= length tuple2 = invalid [ "cannot consolidate tuples of different lengths" ]
  | otherwise = ado
    combinedTuple <- sequence $ map combine (zip tuple1 tuple2)
    in TreeExpression combinedTuple
    where
    combine :: Tuple DeterministicEvaluatedExpression DeterministicEvaluatedExpression -> V Errors DeterministicEvaluatedExpression
    combine (Tuple el1 el2) = consolidateEvaluatedExpressions el1 el2

consolidateEvaluatedExpressions (LeafExpression val1) (LeafExpression val2) = pure $ LeafExpression (val1 <> val2)

consolidateEvaluatedExpressions expr1 expr2 = consolidateEvaluatedExpressions expr1' expr2'
  where
  expr1' = (TreeExpression (evaluatedExpressionToArray expr1))

  expr2' = (TreeExpression (evaluatedExpressionToArray expr2))

unifyVariableDeclarations :: NonDeterministicVariableDeclaration -> NonDeterministicVariableDeclaration -> NonDeterministicVariableDeclaration
unifyVariableDeclarations deterministicDecs1 deterministicDecs2 = unifiedDecs
  where
  unifiedDecs = do
    values1 <- deterministicDecs1
    values2 <- deterministicDecs2
    pure $ unionWith (\obj1 obj2 -> obj1) values1 values2
