module Surface.Syntax

import Data.Vect

%default total
%access public export

record Var where
  constructor MkVar
  var : String

Eq Var where
  (==) v1 v2 = var v1 == var v2
  (/=) v1 v2 = var v1 /= var v2

DecEq Var where
  decEq (MkVar var1) (MkVar var2) = case decEq var1 var2 of
                                         Yes Refl => Yes Refl
                                         No contra => No $ \Refl => contra Refl

mutual
  data STerm : Type where
    SVar  : (var : Var) -> STerm
    SLam  : (var : Var) -> (t : SType) -> (e : STerm) -> STerm
    SApp  : (e1 : STerm) -> (e2 : STerm) -> STerm
    SUnit : STerm
    SCase : (scrut : STerm) -> (branches : CaseBranches n) -> STerm
    SCon  : (idx : Fin n) -> (body : STerm) -> (adtCons : ADTCons n) -> STerm

  record CaseBranch where
    constructor MkCaseBranch
    var : Var
    body : STerm

  data BaseType = BUnit

  infixl 6 &
  infixl 7 |=|
  data Refinement = (|=|) STerm STerm
                  | (&) Refinement Refinement
  %name Refinement r, r1, r2

  ADTCons : Nat -> Type
  ADTCons n = Vect n SType

  CaseBranches : Nat -> Type
  CaseBranches n = Vect n CaseBranch

  data SType : Type where
    SRBT : (var : Var) -> (b : BaseType) -> (ref : Refinement) -> SType
    SArr : (var : Var) -> (t1 : SType) -> (t2 : SType) -> SType
    SADT : (cons : ADTCons n) -> SType

isValue : STerm -> Bool
isValue (SVar _) = True
isValue SUnit = True
isValue (SCon _ body _) = isValue body
isValue _ = False

Ctx : Type
Ctx = List (Var, SType)

-- Helpers

Τ : Refinement
Τ = SUnit |=| SUnit

syntax "{" [v] ":" [b] "|" [r] "}" = SRBT v b r

mutual
  substInType : Var -> STerm -> SType -> SType
  substInType x e (SRBT var b ref) = SRBT var b $ substInRef x e ref
  substInType x e (SArr var t1 t2) = SArr var (substInType x e t1) (substInType x e t2)
  substInType x e (SADT cons) = SADT $ substInADT x e cons

  substInRef : Var -> STerm -> Refinement -> Refinement
  substInRef x e (e1 |=| e2) = substInTerm x e e1 |=| substInTerm x e e2
  substInRef x e (r1 & r2) = substInRef x e r1 & substInRef x e r2

  substInTerm : Var -> STerm -> STerm -> STerm
  substInTerm x e (SVar var) = case decEq x var of
                                    Yes _ => e
                                    No _ => SVar var
  substInTerm x e (SLam var t body) = SLam var t $ case decEq x var of
                                                        Yes _ => body
                                                        No _ => substInTerm x e body
  substInTerm x e (SApp e1 e2) = SApp (substInTerm x e e1) (substInTerm x e e2)
  substInTerm x e SUnit = SUnit
  substInTerm x e (SCase scrut branches) = SCase (substInTerm x e scrut) (substInBranches x e branches)
  substInTerm x e (SCon idx body adtCons) = SCon idx (substInTerm x e body) (substInADT x e adtCons)

  substInADT : Var -> STerm -> ADTCons n -> ADTCons n
  substInADT x e [] = []
  substInADT x e (ty :: xs) = substInType x e ty :: substInADT x e xs
  -- TODO can we have `map` here while keeping the totality checker happy?

  substInBranches : Var -> STerm -> CaseBranches n -> CaseBranches n
  substInBranches x e [] = []
  substInBranches x e (b@(MkCaseBranch var body) :: bs) =
    let this = case decEq x var of
                    Yes _ => b
                    No _ => MkCaseBranch var $ substInTerm x e body
        rest = substInBranches x e bs
    in this :: rest
