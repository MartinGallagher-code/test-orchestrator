# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""`python -m testing_orchestrator` runs the same tool `tx` does."""

import sys

from .tx import main

if __name__ == "__main__":
    sys.exit(main())
