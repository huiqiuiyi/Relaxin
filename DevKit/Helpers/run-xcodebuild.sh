#!/usr/bin/env bash
# Wrapper around xcodebuild that treats the log content as the source of truth,
# not the process exit code.
#
# Why: xcodebuild can exit 0 while its log still contains a failed build marker.
#
# Behavior:
#   1. Validate kernel primitive ABI boundaries.
#   2. Validate the BaseBin source contracts and kcall-less Runtime boundary.
#   3. Validate the deliberate zstd integration.
#   4. Validate that the credits page stays unlocalized.
#   5. Validate that RelaxinEngine stays unlocalized.
#   6. Capture the complete `xcodebuild "$@"` output.
#   7. Normalize the captured transcript into a plain-text log.
#   8. Replay the normalized log through xcbeautify when available.
#   9. Scan the log for error markers. If any are found, or the xcodebuild
#      invocation itself exited non-zero, exit with a non-zero status so make
#      halts the chain.
#
# Env:
#   XCBUILD_LABEL  Optional label (e.g. "build-ios") used in failure messages.

set -u -o pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIRECTORY/../../.env.sh"
"$SCRIPT_DIRECTORY/check-tools.sh" xcode || exit $?
"$SCRIPT_DIRECTORY/check-zstd-integration.sh" || exit $?
"$SCRIPT_DIRECTORY/check-credits-localization.sh" || exit $?
"$SCRIPT_DIRECTORY/check-engine-localization.sh" || exit $?

LABEL="${XCBUILD_LABEL:-xcodebuild}"
RAW_LOG=$(mktemp -t "relaxin-${LABEL//\//_}.raw.XXXXXX.log")
LOG=$(mktemp -t "relaxin-${LABEL//\//_}.XXXXXX.log")
trap 'rm -f "$RAW_LOG" "$LOG"' EXIT

capture_xcodebuild() {
    : >"$RAW_LOG"
    if xcodebuild "$@" >"$RAW_LOG" 2>&1; then
        XC_STATUS=0
    else
        XC_STATUS=$?
    fi
}

normalize_log() {
    perl -ne '
        s/\r/\n/g;
        s/\x08//g;
        s/\x04//g;
        next if m{Metal\.xctoolchain/usr/lib/swift/maccatalyst};
        next if m{CoreData: error: Failed to create NSXPCConnection};
        next if m{connection to service named com\.apple\.linkd\.autoShortcut};
        print;
    ' "$RAW_LOG" >"$LOG"
}

capture_xcodebuild "$@"
normalize_log

if command -v xcbeautify >/dev/null 2>&1; then
    xcbeautify --disable-colored-output --disable-logging <"$LOG"
else
    cat "$LOG"
fi

# Patterns that must never appear in a successful log.
#   - "** BUILD FAILED **", "** TEST FAILED **", "** ARCHIVE FAILED **"
#   - "error:" lines from clang/swiftc/ld (preceded by space after file:line:col:
#     or at start of line)
ERR_RE='(^|[[:space:]])error:|^\*\* (BUILD|TEST|ARCHIVE|CLEAN|ANALYZE) FAILED \*\*|^Testing failed:|^Failing tests:'

FOUND_ERRORS=0
if grep -En "$ERR_RE" "$LOG" >/dev/null 2>&1; then
    FOUND_ERRORS=1
fi

if [ "$XC_STATUS" -ne 0 ] || [ "$FOUND_ERRORS" -ne 0 ]; then
    echo "" >&2
    echo "❌ [$LABEL] xcodebuild failed (exit=$XC_STATUS, errors_in_log=$FOUND_ERRORS)" >&2
    if [ "$FOUND_ERRORS" -ne 0 ]; then
        echo "---- first 40 error lines from log ----" >&2
        grep -En "$ERR_RE" "$LOG" | head -40 >&2 || true
        echo "---------------------------------------" >&2
        # 额外：打印可能与打包相关的上下文（dpkg/deb/tar/rsync/cp 失败行）
        echo "---- packaging-context lines (last 60) ----" >&2
        grep -En "dpkg|\.deb|tar|rsync|VerifyAdHoc|codesign|failed|No such|not found|error" "$LOG" | tail -60 >&2 || true
        echo "---------------------------------------" >&2
    fi
    # Prefer propagating the original xcodebuild exit status when it's non-zero;
    # otherwise fail with 1 because the log says the run is bad.
    if [ "$XC_STATUS" -ne 0 ]; then
        exit "$XC_STATUS"
    fi
    exit 1
fi
