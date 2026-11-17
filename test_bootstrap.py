"""Exercise the real entrypoint against a controlled HTTP bootstrap service.

Run with Python 3, curl and jq installed: python3 -m unittest test_bootstrap.py
No database, plugins, production credentials or public listener are used.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SERVER = r'''#!/usr/bin/env python3
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
if sys.argv[1] == 'version':
    print('bootstrap-regression-fixture')
    sys.exit(0)
if os.environ.get('MARMOT_SERVER_HOST') != '127.0.0.1':
    Path(os.environ['TEST_PUBLIC_MARKER']).write_text('exposed')
    sys.exit(0)
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        self.send_response(200); self.end_headers()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path.endswith('/login'):
            if os.environ['TEST_LOGIN_STATUS'] == 'transport':
                self.connection.close(); return
            self.send_response(int(os.environ['TEST_LOGIN_STATUS']))
            self.end_headers()
            self.wfile.write(os.environ['TEST_LOGIN_BODY'].encode())
        else:
            valid = json.loads(body)['new_password'] == os.environ['MARMOT_ADMIN_PASSWORD']
            self.send_response(200 if valid else 400); self.end_headers()
HTTPServer(('127.0.0.1', int(os.environ['MARMOT_SERVER_PORT'])), Handler).serve_forever()
'''


class BootstrapTest(unittest.TestCase):
    def probe(self, status, body, exposed):
        for dependency in ('curl', 'jq'):
            self.assertIsNotNone(shutil.which(dependency), dependency + ' is required')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binaries = root / 'bin'
            binaries.mkdir()
            for name, content in {
                'marmot': SERVER,
                'su-exec': '#!/bin/sh\nshift\nexec "$@"\n',
                'wget': '#!/bin/sh\nfor last; do :; done\nexec curl --silent --fail --output /dev/null "$last"\n',
            }.items():
                path = binaries / name
                path.write_text(content)
                path.chmod(0o755)
            marker = root / 'public'
            env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'],
                       MARMOT_PLUGINS_DIR=str(root / 'plugins'),
                       MARMOT_ADMIN_PASSWORD='fixture "quoted" password',
                       MARMOT_SERVER_ENCRYPTION_KEY='fixture-not-used-by-mock',
                       TEST_PUBLIC_MARKER=str(marker), TEST_LOGIN_STATUS=str(status),
                       TEST_LOGIN_BODY=body)
            result = subprocess.run(['sh', str(Path(__file__).with_name('entrypoint.sh'))],
                                    env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(marker.exists(), exposed, result.stdout + result.stderr)
            self.assertEqual(result.returncode, 0 if exposed else 1, result.stdout + result.stderr)

    def test_first_boot_replaces_password_before_exposure(self):
        self.probe(200, '{"access_token":"fixture.jwt.token"}', True)

    def test_existing_password_is_retained(self):
        self.probe(401, '{"error":"Invalid credentials","request_id":"fixture"}', True)

    def test_ambiguous_failures_never_expose(self):
        for status, body in [(500, '{"error":"Authentication failed"}'),
                             (403, '{"error":"Password sign-in is turned off"}'),
                             (401, '{"error":"Unexpected rejection"}'),
                             (401, 'not json'), (200, 'not json'),
                             (200, '{"access_token":null}'),
                             (200, '{"access_token":""}'),
                             ('transport', '')]:
            with self.subTest(status=status, body=body):
                self.probe(status, body, False)


if __name__ == '__main__':
    unittest.main()
