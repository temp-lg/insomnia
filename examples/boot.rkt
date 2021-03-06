#lang gamble
#| This file defines the primitive operations for Insomnia.

   Since Insomnia has single-argument functions, everything is heavily curried.  Additionally, Insomnia's Dist monad
   is translated as a thunk in Gamble.  Mind the parens.
 |#

(provide (all-defined-out))

(define ((__BOOT.intAdd x) y) (+ x y))

(define (((((__BOOT.ifIntLt) x) y) t) f)
  (lambda (_)
    (if (< x y) (t null) (f null))))

(define ((__BOOT.realAdd x) y) (+ x y))

(define ((__BOOT.realMul x) y) (+ x y))

(define (((((__BOOT.ifRealLt) x) y) t) f)
  (lambda (_)
    (if (< x y) (t null) (f null))))

(define (((((__BOOT.Distribution.choose) r) d1) d2))
  (if (flip r)
      (d1)
      (d2)))

(define (((__BOOT.Distribution.uniform lo) hi))
  (uniform lo hi))

(define (((__BOOT.Distribution.normal μ) σ²))
  (normal μ σ²))

(define (((((__BOOT.posterior)) kern) obs) prior)
  (lambda ()
    (define x (prior))
    (observe/fail ((kern x)) obs)
    x))
