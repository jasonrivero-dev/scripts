# VS Code IDE Troubleshooting (Celeste)

Personal notes, not a shared doc (gitignored). Two specific IDE problems hit
during the SW-3544 licensing work, their root causes, and the fixes already
in place. Read this before re-diagnosing either from scratch.

## 1. F5 fails to link: "undefined reference to ..."

**Symptom:** CLI build (`dev-build.sh -r`) succeeds, but debugging via F5 (or
the "Build: Standard"/"Build: Debug" ninja-only tasks) fails at the link step
with `undefined reference to <some symbol>`, for a symbol you just added.

**Cause:** most `CMakeLists.txt` in this repo collect sources with
`file(GLOB ...)`, which is evaluated only when CMake *configures* - not on
every `ninja` build. Adding, deleting, or renaming a `.cpp` file changes what
the glob should match, but plain `ninja` (what F5 runs) has no way to notice.
It silently links against the old file list.

**Status: fixed for `back_end/licensing/`** - its `CMakeLists.txt` now uses
`file(GLOB ... CONFIGURE_DEPENDS ...)`, which makes CMake detect glob changes
automatically and reconfigure as part of a normal `ninja` build. No action
needed there.

**Still applies everywhere else** (`back_end/CMakeLists.txt`,
`back_end/learning/`, `back_end/test/`, etc. - not yet converted to
`CONFIGURE_DEPENDS`). **Fix already wired in:** every F5 launch config in
`.vscode/launch.json` has its `preLaunchTask` set to a "Configure" task
(`Build: Debug Configure ...` or `Build: RelWithDebInfo Configure ...`)
instead of a bare `ninja` task. These run `dev-build.sh -t Debug -r` /
`dev-build.sh -r`, which always reconfigures + builds + runs tests before
launching - slower per F5, but immune to this class of stale-link failure.

**If you ever see this error again anyway:**
- Command Palette (`Ctrl+Shift+P`) → `Tasks: Run Task` → pick the matching
  `Build: ... Configure ...` task, or
- terminal: `~/dev/scripts/celeste/dev-build.sh -t Debug -r` (Debug tree) or
  `~/dev/scripts/celeste/dev-build.sh -r` (RelWithDebInfo tree).

Don't type the task's name directly into the Command Palette's default
`>` prompt - that searches built-in VS Code/extension commands, not your
project's `tasks.json` tasks. You have to go through `Tasks: Run Task` first.

## 2. IntelliSense: phantom "cannot open source file" errors

**Symptom:** the Problems panel floods with `cannot open source file X`
errors for real, existing headers (`magic_enum.hpp`, `cfg_loader.h`, feature
headers under `src/ai/`, etc.) - but the actual build compiles those files
fine.

**Cause:** most targets in this repo build with a CMake-generated
precompiled header, forced in via `-include .../cmake_pch.hxx` in
`compile_commands.json`. VS Code's C/C++ extension can't parse that flag
combination - it silently drops that file's real include paths and falls
back to a generic guess, which fails for anything not directly under
`${workspaceFolder}`.

**Fix already wired in:** `dev-build-lib`'s `configure_and_build_host()` now
calls `generate_ide_compile_commands()` after every build (any `-r`/`-c`/`-m`
run), which strips the `-include` flag into an IDE-only copy at
`.vscode/compile_commands.json` (the real build's own copy, inside the
`cmake-build-*` tree, is untouched). `.vscode/c_cpp_properties.json` points
IntelliSense at that stripped copy.

**If IntelliSense still shows stale errors after a build:**
1. Command Palette → `C/C++: Reset IntelliSense Database`.
2. If that doesn't clear it, fully quit and reopen VS Code (not just
   `Developer: Reload Window`) - the extension's handshake over which
   provider (CMake Tools vs. the plain `c_cpp_properties.json`) serves
   IntelliSense sometimes only re-negotiates on a fresh start.
3. To confirm what it's actually using: Command Palette →
   `C/C++: Edit Configurations (UI)` → check "Compile Commands" points at
   `${workspaceFolder}/.vscode/compile_commands.json`, and "Configuration
   provider" (under Advanced Settings) is blank, not `ms-vscode.cmake-tools`.

## Where these fixes actually live

- `back_end/licensing/CMakeLists.txt` - `CONFIGURE_DEPENDS`.
- `~/dev/scripts/celeste/dev-build-lib` - `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`
  on the configure line, plus `generate_ide_compile_commands()`.
- `.vscode/tasks.json` - the "... Configure ..." tasks.
- `.vscode/launch.json` - `preLaunchTask` on every debuggable config.
- `.vscode/c_cpp_properties.json`, `.vscode/settings.json` - IntelliSense
  wiring (`compileCommands` path, `cmake.buildDirectory`,
  `cmake.configureOnOpen: false`).
