# Agent notes for RenPy Player

## Rules

- **Never fix the game.** Don't edit anything in `games/` to make a game run. Games come
  from many Ren'Py SDK versions and get re-synced from the NAS, so edits don't stick.
  Fix the app instead, usually in
  [`ios/overlay/renpy_player_compat.py`](ios/overlay/renpy_player_compat.py), gated on the
  game's Ren'Py version (`config.script_version`) where needed.
- Fixes must work for every game made with that Ren'Py version, not only the one that failed.

## How the app runs games

- Engine: Ren'Py 8.6.2 (Python 3), source in `.cache/renpy-8.6.2-sdk/renpy/`.
  The game's own `renpy/` and `lib/` folders are ignored.
- `scripts/apply_overlay.py` copies `renpy_player_compat.py` into `ios/RenPyPlayer/base/`
  and hooks `install()` into `base/main.py`. Patches are applied right after
  `renpy.import_all()`.
- After changing anything in `ios/overlay/`, run `scripts/setup.sh` (re-applies the
  overlay), then `./install.sh` to build and install on the phone.
- `setup.sh` rewrites signing settings, so always pass them:
  `TEAM_ID=4YB4ZBB6A3 BUNDLE_ID=com.tejasvedagiri.renpyplayer scripts/setup.sh`.
  Without them the build fails with "requires a development team".

## Debugging a game that fails

1. Read the traceback (screenshot, or `Documents/saves/<game>/traceback.txt` / `log.txt`,
   pulled with `xcrun devicectl device copy from ...`).
2. Find the game's Ren'Py version: `game/script_version.txt`, or `renpy/__init__.py` in
   the game folder.
3. Game scripts are often only in `.rpa` archives / `.rpyc` files. Extract them into the
   scratchpad to read them; never into `games/`.
4. Work out which engine difference (old Ren'Py vs 8.6.2, Python 2 vs 3) causes it and add
   a compat fix. Test it with the SDK's Python before installing.

## Compat fixes so far (`renpy_player_compat.py`)

- `.rpy` that doesn't compile on 8.6.2 → fall back to the game's shipped `.rpyc`.
- Games ≤ 7.5.3 / 8.0.3 → also search `game/images/` for files by name.
- Ren'Py 7 (Python 2) games → Python 2 module names (`cPickle`, `StringIO`, `urllib2`,
  `__builtin__`, ...) import their Python 3 equivalents. `cPickle` uses Ren'Py's
  `renpy.compat.pickle`, which reads Python 2 pickles.
- Ren'Py 7 (Python 2) games → `keys()`, `values()` and `items()` on dicts made in game code
  (RevertableDict) return lists again, so `random.choice(d.keys())` and `d.items()[0]` work.
  (`iteritems`, `has_key`, `unicode` and `xrange` are already provided by Ren'Py 8.)
- Ren'Py 7 (Python 2) games → `<`, `<=`, `>`, `>=` fall back to Python 2 ordering
  (None < numbers < other types) instead of raising TypeError, e.g. `Q_Giant > 0` while
  `Q_Giant` is None. Done by rewriting the AST in `renpy.python.wrap_node`; the bytecode
  cache magic is bumped so old cached bytecode isn't reused.
