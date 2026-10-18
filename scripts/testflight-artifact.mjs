import { readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';

// Xcode names the IPA after the archived product, not CFBundleDisplayName.
export function findExportedIPA(directory) {
  const candidates = readdirSync(directory, { withFileTypes: true })
    .filter(entry => /\.ipa$/i.test(entry.name));
  if (candidates.length !== 1 || !candidates[0].isFile()) {
    throw new Error('Expected exactly one regular exported IPA file.');
  }
  return join(resolve(directory), candidates[0].name);
}

export function validatePreparedIPA(directory, preparedPath) {
  const ipa = findExportedIPA(directory);
  if (typeof preparedPath !== 'string' || resolve(preparedPath) !== ipa) {
    throw new Error('Unexpected prepared IPA path.');
  }
  return ipa;
}
