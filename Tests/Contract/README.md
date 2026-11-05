# Tilde's UI contract

What Tilde's UI must do, in plain files. No test here imports Tilde's code: a rewrite only has to read
the same files through the same tool and give the same results.

`scripts/ui-check.sh` runs both layers, in seconds, with no screen, mouse or keyboard. It fails above 60 s (goal 30 s).
Run it on every commit.

| Layer | Files | Meaning |
|---|---|---|
| State to picture | `states/*.json`, `pictures/macos-<version>/*.png` | This state must look like this picture |
| State plus event to state | `transitions/*.json` | Each row: from this state, this event gives this state and these effects |

- **Seam:** `tilde-state render <out> <files>` and `tilde-state transition <table>`, the only code that touches Tilde.
- **Checker:** `tilde-ui-check` uses no code of Tilde.
- **New UI state:** add a state file, run `scripts/ui-check.sh --record <name>`, look at the picture, commit it. A picture records what you approve, bugs too.
- **New rule:** add a row. A key left out of `expect` is not checked.

Pictures belong to one macOS version and one SDK: `pictures/macos-<major.minor>/`, with the exact setup in `recorded-on.txt`. On another version the check says that it skips them, and it warns when the SDK or patch version differs. Record only on the macOS they are for.

Clicks, keys and real apps are not tested here: the 5 flows in `Tests/TildeUXTests` do that before a release, in at most 3 minutes (`scripts/ux.sh`, or `scripts/ux-vm.sh` in the VM).
