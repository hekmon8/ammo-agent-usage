#!/usr/bin/env python3
"""Synthetic public-boundary CLI and official-SDK MCP lifecycle acceptance."""
import json, os, selectors, subprocess, tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='qi-cli-') as raw:
    directory = Path(raw)
    target = directory / 'latest-public.json'
    target.write_bytes((ROOT/'contracts/fixtures/01-fresh.json').read_bytes())
    target.chmod(0o600)
    qi = ROOT/'.build/debug/qi'
    def run(*args):
        return subprocess.run([str(qi), '--data-dir', raw, *args], text=True, capture_output=True, timeout=10)
    result = run('status', '--json')
    assert result.returncode == 0, result.stderr
    status = json.loads(result.stdout)
    assert status['schemaVersion'] == '1.0.0'
    assert run('status', '--require-fresh').returncode == 4
    assert run('refresh', '--wait', '--timeout', '1').returncode == 3
    assert run('quota', 'delete', '--window', 'anything').returncode == 2
    account_list = run('quota', 'list', '--provider', 'codex', '--account', 'account_demo')
    assert account_list.returncode == 0, account_list.stderr
    assert [w['accountId'] for w in json.loads(account_list.stdout)['windows']] == ['account_demo']
    assert json.loads(account_list.stdout)['windows'][0]['accountAlias']
    assert run('quota', 'list', '--account').returncode == 2
    assert json.loads(run('quota', 'list', '--account', 'nobody').stdout)['windows'] == []
    snapshot = json.loads(target.read_bytes())
    window = snapshot['windows'][0]
    now = datetime.now(timezone.utc)
    stamp = lambda delta: (now + delta).isoformat(timespec='seconds').replace('+00:00', 'Z')
    snapshot['capturedAt'] = stamp(timedelta())
    window.update(observedAt=stamp(timedelta(minutes=-1)), staleAt=stamp(timedelta(minutes=10)))
    period = window['window']
    period.update(startsAt=stamp(timedelta(hours=-1)), resetsAt=stamp(timedelta(seconds=period['durationSeconds'] - 3600)))
    target.write_text(json.dumps(snapshot))
    assert run('status', '--require-fresh').returncode == 0
    window['fetchOutcome'] = 'error'
    target.write_text(json.dumps(snapshot))
    assert run('status', '--require-fresh').returncode == 4
    assert json.loads(run('quota', 'list', '--exclude-stale').stdout)['windows'] == []
    child = subprocess.Popen([str(qi), '--data-dir', raw, 'mcp', 'serve', '--stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    selection = selectors.DefaultSelector(); selection.register(child.stdout, selectors.EVENT_READ)
    def send(value):
        child.stdin.write(json.dumps(value)+'\n'); child.stdin.flush()
    def receive(identifier):
        for _ in range(10):
            assert selection.select(5), 'MCP response timeout'
            line = child.stdout.readline()
            assert line, 'MCP ended early'
            value = json.loads(line)
            if value.get('id') == identifier: return value
        raise AssertionError('missing response')
    try:
        send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'qi-synthetic-test','version':'1'}}})
        assert 'result' in receive(1)
        send({'jsonrpc':'2.0','method':'notifications/initialized'})
        send({'jsonrpc':'2.0','id':2,'method':'tools/list','params':{}})
        tools = receive(2)['result']['tools']
        assert {x['name'] for x in tools} == {'quota_list','quota_get','quota_history','quota_health'}
        send({'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'quota_list','arguments':{}}})
        retained = json.loads(receive(3)['result']['content'][0]['text'])['windows'][0]
        assert retained['fetchOutcome'] == 'error' and retained['freshness'] == 'stale'
        assert retained['value']['remainingBps'] == window['remainingBps']
        send({'jsonrpc':'2.0','id':10,'method':'tools/call','params':{'name':'quota_list','arguments':{'includeStale':False}}})
        assert json.loads(receive(10)['result']['content'][0]['text'])['windows'] == []
        send({'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'shell','arguments':{'command':'invalid'}}})
        assert receive(4)['result']['isError'] is True
        send({'jsonrpc':'2.0','id':5,'method':'resources/read','params':{'uri':'quota://snapshot/latest'}})
        assert receive(5)['result']['contents'][0]['mimeType'] == 'application/json'
        responses = {}
        for identifier, name, arguments in [
            (6, 'quota_get', {'windowId': 'codex-primary'}),
            (7, 'quota_history', {'windowId': 'codex-primary', 'range': '24h'}),
            (8, 'quota_health', {}),
            (10, 'quota_list', {'providerId': 'codex', 'accountId': 'account_demo'}),
        ]:
            send({'jsonrpc':'2.0','id':identifier,'method':'tools/call','params':{'name':name,'arguments':arguments}})
            response = receive(identifier)['result']
            assert response.get('isError') is not True, response
            responses[identifier] = json.loads(response['content'][0]['text'])
            assert responses[identifier]['schemaVersion'] == '1.0.0'
        assert [(w['accountId'], w['accountAlias']) for w in responses[10]['windows']] == [('account_demo', '个人账户')]
        send({'jsonrpc':'2.0','id':11,'method':'tools/call','params':{'name':'quota_list','arguments':{'accountId': 'account_demo', 'extra': 1}}})
        assert receive(11)['result']['isError'] is True
        send({'jsonrpc':'2.0','id':9,'method':'resources/read','params':{'uri':'quota://providers'}})
        providers_resource = receive(9)['result']
        assert providers_resource['contents'][0]['mimeType'] == 'application/json'
        providers = json.loads(providers_resource['contents'][0]['text'])
        assert [(a['providerId'], a['accountId'], a['windowCount']) for a in providers['accounts']] == [('codex', 'account_demo', 1)]
        child.stdin.close(); child.wait(timeout=5)
        assert child.returncode == 0
    finally:
        if child.poll() is None: child.kill(); child.wait()
        selection.close()
print('PASS: CLI statuses/freshness/unavailable refresh and MCP initialize/tools/resources/read-only/EOF shutdown')
