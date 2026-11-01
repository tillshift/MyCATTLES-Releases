"""MyCATTLES Chrome Native Messaging Host (Phase 2).
Requires Python 3 on Windows. Stdout is reserved for Native Messaging frames.
"""
import json
import os
import pathlib
import socket
import struct
import sys
import threading
import time
import ctypes

MAX_MESSAGE = 65536


def app_support_dir():
    # path_provider Windows: %APPDATA%/<Flutter executable name> on standard builds.
    # Set MYCATTLES_SUPPORT_DIR if the application uses another directory.
    override = os.environ.get('MYCATTLES_SUPPORT_DIR')
    if override:
        return pathlib.Path(override)
    root = pathlib.Path(os.environ['APPDATA'])
    candidates = [root / 'MyCATTLES', root / 'mycattles', root / 'MyCATLLES']
    for candidate in candidates:
        if (candidate / 'chrome_bridge_v1.json').is_file():
            return candidate
    # Search only directly under Roaming for app-specific descriptor.
    for child in root.iterdir():
        if not child.is_dir():
            continue
        for candidate in [child, *(p for p in child.iterdir() if p.is_dir())]:
            if (candidate / 'chrome_bridge_v1.json').is_file():
                return candidate
    raise FileNotFoundError('MyCATTLES bridge descriptor not found')


def read_exact(count):
    result = bytearray()
    while len(result) < count:
        block = sys.stdin.buffer.read(count - len(result))
        if not block:
            return None
        result.extend(block)
    return bytes(result)


def send(response):
    data = json.dumps(response, separators=(',', ':')).encode('utf-8')
    sys.stdout.buffer.write(struct.pack('<I', len(data)))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def handle(request):
    if not isinstance(request, dict) or request.get('action') not in ('ping','capture','pending','fill_pending','ack'):
        return {'ok': False, 'error': 'unsupported_request'}
    if request['action'] == 'capture':
        capture = request.get('capture')
        if not isinstance(capture, dict) or capture.get('schemaVersion') != 3:
            return {'ok': False, 'error': 'unsupported_schema'}
        if not isinstance(capture.get('origin'), str) or not capture['origin'].startswith('https://'):
            return {'ok': False, 'error': 'invalid_origin'}
        if not isinstance(capture.get('forms'), list) or len(capture['forms']) > 30:
            return {'ok': False, 'error': 'invalid_capture'}
    if request['action'] == 'ack' and not isinstance(request.get('id'), str):
        return {'ok': False, 'error': 'invalid_ack'}
    try:
        info = json.loads((app_support_dir() / 'chrome_bridge_v1.json').read_text(encoding='utf-8'))
        if (info.get('protocol') != 1 or not isinstance(info.get('port'), int)
                or not isinstance(info.get('token'), str) or not info['token']):
            raise ValueError('invalid descriptor')
        with socket.create_connection(('127.0.0.1', info['port']), timeout=3) as connection:
            connection.settimeout(3)
            payload = {'protocol': 1, 'action': request['action'], 'token': info['token']}
            if request['action'] == 'capture':
                payload['capture'] = request.get('capture')
            if request['action'] == 'ack':
                payload['id'] = request.get('id')
            outgoing = json.dumps(payload, separators=(',', ':')).encode('utf-8') + b'\n'
            if len(outgoing) > MAX_MESSAGE:
                return {'ok': False, 'error': 'message_too_large'}
            connection.sendall(outgoing)
            reply = bytearray()
            while b'\n' not in reply and len(reply) < MAX_MESSAGE:
                part = connection.recv(4096)
                if not part:
                    break
                reply.extend(part)
            if b'\n' not in reply:
                return {'ok': False, 'error': 'invalid_app_response'}
            response = json.loads(reply.split(b'\n', 1)[0])
            return response if isinstance(response, dict) else {'ok': False, 'error': 'invalid_app_response'}
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return {'ok': False, 'error': 'app_disconnected'}


def focus_app_window():
    """Best-effort foreground request from Chrome-launched native host (Windows)."""
    if os.name != 'nt':
        return
    try:
        user32 = ctypes.windll.user32
        user32.IsWindowVisible.argtypes = [ctypes.c_void_p]
        user32.GetWindowTextLengthW.argtypes = [ctypes.c_void_p]
        user32.GetWindowTextW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
        user32.ShowWindow.argtypes = [ctypes.c_void_p, ctypes.c_int]
        user32.BringWindowToTop.argtypes = [ctypes.c_void_p]
        user32.SetForegroundWindow.argtypes = [ctypes.c_void_p]
        found = []
        callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
        def visit(hwnd, unused):
            if not user32.IsWindowVisible(hwnd):
                return True
            length = user32.GetWindowTextLengthW(hwnd)
            if not length or length > 512:
                return True
            title = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, title, length + 1)
            if title.value.strip().lower() in ('mycattles', 'mycatlles'):
                found.append(hwnd)
            return True
        callback = callback_type(visit)
        user32.EnumWindows(callback, 0)
        for hwnd in found:
            user32.ShowWindow(hwnd, 9)  # SW_RESTORE
            user32.BringWindowToTop(hwnd)
            if user32.SetForegroundWindow(hwnd):
                return
    except Exception:
        pass


def main():
    write_lock = threading.Lock()
    alive = threading.Event()
    alive.set()
    def safe_send(payload):
        with write_lock:
            send(payload)

    def read_loop():
        while True:
            length_bytes = read_exact(4)
            if length_bytes is None:
                break
            size = struct.unpack('<I', length_bytes)[0]
            if size > MAX_MESSAGE:
                break
            data = read_exact(size)
            if data is None:
                break
            try:
                request = json.loads(data)
                reply = handle(request)
                safe_send(reply)
                if isinstance(request, dict) and request.get('action') == 'capture' and reply.get('ok'):
                    # Give Flutter a moment to show its dialog before requesting foreground.
                    time.sleep(0.15)
                    focus_app_window()
            except (ValueError, UnicodeDecodeError):
                safe_send({'ok': False, 'error': 'invalid_json'})
            except (OSError, BrokenPipeError):
                break
        alive.clear()

    reader = threading.Thread(target=read_loop, daemon=True)
    reader.start()
    while alive.is_set():
        time.sleep(0.45)
    reader.join(timeout=1)


if __name__ == '__main__':
    main()
