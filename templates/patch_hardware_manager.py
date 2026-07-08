#!/usr/bin/env python3
"""Patch Waydroid's hardware_manager.py so suspend_action supports "none"
(never auto-suspend), instead of only "stop" vs. always-freeze. Without this,
Waydroid freezes its Android container the moment its window loses OS focus
-- including mid-boot -- which is fatal for an unattended/scripted launch."""
import sys

path = "/usr/lib/waydroid/tools/services/hardware_manager.py"

old = '''    def suspend():
        cfg = tools.config.load(args)
        if cfg["waydroid"]["suspend_action"] == "stop":
            tools.actions.session_manager.stop(args)
        else:
            tools.actions.container_manager.freeze(args)'''

new = '''    def suspend():
        cfg = tools.config.load(args)
        if cfg["waydroid"]["suspend_action"] == "stop":
            tools.actions.session_manager.stop(args)
        elif cfg["waydroid"]["suspend_action"] == "freeze":
            tools.actions.container_manager.freeze(args)
        # else: suspend_action == "none" -> do nothing, never auto-suspend'''

with open(path) as f:
    content = f.read()

if new in content:
    print("Already patched.")
    sys.exit(0)

if old not in content:
    print("WARNING: expected pattern not found -- hardware_manager.py may have "
          "changed upstream. Leaving file untouched; suspend-on-blur freeze "
          "bug may still occur.", file=sys.stderr)
    sys.exit(1)

with open(path + ".bak", "w") as f:
    f.write(content)

content = content.replace(old, new)
with open(path, "w") as f:
    f.write(content)

print("Patched hardware_manager.py (backup at hardware_manager.py.bak)")
