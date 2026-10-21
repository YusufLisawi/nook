"""Structural guards for paths that could accidentally resurrect a disabled service."""
from pathlib import Path
services = Path('Nook/Core/Services.swift').read_text()
assert 'let media = MediaController()' not in services
assert 'Features.shared.start(self)' in services
assert 'LauncherFeature.start()' not in services
assert 'FileNameIndex.shared.shutdown()' not in services
hover = Path('Nook/NotchController.swift').read_text()
assert 'Timer(' not in hover and 'addGlobalMonitorForEvents(matching: mask' in hover
web = Path('Nook/Core/WebPluginHost.swift').read_text()
assert 'Features.shared.allowsBridge(fn)' in web
assert 'removeScriptMessageHandler(forName: "nook")' in web
assert 'nookFeaturesChanged' in web and 'self.unload(id)' in web
assert 'settingsController.prewarm()' not in Path('Nook/AppDelegate.swift').read_text()
print('Features: startup, bridge, view eviction and event-driven hover guards passed')

launcher = Path('Nook/Core/PluginSearchMode.swift').read_text()
assert 'LauncherApplicationIndex' not in launcher and 'FileSearchService' not in launcher
for folder in ['Files', 'Clips', 'Windows', 'Launcher']:
    assert not list(Path('Nook/Services', folder).glob('*.swift')), folder
assert 'Services/Files/FileNameIndex.c' not in Path('project.yml').read_text()
assert 'var hold: DictationShortcut? = .defaultHold' not in Path('Nook/Services/Dictation/HotkeyMonitor.swift').read_text()
