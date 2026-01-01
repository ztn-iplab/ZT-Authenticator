#!/usr/bin/env python3
import argparse
import json
import os
import smtplib
from datetime import datetime, timezone
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, HTTPServer


class FeedbackHandler(BaseHTTPRequestHandler):
    def _send(self, status, body):
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path != "/health":
            self._send(404, {"error": "not_found"})
            return
        self._send(200, {"status": "ok"})

    def do_POST(self):
        if self.path != "/feedback":
            self._send(404, {"error": "not_found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self._send(400, {"error": "invalid_json"})
            return

        record = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "source": payload.get("source", "zt-authenticator"),
            "email": payload.get("email", ""),
            "category": payload.get("category", ""),
            "subject": payload.get("subject", ""),
            "message": payload.get("message", ""),
            "ip_address": self.client_address[0],
            "user_agent": self.headers.get("User-Agent", ""),
        }

        os.makedirs(self.server.output_dir, exist_ok=True)
        with open(self.server.output_file, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=True) + "\n")

        self._send_feedback_email(record)
        self._send(200, {"status": "ok"})

    def _send_feedback_email(self, record):
        recipient = os.getenv("FEEDBACK_EMAIL", "").strip()
        if not recipient:
            return

        msg = EmailMessage()
        msg["Subject"] = f"Feedback received ({record['source']})"
        msg["From"] = os.getenv("MAIL_DEFAULT_SENDER", "no-reply@example.com")
        msg["To"] = recipient
        msg.set_content(
            "New feedback received:\n\n"
            f"Time: {record['timestamp']}\n"
            f"Source: {record['source']}\n"
            f"Email: {record['email']}\n"
            f"Category: {record['category']}\n"
            f"Subject: {record['subject']}\n"
            f"Message: {record['message']}\n"
            f"IP: {record['ip_address']}\n"
            f"User-Agent: {record['user_agent']}\n"
        )

        mail_host = os.getenv("MAIL_SERVER", "localhost")
        mail_port = int(os.getenv("MAIL_PORT", "1025"))
        use_tls = os.getenv("MAIL_USE_TLS", "False").lower() == "true"
        username = os.getenv("MAIL_USERNAME")
        password = os.getenv("MAIL_PASSWORD")

        with smtplib.SMTP(mail_host, mail_port) as server:
            if use_tls:
                server.starttls()
            if username and password:
                server.login(username, password)
            server.send_message(msg)


def main():
    parser = argparse.ArgumentParser(description="Local feedback receiver for ZT-Authenticator.")
    parser.add_argument("--host", default="0.0.0.0", help="Bind host (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=5055, help="Bind port (default: 5055)")
    parser.add_argument(
        "--output-dir",
        default=os.path.join(os.getcwd(), "feedback"),
        help="Directory to write feedback logs",
    )
    args = parser.parse_args()

    server = HTTPServer((args.host, args.port), FeedbackHandler)
    server.output_dir = args.output_dir
    server.output_file = os.path.join(args.output_dir, "zt_authenticator_feedback.jsonl")

    print(f"Feedback server running on http://{args.host}:{args.port}")
    print(f"Writing feedback to {server.output_file}")
    server.serve_forever()


if __name__ == "__main__":
    main()
