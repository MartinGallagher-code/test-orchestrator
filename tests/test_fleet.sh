#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
#
# Deploy, the synchronised start, status, stop and clean -- exercised end
# to end against a fake fleet, so the whole workflow is covered without a
# network or a second machine.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# A job's command is single-quoted throughout this file on purpose: it has
# to reach the far side unexpanded, so that $TX_OUT means the out
# directory on the host rather than an empty variable in this shell. That
# non-expansion is SC2016's whole warning and is the behaviour under test.
# shellcheck disable=SC2016

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"


# A fleet with a working payload, ready to start. Echoes the plan path.
#
# It does NOT install the fake ssh: callers use it in a command
# substitution, and a subshell's `export PATH` reaches nobody. Every test
# below calls install_fake_ssh itself, in its own shell, first.
fleet_with_job() {
    mkdir -p bench
    cat > bench/bench.sh <<'SH'
#!/bin/sh
echo "ran on $TX_HOST"
echo "$TX_HOST" > "$TX_OUT/who"
SH
    chmod +x bench/bench.sh
    plan_for --payload ./bench --run ./bench.sh --tag job --timeout 30 -- "$@"
}

# Wait until every host has a finished run record, or give up.
await_fleet() {
    local plan="$1" n="$2" i=0
    while [ "$i" -lt 100 ]; do
        if [ "$(find "$FAKE_ROOT" -name run.json -exec grep -l '"state": "done"' {} + 2>/dev/null | wc -l)" -ge "$n" ]; then
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# ---- deploy ----------------------------------------------------------------

t_the_payload_lands_unpacked_on_every_host() {
    # The deploy is the step that has to work before anything else can:
    # the agent and the payload both have to be there, and the payload
    # has to be *unpacked*, not left as the tarball it travelled in.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC" "start should succeed"
    for h in web01 web02; do
        d="$FAKE_ROOT/$h$TX_REMOTE_DIR"
        assert_file_exists "$d/tx.py" "the agent should be on $h"
        assert_file_exists "$d/bench.sh" "the payload should be unpacked on $h"
        assert_no_file "$d/payload.tar.gz" "the tarball should not be left behind"
    done
}

t_a_payload_keeps_its_shape_and_its_execute_bit() {
    install_fake_ssh
    mkdir -p bench/data
    printf 'x\n' > bench/data/input.txt
    cat > bench/bench.sh <<'SH'
#!/bin/sh
cat data/input.txt > "$TX_OUT/echoed"
SH
    chmod +x bench/bench.sh
    plan="$(plan_for --payload ./bench --run ./bench.sh --timeout 30 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    assert_file_exists "$d/data/input.txt" "a subdirectory should survive"
    [ -x "$d/bench.sh" ] || fail "the payload lost its execute bit"
    await_fleet "$plan" 1 || fail "the job never finished"
    assert_file_exists "$d/out/echoed" "the job should have read its own data"
}

t_a_job_with_no_payload_still_runs() {
    # Nothing to ship is a legitimate run: the job is whatever is already
    # on the hosts.
    install_fake_ssh
    plan="$(plan_for --run 'echo bare > "$TX_OUT/note"' --timeout 30 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC"
    await_fleet "$plan" 1 || fail "the job never finished"
    assert_file_exists "$FAKE_ROOT/web01$TX_REMOTE_DIR/out/note"
}

t_deploying_over_a_running_job_is_refused() {
    # Unpacking a new payload under a job that is still reading the old
    # one is how a run produces results nobody can account for.
    install_fake_ssh
    plan="$(fleet_with_job web01)"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    mkdir -p "$d"
    # A pid that is alive and is not going anywhere.
    sleep 30 & echo $! > "$d/agent.pid"
    holder=$!
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    kill "$holder" 2>/dev/null
    assert_status 1 "$RUN_RC" "start should refuse to deploy over a live job"
    assert_contains "$RUN_OUT" "already running"
}

# ---- the synchronised start ------------------------------------------------

t_every_host_begins_at_the_same_instant() {
    # The whole point of arming rather than starting: each agent waits for
    # a wall-clock instant, so the spread across the fleet is milliseconds
    # rather than however long the ssh fan-out took.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02 web03 web04)"
    run_tx start --plan "$plan" --start-in 2 --no-skew-check
    assert_status 0 "$RUN_RC"
    await_fleet "$plan" 4 || fail "the fleet never finished"
    run_tx summarize --plan "$plan"
    assert_contains "$RUN_OUT" "START     spread"
    # Every host's recorded start must be within a hair of the instant it
    # was armed for. A second would already be too much.
    for h in web01 web02 web03 web04; do
        off="$(python3 -c 'import json,sys; print(abs(json.load(open(sys.argv[1]))["start_offset"]))' \
              "$FAKE_ROOT/$h$TX_REMOTE_DIR/run.json")"
        assert_between 0 0.5 "$off" "$h started $off s off the armed instant"
    done
}

t_the_armed_instant_is_the_same_one_for_everybody() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02 web03)"
    run_tx start --plan "$plan" --start-in 2 --no-skew-check
    assert_status 0 "$RUN_RC"
    await_fleet "$plan" 3 || fail "the fleet never finished"
    armed="$(for h in web01 web02 web03; do
        python3 -c 'import json,sys; print("%.3f" % json.load(open(sys.argv[1]))["armed_for"])' \
            "$FAKE_ROOT/$h$TX_REMOTE_DIR/run.json"
     done | sort -u | wc -l)"
    assert_eq "1" "$(echo "$armed" | tr -d ' ')" \
        "all hosts should be armed for one instant, not one each"
}

t_a_fleet_where_nothing_can_start_reports_it() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02 web03)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check --no-deploy
    # --no-deploy on a fleet where nothing was deployed: no host can
    # start, and the run says so rather than reporting a success.
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "not started on the rest"
}

t_a_fleet_that_cannot_all_be_armed_is_not_half_started() {
    # A run that began on two hosts of three is not a fleet measurement,
    # and leaving those two going would be worse than not starting: they
    # would burn the machines and produce results nobody asked for.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02 web03)"
    # Deploy to all three, then take one host's working directory away,
    # so the next start arms two and fails on the third.
    run_tx start --plan "$plan" --start-in 10 --no-skew-check
    assert_status 0 "$RUN_RC" "the setup start should succeed"
    run_tx stop --plan "$plan"
    rm -rf "$FAKE_ROOT/web03$TX_REMOTE_DIR"
    for h in web01 web02; do
        rm -f "$FAKE_ROOT/$h$TX_REMOTE_DIR/run.json"
    done

    run_tx start --plan "$plan" --start-in 20 --no-skew-check --no-deploy
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "not started on the rest"
    # The two that were armed must have been stood back down: no agent
    # left waiting for an instant that is still twenty seconds away.
    sleep 1
    for h in web01 web02; do
        pidfile="$FAKE_ROOT/$h$TX_REMOTE_DIR/agent.pid"
        assert_no_file "$pidfile" "$h was left armed after the fleet failed"
        # The record exists from the moment the agent starts, so what
        # says the job never ran is the job's own output not being there.
        assert_no_file "$FAKE_ROOT/$h$TX_REMOTE_DIR/out/who" \
            "$h ran the job even though the fleet could not all start"
    done
}

t_arming_that_overruns_its_window_is_reported() {
    # A start window shorter than the fan-out means the last hosts begin
    # late, which is exactly the failure the arming exists to prevent --
    # so it must be said out loud rather than silently tolerated.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    # A shim that takes longer than the window to contact each host.
    cat > "$FAKE_BIN/slowssh" <<'SHIM'
#!/usr/bin/env bash
sleep 1.2
exec ssh "$@"
SHIM
    chmod +x "$FAKE_BIN/slowssh"
    run_tx start --plan "$plan" --start-in 0.5 --no-skew-check \
        --ssh "$FAKE_BIN/slowssh" --jobs 1
    assert_contains "$RUN_OUT" "started late"
}

# ---- clocks ----------------------------------------------------------------

t_a_fleet_whose_clocks_agree_is_started() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    skew_host web01 0
    skew_host web02 0
    run_tx start --plan "$plan" --start-in 1
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "clocks agree"
}

t_a_fleet_whose_clocks_disagree_is_refused() {
    # "At the same instant" means nothing if the instants are not the
    # same, so this is a refusal rather than a warning.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    skew_host web01 0
    skew_host web02 45
    run_tx start --plan "$plan" --start-in 1
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "clocks disagree"
    assert_contains "$RUN_OUT" "web02"
    # And nothing was armed.
    assert_no_file "$FAKE_ROOT/web01$TX_REMOTE_DIR/run.json"
}

t_a_skew_you_have_decided_to_accept_is_accepted() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    skew_host web02 5
    run_tx start --plan "$plan" --start-in 1 --max-skew 30
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "clocks agree"
}

t_the_skew_check_can_be_skipped_entirely() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    skew_host web02 900
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC"
    assert_not_contains "$RUN_OUT" "clocks"
}

# ---- status ----------------------------------------------------------------

t_status_says_what_each_host_is_doing() {
    install_fake_ssh
    plan="$(plan_for --run 'sleep 3' --timeout 30 -- web01 web02)"
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "NOT-DEPLOYED"

    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC"
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "ARMED"

    sleep 2
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "RUNNING"
}

t_status_reports_the_exit_code_of_a_finished_job() {
    install_fake_ssh
    plan="$(plan_for --run 'exit 7' --timeout 30 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    await_fleet "$plan" 1 || fail "the job never finished"
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "FAILED"
    assert_contains "$RUN_OUT" "exit 7"
}

# ---- stop and clean --------------------------------------------------------

t_stop_ends_the_job_and_keeps_what_it_made() {
    install_fake_ssh
    plan="$(plan_for --run 'echo early > "$TX_OUT/note"; sleep 60' --timeout 120 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2
    run_tx stop --plan "$plan"
    assert_status 0 "$RUN_RC"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    assert_file_exists "$d/out/note" "stop must not delete the results"
    assert_no_file "$d/agent.pid" "the pid file should be gone"
}

t_stop_takes_the_jobs_children_with_it() {
    # A benchmark is almost always a script that starts other things.
    # Killing only the agent leaves the machine still working, and the
    # files we are about to collect still being written.
    install_fake_ssh
    marker="$TEST_TMPDIR/still-alive"
    plan="$(plan_for --run "sh -c 'while true; do touch $marker; sleep 0.2; done' &
sleep 60" --timeout 120 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2
    [ -f "$marker" ] || fail "the grandchild never started; the test proves nothing"
    run_tx stop --plan "$plan"
    rm -f "$marker"
    sleep 1.5
    assert_no_file "$marker" "a grandchild of the job outlived the stop"
}

t_clean_leaves_nothing_behind() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    await_fleet "$plan" 2 || fail "the fleet never finished"
    run_tx clean --plan "$plan" --yes
    assert_status 0 "$RUN_RC"
    for h in web01 web02; do
        assert_no_file "$FAKE_ROOT/$h$TX_REMOTE_DIR" \
            "$h should have nothing left"
    done
    assert_contains "$RUN_OUT" "nothing of tx remains"
}

t_clean_asks_before_deleting_anything() {
    install_fake_ssh
    plan="$(fleet_with_job web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    await_fleet "$plan" 1 || fail "the job never finished"
    # No --yes and nothing on stdin: the prompt gets EOF and must refuse.
    RUN_OUT="$(python3 "$TX" clean --plan "$plan" < /dev/null 2>&1)"
    RUN_RC=$?
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "nothing done"
    assert_file_exists "$FAKE_ROOT/web01$TX_REMOTE_DIR/run.json"
}

t_a_dry_run_contacts_nothing() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    : > "$FAKE_ROOT/calls.log"
    run_tx start --plan "$plan" --dry-run
    assert_eq "0" "$(wc -l < "$FAKE_ROOT/calls.log" | tr -d ' ')" \
        "--dry-run should not touch the fleet"
}

echo "fleet"
run_test "the payload lands unpacked"          t_the_payload_lands_unpacked_on_every_host
run_test "a payload keeps its shape"           t_a_payload_keeps_its_shape_and_its_execute_bit
run_test "a job with no payload still runs"    t_a_job_with_no_payload_still_runs
run_test "deploying over a running job"        t_deploying_over_a_running_job_is_refused
run_test "every host begins together"          t_every_host_begins_at_the_same_instant
run_test "one instant, not one each"           t_the_armed_instant_is_the_same_one_for_everybody
run_test "a fleet with no starter reports it"  t_a_fleet_where_nothing_can_start_reports_it
run_test "a fleet is not half started"         t_a_fleet_that_cannot_all_be_armed_is_not_half_started
run_test "arming that overruns is reported"    t_arming_that_overruns_its_window_is_reported
run_test "agreeing clocks are started"         t_a_fleet_whose_clocks_agree_is_started
run_test "disagreeing clocks are refused"      t_a_fleet_whose_clocks_disagree_is_refused
run_test "a skew you accept is accepted"       t_a_skew_you_have_decided_to_accept_is_accepted
run_test "the skew check can be skipped"       t_the_skew_check_can_be_skipped_entirely
run_test "status says what each host does"     t_status_says_what_each_host_is_doing
run_test "status reports the exit code"        t_status_reports_the_exit_code_of_a_finished_job
run_test "stop keeps what the job made"        t_stop_ends_the_job_and_keeps_what_it_made
run_test "stop takes the children too"         t_stop_takes_the_jobs_children_with_it
run_test "clean leaves nothing behind"         t_clean_leaves_nothing_behind
run_test "clean asks first"                    t_clean_asks_before_deleting_anything
run_test "a dry run contacts nothing"          t_a_dry_run_contacts_nothing
report_tests
