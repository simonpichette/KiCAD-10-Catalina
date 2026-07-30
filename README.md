# Building KiCad 10.0.5 on macOS 10.15 (Catalina), Intel, with MacPorts

This procedure has been designed incrementally on 2026-07-30 with help from Claude Opus 5. It may not be the most efficient, but it produced a usable build.

It is posted here in the hope that it can be useful to somebody attempting a similar build on another unsupported mac OS version. If you just want to use the app on your older mac running Catalina, you can find the disk image as a Release.


**Target result:** a self-contained `KiCad.app` with schematic editor, PCB editor,
3D viewer (with models), gerbview, calculator, symbol/footprint editors, design
blocks, jobsets, Plugin & Content Manager, the IPC API, and the ngspice simulator
— plus a redistributable DMG that runs on machines with no MacPorts.

**Not included:** the wxPython scripting console (deliberately disabled — see
Step 6). It is deprecated upstream in favour of the IPC API, which *is* built.

---

## 0. Assumptions and why the obvious routes don't work

| | |
|---|---|
| Machine | Intel Mac, macOS 10.15.x, ≥16 GB RAM, ≥60 GB free (~25 GB with 3D models) |
| Toolchain | Xcode 11.7 / Command Line Tools installed |
| Packages | MacPorts installed and `selfupdate`-ed; no Homebrew required |
| Time | ~4 hours: MacPorts dependencies dominate, the build itself is ~1 hour at `-j12` |

Three things rule out the easy paths:

- **Official binaries** require macOS ≥ 11.6.
- **`sudo port install kicad`** is far behind the current release.
- **kicad-mac-builder** (what the KiCad project uses) assumes Homebrew and builds
  its own *patched* wxWidgets. We use stock MacPorts wx 3.2 instead, which costs
  us two source patches (Steps 4–5) and the scripting console.

Also note **Apple Clang 11.0.3 cannot build KiCad 10** — it is LLVM 9 internally
and KiCad uses C++20 concepts (LLVM 10+). We use MacPorts `clang-17`. This is
safe: clang 17 ships modern libc++ *headers* but links Catalina's ABI-stable
libc++ *runtime*, and mixing it with Apple-clang-built MacPorts dylibs is fine.

---

## 1. Install dependencies

Install in batches, so one failure doesn't abort the remainder of the list.

```bash
sudo port selfupdate

# build tooling + compiler (clang-17 is the long pole; start it first)
sudo port install clang-17 cmake ninja swig swig-python pkgconfig doxygen \
                  gettext bison 2>&1 | tee ~/ports1.log

# GUI + core libraries
sudo port install wxWidgets-3.2 glm cairo harfbuzz curl zstd unixODBC \
                  boost188 2>&1 | tee ~/ports2.log

# heavy / KiCad-specific
sudo port install opencascade ngspice protobuf3-cpp nng libgit2 \
                  python312 2>&1 | tee ~/ports3.log
```

What each group is for:

- **cmake / ninja / swig / pkgconfig / gettext / bison / doxygen** — build system,
  Python binding generator, translation tooling, parser generator.
- **wxWidgets-3.2** — the GUI toolkit. KiCad 10 requires the `webview` component
  in addition to the usual ones; the MacPorts port builds it against system WebKit.
- **opencascade** — 3D viewer and STEP import/export. The heaviest dependency.
- **glm / cairo / harfbuzz** — math, 2D fallback rendering, text shaping.
  (**GLEW is no longer required** — KiCad 10 bundles `glad` instead.)
- **protobuf3-cpp + nng** — the IPC plugin API. Mandatory even with IPC off.
- **libgit2** — project git integration.
- **ngspice** — circuit simulator backend.
- **mbedtls** arrives as an `nng` dependency but still needs explicit link flags
  (Step 6), because MacPorts ships `libnng.a` static.

Deliberately **not** installed: `py*-wxpython-*`. See Step 6.

---

## 2. Verify the local paths

MacPorts version numbers and layouts differ between machines and ports-tree
vintages. These four are used verbatim in Step 6 — check them before configuring.

```bash
ls /opt/local/bin/clang++-mp-17
ls /opt/local/libexec/boost/                  # note the version, e.g. 1.88
ls /opt/local/lib/libngspice*                 # note the versioned dylib name
/opt/local/Library/Frameworks/wxWidgets.framework/Versions/wxWidgets/3.1/bin/wx-config --libs webview
```

Notes:

- The wx path really does contain **`3.1`** despite the port being `wxWidgets-3.2`.
  Getting this wrong produces `Could NOT find wxWidgets (missing: wxWidgets_LIBRARIES)`.
- The last command must succeed and mention `libwx_osx_cocoau_webview`. If it
  fails, KiCad 10 will not configure.
- Reference versions from the 2026-07-30 build: boost 1.88, OpenCascade 7.9.3,
  ngspice 46 (`libngspice.0.dylib`), wxWidgets 3.2.11, Python 3.12.13, clang 17.0.6.

---

## 3. Get the source

```bash
mkdir -p ~/projects/kicad_build/src && cd ~/projects/kicad_build/src
git clone --branch 10.0.5 --depth 1 https://gitlab.com/kicad/code/kicad.git
cd kicad
```

---

## 4. Patch the macOS install scripts and one source file

Four patches. All are Catalina/MacPorts adaptations of code that only ever ran
under kicad-mac-builder's controlled Homebrew tree. Each asserts its anchor text
and aborts if absent, so a different source revision fails loudly rather than
silently no-op'ing.

```bash
cd ~/projects/kicad_build/src/kicad

cp cmake/InstallSteps/InstallMacOS.cmake cmake/InstallSteps/InstallMacOS.cmake.orig
cp cmake/InstallSteps/RefixupMacOS.cmake cmake/InstallSteps/RefixupMacOS.cmake.orig
cp eeschema/CMakeLists.txt eeschema/CMakeLists.txt.orig
cp kicad/project_tree.cpp kicad/project_tree.cpp.orig

python3 - << 'PYEOF'
import sys

def patch(path, old, new, label):
    s = open(path).read()
    if s.count(old) != 1:
        sys.exit(f"{label}: anchor found {s.count(old)} times -- patch by hand")
    open(path, "w").write(s.replace(old, new))
    print(f"{label}: ok")

# --- 1: dependency scan ------------------------------------------------------
# a) Conflicting paths (/opt/local/lib/libbz2 vs /usr/lib/libbz2) are a hard
#    error upstream; prefer the MacPorts copy.
# b) Catalina still has system dylibs on disk (Big Sur+ hides them in the dyld
#    shared cache), so the scanner bundles libSystem/libobjc/etc. and the refixup
#    then rewrites them to @rpath -- making dyld abort at launch with
#    "initializer in image ... that does not link with libSystem.dylib".
patch("cmake/InstallSteps/InstallMacOS.cmake",
"""    file( GET_RUNTIME_DEPENDENCIES
        LIBRARIES ${libs}
        EXECUTABLES ${exe}
        RESOLVED_DEPENDENCIES_VAR _r_deps
        UNRESOLVED_DEPENDENCIES_VAR _u_deps
        POST_EXCLUDE_FILES Python
    )""",
"""    file( GET_RUNTIME_DEPENDENCIES
        LIBRARIES ${libs}
        EXECUTABLES ${exe}
        RESOLVED_DEPENDENCIES_VAR _r_deps
        UNRESOLVED_DEPENDENCIES_VAR _u_deps
        CONFLICTING_DEPENDENCIES_PREFIX _c_deps
        POST_EXCLUDE_FILES Python
        POST_EXCLUDE_REGEXES "^/usr/lib/" "^/System/"
    )

    # Prefer the MacPorts copy when a dependency resolves to several paths.
    foreach( _fname ${_c_deps_FILENAMES} )
        set( _picked "" )
        foreach( _cand ${_c_deps_${_fname}} )
            if( _cand MATCHES "^/opt/local/" )
                set( _picked "${_cand}" )
            endif()
        endforeach()
        if( _picked STREQUAL "" )
            list( GET _c_deps_${_fname} 0 _picked )
        endif()
        message( STATUS "Conflict for ${_fname}: using ${_picked}" )
        list( APPEND _r_deps "${_picked}" )
    endforeach()""",
"patch 1 (InstallMacOS scan)")

# --- 2: never rewrite load commands through a symlink ------------------------
# install_name_tool would follow the link back to the root-owned original in
# /opt/local and fail with "Permission denied".
patch("cmake/InstallSteps/RefixupMacOS.cmake",
"""    foreach( item ${items} )
        message( "Refixing prereqs for '${item}'" )
        refix_prereqs( ${item} )
    endforeach( )""",
"""    foreach( item ${items} )
        if( IS_SYMLINK "${item}" )
            message( "Skipping symlink '${item}'" )
            continue()
        endif()
        message( "Refixing prereqs for '${item}'" )
        refix_prereqs( ${item} )
    endforeach( )""",
"patch 2 (Refixup symlink skip)")

# --- 3: ngspice -- install the real dylib, not all of /opt/local/lib ---------
# LIBNGSPICE_PATH is /opt/local/lib here, so the upstream rule vacuums the whole
# MacPorts lib tree into PlugIns/sim, symlinks included.
patch("eeschema/CMakeLists.txt",
"""    install( DIRECTORY "${LIBNGSPICE_PATH}/"
            DESTINATION "${OSX_BUNDLE_INSTALL_PLUGIN_DIR}/sim"
            FILES_MATCHING PATTERN "*.dylib")""",
"""    # MacPorts: LIBNGSPICE_PATH is /opt/local/lib; copying every dylib under it
    # is wrong. Install only the ngspice shared library itself, dereferenced and
    # user-writable so install_name_tool can rewrite it.
    get_filename_component( NGSPICE_DLL_REALPATH "${NGSPICE_DLL}" REALPATH )
    install( FILES "${NGSPICE_DLL_REALPATH}"
            PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
                        GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE
            DESTINATION "${OSX_BUNDLE_INSTALL_PLUGIN_DIR}/sim" )""",
"patch 3 (ngspice install rule)")

# --- 4: stock wx 3.2 has no SetStateImages backport --------------------------
# Upstream assumes any macOS build uses kicad-mac-builder's patched wx, which
# backports wxWidgets 3.3's SetStateImages. Stock MacPorts wx 3.2 does not have
# it. Dropping __WXMAC__ from the guard selects the wxImageList fallback that
# upstream already ships for other platforms.
patch("kicad/project_tree.cpp",
"#if wxCHECK_VERSION( 3, 3, 0 ) || defined( __WXMAC__ )",
"#if wxCHECK_VERSION( 3, 3, 0 )",
"patch 4 (project_tree wx guard)")
PYEOF
```

---

## 5. Patch 5 — make copied dylibs writable before rewriting them

MacPorts installs its dylibs read-only; the copies in the bundle inherit that,
and `install_name_tool` cannot rewrite them. Separate from patch 2, which only
covers the symlink half of the same function's problems.

```bash
cd ~/projects/kicad_build/src/kicad

python3 - << 'PYEOF'
import sys
p = "cmake/InstallSteps/RefixupMacOS.cmake"
s = open(p).read()
old = "function( refix_prereqs target )"
new = """function( refix_prereqs target )
    # MacPorts installs its dylibs read-only; once copied into the bundle
    # install_name_tool cannot rewrite them. Make each one user-writable first.
    file( CHMOD "${target}" PERMISSIONS
          OWNER_READ OWNER_WRITE OWNER_EXECUTE
          GROUP_READ GROUP_EXECUTE
          WORLD_READ WORLD_EXECUTE )
"""
if s.count(old) != 1:
    sys.exit(f"anchor found {s.count(old)} times -- patch by hand")
open(p, "w").write(s.replace(old, new))
print("patch 5 (refix_prereqs chmod): ok")
PYEOF
```

---

## 6. Configure

Write this to a **file** rather than pasting it into a terminal. A long multi-line
paste into zsh silently drops characters, and a missing `-D` flag produces a
confusing failure several steps later.

Adjust `1.88` and `libngspice.0.dylib` to match Step 2.

```bash
mkdir -p ~/projects/kicad_build/src/kicad/build/release

cat > ~/kicad10-configure.sh << 'SCRIPTEOF'
#!/bin/bash
set -e
cd ~/projects/kicad_build/src/kicad/build/release
MBEDTLS="-L/opt/local/lib -lmbedtls -lmbedx509 -lmbedcrypto"
WXCFG=/opt/local/Library/Frameworks/wxWidgets.framework/Versions/wxWidgets/3.1/bin/wx-config
PYFW=/opt/local/Library/Frameworks/Python.framework

cmake -G Ninja \
  -DCMAKE_C_COMPILER=/opt/local/bin/clang-mp-17 \
  -DCMAKE_CXX_COMPILER=/opt/local/bin/clang++-mp-17 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$HOME/kicad10 \
  -DCMAKE_PREFIX_PATH=/opt/local \
  -DCMAKE_CXX_FLAGS="-isystem /opt/local/libexec/boost/1.88/include -D_LIBCPP_ENABLE_EXPERIMENTAL" \
  -DCMAKE_EXE_LINKER_FLAGS="$MBEDTLS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$MBEDTLS" \
  -DCMAKE_MODULE_LINKER_FLAGS="$MBEDTLS" \
  -DBoost_ROOT=/opt/local/libexec/boost/1.88 \
  -DwxWidgets_CONFIG_EXECUTABLE=$WXCFG \
  -DPYTHON_EXECUTABLE=/opt/local/bin/python3.12 \
  -DPYTHON_LIBRARY=$PYFW/Versions/3.12/lib/libpython3.12.dylib \
  -DPYTHON_INCLUDE_DIR=$PYFW/Versions/3.12/include/python3.12 \
  -DPYTHON_FRAMEWORK=$PYFW \
  -DOCC_INCLUDE_DIR=/opt/local/include/opencascade \
  -DOCC_LIBRARY_DIR=/opt/local/lib \
  -DNGSPICE_INCLUDE_DIR=/opt/local/include \
  -DNGSPICE_LIBRARY=/opt/local/lib/libngspice.dylib \
  -DNGSPICE_DLL=/opt/local/lib/libngspice.0.dylib \
  -DKICAD_SCRIPTING_WXPYTHON=OFF \
  -DKICAD_USE_SENTRY=OFF \
  -DKICAD_BUILD_I18N=ON \
  ../.. 2>&1 | tee configure.log
SCRIPTEOF

chmod +x ~/kicad10-configure.sh
grep -n "WXPYTHON\|NGSPICE_DLL\|CXX_FLAGS" ~/kicad10-configure.sh   # verify intact
bash ~/kicad10-configure.sh
```

Rationale for the non-obvious flags:

| Flag | Why |
|---|---|
| `clang-mp-17` | Apple Clang 11 is LLVM 9; KiCad 10 needs C++20 concepts. |
| `-isystem .../boost/1.88/include` | `Boost_ROOT` reaches only targets linking a Boost *component*. Header-only users (`boost/ptr_container`) get nothing, and MacPorts' versioned layout is not on any default search path. `-isystem` (not `-I`) keeps Boost's headers out of KiCad's warning set. |
| `-D_LIBCPP_ENABLE_EXPERIMENTAL` | libc++ 17 ships `std::views::join` but gates it behind this macro pending an ABI change (D2770). KiCad 10 uses it in `common/libraries/library_manager.cpp`. **Do not use `-fexperimental-library`** — it works for compiling but adds `-lc++experimental` at link time, which MacPorts clang-17 does not ship. |
| mbedtls linker flags | MacPorts ships `libnng.a` static; its TLS symbols do not come along otherwise. |
| `wx-config` path | MacPorts installs wx as a framework outside the normal search path. Note the `3.1` directory. |
| `OCC_*`, `NGSPICE_*`, `PYTHON_*` | Pre-seeding these skips the find-module searches, which do not know MacPorts' layout. `PYTHON_FRAMEWORK` in particular: without it, configure fails with `set_target_properties called with incorrect number of arguments`. |
| `KICAD_SCRIPTING_WXPYTHON=OFF` | See below. Also drops `wxWidgets_REQ_VERSION` to 3.2.0, which is what MacPorts provides. |
| `KICAD_USE_SENTRY=OFF` | No crash telemetry; one less dependency. |

**On the scripting console.** MacPorts' wxPython links its own private wx 3.2.8
dylibs, while KiCad links wx 3.2.11. Enabling the console loads two wx runtimes
in one process; the symptom is subtle and severe — every window stops responding
to its red close button. The console is deprecated upstream in favour of the IPC
API. Leave it off. The `pcbnew` Python module, action plugins, `kicad-cli` and
the IPC API all still work.

Configure ends with `Generating done`. `Python3_EXECUTABLE was not used` is
harmless (KiCad uses the legacy `PYTHON_EXECUTABLE`), as is `kicad-cli not found`
— that only disables an optional font-regeneration target.

---

## 7. Build

```bash
cd ~/projects/kicad_build/src/kicad/build/release
ninja -j12 2>&1 | tee build.log
```

2780 targets. Roughly an hour on 12 cores. Linking peaks around 3 GB per job, so
`-j12` needs ~36 GB available; scale down on a smaller machine (`-j4` for 16 GB).

If it stops, find the *first* error rather than the tail:

```bash
grep -n -m1 -B5 -A30 "error:" build.log
```

---

## 8. Install

```bash
ninja install 2>&1 | tee install.log
grep -n -i "error\|failed\|permission denied\|fatal" install.log | head -30
```

This assembles the bundle in `~/kicad10`: it runs `GET_RUNTIME_DEPENDENCIES`,
copies the MacPorts dylibs into `KiCad.app/Contents/Frameworks`, rewrites install
names, and copies the Python framework.

Six `macOS signing failed` **warnings** at the end are expected at this stage and
are fixed by Step 9. The install itself has succeeded.

---

## 9. Repair the Python framework

KiCad's `cleanup_python()` globs `Versions/3*` and feeds the result to `ln -s`.
The MacPorts build pulls in a second Python (3.14) as a build dependency, so the
glob returns two entries, no `Versions/Current` is created, and:

- the app dies at launch with
  `Unhandled exception ... failed to get the Python codec of the filesystem encoding`;
- `codesign` rejects the framework as `bundle format unrecognized, invalid, or unsuitable`.

```bash
PF=~/kicad10/KiCad.app/Contents/Frameworks/Python.framework
rm -rf "$PF/Versions/3.14"
( cd "$PF/Versions" && rm -f Current && ln -s 3.12 Current )
ls -la "$PF/Versions"

codesign --force --deep --sign - ~/kicad10/KiCad.app
codesign --verify --deep --strict ~/kicad10/KiCad.app && echo "signature ok"
```

(Step 12's portability script also does this, and is idempotent — but the app
will not launch for smoke-testing until this is done.)

---

## 10. Libraries

```bash
cd ~/projects/kicad_build/src
git clone --branch 10.0.5 --depth 1 https://gitlab.com/kicad/libraries/kicad-symbols.git
git clone --branch 10.0.5 --depth 1 https://gitlab.com/kicad/libraries/kicad-footprints.git
git clone --branch 10.0.5 --depth 1 https://gitlab.com/kicad/libraries/kicad-templates.git
git clone --branch 10.0.5 --depth 1 https://gitlab.com/kicad/libraries/kicad-packages3D.git
```

The `10.0.5` tag matters: `master` libraries carry a newer file format and the
editors will warn that files came from a more recent version.

```bash
SS=~/kicad10/KiCad.app/Contents/SharedSupport
ln -sfn ~/projects/kicad_build/src/kicad-symbols      "$SS/symbols"
ln -sfn ~/projects/kicad_build/src/kicad-footprints   "$SS/footprints"
ln -sfn ~/projects/kicad_build/src/kicad-packages3D   "$SS/3dmodels"
ls -la "$SS" | grep '^l'
```

**`template` is not a symlink.** Unlike the other three, the install creates a
real `SharedSupport/template` directory containing `kicad.kicad_pro`. Pointing
`ln -sfn` at it creates a link *inside* it, which silently does nothing useful.
Merge the repo contents in instead:

```bash
cp -R ~/projects/kicad_build/src/kicad-templates/. "$SS/template/"
rm -rf "$SS/template/.git"
```

Also note KiCad looks for `3dmodels`, not `packages3D`.

Delete `~/Library/Preferences/kicad/10.0` and relaunch so the setup wizard
re-runs and picks up the library tables.

---

## 11. Smoke test

```bash
~/kicad10/KiCad.app/Contents/MacOS/kicad
```

Run from Terminal, not Finder, so dyld errors are visible. Check: setup wizard
completes, schematic editor, PCB editor, 3D viewer **with models** (exercises
OpenCascade and OpenGL), gerbview, calculator, symbol and footprint editors,
Plugin & Content Manager, and Inspect → Simulator (exercises patch 3). Confirm
windows close with the red button — failure there means two wx runtimes.

A `NSRemoteView ... ignoring attempt to mutate its subviews` warning on launch is
a Catalina AppKit quirk in the file dialog. Harmless.

> **Compatibility warning:** saving a KiCad 9 project from 10.0 upgrades the file
> format, and 9.0.9 cannot reopen it. Settings are already separate
> (`~/Library/Preferences/kicad/10.0`), but project files are not.

---

## 12. Build a distributable DMG

### 12a. Staging copy with real library content

The `SharedSupport` symlinks point into your home directory, which will not exist
on anyone else's machine.

```bash
rm -rf /tmp/kicad-dist && mkdir -p /tmp/kicad-dist
cp -R ~/kicad10/KiCad.app /tmp/kicad-dist/

APP=/tmp/kicad-dist/KiCad.app
SS="$APP/Contents/SharedSupport"

rm -f "$SS/symbols" "$SS/footprints" "$SS/3dmodels" "$SS/packages3D"
cp -R ~/projects/kicad_build/src/kicad-symbols    "$SS/symbols"
cp -R ~/projects/kicad_build/src/kicad-footprints "$SS/footprints"
cp -R ~/projects/kicad_build/src/kicad-packages3D "$SS/3dmodels"
cp -R ~/projects/kicad_build/src/kicad-templates/. "$SS/template/"
find "$SS" -maxdepth 2 -name .git -exec rm -rf {} +

ls -la "$SS" | grep '^l'     # expect no output
du -sh "$SS"/*               # 3D models ~3.2 GB
```

**Do not sweep dangling symlinks here.** The Python framework's top-level
`Python`, `Resources` and `Headers` links are dangling until `Versions/Current`
exists, and deleting them leaves a framework `codesign` rejects as malformed.
Step 12b creates `Current` and repairs those links itself.

### 12b. Make the bundle portable (mandatory)

```bash
chmod +x ~/make-bundle-portable.sh
~/make-bundle-portable.sh /tmp/kicad-dist/KiCad.app
```

This is the difference between a DMG that works and one that only works on the
machine that built it. KiCad's `refix_prereqs` rewrites a dependency to `@rpath`
only when a file of the same *name* was found in the bundle — and the Python
framework's binary is named `Python`, with no extension, so it never matches. Its
absolute `/opt/local` path survives in ~26 files. Invisible on the build machine.

The script also vendors five support libraries the dependency scan never copied
at all (`libffi`, `libsqlite3`, `libncurses`, `libedit`, `libpanel`), removes the
stray Python, repairs the framework symlinks, re-signs every Mach-O individually,
and audits the result.

It must end with:

```
  signature ok

remaining /opt/local references:
  none -- bundle is portable

unresolvable in-bundle references:
  none

sanity: 1 Python version(s) in the framework
```

Anything else: stop, do not build the image.

**Re-run it after every `ninja install`**, which rebuilds the bundle from scratch.

### 12c. The image

```bash
ln -s /Applications /tmp/kicad-dist/Applications

cat > /tmp/kicad-dist/READ-ME-FIRST.txt << 'EOF'
KiCad 10.0.5 for macOS 10.15 Catalina (Intel, x86_64)
Unofficial build. Official releases require macOS 11.6+.

INSTALL
  Drag KiCad.app to the Applications folder.

FIRST LAUNCH
  This build is ad-hoc signed, not notarized, so macOS will refuse to
  open it normally and may claim it is "damaged". It is not. Either:
    - right-click KiCad.app, choose Open, then confirm; or
    - run:  xattr -dr com.apple.quarantine /Applications/KiCad.app

INCLUDED
  Symbols, footprints, templates and 3D models, pinned to the 10.0.5
  library release.

NOT INCLUDED
  The wxPython scripting console (deprecated upstream). The pcbnew
  Python module, action plugins, kicad-cli and the IPC API all work.

NOTE
  Projects saved with 10.0 cannot be reopened by KiCad 9.

SOURCE
  Built from KiCad 10.0.5 with local patches, per GPLv3.
  Procedure and patches: <repo URL>
EOF

hdiutil create -volname "KiCad 10.0.5" -srcfolder /tmp/kicad-dist \
  -ov -format UDZO ~/KiCad-10.0.5-Catalina-x86_64.dmg

ls -lh ~/KiCad-10.0.5-Catalina-x86_64.dmg
```

`UDZO` is compressed read-only. Expect well under GitHub's 2 GiB release-asset
cap even with 3D models included.

### 12d. Verify the image, then verify without MacPorts

Audit what actually shipped, not the staging directory:

```bash
hdiutil attach ~/KiCad-10.0.5-Catalina-x86_64.dmg
VOL="/Volumes/KiCad 10.0.5"

find "$VOL/KiCad.app" -type f -not -path "*/SharedSupport/*" -print0 |
while IFS= read -r -d '' f; do
    file -b "$f" 2>/dev/null | grep -q 'Mach-O' || continue
    otool -L "$f" 2>/dev/null | grep -q "/opt/local" && echo "STILL BAD: $f"
done
echo "audit done"

codesign --verify --strict "$VOL/KiCad.app" && echo "signature ok"
```

Then the real test — install from the image and hide MacPorts:

```bash
sudo cp -R "$VOL/KiCad.app" /Applications/
hdiutil detach "$VOL"

mv ~/Library/Preferences/kicad/10.0 ~/Library/Preferences/kicad/10.0.bak
sudo chmod 000 /opt/local

/Applications/KiCad.app/Contents/MacOS/kicad
```

Moving the settings aside matters: the tables written in Step 10 point at your
source tree, so a test that keeps them is not testing the DMG's own libraries.

`sudo mv /opt/local /opt/local.hidden` is the more thorough approach but is often
refused ("Operation not permitted"); `chmod 000` blocks your user's access, which
is sufficient since KiCad runs as you.

Run the full Step 11 checklist, then restore:

```bash
sudo chmod 755 /opt/local
mv ~/Library/Preferences/kicad/10.0.bak ~/Library/Preferences/kicad/10.0
```

---

## 13. Distribution notes

- **Gatekeeper.** The signature is ad-hoc (`--sign -`). A downloaded DMG is
  quarantined and recipients see "KiCad.app is damaged and can't be opened".
  Fixing this properly needs a Developer ID certificate *and* notarization —
  and notarization is a hard blocker on Catalina: Apple retired the `altool`
  path in late 2023, and `notarytool` ships with Xcode 13+, which will not run
  here. You would need a newer Mac to notarize, even though the binary is built
  on this one. The README's `xattr` instruction is the practical workaround.
- **GPLv3.** Distributing binaries obliges you to offer corresponding source,
  including these patches. Publishing the patched tree, or this document plus a
  patch set, satisfies that.
- **Result compatibility:** x86_64 only (runs under Rosetta 2 on Apple Silicon),
  built against the 10.15 SDK, so macOS 10.15 and later — exactly the audience
  that cannot use the official builds.

---

## Appendix A: failure signatures and their causes

| Symptom | Cause / fix |
|---|---|
| `error: expected unqualified-id ... concept` | Building with Apple Clang. Use `clang-mp-17` (Step 6). |
| `fatal error: 'boost/ptr_container/ptr_vector.hpp' file not found` | Missing the boost `-isystem` flag (Step 6). `Boost_ROOT` alone is not enough. |
| `no member named 'join' in namespace 'std::ranges::views'` | Missing `-D_LIBCPP_ENABLE_EXPERIMENTAL` (Step 6). |
| `ld: library not found for -lc++experimental` | Used `-fexperimental-library` instead of the macro. MacPorts clang-17 does not ship that library. |
| ~40 undefined `_mbedtls_*` symbols linking `libkicommon` | Missing mbedtls linker flags (Step 6). |
| `Could NOT find Boost (missing: Boost_INCLUDE_DIR)` | Missing `Boost_ROOT` (Step 6). |
| `Could NOT find wxWidgets (missing: wxWidgets_LIBRARIES)` | Wrong `wx-config` path — remember the `3.1` directory name. |
| wxWidgets found but `webview` missing | MacPorts wx built without WebKit support; reinstall `wxWidgets-3.2`. KiCad 10 requires it. |
| `NGSPICE library missing` at configure | Missing `NGSPICE_LIBRARY` / `NGSPICE_DLL`. |
| `Standard_Version.hxx cannot be read` | Wrong `OCC_INCLUDE_DIR`; check `port contents opencascade`. |
| `set_target_properties called with incorrect number of arguments` | Missing `PYTHON_FRAMEWORK`. |
| `error: use of undeclared identifier 'SetStateImages'` | Patch 4 not applied. |
| `Multiple conflicting paths found for libbz2` | Patch 1 not applied. |
| `install_name_tool: ... Permission denied` during install | Patch 5 (or patch 2, if the path is under `PlugIns/sim`). |
| `dyld: initializer in image (.../libSystem.B.dylib) that does not link with libSystem.dylib` | System dylibs got bundled — patch 1's `POST_EXCLUDE_REGEXES`. |
| `failed to get the Python codec of the filesystem encoding` | No `Versions/Current` in the Python framework (Step 9). |
| `bundle format unrecognized, invalid, or unsuitable` on Python.framework | Same cause as above (Step 9). |
| `embedded framework contains modified or invalid version` | Stray second Python version still present (Step 9). |
| `codesign: invalid destination for symbolic link in bundle` | A symlink resolving outside the bundle. `find <bundle> -type l -lname '/*'`. |
| `a sealed resource is missing or invalid` | Stale nested `_CodeSignature`. The portability script removes them before re-signing. |
| `ModuleNotFoundError: No module named 'encodings'` | Running the app from the *build tree*. Only the installed bundle has a populated Python framework. |
| App works here but `Library not loaded: /opt/local/...` elsewhere | Step 12b not run, or run before the last `ninja install`. |
| Windows will not close with the red button | Two wx runtimes loaded. Rebuild with `KICAD_SCRIPTING_WXPYTHON=OFF`. |
| Footprint editor: "created with a more recent version" | Libraries on `master` instead of tag 10.0.5 (Step 10). |
| Recipient sees "KiCad.app is damaged and can't be opened" | Quarantine on an ad-hoc-signed download, not corruption. `xattr -dr com.apple.quarantine /Applications/KiCad.app`. |
| Templates missing in the New Project dialog | `SharedSupport/template` is a real directory, not a symlink (Step 10). |

---

## Appendix B: upstream issues worth reporting

Two findings here are upstream bugs rather than local quirks:

1. **`kicad/project_tree.cpp`** guards the `SetStateImages` path with
   `wxCHECK_VERSION( 3, 3, 0 ) || defined( __WXMAC__ )`, assuming every macOS
   build uses kicad-mac-builder's patched wxWidgets. Any macOS build against
   stock wx 3.2 fails to compile.

2. **`cleanup_python()` in `cmake/InstallSteps/RefixupMacOS.cmake`** globs
   `Versions/3*` and passes the result to `ln -s`. When more than one Python
   version is present in the bundle it produces no `Versions/Current`, which
   makes the app unlaunchable and the bundle unsignable. It should use the
   version it actually bundled.

A third is arguably a design limitation: `refix_prereqs` matches dependencies by
filename, so the extensionless `Python` framework binary is never rewritten. This
is what `make-bundle-portable.sh` exists to work around.

