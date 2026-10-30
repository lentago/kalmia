#!/bin/bash
# ============================================================================
# pe-publish-job-guard — runs roles/pe_publish's job-started hook under fake
# runner process trees, and checks that every refusal stops the job, also when
# the hook finds no Runner.Worker above itself (#206).
#
#   tests/pe-publish-job-guard.sh             render the guard, then run the
#                                             cases as root (sudo) in a fresh
#                                             PID namespace
#   tests/pe-publish-job-guard.sh render OUT  render the guard to OUT
#   tests/pe-publish-job-guard.sh run GUARD   run the cases; only as root and
#                                             PID 1 of a fresh PID namespace
#
# The guard is rendered from the role's defaults with the runner user set to
# test_uid, and every fake runner process runs as that uid. The PID namespace
# keeps the fallback's pkill off the host's processes. Rendering needs
# ansible; running needs root, unshare, setpriv and procps. CI runs it from
# .github/workflows/pe-publish-guard.yml. Elsewhere, a container works:
#
#   tests/pe-publish-job-guard.sh render /tmp/guard.sh
#   docker run --rm -v "$PWD/tests:/t:ro" -v /tmp/guard.sh:/guard.sh:ro debian:12 sh -c \
#     'apt-get -qq update && apt-get -qq install procps >/dev/null && exec /t/pe-publish-job-guard.sh run /guard.sh'
# ============================================================================
set -uo pipefail

test_uid=4242
# What the role's defaults allow.
repo=cpitzi/professional-endeavors
workflow_ref=$repo/.github/workflows/publish.yml@refs/heads/main

die() {
    echo "pe-publish-job-guard test: $*" >&2
    exit 2
}

render() {
    local root out
    root=$(cd "$(dirname "$0")/.." && pwd) || die "can't find the repo root"
    out=$(ansible all -i localhost, -c local -m ansible.builtin.template \
        -a "src=$root/roles/pe_publish/templates/pe-publish-job-guard.sh.j2 dest=$1 mode=0755" \
        -e "@$root/roles/pe_publish/defaults/main.yml" \
        -e "pe_publish_runner_user=$test_uid" 2>&1) || {
        echo "$out" >&2
        die "rendering the guard failed"
    }
}

# --- the fake runner, run as test_uid --------------------------------------

# A Runner.Listener whose worker runs the job.
listener() {
    printf Runner.Listener > "/proc/$$/comm"
    "$0" worker "$@"
    exit $?
}

# A worker named $2 runs the guard with the github context in ${@:3}, the
# way the runner starts a hook, then a post step (an `if: always()` step):
# a hook that only fails the job still lets that run. Like the real worker, a
# SIGTERM cancels the running hook (SIGINT, SIGTERM, then SIGKILL) and ends
# the job without running anything else.
worker() {
    local work=$1 name=$2
    shift 2
    printf %s "$name" > "/proc/$$/comm"
    trap 'touch "$work/worker-term"
          kill -INT "$hook" 2>/dev/null; sleep 0.2
          kill -TERM "$hook" 2>/dev/null; sleep 0.2
          kill -KILL "$hook" 2>/dev/null; exit 143' TERM
    env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@" \
        bash --noprofile --norc -e -o pipefail "$work/guard.sh" > "$work/guard.out" 2>&1 &
    hook=$!
    wait "$hook"
    echo $? > "$work/guard.rc"
    touch "$work/post-step"
}

# --- the cases, run as root ------------------------------------------------

# Runs one job under a worker named $1 with the github context in ${@:2}.
job() {
    pkill -KILL -U "$test_uid"
    rm -f "$work"/{guard.out,guard.rc,post-step,worker-term}
    # wait's stderr is where the shell reports the fallback's SIGKILL.
    timeout -s KILL 60 setpriv --reuid="$test_uid" --regid="$test_uid" --clear-groups \
        "$work/tree.sh" listener "$work" "$@" &
    wait $! 2>/dev/null
}

# No process of test_uid is left, zombies aside. SIGKILL lands at once, but
# exiting takes a moment.
runner_gone() {
    local _
    for _ in {1..20}; do
        ps -eo uid=,stat= | awk -v uid="$test_uid" '$1 == uid && $2 !~ /^Z/ { n++ } END { exit n > 0 }' &&
            return 0
        sleep 0.1
    done
    return 1
}

allowed_job() {
    [[ $(cat "$work/guard.rc" 2>/dev/null) == 0 && -e $work/post-step && ! -e $work/worker-term ]]
}

stopped_job() {
    [[ ! -e $work/post-step && -e $work/worker-term ]] && grep -q Refused "$work/guard.out"
}

# No worker to stop: everything the runner user ran is gone, and nothing else.
runner_killed() {
    [[ ! -e $work/post-step ]] && grep -q Refused "$work/guard.out" &&
        runner_gone && kill -0 "$bystander" 2>/dev/null
}

fails=0
check() {
    local what=$1
    shift
    if "$@"; then
        echo "ok - $what"
    else
        echo "not ok - $what"
        sed 's/^/#   /' "$work/guard.out" 2>/dev/null
        fails=$((fails + 1))
    fi
}

run() {
    (( EUID == 0 )) || die "run needs root, to run the fake runner as uid $test_uid"
    # The fallback kills every process of test_uid that /proc lists, so make
    # sure /proc is this namespace's own.
    [[ $$ == 1 && /proc/self -ef /proc/1 ]] ||
        die "run only as PID 1 of a fresh PID namespace (unshare --pid --fork --mount-proc)"

    work=$(mktemp -d) || die "can't make a work directory"
    chown "$test_uid:$test_uid" "$work" || die "can't hand $work to uid $test_uid"
    install -m 0755 "$1" "$work/guard.sh"
    install -m 0755 "$0" "$work/tree.sh"
    sleep 300 &
    bystander=$!

    local main=(GITHUB_REPOSITORY="$repo" GITHUB_REF=refs/heads/main GITHUB_WORKFLOW_REF="$workflow_ref")
    local branch=(GITHUB_REPOSITORY="$repo" GITHUB_REF=refs/heads/topic
        GITHUB_WORKFLOW_REF="$repo/.github/workflows/publish.yml@refs/heads/topic" GITHUB_EVENT_NAME=push)
    local event

    for event in push workflow_dispatch; do
        job Runner.Worker "${main[@]}" GITHUB_EVENT_NAME="$event"
        check "publish.yml on main, $event: allowed" allowed_job
    done

    for event in pull_request_target schedule workflow_run pull_request; do
        job Runner.Worker "${main[@]}" GITHUB_EVENT_NAME="$event"
        check "publish.yml on main, $event: worker stopped" stopped_job
    done
    job Runner.Worker "${main[@]}"
    check "publish.yml on main, no event: worker stopped" stopped_job

    job Runner.Worker "${branch[@]}"
    check "publish.yml on a branch: worker stopped" stopped_job

    job Runner.Worker GITHUB_REPOSITORY="$repo" GITHUB_REF=refs/heads/main \
        GITHUB_WORKFLOW_REF="$repo/.github/workflows/other.yml@refs/heads/main" GITHUB_EVENT_NAME=push
    check "another workflow on main: worker stopped" stopped_job

    # A runner release that renames the worker.
    job dotnet "${main[@]}" GITHUB_EVENT_NAME=push
    check "no Runner.Worker, allowed job: allowed" allowed_job
    job dotnet "${branch[@]}"
    check "no Runner.Worker, refused job: every runner process killed" runner_killed

    pkill -KILL -U "$test_uid"
    kill "$bystander"
    rm -rf "$work"
    (( fails == 0 ))
}

main() {
    local tmp rc self
    self=$(realpath "$0")
    tmp=$(mktemp -d) || die "mktemp failed"
    render "$tmp/guard.sh"
    if (( EUID == 0 )); then
        unshare --pid --fork --mount-proc --kill-child "$self" run "$tmp/guard.sh"
    else
        sudo unshare --pid --fork --mount-proc --kill-child "$self" run "$tmp/guard.sh"
    fi
    rc=$?
    rm -rf "$tmp"
    return $rc
}

case ${1:-} in
    '') main ;;
    render) render "${2:?render OUT}" ;;
    run) run "${2:?run GUARD}" ;;
    listener) shift; listener "$@" ;;
    worker) shift; worker "$@" ;;
    *) die "usage: $0 [render OUT | run GUARD]" ;;
esac
