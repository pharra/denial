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

## Xwayland input regions

The input-shape regression uses an X11 server named by `DISPLAY`. It creates
only unmapped windows and checks the frame's actual server-side input region
after shape changes, resizing, and reparenting. It is ignored by default so
headless test runs do not need an X server. From the repository root, run:

```sh
cargo test --locked --manifest-path compositor/Cargo.toml --features flutter \
  --bin deniald frame_preserves_client_input_holes_across_shape_and_lifecycle_changes \
  -- --ignored
```
