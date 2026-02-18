# AGENTS.md

## Project Overview

Chrome Extension (Manifest V3) that filters tweets on Twitter/X using Gemini Nano (on-device AI). Written in PureScript 0.15.15 with JavaScript FFI.

## Prerequisites

- Node.js >= 22.5 (required by spago 1.x)
- PureScript compiler (`purs`) 0.15.15
- npm (spago and vite are npm devDependencies)

If using Nix: `nix develop` provides the full toolchain.

Otherwise install manually:

```sh
npm install
```

This installs `spago` (PureScript build tool) and `vite` (bundler) as devDependencies.

## Build

The build has two stages: PureScript compilation and Vite bundling.

### Full build (compile + bundle)

```sh
npm run build
```

This runs `spago build` then `node build.mjs`. Output goes to `dist/`.

### PureScript compile only

```sh
npx spago build
```

Compiles all PureScript modules to `output/`. Use this for fast type-checking during development. Warnings about `UnnecessaryFFIModule` are expected (JS companion files exist for modules that no longer import FFI).

### Bundle only (after compile)

```sh
node build.mjs
```

Bundles 4 entry points via Vite:

| Entry Point | Format | Output |
|---|---|---|
| `src/entries/background.js` | ES module | `dist/background/index.js` |
| `src/entries/offscreen.js` | IIFE | `dist/offscreen/index.js` |
| `src/entries/content.js` | IIFE | `dist/content/index.js` |
| `src/entries/options.js` | IIFE | `dist/options/index.js` |

Also copies static assets (manifest.json, HTML, CSS) to `dist/`.

### Development build (unminified, with sourcemaps)

```sh
NODE_ENV=development node build.mjs
```

## Test

```sh
npm test
```

This runs `spago test`, which compiles and executes `test/Main.purs` via Node.js. Tests cover:

- OutputLanguage round-trip encoding
- Constants validation
- Message protocol encode/decode round-trip (all message types)
- Malformed input rejection (missing fields, wrong types)
- Required field regression tests

Expected output: 29 passing tests, exit code 0.

### Troubleshooting: SQLite error

If `npm test` fails with `ERR_SQLITE_ERROR: unable to open database file`, this is a spago registry cache issue, not a code problem. Fix:

```sh
rm -rf .spago/registry
npm test
```

## Project Structure

```
src/
  entries/           -- JS entry points (import PureScript output)
  FFI/               -- Foreign Function Interface
    Chrome/          -- Chrome Extension APIs (Runtime, Storage, Offscreen)
    GeminiNano.purs  -- Gemini Nano LanguageModel API
    WebApi.purs      -- DOM, timers, fetch, MutationObserver
  background/        -- Service Worker (message routing, cache, offscreen management)
  content/           -- Content Script (tweet detection, filtering, DOM manipulation)
  offscreen/         -- Offscreen Document (AI session management, evaluation queue)
  options/           -- Options Page (settings UI, model status)
  shared/            -- Shared modules
    messaging/       -- Typed message protocol (ADT + encode/decode)
    Types/           -- Domain types (Storage, Tweet)
    Constants.purs   -- Selectors, delays
    Logger.purs      -- Logging
    Storage.purs     -- chrome.storage.sync wrapper
test/
  Main.purs          -- Test suite
```

## Architecture

4 Chrome Extension components communicate via `chrome.runtime.sendMessage`:

```
Content Script  -->  Background (Service Worker)  -->  Offscreen Document
  (tweet DOM)        (message routing, cache)          (Gemini Nano sessions)
```

- **Content Script**: Observes DOM for tweets via MutationObserver, sends evaluation requests
- **Background**: Routes messages, manages cache, manages offscreen document lifecycle
- **Offscreen**: Holds Gemini Nano sessions, evaluates tweets through a serialized queue
- **Options**: UI for configuration (filter criteria, model download)

All inter-component messages use a typed ADT (`Shared.Messaging.Types.Message`) with `encodeMessage`/`decodeMessage` for type-safe serialization.

## Key Conventions

- **Concurrency**: `AVar Unit` as mutex (full = idle, empty = locked), `bracket` for acquire/release
- **Cancellation**: `Ref Boolean` flags checked at loop boundaries
- **FFI pattern**: PureScript signatures in `.purs`, implementations in `.js` companion files
- **Error handling**: `Either String a` for decode errors, `Aff` with `try`/`bracket` for effects
- **Resource cleanup**: Listeners and timers return or store cleanup functions for removal

## Functional Programming Idioms

- Prefer total functions; represent absence/failure with `Maybe`/`Either` rather than sentinel values.
- Model control flow with ADTs and pattern matching, not stringly-typed branching.
- Keep pure data transformation separate from effectful orchestration.
- Minimize mutable state scope; isolate `Ref` writes behind small helper functions.
- Make side-effect boundaries explicit and composable (`map`, `traverse`, `foldM`, `bracket`).
- Favor declarative collection operations over manual index/state loops.
- Keep functions small and single-purpose; compose behavior from reusable pure parts.
- Add regression tests for each bug fix and boundary-condition handling.

## PureScript-Specific Idioms

- Prefer closed ADTs/newtypes for domain modeling; avoid broad records with loosely-coupled booleans.
- Use row-polymorphic records intentionally; keep shared field sets explicit and stable.
- Derive and use typeclass instances where meaningful (`Eq`, `Ord`, `Show`, etc.).
- Keep `Effect`/`Aff` in outer layers; pass pure values into core logic whenever possible.
- Use `Aff` resource safety patterns (`bracket`, `try`, cancellation-safe cleanup) for async code.
- Treat FFI as an unsafe boundary: validate `Foreign` shapes before `unsafeFromForeign`.
- Encode/decode extension protocol through typed constructors (`Message` ADT) only.
- Prefer `newtype` wrappers for opaque IDs and constrained values when invariants matter.
- Keep module APIs small and explicit; avoid re-exporting large internal surfaces by default.

## Verification Checklist

After any code change, run all four:

```sh
npx spago build        # 0 errors
node build.mjs         # 4 entry points bundled
npx spago test         # 29 tests passing
```

Checklist reference: `docs/FUNCTIONAL_IDIOM_CHECKLIST.md`

For manual testing, load `dist/` as an unpacked extension in `chrome://extensions/` (Developer mode).
