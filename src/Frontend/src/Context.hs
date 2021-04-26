module Context where

import Syntax
import Data.List
import Text.Parsec
import Data.Functor.Identity (Identity)
type Parser a = ParsecT String Context Identity a

type Name = String
-- data Name
--   = Var String
--   | Wir Pattern
--   deriving (Show, Eq)
data Binding
  = NameBind
  | VarBind Type
  | WireBind Wtype

type Context = [(Name, Binding)]

emptyctx :: Context
emptyctx = []

addBinding :: Context -> Name -> Binding -> Context
addBinding ctx x bind = (x, bind) : ctx

-- | Add all wire variables in the Pattern to the Context
-- The types of all variables are given in the corresponding position of Wtype
addPatBinding2State :: Pattern -> Wtype -> Parser ()
addPatBinding2State patvar wtype = case patvar of
  PtVar _ _    -> error "Invalid PtVar in addPatBinding2State"
  PtName name  -> getState
                  >>= \ctx -> setState (addBinding ctx name (WireBind wtype))
  PtEmp        -> return ()
  PtProd p1 p2 -> case wtype of
    WtProd w1 w2 -> addPatBinding2State p1 w1 >> addPatBinding2State p2 w2
    _            -> error "Pattern and Wtype not match in addPatBinding2State"

name2index :: Monad m => Context -> Name -> m Int
name2index ctx name =
  case findIndex ((== name). fst) ctx of
    Just ind -> return ind
    Nothing -> error $ "Unbounded variable name \"" ++ name ++ "\""