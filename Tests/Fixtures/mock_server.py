"""Synthetic local fixture. No credentials, disk access, or networking."""
import json
import sys
import time
import os
import signal

mode = sys.argv[1] if sys.argv[1] != "app-server" else "normal"
initialized = False
token_request_rejected = False

def send(value):
    data = json.dumps(value) + '\n'
    # Exercise fragmented pipe reads.
    sys.stdout.write(data[:5])
    sys.stdout.flush()
    time.sleep(0.002)
    sys.stdout.write(data[5:])
    sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    if method == 'initialize':
        send({'id': message['id'], 'result': {'userAgent': 'synthetic'}})
    elif method == 'initialized':
        initialized = True
    elif method == 'account/rateLimits/read':
        assert initialized
        if mode == 'stubborn':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            send({'id': message['id'], 'result': {'pid': os.getpid()}})
            while True:
                time.sleep(1)
        if mode == 'huge':
            sys.stdout.write('x' * 2_000_000)
            sys.stdout.flush()
            continue
        if mode == 'flood':
            while True:
                sys.stdout.write('{"method":"unknown/notification","params":{}}\n' * 2000)
                sys.stdout.flush()
        if mode in ('bool-id', 'fraction-id', 'array-result', 'both-fields'):
            response = {'id': message['id'], 'result': {}}
            if mode == 'bool-id': response['id'] = True
            if mode == 'fraction-id': response['id'] = 2.5
            if mode == 'array-result': response['result'] = []
            if mode == 'both-fields': response['error'] = {'code': -1}
            send(response)
            continue
        if mode == 'timeout':
            continue
        if mode == 'exit':
            sys.exit(0)
        if mode == 'malformed':
            sys.stdout.write('invalid-json\n')
            sys.stdout.flush()
            continue
        if mode == 'auth':
            send({'id': message['id'], 'error': {'code': -32600, 'message': 'Codex account authentication required'}})
            continue
        send({'method': 'unknown/notification', 'params': {}})
        send({'method': 'account/chatgptAuthTokens/refresh', 'id': 'external-auth', 'params': {}})
        send({'id': message['id'], 'result': {'rateLimits': {
            'primary': {'usedPercent': 32, 'windowDurationMins': 300, 'resetsAt': 1800000000},
            'secondary': {'usedPercent': 54, 'windowDurationMins': 10080, 'resetsAt': 1800100000}}}})
    elif message.get('id') == 'external-auth':
        assert message['error']['code'] == -32601
        assert 'result' not in message
        token_request_rejected = True
    elif method == 'account/usage/read':
        assert initialized and token_request_rejected
        if mode == 'unsupported':
            send({'id': message['id'], 'error': {'code': -32601, 'message': 'Method not found'}})
        else:
            send({'id': message['id'], 'result': {'summary': {'lifetimeTokens': 123}}})
    else:
        raise AssertionError('Unexpected client method')
