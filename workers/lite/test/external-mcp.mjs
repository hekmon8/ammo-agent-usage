import assert from 'node:assert/strict';

// Runs inside the existing ephemeral D1/Worker harness. No production access.
export async function verifyExternalMCP(base, writer, otherWriter, viewerHash, forceExpiry) {
  const token = 'synthetic-mcp-token-'.padEnd(43, 'a');
  const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream', 'mcp-protocol-version': '2025-11-25' };
  const writerHeaders = { authorization: `Bearer ${writer.deviceToken}`, 'content-type': 'application/json' };
  const rpc = async (method, params = {}, extra = {}) => {
    const response = await fetch(`${base}/mcp`, { method: 'POST', headers: { ...headers, ...extra }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
    return { response, body: await response.json() };
  };
  assert.equal((await rpc('tools/list')).response.status, 401);
  assert.equal((await rpc('tools/list', {}, { authorization: 'Bearer synthetic-expired-mcp-token-0000000000' })).response.status, 401);
  const hash = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token))).toString('hex');
  const setup = (tokenHash = hash) => fetch(`${base}/v1/mcp-access`, { method: 'PUT', headers: writerHeaders, body: JSON.stringify({ tokenHash, consent: 'share_redacted_quotas', sourceEpoch: writer.sourceEpoch }) });
  assert.equal((await fetch(`${base}/v1/mcp-access`, { method: 'PUT', headers: writerHeaders, body: JSON.stringify({ tokenHash: hash, consent: 'share_redacted_quotas', sourceEpoch: 'old-epoch' }) })).status, 400);
  const setupResponse = await setup();
  assert.equal(setupResponse.status, 200);
  assert.ok(Math.abs(Date.parse((await setupResponse.json()).expiresAt) - Date.now() - 90 * 86400000) < 5000);
  assert.equal((await rpc('tools/list', {}, { authorization: `Bearer ${writer.deviceToken}` })).response.status, 401);
  assert.equal((await rpc('tools/list', {}, { authorization: `Bearer ${otherWriter.deviceToken}` })).response.status, 401);
  assert.equal((await fetch(`${base}/v1/devices`, { headers })).status, 401);
  assert.equal((await rpc('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'test', version: '1' } })).body.result.protocolVersion, '2025-11-25');
  for (const protocolVersion of ['2025-03-26', '2025-06-18']) {
    assert.equal((await rpc('initialize', { protocolVersion, capabilities: {}, clientInfo: { name: 'test', version: '1' } }, { 'mcp-protocol-version': protocolVersion })).body.result.protocolVersion, protocolVersion);
  }
  assert.equal((await rpc('initialize', { protocolVersion: '2025-11-25' })).body.error.code, -32602);
  assert.deepEqual((await rpc('tools/list')).body.result.tools.map(x => x.name), ['quota_list', 'quota_get', 'quota_health']);
  assert.equal((await rpc('tools/list', {}, { origin: 'https://evil.invalid' })).response.status, 403);
  assert.equal((await rpc('tools/list', {}, { accept: 'application/json' })).response.status, 406);
  assert.equal((await rpc('tools/list', {}, { 'mcp-protocol-version': 'invalid' })).response.status, 400);
  assert.equal((await fetch(`${base}/mcp`, { headers })).status, 405);
  const notified = await fetch(`${base}/mcp`, { method: 'POST', headers, body: JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) });
  assert.equal(notified.status, 202);
  const call = name => rpc('tools/call', { name, arguments: {} });
  assert.equal(JSON.parse((await call('quota_health')).body.result.content[0].text).available, false);
  const window = { id: 'window1', providerId: 'codex', unit: 'percent', currency: null, quotaKey: 'primary', availability: 'available', remainingBps: 6400, amount: null, limit: null, quality: 'reported', fetchOutcome: 'ok', observedAt: new Date().toISOString(), staleAt: new Date(Date.now() + 300000).toISOString(), resetsAt: null };
  const projection = { sourceEpoch: writer.sourceEpoch, sequence: 10, capturedAt: new Date().toISOString(), windows: [window] };
  const upload = (body, h = writerHeaders) => fetch(`${base}/v1/mcp-snapshot`, { method: 'PUT', headers: h, body: JSON.stringify(body) });
  const uploaded = await upload(projection);
  assert.equal(uploaded.status, 200, await uploaded.text());
  assert.equal((await upload({ ...projection, sequence: 9 })).status, 409);
  assert.equal((await upload({ ...projection, windows: [{ ...window, accountAlias: 'never-share' }] })).status, 400);
  assert.equal((await upload({ ...projection, sourceEpoch: 'wrong-epoch' })).status, 400);
  assert.equal((await upload(projection, { ...writerHeaders, authorization: `Bearer ${otherWriter.deviceToken}` })).status, 400);
  const money = { ...window, unit: 'money', currency: 'USD', remainingBps: null, amount: '123456789012345678901.123456789012' };
  assert.equal((await upload({ ...projection, windows: [money] })).status, 409);
  assert.equal((await upload({ ...projection, sequence: 11, windows: [money] })).status, 200);
  const moneyResult = JSON.parse((await call('quota_list')).body.result.content[0].text);
  assert.equal(moneyResult.windows[0].currency, 'USD');
  assert.equal(moneyResult.windows[0].amount, money.amount);
  assert.equal((await upload(projection)).status, 409);
  assert.equal((await upload({ ...projection, sequence: 11, windows: [money] })).status, 200);
  const list = JSON.parse((await call('quota_list')).body.result.content[0].text);
  const otherHealth = await rpc('tools/call', { name: 'quota_health', arguments: {} }, { authorization: 'Bearer synthetic-other-mcp-token-000000000000' });
  assert.equal(JSON.parse(otherHealth.body.result.content[0].text).available, false);
  assert.equal(list.windows.length, 1); assert.equal(list.windows[0].stale, false);
  assert.equal(JSON.parse((await rpc('tools/call', { name: 'quota_get', arguments: { windowId: 'window1' } })).body.result.content[0].text).amount, money.amount);
  assert.equal((await rpc('tools/call', { name: 'quota_list', arguments: { secret: 'x' } })).body.error.code, -32602);
  assert.equal((await call('quota_refresh')).body.error.code, -32602);
  assert.equal((await rpc('unknown/method')).body.error.code, -32601);
  const write = (path, method, body, deviceToken = writer.deviceToken) => fetch(`${base}${path}`, { method, headers: { ...writerHeaders, authorization: `Bearer ${deviceToken}` }, body: JSON.stringify(body) });
  let activeHash = hash;
  const patch = (body = { lifetime: 'until_revoked', tokenHash: activeHash }) => write('/v1/mcp-access', 'PATCH', body);
  const setRefs = (shares, deviceToken, tokenHash = activeHash) => write('/v1/mcp-shares', 'PUT', { shares, tokenHash }, deviceToken);
  let activeToken = token;
  const ownRpc = (name, args = {}, selectedToken = activeToken) => rpc('tools/call', { name, arguments: args }, { 'cf-connecting-ip': '192.0.2.2', authorization: `Bearer ${selectedToken}` });
  const tool = async (...args) => {
    const { response, body } = await ownRpc(...args);
    assert.equal(response.status, 200);
    return JSON.parse(body.result.content[0].text);
  };
  const ref = { shareId: 'test-received-share', viewerTokenHash: viewerHash };
  assert.equal((await setRefs([ref], token)).status, 401);
  assert.equal((await setRefs([{ ...ref, viewerToken: 'plaintext-is-not-allowed' }])).status, 400);
  assert.equal((await setRefs([ref, ref])).status, 400);
  assert.equal((await setRefs(Array.from({ length: 33 }, (_, n) => ({ ...ref, shareId: `share${n}` })))).status, 400);
  assert.equal((await setRefs([ref])).status, 200);
  assert.equal((await tool('quota_health')).windowCount, 1); // Approved but no projection.
  const { id, providerId, ...receivedWindow } = window;
  const publish = (remainingBps) => write(`/v1/shares/${ref.shareId}/projection`, 'PUT', { capturedAt: new Date().toISOString(), windows: [{ ...receivedWindow, remainingBps }, { ...receivedWindow, remainingBps: 4050 }] }, otherWriter.deviceToken);
  assert.equal((await publish(5200)).status, 200);
  assert.equal((await setRefs([{ ...ref, viewerTokenHash: '0'.repeat(64) }, { ...ref, shareId: 'bogus-reference' }])).status, 200);
  assert.equal((await tool('quota_health')).windowCount, 1);
  assert.equal((await setRefs([ref])).status, 200);
  assert.equal((await setRefs([ref])).status, 200);
  assert.equal((await patch({ lifetime: 'until_revoked' })).status, 400);
  assert.equal((await patch({ lifetime: 'forever', tokenHash: hash })).status, 400);
  for (let i = 0; i < 2; i++) {
    const patched = await patch();
    assert.equal(patched.status, 200);
    assert.deepEqual(await patched.json(), { accepted: true, expiresAt: null });
  }
  await forceExpiry(hash);
  const merged = await tool('quota_list');
  assert.deepEqual(merged.windows.map(w => [w.providerId, w.source]), [['codex', 'local'], ['antigravity', 'received'], ['antigravity', 'received']]);
  assert.equal(merged.windows[0].id, 'window1');
  assert.equal(merged.windows[0].account, null); // Projection from a client without account tags.
  assert.equal(merged.windows[0].amount, money.amount);
  assert.match(merged.windows[1].account, /^[a-f0-9]{64}$/); // One share is one account.
  assert.equal(merged.windows[1].account, merged.windows[2].account);
  assert.notEqual(merged.windows[1].account, merged.windows[0].account);
  assert.ok(!/private-account|Private Share Label|private-connection|test-received-share/.test(JSON.stringify(merged)));
  const receivedId = merged.windows[1].id;
  assert.match(receivedId, /^rs\.[a-f0-9]{64}$/);
  assert.notEqual(receivedId, merged.windows[2].id);
  assert.equal((await tool('quota_get', { windowId: receivedId })).remainingBps, 5200);
  assert.equal((await publish(4800)).status, 200);
  assert.equal((await tool('quota_get', { windowId: receivedId })).remainingBps, 4800);
  assert.equal((await setRefs([])).status, 200);
  assert.equal((await tool('quota_health')).windowCount, 1);
  assert.equal((await setRefs([ref])).status, 200);
  const rotatedToken = 'synthetic-rotated-mcp-token-0000000000';
  const rotatedHash = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rotatedToken))).toString('hex');
  assert.equal((await setup(rotatedHash)).status, 200);
  assert.equal((await ownRpc('quota_health')).response.status, 401);
  activeToken = rotatedToken;
  activeHash = rotatedHash;
  assert.equal((await patch({ lifetime: 'until_revoked', tokenHash: hash })).status, 409);
  assert.equal((await setRefs([ref], undefined, hash)).status, 409);
  assert.equal((await tool('quota_health')).available, false); // Rotation clears local data and received refs.
  assert.equal((await setRefs([ref])).status, 200);
  assert.equal((await tool('quota_health')).windowCount, 2); // Received-only is available.
  assert.equal((await write(`/v1/shares/${ref.shareId}`, 'DELETE', undefined, otherWriter.deviceToken)).status, 200);
  assert.equal((await tool('quota_health')).available, false);
  assert.equal((await tool('quota_get', { windowId: receivedId })).available, false);
  await forceExpiry(rotatedHash);
  assert.equal((await ownRpc('quota_health')).response.status, 401);
  assert.equal((await patch()).status, 409);
  assert.equal((await setRefs([ref])).status, 409);
  assert.equal((await setup()).status, 200);
  activeHash = hash;
  // Several accounts of one provider: opaque `account` tags group their windows and filter quota_list.
  const [accountA, accountB] = ['a'.repeat(64), 'b'.repeat(64)];
  assert.equal((await upload({ ...projection, sequence: 12, windows: [{ ...money, account: 'not-a-digest' }] })).status, 400);
  const twoAccounts = [
    { ...window, id: 'a-primary', account: accountA },
    { ...window, id: 'a-secondary', quotaKey: 'secondary', account: accountA },
    { ...window, id: 'b-primary', account: accountB },
  ];
  assert.equal((await upload({ ...projection, sequence: 12, windows: twoAccounts })).status, 200);
  // This fresh grant belongs to the original token, not the rotated one `tool` still holds.
  const read = async (name, args = {}) => (await rpc('tools/call', { name, arguments: args })).body;
  const grouped = JSON.parse((await read('quota_list')).result.content[0].text);
  assert.deepEqual(grouped.windows.map(w => [w.id, w.account]), [['a-primary', accountA], ['a-secondary', accountA], ['b-primary', accountB]]);
  assert.deepEqual(JSON.parse((await read('quota_list', { account: accountB })).result.content[0].text).windows.map(w => w.id), ['b-primary']);
  assert.deepEqual(JSON.parse((await read('quota_list', { account: 'f'.repeat(64) })).result.content[0].text).windows, []);
  assert.equal(JSON.parse((await read('quota_get', { windowId: 'a-secondary' })).result.content[0].text).account, accountA);
  assert.equal((await read('quota_list', { account: 'short' })).error.code, -32602);
  assert.equal((await read('quota_list', { account: accountA, extra: 1 })).error.code, -32602);
  const stale = { ...window, observedAt: new Date(Date.now() - 120000).toISOString(), staleAt: new Date(Date.now() - 60000).toISOString() };
  assert.equal((await upload({ ...projection, sequence: 13, windows: [stale] })).status, 200);
  assert.equal((await patch()).status, 200);
  assert.equal(JSON.parse((await call('quota_health')).body.result.content[0].text).stale, true);
  // Revocation removes data and cannot be undone by a delayed uploader.
  assert.equal((await fetch(`${base}/v1/mcp-access`, { method: 'DELETE', headers: writerHeaders })).status, 200);
  assert.equal((await rpc('tools/list')).response.status, 401);
  assert.equal((await upload({ ...projection, sequence: 14 })).status, 409);
  assert.equal((await patch()).status, 409);
  assert.equal((await setRefs([])).status, 409);
  assert.equal((await setup()).status, 200);
  assert.equal(JSON.parse((await call('quota_health')).body.result.content[0].text).available, false);
  await fetch(`${base}/v1/mcp-access`, { method: 'DELETE', headers: writerHeaders });
}
