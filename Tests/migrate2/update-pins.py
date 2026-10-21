#!/usr/bin/env python3
"""Pin reviewed local package bytes for built-in-to-Store adoption. No network/install/publish."""
from pathlib import Path
import hashlib,re
root=Path(__file__).resolve().parents[2]
digests={}
for package in ['commands','agents','dictation','mixer']:
 folder=root/'store/plugins'/package
 digest=hashlib.sha256()
 for file in sorted((p for p in folder.rglob('*') if p.is_file()), key=lambda p:p.relative_to(folder).as_posix().encode()):
  relative=file.relative_to(folder).as_posix()
  assert not file.is_symlink() and not any(c.startswith('.') for c in file.relative_to(folder).parts),file
  data=file.read_bytes(); mode='100755' if file.stat().st_mode & 0o111 else '100644'
  digest.update(f'{relative}\0{mode}\0{len(data)}\0'.encode());digest.update(data)
 digests[package]=digest.hexdigest()
p=root/'Nook/Core/PluginEngine/PluginDailyMigration.swift'
s=p.read_text();start=s.index('  static let digests:');end=s.index('  static func captureLegacyInstall',start)
s=s[:start]+'  static let digests: [String: String] = [\n'+''.join(f'    "{k}": "{v}",\n' for k,v in digests.items())+'  ]\n'+s[end:];p.write_text(s)
for package,digest in digests.items():print(package,digest)
