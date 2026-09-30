# Tessera — working agreement for agents

Read `docs/plan/PLAN-v4.1.es.md` before changing anything. It is the approved contract:
§12 lists the invariants and spike criteria, §13 the phase you are in.

## Rules

- **Code and documentation in English.** Only user-facing strings are localised (es, en).
- **Never push or open a pull request without the owner's explicit approval.**
- `TesseraCore` imports the standard library only. No Foundation, no AppKit.
- Geometry is integer points with a top-left origin. AppKit's bottom-left space is converted
  at the platform boundary and never enters the core.
- Never read window titles in diagnostics, fixtures or logs.
- Every spike ends with an ADR in `docs/adr/` (go / no-go / fallback) and a reproducible script
  in `spikes/Sx/`. Each live run appends its result to `spikes/results/<test>.jsonl`
  (committed); per-run logs go to `spikes/**/output/` and the run's state directory (ignored).
- Live tests use `spikes/lib/lab.py`: their own state directory, conditions with deadlines, an
  idle desktop, and the owner returned to the Space they started on.
- "No holes" is measured on screen, never asserted from the plan.

## Verification before calling anything done

```bash
scripts/gate.sh    # build, tests, core import rule, no titles, environment reads, perf budgets
```

`scripts/install-hooks.sh` makes the pre-push hook run the same gate. Invariants are catalogued
in `docs/invariants.md`; operations in `docs/RUNBOOK.md`.

Anything that moves real windows runs in the `tessera-lab` user account, never in the
owner's session, unless the owner asks for it.
