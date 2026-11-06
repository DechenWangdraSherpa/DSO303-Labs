#!/usr/bin/env python3
"""Dependency-free teaching alternatives; no AWS credentials or course mutations."""
import argparse
import collections
import contextlib
import http.server
import json
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

@contextlib.contextmanager
def server(handler):
    instance = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    thread = threading.Thread(target=instance.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{instance.server_port}'
    finally:
        instance.shutdown()
        instance.server_close()
        thread.join()

class QuietHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, status, message):
        body = message.encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

def routing():
    def backend(name):
        class Backend(QuietHandler):
            def do_GET(self):
                self.reply(200, name)
        return Backend

    with server(backend('backend-A')) as a, server(backend('backend-B')) as b:
        class Router(QuietHandler):
            def do_GET(self):
                target = a if self.path.startswith('/enrolment') else b
                with urllib.request.urlopen(target, timeout=3) as response:
                    self.reply(response.status, response.read().decode())
        with server(Router) as proxy:
            for path, expected in [('/enrolment', 'backend-A'), ('/results', 'backend-B')]:
                with urllib.request.urlopen(proxy + path, timeout=3) as response:
                    actual = response.read().decode()
                assert actual == expected
                print(f'{path} -> {actual} (HTTP 200)')
    print('Routing complete; all three HTTP servers closed.')

def scaling():
    workers = []
    def resize(count):
        while len(workers) < count:
            workers.append(subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']))
        while len(workers) > count:
            process = workers.pop()
            process.terminate()
            process.wait()
        assert all(process.poll() is None for process in workers)
        print(f'Live worker processes: {len(workers)}')
    try:
        print('Accelerated schedule: morning=3 workers, evening=1 worker')
        resize(3)
        resize(1)
        for queue_depth in (20, 0):
            desired = 3 if queue_depth > 10 else 1
            print(f'Synthetic queue depth={queue_depth}; local controller requests {desired}')
            resize(desired)
    finally:
        resize(0)
    print('Scaling complete; all worker processes stopped. No ECS autoscaler was used.')

def security():
    print('Teaching policy model: identity allow INTERSECT boundary allow; explicit deny wins.')
    identity = {'s3:GetObject', 's3:PutObject'}
    boundary = {'s3:GetObject'}
    denied = {'s3:DeleteObject'}
    for action in ('s3:GetObject', 's3:PutObject', 's3:DeleteObject'):
        allowed = action in identity and action in boundary and action not in denied
        print(f'{action}: {"ALLOW" if allowed else "DENY"}')
    class TokenGate(QuietHandler):
        def do_GET(self):
            if self.headers.get('X-Lab-Token') != 'student-demo':
                self.reply(401, 'token required')
            else:
                self.reply(200, 'fictional metadata')
    with server(TokenGate) as endpoint:
        try:
            urllib.request.urlopen(endpoint, timeout=3)
            raise AssertionError('Unauthenticated request was accepted')
        except urllib.error.HTTPError as error:
            assert error.code == 401
            print('Without token: HTTP 401')
        request = urllib.request.Request(endpoint, headers={'X-Lab-Token': 'student-demo'})
        with urllib.request.urlopen(request, timeout=3) as response:
            assert response.status == 200
            print('With token: HTTP 200')
    print('Model only: this is not an IAM evaluator or an IMDSv2 implementation.')

def observability():
    trace_id = 'student-local-trace'
    events = []
    for faculty, seconds in [('science', 0.5), ('engineering', 2.4), ('engineering', 3.1)]:
        event = dict(event='transcript.processed', faculty=faculty, seconds=seconds,
                     trace_id=trace_id, timestamp=time.time())
        events.append(event)
        print(json.dumps(event))
    print('Counts by faculty:', dict(collections.Counter(e['faculty'] for e in events)))
    lag_high = max(e['seconds'] for e in events) > 2
    silence = len(events) == 0
    print(f'Local condition evaluation: lag_high={lag_high}, silence={silence}, OR={lag_high or silence}')
    print('Correlation:', trace_id, 'links', len(events), 'events')
    print('No X-Ray spans exported; no CloudWatch period/history/dashboard behavior asserted.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('demo', choices=['routing', 'scaling', 'security', 'observability', 'all'])
    args = parser.parse_args()
    demos = dict(routing=routing, scaling=scaling, security=security, observability=observability)
    for name, run in demos.items():
        if args.demo in (name, 'all'):
            print(f'\n--- {name} ---')
            run()
