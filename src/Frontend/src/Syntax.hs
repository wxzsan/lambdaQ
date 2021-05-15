module Syntax where

data Type
  = TyUnit
  | TyBool
  | TyProd Type Type
  | TyArr Type Type
  | TyCir Wtype Wtype
  deriving (Show, Eq)

data Term
  = TmVar Int Int
  | TmUnit
  | TmTrue
  | TmFalse
  | TmNot Term
  | TmAbs String Type Term
  | TmApp Term Term
  | TmProd Term Term
  | TmFst Term
  | TmSnd Term
  | TmIf Term Term Term
  | TmRun Circ
  | TmCir Pattern Wtype Circ
  deriving (Show, Eq)

data Circ
  = CcOutput Pattern
  | CcGate Pattern Gate Pattern Circ
  | CcComp Pattern Circ Circ
  | CcLift String Pattern Circ
  | CcApp Term Pattern
  deriving (Show, Eq)

data Wtype
  = WtUnit
  | WtBit
  | WtQubit
  | WtProd Wtype Wtype
  deriving (Show, Eq)

data Pattern
  = PtName String -- Name
  | PtEmp
  | PtProd Pattern Pattern
  | PtVar Int Int -- De Bruijn Index
  deriving (Show, Eq)

data Gate = Gt String
  deriving (Show, Eq)

gateInfos :: [(String, Wtype, Wtype)]
gateInfos =
  [ ("new0", WtUnit, WtBit)
  , ("new1", WtUnit, WtBit)
  , ("init0", WtUnit, WtQubit)
  , ("init1", WtUnit, WtQubit)
  , ("meas", WtQubit, WtBit)
  , ("discard", WtBit, WtUnit)
  , ("H", WtQubit, WtQubit)
  , ("X", WtQubit, WtQubit)
  , ("CNOT", WtProd WtQubit WtQubit, WtProd WtQubit WtQubit)
  ]

singleUnitaryGates :: [String]
singleUnitaryGates = ["H", "X"]

gateNames :: [String]
gateNames = map (\(a, _, _) -> a) gateInfos