# RenPy Player for iOS

An iPhone/iPad app that plays Ren'Py games. It's built on Ren'Py's official iOS runtime
(renios, Ren'Py 8.6.2) with a native game library in front of it.

1. Pick a game from the list.
2. Ren'Py starts that game.
3. Saves are kept per game in `Documents/saves/<game folder>/`.

## Getting games onto the phone

There are three ways, and you can mix them:

| Way | How |
| --- | --- |
| **Repo `games/` folder** | Put unzipped game folders in [`games/`](games/README.md) and build in Xcode. They're bundled into the app. |
| **Finder / Files app** | Connect the iPhone to your Mac → Finder → iPhone → **Files** → RenPy Player → drag folders into `games`. Or on the phone: Files → On My iPhone → RenPy Player → games. |
| **+ button in the app** | Import a game folder from iCloud Drive or another location in Files. It's copied into the app. |

Games need to be **unzipped**. Use the regular PC/Mac/Linux download. The game's own
`renpy/` and `lib/` folders are ignored, because the app ships its own engine.

## Setup (once)

Requirements: macOS with Xcode, and an Apple ID for signing. A free account works for
your own device.

```sh
scripts/setup.sh            # optional: TEAM_ID=ABCDE12345 BUNDLE_ID=com.you.renpyplayer scripts/setup.sh
open ios/RenPyPlayer/*.xcodeproj
```

`setup.sh`:

1. downloads the Ren'Py 8.6.2 SDK and renios into `.cache/`,
2. runs Ren'Py's own iOS packager (`renpy.sh launcher ios_create`) to make the Xcode
   project, which contains the engine, Python and the prebuilt libraries,
3. runs `scripts/apply_overlay.py`, which:
   - replaces `main.c` with [`ios/overlay/main.m`](ios/overlay/main.m) (the library UI and launcher),
   - adds a **Bundle games** build phase that copies `games/` into the app,
   - turns on Files app / Finder access to the app's Documents folder,
   - sends Ren'Py's `log.txt` to each game's save folder.

In Xcode, choose your Team under *Signing & Capabilities*, plug in the iPhone, and press Run.
After that you only need Xcode: adding games to `games/` and pressing Run again is enough.

Or reinstall from the terminal, without opening Xcode:

```sh
./install.sh               # build, install on the connected iPhone, and launch
./install.sh --no-launch   # DEVICE="My iPhone" or CONFIGURATION=Debug also work
```

Installing over the existing app keeps its saves and imported games.

If you change `ios/overlay/main.m`, run `scripts/setup.sh` again. It re-applies the
overlay without regenerating the project. `--force` regenerates the project from scratch.

## Notes and limits

- **Engine version:** games run on Ren'Py 8.6.2. Games made with Ren'Py 8.x generally work.
  Ren'Py 7.x (Python 2) games may fail if they include custom Python code.
- **Switching games:** quitting a game closes the app (Ren'Py can only start once per
  process). Open the app again to pick another game.
- **Mods / PC-only code:** games that depend on desktop features (Steam, opening local
  files, native libraries) may not work.
- **Logs:** if a game crashes, look for `log.txt` / `traceback.txt` in
  `Files → RenPy Player → saves → <game>`.
- Games bundled in the app are read-only. Ren'Py handles this, but games that ship only
  `.rpy` sources compile more slowly on every launch. Putting them in Documents
  (Finder/Files) lets Ren'Py cache the compiled scripts.
