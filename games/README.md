# games/

Drop Ren'Py games here, **one unzipped folder per game**. Every Xcode build copies this
folder into the app, and each game shows up in the app's library under "Included With App".

```
games/
  MyGame/                  <- the unzipped PC / Mac / Linux build
    game/                  <- must exist (scripts, images, .rpa archives…)
    renpy/  lib/  *.exe    <- fine to leave in; they're skipped when bundling
  AnotherGame-1.2-pc/
    game/
```

Also accepted: a folder that directly holds the game's `.rpy`/`.rpyc`/`.rpa` files, one
extra level of nesting (`games/MyGame/MyGame-1.0-pc/game`), and Mac builds
(`games/MyGame/MyGame.app`).

Zip files are **not** read by the app. Unzip them first, or let `sync.sh` do it.

## Syncing from the NAS

```sh
games/sync.sh             # copy new/changed games from the NAS's /home/tejas/renpy_games
games/sync.sh --dry-run   # preview
games/sync.sh --delete    # also delete local games that aren't on the NAS (including HelloWorld!)
```

It reads the SMB mount (`~/ugreen_nas/renpy_games`) and falls back to rsync over SSH.
Top-level `*.zip` files on the NAS are unzipped into their own folder.

Everything in here except this README is git-ignored.
