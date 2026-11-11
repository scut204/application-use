#!/usr/bin/env python3
"""Legacy application-use commands backed exclusively by a background runtime."""

import argparse
import base64
import copy
import ctypes
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import select
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time


IDLE_SECONDS = 600
HINT_SECONDS = 120
MAX_MESSAGE = 32 * 1024 * 1024
NATIVE_TIMEOUT = 60


class ApplicationUseError(Exception):
    pass


def result_text(result):
    return "\n".join(str(item.get("text", "")) for item in result.get("content", [])
                     if item.get("type") == "text")


def checked_result(result):
    if not isinstance(result, dict):
        raise ApplicationUseError("The background runtime returned an invalid response.")
    if result.get("error"):
        raise ApplicationUseError(str(result["error"]))
    if result.get("isError"):
        raise ApplicationUseError(result_text(result) or "The background operation failed.")
    return result


def read_line(stream, limit=MAX_MESSAGE):
    line = stream.readline(limit + 1)
    if not line or len(line) > limit or not line.endswith(b"\n"):
        raise ApplicationUseError("The background connection closed or returned an oversized response.")
    try:
        return json.loads(line)
    except (ValueError, UnicodeError) as error:
        raise ApplicationUseError("The background runtime returned invalid JSON.") from error


def private_directory(path):
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        pass
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ApplicationUseError("The session directory must be owned by this user with permissions 0700.")
    return path


def peer_uid(connection):
    if sys.platform == "darwin":
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
            raise ApplicationUseError("Cannot verify the local session peer.")
        return uid.value
    if hasattr(socket, "SO_PEERCRED"):
        return struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
    raise ApplicationUseError("Peer verification is unavailable on this platform.")


class NativeClient:
    def __init__(self, executable, log_file):
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("OPEN_COMPUTER_USE_")}
        environment.update({"OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "0",
                            "OPEN_COMPUTER_USE_VISUAL_CURSOR": "1",
                            "OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY": "1"})
        self.process = subprocess.Popen([str(executable), "--stdio"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=log_file, env=environment)
        self.buffer = b""
        self.closed = False

    def call(self, tool, arguments):
        if self.process.poll() is not None:
            raise ApplicationUseError("The background runtime stopped. Start a new snapshot session.")
        payload = json.dumps({"tool": tool, "arguments": arguments}, ensure_ascii=False).encode() + b"\n"
        if len(payload) > MAX_MESSAGE:
            raise ApplicationUseError("The requested operation is too large.")
        try:
            self.process.stdin.write(payload)
            self.process.stdin.flush()
            deadline = time.monotonic() + NATIVE_TIMEOUT
            while b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                    self.close()
                    raise ApplicationUseError("The background operation timed out; it was not retried.")
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise ApplicationUseError("The background runtime closed its response stream.")
                self.buffer += chunk
                if len(self.buffer) > MAX_MESSAGE:
                    self.close()
                    raise ApplicationUseError("The background response exceeded the size limit.")
            line, self.buffer = self.buffer.split(b"\n", 1)
            return checked_result(json.loads(line))
        except (BrokenPipeError, ValueError, UnicodeError) as error:
            self.close()
            raise ApplicationUseError("The background protocol failed; the operation was not retried.") from error

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.process.stdin:
            try:
                self.process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
        if self.process.poll() is None:
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
        for stream in (self.process.stdin, self.process.stdout):
            if stream:
                stream.close()


def hint_name(number):
    result = ""
    number += 1
    while number:
        number, remainder = divmod(number - 1, 26)
        result = chr(65 + remainder) + result
    return result


def valid_frame(frame):
    if not isinstance(frame, dict):
        return False
    values = [frame.get(key) for key in ("x", "y", "width", "height")]
    return (all(isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
                for value in values) and values[2] > 0 and values[3] > 0)


def fingerprint(element):
    return tuple(json.dumps(element.get(key), sort_keys=True, ensure_ascii=False)
                 for key in ("index", "role", "title", "value", "frame"))


def observation_fingerprint(observation):
    return tuple(json.dumps(observation.get(key), sort_keys=True, ensure_ascii=False)
                 for key in ("kind", "text", "frame"))


def reject_lifecycle_key(key):
    tokens = [part.strip().lower().replace(" ", "") for part in str(key).split("+")]
    if len(tokens) > 1 and {"cmd", "command", "super", "meta"}.intersection(tokens[:-1]) and tokens[-1] in {"q", "w", "m", "h", "tab"}:
        raise ApplicationUseError("This app/window lifecycle shortcut is unavailable in strict background mode.")


def reject_noneditable_fill(entry):
    if not entry:
        return
    if entry["kind"] != "ax":
        raise ApplicationUseError("fill requires an editable AX hint; OCR and icon hints cannot identify the text recipient safely.")
    role = str(entry["element"].get("role", "")).lower().replace(" ", "")
    if role.startswith("ax"):
        role = role[2:]
    if role not in {"textfield", "textarea", "textview", "combobox", "searchfield", "securetextfield"}:
        raise ApplicationUseError("fill requires an editable AX text control; no click or text input was sent.")


class BackgroundSession:
    def __init__(self, native, directory, model_path=None):
        self.native = native
        self.directory = Path(directory)
        self.model_path = model_path
        self.snapshots = {}
        self.aliases = {}
        self.last_app = None

    def _call(self, tool, arguments):
        return checked_result(self.native.call(tool, arguments))

    def _capture(self, app):
        capture = self._call("snapshot", {"app": app})
        checked_result(capture.get("result", {}))
        if capture.get("pid") is None or capture.get("windowID") is None:
            raise ApplicationUseError("The background snapshot has no verified process/window identity.")
        capture = copy.deepcopy(capture)
        capture["created"] = time.monotonic()
        capture["hints"] = {}
        capture["warnings"] = []
        for element in capture.get("elements", []):
            if element.get("index") is not None:
                capture["hints"][hint_name(len(capture["hints"]))] = {"kind": "ax", "element": element}
        images = [item for item in capture.get("result", {}).get("content", []) if item.get("type") == "image"]
        if images:
            image = images[0]
            capture["image"] = image
            capture["image_hash"] = hashlib.sha256(image.get("data", "").encode()).hexdigest()
            recognition = self._call("recognize", {"image_base64": image["data"],
                                                    "model_path": self.model_path or ""})
            capture["image_width"] = recognition.get("width")
            capture["image_height"] = recognition.get("height")
            capture["warnings"].extend(recognition.get("warnings", []))
            for observation in recognition.get("observations", []):
                if observation.get("kind") not in ("text", "icon") or not valid_frame(observation.get("frame")):
                    continue
                capture["hints"][hint_name(len(capture["hints"]))] = {
                    "kind": observation["kind"], "observation": observation}
        return capture

    def _remember(self, app, capture):
        canonical = str(capture.get("bundleIdentifier") or capture.get("app") or app)
        self.snapshots.pop(canonical, None)
        self.snapshots[canonical] = capture
        while len(self.snapshots) > 5:
            self.snapshots.pop(next(iter(self.snapshots)))
        for alias in (app, canonical, capture.get("app"), capture.get("bundleIdentifier")):
            if alias:
                self.aliases[str(alias).casefold()] = canonical
        self.last_app = canonical

    def _target(self, app, require_snapshot=True):
        if not app:
            app = self.last_app
        if not app:
            raise ApplicationUseError("Specify --appName and take a snapshot first; the foreground app is never selected implicitly.")
        canonical = self.aliases.get(str(app).casefold(), str(app))
        if require_snapshot and canonical not in self.snapshots:
            raise ApplicationUseError("No snapshot for this app. Run snapshot --appName before interacting.")
        return canonical

    def _fresh_target(self, app, hint=None):
        canonical = self._target(app)
        previous = self.snapshots[canonical]
        if time.monotonic() - previous["created"] > HINT_SECONDS:
            self.snapshots.pop(canonical, None)
            raise ApplicationUseError("The snapshot expired. Take a new snapshot before interacting.")
        old_hint = None
        if hint:
            old_hint = previous["hints"].get(hint.upper())
            if old_hint is None:
                raise ApplicationUseError("Unknown hint. Use a hint from this app's latest snapshot.")
        fresh = self._capture(canonical)
        if (fresh["pid"], fresh["windowID"]) != (previous["pid"], previous["windowID"]):
            self.snapshots.pop(canonical, None)
            raise ApplicationUseError("The target process or window changed. Take a new snapshot; no input was sent.")
        matched = None
        if old_hint:
            if old_hint["kind"] == "ax":
                candidates = [entry for entry in fresh["hints"].values() if entry["kind"] == "ax"
                              and fingerprint(entry["element"]) == fingerprint(old_hint["element"])]
            else:
                candidates = [entry for entry in fresh["hints"].values()
                              if entry["kind"] == old_hint["kind"]
                              and observation_fingerprint(entry["observation"])
                              == observation_fingerprint(old_hint["observation"])]
                if old_hint["kind"] == "icon" and fresh.get("image_hash") != previous.get("image_hash"):
                    candidates = []
            if len(candidates) != 1:
                self.snapshots.pop(canonical, None)
                raise ApplicationUseError("The hint is stale or ambiguous. Take a new snapshot; no input was sent.")
            matched = candidates[0]
        self._remember(canonical, fresh)
        return canonical, fresh, matched

    def _save_image(self, image, destination=None):
        try:
            payload = base64.b64decode(image["data"], validate=True)
        except (ValueError, KeyError) as error:
            raise ApplicationUseError("The screenshot data is invalid.") from error
        extension = {"image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp"}.get(image.get("mimeType"))
        if not extension:
            raise ApplicationUseError("Unsupported screenshot format.")
        if destination:
            path = Path(destination)
            accepted_suffixes = {"image/png": {".png"}, "image/jpeg": {".jpg", ".jpeg"},
                                 "image/webp": {".webp"}}[image["mimeType"]]
            if path.suffix.lower() not in accepted_suffixes:
                raise ApplicationUseError("The screenshot format is {}; choose a matching {} filename.".format(
                    image["mimeType"], extension))
            try:
                descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            except FileExistsError as error:
                raise ApplicationUseError("The screenshot destination already exists; choose a new filename.") from error
        else:
            descriptor, filename = tempfile.mkstemp(prefix="snapshot-", suffix=extension, dir=str(self.directory))
            path = Path(filename)
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
        return str(path)

    def _render(self, capture, save_image=True):
        lines = ["Background app: {} (pid {}, window {})".format(
            capture.get("app") or capture.get("bundleIdentifier"), capture["pid"], capture["windowID"])]
        for hint, entry in capture["hints"].items():
            if entry["kind"] == "ax":
                element = entry["element"]
                label = element.get("title") or element.get("value") or ""
                line = "[{}] AX {} {}".format(hint, element.get("role", "element"), str(label).replace("\n", " ")[:250])
                if element.get("value") is not None and element.get("value") != label:
                    line += " value=" + json.dumps(str(element["value"])[:250], ensure_ascii=False)
                lines.append(line)
            else:
                observation = entry["observation"]
                lines.append("[{}] {} {}".format(hint, "OCR" if entry["kind"] == "text" else "ICON",
                                                str(observation.get("text") or "icon").replace("\n", " ")[:250]))
        if not capture["hints"]:
            lines.append(result_text(capture.get("result", {})) or "No actionable elements were returned.")
        lines.extend("Note: " + str(warning) for warning in capture.get("warnings", []))
        if save_image and capture.get("image"):
            lines.append("Screenshot: " + self._save_image(capture["image"]))
        return "\n".join(lines)

    def _click(self, app, entry, double=False):
        arguments = {"app": app, "click_method": "sky_click", "mouse_button": "left",
                     "click_count": 2 if double else 1}
        if entry["kind"] == "ax":
            arguments["element_index"] = str(entry["element"]["index"])
        else:
            frame = entry["observation"]["frame"]
            arguments.update(x=frame["x"] + frame["width"] / 2, y=frame["y"] + frame["height"] / 2)
        return self._call("click", arguments)

    def execute(self, request):
        command = request.get("command")
        app = request.get("app")
        if command == "doctor":
            return json.dumps(self._call("doctor", {}), ensure_ascii=False, indent=2)
        if command == "search":
            found = self._call("search", {"query": request.get("query") or ""})
            return result_text(found) or json.dumps(found, ensure_ascii=False, indent=2)
        if command == "open":
            if not app:
                raise ApplicationUseError("open requires --appName.")
            self._call("open", {"app": app})
            capture = self._capture(app)
            self._remember(app, capture)
            return self._render(capture)
        if command in ("snapshot", "screenshot"):
            if request.get("frame"):
                raise ApplicationUseError("--frame desktop cropping is unavailable in background mode; capture the target window.")
            app = self._target(app, require_snapshot=False)
            capture = self._capture(app)
            self._remember(app, capture)
            if command == "screenshot":
                if not capture.get("image"):
                    raise ApplicationUseError("The background window returned no screenshot.")
                return "Screenshot: " + self._save_image(capture["image"], request["path"])
            return self._render(capture)
        if command == "close":
            app = self._target(app, require_snapshot=False)
            result = self._call("close", {"app": app})
            self.snapshots.pop(app, None)
            if self.last_app == app:
                self.last_app = None
            return result_text(result) or "The background close request completed."
        if command not in ("click", "fill", "sendkey", "scroll"):
            raise ApplicationUseError("Unsupported command; no foreground or legacy fallback is available.")
        if request.get("right"):
            raise ApplicationUseError("Right-click is not supported by the verified background path.")
        if command == "sendkey":
            reject_lifecycle_key(request.get("key", ""))
        hint = request.get("hint")
        main_scroll = False
        if command == "scroll":
            hint = request.get("area")
            if str(hint).casefold() in ("main", "center"):
                hint = None
                main_scroll = True
        app, capture, entry = self._fresh_target(app, hint)
        try:
            if command == "click":
                self._click(app, entry, request.get("double", False))
            elif command == "fill":
                reject_noneditable_fill(entry)
                arguments = {"app": app, "text": request["text"], "key_method": "sky_key"}
                if entry:
                    self._click(app, entry)
                    arguments["expected_element_index"] = str(entry["element"]["index"])
                self._call("type_text", arguments)
            elif command == "sendkey":
                self._call("press_key", {"app": app, "key": request["key"], "key_method": "sky_key"})
            elif command == "scroll":
                if main_scroll:
                    scroll_areas = [candidate for candidate in capture["hints"].values()
                                    if candidate["kind"] == "ax" and str(candidate["element"].get("role", "")).lower()
                                    in ("axscrollarea", "scrollarea", "scroll area")]
                    if len(scroll_areas) != 1:
                        raise ApplicationUseError("Main is ambiguous; choose an explicit AX scroll-area hint.")
                    entry = scroll_areas[0]
                if not entry or entry["kind"] != "ax":
                    raise ApplicationUseError("Background scrolling requires an AX element hint.")
                arguments = {"app": app, "element_index": str(entry["element"]["index"]),
                             "direction": request["direction"]}
                if request.get("pages") is not None:
                    arguments["pages"] = request["pages"]
                    self._call("scroll", arguments)
                else:
                    arguments["pixels"] = request.get("distance") or 200
                    self._call("scroll_pixels", arguments)
            after = self._capture(app)
            self._remember(app, after)
            return self._render(after)
        except Exception:
            self.snapshots.pop(app, None)
            raise


def parser():
    root = argparse.ArgumentParser(description="Operate a named app in the background without foreground fallback.")
    commands = root.add_subparsers(dest="command", required=True)
    for command in ("doctor", "open", "snapshot", "close", "session-stop"):
        commands.add_parser(command)
    search = commands.add_parser("search")
    search.add_argument("query", nargs="?", default="")
    click = commands.add_parser("click")
    click.add_argument("hint")
    click.add_argument("--double", action="store_true")
    click.add_argument("--right", action="store_true")
    fill = commands.add_parser("fill", aliases=["type"])
    fill.add_argument("values", nargs="+")
    sendkey = commands.add_parser("sendkey")
    sendkey.add_argument("key")
    scroll = commands.add_parser("scroll")
    scroll.add_argument("area")
    scroll.add_argument("direction", choices=("up", "down", "left", "right"))
    scroll.add_argument("distance", nargs="?", type=float)
    scroll.add_argument("--pages", type=float)
    screenshot = commands.add_parser("screenshot")
    screenshot.add_argument("path", nargs="?", default="screenshot.png")
    screenshot.add_argument("--frame", "-f")
    return root


def parse_request(argv):
    app, remaining = None, []
    index = 0
    while index < len(argv):
        value = argv[index]
        if value == "--":
            remaining.extend(argv[index:])
            break
        if value in ("--appName", "-a"):
            if index + 1 >= len(argv):
                raise ApplicationUseError("--appName requires a value.")
            if app is not None:
                raise ApplicationUseError("Specify --appName only once.")
            app = argv[index + 1]
            index += 2
            continue
        if value.startswith("--appName="):
            if app is not None:
                raise ApplicationUseError("Specify --appName only once.")
            app = value.split("=", 1)[1]
        else:
            remaining.append(value)
        index += 1
    request = vars(parser().parse_args(remaining))
    request["app"] = app
    if request["command"] in ("fill", "type"):
        values = request.pop("values")
        if len(values) not in (1, 2):
            raise ApplicationUseError("fill accepts text, or a hint followed by text; quote text containing spaces.")
        request.update(command="fill", hint=values[0] if len(values) == 2 else None, text=values[-1])
    if request["command"] == "screenshot":
        request["path"] = str(Path(request["path"]).absolute())
    if request["command"] == "scroll":
        if request["pages"] is not None and request["distance"] is not None:
            raise ApplicationUseError("Choose a pixel distance or --pages, not both.")
        for key in ("pages", "distance"):
            if request[key] is not None and (not math.isfinite(request[key]) or request[key] <= 0):
                raise ApplicationUseError("Scroll distance must be a positive finite number.")
    return request


def paths():
    script = Path(__file__).resolve()
    native = Path(os.environ.get("APPLICATION_USE_RUNTIME") or
                  script.parent.parent / "runtime" / "ApplicationUseBackground").resolve()
    if not native.is_file() or not os.access(native, os.X_OK):
        raise ApplicationUseError("The installed background runtime is missing. No legacy fallback will be used.")
    signature = hashlib.sha256(script.read_bytes() + str(native).encode()
                               + str(native.stat().st_mtime_ns).encode()
                               + os.environ.get("APPLICATION_USE_SESSION", "").encode()
                               + os.environ.get("APPLICATION_USE_MODEL", "").encode()).hexdigest()[:16]
    directory = private_directory(Path(tempfile.gettempdir()) / ("application-use-" + str(os.getuid()) + "-" + signature))
    socket_path = directory / "session.sock"
    if len(os.fsencode(socket_path)) >= 104:
        raise ApplicationUseError("The temporary directory path is too long for a local session socket.")
    return native, directory, socket_path


def connect(socket_path):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(NATIVE_TIMEOUT * 5)
    try:
        connection.connect(str(socket_path))
        if peer_uid(connection) != os.getuid():
            raise ApplicationUseError("The session belongs to another user.")
        return connection
    except Exception:
        connection.close()
        raise


def session_request(request, start=True):
    native, directory, socket_path = paths()
    lock_fd = os.open(str(directory / "start.lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            connection = connect(socket_path)
        except (FileNotFoundError, ConnectionRefusedError):
            if not start:
                return "No background session was running."
            if socket_path.exists():
                if not stat.S_ISSOCK(socket_path.lstat().st_mode):
                    raise ApplicationUseError("The session socket path is occupied by another file.")
                socket_path.unlink()
            child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "_serve"],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
            deadline = time.monotonic() + 5
            while True:
                try:
                    connection = connect(socket_path)
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    if child.poll() is not None or time.monotonic() >= deadline:
                        raise ApplicationUseError("Could not start the private background session.")
                    time.sleep(0.05)
    with connection:
        stream = connection.makefile("rwb")
        try:
            stream.write(json.dumps(request, ensure_ascii=False).encode() + b"\n")
            stream.flush()
            response = read_line(stream)
        finally:
            stream.close()
    if not response.get("ok"):
        raise ApplicationUseError(str(response.get("error") or "The background operation failed."))
    return response["text"]


def serve():
    native_path, directory, socket_path = paths()
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(socket_path))
    os.chmod(socket_path, 0o600)
    listener.listen(8)
    listener.settimeout(IDLE_SECONDS)
    # Tool errors travel in the JSON protocol. Native debug stderr can include
    # input text, so the private session never persists it to a log file.
    native_log = open(os.devnull, "ab", buffering=0)
    native = NativeClient(native_path, native_log)
    session = BackgroundSession(native, directory, os.environ.get("APPLICATION_USE_MODEL") or
                                 os.environ.get("APPLICATION_USE_MODEL_PATH"))
    try:
        while True:
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                break
            with connection:
                connection.settimeout(10)
                if peer_uid(connection) != os.getuid():
                    continue
                with connection.makefile("rwb") as stream:
                    request = None
                    try:
                        request = read_line(stream)
                        if not isinstance(request, dict):
                            raise ApplicationUseError("Invalid local request.")
                        if request.get("command") == "_shutdown":
                            # The reply is also the cursor-cleanup acknowledgement:
                            # do not report completion while the native app is alive.
                            native.close()
                            response = {"ok": True, "text": "Background session closed."}
                        else:
                            response = {"ok": True, "text": session.execute(request)}
                    except Exception as error:
                        response = {"ok": False, "error": str(error)}
                    try:
                        stream.write(json.dumps(response, ensure_ascii=False).encode() + b"\n")
                        stream.flush()
                    except (BrokenPipeError, OSError):
                        pass
                    if isinstance(request, dict) and request.get("command") == "_shutdown":
                        break
                    if native.process.poll() is not None:
                        break
    finally:
        native.close()
        native_log.close()
        listener.close()
        socket_path.unlink(missing_ok=True)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        if argv == ["_serve"]:
            serve()
            return 0
        if argv in (["_shutdown"], ["session-stop"]):
            print(session_request({"command": "_shutdown"}, start=False))
            return 0
        print(session_request(parse_request(argv)))
        return 0
    except (ApplicationUseError, OSError) as error:
        print("application-use: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
