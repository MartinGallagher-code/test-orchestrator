<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`tx run --batch N` covers a fleet bigger than what can run at once.**
  Some jobs cannot go fleet-wide in one go -- a licence with a seat
  count, a filer with only so much throughput, a power envelope, a test
  fixture that takes twenty machines. The answer is not to give up the
  simultaneity but to narrow what it applies to: each wave of N hosts is
  armed for its own instant and is as simultaneous as any whole-fleet
  run, and the waves march through the fleet in plan order until it is
  used up.

  Everything lands in **one** directory, chosen before the first wave,
  because the point of covering the fleet is to end with one set of
  results for all of it -- the names already carry the host, so a
  hundred hosts' results sit together and still read apart.

  A wave is an ordinary run over a smaller plan, so start, collect and
  clean are the same code a whole-fleet run uses rather than a second
  path that only waves take.

  The report says what fraction of the fleet was reached, and is
  rendered from what each wave recorded while its hosts still held the
  record -- by the end the early waves have been collected and possibly
  cleaned, and polling then would read them as hosts that never
  answered. Hosts a stopped sweep never got to are reported as
  `NOT REACHED`, not counted as passes.

  By default a wave that fails does not stop the sweep: one unreachable
  rack should not cost the other nine their coverage. `--stop-on-fail`
  stops instead.

### Fixed

- **The start spread no longer claims waves were simultaneous with each
  other.** Each host's offset is measured against its *own* wave's
  instant, so in `--batch` mode the figure is how tightly each wave
  began -- reporting it as "spread across N hosts" read as a claim about
  the whole fleet that `--batch` deliberately does not make. It now says
  "within each wave", and names the trade.

- **`SLOW` no longer fires on scheduler noise.** The finding was a bare
  ratio against the median, so a 9ms job against a 6ms median was
  reported as an outlier. Below a one-second median the ratio is not
  measuring the job, and the finding is withheld.

## [1.0.0] - 2026-09-11

First release. `tx` runs one benchmark or test on a whole fleet at once
and brings the results back.

### Added

- **The six commands.** `tx gen` builds `plan.ini` from a server list;
  `tx start` deploys the job and arms every host; `tx status` says what
  each is doing; `tx collect` brings the results back; `tx summarize`
  says who passed and who was slow; `tx clean` removes every trace.
  `tx run` does all of it in one shot, and `tx check`, `tx doctor`,
  `tx stop`, `tx logs` and `tx hints` fill in around them.

- **A start that is simultaneous, and says how simultaneous.** Starting
  forty ssh sessions takes seconds, so `tx start` arms every host with a
  wall-clock instant a few seconds out rather than starting anything.
  Each agent sleeps until then. Because that depends on the fleet's
  clocks agreeing, the deploy measures each host's offset (round-trip
  corrected) and refuses a fleet outside `--max-skew`; every agent
  records the instant it actually began, and `tx summarize` reports the
  spread. Arming that overruns its window is reported rather than
  quietly producing a staggered run, and a fleet that cannot all be
  armed is stood back down rather than left half-started.

- **The job, and everything it needs.** `--payload` is a file or
  directory, packed once and unpacked into the working directory on
  every host. `--setup` runs first -- a host whose setup fails does not
  run the job, because reporting a benchmark failure that was really a
  build failure is a wrong answer rather than a missing one --
  and `--teardown` runs afterwards whether the job passed or not. The
  job is given `TX_OUT`, `TX_HOST`, `TX_INDEX`, `TX_NHOSTS`, `TX_TAG`,
  `TX_RUN_ID`, and `TX_HOSTS` with `--peers`.

- **Results that stay apart.** One directory per collection, flat, with
  the tag leading every name: `bench~web01~out~results.json`. Several
  runs can share a directory and still be told apart. Nothing a remote
  host says is used as a local path, and two files that would fold onto
  one name are reported rather than written over each other. Everything
  under `TX_OUT` comes back, plus each host's stdout, stderr, setup and
  teardown logs and the run's own JSON record; `collect =` globs add
  anything else.

- **Bounds that hold.** Every plan carries a timeout, because a job with
  no bound is a fleet nobody can get back. The agent gives each phase a
  session of its own and kills the whole process group, so a benchmark
  that spawned helpers does not outlive its own timeout -- and `tx stop`
  is forwarded down to the job for the same reason.

- **77 tests** across five bash suites, run against a fake fleet so the
  whole workflow -- deploy, arm, run, collect, stop, clean -- is covered
  without a network or a second machine. CI runs them on Python 3.9
  through 3.13 and under a real Python 3.6, with vermin, shellcheck,
  REUSE and a wheel build.
