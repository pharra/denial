# Rust test policy

The Rust suite is intentionally limited to critical contracts. A test belongs
here only when its failure could compromise a session, cross a trust boundary,
corrupt durable state, leak or reuse a native resource, or leave hardware and
the compositor in conflicting states.

Keep tests for:

- authentication, privacy, bounded untrusted input, and fail-closed behavior;
- persistent settings validation, migration, revisioning, and filesystem
  safety;
- native protocol framing and queue limits;
- KMS, hotplug, DPMS, and engine resource ownership or rollback;
- cursor texture lifetime and externally observable portal contracts.

Do not add exhaustive value permutations, option-parser examples, cache or
allocation trivia, duplicated round trips, synthetic integer-limit scenarios,
or tests for states that production validation makes unreachable. Prefer one
strong invariant test over many examples of the same branch.

## Xwayland overlay placement policy

`overlays_that_ask_to_float_keep_their_own_placement` and
`skip_taskbar_windows_are_auxiliary` are plain unit tests: they cover the
predicate that decides whether an X11 window owns its placement and whether it
stays out of managed layouts. They need no X server and run with the normal
suite:

```sh
cargo test --locked --manifest-path compositor/Cargo.toml --features flutter \
  --bin deniald -- overlay skip_taskbar
```

The overlay policy itself is covered by two Rust unit tests:
`overlays_that_ask_to_float_keep_their_own_placement` (client-owned origin) and
`skip_taskbar_windows_are_auxiliary` (layout exclusion). The shell side reads
the resulting `server_side_decorated` and `suppress_animations` flags, which
make an overlay draw with its own alpha and stay out of the switcher.
