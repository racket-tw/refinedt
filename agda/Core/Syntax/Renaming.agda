{-# OPTIONS --safe #-}

module Core.Syntax.Renaming where

open import Data.Fin using (zero; suc; raise)

open import Core.Syntax
open import Core.Syntax.Actions (record { Target = Fin
                                        ; var-action = λ ι → CVar ι
                                        ; ext = λ where _ zero → zero
                                                        ρ (suc n) → suc (ρ n)
                                        }) public

weaken-ε : CExpr ℓ → CExpr (suc ℓ)
weaken-ε = act-ε suc

weaken-ε-k : ∀ k → CExpr ℓ → CExpr (k + ℓ)
weaken-ε-k k = act-ε (raise k)
