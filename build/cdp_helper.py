#!/usr/bin/env python3
# Minimal, dependency-free Chrome DevTools Protocol client used by
# build/smoke-test-window-state.sh to drive and inspect a running HUPI
# Code instance over its --remote-debugging-port.
#
# Implemented directly against raw sockets (urllib for the /json/list
# HTTP endpoint, hand-rolled RFC 6455 framing for the WebSocket RPC
# calls) rather than depending on `websocket-client` (pip) or a
# Node-based CDP client: this script must run as a CI step on a fresh
# GitHub Actions runner where neither is guaranteed to be installed or
# installable without a network round-trip, but python3 already is —
# build.sh itself already hard-depends on python3/python being present
# (see docs/UPSTREAM_UPGRADES.md's "python3 hardcoded" note) — so this
# adds zero new dependencies beyond what the build already requires.
#
# Not a general-purpose CDP library: just the handful of operations
# smoke-test-window-state.sh's own real, already-proven-by-hand repro
# needs (see that script and docs/UPSTREAM_UPGRADES.md's 0008 section
# for the manual technique this automates).
import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.request


def http_get_json(url, timeout=10):
	with urllib.request.urlopen(url, timeout=timeout) as resp:
		return json.loads(resp.read().decode('utf-8'))


def ws_connect(ws_url):
	# A hand-rolled client, not a browser, so there is no Origin header
	# to satisfy --remote-allow-origins's check — but the launcher script
	# still passes that flag anyway, matching the exact recipe
	# docs/UPSTREAM_UPGRADES.md's 0008 section already found necessary
	# for *some* CDP clients against this app, rather than relying on
	# this client's own lack of an Origin header always being enough.
	assert ws_url.startswith('ws://'), f'unexpected websocket URL scheme: {ws_url}'
	rest = ws_url[len('ws://'):]
	hostport, _, path = rest.partition('/')
	path = '/' + path
	host, _, port_s = hostport.partition(':')
	port = int(port_s) if port_s else 80
	sock = socket.create_connection((host, port), timeout=10)
	key = base64.b64encode(os.urandom(16)).decode()
	request = (
		f'GET {path} HTTP/1.1\r\n'
		f'Host: {hostport}\r\n'
		'Upgrade: websocket\r\n'
		'Connection: Upgrade\r\n'
		f'Sec-WebSocket-Key: {key}\r\n'
		'Sec-WebSocket-Version: 13\r\n'
		'\r\n'
	)
	sock.sendall(request.encode('ascii'))
	response = b''
	while b'\r\n\r\n' not in response:
		chunk = sock.recv(4096)
		if not chunk:
			raise RuntimeError('CDP websocket handshake: connection closed before headers completed')
		response += chunk
	status_line = response.split(b'\r\n', 1)[0]
	if b'101' not in status_line:
		raise RuntimeError(f'CDP websocket handshake rejected: {status_line!r}')
	return sock


def ws_send_text(sock, payload):
	data = payload.encode('utf-8')
	header = bytearray([0x81])  # FIN + text-frame opcode
	length = len(data)
	if length < 126:
		header.append(0x80 | length)
	elif length < 65536:
		header.append(0x80 | 126)
		header += struct.pack('>H', length)
	else:
		header.append(0x80 | 127)
		header += struct.pack('>Q', length)
	# RFC 6455 requires every client->server frame to be masked.
	mask_key = os.urandom(4)
	header += mask_key
	masked = bytes(b ^ mask_key[i % 4] for i, b in enumerate(data))
	sock.sendall(bytes(header) + masked)


def ws_recv_frame(sock):
	def recv_exact(n):
		buf = b''
		while len(buf) < n:
			chunk = sock.recv(n - len(buf))
			if not chunk:
				raise RuntimeError('CDP websocket: connection closed mid-frame')
			buf += chunk
		return buf

	b1, b2 = recv_exact(2)
	opcode = b1 & 0x0F
	masked = bool(b2 & 0x80)
	length = b2 & 0x7F
	if length == 126:
		length = struct.unpack('>H', recv_exact(2))[0]
	elif length == 127:
		length = struct.unpack('>Q', recv_exact(8))[0]
	mask_key = recv_exact(4) if masked else None
	payload = recv_exact(length)
	if masked:
		payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
	return opcode, payload


def ws_rpc(ws_url, method, params, timeout_s=15):
	sock = ws_connect(ws_url)
	sock.settimeout(timeout_s)
	try:
		ws_send_text(sock, json.dumps({'id': 1, 'method': method, 'params': params}))
		deadline = time.time() + timeout_s
		while time.time() < deadline:
			opcode, payload = ws_recv_frame(sock)
			if opcode == 0x8:
				raise RuntimeError('CDP websocket: server closed the connection')
			if opcode != 0x1:
				continue  # ignore ping/binary frames
			message = json.loads(payload.decode('utf-8'))
			# The renderer also emits its own unsolicited CDP events
			# (Page.*, Runtime.*, Log.*) on this same socket — skip
			# anything that isn't the reply to our one request.
			if message.get('id') == 1:
				return message
		raise TimeoutError(f'no reply to {method} within {timeout_s}s')
	finally:
		sock.close()


def cmd_wait(args):
	"""wait PORT URL_SUBSTRING TIMEOUT_SECS — poll /json/list until a page
	target whose url contains URL_SUBSTRING appears; print its
	webSocketDebuggerUrl and exit 0, or exit 1 after the timeout."""
	port, url_substring, timeout_s = args[0], args[1], float(args[2])
	deadline = time.time() + timeout_s
	last_targets = []
	while time.time() < deadline:
		try:
			last_targets = http_get_json(f'http://127.0.0.1:{port}/json/list')
		except Exception:
			last_targets = []
		for t in last_targets:
			if t.get('type') == 'page' and url_substring in t.get('url', ''):
				print(t['webSocketDebuggerUrl'])
				return 0
		time.sleep(0.5)
	sys.stderr.write(f'timed out after {timeout_s}s waiting for a page target containing {url_substring!r}\n')
	sys.stderr.write('current targets:\n')
	for t in last_targets:
		sys.stderr.write(f"  type={t.get('type')} title={t.get('title')!r} url={t.get('url')!r}\n")
	return 1


def cmd_wait_absent(args):
	"""wait-absent PORT URL_SUBSTRING TIMEOUT_SECS — poll until no page
	target's url contains URL_SUBSTRING. Treats the devtools endpoint
	itself becoming unreachable as "absent" too (the app may already be
	mid-shutdown by the time this is called)."""
	port, url_substring, timeout_s = args[0], args[1], float(args[2])
	deadline = time.time() + timeout_s
	while time.time() < deadline:
		try:
			targets = http_get_json(f'http://127.0.0.1:{port}/json/list')
		except Exception:
			return 0
		if not any(t.get('type') == 'page' and url_substring in t.get('url', '') for t in targets):
			return 0
		time.sleep(0.5)
	sys.stderr.write(f'timed out after {timeout_s}s waiting for the page target containing {url_substring!r} to close\n')
	return 1


def cmd_keypress_close_window(args):
	"""keypress-close-window WS_URL — dispatches a real Ctrl+Shift+W to the
	given page target, the exact CDP Input.dispatchKeyEvent sequence
	docs/UPSTREAM_UPGRADES.md's 0008 investigation confirmed actually
	exercises workbench.action.closeWindow's real close path (unlike
	Target.closeTarget/Page.close, which bypass it and produce false
	negatives — see that doc for the full story of why)."""
	ws_url = args[0]
	mod = 2 | 8  # Ctrl (2) | Shift (8)
	ws_rpc(ws_url, 'Input.dispatchKeyEvent', {
		'type': 'rawKeyDown', 'modifiers': mod,
		'windowsVirtualKeyCode': 87, 'code': 'KeyW', 'key': 'W',
	})
	ws_rpc(ws_url, 'Input.dispatchKeyEvent', {
		'type': 'keyUp', 'modifiers': mod,
		'windowsVirtualKeyCode': 87, 'code': 'KeyW', 'key': 'W',
	})
	return 0


def cmd_click_close_button(args):
	"""click-close-button WS_URL — clicks the real DOM close-icon element
	for a window that doesn't have workbench.action.closeWindow at all
	(the Agents/Sessions window — see docs/UPSTREAM_UPGRADES.md's 0008
	section for why). Requires window.controlsStyle: "custom" in the
	profile's settings.json, which forces this element to actually exist
	in the DOM instead of being drawn as an OS-compositor-owned Window
	Controls Overlay region with nothing for CDP to click. Prints
	"true"/"false" depending on whether the element was found and
	clicked."""
	ws_url = args[0]
	expr = (
		"(() => { const el = document.querySelector('.window-icon.window-close'); "
		"if (el) { el.click(); return true; } return false; })()"
	)
	result = ws_rpc(ws_url, 'Runtime.evaluate', {'expression': expr, 'returnByValue': True})
	value = result.get('result', {}).get('result', {}).get('value')
	print('true' if value else 'false')
	return 0


def cmd_titles(args):
	"""titles PORT — best-effort dump of every page target's title/url,
	for FAIL-path diagnostics."""
	port = args[0]
	try:
		targets = http_get_json(f'http://127.0.0.1:{port}/json/list')
	except Exception as e:
		print(f'(could not reach devtools endpoint on port {port}: {e})')
		return 0
	for t in targets:
		print(f"type={t.get('type')} title={t.get('title')!r} url={t.get('url')!r}")
	return 0


COMMANDS = {
	'wait': cmd_wait,
	'wait-absent': cmd_wait_absent,
	'keypress-close-window': cmd_keypress_close_window,
	'click-close-button': cmd_click_close_button,
	'titles': cmd_titles,
}

if __name__ == '__main__':
	command = sys.argv[1]
	try:
		sys.exit(COMMANDS[command](sys.argv[2:]))
	except Exception as e:
		sys.stderr.write(f'cdp_helper.py {command}: {e}\n')
		sys.exit(1)
