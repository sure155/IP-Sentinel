#!/usr/bin/env python3
# ==========================================================
# 脚本名称: webhook.py (IP-Sentinel Edge Agent Webhook Server v3.1.0)
# 核心功能: Token 鉴权、模块级路由分发(403拦截)、日志回传
# ==========================================================
import http.server
import socketserver
import subprocess
import sys
import os
import hashlib
import time
from urllib.parse import urlparse, parse_qs

VERSION = "3.1.0"
CONFIG_FILE = "/opt/ip_sentinel/config.conf"

def load_config():
    """从 config.conf 加载配置为字典"""
    cfg = {}
    if not os.path.exists(CONFIG_FILE):
        return cfg
    with open(CONFIG_FILE, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' in line:
                key, _, val = line.partition('=')
                cfg[key.strip()] = val.strip().strip('"').strip("'")
    return cfg

CFG = load_config()
AGENT_TOKEN = CFG.get('AGENT_TOKEN', '')

class AgentHandler(http.server.BaseHTTPRequestHandler):
    """支持 Token 鉴权的 Agent Webhook Handler"""

    def _validate_token(self):
        """校验请求中的 Token，支持 URL 参数和 Authorization Header 两种方式"""
        if not AGENT_TOKEN:
            # 未配置 Token 时允许所有请求（向后兼容）
            return True

        # 方式1: URL 参数 ?token=xxx
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        if params.get('token', [''])[0] == AGENT_TOKEN:
            return True

        # 方式2: Authorization: Bearer xxx
        auth_header = self.headers.get('Authorization', '')
        if auth_header.startswith('Bearer ') and auth_header[7:] == AGENT_TOKEN:
            return True

        return False

    def _route_path(self):
        """提取纯路由路径（去掉查询参数）"""
        return urlparse(self.path).path

    def do_GET(self):
        route = self._route_path()

        # 健康检查端点（无需鉴权）
        if route == '/healthz':
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(f"IP-Sentinel Agent v{VERSION} OK\n".encode())
            return

        # Token 鉴权
        if not self._validate_token():
            self.send_response(401)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"401 Unauthorized: Invalid or missing token\n")
            return

        # 路由 1: Google 区域纠偏 (含老版 run 指令兼容)
        if route == '/trigger_google' or route == '/trigger_run':
            if os.path.exists('/opt/ip_sentinel/core/mod_google.sh'):
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: mod_google\n")
                subprocess.Popen(['bash', '/opt/ip_sentinel/core/mod_google.sh'])
            else:
                self.send_response(403)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"403 Forbidden: Google Module Disabled\n")

        # 路由 2: IP 信用净化
        elif route == '/trigger_trust':
            if os.path.exists('/opt/ip_sentinel/core/mod_trust.sh'):
                self.send_response(200)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Action Accepted: mod_trust\n")
                subprocess.Popen(['bash', '/opt/ip_sentinel/core/mod_trust.sh'])
            else:
                self.send_response(403)
                self.send_header("Content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"403 Forbidden: Trust Module Disabled\n")

        # 路由 3: 触发战报推送
        elif route == '/trigger_report':
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Action Accepted: tg_report\n")
            subprocess.Popen(['bash', '/opt/ip_sentinel/core/tg_report.sh'])

        # 路由 4: 抓取并回传实时日志
        elif route == '/trigger_log':
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Action Accepted: fetch_log\n")
            bash_cmd = """
source /opt/ip_sentinel/config.conf
LOG_DATA=$(tail -n 15 /opt/ip_sentinel/logs/sentinel.log)
NODE=$(hostname | cut -c 1-15)
curl -s -X POST "${TG_API_URL}" \
  -d "chat_id=${CHAT_ID}" \
  -d "text=📄 **[${NODE}] 实时运行日志:**%0A```log%0A${LOG_DATA}%0A```" \
  -d "parse_mode=Markdown"
"""
            subprocess.Popen(['bash', '-c', bash_cmd])

        else:
            self.send_response(404)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"404 Not Found\n")

    def log_message(self, format, *args):
        """静默日志（不输出到 stderr）"""
        pass

import socket

class DualStackServer(socketserver.TCPServer):
    """支持 IPv4/IPv6 双栈的 HTTP Server"""
    address_family = socket.AF_INET6 if socket.has_ipv6 else socket.AF_INET
    allow_reuse_address = True

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <port>", file=sys.stderr)
        sys.exit(1)

    PORT = int(sys.argv[1])
    bind_addr = "::" if socket.has_ipv6 else ""

    try:
        with DualStackServer((bind_addr, PORT), AgentHandler) as httpd:
            httpd.serve_forever()
    except Exception as e:
        print(f"Webhook server failed: {e}", file=sys.stderr)
        sys.exit(1)
