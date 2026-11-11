import base64
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
from unittest import mock

import application_use as appuse


IMAGE = base64.b64encode(b"test image bytes").decode()


def snapshot(window=17, elements=None, image=IMAGE):
    return {
        "app": "Fixture", "bundleIdentifier": "test.background.fixture", "pid": 99,
        "windowID": window, "windowBounds": {"x": 10, "y": 20, "width": 500, "height": 400},
        "elements": elements if elements is not None else [
            {"index": 1, "role": "AXButton", "title": "Counter", "value": None,
             "frame": {"x": 10, "y": 20, "width": 40, "height": 20}},
            {"index": 2, "role": "AXTextField", "title": "Input", "value": "",
             "frame": {"x": 10, "y": 60, "width": 200, "height": 20}},
            {"index": 3, "role": "AXScrollArea", "title": "Content", "value": None,
             "frame": {"x": 10, "y": 100, "width": 300, "height": 200}},
        ],
        "result": {"isError": False, "content": [
            {"type": "text", "text": "fixture snapshot"},
            {"type": "image", "mimeType": "image/png", "data": image},
        ]},
    }


class FakeNative:
    def __init__(self):
        self.calls = []
        self.capture = snapshot()
        self.observations = []
        self.error_tool = None

    def call(self, tool, arguments):
        self.calls.append((tool, copy.deepcopy(arguments)))
        if tool == self.error_tool:
            return {"isError": True, "content": [{"type": "text", "text": "Denied"}]}
        if tool == "snapshot":
            return copy.deepcopy(self.capture)
        if tool == "recognize":
            return {"width": 1000, "height": 800, "observations": copy.deepcopy(self.observations),
                    "warnings": []}
        if tool == "doctor":
            return {"allGranted": False, "missingPermissions": ["accessibility"]}
        return {"isError": False, "content": [{"type": "text", "text": "ok"}]}


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.native = FakeNative()
        self.session = appuse.BackgroundSession(self.native, self.temp.name, "/model.mlpackage")

    def take_snapshot(self):
        return self.session.execute({"command": "snapshot", "app": "Fixture"})

    def action_calls(self):
        return [(tool, arguments) for tool, arguments in self.native.calls
                if tool not in ("snapshot", "recognize")]

    def test_snapshot_produces_source_hints_and_private_image_not_base64(self):
        self.native.observations = [{"kind": "text", "text": "Visible text", "confidence": 0.9,
                                    "frame": {"x": 200, "y": 200, "width": 80, "height": 20}}]
        text = self.take_snapshot()
        self.assertIn("[A] AX AXButton Counter", text)
        self.assertIn("[D] OCR Visible text", text)
        self.assertNotIn(IMAGE, text)
        path = Path(text.split("Screenshot: ", 1)[1])
        self.assertEqual(path.read_bytes(), b"test image bytes")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.native.calls[-1][1]["model_path"], "/model.mlpackage")

    def test_click_revalidates_then_uses_only_sky_click(self):
        self.take_snapshot()
        self.session.execute({"command": "click", "hint": "A", "double": True})
        self.assertEqual(self.action_calls(), [("click", {"app": "test.background.fixture",
            "click_method": "sky_click", "mouse_button": "left", "click_count": 2, "element_index": "1"})])

    def test_no_implicit_foreground_target(self):
        with self.assertRaisesRegex(appuse.ApplicationUseError, "foreground app is never selected"):
            self.session.execute({"command": "snapshot"})
        self.assertEqual(self.native.calls, [])

    def test_action_requires_previous_snapshot(self):
        with self.assertRaisesRegex(appuse.ApplicationUseError, "No snapshot"):
            self.session.execute({"command": "click", "hint": "A", "app": "Fixture"})
        self.assertEqual(self.native.calls, [])

    def test_window_change_rejects_before_input(self):
        self.take_snapshot()
        self.native.capture["windowID"] = 18
        with self.assertRaisesRegex(appuse.ApplicationUseError, "window changed"):
            self.session.execute({"command": "click", "hint": "A"})
        self.assertEqual(self.action_calls(), [])

    def test_reused_index_with_changed_control_rejects(self):
        self.take_snapshot()
        self.native.capture["elements"][0]["title"] = "Delete document"
        with self.assertRaisesRegex(appuse.ApplicationUseError, "stale"):
            self.session.execute({"command": "click", "hint": "A"})
        self.assertEqual(self.action_calls(), [])

    def test_expired_hint_rejects_before_native_work(self):
        self.take_snapshot()
        self.session.snapshots[self.session.last_app]["created"] = time.monotonic() - 121
        before = len(self.native.calls)
        with self.assertRaisesRegex(appuse.ApplicationUseError, "expired"):
            self.session.execute({"command": "click", "hint": "A"})
        self.assertEqual(len(self.native.calls), before)

    def test_fill_preserves_insertion_and_unicode_semantics(self):
        self.take_snapshot()
        self.session.execute({"command": "fill", "hint": "B", "text": " 中文🙂  "})
        calls = self.action_calls()
        self.assertEqual([tool for tool, _ in calls], ["click", "type_text"])
        self.assertEqual(calls[1][1], {"app": "test.background.fixture", "text": " 中文🙂  ",
                                     "key_method": "sky_key", "expected_element_index": "2"})

    def test_fill_without_hint_does_not_click(self):
        self.take_snapshot()
        self.session.execute({"command": "fill", "text": ""})
        self.assertEqual([tool for tool, _ in self.action_calls()], ["type_text"])

    def test_fill_button_rejects_before_click_or_text(self):
        self.take_snapshot()
        with self.assertRaisesRegex(appuse.ApplicationUseError, "editable AX text control"):
            self.session.execute({"command": "fill", "hint": "A", "text": "wrong target"})
        self.assertEqual(self.action_calls(), [])

    def test_fill_ocr_target_rejects_without_click_or_text(self):
        self.native.observations = [{"kind": "text", "text": "Text input", "confidence": 0.9,
                                    "frame": {"x": 200, "y": 100, "width": 80, "height": 20}}]
        self.take_snapshot()
        with self.assertRaisesRegex(appuse.ApplicationUseError, "editable AX hint"):
            self.session.execute({"command": "fill", "hint": "D", "text": "text"})
        self.assertEqual(self.action_calls(), [])
        self.assertEqual(self.session.snapshots, {})

    def test_fill_unknown_ax_role_rejects_without_click(self):
        self.native.capture["elements"][1]["role"] = "AXGroup"
        self.take_snapshot()
        with self.assertRaisesRegex(appuse.ApplicationUseError, "editable AX text control"):
            self.session.execute({"command": "fill", "hint": "B", "text": "text"})
        self.assertEqual(self.action_calls(), [])

    def test_sendkey_uses_sky_key(self):
        self.take_snapshot()
        self.session.execute({"command": "sendkey", "key": "cmd+a"})
        self.assertEqual(self.action_calls()[0], ("press_key", {"app": "test.background.fixture",
                                                                "key": "cmd+a", "key_method": "sky_key"}))

    def test_lifecycle_key_aliases_reject_before_any_native_call(self):
        for key in ("cmd+q", "Command+W", "SUPER+alt+m", "shift+meta+h", "cmd+shift+Tab"):
            with self.subTest(key=key), self.assertRaisesRegex(appuse.ApplicationUseError, "lifecycle shortcut"):
                self.session.execute({"command": "sendkey", "key": key})
        self.assertEqual(self.native.calls, [])

    def test_plain_tab_remains_available(self):
        self.take_snapshot()
        self.session.execute({"command": "sendkey", "key": "Tab"})
        self.assertEqual(self.action_calls()[0][1]["key"], "Tab")

    def test_pixel_scroll_is_not_silently_converted_to_pages(self):
        self.take_snapshot()
        self.session.execute({"command": "scroll", "area": "C", "direction": "down", "distance": 451})
        self.assertEqual(self.action_calls()[0], ("scroll_pixels", {"app": "test.background.fixture",
            "element_index": "3", "direction": "down", "pixels": 451}))

    def test_default_scroll_preserves_200_pixel_default(self):
        self.take_snapshot()
        self.session.execute({"command": "scroll", "area": "C", "direction": "down"})
        self.assertEqual(self.action_calls()[0][1]["pixels"], 200)

    def test_main_scroll_requires_a_unique_scroll_area(self):
        self.take_snapshot()
        self.session.execute({"command": "scroll", "area": "Main", "direction": "down"})
        self.assertEqual(self.action_calls()[0][1]["element_index"], "3")
        extra = copy.deepcopy(self.native.capture["elements"][2])
        extra["index"] = 4
        self.native.capture["elements"].append(extra)
        with self.assertRaisesRegex(appuse.ApplicationUseError, "ambiguous"):
            self.session.execute({"command": "scroll", "area": "Main", "direction": "down"})
        self.assertEqual(len(self.action_calls()), 1)

    def test_ocr_click_uses_screenshot_pixels(self):
        self.native.observations = [{"kind": "text", "text": "OCR only", "confidence": 0.9,
                                    "frame": {"x": 200, "y": 100, "width": 80, "height": 20}}]
        self.take_snapshot()
        self.session.execute({"command": "click", "hint": "D"})
        self.assertEqual(self.action_calls()[0][1]["x"], 240)
        self.assertEqual(self.action_calls()[0][1]["y"], 110)
        self.assertNotIn("element_index", self.action_calls()[0][1])

    def test_icon_rejects_changed_image_even_at_same_position(self):
        self.native.observations = [{"kind": "icon", "text": "icon", "confidence": 0.9,
                                    "frame": {"x": 200, "y": 100, "width": 20, "height": 20}}]
        self.take_snapshot()
        self.native.capture["result"]["content"][1]["data"] = base64.b64encode(b"changed icon").decode()
        with self.assertRaisesRegex(appuse.ApplicationUseError, "stale"):
            self.session.execute({"command": "click", "hint": "D"})
        self.assertEqual(self.action_calls(), [])

    def test_right_click_rejected_without_native_call(self):
        with self.assertRaisesRegex(appuse.ApplicationUseError, "Right-click"):
            self.session.execute({"command": "click", "hint": "A", "right": True})
        self.assertEqual(self.native.calls, [])

    def test_native_error_invalidates_hints_and_never_retries(self):
        self.take_snapshot()
        self.native.error_tool = "click"
        with self.assertRaisesRegex(appuse.ApplicationUseError, "Denied"):
            self.session.execute({"command": "click", "hint": "A"})
        self.assertEqual([tool for tool, _ in self.action_calls()], ["click"])
        self.assertEqual(self.session.snapshots, {})

    def test_screenshot_refuses_existing_destination(self):
        destination = Path(self.temp.name) / "existing.png"
        destination.write_bytes(b"keep")
        with self.assertRaisesRegex(appuse.ApplicationUseError, "already exists"):
            self.session.execute({"command": "screenshot", "app": "Fixture", "path": str(destination)})
        self.assertEqual(destination.read_bytes(), b"keep")

    def test_doctor_reports_missing_permissions_without_opening_anything(self):
        result = json.loads(self.session.execute({"command": "doctor"}))
        self.assertFalse(result["allGranted"])
        self.assertEqual(self.native.calls, [("doctor", {})])

    def test_unknown_command_cannot_fallback_to_legacy(self):
        with self.assertRaisesRegex(appuse.ApplicationUseError, "no foreground or legacy fallback"):
            self.session.execute({"command": "activate", "app": "Fixture"})
        self.assertEqual(self.native.calls, [])


class ParsingAndProtocolTests(unittest.TestCase):
    def test_help_advertises_session_stop(self):
        self.assertIn("session-stop", appuse.parser().format_help())

    def test_app_option_may_follow_command_and_text_is_preserved(self):
        request = appuse.parse_request(["fill", "B", " spaced text ", "--appName", "Fixture"])
        self.assertEqual(request["app"], "Fixture")
        self.assertEqual(request["text"], " spaced text ")
        self.assertEqual(request["hint"], "B")

    def test_foreground_flag_is_not_accepted(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            appuse.parse_request(["click", "A", "--foreground"])

    def test_scroll_units_cannot_conflict(self):
        with self.assertRaisesRegex(appuse.ApplicationUseError, "not both"):
            appuse.parse_request(["scroll", "C", "down", "500", "--pages", "1"])

    def test_nonfinite_scroll_is_rejected(self):
        with self.assertRaises(appuse.ApplicationUseError):
            appuse.parse_request(["scroll", "C", "down", "nan"])

    def test_native_environment_cannot_enable_global_input(self):
        process = mock.Mock()
        process.poll.return_value = 0
        with mock.patch.dict(os.environ, {"OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": "1",
                                          "OPEN_COMPUTER_USE_UNKNOWN_SWITCH": "1"}), \
             mock.patch.object(appuse.subprocess, "Popen", return_value=process) as spawn:
            client = appuse.NativeClient("/native", io.BytesIO())
            environment = spawn.call_args.kwargs["env"]
            self.assertEqual(environment["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS"], "0")
            self.assertNotIn("OPEN_COMPUTER_USE_UNKNOWN_SWITCH", environment)
            client.close()

    def test_native_json_lines_round_trip_and_tool_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "native"
            executable.write_text("#!/usr/bin/env python3\nimport json,sys\nfor line in sys.stdin:\n"
                                  " request=json.loads(line)\n"
                                  " print(json.dumps({'content':[{'type':'text','text':request['tool']}],"
                                  "'isError':request['tool']=='denied'}),flush=True)\n")
            executable.chmod(0o700)
            with open(os.devnull, "wb") as log:
                client = appuse.NativeClient(executable, log)
                try:
                    self.assertEqual(appuse.result_text(client.call("snapshot", {"app": "Fixture"})), "snapshot")
                    with self.assertRaisesRegex(appuse.ApplicationUseError, "denied"):
                        client.call("denied", {})
                finally:
                    client.close()
                    client.close()

    def test_socket_peer_uid_is_checked_on_supported_platform(self):
        first, second = socket.socketpair()
        try:
            self.assertEqual(appuse.peer_uid(first), os.getuid())
        finally:
            first.close()
            second.close()

    def test_private_directory_rejects_permissive_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "unsafe"
            path.mkdir(mode=0o755)
            with self.assertRaises(appuse.ApplicationUseError):
                appuse.private_directory(path)

    def test_daemon_retains_hints_across_cli_processes_with_private_socket(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "native"
            script = ("#!/usr/bin/env python3\nimport json,sys\n"
                      "capture=" + repr(snapshot()) + "\n"
                      "for line in sys.stdin:\n"
                      " request=json.loads(line)\n"
                      " tool=request['tool']\n"
                      " if tool=='snapshot': response=capture\n"
                      " elif tool=='recognize': response={'width':1000,'height':800,'observations':[],'warnings':[]}\n"
                      " else: response={'content':[{'type':'text','text':'ok'}],'isError':False}\n"
                      " print(json.dumps(response),flush=True)\n")
            executable.write_text(script)
            executable.chmod(0o700)
            environment = os.environ.copy()
            environment.update(APPLICATION_USE_RUNTIME=str(executable), APPLICATION_USE_SESSION="unit-test-daemon")
            entry = str(Path(appuse.__file__).resolve())
            command = [appuse.sys.executable, entry]
            with mock.patch.dict(os.environ, environment):
                _, runtime_directory, socket_path = appuse.paths()
            try:
                first = subprocess.run(command + ["snapshot", "--appName", "Fixture"], env=environment,
                                       capture_output=True, text=True, timeout=15)
                self.assertEqual(first.returncode, 0, first.stderr)
                self.assertEqual(runtime_directory.stat().st_mode & 0o777, 0o700)
                self.assertEqual(socket_path.stat().st_mode & 0o777, 0o600)
                second = subprocess.run(command + ["click", "A"], env=environment,
                                        capture_output=True, text=True, timeout=15)
                self.assertEqual(second.returncode, 0, second.stderr)
                self.assertIn("[A] AX AXButton Counter", second.stdout)
            finally:
                stopped = subprocess.run(command + ["_shutdown"], env=environment,
                                         capture_output=True, text=True, timeout=15)
                self.assertEqual(stopped.returncode, 0, stopped.stderr)
            deadline = time.monotonic() + 5
            while socket_path.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertFalse(socket_path.exists())

    def test_session_stop_waits_for_delayed_native_exit_before_success(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "native"
            exit_marker = Path(directory) / "native-exited"
            executable.write_text(
                "#!/usr/bin/env python3\nimport json,os,sys,time\nfrom pathlib import Path\n"
                "for line in sys.stdin:\n"
                " request=json.loads(line)\n"
                " print(json.dumps({'runtimePID':os.getpid(),'allGranted':True}),flush=True)\n"
                "time.sleep(0.4)\n"
                "Path(" + repr(str(exit_marker)) + ").write_text('finished')\n")
            executable.chmod(0o700)
            environment = os.environ.copy()
            environment.update(APPLICATION_USE_RUNTIME=str(executable),
                               APPLICATION_USE_SESSION="unit-test-delayed-native-exit")
            command = [appuse.sys.executable, str(Path(appuse.__file__).resolve())]
            try:
                started = subprocess.run(command + ["doctor"], env=environment,
                                         capture_output=True, text=True, timeout=15)
                self.assertEqual(started.returncode, 0, started.stderr)
                runtime_pid = json.loads(started.stdout)["runtimePID"]
                stopped = subprocess.run(command + ["session-stop"], env=environment,
                                         capture_output=True, text=True, timeout=15)
                self.assertEqual(stopped.returncode, 0, stopped.stderr)
                self.assertIn("session closed", stopped.stdout)
                self.assertTrue(exit_marker.exists(), "Success arrived before native EOF cleanup completed")
                with self.assertRaises(ProcessLookupError):
                    os.kill(runtime_pid, 0)
            finally:
                subprocess.run(command + ["_shutdown"], env=environment,
                               capture_output=True, text=True, timeout=15)


if __name__ == "__main__":
    unittest.main()
