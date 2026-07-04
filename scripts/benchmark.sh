#!/bin/bash
# H4 benchmark (PRD §4.2): identical 40-tab load in Sill (3 of 4 workspaces
# hibernated) vs Arc and Chrome, RSS of all app processes summed.
#
# Method notes:
# - Sill's WebKit content processes are named com.apple.WebKit.*, shared with
#   other WebKit apps. QUIT Safari (and any WebKit-view-heavy apps) before
#   measuring, or the Sill number will be inflated. The script warns if
#   Safari is running.
# - Run each browser alone, measure, quit, then the next.
# - Results go in docs/M2-workspaces.md, flattering or not.
set -euo pipefail

cd "$(dirname "$0")/.."
READY=/tmp/sill-benchmark-ready

sum_rss_mb() { # args: awk regex over comm
  ps -axo rss=,comm= | awk -v pat="$1" '
    $0 ~ pat { sum += $1 }
    END { printf "%.0f", sum / 1024 }'
}

measure_sill() {
  if pgrep -xq Safari; then
    echo "WARNING: Safari is running — its WebKit processes will pollute the Sill number." >&2
  fi
  local app_mb webkit_mb
  app_mb=$(sum_rss_mb "/Sill$")
  webkit_mb=$(sum_rss_mb "com.apple.WebKit")
  echo "Sill shell:            ${app_mb} MB"
  echo "WebKit processes:      ${webkit_mb} MB"
  echo "SILL TOTAL:            $((app_mb + webkit_mb)) MB"
}

measure_chrome() {
  local mb
  mb=$(sum_rss_mb "Google Chrome")
  echo "CHROME TOTAL:          ${mb} MB"
}

measure_arc() {
  local mb
  mb=$(sum_rss_mb "^(/Applications/Arc|.*Arc Helper|.*/Arc$)")
  echo "ARC TOTAL:             ${mb} MB"
}

open_tabs_applescript() { # $1 = app name; reads URLs on stdin, 10 per window
  local app="$1" i=0 script=""
  while read -r url; do
    if (( i % 10 == 0 )); then
      script+="tell application \"$app\" to make new window\ndelay 1\n"
    fi
    script+="tell application \"$app\" to open location \"$url\"\ndelay 0.5\n"
    ((i++)) || true
  done
  printf '%b' "$script" | osascript -
}

case "${1:-}" in
  sill)
    make app
    rm -f "$READY"
    open build/Sill.app --args --benchmark-seed
    echo "Loading 40 tabs across 4 workspaces (3 will hibernate)…"
    for _ in $(seq 1 120); do
      [[ -f $READY ]] && break
      sleep 5
    done
    [[ -f $READY ]] || { echo "Timed out waiting for $READY"; exit 1; }
    echo "Settling 20s, then measuring:"
    sleep 20
    measure_sill
    ;;
  chrome)
    .build/release/Sill --print-benchmark-plan | open_tabs_applescript "Google Chrome"
    echo "Tabs opening in Chrome. Wait for loads (~2 min), then: $0 measure-chrome"
    ;;
  arc)
    .build/release/Sill --print-benchmark-plan | open_tabs_applescript "Arc"
    echo "Tabs opening in Arc. Wait for loads (~2 min), then: $0 measure-arc"
    ;;
  measure-sill)   measure_sill ;;
  measure-chrome) measure_chrome ;;
  measure-arc)    measure_arc ;;
  *)
    echo "usage: $0 {sill|chrome|arc|measure-sill|measure-chrome|measure-arc}"
    exit 1
    ;;
esac
