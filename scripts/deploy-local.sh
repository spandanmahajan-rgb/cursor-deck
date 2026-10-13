#!/bin/bash
# Que local deploy. Copyright (c) 2026 Spandan Mahajan. PolyForm Noncommercial 1.0.0 (see LICENSE).
#
#   ./scripts/deploy-local.sh           build, swap into /Applications/Que.app, relaunch
#   ./scripts/deploy-local.sh --check   build, sign and verify ./Que.app, report what a deploy would do;
#                                       never touches /Applications or the running Que
#
# Local only: never commits, pushes, tags or publishes. Never deletes an app, never force-quits Que.
# The previous install is kept, untouched, at .build_cache/deploy-<timestamp>/Que.app.
#
# Test sandbox: set QUE_DEPLOY_APPS_DIR to a folder other than /Applications. Processes then come from
# QUE_DEPLOY_PS_FIXTURE (lines of "PID UID PATH") instead of the real system; quit, defaults and launch are
# simulated. QUE_DEPLOY_FAIL_AT=<step id> and QUE_DEPLOY_SKIP_BUILD=1 work only in the sandbox.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE_ID="com.cursordeck.app"
SRC_APP="$ROOT/Que.app"
ARM_BIN="$ROOT/.build/arm64-apple-macosx/release/Que"
X86_BIN="$ROOT/.build/x86_64-apple-macosx/release/Que"

CHECK_ONLY=0
case "${1:-}" in "") ;; --check) CHECK_ONLY=1 ;; *) echo "Usage: $0 [--check]" >&2; exit 2 ;; esac

APPS_DIR="${QUE_DEPLOY_APPS_DIR:-/Applications}"
SANDBOX=0
[ "$APPS_DIR" = "/Applications" ] || SANDBOX=1
if [ $SANDBOX = 0 ] && [ -n "${QUE_DEPLOY_FAIL_AT:-}${QUE_DEPLOY_SKIP_BUILD:-}${QUE_DEPLOY_PS_FIXTURE:-}" ]; then
  echo "QUE_DEPLOY_FAIL_AT, _SKIP_BUILD and _PS_FIXTURE only work with a sandbox QUE_DEPLOY_APPS_DIR." >&2
  exit 2
fi
FAIL_AT="${QUE_DEPLOY_FAIL_AT:-}"

DEST_APP="$APPS_DIR/Que.app"
DEST_BIN="$DEST_APP/Contents/MacOS/Que"
STAGED_APP="$APPS_DIR/Que.app.new"
if [ $SANDBOX = 1 ]; then RUN_PARENT="$(dirname "$APPS_DIR")"; else RUN_PARENT="$ROOT/.build_cache"; fi
RUN_DIR="$RUN_PARENT/deploy-$(date +%Y%m%d-%H%M%S)"
BACKUP_APP="$RUN_DIR/Que.app"   # the previous install, moved here as-is
LOG_DIR="$RUN_DIR/logs"
ME="$(id -u)"

# What this run has done so far; recovery reads these plus the actual files on disk.
STAGED_BY_US=0; QUIT_BY_US=0; HANDLED=0; KEEP_LOGS=0; STEP_NO=0; LAST_LOG=/dev/null
SB_STATE=running   # sandbox only: running | quit | launched
QUE_STATE=none; QUE_PID=""; QUE_WHY=""

# ---------- Output, failure and recovery ----------

show_logs_path() { if [ -d "$LOG_DIR" ]; then echo "  Logs: $LOG_DIR" >&2; fi; }

abort() {
  HANDLED=1
  printf '✗ %b\n' "$1" >&2
  recover
  show_logs_path
  exit 1
}

on_exit() {
  local code=$?
  if [ $code != 0 ] && [ $HANDLED = 0 ]; then
    HANDLED=1
    echo "✗ Stopped unexpectedly (exit $code)." >&2
    recover
    show_logs_path
  fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# run <id> <label> <command…>: one line on success; command, exit code and log tail on failure.
run() {
  local id="$1" label="$2" code=0
  shift 2
  STEP_NO=$((STEP_NO + 1))
  LAST_LOG="$LOG_DIR/$(printf '%02d' "$STEP_NO")-$id.log"
  printf '→ %s… ' "$label"
  if [ "$FAIL_AT" = "$id" ]; then
    echo "sandbox: injected failure" >"$LAST_LOG"; code=99
  else
    "$@" >"$LAST_LOG" 2>&1 || code=$?
  fi
  if [ $code = 0 ]; then echo "ok"; return 0; fi
  echo "FAILED (exit $code)"
  {
    echo "  Command: $*"
    echo "  Last 40 lines of $LAST_LOG:"
    tail -n 40 "$LAST_LOG" | sed 's/^/    /'
  } >&2
  abort "$label failed."
}

manual_restore() {
  cat >&2 <<EOF
  ✗ Couldn't restore automatically. Your previous install is safe at:
      $BACKUP_APP
    To put it back by hand (first line only if $DEST_APP exists):
      mv "$DEST_APP" "$RUN_DIR/Que.app.rejected"
      mv "$BACKUP_APP" "$DEST_APP"
      open "$DEST_APP"
EOF
}

relaunch_previous() {
  classify_que
  if [ "$QUE_STATE" != none ] || [ ! -d "$DEST_APP" ]; then return; fi
  if [ $SANDBOX = 1 ]; then echo "  (sandbox) Would relaunch $DEST_APP" >&2; return; fi
  if open "$DEST_APP"; then echo "  Relaunched the previous Que." >&2
  else echo "  Couldn't relaunch Que. Open it from Applications." >&2; fi
}

# Puts things back the way they were, judged by what is actually on disk. Never deletes; only moves.
recover() {
  set +e
  trap '' INT TERM
  local changed=0
  if [ -e "$BACKUP_APP" ]; then          # the old install was moved aside
    changed=1
    if [ -e "$DEST_APP" ]; then           # …and the new one is in its place
      classify_que
      if [ "$QUE_STATE" != none ]; then
        echo "  A Que process is running ($QUE_STATE), so the new copy stays in place." >&2
        echo "  Previous install is safe at $BACKUP_APP" >&2
        return
      fi
      if mv "$DEST_APP" "$RUN_DIR/Que.app.rejected"; then echo "  New copy moved to $RUN_DIR/Que.app.rejected" >&2
      else manual_restore; return; fi
    fi
    if mv "$BACKUP_APP" "$DEST_APP"; then echo "  Restored the previous Que to $DEST_APP" >&2
    else manual_restore; return; fi
  fi
  if [ $STAGED_BY_US = 1 ] && [ -e "$STAGED_APP" ]; then
    changed=1
    if mv "$STAGED_APP" "$RUN_DIR/Que.app.unused"; then echo "  Unused staged copy moved to $RUN_DIR/Que.app.unused" >&2
    else echo "  Couldn't move $STAGED_APP away. Move it yourself before the next deploy." >&2; fi
  fi
  if [ $QUIT_BY_US = 1 ]; then relaunch_previous; fi
  if [ $changed = 0 ] && [ $QUIT_BY_US = 0 ]; then echo "  Nothing in $APPS_DIR was changed." >&2; fi
}

# ---------- Checks ----------

bundle_id() { plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || echo "?"; }

verify_thin() {   # <binary> <arch>
  [ -s "$1" ] || { echo "Missing or empty: $1"; return 1; }
  local archs
  archs="$(lipo -archs "$1")" || return 1
  [ "$archs" = "$2" ] || { echo "$1 has '$archs', expected '$2'"; return 1; }
}

verify_builds() { verify_thin "$ARM_BIN" arm64 && verify_thin "$X86_BIN" x86_64; }

verify_app() {    # <app>: Que's bundle ID, arm64 + x86_64 binary, valid signature
  local id
  id="$(bundle_id "$1")"
  [ "$id" = "$BUNDLE_ID" ] || { echo "$1 has bundle ID '$id', expected $BUNDLE_ID"; return 1; }
  [ -s "$1/Contents/MacOS/Que" ] || { echo "Missing or empty: $1/Contents/MacOS/Que"; return 1; }
  lipo "$1/Contents/MacOS/Que" -verify_arch arm64 x86_64 \
    || { echo "$1 lacks arm64 or x86_64 (has: $(lipo -archs "$1/Contents/MacOS/Que" 2>&1))"; return 1; }
  codesign --verify --deep --strict "$1"
}

verify_copy() {   # <app>: valid, and its binary is byte-identical to ./Que.app's
  verify_app "$1" && cmp "$SRC_APP/Contents/MacOS/Que" "$1/Contents/MacOS/Que"
}

warn_count() {
  local n
  n="$(grep -c ' warning: ' "$LAST_LOG" || true)"
  if [ "$n" != 0 ]; then KEEP_LOGS=1; echo "  ($n warning lines, see $LAST_LOG)"; fi
}

# ---------- Process detection ----------

# Prints every running Que as "PID UID PATH": any executable named Que, or anything inside a Que.app* bundle.
list_que_processes() {
  local all
  if [ $SANDBOX = 1 ]; then
    case $SB_STATE in
      running)  cat "${QUE_DEPLOY_PS_FIXTURE:-/dev/null}" || return 1 ;;
      launched) echo "99999 $ME $DEST_BIN" ;;
    esac
    return 0
  fi
  all="$(ps -axww -o pid=,uid=,comm=)" || return 1
  [ -n "$all" ] || return 1
  printf '%s\n' "$all" | awk '{ p = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", p); n = split(p, part, "/");
                               if (part[n] == "Que" || index(p, "/Que.app")) print }'
}

# Sets QUE_STATE: none | installed (one Que, ours, at DEST_BIN; QUE_PID set) | unknown (QUE_WHY says why).
classify_que() {
  local procs line pid uid path
  QUE_PID=""; QUE_WHY=""
  if ! procs="$(list_que_processes)"; then QUE_STATE=unknown; QUE_WHY="couldn't read the process list"; return 0; fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r pid uid path <<< "$line"
    case "$pid" in ''|*[!0-9]*) QUE_STATE=unknown; QUE_WHY="unreadable process line: $line"; return 0 ;; esac
    if [ "$path" = "$DEST_BIN" ] && [ "$uid" = "$ME" ] && [ -z "$QUE_PID" ]; then
      QUE_PID="$pid"
    else
      QUE_STATE=unknown; QUE_WHY="unrecognised Que process: $line"; return 0
    fi
  done <<< "$procs"
  if [ -n "$QUE_PID" ]; then QUE_STATE=installed; else QUE_STATE=none; fi
}

require_known_que() {
  classify_que
  [ "$QUE_STATE" != unknown ] || abort "Can't confidently identify the running Que, so nothing will be replaced.\n  ($QUE_WHY)\n  Quit any extra copy of Que yourself, then re-run."
}

quit_que() {      # normal quit only; fails (without forcing) if Que is still running after ~15 s
  if [ $SANDBOX = 1 ]; then SB_STATE=quit; return 0; fi
  osascript -e 'with timeout of 15 seconds' -e 'quit app "Que"' -e 'end timeout' || return 1
  sleep 2
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
    ps -p "$QUE_PID" >/dev/null || return 0
    sleep 1
  done
  echo "Que (pid $QUE_PID) is still running after a normal quit. Not forcing it."
  return 1
}

launch_que() {    # open, then wait up to 15 s for exactly our Que at DEST_BIN
  if [ $SANDBOX = 1 ]; then SB_STATE=launched; else open "$DEST_APP" || return 1; fi
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    classify_que
    case $QUE_STATE in
      installed) echo "Que running, pid $QUE_PID"; return 0 ;;
      unknown)   echo "$QUE_WHY"; return 1 ;;
    esac
    sleep 1
  done
  echo "No Que process at $DEST_BIN after 15 s."
  return 1
}

# ---------- 1. Preflight (read-only, apart from creating this run's folder) ----------

title="Que local deploy"
[ $CHECK_ONLY = 0 ] || title="$title (check only)"
[ $SANDBOX = 0 ] || title="$title (sandbox: $APPS_DIR)"
echo "$title"
for tool in swift lipo codesign plutil ditto xattr osascript defaults open ps cmp; do
  command -v "$tool" >/dev/null || abort "Missing tool: $tool"
done
[ -d "$SRC_APP/Contents/MacOS" ] || abort "$SRC_APP/Contents/MacOS not found."
[ "$(bundle_id "$SRC_APP")" = "$BUNDLE_ID" ] || abort "./Que.app has bundle ID '$(bundle_id "$SRC_APP")', not $BUNDLE_ID."
[ -d "$DEST_APP" ] || abort "$DEST_APP not found. Install Que from the DMG first."
[ "$(bundle_id "$DEST_APP")" = "$BUNDLE_ID" ] || abort "$DEST_APP has bundle ID '$(bundle_id "$DEST_APP")', not Que's. Not touching it."
[ ! -e "$STAGED_APP" ] || abort "$STAGED_APP already exists (from an earlier run?). Look at it and move it away yourself."
[ -w "$APPS_DIR" ] || abort "Can't write to $APPS_DIR."
mkdir -p "$RUN_PARENT"
mkdir "$RUN_DIR" "$LOG_DIR"
[ "$(stat -f %d "$APPS_DIR")" = "$(stat -f %d "$RUN_DIR")" ] \
  || abort "$RUN_DIR is on a different disk from $APPS_DIR, so moving Que aside wouldn't be instant."
require_known_que
if [ "$QUE_STATE" = installed ]; then echo "  Que is running (pid $QUE_PID)"; else echo "  Que is not running"; fi

# ---------- 2. Build and verify ./Que.app (nothing installed is touched) ----------

if [ "${QUE_DEPLOY_SKIP_BUILD:-}" = 1 ]; then
  echo "→ Build skipped (sandbox)"
else
  run build-arm64  "Build arm64"  swift build -c release --triple arm64-apple-macosx;  warn_count
  run build-x86_64 "Build x86_64" swift build -c release --triple x86_64-apple-macosx; warn_count
fi
run check-builds "Check both builds"         verify_builds
run combine      "Combine universal binary"  lipo -create -output "$SRC_APP/Contents/MacOS/Que" "$ARM_BIN" "$X86_BIN"
run sign         "Sign (ad-hoc)"             codesign --force --deep -s - "$SRC_APP"
run verify-build "Verify ./Que.app"          verify_app "$SRC_APP"

if [ $CHECK_ONLY = 1 ]; then
  if [ "$QUE_STATE" = installed ]; then plan="quit Que (pid $QUE_PID) normally, replace"; else plan="replace"; fi
  echo "✓ Check passed. A deploy would $plan $DEST_APP and keep the old copy in $RUN_PARENT."
  [ $KEEP_LOGS = 1 ] || { rm -rf "$LOG_DIR"; rmdir "$RUN_DIR"; }
  exit 0
fi

# ---------- 3. Stage next to the installed app (Que keeps running) ----------

STAGED_BY_US=1
run stage        "Stage new copy"     ditto "$SRC_APP" "$STAGED_APP"
run verify-stage "Verify staged copy" verify_copy "$STAGED_APP"

# ---------- 4. Quit normally (never forced) ----------

require_known_que   # again: something may have started during the build
if [ "$QUE_STATE" = installed ]; then
  QUIT_BY_US=1
  run quit "Quit Que (pid $QUE_PID)" quit_que
  require_known_que
  [ "$QUE_STATE" = none ] || abort "Que is still running after quitting. Nothing was replaced."
else
  echo "→ Que not running, nothing to quit"
fi
if [ $SANDBOX = 1 ]; then
  run flag "Mark as update (sandbox: skipped)" true
else
  run flag "Mark as update (skip welcome)" defaults write "$BUNDLE_ID" Que_updateInProgress -bool true
fi

# ---------- 5. Swap (two instant renames on one disk) ----------

run move-old       "Move old copy to backup" mv "$DEST_APP" "$BACKUP_APP"
run move-new       "Move new copy in"        mv "$STAGED_APP" "$DEST_APP"
run xattr          "Clear quarantine flags"  xattr -cr "$DEST_APP"
run verify-install "Verify installed copy"   verify_copy "$DEST_APP"

# ---------- 6. Launch and confirm ----------

run launch "Launch" launch_que

HANDLED=1   # done: a late Ctrl-C must not roll back a working install
version="$(plutil -extract CFBundleShortVersionString raw -o - "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo "?")"
echo "✓ Que $version running from $DEST_APP (pid $QUE_PID)"
echo "  Previous install kept at $BACKUP_APP"
[ $KEEP_LOGS = 1 ] || rm -rf "$LOG_DIR"
