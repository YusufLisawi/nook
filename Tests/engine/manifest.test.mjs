import test from 'node:test';
import assert from 'node:assert/strict';
import { validateV2 } from '../../store/scripts/validate-v2.mjs';

const base = { id: 'test', name: 'Test', apiVersion: 2 };
const files = [{ path: 'helper.py', executable: false }, { path: 'bin/helper', executable: true }];
test('legacy web manifests and v2 interpreter/command forms', () => {
  for (const manifest of [{ id: 'old', name: 'Old' }, { ...base, native: { command: 'bin/helper' } }, { ...base, native: { run: ['python3', 'helper.py'] } }, { ...base, native: { command: { run: ['python3', 'helper.py'] } } }]) assert.deepEqual(validateV2(manifest, files), []);
});
test('v2 rejects malformed/unsafe helper declarations and missing permissions', () => {
  for (const patch of [
    { apiVersion: true }, { apiVersion: 3 }, { apiVersion: 2.5 }, { apiVersion: 1, native: {} },
    { native: { command: '../escape' } }, { native: { command: '/bin/sh' } },
    { native: { run: ['python3', '-c', 'print(1)'] } }, { native: { run: ['env', 'helper.py'] } },
    { native: { command: 'bin/missing' } }, { native: { command: 'bin/helper', background: true } },
    { native: { command: 'bin/helper', background: 1 } }, { permissions: ['all'] },
    { contributes: { hotkeys: [{ id: 'x' }] } }, { contributes: { invalid: [] } },
    { contributes: { settings: [{ id: 'x' }, { id: 'x' }] } },
  ]) assert.ok(validateV2({ ...base, ...patch }, files).length, JSON.stringify(patch));
});
test('contribution capabilities and background declared explicitly', () => {
  assert.deepEqual(validateV2({ ...base, native: { command: 'bin/helper', background: true, permissions: ['background', 'hotkeys'] }, contributes: { hotkeys: [{ id: 'toggle', keyCode: 49, modifiers: 0x80000 }], backgroundJobs: [{ id: 'refresh', interval: 60 }] } }, files), []);
});
