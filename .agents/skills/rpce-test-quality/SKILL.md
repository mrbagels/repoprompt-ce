---
name: rpce-test-quality
description: Select, design, review, consolidate, or delete RepoPrompt CE tests and diagnostics by regression value and maintenance cost. Use for bug fixes or features that may need coverage, test-adequacy reviews, XCTest or provider-package changes, runtime diagnostic harnesses, live or packaged smoke, core migrations, and decisions about whether a test is worth committing.
---

# RepoPrompt CE Test Quality

Protect meaningful current contracts, not changed lines or method counts. Maximize regression signal per maintenance cost. Follow `AGENTS.md` for repository commands and approvals.

## Decide Before Writing

1. Name the behavior and plausible defect: user failure, data loss, protocol or security break, race, persistence error, malformed input, or costly operational failure.
2. Search existing direct and outcome-level coverage.
3. Define an oracle that distinguishes broken from fixed behavior.
4. Choose the lowest layer that faithfully reproduces the risk.
5. Add, consolidate, redesign, classify as diagnostics, or omit.

For a bug, prefer a test that fails against the known-bad behavior. If no stable contract, credible defect, or discriminating oracle can be named, do not add a test.

## Choose the Layer

- **Isolated core:** deterministic decisions, transformations, parsers, state machines, policy, invariants, and failure semantics. Prefer this when the behavior can be imported there.
- **Provider package:** provider protocol, codec, translation, launch-argument, and model-mapping behavior under `Packages/RepoPromptAgentProviders/Tests`.
- **Root SwiftPM:** module behavior without a launched GUI, including actors, persistence, filesystem or Git fixtures, subprocess adapters, in-process MCP, and deterministic concurrency. Keep app bridge and integration coverage under `Tests/RepoPromptTests`.
- **Runtime diagnostic harness:** assembled-app-only rendering, restoration, routing instrumentation, churn, or memory/CPU investigations. Put app-integrated harnesses under `Sources/RepoPrompt/Features/Diagnostics`; require a bounded scenario, machine-readable privacy-safe evidence, entry point, and cleanup path. Without an acceptance threshold, a benchmark is diagnostics, not behavioral coverage.
- **Live debug smoke:** running-app readiness, real app/MCP wiring, and a few critical journeys.
- **Packaged smoke:** bundle layout, embedded helper, process/socket ownership, architecture, signing, provenance, and packaged round trips.
- **Structural guard:** last resort for a narrow architecture, deletion, or exposure constraint that executable behavior, compiler boundaries, lint, or guardrail scripts cannot cheaply enforce.

Do not use smoke as the only protection for deterministic logic.

## Commit Gate

Commit only when the test:

- protects a current contract with plausible impact;
- fails for a meaningful defect and asserts observable output, state, error, side effect, cleanup, wire format, or bounded performance;
- adds distinct coverage at the lowest faithful layer;
- is deterministic, isolated, failure-focused, and maintainable relative to the risk.

Redesign or omit invocation-only, no-crash, non-nil-only, source-shape, symbol-presence, constant-restatement, coverage-driven, report-only, arbitrary-sleep, and omnibus tests. Allow an exception only when that fact is the explicit contract and no stronger oracle exists.

## Author and Validate

Assert exact outcomes and negative boundaries. Keep one coherent contract per test; use labeled tables only for equivalent cases. Control time, randomness, locale, environment, resources, ordering, and concurrency; use gates, clocks, or continuations instead of sleeps. Use temporary resources and verify important cleanup or ownership. Add production seams only when narrow, deterministic, behavior-preserving, and justified.

Run the smallest relevant daemon-coordinated lane, then broaden for the affected boundary. Do not launch the app to validate ordinary logic, and obtain required approval before visible app lifecycle actions.

Report the protected contract and risk, chosen layer, oracle, validation run, and any coverage omitted, consolidated, moved to diagnostics, or replaced by a guardrail.
