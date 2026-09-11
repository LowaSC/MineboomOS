#!/usr/bin/env python3
"""Runs tests/run.lua under Lua 5.1 (pip install lupa). Exit code 1 on failure."""
import os, sys
try:
    from lupa import lua51
except ImportError:
    sys.exit("pip install lupa   (Lua 5.1 runtime is required)")

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.environ["MINEBOOM_REPO"] = repo
lua = lua51.LuaRuntime(unpack_returned_tuples=True)
with open(os.path.join(repo, "tests", "run.lua"), encoding="utf-8") as f:
    src = f.read()
lua.execute(src)
