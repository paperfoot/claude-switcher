#!/usr/bin/env python3
"""Build a local adapter from an installed, exactly verified vendor extension."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

VERSION = '1.0.98'
HASHES = {
    'manifest.json': '8c8700f49e11f83489f5b79c7abb51d3828fc87c9c19cea3db354f8350bd2f21',
    'assets/service-worker.ts-V-8fXAa7.js': 'bbc60ce0305c9afa0667087bf64df4d268b63471b5421b13d6b866db8c3835ed',
    'assets/SavedPromptsService-YcP6ns-3.js': '1eb977e69ee5ed54e7a850a3d330d75b4487622870877308a4ac911cb5143e15',
}
AUTH = 'assets/SavedPromptsService-YcP6ns-3.js'
WORKER = 'assets/service-worker.ts-V-8fXAa7.js'
COMPANION = 'hlldhcbaknomojegdfceljiepokkhcll'

AUTH_HOOK = '''
export const paperfootOAuth = {
  config: () => p().oauth,
  epoch: cr,
  invalidate: () => ++re,
  random: () => sr(32),
  challenge: ir,
  exchange: or,
  verify: token => Ir(token, {forceRefresh: true}),
  commit: (tokens, state, epoch) => ar(tokens, state, {unlessAuthResetSince: epoch})
};
'''
WORKER_HOOK = '''
import {paperfootOAuth} from './SavedPromptsService-YcP6ns-3.js';
import {installAccountLink} from './paperfoot-account-link.js';
installAccountLink({chromeAPI: chrome, oauth: paperfootOAuth, currentAccount: () => T(undefined, {forceRefresh: true}),
  afterSwitch: async (previous, next) => {
    V(); Ai();
    await qi(async () => { if (!await de(q.PERMISSION_CONSENT_OWNER)) await L(P); });
    await Wi(next);
    if (previous !== next) {
      Bt();
      await A(); await A();
      if (previous !== undefined) await L(q.LAST_ACTIVE_ORG_HINT);
      if (previous !== undefined && next !== undefined) await z.clearForAccountSwitch(Vi);
    }
    h().catch(() => {}).then(() => Ut());
    ui(); G(); Q();
  }
});
'''


def build(source, destination):
    source, destination = Path(source).resolve(), Path(destination).absolute()
    if destination.resolve() == source or source in destination.resolve().parents:
        raise ValueError('Output must be outside the vendor source')
    if destination.exists() or destination.is_symlink():
        raise ValueError('Output must be a new directory')
    for filename, expected in HASHES.items():
        file = source / filename
        if file.is_symlink() or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
            raise ValueError(f'Unreviewed vendor file: {filename}')
    manifest = json.loads((source / 'manifest.json').read_text())
    if manifest['version'] != VERSION:
        raise ValueError('Unreviewed vendor version')
    if any(file.is_symlink() for file in source.rglob('*')):
        raise ValueError('Vendor source contains a symlink')
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns('_metadata'))
    try:
        manifest['externally_connectable']['ids'] = [COMPANION]
        manifest['version_name'] = VERSION + ' · Paperfoot account link'
        manifest.pop('update_url', None)
        (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        for filename, addition in [(AUTH, AUTH_HOOK), (WORKER, WORKER_HOOK)]:
            with (destination / filename).open('a') as stream:
                stream.write(addition)
        shutil.copyfile(Path(__file__).with_name('account-link.js'), destination / 'assets/paperfoot-account-link.js')
        (destination / 'paperfoot-build.json').write_text(json.dumps({'vendorVersion': VERSION, 'vendorHashes': HASHES}, indent=2) + '\n')
    except Exception:
        shutil.rmtree(destination)
        raise
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source')
    parser.add_argument('destination')
    args = parser.parse_args()
    try:
        print(build(args.source, args.destination))
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
