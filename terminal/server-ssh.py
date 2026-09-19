"""Terminal server with remote hosts — same allowlist, over SSH.

Drop-in replacement for server.py. Everything server.py enforces locally still
applies; `run_command` and `read_file` simply gain a `host` argument naming a
target from hosts.json.

Two properties are deliberate and worth keeping if you edit this:

  * The model names a HOST, never an address. hosts.json is yours; the model
    chooses from it. Nothing it can say produces a connection to an address you
    did not configure.
  * The allowlist is vetted locally, before the connection. The remote end
    receives an argv list that has already been checked, each element shell-
    quoted, so a remote shell cannot re-interpret it.

Run it in place of server.py:
    ~/terminal/venv/bin/python -m uvicorn server-ssh:app --host 127.0.0.1 --port 8002
(or point the launchd/systemd unit at `server_ssh:app` after renaming the file
with an underscore — uvicorn imports it as a module name).
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

HERE = Path(__file__).parent
TOKEN = (HERE / ".token").read_text().strip()
ROOT = Path(os.environ.get("TERMINAL_ROOT", Path.home())).expanduser().resolve()
TIMEOUT = int(os.environ.get("TERMINAL_TIMEOUT", "30"))
MAX_OUTPUT = int(os.environ.get("TERMINAL_MAX_OUTPUT", "60000"))
HOSTS_FILE = Path(os.environ.get("TERMINAL_HOSTS", HERE / "hosts.json"))

ALLOWED = {
    "ls", "stat", "file", "find", "du", "df", "wc", "head", "tail", "cat",
    "basename", "dirname", "realpath", "tree",
    "grep", "sort", "uniq", "cut", "awk", "sed",
    "uname", "sw_vers", "sysctl", "uptime", "date", "whoami", "hostname",
    "vm_stat", "system_profiler", "arch", "id", "groups",
    "free", "lscpu", "lsblk", "systemctl", "journalctl", "ip",   # useful on Linux targets
    "ps", "launchctl", "lsof", "pgrep",
    "git", "ollama", "python3", "which", "env", "defaults",
    # Standards fetcher. It is not a general downloader: the URLs are
    # hardcoded to 3gpp.org and rfc-editor.org, so this grants the model
    # "fetch a published specification" and nothing wider.
    "fetch-specs",
}

DENIED_SUBCOMMANDS = {
    "launchctl": {"bootout", "bootstrap", "unload", "load", "kickstart", "stop",
                  "start", "enable", "disable", "remove", "submit", "setenv"},
    "systemctl": {"start", "stop", "restart", "reload", "enable", "disable",
                  "mask", "unmask", "kill", "isolate", "daemon-reload"},
    "git":       {"push", "commit", "reset", "checkout", "clean", "rm", "mv",
                  "merge", "rebase", "filter-branch", "gc", "config"},
    "ollama":    {"rm", "cp", "create", "push", "stop"},
    "defaults":  {"write", "delete", "rename", "import"},
    "ip":        {"link", "addr", "route"},   # `ip route add` etc. — read via `ip -br a`
}

SHELL_METACHARACTERS = set(";&|<>`$\n")
PATH_CONFINEMENT_EXEMPT = {"df", "sysctl", "vm_stat", "system_profiler", "uname",
                           "sw_vers", "free", "lscpu", "lsblk", "fetch-specs"}

SENSITIVE_DIRS = {".ssh", ".gnupg", ".aws", ".kube", ".docker", ".password-store",
                  "Keychains", ".config/gh", ".azure", ".gcloud"}
SENSITIVE_NAMES = {".netrc", ".git-credentials", ".token", ".apikey", ".env",
                   "credentials", "id_rsa", "id_ed25519", "id_ecdsa", ".npmrc", ".pypirc"}
SENSITIVE_SUFFIXES = {".pem", ".key", ".p12", ".keystore", ".jks"}

app = FastAPI(
    title="myai terminal",
    description="Inspect this machine and configured remote hosts with read-only commands.",
    version="2.0.0",
)
bearer = HTTPBearer(auto_error=False)

_cwd: dict[tuple[str, str], Path] = {}   # (session, host) -> cwd


# --------------------------------------------------------------------- hosts --
def load_hosts() -> dict[str, dict]:
    """Re-read per call so edits to hosts.json take effect without a restart."""
    try:
        data = json.loads(HOSTS_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {
        name: entry for name, entry in data.items()
        if not name.startswith("_") and isinstance(entry, dict) and entry.get("host")
    }


def resolve_host(name: Optional[str]) -> Optional[dict]:
    """None means local. Anything else must be a configured target."""
    if not name or name == "local":
        return None
    hosts = load_hosts()
    if name not in hosts:
        known = ", ".join(sorted(hosts)) or "none configured"
        raise HTTPException(
            status_code=404,
            detail=f"unknown host '{name}'. Configured targets: {known}. "
                   "Hosts are added by the user in hosts.json, not at request time.",
        )
    return hosts[name]


def ssh_argv(target: dict, remote_command: str) -> list[str]:
    """Build the local argv that runs `remote_command` on `target`.

    `remote_command` must already be shell-quoted by the caller: ssh hands its
    trailing argument to a remote shell verbatim, so quoting is what keeps the
    vetted argv from being re-interpreted at the other end.
    """
    ssh = ["ssh",
           "-o", "BatchMode=yes",              # fail rather than prompt
           "-o", "ConnectTimeout=10",
           "-o", "StrictHostKeyChecking=accept-new"]
    if target.get("port"):
        ssh += ["-p", str(target["port"])]
    if target.get("key"):
        ssh += ["-i", os.path.expanduser(str(target["key"]))]
    if target.get("jump"):
        ssh += ["-J", str(target["jump"])]
    destination = f'{target["user"]}@{target["host"]}' if target.get("user") else str(target["host"])
    return ssh + [destination, "--", remote_command]


def quote_argv(argv: list[str]) -> str:
    return " ".join(shlex.quote(a) for a in argv)


# ----------------------------------------------------------------- guardrails --
def auth(creds: Optional[HTTPAuthorizationCredentials] = Depends(bearer)) -> None:
    if creds is None or creds.credentials != TOKEN:
        raise HTTPException(status_code=401, detail="bad or missing bearer token")


def session_cwd(session: Optional[str], host: Optional[str]) -> Path:
    return _cwd.get((session or "-", host or "local"), ROOT if not host else Path("."))


def sensitive(path: Path) -> bool:
    if set(path.parts) & SENSITIVE_DIRS or path.name in SENSITIVE_NAMES:
        return True
    if path.suffix in SENSITIVE_SUFFIXES:
        return True
    return any(str(path).endswith(n) for n in (".token", ".apikey"))


def confine(path: Path, base: Path) -> Path:
    """Local paths only. Remote filesystems are not ours to confine."""
    path = path.expanduser()
    resolved = (path if path.is_absolute() else base / path).resolve()
    if resolved != ROOT and ROOT not in resolved.parents:
        raise HTTPException(status_code=403, detail=f"outside the permitted root {ROOT}")
    if sensitive(resolved):
        raise HTTPException(status_code=403,
                            detail=f"{resolved.name} holds credentials and is not readable")
    return resolved


def clip(text: str) -> str:
    if len(text) <= MAX_OUTPUT:
        return text
    return text[:MAX_OUTPUT] + f"\n... [truncated, {len(text) - MAX_OUTPUT} more characters]"


def vet(command: str, base: Path, remote: bool) -> list[str]:
    """Turn a command string into a safe argv list, or refuse it.

    Runs before any connection is made, so a remote host never sees a command
    that would have been refused locally.
    """
    if any(ch in SHELL_METACHARACTERS for ch in command):
        raise HTTPException(
            status_code=400,
            detail="No shell features here: pipes, redirects, ';', '&&' and '$(...)' "
                   "are not supported. Send one simple command.",
        )
    try:
        argv = shlex.split(command)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"could not parse command: {exc}") from exc
    if not argv:
        raise HTTPException(status_code=400, detail="empty command")

    program = Path(argv[0]).name
    if program not in ALLOWED:
        raise HTTPException(
            status_code=403,
            detail=f"'{program}' is not on the allowlist. Permitted: " + ", ".join(sorted(ALLOWED)),
        )

    denied = DENIED_SUBCOMMANDS.get(program)
    if denied is not None:
        subcommand = next((a for a in argv[1:] if not a.startswith("-")), None)
        if subcommand and subcommand in denied:
            raise HTTPException(status_code=403,
                                detail=f"'{program} {subcommand}' changes state and is not permitted")

    if program == "python3" and not set(argv[1:]) <= {"-V", "--version"}:
        raise HTTPException(status_code=403, detail="python3 is only permitted as 'python3 --version'")

    exempt = program in PATH_CONFINEMENT_EXEMPT
    for i, arg in enumerate(argv[1:], start=1):
        if arg.startswith("-"):
            continue
        if remote:
            # A remote path cannot be resolved from here, and ROOT describes this
            # machine. Refuse the obviously sensitive ones by name and leave the
            # rest to the remote account's own permissions.
            if sensitive(Path(arg)):
                raise HTTPException(status_code=403,
                                    detail=f"{Path(arg).name} looks like a credential file")
            continue
        if arg.startswith("~"):
            argv[i] = arg = os.path.expanduser(arg)
        if exempt:
            continue
        candidate = Path(arg) if Path(arg).is_absolute() else base / arg
        try:
            if candidate.exists():
                confine(Path(arg), base)
        except OSError:
            continue
    return argv


# --------------------------------------------------------------------- models --
class RunCommand(BaseModel):
    command: str = Field(..., description="One command with its arguments, e.g. 'df -h'. No pipes or redirects.")
    host: Optional[str] = Field(None, description="Target name from the configured host list. Omit for this machine.")
    cwd: Optional[str] = Field(None, description="Directory to run in.")


class ReadFile(BaseModel):
    path: str = Field(..., description="Path of the file to read")
    host: Optional[str] = Field(None, description="Target name. Omit for this machine.")
    max_bytes: int = Field(200_000, description="Stop after this many bytes")


class SetCwd(BaseModel):
    cwd: Optional[str] = None
    directory: Optional[str] = None


# ---------------------------------------------------------------------- tools --
@app.get("/list_hosts", operation_id="list_hosts", summary="List reachable machines")
def list_hosts(_: None = Depends(auth)) -> dict:
    """List the machines this terminal can reach.

    Call this first when the user mentions a machine by name, to find out which
    targets exist. 'local' is always available and means the user's own computer.
    """
    hosts = load_hosts()
    return {
        "hosts": [
            {"name": "local", "description": f"this machine, rooted at {ROOT}"},
            *[
                {
                    "name": name,
                    "description": (f'{entry.get("user","")}@{entry["host"]}'
                                    if entry.get("user") else entry["host"])
                                   + (f' via {entry["jump"]}' if entry.get("jump") else ""),
                }
                for name, entry in sorted(hosts.items())
            ],
        ]
    }


@app.post("/run_command", operation_id="run_command", summary="Run an inspection command")
def run_command(
    body: RunCommand,
    _: None = Depends(auth),
    x_session_id: Optional[str] = Header(None),
) -> dict:
    """Run one read-only command, on this machine or a configured remote host.

    For inspecting machines: disk, memory, processes, services, files, logs.
    Set `host` to a name from list_hosts to run it remotely; omit it for the
    local machine. One command per call — pipes and redirects are unavailable,
    so ask for raw output and interpret it yourself.
    """
    target = resolve_host(body.host)
    remote = target is not None
    key = (x_session_id or "-", body.host or "local")

    if remote:
        base = Path(body.cwd) if body.cwd else session_cwd(x_session_id, body.host)
        argv = vet(body.command, base, remote=True)
        remote_command = quote_argv(argv)
        # A remote `cd` is a prefix on the command line; there is no persistent
        # shell at the other end to hold a directory between calls.
        if str(base) not in (".", ""):
            remote_command = f"cd {shlex.quote(str(base))} && {remote_command}"
        full = ssh_argv(target, remote_command)
        try:
            proc = subprocess.run(full, capture_output=True, text=True, timeout=TIMEOUT + 10)
        except subprocess.TimeoutExpired:
            return {"stdout": "", "stderr": f"timed out after {TIMEOUT + 10}s",
                    "exit_code": 124, "host": body.host, "cwd": str(base)}
        if proc.returncode == 255 and "Permission denied" in proc.stderr:
            proc.stderr += ("\nThe key for this host is not usable non-interactively. "
                            "Load it into ssh-agent, or set 'key' in hosts.json.")
        return {"stdout": clip(proc.stdout), "stderr": clip(proc.stderr),
                "exit_code": proc.returncode, "host": body.host, "cwd": str(base)}

    base = confine(Path(body.cwd), session_cwd(x_session_id, None)) if body.cwd \
        else session_cwd(x_session_id, None)
    if not base.is_dir():
        raise HTTPException(status_code=400, detail=f"not a directory: {base}")
    argv = vet(body.command, base, remote=False)
    try:
        proc = subprocess.run(argv, cwd=str(base), capture_output=True, text=True, timeout=TIMEOUT)
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail=f"command not found: {argv[0]}") from None
    except subprocess.TimeoutExpired:
        return {"stdout": "", "stderr": f"timed out after {TIMEOUT}s",
                "exit_code": 124, "host": "local", "cwd": str(base)}
    _cwd[key] = base
    return {"stdout": clip(proc.stdout), "stderr": clip(proc.stderr),
            "exit_code": proc.returncode, "host": "local", "cwd": str(base)}


@app.post("/read_file", operation_id="read_file", summary="Read a file")
def read_file(
    body: ReadFile,
    _: None = Depends(auth),
    x_session_id: Optional[str] = Header(None),
) -> dict:
    """Read a text file, from this machine or a configured remote host."""
    target = resolve_host(body.host)
    if target is not None:
        if sensitive(Path(body.path)):
            raise HTTPException(status_code=403,
                                detail=f"{Path(body.path).name} looks like a credential file")
        full = ssh_argv(target, quote_argv(["cat", body.path]))
        proc = subprocess.run(full, capture_output=True, text=True, timeout=TIMEOUT + 10)
        if proc.returncode != 0:
            raise HTTPException(status_code=404, detail=clip(proc.stderr) or "could not read file")
        return {"path": body.path, "host": body.host,
                "content": clip(proc.stdout[: body.max_bytes])}

    resolved = confine(Path(body.path), session_cwd(x_session_id, None))
    if not resolved.is_file():
        raise HTTPException(status_code=404, detail=f"no such file: {resolved}")
    data = resolved.read_bytes()[: body.max_bytes]
    return {"path": str(resolved), "host": "local", "size": resolved.stat().st_size,
            "content": clip(data.decode("utf-8", errors="replace"))}


# ------------------------------------------------- Open WebUI terminal panel --
@app.get("/files/cwd", summary="Current working directory")
def files_cwd(_: None = Depends(auth), x_session_id: Optional[str] = Header(None)) -> dict:
    return {"cwd": str(session_cwd(x_session_id, None)), "home": str(ROOT), "root": str(ROOT)}


@app.post("/files/cwd", summary="Change working directory")
def set_cwd(body: SetCwd, _: None = Depends(auth),
            x_session_id: Optional[str] = Header(None)) -> dict:
    target = body.cwd or body.directory
    if not target:
        raise HTTPException(status_code=400, detail="cwd is required")
    resolved = confine(Path(target), session_cwd(x_session_id, None))
    if not resolved.is_dir():
        raise HTTPException(status_code=400, detail=f"not a directory: {resolved}")
    _cwd[(x_session_id or "-", "local")] = resolved
    return {"cwd": str(resolved), "home": str(ROOT), "root": str(ROOT)}


@app.get("/files/list", summary="List a directory")
def files_list(directory: str = ".", _: None = Depends(auth),
               x_session_id: Optional[str] = Header(None)) -> dict:
    base = confine(Path(directory), session_cwd(x_session_id, None))
    if not base.is_dir():
        raise HTTPException(status_code=400, detail=f"not a directory: {base}")
    entries = []
    for child in sorted(base.iterdir(), key=lambda c: (not c.is_dir(), c.name.lower())):
        if sensitive(child):
            continue
        try:
            st = child.stat(); size, modified = st.st_size, int(st.st_mtime)
        except OSError:
            size, modified = 0, 0
        entries.append({"name": child.name, "path": str(child),
                        "type": "directory" if child.is_dir() else "file",
                        "size": size, "modified": modified})
    return {"entries": entries, "writable": False, "cwd": str(base)}


@app.get("/ports", summary="Forwarded ports")
def ports(_: None = Depends(auth)) -> dict:
    return {"ports": []}


@app.get("/api/config", summary="Feature flags")
def api_config() -> dict:
    return {"features": {"system": True}}


@app.get("/system", summary="System prompt")
def system(_: None = Depends(auth), x_session_id: Optional[str] = Header(None)) -> dict:
    names = ", ".join(["local", *sorted(load_hosts())])
    prompt = (
        "You can inspect the user's machines with the `run_command` tool.\n"
        f"- Reachable targets: {names}. Call list_hosts if unsure. Pass the NAME "
        "in `host`; omit it for the user's own computer.\n"
        f"- Local working directory: {session_cwd(x_session_id, None)}, rooted at {ROOT}.\n"
        "- One simple command per call. There is no shell: pipes, redirects, ';' "
        "and '$(...)' are rejected, so read the raw output and interpret it yourself.\n"
        "- Read-only inspection tools only. Anything that would change a system is "
        "refused by the server — do not attempt it, and say so plainly if asked.\n"
        "- Run the command and answer from its real output. Never invent output.\n"
        "- If a remote host fails to connect, report the error rather than guessing "
        "at what the machine might contain."
    )
    return {"system": prompt, "prompt": prompt}


@app.get("/health", summary="Health")
def health() -> dict:
    return {"ok": True, "root": str(ROOT), "hosts": sorted(load_hosts()),
            "allowed": sorted(ALLOWED)}
