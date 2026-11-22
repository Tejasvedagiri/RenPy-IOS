#!/usr/bin/env python3
"""
Mirrors one game folder from games/ into a staging folder as hard links,
leaving out what the app doesn't need (the game's own Ren'Py, desktop
executables, archives). Hard links keep the files' modification times, which
is how `devicectl device copy to` skips files that are already on the phone.

    scripts/stage_games.py <games/Game> <stage/Game>

Files and folders in the stage that are no longer in the source are removed.
"""

import fnmatch
import os
import shutil
import sys

# Matched against each file or folder name.
EXCLUDE_NAMES = ["*.exe", "*.dll", "*.so", "*.dylib", "*.sh", "*.zip", "*.7z", "*.rar"]
# Folders inside a lib/ folder that hold a desktop Python.
EXCLUDE_LIB = ["py2-*", "py3-*", "python2.7", "python3.*"]


def excluded(rel, name, is_dir):
    if name.startswith("."):
        return True
    if is_dir:
        parts = rel.split(os.sep)
        # The game's own copy of Ren'Py: <Game>/renpy or <Game>/<Build>/renpy.
        if name == "renpy" and len(parts) <= 2:
            return True
        if len(parts) >= 2 and parts[-2] == "lib" and any(fnmatch.fnmatch(name, p) for p in EXCLUDE_LIB):
            return True
        return False
    return any(fnmatch.fnmatch(name, p) for p in EXCLUDE_NAMES)


def remove(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.unlink(path)


def mirror(src, dst, rel=""):
    os.makedirs(dst, exist_ok=True)
    keep = set()

    with os.scandir(src) as it:
        entries = list(it)

    for entry in entries:
        if entry.is_symlink():
            continue
        is_dir = entry.is_dir()
        sub = os.path.join(rel, entry.name)
        if excluded(sub, entry.name, is_dir):
            continue

        keep.add(entry.name)
        target = os.path.join(dst, entry.name)

        if is_dir:
            if os.path.lexists(target) and not os.path.isdir(target):
                remove(target)
            mirror(entry.path, target, sub)
            continue

        st = entry.stat()
        if os.path.lexists(target):
            tst = os.lstat(target)
            if tst.st_ino == st.st_ino and tst.st_dev == st.st_dev:
                continue
            remove(target)
        os.link(entry.path, target)

    for name in os.listdir(dst):
        if name not in keep:
            remove(os.path.join(dst, name))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip())
    mirror(os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]))


if __name__ == "__main__":
    main()
