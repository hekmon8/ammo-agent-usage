// Shared by the local release command and CI; no credentials are read here.
export function exportOptions(teamID, bundleID, env = process.env) {
  const options = {method: 'app-store-connect', teamID, signingStyle: 'automatic', testFlightInternalTestingOnly: true};
  if (!env.IOS_SIGNING_STYLE) return options;
  if (env.IOS_SIGNING_STYLE !== 'manual') throw new Error('Only explicit manual CI signing is supported.');
  const profiles = JSON.parse(env.IOS_PROVISIONING_PROFILES || '{}');
  const expected = [bundleID, `${bundleID}.widgets`].sort();
  if (JSON.stringify(Object.keys(profiles).sort()) !== JSON.stringify(expected) ||
      Object.values(profiles).some(value => typeof value !== 'string' || !value.trim() || /[\r\n]/.test(value))) {
    throw new Error('Manual signing requires exact app and widget profile names.');
  }
  return {...options, signingStyle: 'manual', signingCertificate: 'Apple Distribution', provisioningProfiles: profiles};
}
