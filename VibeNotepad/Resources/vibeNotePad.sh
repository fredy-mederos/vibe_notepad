#!/bin/sh
# vibeNotePad — open files in Vibe Notepad from the terminal (or from an agent).
#
#   vibeNotePad file.md               open a file (created if it doesn't exist yet)
#   vibeNotePad src/app.swift:42      open at line 42
#   vibeNotePad src/app.swift:42:7    open at line 42, column 7
#   vibeNotePad a.txt b.yml .env      open several files
#   cat server.log | vibeNotePad -    open stdin in a new tab
#   vibeNotePad -- -notes.txt         treat what follows "--" as file names
#   vibeNotePad                       bring Vibe Notepad to the front
#
# Deep link equivalent: open "vibeNotePad://open?path=/abs/path&line=42&column=7"

APP="Vibe Notepad"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

encode() {
  # Percent-encode a path for use in a URL query.
  if [ -x /usr/bin/perl ]; then
    printf '%s' "$1" | /usr/bin/perl -pe 's/([^A-Za-z0-9\/._~-])/sprintf("%%%02X", ord($1))/seg'
  else
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]), end="")' "$1"
  fi
}

absolute() {
  dir=$(dirname -- "$1")
  base=$(basename -- "$1")
  (cd -- "$dir" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$base")
}

is_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

if [ $# -eq 0 ]; then
  open -a "$APP"
  exit $?
fi

status=0
only_files=0
for arg in "$@"; do
  if [ "$only_files" -eq 1 ]; then
    arg_kind=file
  else
    case "$arg" in
      --) only_files=1; continue ;;
      -h|--help) usage; exit 0 ;;
      -) arg_kind=stdin ;;
      -*)
        echo "vibeNotePad: unknown option: $arg (use -- before file names that start with -)" >&2
        usage >&2
        exit 2
        ;;
      *) arg_kind=file ;;
    esac
  fi
  case "$arg_kind" in
    stdin)
      base="$(mktemp -t vibeNotePad)" || { status=1; continue; }
      tmp="$base.txt"
      mv "$base" "$tmp"
      cat > "$tmp"
      open -a "$APP" "$tmp" || status=1
      continue
      ;;
  esac

  path="$arg"
  line=""
  column=""
  if [ ! -e "$path" ]; then
    last="${arg##*:}"
    rest="${arg%:*}"
    if [ "$rest" != "$arg" ] && is_number "$last"; then
      previous="${rest##*:}"
      rest2="${rest%:*}"
      if [ "$rest2" != "$rest" ] && is_number "$previous"; then
        path="$rest2"; line="$previous"; column="$last"
      else
        path="$rest"; line="$last"
      fi
    fi
  fi

  if [ ! -e "$path" ]; then
    parent=$(dirname -- "$path")
    if [ -d "$parent" ]; then
      : > "$path" || { status=1; continue; }
    else
      echo "vibeNotePad: no such directory: $parent" >&2
      status=1
      continue
    fi
  fi

  full=$(absolute "$path")
  if [ -n "$line" ]; then
    url="vibenotepad://open?path=$(encode "$full")&line=$line"
    [ -n "$column" ] && url="$url&column=$column"
    open "$url" || status=1
  else
    open -a "$APP" "$full" || status=1
  fi
done
exit $status
