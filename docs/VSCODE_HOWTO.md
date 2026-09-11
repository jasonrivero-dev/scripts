# VS Code How-To (Celeste)

Personal notes, not a shared doc (gitignored). Covers the actual `.vscode/tasks.json`
and `.vscode/launch.json` set up in this repo for building and debugging Celeste
on the host (CLion/ninja build, not Docker).

`.vscode/` itself is already gitignored repo-wide (`**/.vscode` in `.gitignore`),
so anything in `tasks.json`/`launch.json` is personal/local already - free to
tweak without worrying about affecting anyone else or showing up in a diff.

See also `VSCODE_IDE_TROUBLESHOOTING.md` - this doc is the day-to-day how-to;
that one covers specific failure symptoms (stale links after adding a source
file, phantom IntelliSense errors) and their root causes in more depth.

## The Command Palette - your main entry point

**Ctrl+Shift+P** opens the Command Palette - a searchable list of every command
VS Code knows. You will use this constantly; almost everything below can be
reached either through a shortcut/button *or* by typing its name here. If you
forget a shortcut, just open the palette and type what you want to do
("build", "debug", "breakpoint"...) - it fuzzy-matches.

Two palette commands you'll use most for this repo:

- **`Tasks: Run Task`** - runs one of the build tasks below without debugging.
- **`Debug: Select and Start Debugging`** - same list as the Run and Debug
  dropdown (see below), picked from the palette instead.

## The sidebar (Activity Bar, left edge)

The icons down the far left edge switch what the sidebar shows:

- **Explorer** (top icon, or **Ctrl+Shift+E**) - file tree.
- **Search** (**Ctrl+Shift+F**) - project-wide text search.
- **Source Control** (**Ctrl+Shift+G**) - git status/diff/commit, if you use
  it instead of the terminal.
- **Run and Debug** (**Ctrl+Shift+D**) - this is the one you want for
  debugging Celeste. Opens the view with the green Play button, the
  configuration dropdown, Variables/Watch/Call Stack/Breakpoints panels (this
  is the panel you were looking at earlier today).

## Building (without debugging)

Two ways to trigger a build task:

1. **Ctrl+Shift+B** - runs the *default* build task directly, no menu. Right
   now that's **"Build: Standard (celeste)"** (fast incremental `ninja`
   build of the RelWithDebInfo tree).
2. **Ctrl+Shift+P → "Tasks: Run Task"** - shows every task below, pick one.

Build output streams into an integrated terminal panel at the bottom
(auto-opens). Compiler errors get underlined/clickable if `problemMatcher`
catches them (it's set to `$gcc` on the build tasks, so most errors are
click-to-jump).

### Available tasks (`.vscode/tasks.json`)

| Task | What it does | When to use it |
| --- | --- | --- |
| **Build: Standard (celeste)** | `ninja -C back_end/cmake-build-relwithdebinfo celeste` | Manual fast incremental build, or Ctrl+Shift+B. Not wired to any debug config's `preLaunchTask` anymore (see "Build: RelWithDebInfo Configure" below). |
| **Build: Debug Configure (celeste - run after adding/removing/renaming a .cpp)** | `dev-build.sh -t Debug -r` - full configure + build + run tests into `cmake-build-debug` | The `preLaunchTask` for **"Debug: Celeste (Main Config, Debug Build)"** - runs on every F5 for that config, not just once, so plain `ninja` never silently links against a stale source-file list. Slower per F5 (runs the whole test suite too) - that's the deliberate tradeoff. |
| **Build: Debug (celeste)** | `ninja -C back_end/cmake-build-debug celeste` | Manual fast incremental build only - no longer any debug config's `preLaunchTask`. |
| **Build: RelWithDebInfo Configure (celeste - run after adding/removing/renaming a .cpp)** | `dev-build.sh -r` - full configure + build + run tests into `cmake-build-relwithdebinfo` | The `preLaunchTask` for the other three debug configs (Main Config, NovAI Config, Installed Config) - same reconfigure-safety as the Debug Configure task above, for the RelWithDebInfo tree. |
| **Build: Clean & Conan (-cl)** | `dev-build.sh -cl` | Wipes `back_end/cmake-build-relwithdebinfo` and ffmpeg_recorder's build dir. Doesn't rebuild by itself. |
| **Build: Rebuild Metrics (-m)** | `dev-build.sh -m` | Rebuilds the `metrics-cpp` dependency, then builds `celeste`. |
| **Build: Coverage Enabled (-c)** | `dev-build.sh -c -r` | Build + run everything with coverage instrumentation, produces a coverage report. |
| **Test: Full Monolithic Suite (Host)** | `./build.sh dev-tests` | Full host-side test run via celeste's own `build.sh`. |
| **Test: Recorder Surgical (Host)** | `./build.sh dev-recorder-tests` | Just the recorder tests, faster than the full suite. |

### Recovering the host build after a Docker test run (`-d`)

`-d`/`--docker-test` isn't a VS Code task (destructive, terminal-only) - it
wipes `back_end/cmake-build-*`, `deps/`, and repo-root `build/` before
running celeste's own Docker `./build.sh test`, which is the only reliable
way to get a trustworthy Docker-build signal (a host build's `deps/metrics-cpp`
otherwise contaminates the container's own via a `cp -r` nesting bug). That
wipe takes the whole host build environment down with it, so it needs
restoring in this exact order before VS Code debugging works again:

1. `~/dev/scripts/celeste/dev-build.sh -d` - runs the clean Docker test.
2. `cd ~/dev/celeste && ./build.sh --setup-clion` - restores `deps/libtorch`,
   `deps/metrics-cpp`, `celeste_infra`, `ffmpeg_recorder`. Does **not** build
   `celeste` itself.
3. `~/dev/scripts/celeste/dev-build.sh -r` - same as "Build: RelWithDebInfo
   Configure" above, run from a terminal instead of the task since
   `cmake-build-relwithdebinfo` doesn't exist yet for that task to build
   into. Re-configures and builds it from scratch.
4. `~/dev/scripts/celeste/dev-build.sh -t Debug -r` - same as "Build: Debug
   Configure" above, re-configures and builds `cmake-build-debug` from
   scratch.

After step 4, F5 on any debug config works normally again - the fast
incremental `ninja` preLaunchTasks have a tree to build into once more.

## Debugging Celeste

1. Open the **Run and Debug** view (**Ctrl+Shift+D**).
2. At the top, there's a dropdown listing every config from `launch.json` -
   click it to pick one (see table below).
3. Press the green **Play** button next to the dropdown, or just **F5**.
4. Because each config has a `preLaunchTask`, it reconfigures + rebuilds
   first automatically - no separate manual build step needed anymore. This
   is deliberately the slower "Configure" task for every config now, not a
   plain fast `ninja` build, so F5 never silently links against a stale
   source-file list after you add/remove/rename a `.cpp`. See
   `VSCODE_IDE_TROUBLESHOOTING.md` for why. Watch the terminal panel; if the
   build fails, the debugger won't launch and you'll see the error there.

### Available debug configs (`.vscode/launch.json`)

| Config | Binary | Config file used | Build type |
| --- | --- | --- | --- |
| **Debug: Celeste (Main Config)** | `cmake-build-relwithdebinfo/celeste` | `noveye-local-main.cfg` | RelWithDebInfo (optimized - fine for general runs, unreliable for stepping through logic closely) |
| **Debug: Celeste (Main Config, Debug Build)** | `cmake-build-debug/celeste` | `noveye-local-main.cfg` | Debug, unoptimized - use this one when you actually need to step line-by-line and trust variable values |
| **Debug: Celeste (NovAI Config)** | `cmake-build-relwithdebinfo/celeste` | `noveye-local-novai.cfg` | RelWithDebInfo |
| **Debug: Celeste (Installed Config: /opt/novarc/apps/celeste/etc/noveye.cfg)** | `cmake-build-relwithdebinfo/celeste` | the installed config from `celeste-setup.sh` (real AI models, sample video) | RelWithDebInfo |
| **Debug: Recorder Integration Tests** | `cmake-build-relwithdebinfo/test/recorder_tests` | n/a (Catch2 test binary) | RelWithDebInfo |

All of `noveye-local-main.cfg`/`noveye-local-novai.cfg` already set
`ai mode = autonomy`, so any of the top configs will exercise the
NovEye/autonomy licensing gate path if that's what you're debugging.

### While stopped at a breakpoint

- **F9** - toggle a breakpoint on the current line (or click in the gutter,
  just left of the line numbers - a red dot appears).
- **F5** - continue running to the next breakpoint.
- **F10** - step over (run this line, don't enter function calls).
- **F11** - step into (enter the function call on this line).
- **Shift+F11** - step out of the current function.
- **Shift+F5** - stop debugging.
- **Ctrl+Shift+F5** - restart the debug session from scratch.

Panels on the left while debugging (this is the layout from the screenshot
earlier):

- **Variables** - everything in scope at the current line. Expand structs/
  objects to drill in.
- **Watch** - pin specific expressions you want to keep an eye on across
  steps (click the `+`, type any valid C++ expression).
- **Call Stack** - click any frame to jump the Variables/editor view to that
  point in the stack.
- **Breakpoints** - lists every breakpoint set anywhere in the project; check/
  uncheck to enable/disable without deleting.

Right-click a breakpoint's red dot for **conditional breakpoints** (e.g. only
break when `entitlement_name_ == "noveye"`) or **logpoints** (print a message
to the Debug Console instead of stopping - useful for tracing without
interrupting flow).

The **Debug Console** tab (bottom panel, next to Terminal) is a live
expression evaluator while stopped - type any C++ expression in scope and it
evaluates it immediately, e.g. `state`, `startup_noveye_status.reason` (in
`main.cpp`), `entitlement_name_.c_str()`.

## A concrete example: the licensing gate

To watch `LicenseEntitlementGate::CheckEntitlement()` handle a real daemon
response:

1. Open `back_end/licensing/src/LicenseEntitlementGate.cpp`.
2. Click in the gutter next to the `std::transform(...)` line (or the
   `if (state == "GRANTED")` line right after) to set a breakpoint.
3. Ctrl+Shift+D → select **"Debug: Celeste (Main Config, Debug Build)"** →
   F5. Every run now goes through "Build: Debug Configure" first (see
   above) - slower than a plain incremental build, but safe.
4. When it hits the breakpoint, hover `state` in the editor (or check the
   Variables panel) to see the daemon's raw response before normalization.

## Misc

- **Ctrl+`** (backtick) - toggle the integrated terminal panel.
- **Ctrl+P** - quick-open any file by name (not the Command Palette - no
  Shift).
- Status bar at the very bottom shows the current git branch, and (while a
  debug session is picked) sometimes the active launch config name - useful
  to confirm which one you're about to run before hitting F5.
