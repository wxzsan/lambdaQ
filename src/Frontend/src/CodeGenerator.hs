{-# LANGUAGE FlexibleContexts, FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses, UndecidableInstances #-}

module CodeGenerator where

import Syntax
import Context
import QASMSyntax
import Data.List
import Control.Monad.State
import Control.Monad.Except
import qualified Data.Map as Map
import Debug.Trace

type Mapping = Map.Map Name Name
type Registers = (Mapping, Int)
-- We make use of the De Bruijn index of term variables here:
-- we add vars into it whenever we encounter an abstraction,
-- and when we need to find a corresponding bitvar, we just use the index.
type Variables = [(Name, Maybe Name)] -- boolvar name |-> bitvar name
type StateCG = (Registers, Variables)
emptystate :: StateCG
emptystate = ((Map.empty, 0), [])

-- instance MonadState StateCG m => MonadState (Mapping, Int) m where
--   get = getfst
--   put = putfst
-- I failed, give up :)

getRegs :: MonadState StateCG m => m Registers
getRegs = getfst
putRegs :: MonadState StateCG m => Registers -> m ()
putRegs = setfst

-- | pick a new register name and increment the count
pickNewReg :: MonadState StateCG m => m Name
pickNewReg = do
  (regs, cnt) <- getRegs
  putRegs (regs, cnt+1)
  return $ "r" ++ show cnt

-- | add a new mapping
addMapping :: MonadState StateCG m => Name -> Name -> m ()
addMapping var reg = do
  (regs, cnt) <- getRegs
  let regs' = Map.insert var reg regs
  putRegs (regs', cnt)

-- | add new mappings
addMappings :: (MonadState StateCG m, MonadError Err m) => Pattern -> Pattern -> m ()
addMappings PtEmp PtEmp = return ()
addMappings (PtName var) (PtName reg) = addMapping var reg
addMappings (PtProd pvar1 pvar2) (PtProd preg1 preg2) = do
  addMappings pvar1 preg1
  addMappings pvar2 preg2

-- | map variables to registers
var2reg :: Mapping -> Pattern -> Pattern
var2reg regs p = case p of
  PtEmp -> PtEmp
  PtName var -> PtName (regs Map.! var)
  PtProd p1 p2 -> PtProd (var2reg regs p1) (var2reg regs p2)

-- | restore the original mapping, preserve the new count
restore :: MonadState StateCG m => Registers -> m ()
restore (regs, cnt) = do
  (regs', cnt') <- getRegs
  putRegs (regs, cnt')

-- add pattern bitvar
addPatBitvar :: MonadError Err m => Variables -> (Pattern, Pattern) -> m Variables
addPatBitvar vars (patvar, ty) = case patvar of
  PtEmp -> return vars
  PtName name -> case ty of
    PtName x -> return $ addBinding vars (name, Just x)
    _ -> throwError $ "addPatBitvar: lift mismatch"
  PtProd p1 p2 -> case ty of
    PtProd t1 t2 -> do
      vars' <- addPatBitvar vars (p1, t1)
      addPatBitvar vars' (p2, t2)
    _ -> throwError $ "addPatBitvar: lift mismatch"

-- NOTE: I think that using GADT to define Term is better
term2QASM :: Term -> ExceptT Err (State StateCG) Program
term2QASM (TmCir p wt c) = case wt of
  WtUnit -> do
    (prog, _) <- circ2QASM c
    return prog
  _ -> throwError $ "term2QASM : not supported currently"
term2QASM _ = throwError $ "term2QASM : not supported currently"

circ2QASM :: Circ -> ExceptT Err (State StateCG) (Program, Pattern) -- QASM Program and return value
circ2QASM (CcOutput p) = do
  (regs, _) <- getRegs
  return ([], var2reg regs p)
circ2QASM (CcGate p1 g p2 c) = case g of
  Gt "new0" -> do
    current <- getRegs
    creg <- pickNewReg
    let (PtName var) = p1 in addMapping var creg
    (prog', outpat) <- circ2QASM c
    restore current
    return ([SmDecl (Creg creg)] ++ prog', outpat)
  Gt "new1" -> do
    current <- getRegs
    creg <- pickNewReg
    qreg <- pickNewReg
    let (PtName var) = p1 in addMapping var creg
    (prog', outpat) <- circ2QASM c
    let prog =
          [ SmDecl (Creg creg)
          , SmDecl (Qreg qreg)
          , SmQop (Uop (UX qreg))
          , SmQop (Measure qreg creg)]
    restore current
    return (prog ++ prog', outpat)
  Gt "init0" -> do
    current <- getRegs
    qreg <- pickNewReg
    let (PtName var) = p1 in addMapping var qreg
    (prog', outpat) <- circ2QASM c
    restore current
    return ([SmDecl (Qreg qreg)] ++ prog', outpat)
  Gt "init1" -> do
    current <- getRegs
    qreg <- pickNewReg
    let (PtName var) = p1 in addMapping var qreg
    (prog', outpat) <- circ2QASM c
    restore current
    return ([SmDecl (Qreg qreg), SmQop (Uop (UX qreg))] ++ prog', outpat)
  Gt gatename | gatename `elem` singleUnitaryGates -> do
    current@(regs, cnt) <- getRegs
    let (PtName reg) = var2reg regs p2
    let (PtName var) = p1 in addMapping var reg
    (prog', outpat) <- circ2QASM c
    restore current
    return ([SmQop (Uop (getSingleUop gatename reg))] ++ prog', outpat)
  Gt "meas" -> do
    current@(regs, cnt) <- getRegs
    let (PtName qreg) = var2reg regs p2
    creg <- pickNewReg
    let (PtName var) = p1 in addMapping var creg
    (prog', outpat) <- circ2QASM c
    restore current
    return ([SmQop (Measure qreg creg)] ++ prog', outpat)
  Gt "discard" -> do
    circ2QASM c
  Gt "CNOT" -> do
    current@(regs, cnt) <- getRegs
    let preg = var2reg regs p2
    let (PtProd (PtName reg1) (PtName reg2)) = preg -- needed by return
    let pvar = p1 in addMappings pvar preg
    (prog', outpat) <- circ2QASM c
    restore current
    return ([SmQop (Uop (UCX reg1 reg2))] ++ prog', outpat)
circ2QASM (CcComp p c1 c2) = do
  current <- getRegs
  (prog1, outpat1) <- circ2QASM c1
  addMappings p outpat1
  (prog2, outpat2) <- circ2QASM c2
  return (prog1 ++ prog2, outpat2)
circ2QASM (CcLift x p c) = do
  -- We need to maintain the De Bruijn index here
  current@((regs, cnt), vars) <- get
  let regbitvar = var2reg regs p
  addPatBitvar vars (x, regbitvar) >>= setsnd
  -- TODO: if the wtype of p is QuBit, we need to add a measure statement
  (prog', outpat) <- circ2QASM c
  put current
  return (prog', outpat)
circ2QASM (CcApp t p') = case t of
  TmCir _ _ _ -> tmCir2QASM t p'
  TmIf _ _ _ -> tmIf2QASM t p'
  -- TmVar x _ -> throwError $ "Currently Not Supported! [" ++ show x ++ "]"
  x -> throwError $ "circ2QASM CcApp : syntax " ++ show x ++ " not supported"

tmCir2QASM :: Term -> Pattern -> ExceptT Err (State StateCG) (Program, Pattern)
tmCir2QASM t p' = case t of
  TmCir p _ c -> do
    current@(regs, cnt) <- getRegs
    let preg = var2reg regs p'
    addMappings p preg
    (prog', outpat) <- circ2QASM c
    restore current
    return (prog', outpat)
  _ -> throwError $ "tmCir2QASM : not a circuit abstraction"

tmIf2QASM :: Term -> Pattern -> ExceptT Err (State StateCG) (Program, Pattern)
tmIf2QASM t p' = case t of
  TmIf t1 t2 t3 -> case t1 of
    TmVar x _ -> do
      (prog2, outpat2) <- tmCir2QASM t2 p'
      (prog3, outpat3) <- tmCir2QASM t3 p'
      mqop2 <- checkIf prog2
      mqop3 <- checkIf prog3
      vars <- getsnd
      let (_, bitvar) = vars !! x
      case bitvar of
        Just s -> if outpat2 /= outpat3 -- outpat2 and outpat3 need to be the same
                  then throwError $ "tmIf2QASM : different output patterns"
                  else return (generateIf s 1 mqop2 ++ generateIf s 0 mqop3, outpat2)
        Nothing -> throwError $ "tmIf2QASM : if condition is not a bool var"
    TmNot (TmVar x _) -> do
      (prog2, outpat2) <- tmCir2QASM t2 p'
      (prog3, outpat3) <- tmCir2QASM t3 p'
      mqop2 <- checkIf prog2
      mqop3 <- checkIf prog3
      vars <- getsnd
      let (_, bitvar) = vars !! x
      case bitvar of
        Just s -> if outpat2 /= outpat3 -- outpat2 and outpat3 need to be the same
                  then throwError $ "tmIf2QASM : different output patterns"
                  else return (generateIf s 0 mqop2 ++ generateIf s 1 mqop3, outpat2)
        Nothing -> throwError $ "tmIf2QASM : if condition is not a bool var"
  where
    checkIf :: (MonadState StateCG m, MonadError Err m) => Program -> m (Maybe Qop)
    checkIf prog = case prog of
      [] -> return Nothing
      [SmQop qop] -> return (Just qop)
      _ -> throwError $ "tmIf2QASM : two many statements in if-branch"
    generateIf :: Name -> Int -> Maybe Qop -> Program
    generateIf s x mqop = case mqop of
      Just qop -> [SmIf s x qop]
      Nothing -> []