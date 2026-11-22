#!/usr/bin/env python3
"""
Turns a stock renios Xcode project (made by `renpy.sh launcher ios_create`)
into RenPy Player:

  * swaps main.c for ios/overlay/main.m (the game library UI),
  * removes the old "Bundle games" build phase (games are copied to the
    phone's storage by scripts/push_games.sh instead of into the app),
  * exposes Documents/ to Finder and the Files app,
  * lets base/main.py write logs next to each game's saves,
  * installs ios/overlay/renpy_player_compat.py (fixes for games made with
    older Ren'Py versions),
  * sets the bundle id / team.

Safe to run more than once.
"""

import argparse
import os
import plistlib
import re
import shutil
import sys
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OVERLAY = os.path.join(ROOT, "ios", "overlay")

GAMES_PHASE_NAME = "Bundle games"

LOGDIR_PATCH = """    import renpy  # @UnresolvedImport

    if "RENPY_PLAYER_LOGDIR" in os.environ:
        return os.environ["RENPY_PLAYER_LOGDIR"]

    if renpy.android:
        return os.environ["ANDROID_PUBLIC"]
"""

COMPAT_PATCH = """    except ImportError:
        print("Could not import renpy.bootstrap. Please ensure you decompressed Ren'Py", file=sys.stderr)
        print("correctly, preserving the directory structure.", file=sys.stderr)
        raise

    # RenPy Player: fixes for games made with older Ren'Py versions.
    import renpy_player_compat

    renpy_player_compat.install()
"""


def new_id():
    return uuid.uuid4().hex[:24].upper()


def pbxproj_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def find_pbxproj(project):
    for name in os.listdir(project):
        if name.endswith(".xcodeproj"):
            return os.path.join(project, name, "project.pbxproj")
    sys.exit(f"No .xcodeproj found in {project}")


def patch_sources(project, text):
    shutil.copy(os.path.join(OVERLAY, "main.m"), os.path.join(project, "main.m"))

    main_c = os.path.join(project, "main.c")
    if os.path.exists(main_c):
        os.unlink(main_c)

    text = re.sub(r"\bmain\.c\b", "main.m", text)
    text = re.sub(
        r"(lastKnownFileType\s*=\s*)sourcecode\.c\.c(;\s*path\s*=\s*main\.m;)",
        r"\1sourcecode.c.objc\2",
        text,
    )
    return text


def remove_games_phase(text):
    # Older versions of this script added a build phase that copied games/ into the app.
    m = re.search(r"\t\t(\w+) /\* %s \*/ = \{\n.*?\n\t\t\};\n" % GAMES_PHASE_NAME, text, flags=re.S)
    if not m:
        return text
    text = text.replace(m.group(0), "", 1)
    text = re.sub(r"\n\s*%s /\* %s \*/," % (m.group(1), GAMES_PHASE_NAME), "", text)
    return text


def patch_build_settings(text, bundle_id, team):
    # Target configurations are the ones that set INFOPLIST_FILE.
    def fix_config(m):
        block = m.group(0)
        indent = re.search(r"\n(\s*)INFOPLIST_FILE", block).group(1)

        block = re.sub(r"\n\s*ENABLE_USER_SCRIPT_SANDBOXING = \w+;", "", block)
        block = block.replace(
            "\n" + indent + "INFOPLIST_FILE",
            f"\n{indent}ENABLE_USER_SCRIPT_SANDBOXING = NO;\n{indent}INFOPLIST_FILE",
            1,
        )
        block = re.sub(
            r"PRODUCT_BUNDLE_IDENTIFIER = [^;]+;",
            f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};",
            block,
        )
        block = re.sub(
            r"DEVELOPMENT_TEAM = [^;]*;",
            f"DEVELOPMENT_TEAM = {pbxproj_string(team)};",
            block,
        )
        return block

    text = re.sub(
        r"buildSettings = \{(?:(?!\n\t\t\};).)*?INFOPLIST_FILE(?:(?!\n\t\t\};).)*",
        fix_config,
        text,
        flags=re.S,
    )
    text = re.sub(r"DevelopmentTeam = [^;]*;", f"DevelopmentTeam = {pbxproj_string(team)};", text)
    return text


def patch_info_plist(project, display_name):
    fn = os.path.join(project, "Info.plist")
    with open(fn, "rb") as f:
        plist = plistlib.load(f)

    plist["CFBundleDisplayName"] = display_name
    plist["UIFileSharingEnabled"] = True
    plist["LSSupportsOpeningDocumentsInPlace"] = True
    plist["UISupportsDocumentBrowser"] = False

    with open(fn, "wb") as f:
        plistlib.dump(plist, f)


def patch_main_py(project):
    fn = os.path.join(project, "base", "main.py")
    if not os.path.exists(fn):
        print(f"warning: {fn} not found; skipping base/main.py patches.")
        return

    shutil.copy(os.path.join(OVERLAY, "renpy_player_compat.py"), os.path.join(project, "base", "renpy_player_compat.py"))

    with open(fn) as f:
        text = f.read()

    if "RENPY_PLAYER_LOGDIR" not in text:
        original = """    import renpy  # @UnresolvedImport

    if renpy.android:
        return os.environ["ANDROID_PUBLIC"]
"""
        if original in text:
            text = text.replace(original, LOGDIR_PATCH, 1)
        else:
            print("warning: path_to_logdir() in base/main.py has an unexpected shape; skipping log directory patch.")

    if "renpy_player_compat" not in text:
        original = COMPAT_PATCH.split("\n\n    # RenPy Player")[0] + "\n"
        if original in text:
            text = text.replace(original, COMPAT_PATCH, 1)
        else:
            print("warning: main() in base/main.py has an unexpected shape; skipping compatibility patch.")

    with open(fn, "w") as f:
        f.write(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("project", help="The renios Xcode project directory (e.g. ios/RenPyPlayer).")
    ap.add_argument("--bundle-id", default="com.example.renpyplayer")
    ap.add_argument("--team", default="", help="Apple Developer Team ID (leave empty to pick it in Xcode).")
    ap.add_argument("--display-name", default="RenPy Player")
    args = ap.parse_args()

    project = os.path.abspath(args.project)
    pbxproj = find_pbxproj(project)

    with open(pbxproj) as f:
        text = f.read()

    text = patch_sources(project, text)
    text = remove_games_phase(text)
    text = patch_build_settings(text, args.bundle_id, args.team)

    with open(pbxproj, "w") as f:
        f.write(text)

    patch_info_plist(project, args.display_name)
    patch_main_py(project)

    print(f"Patched {project}")


if __name__ == "__main__":
    main()
