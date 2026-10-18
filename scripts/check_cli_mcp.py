#!/usr/bin/env python3
"""Synthetic public-boundary CLI and official-SDK MCP lifecycle acceptance."""
import json, os, selectors, subprocess, tempfile
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
        assert receive(3)['result'].get('isError') is not True
        send({'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'shell','arguments':{'command':'invalid'}}})
        assert receive(4)['result']['isError'] is True
        send({'jsonrpc':'2.0','id':5,'method':'resources/read','params':{'uri':'quota://snapshot/latest'}})
        assert receive(5)['result']['contents'][0]['mimeType'] == 'application/json'
        for identifier, name, arguments in [
            (6, 'quota_get', {'windowId': 'codex-primary'}),
            (7, 'quota_history', {'windowId': 'codex-primary', 'range': '24h'}),
            (8, 'quota_health', {}),
        ]:
            send({'jsonrpc':'2.0','id':identifier,'method':'tools/call','params':{'name':name,'arguments':arguments}})
            response = receive(identifier)['result']
            assert response.get('isError') is not True, response
            assert json.loads(response['content'][0]['text'])['schemaVersion'] == '1.0.0'
        send({'jsonrpc':'2.0','id':9,'method':'resources/read','params':{'uri':'quota://providers'}})
        assert receive(9)['result']['contents'][0]['mimeType'] == 'application/json'
        child.stdin.close(); child.wait(timeout=5)
        assert child.returncode == 0
    finally:
        if child.poll() is None: child.kill(); child.wait()
        selection.close()
print('PASS: CLI statuses/freshness/unavailable refresh and MCP initialize/tools/resources/read-only/EOF shutdown')
