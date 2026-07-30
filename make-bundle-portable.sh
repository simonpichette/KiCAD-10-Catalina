#!/bin/bash
#
# make-bundle-portable.sh (v4) -- remove every /opt/local dependency from a
# KiCad.app built against MacPorts, so the bundle runs where MacPorts is absent.
#
# Background: KiCad's cmake/InstallSteps/RefixupMacOS.cmake rewrites a dependency
# to @rpath only when a file of the same NAME was found inside the bundle. Two
# things slip through, and neither is visible on the build machine because
# /opt/local is present there:
#
#   A. The Python framework binary is named "Python" (no extension), so it never
#      matches and its absolute /opt/local path survives in ~25 files. Fatal:
#      "Library not loaded: /opt/local/.../Python.framework/Versions/3.x/Python".
#
#   B. Python extension modules link support libraries (libffi, libsqlite3,
#      libncurses, libedit, libmpdec, libpanel, libintl) never copied into the
#      bundle. Non-fatal -- ImportError only if something imports them.
#
# Usage:
#   ./make-bundle-portable.sh [/path/to/KiCad.app]
#
# Environment:
#   KEEP_SITE_PACKAGES=1   keep numpy / PIL / wx in site-packages (default: drop)
#
# Safe to re-run. Run on the staging copy before `hdiutil create`, or in place.
# MUST be re-run after every `ninja install`, which rebuilds the bundle.
#
# Do NOT delete dangling symlinks before running this -- the framework's
# top-level Python/Resources/Headers links are dangling until Versions/Current
# exists, which this script creates.

set -u

APP="${1:-/Applications/KiCad.app}"
KEEP_SITE_PACKAGES="${KEEP_SITE_PACKAGES:-0}"

[ -d "$APP" ] || { echo "error: no bundle at $APP" >&2; exit 1; }

APP=$(cd "$APP" && pwd -P)
FW="$APP/Contents/Frameworks/Python.framework"
DEST="$APP/Contents/Frameworks"

[ -d "$FW" ] || { echo "error: no Python.framework in $APP" >&2; exit 1; }

echo "bundle: $APP"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# relpath <from-dir> <to-path>   (both absolute, no trailing slash on from-dir)
relpath() {
    local from="$1" to="$2" common up=""
    common="$from"
    while [ "${to#"$common"/}" = "$to" ] && [ "$common" != "/" ]; do
        common=$(dirname "$common")
        up="../$up"
    done
    printf '%s%s' "$up" "${to#"$common"/}"
}

is_macho() {
    [ -f "$1" ] && [ ! -L "$1" ] && file -b "$1" 2>/dev/null | grep -q 'Mach-O'
}

# All Mach-O files in the bundle. SharedSupport is excluded: it holds the
# symbol/footprint/3D libraries (gigabytes of data, no executables), and
# scanning it makes this script take minutes instead of seconds.
macho_list() {
    find "$APP" -type f -not -path "$APP/Contents/SharedSupport/*" -print0 |
    while IFS= read -r -d '' f; do
        is_macho "$f" && printf '%s\0' "$f"
    done
}

# install_name_tool refuses to write read-only files (MacPorts ships its dylibs
# read-only, and the copies inherit that). Force write permission every time.
int_change() {   # int_change <file> <old> <new>
    chmod u+w "$1" 2>/dev/null
    install_name_tool -change "$2" "$3" "$1" 2>/dev/null
}

int_id() {       # int_id <file> <new-id>
    chmod u+w "$1" 2>/dev/null
    install_name_tool -id "$2" "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. determine which Python version this build actually links against
# ---------------------------------------------------------------------------
# Taking the highest Versions/3.x present is wrong: builds sometimes bundle a
# second Python as a side effect, and deleting the wrong one breaks the app.
# Ask the binaries instead.

PYVER=$(otool -L "$APP/Contents/MacOS/kicad" 2>/dev/null |
        grep -oE 'Versions/3\.[0-9]+/Python' | head -1 |
        sed -E 's|Versions/(3\.[0-9]+)/Python|\1|')

if [ -z "${PYVER:-}" ]; then
    PYVER=$(ls "$FW/Versions" 2>/dev/null | grep -E '^3\.[0-9]+$' | sort -V | tail -1)
fi

[ -n "${PYVER:-}" ] || { echo "error: cannot determine Python version" >&2; exit 1; }
[ -d "$FW/Versions/$PYVER" ] || { echo "error: $FW/Versions/$PYVER missing" >&2; exit 1; }

echo "python: $PYVER"

PY_IN_BUNDLE="$FW/Versions/$PYVER/Python"
PY_MACPORTS="/opt/local/Library/Frameworks/Python.framework/Versions/$PYVER/Python"

# ---------------------------------------------------------------------------
# 2. framework structure: one version, Current, and the top-level symlinks
# ---------------------------------------------------------------------------
# KiCad's cleanup_python() globs Versions/3* and feeds the result to `ln -s`.
# With two versions present the glob returns a list, no Current gets created,
# and the app dies at launch with "failed to get the Python codec of the
# filesystem encoding" -- and codesign rejects the framework as malformed.

for d in "$FW/Versions"/3.*; do
    [ -d "$d" ] || continue
    if [ "$(basename "$d")" != "$PYVER" ]; then
        echo "  removing stray Python $(basename "$d")"
        rm -rf "$d"
    fi
done

( cd "$FW/Versions" && rm -f Current && ln -s "$PYVER" Current )

# A framework codesign accepts needs these at the top level, resolving inside.
( cd "$FW" \
  && rm -f Python Resources Headers \
  && ln -s "Versions/Current/Python"    Python \
  && ln -s "Versions/Current/Resources" Resources \
  && { [ -d "Versions/Current/Headers" ] && ln -s "Versions/Current/Headers" Headers; } \
  ; true )

# ---------------------------------------------------------------------------
# 3. debris
# ---------------------------------------------------------------------------
# Swept in wholesale by the dependency scan; none of it is used by KiCad.

SP="$FW/Versions/$PYVER/lib/python$PYVER/site-packages"

rm -f  "$FW/Versions/$PYVER/lib/python$PYVER/lib-dynload/ivlng.so"   # Verilog VPI bridge
rm -f  "$DEST/wxrc-3.2" "$APP/Contents/MacOS/wxrc-3.2"               # wx resource compiler
rm -rf "$FW/Versions/$PYVER/lib/python$PYVER/tkinter"
rm -f  "$FW/Versions/$PYVER/lib/python$PYVER/lib-dynload/_tkinter"*.so

if [ "$KEEP_SITE_PACKAGES" != "1" ] && [ -d "$SP" ]; then
    # NB: pcbnew.py and _pcbnew.so live here too -- only named debris goes.
    for junk in numpy PIL Pillow.libs wx wxPython; do
        [ -e "$SP/$junk" ] && { echo "  dropping site-packages/$junk"; rm -rf "$SP/$junk"; }
    done
    rm -rf "$SP"/*.dist-info "$SP"/*.egg-info 2>/dev/null
fi

# Any symlink pointing outside the bundle will fail codesign. The framework's
# own top-level links were just recreated as relative, so this is safe now.
find "$APP" -type l -lname '/*' -not -path "$APP/Contents/SharedSupport/*" -print -delete

# ---------------------------------------------------------------------------
# 4. Pass A -- rewrite references to the Python framework binary
# ---------------------------------------------------------------------------
# Files inside the framework carry no LC_RPATH of their own, so @rpath would
# resolve for the app but not when the framework's own python3 runs. Use a
# path relative to each file instead: correct in both cases.

echo
echo "pass A: Python framework references"
countA=0
while IFS= read -r -d '' f; do
    refs=$(otool -L "$f" 2>/dev/null | awk 'NR>1 {print $1}' |
           grep -E '/Python\.framework/Versions/[0-9.]+/Python$' |
           grep -v '^@')
    [ -z "$refs" ] && continue
    rel=$(relpath "$(dirname "$f")" "$PY_IN_BUNDLE")
    for r in $refs; do
        int_change "$f" "$r" "@loader_path/$rel"
        countA=$((countA+1))
    done
done < <(macho_list)
echo "  rewrote $countA reference(s)"

int_id "$PY_IN_BUNDLE" "@loader_path/Python"

# ---------------------------------------------------------------------------
# 5. Pass B -- vendor any remaining /opt/local libraries, transitively
# ---------------------------------------------------------------------------
# Only possible on a machine that still has MacPorts. Elsewhere the script
# reports what is missing and moves on.

echo
if [ -d /opt/local/lib ]; then
    echo "pass B: vendoring missing MacPorts libraries"
    round=0
    while : ; do
        round=$((round+1))
        newly=0
        while IFS= read -r -d '' f; do
            refs=$(otool -L "$f" 2>/dev/null | awk 'NR>1 {print $1}' | grep '^/opt/local')
            for r in $refs; do
                base=$(basename "$r")
                # never vendor the Python framework binary as a loose dylib
                [ "$base" = "Python" ] && continue
                if [ ! -e "$DEST/$base" ]; then
                    if [ -e "$r" ]; then
                        cp -L "$r" "$DEST/$base" 2>/dev/null || continue
                        chmod u+w "$DEST/$base"
                        int_id "$DEST/$base" "@rpath/$base"
                        echo "  + $base"
                        newly=$((newly+1))
                    else
                        continue
                    fi
                fi
                rel=$(relpath "$(dirname "$f")" "$DEST/$base")
                int_change "$f" "$r" "@loader_path/$rel"
            done
        done < <(macho_list)
        [ "$newly" -eq 0 ] && break
        [ "$round" -ge 8 ] && { echo "  giving up after $round rounds"; break; }
    done
else
    echo "pass B: skipped -- /opt/local not present on this machine"
    echo "        Any library listed in the audit below is genuinely missing."
    echo "        Re-run this script on the build machine to vendor it."
fi

# ---------------------------------------------------------------------------
# 6. re-sign
# ---------------------------------------------------------------------------
# Every install_name_tool edit invalidates the signature. Sign inside-out:
# --deep validates nested-framework seals rather than replacing them, so stale
# seals must be removed first and each nested Mach-O signed individually.

echo
echo "re-signing..."
find "$APP" -name _CodeSignature -exec rm -rf {} + 2>/dev/null

while IFS= read -r -d '' f; do
    codesign --force --sign - "$f" 2>/dev/null
done < <(macho_list)

codesign --force --sign - "$FW"  2>/dev/null
codesign --force --sign - "$APP" 2>/dev/null

if codesign --verify --strict "$APP" 2>/tmp/cs.err; then
    echo "  signature ok"
else
    echo "  signature FAILED:"
    sed 's/^/    /' /tmp/cs.err
fi

# ---------------------------------------------------------------------------
# 7. audit
# ---------------------------------------------------------------------------

echo
echo "remaining /opt/local references:"
remaining=0
while IFS= read -r -d '' f; do
    refs=$(otool -L "$f" 2>/dev/null | grep '/opt/local')
    if [ -n "$refs" ]; then
        echo "  $f"
        echo "$refs" | sed 's/^/    /'
        remaining=$((remaining+1))
    fi
done < <(macho_list)
[ "$remaining" -eq 0 ] && echo "  none -- bundle is portable" \
                       || echo "  $remaining file(s) still reference MacPorts."

echo
echo "unresolvable in-bundle references:"
bad=0
while IFS= read -r -d '' f; do
    d=$(dirname "$f")
    for r in $(otool -L "$f" 2>/dev/null | awk 'NR>1 {print $1}' | grep '^@loader_path/'); do
        t="$d/${r#@loader_path/}"
        [ -e "$t" ] || { echo "  $f -> $r"; bad=$((bad+1)); }
    done
done < <(macho_list)
[ "$bad" -eq 0 ] && echo "  none"

echo
echo "sanity: $(ls "$FW/Versions" | grep -cE '^3\.[0-9]+$') Python version(s) in the framework"
