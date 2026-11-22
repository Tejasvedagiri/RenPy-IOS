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


# Python 2 module names that Ren'Py 7 games import, and their Python 3 homes.
# cPickle is special-cased in Py2ModuleFinder.
PY2_MODULES = {
    "__builtin__": "builtins",
    "ConfigParser": "configparser",
    "Queue": "queue",
    "copy_reg": "copyreg",
    "thread": "_thread",
    "dummy_thread": "_dummy_thread",
    "repr": "reprlib",
    "urllib2": "urllib.request",
    "urlparse": "urllib.parse",
    "httplib": "http.client",
    "HTMLParser": "html.parser",
    "htmlentitydefs": "html.entities",
    "cookielib": "http.cookiejar",
    "Cookie": "http.cookies",
    "SocketServer": "socketserver",
    "cStringIO": "io",
    "StringIO": "io",
}


_script_version_txt = []


def game_script_version(renpy):
    """
    The Ren'Py version the game was made for, or None if unknown. Reads
    script_version.txt itself when the game's config doesn't have it yet
    (e.g. while Ren'Py compiles the game's Python before init).
    """

    version = getattr(renpy.config, "script_version", None) or getattr(renpy.config, "early_script_version", None)

    if version:
        return tuple(version)

    if not _script_version_txt:
        try:
            import ast

            with renpy.loader.load("script_version.txt") as f:
                _script_version_txt.append(tuple(ast.literal_eval(f.read().decode("utf-8"))))
        except Exception:
            return None

    return _script_version_txt[0]


def python2_game(renpy):
    """
    True unless the game is known to be made for Ren'Py 8 (Python 3).
    """

    version = game_script_version(renpy)

    return not version or version < (8, 0, 0)


class Py2ModuleLoader(object):

    def __init__(self, renpy, name):
        self.renpy = renpy
        self.name = name

    def create_module(self, spec):
        import importlib
        import types

        if self.name == "cPickle":
            # Ren'Py's own pickle wrappers read Python 2 pickles (e.g. old
            # saves the game unpickles itself).
            import pickle

            compat_pickle = self.renpy.compat.pickle

            module = types.ModuleType("cPickle")
            module.__dict__.update((k, v) for k, v in vars(pickle).items() if not k.startswith("__"))
            module.load = compat_pickle.load
            module.loads = compat_pickle.loads
            module.dump = lambda obj, f, protocol=None: compat_pickle.dump(obj, f)
            module.dumps = lambda obj, protocol=None: compat_pickle.dumps(obj)
            return module

        module = importlib.import_module(PY2_MODULES[self.name])
        self.saved = (module.__spec__, getattr(module, "__loader__", None))
        return module

    def exec_module(self, module):
        # The import system sets __spec__ and __loader__ on the module we
        # returned; put the real module's back.
        saved = getattr(self, "saved", None)

        if saved:
            module.__spec__, module.__loader__ = saved


class Py2ModuleFinder(object):
    """
    Lets `import cPickle` and other Python 2 module names work in games made
    for Ren'Py 7, which ran on Python 2.
    """

    def __init__(self, renpy):
        self.renpy = renpy

    def find_spec(self, name, path=None, target=None):
        if name != "cPickle" and name not in PY2_MODULES:
            return None

        if not python2_game(self.renpy):
            return None

        import importlib.machinery

        return importlib.machinery.ModuleSpec(name, Py2ModuleLoader(self.renpy, name))


def patch_imports(renpy):
    import sys

    if not any(isinstance(i, Py2ModuleFinder) for i in sys.meta_path):
        sys.meta_path.append(Py2ModuleFinder(renpy))


def patch_dict_views(renpy):
    """
    On Python 2, dict.keys(), .values() and .items() returned lists, so Ren'Py 7
    games do things like random.choice(d.keys()). Dicts made in game code are
    RevertableDicts; for Python 2 games, make those methods return lists again.
    """

    RevertableDict = renpy.revertable.RevertableDict

    def list_method(view):
        def method(self):
            if python2_game(renpy):
                return list(view(self))

            return view(self)

        method.__name__ = view.__name__
        return method

    RevertableDict.keys = list_method(dict.keys)
    RevertableDict.values = list_method(dict.values)
    RevertableDict.items = list_method(dict.items)


def py2_order_key(x):
    """
    How Python 2 ordered values of different types: None first, then numbers,
    then everything else by type name.
    """

    import numbers

    if x is None:
        return (0, "")

    if isinstance(x, numbers.Number):
        return (1, "")

    return (2, type(x).__name__)


def py2_compare(op, a, b):
    try:
        return op(a, b)
    except TypeError:
        ka = py2_order_key(a)
        kb = py2_order_key(b)

        if ka == kb:
            raise

        return op(ka, kb)


PY2_COMPARE = "_renpy_player_py2_compare"


def patch_comparisons(renpy):
    """
    Python 2 let any two values be ordered (None < 0 is True), and Ren'Py 7
    games rely on it, e.g. `if Q_Giant > 0:` before Q_Giant is set. For Python 2
    games, compile <, <=, > and >= into a call that falls back to Python 2's
    ordering when Python 3 raises TypeError.
    """

    import ast
    import builtins
    import operator

    ops = {
        ast.Lt: "lt",
        ast.LtE: "le",
        ast.Gt: "gt",
        ast.GtE: "ge",
    }

    setattr(builtins, PY2_COMPARE, py2_compare)

    class Py2Comparisons(ast.NodeTransformer):

        def visit_Compare(self, node):
            self.generic_visit(node)

            # Chained comparisons (a < b < c) are left alone.
            if len(node.ops) != 1 or type(node.ops[0]) not in ops:
                return node

            call = ast.Call(
                func=ast.Name(id=PY2_COMPARE, ctx=ast.Load()),
                args=[
                    ast.Attribute(value=ast.Name(id="_renpy_player_operator", ctx=ast.Load()), attr=ops[type(node.ops[0])], ctx=ast.Load()),
                    node.left,
                    node.comparators[0],
                ],
                keywords=[],
            )

            return ast.copy_location(call, node)

    setattr(builtins, "_renpy_player_operator", operator)

    class PlayerWrapNode(object):
        """
        Stands in for renpy.python.wrap_node, which py_compile() runs on every
        piece of game Python.
        """

        def __init__(self, wrap_node):
            self.wrap_node = wrap_node
            self.transformer = Py2Comparisons()

        def visit(self, node):
            node = self.wrap_node.visit(node)

            if python2_game(renpy):
                node = ast.fix_missing_locations(self.transformer.visit(node))

            return node

    if not isinstance(renpy.python.wrap_node, PlayerWrapNode) and type(renpy.python.wrap_node).__name__ != "PlayerWrapNode":
        renpy.python.wrap_node = PlayerWrapNode(renpy.python.wrap_node)

    # Don't reuse bytecode compiled without this.
    CompileCache = renpy.python.CompileCache
    if not CompileCache.MAGIC_NUMBER.endswith(b"_player1"):
        CompileCache.MAGIC_NUMBER = CompileCache.MAGIC_NUMBER + b"_player1"


def patch_missing_expressions(renpy):
    """
    Older Ren'Py compiled a screen property with no value (a bare `xpos` line)
    to an expression of None, and its py_compile() did str(source), so it meant
    `xpos None`. 8.6.2 raises TypeError for it, so compile None as "None".
    """

    py_compile = renpy.python.py_compile
    if getattr(py_compile, "_renpy_player", False):
        return

    def player_py_compile(source, *args, **kwargs):
        if source is None:
            source = "None"
        return py_compile(source, *args, **kwargs)

    player_py_compile._renpy_player = True

    renpy.python.py_compile = player_py_compile
    # pyanalysis imported it by name.
    if renpy.pyanalysis.py_compile is py_compile:
        renpy.pyanalysis.py_compile = player_py_compile


def apply(renpy):
    patch_loader(renpy)
    patch_script(renpy)
    patch_imports(renpy)
    patch_dict_views(renpy)
    patch_comparisons(renpy)
    patch_missing_expressions(renpy)


def install():
    import renpy

    import_all = renpy.import_all

    def player_import_all():
        import_all()
        apply(renpy)

    renpy.import_all = player_import_all
