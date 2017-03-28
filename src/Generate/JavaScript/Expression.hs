{-# LANGUAGE OverloadedStrings #-}
module Generate.JavaScript.Expression
  ( generateDecl
  )
  where

import Control.Arrow (second)
import Control.Monad.State (State, foldM)
import qualified Data.List as List
import qualified Data.Map as Map
import Data.Monoid ((<>))
import qualified Data.Text as Text
import Data.Text (Text)

import qualified AST.Expression.Canonical as Can
import AST.Expression.Optimized as Opt
import qualified AST.Literal as L
import qualified AST.Module.Name as ModuleName
import qualified AST.Variable as V
import Generate.JavaScript.Helpers as Help
import qualified Generate.JavaScript.Builder as JS
import qualified Generate.JavaScript.BuiltIn as BuiltIn
import qualified Generate.JavaScript.Foreign as Foreign
import qualified Generate.JavaScript.Literal as Literal
import qualified Generate.JavaScript.Variable as Var
import qualified Optimize.DecisionTree as DT



-- GENERATE DECLARATION


generateDecl :: ModuleName.Canonical -> Text -> Opt.Def -> State Int [JS.Stmt]
generateDecl home name def =
  Var.defineGlobal home name <$> generateDef name def



-- CODE CHUNKS


data Code
    = JsExpr JS.Expr
    | JsBlock [JS.Stmt]


jsExpr :: JS.Expr -> State Int Code
jsExpr exp =
  return (JsExpr exp)


jsBlock :: [JS.Stmt] -> State Int Code
jsBlock exp =
  return (JsBlock exp)


isBlock :: Code -> Bool
isBlock code =
  case code of
    JsBlock _ -> True
    JsExpr _ -> False


toStatementList :: Code -> [JS.Stmt]
toStatementList code =
  case code of
    JsExpr expr ->
        [ JS.Return (Just expr) ]

    JsBlock stmts ->
        stmts


toStatement :: Code -> JS.Stmt
toStatement code =
  case code of
    JsExpr expr ->
        JS.Return (Just expr)

    JsBlock [stmt] ->
        stmt

    JsBlock stmts ->
        JS.Block stmts


toExpr :: Code -> JS.Expr
toExpr code =
  case code of
    JsExpr expr ->
      expr

    JsBlock stmts ->
      JS.Call (function [] stmts) []



-- EXPRESSIONS


generateJsExpr :: Opt.Expr -> State Int JS.Expr
generateJsExpr optExpr =
  toExpr <$> generateCode optExpr


generateCode :: Opt.Expr -> State Int Code
generateCode expr =
    case expr of
      VarLocal name ->
          jsExpr $ Var.local name

      VarGlobal home name ->
          jsExpr $ Var.global home name

      Literal lit ->
          jsExpr (Literal.literal lit)

      Access record field ->
          do  jsRecord <- generateJsExpr record
              jsExpr $ JS.DotRef jsRecord (JS.Id (Var.safe field))

      Update record fields ->
          let
            fieldToJs (field, value) =
              do  jsValue <- generateJsExpr value
                  return (Var.safe field, jsValue)
          in
            do  jsRecord <- generateJsExpr record
                jsFields <- mapM fieldToJs fields
                jsExpr $ BuiltIn.recordUpdate jsRecord jsFields

      Record fields ->
          let
            toField (field, value) =
              do  jsValue <- generateJsExpr value
                  return (Var.safe field ==> jsValue)
          in
            do  jsFields <- mapM toField fields
                jsExpr $ JS.Object jsFields

      Binop home op leftExpr rightExpr ->
          generateBinop home op leftExpr rightExpr

      Function args body ->
          generateFunction args body

      Call func args ->
          generateCall func args

      TailCall name argNames args ->
          let
            reassign name tempName =
              JS.ExprStmt $
                JS.Assign (JS.LVar (Var.safe name)) (ref tempName)
          in
            do  args' <- mapM generateJsExpr args
                tempNames <- mapM (\_ -> Var.fresh) args
                jsBlock $
                  JS.VarDeclStmt (zipWith varDecl tempNames args')
                  : zipWith reassign argNames tempNames
                  ++ [JS.Continue (Just (JS.Id (Var.safe name)))]

      Let defs body ->
          do  stmts <- mapM generateLetDef defs
              code <- generateCode body
              jsBlock (stmts ++ toStatementList code)

      If branches finally ->
          generateIf branches finally

      Case exprName decider jumps ->
          JsBlock <$> generateCase exprName decider jumps

      List elements ->
          do  jsElements <- mapM generateJsExpr elements
              jsExpr $ BuiltIn.list jsElements

      Ctor tag members ->
        let
          ctor =
            "ctor" ==> JS.String tag

          toEntry entry n =
            ("_" <> Text.pack (show n)) ==> entry
        in
          do  jsMembers <- mapM generateJsExpr members
              jsExpr $ JS.Object (ctor : zipWith toEntry jsMembers [ 0 :: Int .. ])

      CtorAccess dataExpr index ->
          do  jsDataExpr <- generateJsExpr dataExpr
              jsExpr $ JS.DotRef jsDataExpr (JS.Id ("_" <> Text.pack (show index)))

      Cmd moduleName _ ->
          jsExpr $ BuiltIn.effect moduleName

      Sub moduleName _ ->
          jsExpr $ BuiltIn.effect moduleName

      OutgoingPort name tipe ->
          jsExpr $ BuiltIn.outgoingPort name (Foreign.encode tipe)

      IncomingPort name tipe ->
          do  jsDecoder <- generateJsExpr (Foreign.decode tipe)
              jsExpr $ BuiltIn.incomingPort name jsDecoder

      Program kind body ->
          generateProgram kind body

      GLShader src ->
          jsExpr $ JS.Object [(JS.StringProp "src", Literal.literal (L.Str src))]

      Crash home region maybeBranchProblem ->
          do  maybeOptBranchProblem <- traverse generateJsExpr maybeBranchProblem
              jsExpr $ BuiltIn.crash home region maybeOptBranchProblem



-- PROGRAMS


generateProgram :: Can.Main -> Opt.Expr -> State Int Code
generateProgram kind body =
  case kind of
    Can.VDom ->
      do  html <- generateJsExpr body
          jsExpr (Var.staticProgram <| html)

    Can.NoFlags ->
      do  almostProgram <- generateJsExpr body
          jsExpr (JS.Call almostProgram [])

    Can.Flags tipe ->
      do  almostProgram <- generateJsExpr body
          flagDecoder <- generateJsExpr (Foreign.decode tipe)
          jsExpr (almostProgram <| flagDecoder)



-- DEFINITIONS


generateLetDef :: (Text, Opt.Def) -> State Int JS.Stmt
generateLetDef (name, def) =
  do  jsBody <- generateDef name def
      return $ JS.VarDeclStmt [ Help.varDecl name jsBody ]


generateDef :: Text -> Opt.Def -> State Int JS.Expr
generateDef name def =
  case def of
    Opt.TailDef argNames body ->
      generateTailFunction name argNames body

    Opt.Def body ->
      generateJsExpr body


generateTailFunction :: Text -> [Text] -> Opt.Expr -> State Int JS.Expr
generateTailFunction name args body =
  do  code <- generateCode body
      return $ generateFunctionWithArity args $ JsBlock $ (:[]) $
          JS.Labelled
              (JS.Id (Var.safe name))
              (JS.While (JS.Bool True) (toStatement code))



-- FUNCTIONS


generateFunction :: [Text] -> Opt.Expr -> State Int Code
generateFunction args body =
  do  code <- generateCode body
      jsExpr (generateFunctionWithArity args code)


generateFunctionWithArity :: [Text] -> Code -> JS.Expr
generateFunctionWithArity rawArgs code =
    let
        args = map Var.safe rawArgs
        arity = length args
    in
      if 2 <= arity && arity <= 9 then
          let
              fN = "F" <> Text.pack (show arity)
          in
              ref fN <| function args (toStatementList code)
      else
          let
              (lastArg:otherArgs) = reverse args
              innerBody = function [lastArg] (toStatementList code)
          in
              foldl (\body arg -> function [arg] [JS.Return (Just body)]) innerBody otherArgs



-- GENERATE CALL


generateCall :: Opt.Expr -> [Opt.Expr] -> State Int Code
generateCall func args =
  case (func, args) of
    (Opt.VarGlobal home name, [arg]) ->
      case name of
        "complement" | home == bitwise -> genPrefix JS.PrefixBNot arg
        "not"        | home == basics  -> genPrefix JS.PrefixLNot arg
        _                              -> generateCallHelp func args

    (Opt.VarGlobal home name, [ left, right ]) | home == bitwise ->
      case name of
        "and"            -> genInfix JS.OpBAnd     left right
        "or"             -> genInfix JS.OpBOr      left right
        "xor"            -> genInfix JS.OpBXor     left right
        "shiftLeftBy"    -> genInfix JS.OpLShift   right left
        "shiftRightBy"   -> genInfix JS.OpSpRShift right left
        "shiftRightZfBy" -> genInfix JS.OpZfRShift right left
        _                -> generateCallHelp func args

    _ ->
      generateCallHelp func args


genPrefix :: JS.PrefixOp -> Opt.Expr -> State Int Code
genPrefix op arg =
  do  jsArg <- generateJsExpr arg
      jsExpr (JS.Prefix op jsArg)


genInfix :: JS.InfixOp -> Opt.Expr -> Opt.Expr -> State Int Code
genInfix op left right =
  do  jsLeft <- generateJsExpr left
      jsRight <- generateJsExpr right
      jsExpr $ JS.Infix op jsLeft jsRight


basics :: ModuleName.Canonical
basics =
  ModuleName.inCore "Basics"


bitwise :: ModuleName.Canonical
bitwise =
  ModuleName.inCore "Bitwise"


generateCallHelp :: Opt.Expr -> [Opt.Expr] -> State Int Code
generateCallHelp func args =
  let
    arity = length args
    aN = "A" <> Text.pack (show arity)
  in
    do  jsFunc <- generateJsExpr func
        jsArgs <- mapM generateJsExpr args
        jsExpr $
          if 2 <= arity && arity <= 9 then
            JS.Call (ref aN) (jsFunc:jsArgs)
          else
            foldl1 (<|) (jsFunc:jsArgs)



-- GENERATE IFS


generateIf :: [(Opt.Expr, Opt.Expr)] -> Opt.Expr -> State Int Code
generateIf givenBranches givenFinally =
  let
    (branches, finally) =
        crushIfs givenBranches givenFinally

    convertBranch (condition, expr) =
        (,) <$> generateJsExpr condition <*> generateCode expr

    ifExpression (condition, branch) otherwise =
        JS.If condition branch otherwise

    ifStatement (condition, branch) otherwise =
        JS.IfStmt condition branch otherwise
  in
    do  jsBranches <- mapM convertBranch branches
        jsFinally <- generateCode finally

        if any isBlock (jsFinally : map snd jsBranches)
          then
            jsBlock [ foldr ifStatement (toStatement jsFinally) (map (second toStatement) jsBranches) ]
          else
            jsExpr (foldr ifExpression (toExpr jsFinally) (map (second toExpr) jsBranches))


crushIfs
    :: [(Opt.Expr, Opt.Expr)]
    -> Opt.Expr
    -> ([(Opt.Expr, Opt.Expr)], Opt.Expr)
crushIfs branches finally =
  crushIfsHelp [] branches finally


crushIfsHelp
    :: [(Opt.Expr, Opt.Expr)]
    -> [(Opt.Expr, Opt.Expr)]
    -> Opt.Expr
    -> ([(Opt.Expr, Opt.Expr)], Opt.Expr)
crushIfsHelp visitedBranches unvisitedBranches finally =
  case unvisitedBranches of
    [] ->
        case finally of
          If subBranches subFinally ->
              crushIfsHelp visitedBranches subBranches subFinally

          _ ->
              (reverse visitedBranches, finally)

    (Literal (L.Boolean True), branch) : _ ->
        crushIfsHelp visitedBranches [] branch

    visiting : unvisited ->
        crushIfsHelp (visiting : visitedBranches) unvisited finally



-- CASE EXPRESSIONS


generateCase :: Text -> Opt.Decider Opt.Choice -> [(Int, Opt.Expr)] -> State Int [JS.Stmt]
generateCase exprName decider jumps =
  do  labelRoot <- Var.fresh
      decider <- generateDecider exprName labelRoot decider
      foldM (goto labelRoot) decider jumps



-- handle any jumps


goto :: Text -> [JS.Stmt] -> (Int, Opt.Expr) -> State Int [JS.Stmt]
goto labelRoot deciderStmts (target, branch) =
  let
    labeledDeciderStmt =
      JS.Labelled
        (toLabel labelRoot target)
        (JS.DoWhile (JS.Block deciderStmts) (JS.Bool False))
  in
    do  code <- generateCode branch
        return (labeledDeciderStmt : toStatementList code)


toLabel :: Text -> Int -> JS.Id
toLabel root target =
  JS.Id (root <> "_" <> Text.pack (show target))



-- turn deciders into ifs and switches


generateDecider :: Text -> Text -> Opt.Decider Opt.Choice -> State Int [JS.Stmt]
generateDecider exprName labelRoot decisionTree =
  case decisionTree of
    Opt.Leaf (Opt.Inline branch) ->
        toStatementList <$> generateCode branch

    Opt.Leaf (Opt.Jump target) ->
        return [ JS.Break (Just (toLabel labelRoot target)) ]

    Opt.Chain testChain success failure ->
        let
          makeTest (path, test) =
            do  testExpr <- pathToTestableExpr exprName path test
                return (JS.Infix JS.OpStrictEq testExpr (testToExpr test))
        in
          do  testExprs <- mapM makeTest testChain
              let cond = List.foldl1' (JS.Infix JS.OpLAnd) testExprs
              thenBranch <- generateDecider exprName labelRoot success
              elseBranch <- generateDecider exprName labelRoot failure
              return [ JS.IfStmt cond (JS.Block thenBranch) (JS.Block elseBranch) ]

    Opt.FanOut path edges fallback ->
        do  testExpr <- pathToTestableExpr exprName path (fst (head edges))
            caseClauses <- mapM (edgeToCase exprName labelRoot) edges
            caseDefault <- JS.Default <$> generateDecider exprName labelRoot fallback
            return [ JS.Switch testExpr (caseClauses ++ [caseDefault]) ]


edgeToCase :: Text -> Text -> (DT.Test, Opt.Decider Opt.Choice) -> State Int JS.Case
edgeToCase exprName labelRoot (test, subTree) =
  JS.Case (testToExpr test) <$> generateDecider exprName labelRoot subTree


testToExpr :: DT.Test -> JS.Expr
testToExpr test =
  case test of
    DT.Constructor (V.Canonical _ tag) ->
        JS.String tag

    DT.Literal (L.Chr char) ->
        JS.String char

    DT.Literal lit ->
        Literal.literal lit



-- work with paths


pathToTestableExpr :: Text -> DT.Path -> DT.Test -> State Int JS.Expr
pathToTestableExpr root path exampleTest =
  do  accessExpr <- generateJsExpr (pathToExpr root path)
      case exampleTest of
        DT.Constructor _ ->
            return $ JS.DotRef accessExpr (JS.Id "ctor")

        DT.Literal (L.Chr _) ->
            return $ JS.Call (JS.DotRef accessExpr (JS.Id "valueOf")) []

        DT.Literal _ ->
            return accessExpr


pathToExpr :: Text -> DT.Path -> Opt.Expr
pathToExpr root fullPath =
    go (Opt.VarLocal root) fullPath
  where
    go expr path =
        case path of
          DT.Position index subpath ->
              go (Opt.CtorAccess expr index) subpath

          DT.Field field subpath ->
              go (Opt.Access expr field) subpath

          DT.Empty ->
              expr

          DT.Alias ->
              expr



-- BINARY OPERATORS


generateBinop :: ModuleName.Canonical -> Text -> Opt.Expr -> Opt.Expr -> State Int Code
generateBinop home op left right =
  do  jsLeft <- generateJsExpr left
      jsRight <- generateJsExpr right
      jsExpr (generateBinopHelp home op jsLeft jsRight)



-- BINARY OPERATOR HELPERS


generateBinopHelp :: ModuleName.Canonical -> Text -> JS.Expr -> JS.Expr -> JS.Expr
generateBinopHelp home op leftExpr rightExpr =
  let
    simpleMake left right =
      JS.Call (ref "A2") [ Var.global home op, left, right ]
  in
    if home == basics then
        (Map.findWithDefault simpleMake op basicOps) leftExpr rightExpr

    else if op == "::" && home == list then
        BuiltIn.cons leftExpr rightExpr

    else
        simpleMake leftExpr rightExpr


list :: ModuleName.Canonical
list =
  ModuleName.inCore "List"


basicOps :: Map.Map Text (JS.Expr -> JS.Expr -> JS.Expr)
basicOps =
    Map.fromList (infixOps ++ specialOps)


infixOps :: [(Text, JS.Expr -> JS.Expr -> JS.Expr)]
infixOps =
    let
        infixOp str op =
            (str, JS.Infix op)
    in
        [ infixOp "+"  JS.OpAdd
        , infixOp "-"  JS.OpSub
        , infixOp "*"  JS.OpMul
        , infixOp "/"  JS.OpDiv
        , infixOp "&&" JS.OpLAnd
        , infixOp "||" JS.OpLOr
        ]


specialOps :: [(Text, JS.Expr -> JS.Expr -> JS.Expr)]
specialOps =
    [ (,) "^"  $ \a b -> JS.Call (obj ["Math","pow"]) [a,b]
    , (,) "==" $ \a b -> BuiltIn.eq a b
    , (,) "/=" $ \a b -> JS.Prefix JS.PrefixLNot (BuiltIn.eq a b)
    , (,) "<"  $ cmp JS.OpLT 0
    , (,) ">"  $ cmp JS.OpGT 0
    , (,) "<=" $ cmp JS.OpLT 1
    , (,) ">=" $ cmp JS.OpGT (-1)
    , (,) "//" $ \a b -> JS.Infix JS.OpBOr (JS.Infix JS.OpDiv a b) (JS.Int 0)
    ]


cmp :: JS.InfixOp -> Int -> JS.Expr -> JS.Expr -> JS.Expr
cmp op n a b =
    JS.Infix op (BuiltIn.cmp a b) (JS.Int n)
