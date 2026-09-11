#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
#
# Collection: one directory, names that tell the files apart, and nothing
# a host says ever used as a local path. This is the half of the tool the
# results actually come out of, so its naming is a contract.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# A job's command is single-quoted throughout this file on purpose: it has
# to reach the far side unexpanded, so that $TX_OUT means the out
# directory on the host rather than an empty variable in this shell. That
# non-expansion is SC2016's whole warning and is the behaviour under test.
# shellcheck disable=SC2016

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"


# Run a job to completion on the named hosts. Echoes the plan path.
ran_job() {
    local flags=() hosts=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --) shift; break ;;
            *) flags+=("$1"); shift ;;
        esac
    done
    hosts=("$@")
    local plan
    plan="$(plan_for "${flags[@]}" -- "${hosts[@]}")" || return 1
    python3 "$TX" start --plan "$plan" --start-in 1 --no-skew-check \
        > /dev/null || return 1
    local i=0
    while [ "$i" -lt 150 ]; do
        if [ "$(find "$FAKE_ROOT" -name run.json -exec grep -l '"state": "done"' {} + 2>/dev/null | wc -l)" -ge "${#hosts[@]}" ]; then
            echo "$plan"
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# ---- naming ----------------------------------------------------------------

t_the_tag_leads_then_the_host_then_the_path() {
    # The order is the contract: `ls` groups a directory by run, and
    # `rm bench~*` clears one of them.
    install_fake_ssh
    plan="$(ran_job --run 'echo hi > "$TX_OUT/result.json"' --tag bench \
            --timeout 30 -- web01 web02)" || fail "the fleet never finished"
    run_tx collect --plan "$plan" -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_file_exists "results/bench~web01~out~result.json"
    assert_file_exists "results/bench~web02~out~result.json"
    assert_eq "hi" "$(cat results/bench~web01~out~result.json)"
}

t_a_nested_result_folds_into_its_name() {
    # Rebuilding each host's tree reads well and greps badly; the command
    # you want next is `grep -l FAIL *`.
    install_fake_ssh
    plan="$(ran_job --run 'mkdir -p "$TX_OUT/a/b" && echo deep > "$TX_OUT/a/b/c.txt"' \
            --tag t --timeout 30 -- web01)" || fail "the fleet never finished"
    run_tx collect --plan "$plan" -d results --quiet
    assert_file_exists "results/t~web01~out~a~b~c.txt"
    assert_eq "1" "$(find results -type d | wc -l | tr -d ' ')" \
        "the collection should be one flat directory"
}

t_the_runs_own_record_always_comes_back() {
    install_fake_ssh
    plan="$(ran_job --run 'echo noise' --tag t --timeout 30 -- web01)" \
        || fail "the fleet never finished"
    run_tx collect --plan "$plan" -d results --quiet
    assert_file_exists "results/t~web01~run.json"
    assert_file_exists "results/t~web01~stdout"
    assert_file_exists "results/t~web01~stderr"
    assert_eq "noise" "$(cat results/t~web01~stdout)"
}

t_two_runs_can_share_one_directory() {
    install_fake_ssh
    plan="$(ran_job --run 'echo before > "$TX_OUT/n"' --tag before --timeout 30 -- web01)" \
        || fail "the first run never finished"
    run_tx collect --plan "$plan" -d shared --quiet
    run_tx clean --plan "$plan" --yes > /dev/null

    plan="$(ran_job --run 'echo after > "$TX_OUT/n"' --tag after --timeout 30 -- web01)" \
        || fail "the second run never finished"
    run_tx collect --plan "$plan" -d shared --quiet
    assert_file_exists "shared/before~web01~out~n"
    assert_file_exists "shared/after~web01~out~n"
    assert_eq "before" "$(cat shared/before~web01~out~n)"
    assert_eq "after" "$(cat shared/after~web01~out~n)"
}

t_without_a_directory_each_collection_gets_its_own() {
    # Collecting the same job twice an hour apart is the normal way to use
    # this, and the second quietly replacing the first is not a result
    # anybody wants to find later.
    install_fake_ssh
    plan="$(ran_job --run 'echo x > "$TX_OUT/n"' --timeout 30 -- web01)" \
        || fail "the fleet never finished"
    run_tx collect --plan "$plan" --quiet
    assert_status 0 "$RUN_RC"
    assert_eq "1" "$(find . -maxdepth 1 -type d -name 'tx-*' | wc -l | tr -d ' ')"
    run_tx collect --plan "$plan" --quiet
    assert_eq "2" "$(find . -maxdepth 1 -type d -name 'tx-*' | wc -l | tr -d ' ')" \
        "a second collection must not land on top of the first"
}

# ---- what comes back --------------------------------------------------------

t_extra_globs_are_collected_too() {
    install_fake_ssh
    plan="$(ran_job --run 'echo a > side.csv; echo b > other.log' --tag t \
            --collect '*.csv' --timeout 30 -- web01)" \
        || fail "the fleet never finished"
    run_tx collect --plan "$plan" -d results --quiet
    assert_file_exists "results/t~web01~side.csv"
    assert_no_file "results/t~web01~other.log" \
        "only what was asked for, beyond out/ and the record"
}

t_a_glob_that_matches_nothing_is_not_an_error() {
    install_fake_ssh
    plan="$(ran_job --run 'echo x > "$TX_OUT/n"' --tag t --collect '*.nope' \
            --timeout 30 -- web01)" || fail "the fleet never finished"
    run_tx collect --plan "$plan" -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_file_exists "results/t~web01~out~n"
    assert_no_file "results/t~web01~*.nope"
}

t_binary_results_survive_the_trip() {
    install_fake_ssh
    plan="$(ran_job --run 'head -c 4096 /dev/urandom > "$TX_OUT/blob"' --tag t \
            --timeout 30 -- web01)" || fail "the fleet never finished"
    run_tx collect --plan "$plan" -d results --quiet
    cmp -s "$FAKE_ROOT/web01$TX_REMOTE_DIR/out/blob" "results/t~web01~out~blob" \
        || fail "the bytes did not survive the collection"
}

t_a_host_that_produced_nothing_is_named() {
    install_fake_ssh
    plan="$(ran_job --run 'true' --tag t --timeout 30 -- web01 web02)" \
        || fail "the fleet never finished"
    # Take one host's whole working directory away, the way an unreachable
    # or wiped host would look.
    rm -rf "$FAKE_ROOT/web02$TX_REMOTE_DIR"
    run_tx collect --plan "$plan" -d results
    assert_status 1 "$RUN_RC" "a partial collection is worth an exit code"
    assert_contains "$RUN_OUT" "web02"
    assert_contains "$RUN_OUT" "FAILED"
    # The host that did answer was still collected.
    assert_file_exists "results/t~web01~run.json"
}

t_an_empty_collection_is_an_exit_code() {
    # A script that fans out to gather results and gathers none should
    # stop, not carry on with an empty directory.
    install_fake_ssh
    plan="$(plan_for --run true --timeout 30 -- web01)"
    run_tx collect --plan "$plan" -d results
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "0 files"
}

# ---- safety -----------------------------------------------------------------

t_nothing_a_host_says_becomes_a_local_path() {
    # Names are rebuilt here from the host name and the path within its
    # working directory, so a host answering with ../../etc/cron.d/x
    # writes inside the collection directory or not at all.
    install_fake_ssh
    plan="$(plan_for --run true --tag tx --timeout 30 -- web01)"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    mkdir -p "$d/out"
    echo '{"state": "done", "exit": 0}' > "$d/run.json"
    : > "$d/stdout"; : > "$d/stderr"
    # A tar naming a path outside the tree, as a hostile or broken host
    # would send.
    mkdir -p "$TEST_TMPDIR/evil/a/b"
    echo pwned > "$TEST_TMPDIR/evil/a/b/escape"
    tar cf "$d/out/evil.tar" -C "$TEST_TMPDIR/evil" a/b/escape
    cat > "$FAKE_BIN/eviltar" <<SHIM
#!/usr/bin/env bash
# Answers any collection with a tar whose member names climb out.
cat "$d/out/evil.tar" | python3 -c '
import sys, tarfile, io
src = tarfile.open(fileobj=io.BytesIO(sys.stdin.buffer.read()), mode="r|")
buf = io.BytesIO()
out = tarfile.open(fileobj=buf, mode="w")
for m in src:
    data = src.extractfile(m).read()
    m.name = "../../../../tmp/escaped-by-tx"
    m.size = len(data)
    out.addfile(m, io.BytesIO(data))
out.close()
sys.stdout.buffer.write(buf.getvalue())
'
SHIM
    chmod +x "$FAKE_BIN/eviltar"
    run_tx collect --plan "$plan" -d results --ssh "$FAKE_BIN/eviltar" --quiet
    assert_no_file "/tmp/escaped-by-tx" "a remote name escaped the collection directory"
    assert_file_exists "results/tx~web01~tmp~escaped-by-tx" \
        "the climbing segments should be stripped, not the file dropped"
}

t_two_files_folding_onto_one_name_are_caught() {
    # A file quietly replacing another looks exactly like a successful
    # collection, which is why this is reported rather than tolerated.
    install_fake_ssh
    plan="$(plan_for --run true --tag tx --timeout 30 -- web01)"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    mkdir -p "$d/out/a~b" "$d/out/a/b"
    echo first > "$d/out/a~b/c"
    echo second > "$d/out/a/b/c"
    echo '{"state": "done", "exit": 0}' > "$d/run.json"
    run_tx collect --plan "$plan" -d results
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "COLLISION"
    # Whichever arrived first is intact; the other was not written over it.
    assert_eq "1" "$(find results -name 'tx~web01~out~a~b~c' | wc -l | tr -d ' ')"
}

t_a_dry_run_prints_the_command_and_contacts_nothing() {
    install_fake_ssh
    plan="$(plan_for --run true --timeout 30 -- web01 web02)"
    : > "$FAKE_ROOT/calls.log"
    run_tx collect --plan "$plan" --dry-run
    assert_contains "$RUN_OUT" "tar cf"
    assert_eq "0" "$(wc -l < "$FAKE_ROOT/calls.log" | tr -d ' ')"
}

t_csv_carries_a_row_per_file() {
    install_fake_ssh
    plan="$(ran_job --run 'echo x > "$TX_OUT/n"' --tag t --timeout 30 -- web01)" \
        || fail "the fleet never finished"
    run_tx collect --plan "$plan" -d results --csv c.csv --quiet
    assert_eq "host,local_path,bytes" "$(head -1 c.csv)"
    assert_contains "$(cat c.csv)" "web01,results/t~web01~out~n"
}

echo "collect"
run_test "tag, then host, then path"           t_the_tag_leads_then_the_host_then_the_path
run_test "a nested result folds into a name"   t_a_nested_result_folds_into_its_name
run_test "the run record always comes back"    t_the_runs_own_record_always_comes_back
run_test "two runs can share a directory"      t_two_runs_can_share_one_directory
run_test "each collection gets its own dir"    t_without_a_directory_each_collection_gets_its_own
run_test "extra globs are collected"           t_extra_globs_are_collected_too
run_test "a glob matching nothing is fine"     t_a_glob_that_matches_nothing_is_not_an_error
run_test "binary results survive"              t_binary_results_survive_the_trip
run_test "a host with nothing is named"        t_a_host_that_produced_nothing_is_named
run_test "an empty collection exits 1"         t_an_empty_collection_is_an_exit_code
run_test "no remote name becomes a path"       t_nothing_a_host_says_becomes_a_local_path
run_test "two files on one name are caught"    t_two_files_folding_onto_one_name_are_caught
run_test "a dry run contacts nothing"          t_a_dry_run_prints_the_command_and_contacts_nothing
run_test "csv carries a row per file"          t_csv_carries_a_row_per_file
report_tests
