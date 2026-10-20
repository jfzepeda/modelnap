import json
import os
from pathlib import Path
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer


CLI = Path(__file__).resolve().parents[1] / "napkin"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.loads(raw) if raw else None
        self.server.requests.append((self.command, self.path, body, self.headers.get("Content-Type")))
        code = self.server.response_code
        payload = json.dumps({"mode": "manual"} if code < 400 else {"error": "Control unavailable"}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


class CLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.server.requests = []
        self.server.response_code = 200

    def run_cli(self, *args, url=None):
        env = dict(os.environ, NAPKIN_URL=url or f"http://127.0.0.1:{self.server.server_port}/")
        return subprocess.run([str(CLI), *args], env=env, capture_output=True, text=True, timeout=20)

    def test_queries_use_status_without_mutations(self):
        for args in [("status",), ("mode",), ("idle", "get")]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {"mode": "manual"})
                self.assertEqual(self.server.requests[-1][:3], ("GET", "/control/status", None))

    def test_actions_aliases_and_timeout_encoding(self):
        cases = [
            (("start",), {"action": "start"}),
            (("resume",), {"action": "start"}),
            (("stop",), {"action": "stop"}),
            (("mode", "auto"), {"action": "mode", "value": "auto"}),
            (("mode", "manual"), {"action": "mode", "value": "manual"}),
            (("mode", "toggle"), {"action": "mode", "value": "toggle"}),
            (("auto", "on"), {"action": "mode", "value": "auto"}),
            (("auto", "off"), {"action": "mode", "value": "manual"}),
            (("idle", "set", "10m"), {"action": "idle", "minutes": 10}),
            (("idle", "set", "08"), {"action": "idle", "minutes": 8}),
            (("idle", "set", "1"), {"action": "idle", "minutes": 1}),
            (("idle", "set", "240m"), {"action": "idle", "minutes": 240}),
        ]
        for args, body in cases:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.server.requests[-1], ("POST", "/control", body, "application/json"))

    def test_agents_use_existing_endpoint(self):
        result = self.run_cli("agents", "start")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.requests[-1][:3], ("POST", "/agents/start", {}))

    def test_invalid_arguments_never_send_requests(self):
        cases = [("unknown",), ("mode", "other"), ("mode", "auto", "extra"),
                 ("auto", "toggle"), ("auto",), ("status", "extra"), ("start", "extra"),
                 ("agents", "stop"), ("idle",), ("help", "extra")]
        cases += [("idle", "set", value) for value in
                  ["0", "-1", "241", "1.5", "abc", "1h", "1mm", "1 2", "999999999999999999999999999"]]
        for args in cases:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn("napkin:", result.stderr)
        self.assertEqual(self.server.requests, [])

    def test_help_needs_no_running_app(self):
        for args in [(), ("help",), ("--help",), ("-h",)]:
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 0)
            self.assertIn("Usage: napkin", result.stdout)
        self.assertEqual(self.server.requests, [])

    def test_http_errors_return_nonzero_and_keep_error_body(self):
        self.server.response_code = 409
        result = self.run_cli("start")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout), {"error": "Control unavailable"})

    def test_missing_app_reports_connection_failure(self):
        # Reserve then close an unused local port instead of assuming a fixed one.
        server = HTTPServer(("127.0.0.1", 0), Handler)
        port = server.server_port
        server.server_close()
        result = self.run_cli("status", url=f"http://127.0.0.1:{port}")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Open Napkin", result.stderr)


if __name__ == "__main__":
    unittest.main()
