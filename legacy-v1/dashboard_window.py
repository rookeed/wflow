"""Flow Local — нативное окно дашборда (NSWindow + WKWebView).

Вся работа с окном — строго на main thread.
Если WebKit недоступен, открываем дашборд в браузере.
"""

import webbrowser

from AppKit import (NSApp, NSWindow, NSBackingStoreBuffered, NSMenu, NSMenuItem,
                    NSWindowStyleMaskTitled, NSWindowStyleMaskClosable,
                    NSWindowStyleMaskMiniaturizable, NSWindowStyleMaskResizable)
from Foundation import NSMakeRect, NSURL, NSURLRequest

try:
    import WebKit
    HAS_WEBKIT = True
except ImportError:
    HAS_WEBKIT = False


def _install_edit_menu():
    """Cmd+C/V/X/A в окне: у menu-bar приложения нет меню «Правка» —
    без него системные шорткаты не доходят до полей ввода."""
    main = NSApp.mainMenu()
    if main is None:
        main = NSMenu.alloc().initWithTitle_("Main")
        NSApp.setMainMenu_(main)
    if main.itemWithTitle_("Правка") is not None:
        return
    edit = NSMenu.alloc().initWithTitle_("Правка")
    for title, action, key in (("Вырезать", "cut:", "x"),
                               ("Скопировать", "copy:", "c"),
                               ("Вставить", "paste:", "v"),
                               ("Выделить всё", "selectAll:", "a")):
        edit.addItemWithTitle_action_keyEquivalent_(title, action, key)
    item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
        "Правка", None, "")
    item.setSubmenu_(edit)
    main.addItem_(item)


class DashboardWindow:
    W, H = 1150, 760

    def __init__(self):
        self.window = None
        self.webview = None

    def _build(self):
        style = (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                 NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
        rect = NSMakeRect(0, 0, self.W, self.H)
        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, style, NSBackingStoreBuffered, False)
        win.setTitle_("Flow Local")
        win.setReleasedWhenClosed_(False)  # закрытие = скрытие, не release
        win.center()
        win.setMinSize_((760, 480))
        cfg = WebKit.WKWebViewConfiguration.alloc().init()
        web = WebKit.WKWebView.alloc().initWithFrame_configuration_(rect, cfg)
        web.setAutoresizingMask_(18)  # width | height sizable
        win.contentView().addSubview_(web)
        self.window, self.webview = win, web

    def show(self, url):
        """Вызывать только с main thread."""
        if not HAS_WEBKIT:
            webbrowser.open(url)
            return
        if self.window is None:
            self._build()
        _install_edit_menu()
        req = NSURLRequest.requestWithURL_(NSURL.URLWithString_(url))
        self.webview.loadRequest_(req)
        NSApp.activateIgnoringOtherApps_(True)
        self.window.makeKeyAndOrderFront_(None)
