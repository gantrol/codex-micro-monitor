#!/usr/bin/env python3
"""Packaged Micro -> native bridge -> App Server/Unix IPC fixtures.

No installed Codex, real auth, real chat, Launch Services or native UI operation
is used. This is process E2E at the protocol boundary, not live Codex acceptance.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import selectors
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

A = "01000000-0000-0000-0000-000000000001"
B = "01000000-0000-0000-0000-000000000002"
PINNED_SECTION = "01984de2-8f74-7c91-a3b2-5c5e937cf318"
PINNED_PROJECT = "02000000-0000-0000-0000-000000000001"
MODELS = [{"model": "fixture-a", "displayName": "Fixture A", "defaultReasoningEffort": "medium", "supportedReasoningEfforts": [{"reasoningEffort": x} for x in ("low", "medium", "high")], "serviceTiers": [{"id": "fast"}]}, {"model": "fixture-b", "defaultReasoningEffort": "low", "supportedReasoningEfforts": [{"reasoningEffort": "low"}], "serviceTiers": []}]


def fixture_cli():
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method, params = request["method"], request.get("params", {})
        fixture_root=Path(os.environ["CODEX_HOME"])
        with (fixture_root / "catalog-calls.jsonl").open("a") as log:
            log.write(json.dumps({"method":method,"params":params})+"\n")
        roster_file=fixture_root / "roster-fixture.json"
        roster=json.loads(roster_file.read_text()) if roster_file.exists() else {}
        result = {
            "initialize": {"codexHome": os.environ["CODEX_HOME"]},
            "getAuthStatus": {"authMethod": roster.get("authMethod","fixture"), "requiresOpenaiAuth": False},
            "model/list": {"data": MODELS, "nextCursor": None},
            "thread/list": {"data": [{"id": i, "name": "Same title", "status": {"type": "idle"}} for i in (A, B)]},
            "thread/read": {"thread": {"id": A if params.get("threadId") == B else params.get("threadId"), "cwd": str(Path(os.environ["CODEX_HOME"]) / "Fixture Project #1") if params.get("threadId") == A else None}},
            "config/read": {"config": {"desktop": {}}},
            "account/rateLimits/read": {"rateLimits": {}},
            "collaborationMode/list": {"data": [{"mode": "plan"}, {"mode": "default"}]},
        }.get(method)
        priority_mode=roster.get("priority")
        if method == "thread/list" and not params.get("archived") and "sectionId" not in params and "projectId" not in params and priority_mode:
            page=int(params.get("cursor","0")) if str(params.get("cursor","0")).isdigit() else 1
            def candidate(n):
                status={"type":"active","activeFlags":["waitingOnApproval"]} if n==115 else {"type":"idle"}
                item={"id":f"01000000-0000-0000-0000-{n:012d}","name":"Same title","recencyAt":200-n,"status":status}
                if n==149 and roster.get("rollout"):
                    item.update(status={"type":"notLoaded"},path=str(fixture_root / "sessions" / "old-priority.jsonl"))
                return item
            result={"data":[candidate(n) for n in (range(1,101) if page==0 else range(101,151))],"nextCursor":"1" if page==0 else None}
            if priority_mode=="duplicate" and page:result={"data":[candidate(1)]}
            elif priority_mode=="malformed" and page:result={"data":[{"id":"not-a-chat"}]}
            elif priority_mode=="loop":result={"data":[] if page else [candidate(1)],"nextCursor":"1"}
            elif priority_mode=="empty-middle":
                result={"data":[] if page==1 else [candidate(150)] if page==2 else [candidate(1)],"nextCursor":str(page+1) if page<2 else None}
        pin_mode=roster.get("pins","ordered")
        if method == "threadSection/list":
            if pin_mode == "unsupported":
                print(json.dumps({"id":request["id"],"error":{"code":-32601,"message":"Unsupported threadSection/list"}}),flush=True);continue
            if pin_mode == "missing":result={"data":[{"id":A,"name":"Pinned"}],"nextCursor":None}
            else:result={"data":[{"id":PINNED_SECTION,"name":"Renamed section"}]} if params.get("cursor") else {"data":[{"id":A,"name":"Pinned"}],"nextCursor":"sections-next"}
        if method == "thread/list" and params.get("sectionId"):
            assert params["sectionId"]==PINNED_SECTION and params["sortKey"]=="section_position"
            assert "sortDirection" not in params and params["modelProviders"]==[]
            assert params["useStateDbOnly"] is True and params["archived"] is False
            if pin_mode == "sort-unsupported":
                print(json.dumps({"id":request["id"],"error":{"code":-32602,"message":"Unsupported section_position"}}),flush=True);continue
            old="01000000-0000-0000-0000-000000000003"
            def pin_row(identity):return {"id":identity,"name":None,"preview":"Same title","status":{"type":"idle"},"section":{"id":PINNED_SECTION}}
            result={"data":[pin_row(B if params.get("cursor") else old)],"nextCursor":None if params.get("cursor") else "pins-next"}
            if pin_mode == "empty":result={"data":[],"nextCursor":None}
            elif pin_mode == "wrong-section":result={"data":[dict(pin_row(old),section={"id":A})]}
            elif pin_mode == "duplicate":result={"data":[pin_row(old),pin_row(old)]}
            elif pin_mode == "repeat":result={"data":[],"nextCursor":"same"}
            elif pin_mode == "cap":result={"data":[pin_row(old)] if not params.get("cursor") else [],"nextCursor":str(int(params.get("cursor","0"))+1)}
            elif pin_mode == "too-many":result={"data":[pin_row(f"01000000-0000-0000-0000-{i:012d}") for i in range(1,21)],"nextCursor":"more"}
            elif pin_mode == "ranked-pages":
                result={"data":[dict(pin_row(f"01000000-0000-0000-0000-{i:012d}"),recencyAt=500 if i==15 else i) for i in ([15] if params.get("cursor") else range(1,15))],"nextCursor":None if params.get("cursor") else "rank-next"}
        project_mode=roster.get("projects")
        if method == "project/list":
            assert params["limit"]==100 and params["sortKey"]=="position"
            if project_mode == "unsupported":
                print(json.dumps({"id":request["id"],"error":{"code":-32601,"message":"Unsupported project/list"}}),flush=True);continue
            item={"id":PINNED_PROJECT,"name":"Same title","roots":[{"path":"/fixture/project"}],"metadata":{}}
            result={"data":[item]} if params.get("cursor") else {"data":[dict(item,id="02000000-0000-0000-0000-000000000002")],"nextCursor":"project-next"}
            if project_mode == "duplicate":result={"data":[item,item]}
            if project_mode == "change-preferences":
                state_file=fixture_root / ".codex-global-state.json";state=json.loads(state_file.read_text())
                state["electron-persisted-atom-state"]["unified-sidebar-pinned-order-v1"]=["codex:project:legacy-project"]
                state_file.write_text(json.dumps(state))
        if method == "thread/list" and params.get("projectId"):
            assert params["projectId"]==PINNED_PROJECT and params["sortKey"]=="recency_at" and params["sortDirection"]=="desc"
            assert params["modelProviders"]==[] and params["archived"] is False and params["useStateDbOnly"] is True
            def project_member(n):return {"id":f"01000000-0000-0000-0000-{n:012d}","name":"Same title","projectId":PINNED_PROJECT,"recencyAt":100-n,"status":{"type":"idle"}}
            result={"data":[project_member(21)]} if params.get("cursor") else {"data":[project_member(3),project_member(20)],"nextCursor":"members-next"}
            if project_mode == "wrong-member":result={"data":[dict(project_member(20),projectId="02000000-0000-0000-0000-000000000002")]}
            elif project_mode == "duplicate-member":result={"data":[project_member(20),project_member(20)]}
            elif project_mode == "loop-members":result={"data":[],"nextCursor":"same"}
        if method == "thread/read" and params.get("threadId") == "01000000-0000-0000-0000-000000000003":
            result={"thread":{"id":A if roster.get("wrongRead") else params["threadId"],"name":None,"preview":"Same title","status":{"type":"idle"}}}
        if method == "thread/read" and roster.get("clientReadChange"):
            if roster["clientReadChange"] == "account":
                roster["authMethod"]="fixture-other-account";roster_file.write_text(json.dumps(roster))
            else:
                state_file=fixture_root / ".codex-global-state.json";state=json.loads(state_file.read_text())
                bindings=state["electron-persisted-atom-state"]["client-thread-bindings-v1"]
                if roster["clientReadChange"] == "remove":bindings.clear()
                else:bindings["client-new-thread:"+A]=B
                state_file.write_text(json.dumps(state))
        if method == "thread/read" and params.get("threadId") == "01000000-0000-0000-0000-000000000004":
            print(json.dumps({"id":request["id"],"error":{"code":-32000,"message":"Fixture mapped chat was deleted"}}),flush=True)
            continue
        if method == "thread/list" and params.get("archived"):
            control=Path(os.environ["CODEX_HOME"]) / "archive-fixture.json"
            mode=json.loads(control.read_text())["mode"] if control.exists() else "absent"
            assert params["useStateDbOnly"] is True and params["modelProviders"] == [] and params["limit"] == 100
            assert "subAgent" in params["sourceKinds"] and "unknown" in params["sourceKinds"]
            cursor=params.get("cursor")
            if mode == "present-later":
                result={"data":[{"id":A if cursor == "next" else B}],"nextCursor":None if cursor else "next"}
            elif mode == "repeat":result={"data":[],"nextCursor":"stuck"}
            elif mode == "cap":result={"data":[],"nextCursor":str(int(cursor or "0")+1)}
            elif mode == "invalid":result={"data":[],"nextCursor":123}
            else:result={"data":[],"nextCursor":None}
        response = {"id": request["id"], "result": result} if result is not None else {"id": request["id"], "error": {"message": "Fixture does not implement " + method}}
        print(json.dumps(response), flush=True)


class DesktopFixture:
    def __init__(self, folder):
        self.folder = folder
        (folder / ".codex-global-state.json").write_text(json.dumps({"electron-thread-read-state-v1": {"version": 1, "unreadByIdentity": {}}}))
        self.path = folder / "ipc" / "ipc.sock"
        self.path.parent.mkdir(mode=0o700)
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(self.path)); os.chmod(self.path, 0o600)
        self.server.listen(); self.server.settimeout(0.2)
        self.stopped = False
        self.lock = threading.RLock()
        self.mutations = []
        self.observations = {}
        self.subscribers = {}
        self.observation_revisions = {}
        self.discoveries = []
        self.errors = []
        self.drop_next_mutation_reply = False
        self.owner = "fixture-owner"
        self.state = {"title": "Same title", "latestModel": "fixture-a", "latestReasoningEffort": "medium", "latestThreadSettings": {"model": "fixture-a", "effort": "medium", "serviceTier": None, "collaborationMode": {"mode": "default"}}, "threadRuntimeStatus": {"type": "idle"}, "requests": [], "turnHistory": [], "unconfirmedTurnSubmissions": []}
        self.thread = threading.Thread(target=self.accept, daemon=True); self.thread.start()

    def accept(self):
        while not self.stopped:
            try: connection, _ = self.server.accept()
            except socket.timeout: continue
            except OSError: return
            threading.Thread(target=self.serve, args=(connection,), daemon=True).start()

    @staticmethod
    def read_exact(connection, count):
        output = b""
        while len(output) < count:
            chunk = connection.recv(count-len(output))
            if not chunk: raise EOFError()
            output += chunk
        return output

    @staticmethod
    def send(connection, message):
        data = json.dumps(message).encode()
        # Fragment headers and payloads to exercise the real framing reader.
        frame = struct.pack("<I", len(data)) + data
        connection.sendall(frame[:2]); connection.sendall(frame[2:19]); connection.sendall(frame[19:])

    def serve(self, connection):
        with connection:
            try:
                while not self.stopped:
                    size = struct.unpack("<I", self.read_exact(connection, 4))[0]
                    if not 0 < size <= 16 * 1024 * 1024: raise ValueError("Invalid frame")
                    request = json.loads(self.read_exact(connection, size))
                    method, params = request.get("method"), request.get("params", {})
                    with self.lock:
                        if request["type"] == "broadcast":
                            if method == "thread-read-state-changed":
                                assert request["version"] == 3 and params["conversationId"] == A and params["hasUnreadTurn"] is True
                                context = params["context"]
                                assert context["identity"] == {"kind": "execution-storage", "authMode": "fixture"}
                                def digest(parts): return hashlib.sha256(json.dumps(parts, separators=(",", ":")).encode()).hexdigest()
                                assert context["executionHostKey"] == "local:" + digest(["local", "local", None])
                                self.mutations.append(copy.deepcopy(request))
                                global_state = {"electron-thread-read-state-v1": {"version": 1, "unreadByIdentity": {digest(["execution-storage", "fixture"]): {context["executionHostKey"]: [A]}}}}
                                output = self.folder / ".read-state-tmp"
                                output.write_text(json.dumps(global_state)); output.replace(self.folder / ".codex-global-state.json")
                            if method == "thread-stream-following-changed":
                                identity=params["conversationId"]
                                if params["following"]:
                                    self.subscribers.setdefault(connection,set()).add(identity)
                                    self.send(connection, {"type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": self.owner, "params": {"hostId": "local", "conversationId": identity, "change": {"type": "snapshot", "revision": self.observation_revisions.get(identity,1), "conversationState": self.observations.get(identity,self.state)}}})
                                else:self.subscribers.get(connection,set()).discard(identity)
                            continue
                        response = {"type": "response", "requestId": request["requestId"], "method": method, "resultType": "success", "handledByClientId": self.owner, "result": {}}
                        if method == "initialize": response["result"] = {"clientId": "fixture-client"}
                        elif method == "thread-owner-discovery":
                            self.discoveries.append(params["conversationId"])
                            if params["conversationId"] != A and params["conversationId"] not in self.observations:
                                response.pop("method"); response.update(resultType="error", error="no-client-found")
                        elif method.startswith("thread-follower-"):
                            assert params["conversationId"] == A, "Mutation targeted wrong chat"
                            assert request["targetClientId"] == self.owner, "Mutation targeted wrong owner"
                            self.mutations.append(copy.deepcopy(request))
                            if method == "thread-follower-update-thread-settings":
                                assert request["version"] == 2
                                patch = params["threadSettings"]
                                self.state["latestThreadSettings"].update(patch)
                                for field, key in [("model", "latestModel"), ("effort", "latestReasoningEffort")]:
                                    if field in patch: self.state[key] = patch[field]
                                response["result"] = {"applied": True}
                            elif method == "thread-follower-start-turn":
                                assert request["version"] == 2
                                assert params["turnStart"]["request"]["threadId"] == A
                                self.state["threadRuntimeStatus"] = {"type": "active"}
                                self.state["turnHistory"] = [{"turnId": "fixture-turn", "status": "inProgress"}]
                                response["result"] = {"result": {"turnId": "fixture-turn"}}
                            elif method == "thread-follower-interrupt-turn":
                                assert request["version"] == 4 and params["expectedTurnId"] == "fixture-turn"
                                self.state["threadRuntimeStatus"] = {"type": "idle"}
                                self.state["turnHistory"] = [{"turnId": "fixture-turn", "status": "interrupted"}]
                                response["result"] = {"ok": True, "interruptedTurnId": "fixture-turn"}
                            elif method in ("thread-follower-command-approval-decision", "thread-follower-file-approval-decision"):
                                assert request["version"] == 1
                                assert any(r["id"] == params["requestId"] for r in self.state["requests"])
                                self.state["requests"] = [r for r in self.state["requests"] if r["id"] != params["requestId"]]
                                response["result"] = {"ok": True}
                            else: raise AssertionError("Unexpected mutation: " + method)
                            if self.drop_next_mutation_reply:
                                self.drop_next_mutation_reply = False
                                return
                        else: raise AssertionError("Unexpected request: " + str(method))
                        self.send(connection, response)
            except (EOFError, ConnectionError, BrokenPipeError): pass
            except Exception as error: self.errors.append(repr(error))
            finally:
                with self.lock:self.subscribers.pop(connection,None)

    def push_unread_patch(self, identity, unread):
        self.push_observation_patch(identity,{"hasUnreadTurn":unread})

    def push_observation_patch(self, identity, fields):
        with self.lock:
            base=self.observation_revisions.get(identity,1);self.observation_revisions[identity]=base+1
            self.observations[identity].update(fields)
            patches=[{"op":"replace","path":[key],"value":value} for key,value in fields.items()]
            for connection,identities in list(self.subscribers.items()):
                if identity in identities:
                    self.send(connection,{"type":"broadcast","method":"thread-stream-state-changed","version":11,"sourceClientId":self.owner,"params":{"hostId":"local","conversationId":identity,"change":{"type":"patches","baseRevision":base,"revision":base+1,"patches":patches}}})

    def close(self):
        self.stopped = True; self.server.close(); self.thread.join(timeout=1)


class MCP:
    def __init__(self, app, env):
        self.process = subprocess.Popen([str(app), "--mcp"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.selector = selectors.DefaultSelector(); self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.counter = 0; self.buffer = b""

    def request(self, method, params, expected_rpc_error=False):
        self.counter += 1
        payload = json.dumps({"jsonrpc": "2.0", "id": self.counter, "method": method, "params": params}).encode() + b"\n"
        self.process.stdin.write(payload); self.process.stdin.flush()
        deadline = time.monotonic() + 25
        while b"\n" not in self.buffer:
            if not self.selector.select(max(0, deadline-time.monotonic())): raise TimeoutError(method)
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk: raise RuntimeError("Micro terminated: " + self.process.stderr.read().decode())
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        response = json.loads(line)
        assert response["id"] == self.counter
        if expected_rpc_error:
            assert response.get("error", {}).get("code") == -32602, response
            return response["error"]
        assert "error" not in response, response
        return response["result"]

    def tool(self, name, expected_error=False, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        assert result.get("isError", False) == expected_error, result
        return result if expected_error else result["structuredContent"]

    def close(self):
        self.process.stdin.close()
        try: self.process.wait(timeout=5)
        except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
        self.selector.close()


def run(app, report):
    cases = []
    def check(name, operation):
        started = time.monotonic(); operation(); cases.append({"scenario": name, "result": "Pass", "seconds": round(time.monotonic()-started, 3)})
    with tempfile.TemporaryDirectory(prefix="micro-e2e-", dir="/tmp") as temporary:
        folder = Path(temporary).resolve()
        cli = folder / "fixture-cli"
        cli.write_text(f"#!{sys.executable}\nimport runpy, sys\nsys.argv=[{str(Path(__file__).resolve())!r}, '--fixture-cli']\nrunpy.run_path(sys.argv[0], run_name='__main__')\n")
        cli.chmod(0o700)
        env = dict(os.environ, CODEX_HOME=str(folder), CODEX_MICRO_CLI=str(cli))
        desktop = DesktopFixture(folder); mcp = MCP(app, env)
        try:
            def initialize():
                result = mcp.request("initialize", {"protocolVersion": "2025-11-25", "clientInfo": {"name": "micro-isolated-e2e", "version": "1"}, "capabilities": {}})
                assert result["serverInfo"]["name"] == "codex-micro-keypad"
                tools = mcp.request("tools/list", {})["tools"]
                catalog = {tool["name"]: tool for tool in tools}
                assert len(catalog) == len(tools)
                for name in ["toggle_keypad_pin", "copy_keypad_markdown", "archive_keypad_thread", "toggle_keypad_terminal", "open_keypad_browser", "open_keypad_side_chat", "open_keypad_merge_pull_request", "open_keypad_commit", "open_keypad_branch", "open_keypad_pull_request", "open_keypad_draft_pull_request", "run_keypad_environment_action"]:
                    tool = catalog[name]
                    assert set(tool["inputSchema"]["required"]) == {"thread_id", "target_token"}
                    assert tool["annotations"]["readOnlyHint"] is False and tool["annotations"]["idempotentHint"] is False
                for name in ["open_keypad_feedback", "open_keypad_files", "open_keypad_photos"]:
                    tool = catalog[name]
                    assert set(tool["inputSchema"]["required"]) == {"target_token"}
                    assert tool["annotations"]["readOnlyHint"] is False and tool["annotations"]["idempotentHint"] is False
                assert catalog["archive_keypad_thread"]["annotations"]["destructiveHint"] is True
                assert catalog["get_keypad_archive_state"]["annotations"]["readOnlyHint"] is True
                assert catalog["open_keypad_tasks"]["inputSchema"]["required"] == []
                preset = catalog["insert_keypad_preset_text"]
                assert set(preset["inputSchema"]["required"]) == {"preset", "target_token"}
                assert preset["inputSchema"]["properties"]["preset"]["enum"] == ["YOLO", "YEET"]
                assert preset["annotations"]["readOnlyHint"] is False and preset["annotations"]["idempotentHint"] is False
                assert catalog["list_keypad_threads"]["inputSchema"]["properties"]["mapped_thread_ids"]["maxItems"] == 14
                assert catalog["list_keypad_threads"]["inputSchema"]["properties"]["include_pinned"]["type"] == "boolean"
                assert catalog["list_keypad_threads"]["inputSchema"]["properties"]["include_priority"]["type"] == "boolean"
                assert catalog["list_keypad_threads"]["annotations"]["readOnlyHint"] is True
            check("P01 packaged MCP handshake and native tool contracts; no UI invocation", initialize)
            def state():
                result = mcp.tool("get_keypad_state", thread_id=A)
                assert result["threadId"] == A and result["model"] == "fixture-a"
                mcp.tool("get_keypad_state", expected_error=True, thread_id=B)
            check("P02 exact UUID and unavailable owner", state)
            def folder_read():
                result=mcp.tool("get_keypad_folder",thread_id=A)
                assert result["threadId"]==A and result["cwd"]==str(folder / "Fixture Project #1")
                mcp.tool("get_keypad_folder",expected_error=True,thread_id=B)
                mcp.tool("get_keypad_folder",expected_error=True,thread_id="01000000-0000-0000-0000-000000000003")
                assert not desktop.mutations
            check("P12 exact folder lookup, mismatched ID and missing cwd rejection; no workspace launch",folder_read)
            def archive_state():
                control=folder / "archive-fixture.json"
                for mode,archived,complete in [("present-later",True,True),("absent",False,True),("cap",None,False)]:
                    control.write_text(json.dumps({"mode":mode}))
                    result=mcp.tool("get_keypad_archive_state",thread_id=A)
                    assert result == {"threadId":A,"archived":archived,"complete":complete}, result
                assert not desktop.mutations
            check("P13 archived-list exact ID, pagination and bounded unknown; no archive mutation",archive_state)
            def archive_invalid():
                control=folder / "archive-fixture.json"
                for mode in ["repeat","invalid"]:
                    control.write_text(json.dumps({"mode":mode}))
                    mcp.tool("get_keypad_archive_state",expected_error=True,thread_id=A)
                mcp.tool("get_keypad_archive_state",expected_error=True,thread_id=B)
                assert not desktop.mutations
            check("P14 archive readback rejects repeated cursor, invalid cursor and mismatched ID",archive_invalid)
            def fast():
                for enabled in [True, False]*3:
                    result = mcp.tool("set_keypad_fast", thread_id=A, enabled=enabled)
                    assert result["verified"] and result["state"]["serviceTier"] == ("fast" if enabled else None)
                    assert desktop.state["latestThreadSettings"]["serviceTier"] == ("fast" if enabled else None)
                    assert desktop.state["latestModel"] == "fixture-a" and desktop.state["latestReasoningEffort"] == "medium"
            check("P03 six Fast writes with independent readback", fast)
            def reasoning():
                for effort in ["high", "low", "medium"]:
                    result = mcp.tool("set_keypad_reasoning", thread_id=A, effort=effort)
                    assert result["verified"] and desktop.state["latestReasoningEffort"] == effort
                before = len(desktop.mutations)
                mcp.tool("set_keypad_reasoning", expected_error=True, thread_id=A, effort="invalid")
                assert len(desktop.mutations) == before
            check("P04 reasoning steps and invalid effort rejection", reasoning)
            def plan():
                for mode in ["plan", "default"]:
                    result = mcp.tool("toggle_keypad_plan", thread_id=A)
                    assert result["verified"] and desktop.state["latestThreadSettings"]["collaborationMode"]["mode"] == mode
                    assert desktop.state["latestThreadSettings"]["collaborationMode"]["settings"]["developer_instructions"] is None
            check("P05 Plan round trip preserving model and effort", plan)
            def model():
                result = mcp.tool("set_keypad_model", thread_id=A, model="fixture-b", effort="low")
                assert result["verified"] and desktop.state["latestModel"] == "fixture-b"
                before = len(desktop.mutations)
                mcp.tool("set_keypad_fast", expected_error=True, thread_id=A, enabled=True)
                assert len(desktop.mutations) == before
                mcp.tool("set_keypad_model", thread_id=A, model="fixture-a", effort="medium")
            check("P06 model switch and unsupported Fast rejection", model)
            def submission():
                result = mcp.tool("send_keypad_message", thread_id=A, text="isolated fixture input")
                assert result["acknowledged"] and not result["verified"]
                before = len(desktop.mutations)
                mcp.tool("send_keypad_message", expected_error=True, thread_id=A, text="must not send")
                mcp.tool("stop_keypad_turn", expected_error=True, thread_id=A, turn_id="wrong-turn")
                assert len(desktop.mutations) == before
                result = mcp.tool("stop_keypad_turn", thread_id=A, turn_id="fixture-turn")
                assert result["verified"] and desktop.state["threadRuntimeStatus"]["type"] == "idle"
            check("P07 submit once, reject duplicate, stop exact turn", submission)
            for kind in ["commandExecution", "fileChange"]:
                for decision in ["accept", "decline"]:
                    def approval(kind=kind, decision=decision):
                        with desktop.lock: desktop.state["requests"] = [{"id": "fixture-approval", "method": f"item/{kind}/requestApproval", "params": {"command": "fixture"}}]
                        result = mcp.tool("reply_keypad_approval", thread_id=A, request_id="fixture-approval", decision=decision)
                        assert result["verified"] and not desktop.state["requests"]
                        before = len(desktop.mutations)
                        mcp.tool("reply_keypad_approval", expected_error=True, thread_id=A, request_id="fixture-approval", decision=decision)
                        assert len(desktop.mutations) == before
                    check(f"P08 {kind} {decision} exact request, no replay", approval)
            def uncertain():
                before = len(desktop.mutations); desktop.drop_next_mutation_reply = True
                mcp.tool("set_keypad_fast", expected_error=True, thread_id=A, enabled=True)
                result = mcp.tool("get_keypad_state", thread_id=A)
                assert result["serviceTier"] == "fast" and len(desktop.mutations) == before+1
                mcp.tool("set_keypad_fast", thread_id=A, enabled=False)
            check("P09 lost mutation acknowledgement is not replayed", uncertain)
            def unread():
                before = len(desktop.mutations)
                result = mcp.tool("mark_keypad_unread", thread_id=A)
                assert result["verified"] and result["hasUnreadTurn"] and result["threadId"] == A
                assert len(desktop.mutations) == before + 1
                stored = json.loads((folder / ".codex-global-state.json").read_text())["electron-thread-read-state-v1"]["unreadByIdentity"]
                assert list(list(stored.values())[0].values()) == [[A]]
                mcp.tool("mark_keypad_unread", thread_id=A)
                assert len(desktop.mutations) == before + 1
            check("P10 mark unread with account/host scope and persisted readback", unread)
            def unsafe_fork():
                before = len(desktop.mutations)
                mcp.tool("fork_keypad_thread", expected_error=True, thread_id=A)
                assert len(desktop.mutations) == before
            check("P11 fork without continuation guard is rejected before creating or opening", unsafe_fork)
            old="01000000-0000-0000-0000-000000000003"
            missing="01000000-0000-0000-0000-000000000004"
            roster_file=folder / "roster-fixture.json"
            def catalog_calls():
                return [json.loads(line) for line in (folder / "catalog-calls.jsonl").read_text().splitlines()]
            def mapped_chats():
                first=mcp.tool("list_keypad_threads")
                scope=first["rosterScope"]
                assert len(scope)==64 and all(c in "0123456789abcdef" for c in scope)
                before=len(catalog_calls());mutations=len(desktop.mutations)
                result=mcp.tool("list_keypad_threads",roster_scope=scope,mapped_thread_ids=[old,A,missing,old])
                assert [row["id"] for row in result["threads"]]==[A,B]
                assert [row["id"] for row in result["mappedThreads"]]==[old,A]
                assert result["mappedThreads"][0]["title"]=="Same title"
                assert result["unavailableMappedThreadIds"]==[missing]
                assert result["contextID"]==first["contextID"] and result["rosterScope"]==scope
                reads=[c["params"]["threadId"] for c in catalog_calls()[before:] if c["method"]=="thread/read"]
                assert reads==[old,missing] and len(desktop.mutations)==mutations
            check("P18 exact older mapped chat, duplicate slots and missing chat without catalog restart",mapped_chats)
            def scope_isolation():
                scope=mcp.tool("list_keypad_threads")["rosterScope"]
                roster_file.write_text(json.dumps({"authMethod":"fixture-other-account"}))
                try:
                    before=len(catalog_calls())
                    result=mcp.tool("list_keypad_threads",roster_scope=scope,mapped_thread_ids=[old])
                    assert result["rosterScope"]!=scope and result["mappedThreads"]==[]
                    assert not any(c["method"]=="thread/read" for c in catalog_calls()[before:])
                finally:roster_file.write_text("{}")
                assert mcp.tool("list_keypad_threads")["rosterScope"]==scope
            check("P19 changed account scope never queries saved task IDs",scope_isolation)
            def invalid_mapping():
                scope=mcp.tool("list_keypad_threads")["rosterScope"]
                before=len(catalog_calls())
                for args in [{"mapped_thread_ids":[old]}, {"roster_scope":scope,"mapped_thread_ids":["invalid"]}]:
                    mcp.tool("list_keypad_threads",expected_error=True,**args)
                for values in [[old]*15,"not-an-array",[17],[""]]:
                    mcp.request("tools/call",{"name":"list_keypad_threads","arguments":{"roster_scope":scope,"mapped_thread_ids":values}},expected_rpc_error=True)
                assert len(catalog_calls())==before
            check("P20 malformed or oversized mappings reject before any catalog read",invalid_mapping)
            def wrong_mapping_readback():
                scope=mcp.tool("list_keypad_threads")["rosterScope"]
                roster_file.write_text(json.dumps({"wrongRead":True}))
                try:mcp.tool("list_keypad_threads",expected_error=True,roster_scope=scope,mapped_thread_ids=[old])
                finally:roster_file.write_text("{}")
                result=mcp.tool("list_keypad_threads",roster_scope=scope,mapped_thread_ids=[old])
                assert [row["id"] for row in result["mappedThreads"]]==[old]
            check("P21 wrong mapped readback ID rejects without substituting a recent chat",wrong_mapping_readback)
            def ordered_pins():
                before=len(catalog_calls());mutations=len(desktop.mutations)
                original=(folder / ".codex-global-state.json").read_bytes()
                result=mcp.tool("list_keypad_threads",include_pinned=True)
                assert result["pinnedAvailable"] is True
                assert [row["id"] for row in result["pinnedThreads"]]==[old,B]
                assert [row["id"] for row in result["threads"]]==[A,B]
                assert result["pinnedThreads"][0]["title"]=="Same title"
                calls=catalog_calls()[before:]
                assert [c["method"] for c in calls]==["thread/list","getAuthStatus","threadSection/list","threadSection/list","thread/list","thread/list"]
                assert (folder / ".codex-global-state.json").read_bytes()==original and len(desktop.mutations)==mutations
                before=len(catalog_calls());mcp.tool("list_keypad_threads")
                assert all(c["method"]!="threadSection/list" and "sectionId" not in c["params"] for c in catalog_calls()[before:])
            check("P22 pinned exact section and paged native order, no migration or default query",ordered_pins)
            def unavailable_pins():
                generation=mcp.tool("list_keypad_threads")["contextID"]
                try:
                    for mode in ["empty","missing","unsupported","sort-unsupported","cap"]:
                        roster_file.write_text(json.dumps({"pins":mode}));before=len(catalog_calls())
                        result=mcp.tool("list_keypad_threads",include_pinned=True)
                        assert result["contextID"]==generation and result["pinnedThreads"]==[]
                        assert result["pinnedAvailable"] is (mode=="empty")
                        assert [row["id"] for row in result["threads"]]==[A,B]
                        assert all(c["method"] in {"thread/list","getAuthStatus","threadSection/list"} for c in catalog_calls()[before:])
                finally:roster_file.write_text("{}")
            check("P23 empty, missing, unsupported and bounded pins never fall back or restart catalog",unavailable_pins)
            def conflicting_pins():
                try:
                    for mode in ["wrong-section","duplicate","repeat"]:
                        roster_file.write_text(json.dumps({"pins":mode}));mcp.tool("list_keypad_threads",expected_error=True,include_pinned=True)
                finally:roster_file.write_text("{}")
                assert mcp.tool("list_keypad_threads",include_pinned=True)["pinnedAvailable"] is True
            check("P24 wrong-section, duplicate or looping pin pages fail without substituting a chat",conflicting_pins)
            def bounded_pins_and_unknown_identity():
                try:
                    roster_file.write_text(json.dumps({"pins":"too-many"}));before=len(catalog_calls())
                    result=mcp.tool("list_keypad_threads",include_pinned=True)
                    assert len(result["pinnedThreads"])==14
                    assert sum("sectionId" in c["params"] for c in catalog_calls()[before:])==1
                    roster_file.write_text(json.dumps({"authMethod":"chatgpt"}));before=len(catalog_calls())
                    result=mcp.tool("list_keypad_threads",include_pinned=True)
                    assert result["rosterScope"] is None and result["pinnedAvailable"] is False and result["pinnedThreads"]==[]
                    assert not any(c["method"]=="threadSection/list" or "sectionId" in c["params"] for c in catalog_calls()[before:])
                finally:roster_file.write_text("{}")
            check("P25 fourteen-pin bound and unknown identity prevent extra enumeration",bounded_pins_and_unknown_identity)
            def priority_catalog():
                roster_file.write_text(json.dumps({"priority":"paged"}));before=len(catalog_calls());mutations=len(desktop.mutations)
                result=mcp.tool("list_keypad_threads",include_priority=True)
                assert result["priorityComplete"] is True and len(result["threads"])==150
                assert result["threads"][114]["id"].endswith("000000000115") and result["threads"][114]["attention"]=="waiting"
                assert result["threads"][114]["recencyAt"]==85
                pages=[c["params"] for c in catalog_calls()[before:] if c["method"]=="thread/list"]
                assert len(pages)==2 and pages[1]["cursor"]=="1" and len(desktop.mutations)==mutations
            check("P26 complete paged priority catalog includes older exact attention and recency",priority_catalog)
            live_old="01000000-0000-0000-0000-000000000135"
            live_unread="01000000-0000-0000-0000-000000000145"
            def wait_activity(predicate, seconds=20):
                deadline=time.monotonic()+seconds
                while time.monotonic()<deadline:
                    snapshot=mcp.tool("get_keypad_activity")
                    if predicate(snapshot):return snapshot
                    time.sleep(0.05)
                raise AssertionError("Activity did not converge: "+str({"streamConnected":snapshot.get("streamConnected"),"streamError":snapshot.get("streamError"),"desktopThreads":snapshot.get("desktopThreads"),"oldAttention":snapshot.get("attention",{}).get(live_old),"unreadAttention":snapshot.get("attention",{}).get(live_unread),"errors":desktop.errors,"lastDiscoveries":desktop.discoveries[-8:],"distinctDiscoveries":len(set(desktop.discoveries)),"subscribers":[list(v) for v in desktop.subscribers.values()]}))
            def live_priority():
                with desktop.lock:
                    desktop.observations[live_old]={"threadRuntimeStatus":{"type":"active"},"requests":[{"id":"question-old","method":"item/tool/requestUserInput"}],"hasUnreadTurn":False}
                    desktop.observations[live_unread]={"threadRuntimeStatus":{"type":"active"},"requests":[],"hasUnreadTurn":False}
                mutations=len(desktop.mutations)
                snapshot=wait_activity(lambda s:s.get("attention",{}).get(live_old)=="waiting" and s.get("attention",{}).get(live_unread)=="active")
                assert snapshot["signals"][live_old]=="question" and snapshot["signals"][live_unread]=="running"
                assert snapshot["signals"]["01000000-0000-0000-0000-000000000115"]=="waiting"
                assert len(snapshot["attention"])==150 and len(desktop.mutations)==mutations
            check("P27 actual monitor discovers older live question beyond first 100 and preserves catalog flags",live_priority)
            def unread_only_revision():
                before=mcp.tool("get_keypad_activity");mutations=len(desktop.mutations)
                desktop.push_unread_patch(live_unread,True)
                after=wait_activity(lambda s:s.get("attention",{}).get(live_unread)=="unread")
                assert before["signals"][live_unread]==after["signals"][live_unread]=="running"
                assert after["revision"]>before["revision"] and len(desktop.mutations)==mutations
            check("P28 unread-only stream patch increments ranking revision while running lamp stays unchanged",unread_only_revision)
            def invalid_priority_pages():
                for mode in ["duplicate","malformed","loop"]:
                    roster_file.write_text(json.dumps({"priority":mode}));mcp.tool("list_keypad_threads",expected_error=True,include_priority=True)
                roster_file.write_text(json.dumps({"priority":"empty-middle"}))
                result=mcp.tool("list_keypad_threads",include_priority=True)
                assert result["priorityComplete"] is True and len(result["threads"])==2
                assert result["threads"][1]["id"].endswith("000000000150")
            check("P29 invalid priority pages reject partial ranking and empty pages continue",invalid_priority_pages)
            def default_recent_is_not_priority():
                roster_file.write_text(json.dumps({"priority":"paged"}));before=len(catalog_calls())
                result=mcp.tool("list_keypad_threads")
                assert len(result["threads"])==100 and result["priorityComplete"] is False
                assert sum(c["method"]=="thread/list" for c in catalog_calls()[before:])==1
                roster_file.write_text("{}")
            check("P30 returning to recent stops full priority enumeration",default_recent_is_not_priority)
            def older_rollout_priority():
                identity="01000000-0000-0000-0000-000000000149"
                path=folder / "sessions" / "old-priority.jsonl";path.parent.mkdir(exist_ok=True)
                records=[{"type":"session_meta","payload":{"id":identity}},
                    {"type":"event_msg","payload":{"type":"task_started","turn_id":"old-turn"}},
                    {"type":"event_msg","payload":{"type":"item_completed","turn_id":"old-turn","item":{"type":"agentMessage","id":"old-question","delivery":"async","questions":[{"title":"Fixture question"}]}}}]
                path.write_text("".join(json.dumps(r)+"\n" for r in records))
                roster_file.write_text(json.dumps({"priority":"paged","rollout":True}));mcp.tool("list_keypad_threads",include_priority=True)
                snapshot=wait_activity(lambda s:s.get("attention",{}).get(identity)=="waiting")
                assert snapshot["signals"][identity]=="question"
                with path.open("a") as f:f.write(json.dumps({"type":"event_msg","payload":{"type":"task_complete","turn_id":"old-turn"}})+"\n")
                snapshot=wait_activity(lambda s:s.get("attention",{}).get(identity)=="idle")
                assert snapshot["signals"][identity]=="idle"
                roster_file.write_text("{}")
            check("P31 older unloaded rollout question enters priority and completion clears it",older_rollout_priority)
            def mixed_lamp_precedence():
                roster_file.write_text(json.dumps({"priority":"paged"}));mcp.tool("list_keypad_threads",include_priority=True)
                wait_activity(lambda s:live_old in s.get("signals",{}))
                mutations=len(desktop.mutations)
                approval={"id":"approval-old","method":"item/commandExecution/requestApproval"}
                question={"id":"question-old","method":"item/tool/requestUserInput"}
                transitions=[("systemError",[question,approval],True,"error","waiting"),
                    ("active",[question,approval],True,"waiting","waiting"),
                    ("active",[question],True,"question","waiting"),
                    ("active",[],True,"running","unread"),("idle",[],True,"unread","unread"),
                    ("idle",[],False,"idle","idle")]
                for runtime,requests,unread,lamp,attention in transitions:
                    before=mcp.tool("get_keypad_activity")
                    desktop.push_observation_patch(live_old,{"threadRuntimeStatus":{"type":runtime},"requests":requests,"hasUnreadTurn":unread})
                    after=wait_activity(lambda s:s.get("signals",{}).get(live_old)==lamp and s.get("attention",{}).get(live_old)==attention)
                    assert after["revision"]>before["revision"]
                assert len(desktop.mutations)==mutations
                roster_file.write_text("{}")
            check("P32 mixed live error approval question running and unread transitions preserve independent attention",mixed_lamp_precedence)
            state_file=folder / ".codex-global-state.json"
            original_state=state_file.read_bytes()
            member_a="01000000-0000-0000-0000-000000000020"
            member_b="01000000-0000-0000-0000-000000000021"
            def pin_preferences(manual=False):
                state=json.loads(original_state)
                state.update({"pinned-project-ids":["legacy-project"],
                    "app-server-project-id-by-legacy-project-id-by-host":{"local:"+str(folder):{"legacy-project":PINNED_PROJECT}},
                    "electron-persisted-atom-state":{"unified-sidebar-pinned-order-v1":["codex:thread:local:"+B,"codex:project:legacy-project","codex:thread:local:"+old],
                    "flat-project-sidebar-preferences-v1":{"projectSortMode":"manual" if manual else "updated_at","manualSortVersion":1}}})
                return state
            def mixed_project_pins():
                try:
                    state_file.write_text(json.dumps(pin_preferences()));roster_file.write_text(json.dumps({"projects":"paged"}))
                    before=len(catalog_calls());mutations=len(desktop.mutations);saved=state_file.read_bytes()
                    result=mcp.tool("list_keypad_threads",include_pinned=True)
                    assert result["pinnedAvailable"] is True and [r["id"] for r in result["pinnedThreads"]]==[old,member_a,member_b,B]
                    calls=catalog_calls()[before:]
                    assert sum(c["method"]=="project/list" for c in calls)==2
                    assert sum("projectId" in c["params"] for c in calls)==2
                    assert state_file.read_bytes()==saved and len(desktop.mutations)==mutations
                finally:state_file.write_bytes(original_state);roster_file.write_text("{}")
            check("P33 exact paged project membership interleaves with server pins and removes duplicates",mixed_project_pins)
            def manual_project_pins():
                try:
                    state=pin_preferences(True);state["sidebar-project-thread-orders"]={"legacy-project":{"threadIds":[member_b,member_a]}}
                    state_file.write_text(json.dumps(state));roster_file.write_text(json.dumps({"projects":"paged"}))
                    assert [r["id"] for r in mcp.tool("list_keypad_threads",include_pinned=True)["pinnedThreads"]]==[old,member_b,member_a,B]
                    del state["sidebar-project-thread-orders"];state_file.write_text(json.dumps(state))
                    assert [r["id"] for r in mcp.tool("list_keypad_threads",include_pinned=True)["pinnedThreads"]]==[old,member_b,member_a,B]
                    state["electron-persisted-atom-state"]["flat-project-sidebar-preferences-v1"]["projectSortMode"]="updated_at";state_file.write_text(json.dumps(state))
                    assert [r["id"] for r in mcp.tool("list_keypad_threads",include_pinned=True)["pinnedThreads"]]==[old,member_a,member_b,B]
                finally:state_file.write_bytes(original_state);roster_file.write_text("{}")
            check("P34 stored and in-memory manual project order then recency restoration",manual_project_pins)
            def invalid_project_pins():
                try:
                    state_file.write_text(json.dumps(pin_preferences()))
                    for mode in ["wrong-member","duplicate-member","loop-members","duplicate"]:
                        roster_file.write_text(json.dumps({"projects":mode}));mcp.tool("list_keypad_threads",expected_error=True,include_pinned=True)
                    roster_file.write_text(json.dumps({"projects":"unsupported"}));result=mcp.tool("list_keypad_threads",include_pinned=True)
                    assert result["pinnedAvailable"] is False and result["pinnedThreads"]==[]
                finally:state_file.write_bytes(original_state);roster_file.write_text("{}")
            check("P35 wrong or incomplete project metadata never yields partial executable pins",invalid_project_pins)
            def changed_project_preferences():
                try:
                    state_file.write_text(json.dumps(pin_preferences()));roster_file.write_text(json.dumps({"projects":"change-preferences"}))
                    mutations=len(desktop.mutations);mcp.tool("list_keypad_threads",expected_error=True,include_pinned=True)
                    assert len(desktop.mutations)==mutations
                finally:state_file.write_bytes(original_state);roster_file.write_text("{}")
            check("P36 changed placement during project enumeration rejects the stale snapshot",changed_project_preferences)
            def foreign_project_scope():
                try:
                    state=pin_preferences();state["app-server-project-id-by-legacy-project-id-by-host"]={"local:/other/home":{"legacy-project":PINNED_PROJECT}}
                    state_file.write_text(json.dumps(state));roster_file.write_text(json.dumps({"projects":"paged"}));before=len(catalog_calls())
                    result=mcp.tool("list_keypad_threads",include_pinned=True)
                    assert [r["id"] for r in result["pinnedThreads"]]==[old,B]
                    assert not any("projectId" in c["params"] for c in catalog_calls()[before:])
                finally:state_file.write_bytes(original_state);roster_file.write_text("{}")
            check("P37 project migration identities from another storage root cannot select members",foreign_project_scope)
            def ranked_pins_after_fourteen():
                try:
                    state=json.loads(original_state);state["electron-persisted-atom-state"]={"pinned-sidebar-sort-mode-v1":"updated_at"}
                    state_file.write_text(json.dumps(state));roster_file.write_text(json.dumps({"pins":"ranked-pages"}));before=len(catalog_calls())
                    result=mcp.tool("list_keypad_threads",include_pinned=True)
                    assert len(result["pinnedThreads"])==14 and result["pinnedThreads"][0]["id"].endswith("000000000015")
                    assert sum("sectionId" in c["params"] for c in catalog_calls()[before:])==2
                finally:state_file.write_bytes(original_state);roster_file.write_text("{}")
            check("P38 updated pinned order includes the most recent chat after the first fourteen",ranked_pins_after_fourteen)
            def project_only_pins():
                try:
                    state_file.write_text(json.dumps(pin_preferences()));roster_file.write_text(json.dumps({"projects":"paged","pins":"missing"}))
                    result=mcp.tool("list_keypad_threads",include_pinned=True)
                    assert result["pinnedAvailable"] is True and [r["id"] for r in result["pinnedThreads"]]==[old,member_a,member_b]
                finally:state_file.write_bytes(original_state);roster_file.write_text("{}")
            check("P39 pinned projects remain available when no individual pin section exists",project_only_pins)
            client_id="client-new-thread:"+A
            def binding_state(atoms):
                state=json.loads(original_state);state["electron-persisted-atom-state"]=atoms
                state_file.write_text(json.dumps(state))
            def lookup_client(**extra):
                return mcp.tool("get_keypad_client_thread",client_thread_id=client_id,
                                roster_scope=mcp.tool("list_keypad_threads")["rosterScope"],**extra)
            def exact_client_binding():
                try:
                    for atoms in [{"client-thread-bindings-v1":{client_id:old}},
                                  {"thread-client-id-v1:local%3A"+old:client_id},
                                  {"client-thread-bindings-v1":{client_id:old},"thread-client-id-v1:local%3A"+old:"client-new-thread:"+B}]:
                        binding_state(atoms);before=len(catalog_calls());mutations=len(desktop.mutations);saved=state_file.read_bytes()
                        result=lookup_client()
                        assert result["resolved"] is True and result["threadId"]==old and result["thread"]["id"]==old
                        assert result["clientThreadId"]==client_id and result["thread"]["title"]==""
                        assert [c["params"] for c in catalog_calls()[before:] if c["method"]=="thread/read"]==[{"threadId":old,"includeTurns":False}]
                        assert len(desktop.mutations)==mutations and state_file.read_bytes()==saved
                finally:state_file.write_bytes(original_state)
            check("P40 client forward and reverse binding resolve exact older UUID without writes",exact_client_binding)
            def unresolved_client_binding():
                try:
                    for atoms in [{},{"draft-thread-identities-v1":{"new-conversation":client_id}},
                                  {"thread-client-id-v1:remote%3A"+old:client_id},
                                  {"client-thread-bindings-v1":{client_id:missing}}]:
                        binding_state(atoms);result=lookup_client()
                        assert result["resolved"] is False and result["threadId"] is None and result["thread"] is None
                        assert "draft" not in result
                finally:state_file.write_bytes(original_state)
            check("P41 missing remote home-only or deleted binding does not infer an unsent draft",unresolved_client_binding)
            def conflicting_client_binding():
                try:
                    for atoms in [{"client-thread-bindings-v1":{client_id:A},"thread-client-id-v1:local%3A"+old:client_id},
                                  {"client-thread-bindings-v1":{client_id:"invalid"}},
                                  {"thread-client-id-v1:local%3Abad":client_id}]:
                        binding_state(atoms);before=len(catalog_calls());lookup_client(expected_error=True)
                        assert not any(c["method"]=="thread/read" for c in catalog_calls()[before:])
                    binding_state({"client-thread-bindings-v1":{client_id:B}});lookup_client(expected_error=True)
                finally:state_file.write_bytes(original_state)
            check("P42 conflicting malformed or wrong server readback binding rejects",conflicting_client_binding)
            def client_scope_isolation():
                try:
                    binding_state({"client-thread-bindings-v1":{client_id:old}})
                    scope=mcp.tool("list_keypad_threads")["rosterScope"]
                    roster_file.write_text(json.dumps({"authMethod":"fixture-other-account"}));before=len(catalog_calls())
                    mcp.tool("get_keypad_client_thread",client_thread_id=client_id,roster_scope=scope,expected_error=True)
                    assert not any(c["method"]=="thread/read" for c in catalog_calls()[before:])
                finally:state_file.write_bytes(original_state);roster_file.write_text("{}")
            check("P43 changed account rejects client binding before querying the UUID",client_scope_isolation)
            def client_changes_during_read():
                try:
                    for change in ["account","remove","replace"]:
                        roster_file.write_text(json.dumps({"clientReadChange":change}))
                        binding_state({"client-thread-bindings-v1":{client_id:old}})
                        lookup_client(expected_error=True)
                        roster_file.write_text("{}")
                finally:state_file.write_bytes(original_state);roster_file.write_text("{}")
            check("P44 account removal or replacement during lookup invalidates result",client_changes_during_read)
            def invalid_client_request():
                before=len(catalog_calls())
                for arguments in [{"client_thread_id":"invalid","roster_scope":"a"*64},
                                  {"client_thread_id":client_id,"roster_scope":"invalid"}]:
                    mcp.tool("get_keypad_client_thread",expected_error=True,**arguments)
                assert len(catalog_calls())==before
            check("P45 invalid client identity and scope reject before catalog access",invalid_client_request)
            assert not desktop.errors, desktop.errors
        finally:
            mcp.close(); desktop.close()
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"scope": "Packaged Micro process and native bridge; isolated App Server and Unix IPC peers. No live Codex UI.", "cases": cases}, ensure_ascii=False, indent=2)+"\n")
    print(f"PASS {len(cases)} process scenarios: {report}")


if __name__ == "__main__":
    if "--fixture-cli" in sys.argv:
        fixture_cli()
    else:
        parser = argparse.ArgumentParser()
        parser.add_argument("--app", type=Path, required=True, help="Packaged Contents/MacOS/CodexMicroMac executable")
        parser.add_argument("--report", type=Path, required=True)
        args = parser.parse_args(); run(args.app.resolve(), args.report.resolve())
