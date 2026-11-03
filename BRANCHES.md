# Two branches, two folders

| Folder | Branch | Builds | What it is |
| --- | --- | --- | --- |
| `~/Gruppen` | `master` | `/Applications/Gruppen.app` | The release. No flows. |
| `~/Gruppen-Beta` | `Beta` | `/Applications/Gruppen Beta.app` | Flows, in development. |

Both are one repository (`git worktree`), so a commit in one folder is visible
from the other at once. Switching is opening the other folder.

**A fix for both** — telemetry, stash, workspaces: commit it in `~/Gruppen`,
then in `~/Gruppen-Beta` run `git merge master`.

**Flows work** happens only in `~/Gruppen-Beta`. Don't merge `Beta` into
`master` until flows ship.

**Shipping flows:** in `~/Gruppen`, `git merge Beta`, then delete `CHANNEL`
and commit. `master` already carries the commit that removed flows, and
`Beta` recorded it as merged, so that one merge brings them back.

**What makes the beta app separate:** the `CHANNEL` file, which only `Beta`
has. `build.sh` reads it and builds "Gruppen Beta" with its own bundle id,
settings and data folder (`~/Library/Application Support/Gruppen Beta`), so
the two apps never touch each other's files. Run one at a time: both claim
the same hotkeys and menu bar items.
