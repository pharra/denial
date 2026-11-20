# Why the portable-engine experiment was retired

Denial builds its locked Flutter SDK, engine and every native component from
**one package set**: the flake's `nixpkgs` input, which a consumer replaces the
usual way.

```nix
inputs.denial.inputs.nixpkgs.follows = "nixpkgs";
```

The retired experiment in this directory took the opposite approach. It built
the engine once, with its own pinned Nixpkgs, published it as a self-contained
"raw" artifact, and re-linked a copy to each host's loader and graphics
libraries at install time. Together with a compatibility gate, an artifact
manifest, the cache-contract checks and a negative driver test, that machinery
existed to make a single engine binary usable on hosts whose Nixpkgs differed
from the producer's. It is gone; what follows records why.

## What it was for

A Denial process has exactly one loader and one libc. The Mesa driver it loads
at runtime, however, comes from the host's `/run/opengl-driver`, not from
Denial's closure. When the package had been built against an older libc than
the driver required, `dlopen` failed with `GLIBC_* not found` and libgbm
reported the misleading `ENOENT` that Denial surfaced as a GBM initialization
failure. The experiment reused one expensive build across hosts by rewriting
ELF search paths, and the gate fell back to a source build when the host was
too old for the artifact.

Rationale, then: publish one engine, adapt it per host, verify every byte, and
test the boundary. The motivation was the cost of the engine build, not a
property the desktop needed.

## Why it was retired

Every one of those mechanisms is a workaround for mixing package sets:

- The engine's producer had to ignore the consumer's overlays, so the engine
  and the compositor that maps it could disagree about libc, GL and GBM.
- The adaptation step rewrote loader and library paths, so the engine's
  identity no longer matched any single package set, and its correctness
  depended on a manifest, a checksum inventory and a compatibility baseline.
- The compatibility gate and the `buildFromSource` option then had to decide,
  per host, which of two provenance paths applied, and the negative driver
  test had to synthesize a mismatch to keep that decision honest.
- A second, unstable Nixpkgs existed only to exercise those decisions.

Building one set removes the mismatch instead of detecting it. The engine, the
compositor, the shell, Settings and the host's drivers are then products of the
same Nixpkgs: the same libc is the only one that can be loaded, and there is
nothing to adapt, gate or verify. Denial's runtime fixes stay in Denial's code
instead of in ELF rewriting.

The trade is explicit: a host builds the engine when its Nixpkgs differs from
the one CI published, and the public cache covers hosts that keep Denial's
input. That is the ordinary flake contract, and it is cheaper than a class of
startup failures that only appears after a host update.

## What replaced it

- `nix/flutter-engine.nix` / `nix/flutter-engine-source.nix` build the locked
  engine with the package set in use; `denialFlutter.engine` is that build.
  `SOURCE_LOCK.json` still pins the exact Flutter, Skia and engine sources.
- The NixOS module installs `pkgs.denial`, built from the same set as the
  system's drivers.
- The module check asserts that host dependencies reach the compositor and the
  engine, that the engine is this set's own source build with Denial's
  Impeller-only configuration, and that the Dart SDK stays paired with it.
- `checks.engine-cache` keeps the runtime half of the old contract: the engine
  and the shell bundle load with this set's Mesa driver in one process, and the
  composed runtime holds exactly one libc. It still guards a published engine,
  now the one the cache holds for this set.
- `nix/experiments/` keeps this note only. The portable artifact derivation is
  gone; the reusable probe it shared with the runtime check stays as
  `nix/engine-probe.nix`.
