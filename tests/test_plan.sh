#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# The plan file: what `tx gen` writes, and what every other command reads
# back out of it. Everything the run needs lives here, so a plan that
# loads wrong is a run that is wrong on every host at once.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# A job's command is single-quoted throughout this file on purpose: it has
# to reach the far side unexpanded, so that $TX_OUT means the out
# directory on the host rather than an empty variable in this shell. That
# non-expansion is SC2016's whole warning and is the behaviour under test.
# shellcheck disable=SC2016

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"


# ---- generating ------------------------------------------------------------

t_gen_writes_a_plan_every_command_can_read() {
    servers="$(write_servers web01 web02 web03)"
    run_tx gen --servers "$servers" --plan plan.ini --run './bench.sh'
    assert_status 0 "$RUN_RC" "gen should succeed"
    assert_file_exists plan.ini
    run_tx check --plan plan.ini
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "3 hosts"
    assert_contains "$RUN_OUT" "./bench.sh"
}

t_a_host_list_takes_names_and_addresses() {
    printf 'web01=10.0.0.1\nweb02\n# a comment\n\ndb01=10.0.0.9\n' > s.txt
    run_tx gen --servers s.txt --plan plan.ini --run true
    assert_status 0 "$RUN_RC"
    got="$(cat plan.ini)"
    assert_contains "$got" "web01 = 10.0.0.1"
    # A bare token is its own address.
    assert_contains "$got" "web02 = web02"
    assert_contains "$got" "db01 = 10.0.0.9"
    assert_not_contains "$got" "a comment"
}

t_reachables_output_pipes_straight_in() {
    # `reachable` prints "host  OK  1.2ms"; taking the first field means
    # its output is a server list without anybody editing it.
    printf 'web01  OK   1.2ms\nweb02  OK   0.9ms\n' > s.txt
    run_tx gen --servers s.txt --plan plan.ini --run true
    assert_status 0 "$RUN_RC"
    assert_contains "$(cat plan.ini)" "web01 = web01"
    assert_not_contains "$(cat plan.ini)" "1.2ms"
}

t_a_host_listed_twice_is_refused() {
    # Both copies would write their results under the same name, so the
    # second would land on top of the first and only for the files they
    # had in common.
    printf 'web01\nweb02\nweb01\n' > s.txt
    run_tx gen --servers s.txt --plan plan.ini --run true
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "listed twice"
}

t_a_job_with_nothing_to_run_is_refused() {
    servers="$(write_servers web01)"
    run_tx gen --servers "$servers" --plan plan.ini
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "--run"
}

t_the_tag_defaults_to_the_commands_own_name() {
    servers="$(write_servers web01)"
    run_tx gen --servers "$servers" --plan plan.ini --run '/opt/fio/fio-seq.sh --size 1M'
    assert_status 0 "$RUN_RC"
    assert_contains "$(cat plan.ini)" "tag = fio-seq.sh"
}

t_a_tag_cannot_smuggle_a_path_into_a_filename() {
    # The tag leads every collected name and is the one part the caller
    # writes freely, so it is the one part that could mean a directory.
    servers="$(write_servers web01)"
    run_tx gen --servers "$servers" --plan plan.ini --run true --tag 'a/b c:d'
    assert_status 0 "$RUN_RC"
    assert_contains "$(cat plan.ini)" "tag = a-b-c-d"
}

t_a_missing_payload_is_caught_at_gen_time() {
    servers="$(write_servers web01)"
    run_tx gen --servers "$servers" --plan plan.ini --run true --payload ./nope
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "does not exist"
}

t_a_plan_can_be_written_to_stdout() {
    servers="$(write_servers web01 web02)"
    run_tx gen --servers "$servers" --plan - --run 'echo hi'
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "[hosts]"
    assert_no_file plan.ini
}

# ---- reading back ----------------------------------------------------------

t_a_missing_plan_says_how_to_make_one() {
    run_tx check --plan nope.ini
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "tx gen"
}

t_an_unknown_key_is_a_typo_not_a_silent_default() {
    # A misspelled `timeout` that were quietly ignored would give every
    # host the default bound, which is exactly the kind of thing nobody
    # notices until a run has to be thrown away.
    cat > plan.ini <<'EOF'
[job]
run = true
timout = 5
[hosts]
web01 = web01
EOF
    run_tx check --plan plan.ini
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "unknown key"
    assert_contains "$RUN_OUT" "timout"
}

t_a_plan_with_no_command_is_refused() {
    cat > plan.ini <<'EOF'
[job]
run =
[hosts]
web01 = web01
EOF
    run_tx check --plan plan.ini
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "nothing to run"
}

t_a_plan_with_no_hosts_is_refused() {
    cat > plan.ini <<'EOF'
[job]
run = true
[hosts]
EOF
    run_tx check --plan plan.ini
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "empty"
}

t_a_timeout_that_cannot_mean_anything_is_refused() {
    # A job with no bound is a fleet nobody can get back.
    for bad in 0 -5; do
        cat > plan.ini <<EOF
[job]
run = true
timeout = $bad
[hosts]
web01 = web01
EOF
        run_tx check --plan plan.ini
        assert_status 2 "$RUN_RC" "timeout=$bad should be refused"
        assert_contains "$RUN_OUT" "timeout"
    done
    cat > plan.ini <<'EOF'
[job]
run = true
timeout = later
[hosts]
web01 = web01
EOF
    run_tx check --plan plan.ini
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "bad timeout"
}

t_a_command_survives_the_round_trip_through_the_plan() {
    # The plan is the only place the command lives between gen and start,
    # so anything it loses is lost on every host.
    servers="$(write_servers web01)"
    cmd='./bench.sh --name "a b" --pat '"'"'x$y'"'"' --n 5'
    run_tx gen --servers "$servers" --plan plan.ini --run "$cmd"
    assert_status 0 "$RUN_RC"
    run_tx check --plan plan.ini
    assert_contains "$RUN_OUT" "$cmd"
}

# ---- check -----------------------------------------------------------------

t_check_catches_a_command_the_payload_does_not_carry() {
    # The most common way a fleet run fails on all forty hosts at once.
    mkdir -p bench && : > bench/other.sh
    servers="$(write_servers web01 web02)"
    run_tx gen --servers "$servers" --plan plan.ini --payload ./bench --run ./bench.sh
    run_tx check --plan plan.ini
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "not in the payload"
}

t_check_sizes_the_payload_against_the_fleet() {
    mkdir -p bench
    head -c 4096 /dev/zero > bench/data.bin
    : > bench/bench.sh
    servers="$(write_servers web01 web02 web03 web04)"
    run_tx gen --servers "$servers" --plan plan.ini --payload ./bench --run ./bench.sh
    run_tx check --plan plan.ini
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "2 file(s)"
    assert_contains "$RUN_OUT" "over the fleet"
}

t_check_contacts_nothing() {
    # It is the thing you run before committing to a long run, so it must
    # not depend on a single host being up.
    install_fake_ssh
    servers="$(write_servers web01 web02)"
    run_tx gen --servers "$servers" --plan plan.ini --run 'echo hi'
    : > "$FAKE_ROOT/calls.log"
    run_tx check --plan plan.ini
    assert_status 0 "$RUN_RC"
    assert_eq "0" "$(wc -l < "$FAKE_ROOT/calls.log" | tr -d ' ')" \
        "check should make no ssh or scp calls"
}

echo "plan"
run_test "gen writes a readable plan"          t_gen_writes_a_plan_every_command_can_read
run_test "names and addresses both work"       t_a_host_list_takes_names_and_addresses
run_test "reachable's output pipes in"         t_reachables_output_pipes_straight_in
run_test "a host listed twice is refused"      t_a_host_listed_twice_is_refused
run_test "a job with nothing to run"           t_a_job_with_nothing_to_run_is_refused
run_test "the tag defaults to the command"     t_the_tag_defaults_to_the_commands_own_name
run_test "a tag cannot smuggle a path"         t_a_tag_cannot_smuggle_a_path_into_a_filename
run_test "a missing payload is caught early"   t_a_missing_payload_is_caught_at_gen_time
run_test "a plan can go to stdout"             t_a_plan_can_be_written_to_stdout
run_test "a missing plan says how to make one" t_a_missing_plan_says_how_to_make_one
run_test "an unknown key is a typo"            t_an_unknown_key_is_a_typo_not_a_silent_default
run_test "a plan with no command"              t_a_plan_with_no_command_is_refused
run_test "a plan with no hosts"                t_a_plan_with_no_hosts_is_refused
run_test "impossible timeouts are refused"     t_a_timeout_that_cannot_mean_anything_is_refused
run_test "a command survives the round trip"   t_a_command_survives_the_round_trip_through_the_plan
run_test "check catches a missing command"     t_check_catches_a_command_the_payload_does_not_carry
run_test "check sizes the payload"             t_check_sizes_the_payload_against_the_fleet
run_test "check contacts nothing"              t_check_contacts_nothing
report_tests
