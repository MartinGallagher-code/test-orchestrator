# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Sphinx configuration for test_orchestrator.

Two principles, both anti-drift:

- The prose pages *include* the repository's own markdown (README,
  CHANGELOG, PUBLISHING) rather than duplicating it, so there is one
  copy of every sentence.
- The CLI reference is generated at build time from the real argparse
  parsers -- the same trick `tx help` uses -- so a flag cannot exist
  without being documented here, nor linger here after it is removed.
"""

import os
import sys

DOCS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(DOCS_DIR)
sys.path.insert(0, REPO_ROOT)

from test_orchestrator import tx  # noqa: E402

project = "test-orchestrator"
author = "Martin J. Gallagher"
copyright = "2026, Martin J. Gallagher"  # noqa: A001 - sphinx's name for it
version = tx.VERSION
release = tx.VERSION

extensions = ["myst_parser"]
myst_enable_extensions = ["colon_fence"]
myst_heading_anchors = 3

source_suffix = {".md": "markdown", ".rst": "restructuredtext"}
master_doc = "index"
exclude_patterns = ["_build"]

html_theme = "sphinx_rtd_theme"
html_title = "test-orchestrator %s" % tx.VERSION
html_theme_options = {"collapse_navigation": False}

# The included README carries repo-relative links (LICENSE, tests/...)
# that have no docs-site counterpart; MyST flags them as xref warnings.
# They are correct where the file lives, so quieten just that class.
suppress_warnings = ["myst.xref_missing"]


def _generate_cli_reference():
    """Write cli.md from the live parsers: one section per command, its
    real --help text in a literal block. Runs on every build."""
    ap = tx.build_parser()
    sub = next(a for a in ap._actions
               if isinstance(a, tx.argparse._SubParsersAction))
    out = [
        "# CLI reference",
        "",
        "Generated from the argparse parsers at build time -- this page",
        "cannot drift from what the tool accepts. The same reference is",
        "available offline as `tx help`.",
        "",
    ]
    for name, parser in sub.choices.items():
        if name == "help":
            continue
        out.append("## tx %s" % name)
        out.append("")
        out.append("```text")
        out.append(parser.format_help().rstrip())
        out.append("```")
        out.append("")
    out += [
        "## Environment variables",
        "",
        "Each is the default for the matching flag:",
        "`TX_PLAN`, `TX_SERVERS`, `TX_REMOTE_DIR`, `TX_DIR`,",
        "`TX_USER` (falls back to `SSH_USER`), `TX_JOBS`, `TX_PYTHON`.",
        "",
        "## The job's environment",
        "",
        "Every job runs under bash in the working directory with",
        "`TX_OUT` (where results go, collected in full), `TX_HOST`,",
        "`TX_INDEX`, `TX_NHOSTS`, `TX_TAG`, `TX_RUN_ID`, and `TX_HOSTS`",
        "when `--peers` is given.",
        "",
    ]
    path = os.path.join(DOCS_DIR, "cli.md")
    with open(path, "w") as f:
        f.write("\n".join(out))


_generate_cli_reference()
