#!/bin/bash
# Archive the finished sets of a run of master on the `benchmark-results` branch of CLONE, a
# clone of this repository that may push that branch. Run on the web server after a master job,
# never on the benchmark machine, and it never runs benchmarked code.
#
#     archive.sh LIVE_FOLDER CLONE          # ARCHIVE_DRY_RUN=1 to print the commit instead
set -eu
live=$1 clone=$2
case "$(basename "$live")" in
    master-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) echo "only runs of master are archived: $live" >&2; exit 2 ;;
esac
harness=$(cd "$(dirname "$0")/.." && pwd)
# a copy, so that the results do not change while they are archived
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rsync -a --exclude=run.json --exclude='.*' "$live"/ "$work"/
cd "$harness"
julia --startup-file=no --project=format format/archive.jl "$work" --repo="$clone" --wall=7200 --complete ${ARCHIVE_DRY_RUN:+--dry-run}
