#!/usr/bin/env python3
import argparse
import http.server
import os
import ssl


parser = argparse.ArgumentParser()
parser.add_argument("--root", required=True)
parser.add_argument("--certificate", required=True)
parser.add_argument("--key", required=True)
parser.add_argument("--port-file", required=True)
parser.add_argument("--redirect-url")
arguments = parser.parse_args()

os.setsid()


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *handler_args, **handler_kwargs):
        super().__init__(*handler_args, directory=arguments.root, **handler_kwargs)

    def do_GET(self):
        if arguments.redirect_url and self.path.startswith("/appcast.xml"):
            self.send_response(302)
            self.send_header("Location", arguments.redirect_url)
            self.end_headers()
            return
        super().do_GET()

    def log_message(self, format_string, *format_args):
        print("https-fixture " + format_string % format_args, flush=True)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(arguments.certificate, arguments.key)
server.socket = context.wrap_socket(server.socket, server_side=True)
with open(arguments.port_file, "x", encoding="ascii") as port_output:
    port_output.write(str(server.server_address[1]) + "\n")
server.serve_forever()
