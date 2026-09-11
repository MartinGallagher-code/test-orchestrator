#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
#
# Coverage mode: the whole fleet, a few hosts at a time. What has to hold
# is that every host is reached, each wave is still simultaneous in
# itself, and one sweep ends as one set of results.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# A job's command is single-quoted throughout this file on purpose: it has
# to reach the far side unexpanded, so that $TX_OUT means the out
# directory on the host rather than an empty variable in this shell. That
# non-expansion is SC2016's whole warning and is the behaviour under test.
# shellcheck disable=SC2016

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

# A plan whose job records which host ran it. Echoes the plan path.
sweep_plan() {
    plan_for --run 'echo "$TX_HOST" > "$TX_OUT/who"' --tag sweep \
             --timeout 30 -- "$@"
}

# ---- coverage ---------------------------------------------------------------

t_every_host_is_reached_however_the_waves_fall() {
    # The whole promise: the fleet is used up, not sampled.
    install_fake_ssh
    plan="$(sweep_plan a b c d e)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    for h in a b c d e; do
        assert_file_exists "results/sweep~$h~out~who" "$h was never run"
        assert_eq "$h" "$(cat "results/sweep~$h~out~who")"
    done
    assert_contains "$RUN_OUT" "covered 5 of 5 hosts in 3 waves"
}

t_a_fleet_that_does_not_divide_evenly_still_finishes() {
    # Five hosts in waves of two is two full waves and a short one; the
    # remainder is where an off-by-one would drop a host silently.
    install_fake_ssh
    plan="$(sweep_plan a b c d e)"
    run_tx run --plan "$plan" --batch 3 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_eq "5" "$(find results -name 'sweep~*~out~who' | wc -l | tr -d ' ')"
    assert_contains "$RUN_OUT" "in 2 waves"
}

t_a_batch_bigger_than_the_fleet_is_one_wave() {
    install_fake_ssh
    plan="$(sweep_plan a b)"
    run_tx run --plan "$plan" --batch 50 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "in 1 wave of at most 50"
    assert_eq "2" "$(find results -name 'sweep~*~out~who' | wc -l | tr -d ' ')"
}

t_a_batch_of_one_walks_the_fleet() {
    install_fake_ssh
    plan="$(sweep_plan a b c)"
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "in 3 waves"
    assert_eq "3" "$(find results -name 'sweep~*~out~who' | wc -l | tr -d ' ')"
}

t_only_the_wave_is_running_at_any_moment() {
    # The reason coverage mode exists: something cannot take the whole
    # fleet at once. If more than a wave's worth ever ran together the
    # mode would be pointless, so the job records overlap itself.
    install_fake_ssh
    counter="$TEST_TMPDIR/live"
    mkdir -p "$counter"
    plan="$(plan_for --run "touch $counter/\$TX_HOST
ls $counter | wc -l > \"\$TX_OUT/seen\"
sleep 1
rm -f $counter/\$TX_HOST" --tag over --timeout 30 -- a b c d)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    # Each host counted how many were live when it started. With waves of
    # two, nobody should ever have seen three.
    worst="$(cat results/over~*~out~seen | sort -n | tail -1)"
    assert_between 1 2 "$worst" "a host saw $worst hosts running at once"
}

# ---- one sweep, one set of results ------------------------------------------

t_one_sweep_lands_in_one_directory() {
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    # One directory, not one per wave.
    assert_eq "1" "$(find . -maxdepth 1 -type d -name 'results*' | wc -l | tr -d ' ')"
    assert_eq "0" "$(find . -maxdepth 1 -type d -name 'tx-*' | wc -l | tr -d ' ')"
}

t_without_a_name_the_sweep_still_gets_one_directory() {
    # The default is stamped with the time, and a fresh one per wave would
    # scatter a single sweep across several.
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check --quiet
    assert_status 0 "$RUN_RC"
    assert_eq "1" "$(find . -maxdepth 1 -type d -name 'tx-*' | wc -l | tr -d ' ')" \
        "four waves should not make four directories"
    assert_eq "4" "$(find . -name 'sweep~*~out~who' | wc -l | tr -d ' ')"
}

t_the_report_counts_the_whole_fleet_not_the_last_wave() {
    # The final report is rendered from what each wave recorded while it
    # could -- by the end the early waves have been collected and maybe
    # cleaned, and polling then would read them as hosts that never
    # answered.
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --clean --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "4 of 4 hosts finished: 4 passed"
    assert_contains "$RUN_OUT" "covered 4 of 4 hosts"
    # --clean really did remove them, which is what makes the above a
    # statement about the record rather than about the fleet.
    for h in a b c d; do
        assert_no_file "$FAKE_ROOT/$h$TX_REMOTE_DIR" "$h was not cleaned"
    done
}

t_the_spread_does_not_claim_the_waves_were_simultaneous() {
    # Each host's offset is measured against its own wave's instant. The
    # report must not read as though the whole fleet started together,
    # because in wave mode it deliberately did not.
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_contains "$RUN_OUT" "within each wave"
    assert_contains "$RUN_OUT" "not with each other"
    assert_not_contains "$RUN_OUT" "spread 0ms across 4 hosts"
}

# ---- when a wave goes wrong --------------------------------------------------

t_a_failing_job_does_not_stop_the_sweep() {
    # One bad host should not cost the rest of the fleet its coverage.
    install_fake_ssh
    plan="$(plan_for --run 'test "$TX_HOST" != b' --tag t --timeout 30 \
            -- a b c d)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 1 "$RUN_RC" "a failed host is worth an exit code"
    assert_contains "$RUN_OUT" "covered 4 of 4 hosts"
    assert_contains "$RUN_OUT" "FAILED"
    # The wave after the failure still ran.
    assert_file_exists "results/t~d~run.json"
}

t_stop_on_fail_stops_and_says_who_was_never_reached() {
    # Stopping is a choice, and the hosts nobody asked must not read as
    # hosts that passed.
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    # Take the second wave's hosts away so their wave cannot start.
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --stop-on-fail --quiet --no-deploy
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "NOT REACHED"
    assert_contains "$RUN_OUT" "not starting the remaining waves"
}

t_a_wave_that_cannot_start_is_named_not_skipped_silently() {
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --quiet --no-deploy
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "WAVE DID NOT START"
    # Both waves were tried, since --stop-on-fail was not given.
    assert_contains "$RUN_OUT" "wave 2 of 2"
}

# ---- refusals ---------------------------------------------------------------

t_a_wave_size_that_cannot_mean_anything_is_refused() {
    install_fake_ssh
    plan="$(sweep_plan a b)"
    for bad in 0 -3; do
        run_tx run --plan "$plan" --batch "$bad"
        assert_status 2 "$RUN_RC" "--batch $bad should be refused"
        assert_contains "$RUN_OUT" "--batch"
    done
}

t_stop_on_fail_without_waves_is_refused() {
    # Without --batch there is one wave and nothing to stop, so the flag
    # would silently do nothing.
    install_fake_ssh
    plan="$(sweep_plan a b)"
    run_tx run --plan "$plan" --stop-on-fail
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "only one wave"
}

echo "waves"
run_test "every host is reached"               t_every_host_is_reached_however_the_waves_fall
run_test "an uneven fleet still finishes"      t_a_fleet_that_does_not_divide_evenly_still_finishes
run_test "a batch bigger than the fleet"       t_a_batch_bigger_than_the_fleet_is_one_wave
run_test "a batch of one walks the fleet"      t_a_batch_of_one_walks_the_fleet
run_test "only a wave runs at any moment"      t_only_the_wave_is_running_at_any_moment
run_test "one sweep, one directory"            t_one_sweep_lands_in_one_directory
run_test "an unnamed sweep is one directory"   t_without_a_name_the_sweep_still_gets_one_directory
run_test "the report counts the whole fleet"   t_the_report_counts_the_whole_fleet_not_the_last_wave
run_test "the spread does not overclaim"       t_the_spread_does_not_claim_the_waves_were_simultaneous
run_test "a failing job does not stop it"      t_a_failing_job_does_not_stop_the_sweep
run_test "stop-on-fail names the unreached"    t_stop_on_fail_stops_and_says_who_was_never_reached
run_test "a wave that cannot start is named"   t_a_wave_that_cannot_start_is_named_not_skipped_silently
run_test "an impossible wave size"             t_a_wave_size_that_cannot_mean_anything_is_refused
run_test "stop-on-fail needs waves"            t_stop_on_fail_without_waves_is_refused
report_tests
