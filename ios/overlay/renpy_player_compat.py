# RenPy Player: runtime fixes that let games made for older Ren'Py versions run
# on the app's engine the way they do on the desktop.
#
# Copied into base/ by scripts/apply_overlay.py and installed by base/main.py.
# Patches are applied right after renpy.import_all(), before its module backup,
# so they survive Ren'Py's reloads.

from __future__ import print_function

import os


def legacy_images_prefix(renpy):
    """
    Ren'Py 7.5.3 / 8.0.3 and older also looked for every file in images/
    (e.g. define gui.text_font = "MyFont.ttf" with the font in game/images/).
    Ren'Py 8.1 kept that for old games; 8.6 dropped it.
    """

    # Neither exists until the game's script has started running.
    version = getattr(renpy.config, "script_version", None) or getattr(renpy.config, "early_script_version", None)

    if not version:
        return False

    version = tuple(version)

    if version <= (6, 99, 5):
        return False

    return version <= (7, 5, 3) or (version[0] == 8 and version <= (8, 0, 3))


def patch_loader(renpy):
    loader = renpy.loader
    get_prefixes = loader.get_prefixes

    def player_get_prefixes(tl=True, directory=None):
        # script_version is only known once the game's script has started, so
        # decide here rather than at startup. Config is reset on reload, so this
        # reapplies itself.
        if "images/" not in renpy.config.search_prefixes and legacy_images_prefix(renpy):
            renpy.config.search_prefixes = list(renpy.config.search_prefixes) + ["images/"]

        return get_prefixes(tl=tl, directory=directory)

    loader.get_prefixes = player_get_prefixes


def source_errors(renpy, data, errors_before):
    """
    True if parsing a .rpy file produced errors: either directly, or in the
    expressions Ren'Py compiles later (which is where it rejects things like
    `if x = True:` that older versions accepted).
    """

    if len(renpy.parser.parse_errors) > errors_before:
        return True

    for expr, context in (data or {}).get("expressions") or ():
        mode = "eval" if context == "unknown" else context

        try:
            renpy.python.py_compile(expr, mode)
        except SyntaxError:
            if context != "unknown":
                return True
        except Exception:
            pass

    return False


def patch_script(renpy):
    Script = renpy.script.Script
    load_file = Script.load_file

    def player_load_file(self, dir, fn):
        """
        Ren'Py 8.6 recompiles every .rpy that comes with an older .rpyc, since
        the .rpyc format marker changed. The game's own engine would have used
        the shipped .rpyc, so a .rpy it never compiled can have errors. When
        that happens, fall back to the shipped .rpyc.
        """

        if not dir or not fn.endswith(".rpy"):
            return load_file(self, dir, fn)

        rpycfn = dir + "/" + fn + "c"

        try:
            with open(rpycfn, "rb") as f:
                shipped_rpyc = f.read()
        except Exception:
            return load_file(self, dir, fn)

        parser = renpy.parser
        errors_before = len(parser.parse_errors)
        deferred_before = {k: list(v) for k, v in parser.deferred_parse_errors.items()}

        data, stmts = load_file(self, dir, fn)

        if not source_errors(renpy, data, errors_before):
            return data, stmts

        # Drop the errors from the failed compile.
        del parser.parse_errors[errors_before:]
        parser.deferred_parse_errors.clear()
        for k, v in deferred_before.items():
            parser.deferred_parse_errors[k].extend(v)

        # load_file() overwrites the .rpyc when the game folder is writable.
        try:
            with open(rpycfn, "rb") as f:
                changed = f.read() != shipped_rpyc

            if changed:
                with open(rpycfn, "wb") as f:
                    f.write(shipped_rpyc)
        except Exception:
            pass

        rpyc_data, rpyc_stmts = load_file(self, dir, fn + "c")

        if rpyc_data is None or rpyc_stmts is None:
            # The shipped .rpyc can't be used either: report the real errors.
            print("RenPy Player: {}c can't be loaded; reporting errors in {}".format(fn, fn))
            return load_file(self, dir, fn)

        print("RenPy Player: {} has errors; using the game's compiled {}c instead".format(fn, fn))
        return rpyc_data, rpyc_stmts

    Script.load_file = player_load_file


def apply(renpy):
    patch_loader(renpy)
    patch_script(renpy)


def install():
    import renpy

    import_all = renpy.import_all

    def player_import_all():
        import_all()
        apply(renpy)

    renpy.import_all = player_import_all
