#!/bin/sh
# Private build mirrors for parallel porting work. See CLAUDE.md → "Working in parallel".
#
#   Scripts/agent.sh <name> <owned-paths> pull     copy the published tree into the mirror,
#                                                  leaving your owned paths alone
#   Scripts/agent.sh <name> <owned-paths> build    swift build inside the mirror
#   Scripts/agent.sh <name> <owned-paths> test     run the test suite inside the mirror
#   Scripts/agent.sh <name> <owned-paths> publish  pull, build, and only if that succeeds,
#                                                  copy your owned paths into the published tree
#   Scripts/agent.sh <name> <owned-paths> path     print the mirror directory
#
# <owned-paths> is a comma-separated list relative to the package root, e.g.
#   Sources/ServerLife/Files,Tests/ServerLifeTests/Files
# Edit files ONLY inside the mirror (the `path` output). The published tree is
# written exclusively by `publish`, so it always compiles.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="$1"; OWNED="$2"; CMD="$3"
M="$ROOT/.agents/$NAME"
mkdir -p "$M"

excludes() {
  OLDIFS="$IFS"; IFS=','
  for p in $OWNED; do printf -- "--exclude=/%s\n" "$p"; done
  IFS="$OLDIFS"
}

pull() {
  # shellcheck disable=SC2046
  rsync -a --delete $(excludes) \
    --exclude=/.build --exclude=/.agents --exclude=/build --exclude=/.swiftpm \
    "$ROOT/" "$M/"
  # First pull: seed owned paths from the published tree if the mirror has none.
  OLDIFS="$IFS"; IFS=','
  for p in $OWNED; do
    if [ ! -e "$M/$p" ] && [ -e "$ROOT/$p" ]; then mkdir -p "$(dirname "$M/$p")"; cp -R "$ROOT/$p" "$M/$p"; fi
  done
  IFS="$OLDIFS"
}

build() {
  cd "$M"
  if swift build > "$M/.build-log.txt" 2>&1; then echo "BUILD OK ($NAME)"; return 0; fi
  sed 's/\x1b\[[0-9;]*m//g' "$M/.build-log.txt" | grep -E 'error:' | sort -u | head -60
  echo "BUILD FAILED ($NAME) — full log: $M/.build-log.txt"
  return 1
}

case "$CMD" in
  path) echo "$M" ;;
  pull) pull; echo "pulled into $M" ;;
  build) build ;;
  test)
    cd "$M"
    PLUGINS="$(xcrun --find swift 2>/dev/null | sed 's|/bin/swift$||')/lib/swift/host/plugins/testing"
    [ -d "$PLUGINS" ] || PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
    shift 3
    swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -vE '^\[[0-9]+/[0-9]+\]' | tail -80
    ;;
  publish)
    pull
    build
    OLDIFS="$IFS"; IFS=','
    for p in $OWNED; do
      if [ -e "$M/$p" ]; then
        mkdir -p "$(dirname "$ROOT/$p")"
        if [ -d "$M/$p" ]; then rsync -a --delete "$M/$p/" "$ROOT/$p/"; else cp "$M/$p" "$ROOT/$p"; fi
      fi
    done
    IFS="$OLDIFS"
    echo "PUBLISHED ($NAME): $OWNED"
    ;;
  *) echo "unknown command $CMD" >&2; exit 2 ;;
esac
