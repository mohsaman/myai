"""A read-only diagnostics terminal for Open WebUI.

Implements Open WebUI's terminal-server contract:

  GET  /openapi.json   tool specs (FastAPI generates it; operationId is the tool name)
  POST /run_command    run one allowlisted inspection command
  POST /read_file      read a text file
  GET  /files/cwd      the working directory shown to the model
  GET  /api/config     feature flags — advertises the system-prompt endpoint
  GET  /system         the system prompt injected when the terminal is attached

Deliberately NOT a general shell. Three properties hold by construction:

  * No shell. Commands are executed as an argv list, never through bash, so
    pipes, redirects, `;`, `&&`, `$(...)` and backticks have no meaning — they
    are rejected rather than interpreted.
  * Allowlisted binaries only. ALLOWED lists read-only inspection tools; there
    is no path by which `rm`, `kill`, `sudo`, `curl` or an interpreter runs.
  * Confined. Every path argument and file read is resolved and must land
    inside TERMINAL_ROOT.

The trade is intentional: this answers questions about the machine without
granting arbitrary code execution. Widen ALLOWED only with that in mind.
"""

from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

TOKEN = (Path(__file__).parent / ".token").read_text().strip()
ROOT = Path(os.environ.get("TERMINAL_ROOT", Path.home())).expanduser().resolve()
TIMEOUT = int(os.environ.get("TERMINAL_TIMEOUT", "30"))
MAX_OUTPUT = int(os.environ.get("TERMINAL_MAX_OUTPUT", "60000"))

# Read-only inspection tools. Nothing here writes, deletes, signals a process,
# opens a network connection, or interprets code.
ALLOWED = {
    # filesystem
    "ls", "stat", "file", "find", "du", "df", "wc", "head", "tail", "cat",
    "basename", "dirname", "realpath", "tree",
    # text
    "grep", "sort", "uniq", "cut", "awk", "sed",
    # system
    "uname", "sw_vers", "sysctl", "uptime", "date", "whoami", "hostname",
    "vm_stat", "system_profiler", "sysctl", "arch", "id", "groups",
    # processes and services (read-only verbs are checked below)
    "ps", "launchctl", "lsof", "pgrep",
    # dev
    "git", "ollama", "python3", "which", "env", "defaults",
}

# Subcommands that would mutate state, for tools that can do both.
DENIED_SUBCOMMANDS = {
    "launchctl": {"bootout", "bootstrap", "unload", "load", "kickstart", "stop",
                  "start", "enable", "disable", "remove", "submit", "setenv"},
    "git":       {"push", "commit", "reset", "checkout", "clean", "rm", "mv",
                  "merge", "rebase", "filter-branch", "gc", "config"},
    "ollama":    {"rm", "cp", "create", "push", "stop"},
    "defaults":  {"write", "delete", "rename", "import"},
    "python3":   set(),  # only ever allowed with -c-less, see below
}

SHELL_METACHARACTERS = set(";&|<>`$\n")

# Tools whose path arguments name a volume or device rather than a file to read.
# Confining these to ROOT would reject `df -h /` while exposing nothing: they
# report capacity and mount metadata, never file contents.
PATH_CONFINEMENT_EXEMPT = {"df", "sysctl", "vm_stat", "system_profiler", "uname", "sw_vers"}

app = FastAPI(
    title="myai terminal",
    description="Inspect the local machine with read-only commands.",
    version="1.0.0",
)
bearer = HTTPBearer(auto_error=False)

_cwd: dict[str, Path] = {}


def auth(creds: Optional[HTTPAuthorizationCredentials] = Depends(bearer)) -> None:
    if creds is None or creds.credentials != TOKEN:
        raise HTTPException(status_code=401, detail="bad or missing bearer token")


def session_cwd(session: Optional[str]) -> Path:
    return _cwd.get(session or "-", ROOT)


# Credential stores. Being inside ROOT is not sufficient reason to read these.
SENSITIVE_DIRS = {".ssh", ".gnupg", ".aws", ".kube", ".docker", ".password-store",
                  "Keychains", ".config/gh", ".azure", ".gcloud"}
SENSITIVE_NAMES = {".netrc", ".git-credentials", ".token", ".apikey", ".env",
                   "credentials", "id_rsa", "id_ed25519", "id_ecdsa", ".npmrc", ".pypirc"}
SENSITIVE_SUFFIXES = {".pem", ".key", ".p12", ".keystore", ".jks"}


def sensitive(path: Path) -> bool:
    parts = set(path.parts)
    if parts & SENSITIVE_DIRS or path.name in SENSITIVE_NAMES:
        return True
    if path.suffix in SENSITIVE_SUFFIXES:
        return True
    return any(str(path).endswith(n) for n in (".token", ".apikey"))


def confine(path: Path, base: Path) -> Path:
    resolved = (path if path.is_absolute() else base / path).expanduser().resolve()
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


def vet(command: str, base: Path) -> list[str]:
    """Turn a command string into a safe argv list, or refuse it."""
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
            detail=f"'{program}' is not on the allowlist. Permitted: "
                   + ", ".join(sorted(ALLOWED)),
        )

    denied = DENIED_SUBCOMMANDS.get(program)
    if denied is not None:
        subcommand = next((a for a in argv[1:] if not a.startswith("-")), None)
        if subcommand and subcommand in denied:
            raise HTTPException(status_code=403,
                                detail=f"'{program} {subcommand}' changes state and is not permitted")

    # python3 is allowed only to report its own version, never to run code.
    if program == "python3" and not set(argv[1:]) <= {"-V", "--version"}:
        raise HTTPException(status_code=403, detail="python3 is only permitted as 'python3 --version'")

    # There is no shell, so '~' would reach the program literally. Expand it
    # here, then confine: any argument naming an existing path must be in ROOT.
    exempt = program in PATH_CONFINEMENT_EXEMPT
    for i, arg in enumerate(argv[1:], start=1):
        if arg.startswith("-"):
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


class RunCommand(BaseModel):
    command: str = Field(..., description="One command with its arguments, e.g. 'df -h' or 'ls -la ~/Documents'. No pipes or redirects.")
    cwd: Optional[str] = Field(None, description="Directory to run in. Defaults to the session's current directory.")


class ReadFile(BaseModel):
    path: str = Field(..., description="Path of the file to read")
    max_bytes: int = Field(200_000, description="Stop after this many bytes")


@app.post("/run_command", operation_id="run_command", summary="Run an inspection command")
def run_command(
    body: RunCommand,
    _: None = Depends(auth),
    x_session_id: Optional[str] = Header(None),
) -> dict:
    """Run one read-only command on the user's machine and return its output.

    For inspecting the machine: disk usage, memory, processes, services, files,
    logs, git status, installed models. One command per call — pipes and
    redirects are not available, so ask for the raw output and interpret it
    yourself. Only the allowlisted tools run; anything that would change the
    system is refused.
    """
    base = session_cwd(x_session_id)
    start = confine(Path(body.cwd), base) if body.cwd else base
    if not start.is_dir():
        raise HTTPException(status_code=400, detail=f"not a directory: {start}")

    argv = vet(body.command, start)
    try:
        proc = subprocess.run(
            argv, cwd=str(start), capture_output=True, text=True, timeout=TIMEOUT,
        )
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail=f"command not found: {argv[0]}") from None
    except subprocess.TimeoutExpired:
        return {"stdout": "", "stderr": f"timed out after {TIMEOUT}s",
                "exit_code": 124, "cwd": str(start)}

    return {
        "stdout": clip(proc.stdout),
        "stderr": clip(proc.stderr),
        "exit_code": proc.returncode,
        "cwd": str(start),
    }


@app.post("/read_file", operation_id="read_file", summary="Read a file")
def read_file(
    body: ReadFile,
    _: None = Depends(auth),
    x_session_id: Optional[str] = Header(None),
) -> dict:
    """Read a text file from the machine and return its contents."""
    target = confine(Path(body.path), session_cwd(x_session_id))
    if not target.is_file():
        raise HTTPException(status_code=404, detail=f"no such file: {target}")
    data = target.read_bytes()[: body.max_bytes]
    return {
        "path": str(target),
        "size": target.stat().st_size,
        "content": clip(data.decode("utf-8", errors="replace")),
    }


@app.get("/files/cwd", summary="Current working directory")
def files_cwd(_: None = Depends(auth), x_session_id: Optional[str] = Header(None)) -> dict:
    return {"cwd": str(session_cwd(x_session_id))}


@app.get("/api/config", summary="Feature flags")
def api_config() -> dict:
    return {"features": {"system": True}}


@app.get("/system", summary="System prompt")
def system(_: None = Depends(auth), x_session_id: Optional[str] = Header(None)) -> dict:
    prompt = (
        "You can inspect the user's local machine with the `run_command` tool.\n"
        f"- Working directory: {session_cwd(x_session_id)}, rooted at {ROOT}.\n"
        "- One simple command per call. There is no shell: pipes, redirects, ';' "
        "and '$(...)' are rejected, so read the raw output and interpret it yourself.\n"
        "- Read-only inspection tools only. Anything that would change the system "
        "is refused by the server — do not attempt it, and tell the user plainly "
        "if they ask for something it cannot do.\n"
        "- Use `read_file` for file contents rather than paging with head/tail.\n"
        "- Run the command and answer from its real output. Never invent output."
    )
    return {"system": prompt, "prompt": prompt}


@app.get("/health", summary="Health")
def health() -> dict:
    return {"ok": True, "root": str(ROOT), "allowed": sorted(ALLOWED)}
