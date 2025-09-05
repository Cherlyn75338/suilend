# Suilend
Lending protocol on the Sui Blockchain

# Overview of terminology

A LendingMarket object holds many Reserves and Obligations.

An Obligation is a representations of a user's deposits and borrows. An obligation has exactly one lending market. 

There is 1 Reserve per token type (e.g a SUI Reserve, a SOL Reserve, a USDC Reserve). 
A user can supply assets to the reserve to earn interest, and/or borrow assets from a reserve and pay interest.
When a user deposits assets into a reserve, they will receive CTokens. 
The CToken represents the user's ownership of their deposit, and entitles the user to earn interest on their deposit.

## Running tests and invariants

- Unit tests (Move):
  - From `contracts/suilend`, run: `sui move test` (or your Sui CLI equivalent)
  - Invariant-style tests are in `contracts/suilend/tests/invariant_tests.move`.

- Move Prover (light specs):
  - Install Move Prover toolchain matching `edition = "2024.beta"`.
  - From `contracts/suilend`, run: `mpm prove` or `move prove` depending on your setup.
  - We added basic spec blocks in `sources/rate_limiter.move` and `sources/obligation.move` to check arithmetic and health relations.

Note: This repository uses Move (no Solidity). The invariant tests emulate property-based sequences over deposits/borrows/withdrawals and liquidation paths.
