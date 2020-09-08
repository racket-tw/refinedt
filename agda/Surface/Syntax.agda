module Surface.Syntax where

open import Agda.Builtin.Bool
open import Agda.Builtin.List public
open import Agda.Builtin.Nat public
open import Agda.Builtin.String

open import Data.Fin public using (Fin)
open import Data.Product public using (_×_; _,_)
open import Data.Vec public

record Var : Set where
  constructor MkVar
  field
    var : String

open Var

var-eq : Var → Var → Bool
var-eq x₁ x₂ = primStringEquality (var x₁) (var x₂)

data BaseType : Set where
  BUnit : BaseType


data STerm : Set
data SType : Set
data Refinement : Set
CaseBranches : Nat → Set
ADTCons : Nat → Set

record CaseBranch : Set

data STerm where
  SVar  : (var : Var) → STerm
  SLam  : (var : Var) → (τ : SType) → (ε : STerm) → STerm
  SApp  : (ε₁ : STerm) → (ε₂ : STerm) → STerm
  SUnit : STerm
  SCase : {n : _} → (scrut : STerm) → (branches : CaseBranches n) → STerm
  SCon  : {n : _} → (idx : Fin n) → (body : STerm) → (adtCons : ADTCons n) → STerm

data SType where
  SRBT : (ν : Var) → (b : BaseType) → (ρ : Refinement) → SType
  SArr : (var : Var) → (τ₁ : SType) → (τ₂ : SType) → SType
  SADT : {n : _} → (cons : ADTCons (suc n)) → SType

data Refinement where
  _≈_ : STerm → STerm → Refinement
  _∧_ : (ρ₁ : Refinement) → (ρ₂ : Refinement) → Refinement

record CaseBranch where
  constructor MkCaseBranch
  inductive
  field
    var : Var
    body : STerm

CaseBranches n = Vec CaseBranch n

ADTCons n = Vec SType n


CtxElem : Set
CtxElem = Var × SType

Ctx : Set
Ctx = List CtxElem
