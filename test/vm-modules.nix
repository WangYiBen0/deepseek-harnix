# NixOS VM test: the modules must behave the way they claim at *runtime*, not
# just evaluate.
#
# The interesting part is the end-to-end run: a real `dsh` inside the VM talks
# to a deliberately dumb OpenAI-compatible endpoint that only ever asks for one
# `bash` tool call — `echo hello`. Everything else is the real harness, so the
# test exercises exactly the path a user's first turn takes: provider
# configuration, the tool surface, tool execution, and the follow-up turn.
#
# It also covers the two things a pure eval check cannot see:
#
#   * a `$HOME`-relative harness home expands to the user's real home, not to a
#     literal `$HOME` directory beside it (a quoting bug did that once: the
#     path went through `escapeShellArg`, which wraps it in single quotes, and
#     `mkdir -p '$HOME/.dsh'` created a directory named `$HOME`),
#   * a seeded patch layer is written on the first activation and left alone
#     afterwards, because dsh's web UI rewrites that file at runtime.
{
  lib,
  pkgs,
  module,
  harness,
}:
let
  # The fake model endpoint. It answers the first request with a streamed
  # `tool_calls` delta naming `bash`, and any request that already carries a
  # tool result with plain text, so the run terminates.
  fakeLlm = pkgs.writeScript "fake-llm" ''
    #!${pkgs.python3}/bin/python3
    import json, sys
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    TOOL_ARGS = json.dumps({"command": "echo hello", "description": "Print hello"})

    def sse(payload):
        return f"data: {json.dumps(payload)}\n\n".encode()

    def chunk(delta, finish):
        return {
            "id": "chatcmpl-fake", "object": "chat.completion.chunk",
            "created": 0, "model": "fake-model",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, fmt, *args):
            sys.stderr.write("fake-llm: " + (fmt % args) + "\n")
            sys.stderr.flush()
        def do_POST(self):
            length = int(self.headers.get("content-length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw)
            except Exception:
                body = {}
            # A request carrying a tool result is the follow-up turn: stop.
            follow_up = any(m.get("role") == "tool" for m in body.get("messages") or [])
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("cache-control", "no-cache")
            self.send_header("connection", "close")
            self.end_headers()
            if follow_up:
                self.wfile.write(sse(chunk({"role": "assistant", "content": "DONE"}, None)))
                self.wfile.write(sse(chunk({}, "stop")))
            else:
                self.wfile.write(sse(chunk({"role": "assistant", "tool_calls": [{
                    "index": 0, "id": "call_hello_1", "type": "function",
                    "function": {"name": "bash", "arguments": ""},
                }]}, None)))
                self.wfile.write(sse(chunk({"tool_calls": [{
                    "index": 0, "function": {"arguments": TOOL_ARGS},
                }]}, None)))
                self.wfile.write(sse(chunk({}, "tool_calls")))
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()

    ThreadingHTTPServer(("127.0.0.1", 8099), Handler).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "dsh-modules";

  nodes.machine =
    { ... }:
    {
      users.users.alice = {
        isNormalUser = true;
        linger = true;
      };

      imports = [ module ];

      programs.dsh = {
        enable = true;
        package = harness;
        users = [ "alice" ];
        profiles.headless = {
          includeBase = true;
          bundles = [ "@deepseek-ai/dsh-headless" ];
          plugins = [ ];
          disabledPlugins = [ ];
          # Seeded, not declared: dsh's own UI rewrites this file at runtime,
          # so the module must write it once and then leave it alone. The fake
          # route is the seed content, which also gives the test something to
          # check survives a rebuild.
          seedPatches = [
            # The base layer ships its own DeepSeek route and points
            # `agent-default-model` at it; the test has no real key, so that
            # route is disabled rather than left to fail on the first request.
            {
              id = "llm-deepseek";
              disabled = true;
            }
            {
              id = "agent-default-model";
              name = "@deepseek-ai/dsh-agent-default-model";
              config = {
                provider = "fake";
                model = "fake-model";
              };
            }
            {
              id = "llm-pi-ai";
              name = "@deepseek-ai/dsh-llm-pi-ai";
              config.providers.fake = {
                displayName = "Fake";
                api = "openai-completions";
                baseURL = "http://127.0.0.1:8099/v1";
                apiKeyEnv = "FAKE_API_KEY";
                models = [
                  {
                    id = "fake-model";
                    name = "Fake Model";
                    contextWindow = 32768;
                    maxTokens = 4096;
                    input = [ "text" ];
                  }
                ];
              };
            }
          ];
        };
      };

      systemd.services.fake-llm = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${fakeLlm}";
          Restart = "on-failure";
        };
      };
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("fake-llm.service")
    machine.wait_for_open_port(8099)

    # ── files land in the user's real home ──────────────────────────────────
    # A `$HOME`-style literal must never appear as a directory name.
    machine.succeed("test ! -e '/home/alice/$HOME'")
    machine.succeed("test -d /home/alice/.dsh/profiles/headless")
    machine.succeed("test -f /home/alice/.dsh/profiles/headless/.dsh-managed")
    machine.succeed("grep -q fake-model /home/alice/.dsh/profiles/headless/cordis.patch.yml")

    # ── a seeded patch layer is not rewritten by a rebuild ──────────────────
    machine.succeed(
        "echo '[{\"id\":\"edited-by-dsh\"}]' > /home/alice/.dsh/profiles/headless/cordis.patch.yml"
    )
    # Re-running system activation is what `nixos-rebuild switch` does; the
    # path is the running system's own, so no interpolation is involved.
    machine.succeed("/run/current-system/activate")
    machine.succeed("grep -q edited-by-dsh /home/alice/.dsh/profiles/headless/cordis.patch.yml")

    # ── the real harness calls the fake model, which asks for bash ──────────
    # `--json` emits one run event per line, so the assertions read the actual
    # tool call and its result instead of a human-formatted summary.
    #
    # The seed is re-applied first: the previous step deliberately overwrote
    # cordis.patch.yml to prove a rebuild leaves it alone, and this run needs
    # the fake route back. Writing the profile fresh is what a user does by
    # deleting a profile, so it is the supported path, not a test hack.
    machine.succeed("rm -rf /home/alice/.dsh/profiles/headless")
    machine.succeed("/run/current-system/activate")
    machine.succeed(
        "grep -q fake-model /home/alice/.dsh/profiles/headless/cordis.patch.yml"
    )

    # The redirect is inside the quoted command so the file is written by
    # alice, not by the root shell that launches `su` (which would leave her
    # no write permission on it).
    machine.succeed(
        "su - alice -c \""
        "  export FAKE_API_KEY=sk-fake; "
        "  ${harness}/bin/dsh --profile headless --json 'say hello' "
        "  > /home/alice/run.jsonl 2>/home/alice/run.err"
        "\""
    )
    machine.succeed("grep -q '\"tool\":\"bash\"' /home/alice/run.jsonl")
    machine.succeed("grep -q '\"command\":\"echo hello\"' /home/alice/run.jsonl")
    machine.succeed("grep -q '\"result\":\"hello' /home/alice/run.jsonl")
    machine.succeed("grep -q '\"final\"' /home/alice/run.jsonl")
  '';
}
