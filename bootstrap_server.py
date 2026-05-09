#!/usr/bin/env python3
"""
Bootstrap Server - Serves bootstrap.sh and compose.sh on port 8001
Simple HTTP server for zero-touch device onboarding
"""

from http.server import HTTPServer, SimpleHTTPRequestHandler
import os
from pathlib import Path

class BootstrapHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        """Handle GET requests for bootstrap files"""

        # Map URLs to files
        if self.path == '/bootstrap.sh':
            file_path = Path(__file__).parent / 'web' / 'frontend' / 'public' / 'bootstrap.sh'
        elif self.path == '/compose.sh':
            file_path = Path(__file__).parent / 'compose.sh'
        else:
            self.send_error(404, "File not found")
            return

        if not file_path.exists():
            self.send_error(404, f"File not found: {file_path}")
            return

        # Send file
        self.send_response(200)
        self.send_header('Content-Type', 'text/x-shellscript')
        self.send_header('Content-Disposition', f'inline; filename="{file_path.name}"')
        self.end_headers()

        with open(file_path, 'rb') as f:
            self.wfile.write(f.read())

        print(f"Served {self.path} -> {file_path}")

def run_server(port=8001):
    """Start the bootstrap server"""
    server_address = ('', port)
    httpd = HTTPServer(server_address, BootstrapHandler)
    print(f"Bootstrap server running on port {port}")
    print(f"Access bootstrap.sh: http://localhost:{port}/bootstrap.sh")
    print(f"Access compose.sh: http://localhost:{port}/compose.sh")
    httpd.serve_forever()

if __name__ == '__main__':
    run_server()
