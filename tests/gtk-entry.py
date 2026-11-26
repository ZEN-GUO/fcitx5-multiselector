#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# Minimal GTK3 text entry used by tests/integration.sh.  It only exists so a
# real fcitx5 input context can be focused under Xvfb.
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

win = Gtk.Window(title="smoke")
win.set_default_size(480, 160)
entry = Gtk.Entry()
win.add(entry)
win.connect("destroy", Gtk.main_quit)
win.show_all()
entry.grab_focus()
Gtk.main()
