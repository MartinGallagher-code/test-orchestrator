<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Publishing

`test-orchestrator` publishes to PyPI through **trusted publishing** (OIDC),
so no API token is stored as a repository secret. The workflow in
`.github/workflows/publish.yml` runs on a published GitHub Release, or
manually via `workflow_dispatch`.

## One-time PyPI setup

Do this **before** the first release, or the first publish run fails OIDC
with `invalid-publisher`.

1. Sign in at [pypi.org](https://pypi.org) and go to
   *Your projects → Publishing* (or *Account settings → Publishing* for a
   project that does not exist yet).
2. Add a **GitHub** trusted publisher:

   | Field | Value |
   |---|---|
   | Owner | `MartinGallagher-code` |
   | Repository | `test-orchestrator` |
   | Workflow name | `publish.yml` |
   | Environment | `pypi` |

3. In the GitHub repository, create an environment named `pypi`
   (*Settings → Environments*). Adding required reviewers there gives you a
   manual approval gate before anything is pushed to PyPI.

The workflow name and environment must match exactly. A mismatch is the
usual cause of `invalid-publisher`.

## Cutting a release

1. Update the version in **all three** places. They must agree — the test
   suite (`tests/test_version.sh`) fails if they do not, and so does the
   publish workflow if the tag disagrees:
   - `pyproject.toml` → `version`
   - `test_orchestrator/__init__.py` → `VERSION`
   - `test_orchestrator/tx.py` → `VERSION`

   `tx.py`'s is not redundant with the packaging version. `tx.py` is the
   whole tool in one file, and it is `scp`'d to every host and run there as
   the agent — where its own `VERSION` is the only version there is. It
   stamps that number into each run record as `agent_version`, so a `tx.py`
   left behind at the old number reports a fleet that disagrees with itself
   about what it ran, not a release that was cut carelessly.

   ```bash
   sed -i 's/^VERSION = "1\.0\.0"$/VERSION = "1.1.0"/' \
       test_orchestrator/__init__.py test_orchestrator/tx.py
   sed -i 's/^version = "1\.0\.0"$/version = "1.1.0"/' pyproject.toml
   ```

2. Move the `## [Unreleased]` items in `CHANGELOG.md` under a new
   `## [x.y.z] - YYYY-MM-DD` heading.
3. Commit, and let CI go green on `main`.
4. Tag and push:

   ```bash
   git tag -a v1.1.0 -m "test-orchestrator 1.1.0"
   git push origin v1.1.0
   ```

5. Publish a GitHub Release for that tag. That triggers `publish.yml`, which
   builds an sdist and a wheel, checks the metadata with `twine`, installs
   the wheel and smoke-tests both console scripts (`tx`, `test-orchestrator`)
   before uploading.

## Checking before you tag

```bash
python -m pip install --upgrade build twine
python -m build
python -m twine check dist/*

# The published artifact must be a working tool, not just valid metadata.
python -m pip install dist/*.whl
tx --version                 # and test-orchestrator --version agrees
tx hints
```

`twine check` catches a README that PyPI will not render, which is the most
common cosmetic failure.

## Running the publish twice

Harmless. The upload passes `skip-existing: true`, so a file PyPI already
holds is skipped rather than failing the run.

That matters because **PyPI never lets a filename be reused**. Re-running
the publish against a version that is already up could otherwise only ever
fail, and it is an easy run to start by accident: the version comes from the
tree, not from the dispatch form, so nothing about starting the run tells you
which version it is about to upload.

What it does not do is hide a mistake. Bumping the version is what makes an
upload new; an unbumped one has nothing to publish, and is now skipped
quietly instead of ending the run red. If you expected new files and see
every one skipped, the version was not bumped.

## Version numbers

[Semantic versioning](https://semver.org). For this project specifically:

- **patch** — a bug fix
- **minor** — a new command, a new flag, or a new export overlay
- **major** — a removed or renamed flag, a changed exit code, a changed
  collected-file naming scheme, or a changed `tx export` overlay format

The exit codes, the `tag~host~path` collected-file names, and the `tx export`
results format are the public interface as much as the flags are: people
build scripts, `rm` globs and the datacenter viewer's overlays on them, so a
change there is breaking even when no flag moved.

## Read the Docs

`.readthedocs.yaml` configures the build; importing the repository once on
readthedocs.org is all the setup needed. `ci.yml` builds the same docs with
`-W` (warnings as errors) on every pull request, so a docs break fails the
PR rather than surfacing later on RTD.

The CLI reference is generated from the live argparse parsers during that
build, so a new flag that would render badly also fails CI.
