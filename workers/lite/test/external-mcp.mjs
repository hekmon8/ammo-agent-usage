import assert from 'node:assert/strict';

// Runs inside the existing ephemeral D1/Worker harness. No production access.
export async function verifyExternalMCP(base, writer, otherWriter) {
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
  const setup = () => fetch(`${base}/v1/mcp-access`, { method: 'PUT', headers: writerHeaders, body: JSON.stringify({ tokenHash: hash, consent: 'share_redacted_quotas', sourceEpoch: writer.sourceEpoch }) });
  assert.equal((await fetch(`${base}/v1/mcp-access`, { method: 'PUT', headers: writerHeaders, body: JSON.stringify({ tokenHash: hash, consent: 'share_redacted_quotas', sourceEpoch: 'old-epoch' }) })).status, 400);
  assert.equal((await setup()).status, 200);
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
  assert.equal((await upload(projection)).status, 200);
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
  const stale = { ...window, observedAt: new Date(Date.now() - 120000).toISOString(), staleAt: new Date(Date.now() - 60000).toISOString() };
  assert.equal((await upload({ ...projection, sequence: 12, windows: [stale] })).status, 200);
  assert.equal(JSON.parse((await call('quota_health')).body.result.content[0].text).stale, true);
  // Revocation removes data and cannot be undone by a delayed uploader.
  assert.equal((await fetch(`${base}/v1/mcp-access`, { method: 'DELETE', headers: writerHeaders })).status, 200);
  assert.equal((await rpc('tools/list')).response.status, 401);
  assert.equal((await upload({ ...projection, sequence: 13 })).status, 409);
  assert.equal((await setup()).status, 200);
  assert.equal(JSON.parse((await call('quota_health')).body.result.content[0].text).available, false);
  await fetch(`${base}/v1/mcp-access`, { method: 'DELETE', headers: writerHeaders });
}
