#!/usr/bin/env python3
"""
serena_extract.py - Direct LSP extraction via clangd

Spawns a clangd process, talks LSP JSON-RPC over stdio, and extracts
symbol overviews + cross-file references for each source file.
Produces .serena_context.txt files consumed by archgen Pass 1.

Zero Claude API calls. Zero tokens. Just local clangd queries.

Usage:
    python serena_extract.py --repo-root C:/Coding/Epic_Games/UnrealEngine
    python serena_extract.py --repo-root . --target-dir Engine/Source/Runtime/Core
    python serena_extract.py --repo-root . --file-list files.txt
"""

import argparse
import atexit
import csv
import ctypes
import glob as globmod
import hashlib
import io
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# PCH cleanup - clangd --pch-storage=disk leaves preamble-*.pch in temp
# ---------------------------------------------------------------------------

# Track all PCH files that exist before we start, so we only clean up ours
_pch_baseline = set()
_pch_lock = threading.Lock()


def _get_pch_dir():
    """Return the directory where clangd writes preamble PCH files."""
    return tempfile.gettempdir()


def _snapshot_pch_baseline():
    """Record existing PCH files so we don't delete someone else's."""
    global _pch_baseline
    pattern = os.path.join(_get_pch_dir(), "preamble-*.pch")
    _pch_baseline = set(globmod.glob(pattern))


def cleanup_pch_files():
    """Remove preamble-*.pch files created during this session."""
    pattern = os.path.join(_get_pch_dir(), "preamble-*.pch")
    removed = 0
    total_bytes = 0
    for f in globmod.glob(pattern):
        if f in _pch_baseline:
            continue  # existed before we started
        try:
            sz = os.path.getsize(f)
            os.remove(f)
            removed += 1
            total_bytes += sz
        except OSError:
            pass
    if removed:
        gb = total_bytes / (1024 ** 3)
        print(f"\n  PCH cleanup: removed {removed} file(s), freed {gb:.1f} GB")


# ---------------------------------------------------------------------------
# LSP JSON-RPC client (synchronous, single clangd process)
# ---------------------------------------------------------------------------

LSP_SYMBOL_KINDS = {
    1: "File", 2: "Module", 3: "Namespace", 4: "Package", 5: "Class",
    6: "Method", 7: "Property", 8: "Field", 9: "Constructor", 10: "Enum",
    11: "Interface", 12: "Function", 13: "Variable", 14: "Constant",
    15: "String", 16: "Number", 17: "Boolean", 18: "Array", 19: "Object",
    20: "Key", 21: "Null", 22: "EnumMember", 23: "Struct", 24: "Event",
    25: "Operator", 26: "TypeParameter",
}

# Symbol kinds worth querying references for
REFERENCE_WORTHY_KINDS = {5, 6, 9, 10, 11, 12, 23}  # Class, Method, Constructor, Enum, Interface, Function, Struct

# Cap references per symbol to avoid blowup on popular symbols
MAX_REFS_PER_SYMBOL = 20
REF_TIMEOUT_SECONDS = 10


class ClangdClient:
    """Synchronous LSP client talking to clangd over stdio."""

    def __init__(self, clangd_path, compile_commands_dir, jobs=2):
        cmd = [
            clangd_path,
            f"--compile-commands-dir={compile_commands_dir}",
            "--background-index",
            "--pch-storage=disk",
            f"-j={jobs}",
        ]
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self._request_id = 0
        self._lock = threading.Lock()
        self._pending = {}
        self._notifications = []

        # Start reader thread
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

        # Initialize LSP
        self._initialize()

    def _read_loop(self):
        """Read LSP messages from clangd stdout using buffered I/O."""
        # Wrap stdout in a buffered reader for efficient reads
        stream = self.proc.stdout
        try:
            while True:
                # Read headers line by line until blank line
                headers = {}
                while True:
                    line = b""
                    while True:
                        ch = stream.read(1)
                        if not ch:
                            return  # EOF
                        line += ch
                        if line.endswith(b"\r\n"):
                            break
                    line = line.strip()
                    if not line:
                        break  # Empty line = end of headers
                    if b":" in line:
                        key, val = line.split(b":", 1)
                        headers[key.strip().lower()] = val.strip()

                # Get content length
                length_val = headers.get(b"content-length")
                if not length_val:
                    continue
                length = int(length_val)

                # Read body in one shot
                body = b""
                while len(body) < length:
                    chunk = stream.read(length - len(body))
                    if not chunk:
                        return
                    body += chunk

                msg = json.loads(body)
                if "id" in msg and "method" not in msg:
                    # Response to a request
                    rid = msg["id"]
                    with self._lock:
                        if rid in self._pending:
                            self._pending[rid].set_result(msg)
                # Notifications are discarded
        except Exception:
            pass

    def _send(self, method, params, is_notification=False):
        """Send a JSON-RPC message."""
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        if not is_notification:
            self._request_id += 1
            msg["id"] = self._request_id
            fut = _Future()
            with self._lock:
                self._pending[self._request_id] = fut

        body = json.dumps(msg).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        self.proc.stdin.write(header + body)
        self.proc.stdin.flush()

        if is_notification:
            return None
        return fut

    def request(self, method, params, timeout=30):
        """Send request and wait for response."""
        fut = self._send(method, params)
        return fut.wait(timeout)

    def notify(self, method, params):
        """Send notification (no response expected)."""
        self._send(method, params, is_notification=True)

    def _initialize(self):
        resp = self.request("initialize", {
            "processId": os.getpid(),
            "capabilities": {
                "textDocument": {
                    "documentSymbol": {"hierarchicalDocumentSymbolSupport": True},
                    "references": {},
                }
            },
            "rootUri": None,
        }, timeout=60)
        self.notify("initialized", {})
        return resp

    def did_open(self, file_path, content):
        uri = Path(file_path).as_uri()
        self.notify("textDocument/didOpen", {
            "textDocument": {
                "uri": uri,
                "languageId": "cpp",
                "version": 1,
                "text": content,
            }
        })
        return uri

    def did_close(self, uri):
        self.notify("textDocument/didClose", {
            "textDocument": {"uri": uri}
        })

    def document_symbol(self, uri, timeout=30):
        resp = self.request("textDocument/documentSymbol", {
            "textDocument": {"uri": uri}
        }, timeout=timeout)
        if resp and "result" in resp:
            return resp["result"] or []
        return []

    def find_references(self, uri, line, character, timeout=REF_TIMEOUT_SECONDS):
        resp = self.request("textDocument/references", {
            "textDocument": {"uri": uri},
            "position": {"line": line, "character": character},
            "context": {"includeDeclaration": False},
        }, timeout=timeout)
        if resp and "result" in resp:
            return resp["result"] or []
        return []

    def shutdown(self):
        try:
            self.request("shutdown", {}, timeout=5)
            self.notify("exit", {})
        except Exception:
            pass
        try:
            self.proc.terminate()
        except Exception:
            pass


class _Future:
    """Simple future for synchronous waiting."""
    def __init__(self):
        self._event = threading.Event()
        self._result = None

    def set_result(self, result):
        self._result = result
        self._event.set()

    def wait(self, timeout):
        if self._event.wait(timeout):
            return self._result
        return None


# ---------------------------------------------------------------------------
# Symbol extraction logic
# ---------------------------------------------------------------------------

def flatten_symbols(symbols, parent_path=""):
    """Flatten hierarchical DocumentSymbol tree into a flat list with paths."""
    result = []
    for sym in symbols:
        name = sym.get("name", "")
        kind = sym.get("kind", 0)
        kind_name = LSP_SYMBOL_KINDS.get(kind, f"Unknown({kind})")
        rng = sym.get("range", sym.get("location", {}).get("range", {}))
        start_line = rng.get("start", {}).get("line", 0)
        end_line = rng.get("end", {}).get("line", 0)
        sel_range = sym.get("selectionRange", rng)
        sel_line = sel_range.get("start", {}).get("line", start_line)
        sel_char = sel_range.get("start", {}).get("character", 0)

        path = f"{parent_path}/{name}" if parent_path else name

        result.append({
            "name": name,
            "path": path,
            "kind": kind,
            "kind_name": kind_name,
            "start_line": start_line + 1,  # 1-indexed for display
            "end_line": end_line + 1,
            "sel_line": sel_line,  # 0-indexed for LSP queries
            "sel_char": sel_char,
        })

        # Recurse into children
        children = sym.get("children", [])
        if children:
            result.extend(flatten_symbols(children, path))

    return result


def uri_to_relpath(uri, repo_root):
    """Convert file:// URI to a relative path from repo_root."""
    if uri.startswith("file:///"):
        path = uri[8:]  # Remove file:///
        # Handle Windows drive letters
        if len(path) > 2 and path[1] == ':':
            pass  # Already absolute
        elif len(path) > 2 and path[0] == '/' and path[2] == ':':
            path = path[1:]  # Remove leading /
    elif uri.startswith("file://"):
        path = uri[7:]
    else:
        return uri

    # URL decode
    from urllib.parse import unquote
    path = unquote(path)
    path = path.replace("/", os.sep)

    try:
        return os.path.relpath(path, repo_root).replace("\\", "/")
    except ValueError:
        return path.replace("\\", "/")


def generate_trimmed_source(file_path, symbols, max_lines=800):
    """Opt #3: Extract only meaningful code sections using LSP symbol ranges."""
    try:
        all_lines = Path(file_path).read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return None

    if not all_lines or not symbols:
        return None

    total = len(all_lines)
    if total <= max_lines:
        return None  # File is small enough — no trimming needed

    # Always include first 30 lines (includes, namespace declarations)
    regions = [(0, min(30, total))]

    # Add each top-level symbol's range
    for sym in symbols:
        if "/" in sym.get("path", ""):
            continue  # Skip nested symbols (methods listed under classes)
        start = max(0, sym["start_line"] - 2)  # 1-indexed → 0-indexed with buffer
        end = min(total, sym["end_line"])

        # For large symbols, take first 15 and last 5 lines
        if (end - start) > 25:
            regions.append((start, start + 15))
            regions.append((max(start + 15, end - 5), end))
        else:
            regions.append((start, end))

    # Sort and merge overlapping regions
    regions.sort()
    merged = []
    for start, end in regions:
        if merged and start <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))

    # Build output with gap markers
    output = []
    last_end = 0
    for start, end in merged:
        if start > last_end:
            output.append(f"// ... [{start - last_end} lines omitted] ...")
        output.extend(all_lines[start:end])
        last_end = end
        if len(output) >= max_lines:
            output.append(f"// ... [trimmed at {max_lines} lines, {total - last_end} remaining] ...")
            break

    if last_end < total and len(output) < max_lines:
        output.append(f"// ... [{total - last_end} lines omitted] ...")

    return "\n".join(output[:max_lines])


def extract_file(client, file_path, repo_root, skip_refs=False, compress=False, perf_log=None):
    """Extract symbol overview and references for a single file."""
    timings = {}
    t0 = time.time()

    try:
        content = Path(file_path).read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        return f"Error reading file: {e}"

    timings["read_file"] = time.time() - t0

    t1 = time.time()
    uri = client.did_open(file_path, content)

    timings["did_open"] = time.time() - t1

    try:
        # Get symbols
        t2 = time.time()
        raw_symbols = client.document_symbol(uri, timeout=30)
        timings["document_symbol"] = time.time() - t2
        symbols = flatten_symbols(raw_symbols)

        if not symbols:
            client.did_close(uri)
            return None  # No symbols = no context worth writing

        # Group symbols by kind
        classes = [s for s in symbols if s["kind"] in (5, 23, 10, 11)]  # Class, Struct, Enum, Interface
        functions = [s for s in symbols if s["kind"] in (12,) and "/" not in s["path"]]  # Top-level functions
        methods = [s for s in symbols if s["kind"] in (6, 9) and "/" in s["path"]]  # Methods, Constructors
        variables = [s for s in symbols if s["kind"] in (13, 14) and "/" not in s["path"]]  # Top-level vars

        # Build symbol overview section
        lines = []
        rel = os.path.relpath(file_path, repo_root).replace("\\", "/")
        lines.append(f"=== LSP CONTEXT FOR: {rel} ===")
        lines.append("")
        lines.append("## Symbol Overview")

        if compress:
            # Opt v3#3: Compressed symbol overview — collapse classes, show top symbols
            for s in classes:
                method_count = sum(1 for m in methods if m["path"].startswith(s["name"] + "/"))
                lines.append(f"- {s['name']} ({s['kind_name']}, {method_count} methods, lines {s['start_line']}-{s['end_line']})")
            for s in functions[:10]:
                lines.append(f"- {s['name']} (Function, lines {s['start_line']}-{s['end_line']})")
            if len(functions) > 10:
                lines.append(f"  ... and {len(functions) - 10} more functions")
            if variables:
                lines.append(f"- {len(variables)} file-scope variable(s)")
        else:
            if classes:
                lines.append("### Classes / Structs / Enums")
                for s in classes:
                    lines.append(f"- {s['name']} ({s['kind_name']}, lines {s['start_line']}-{s['end_line']})")

            if functions:
                lines.append("### Functions")
                for s in functions:
                    lines.append(f"- {s['name']} (lines {s['start_line']}-{s['end_line']})")

            if methods and len(methods) <= 50:  # Don't list 200 methods
                lines.append("### Methods")
                for s in methods[:30]:
                    lines.append(f"- {s['path']} (lines {s['start_line']}-{s['end_line']})")
                if len(methods) > 30:
                    lines.append(f"  ... and {len(methods) - 30} more methods")

        if not compress and variables:
            lines.append("### File-Scope Variables")
            for s in variables:
                lines.append(f"- {s['name']} (line {s['start_line']})")

        # Query references for top-level symbols worth tracking
        if not skip_refs:
            t3 = time.time()
            ref_worthy = [s for s in symbols
                          if s["kind"] in REFERENCE_WORTHY_KINDS
                          and "/" not in s["path"]]  # Top-level only

            incoming_refs = {}
            ref_timings = []

            for s in ref_worthy[:15]:  # Cap at 15 symbols to query
                tr = time.time()
                try:
                    refs = client.find_references(uri, s["sel_line"], s["sel_char"],
                                                  timeout=REF_TIMEOUT_SECONDS)
                except Exception:
                    refs = []
                ref_timings.append((s["name"], time.time() - tr, len(refs)))

                external_refs = []
                for ref in refs:
                    ref_uri = ref.get("uri", "")
                    if ref_uri == uri:
                        continue  # Skip self-references
                    ref_rel = uri_to_relpath(ref_uri, repo_root)
                    ref_line = ref.get("range", {}).get("start", {}).get("line", 0) + 1
                    external_refs.append(f"{ref_rel}:{ref_line}")

                if external_refs:
                    incoming_refs[s["name"]] = external_refs[:MAX_REFS_PER_SYMBOL]

            # Build incoming references section
            if incoming_refs:
                lines.append("")
                lines.append("## Incoming References (who calls/uses symbols defined here)")
                for sym_name, refs in incoming_refs.items():
                    lines.append(f"- {sym_name}:")
                    for ref in refs[:10]:
                        lines.append(f"  - {ref}")
                    if len(refs) > 10:
                        lines.append(f"  - ... and {len(refs) - 10} more references")

        if not skip_refs:
            timings["refs_total"] = time.time() - t3
            timings["refs_detail"] = ref_timings

        # For outgoing references, scan the source for #include to identify dependencies
        includes = re.findall(r'#\s*include\s+"([^"]+)"', content)
        if includes:
            lines.append("")
            lines.append("## Direct Include Dependencies")
            for inc in includes[:20]:
                lines.append(f"- {inc}")

        # Opt #3: Generate trimmed source (key sections only)
        t4 = time.time()
        trimmed = generate_trimmed_source(file_path, symbols)
        if trimmed:
            lines.append("")
            lines.append("## Trimmed Source (key sections only)")
            lines.append("```cpp")
            lines.append(trimmed)
            lines.append("```")
        timings["trimmed_source"] = time.time() - t4

        timings["total"] = time.time() - t0
        timings["symbols_count"] = len(symbols)
        timings["lines_count"] = len(content.splitlines())

        # Write perf log entry
        if perf_log:
            rel = os.path.relpath(file_path, repo_root).replace("\\", "/")
            entry = (f"{rel}\t"
                     f"total={timings['total']:.2f}\t"
                     f"open={timings.get('did_open', 0):.2f}\t"
                     f"sym={timings.get('document_symbol', 0):.2f}\t"
                     f"refs={timings.get('refs_total', 0):.2f}\t"
                     f"trim={timings.get('trimmed_source', 0):.2f}\t"
                     f"syms={timings.get('symbols_count', 0)}\t"
                     f"lines={timings.get('lines_count', 0)}")
            ref_detail = timings.get("refs_detail", [])
            if ref_detail:
                slowest = sorted(ref_detail, key=lambda x: x[1], reverse=True)[:3]
                slow_str = " | ".join(f"{n}:{t:.1f}s/{c}refs" for n, t, c in slowest)
                entry += f"\tslowest_refs=[{slow_str}]"
            entry += "\n"
            try:
                with open(perf_log, "a", encoding="utf-8") as f:
                    f.write(entry)
            except Exception:
                pass

        return "\n".join(lines)

    finally:
        client.did_close(uri)


# ---------------------------------------------------------------------------
# File collection and hashing
# ---------------------------------------------------------------------------

def sha1_file(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def load_hash_db(path):
    db = {}
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "\t" in line:
                    sha, rel = line.split("\t", 1)
                    db[rel] = sha
    return db


def save_hash_entry(path, sha, rel):
    with open(path, "a", encoding="utf-8") as f:
        f.write(f"{sha}\t{rel}\n")


def collect_files(repo_root, target_dir, include_rx, exclude_rx, file_list=None):
    """Collect source files matching the patterns."""
    if file_list:
        with open(file_list, "r") as f:
            return [line.strip() for line in f if line.strip()]

    scan_root = os.path.join(repo_root, target_dir) if target_dir != "." else repo_root
    files = []
    for dirpath, dirnames, filenames in os.walk(scan_root):
        rel_dir = os.path.relpath(dirpath, repo_root).replace("\\", "/")
        if re.search(exclude_rx, rel_dir + "/"):
            dirnames.clear()
            continue
        for fn in filenames:
            rel = os.path.join(rel_dir, fn).replace("\\", "/")
            if re.search(exclude_rx, rel):
                continue
            if re.search(include_rx, rel):
                files.append(rel)

    return sorted(files)


# ---------------------------------------------------------------------------
# System memory monitoring
# ---------------------------------------------------------------------------

def get_clangd_ram_gb():
    """Get total RAM used by all clangd processes in GB."""
    try:
        if sys.platform == "win32":
            result = subprocess.run(
                ["tasklist", "/FI", "IMAGENAME eq clangd.exe", "/FO", "CSV", "/NH"],
                capture_output=True, text=True, timeout=5
            )
            total = 0
            # Use csv module to handle commas inside quoted fields
            # Format: "clangd.exe","PID","Session","#","5,711,560 K"
            reader = csv.reader(io.StringIO(result.stdout.strip()))
            for row in reader:
                if len(row) >= 5:
                    mem_str = row[4].strip()
                    # Remove " K" suffix, commas, non-breaking spaces
                    mem_str = mem_str.replace(" K", "").replace(",", "").replace("\xa0", "").strip()
                    try:
                        total += int(mem_str) * 1024  # KB to bytes
                    except ValueError:
                        pass
            return total / (1024 ** 3)
        else:
            # Linux/macOS
            result = subprocess.run(
                ["ps", "-C", "clangd", "-o", "rss="],
                capture_output=True, text=True, timeout=5
            )
            total = sum(int(line.strip()) * 1024 for line in result.stdout.strip().splitlines() if line.strip())
            return total / (1024 ** 3)
    except Exception:
        return 0.0


def get_free_ram_gb():
    """Get free physical RAM in GB (Windows)."""
    try:
        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong),
                ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]
        stat = MEMORYSTATUSEX()
        stat.dwLength = ctypes.sizeof(stat)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat))
        return stat.ullAvailPhys / (1024 ** 3)
    except Exception:
        # Fallback for non-Windows
        try:
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemAvailable:"):
                        return int(line.split()[1]) / (1024 * 1024)
        except Exception:
            return 99.0  # Unknown, assume plenty


# ---------------------------------------------------------------------------
# Parallel extraction worker
# ---------------------------------------------------------------------------

class ExtractionWorker:
    """A worker thread with its own clangd instance."""

    def __init__(self, worker_id, clangd_path, repo_root, jobs, work_queue,
                 result_lock, output_dir, hash_db_path, skip_refs, compress,
                 perf_log, stats, error_log=None, restart_interval=1000):
        self.worker_id = worker_id
        self.clangd_path = clangd_path
        self.repo_root = repo_root
        self.jobs = jobs
        self.work_queue = work_queue
        self.result_lock = result_lock
        self.output_dir = output_dir
        self.hash_db_path = hash_db_path
        self.skip_refs = skip_refs
        self.compress = compress
        self.perf_log = perf_log
        self.stats = stats  # shared dict: done, fail, empty
        self.error_log = error_log
        self.restart_interval = restart_interval
        self.client = None
        self.thread = None
        self.stop_event = threading.Event()
        self.files_since_restart = 0

    def start(self):
        self.client = ClangdClient(self.clangd_path, self.repo_root, jobs=self.jobs)
        time.sleep(3)  # Let clangd load index
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=15)
        if self.client:
            self.client.shutdown()
            self.client = None

    def is_alive(self):
        return self.thread is not None and self.thread.is_alive()

    def _log_error(self, rel, error_type, message):
        """Append an error entry to the error log. Call with result_lock held."""
        if not self.error_log:
            return
        try:
            ts = time.strftime("%Y-%m-%d %H:%M:%S")
            entry = f"{ts}\tw{self.worker_id}\t{error_type}\t{rel}\t{message}\n"
            with open(self.error_log, "a", encoding="utf-8") as f:
                f.write(entry)
        except Exception:
            pass

    def _restart_clangd(self):
        if self.client:
            self.client.shutdown()
        time.sleep(1)
        self.client = ClangdClient(self.clangd_path, self.repo_root, jobs=self.jobs)
        time.sleep(3)
        self.files_since_restart = 0

    def _is_clangd_alive(self):
        """Check if the clangd process is still running."""
        try:
            return self.client is not None and self.client.proc.poll() is None
        except Exception:
            return False

    def _run(self):
        while not self.stop_event.is_set():
            try:
                rel = self.work_queue.get(timeout=1)
            except queue.Empty:
                continue

            if rel is None:  # Poison pill
                self.work_queue.task_done()
                break

            # Periodic clangd restart
            if self.files_since_restart >= self.restart_interval:
                self._restart_clangd()

            # Check if clangd crashed — restart before attempting work
            if not self._is_clangd_alive():
                with self.result_lock:
                    self._log_error(rel, "RESTART", "clangd crashed, restarting")
                try:
                    self._restart_clangd()
                except Exception:
                    with self.result_lock:
                        self.stats["fail"] += 1
                        self._log_error(rel, "FAIL", "clangd restart failed")
                    self.work_queue.task_done()
                    continue

            src = os.path.join(self.repo_root, rel)
            out = os.path.join(self.output_dir, rel + ".serena_context.txt")
            os.makedirs(os.path.dirname(out), exist_ok=True)

            try:
                context = extract_file(self.client, src, self.repo_root,
                                       skip_refs=self.skip_refs, compress=self.compress,
                                       perf_log=self.perf_log)
                if context:
                    Path(out).write_text(context, encoding="utf-8")
                    sha = sha1_file(src)
                    with self.result_lock:
                        save_hash_entry(self.hash_db_path, sha, rel)
                        self.stats["done"] += 1
                else:
                    # Record hash so empty files are skipped on rerun
                    sha = sha1_file(src)
                    with self.result_lock:
                        save_hash_entry(self.hash_db_path, sha, rel)
                        self.stats["empty"] += 1
                        self._log_error(rel, "EMPTY", "No symbols returned by clangd")
            except OSError as e:
                # Errno 22 / broken pipe = clangd crashed mid-file
                # Re-queue the file and restart clangd
                with self.result_lock:
                    self._log_error(rel, "CRASH", f"clangd pipe broken: {e}, restarting and retrying")
                try:
                    self._restart_clangd()
                    # Retry this file once
                    try:
                        context = extract_file(self.client, src, self.repo_root,
                                               skip_refs=self.skip_refs, compress=self.compress,
                                               perf_log=self.perf_log)
                        if context:
                            Path(out).write_text(context, encoding="utf-8")
                            sha = sha1_file(src)
                            with self.result_lock:
                                save_hash_entry(self.hash_db_path, sha, rel)
                                self.stats["done"] += 1
                        else:
                            sha = sha1_file(src)
                            with self.result_lock:
                                save_hash_entry(self.hash_db_path, sha, rel)
                                self.stats["empty"] += 1
                                self._log_error(rel, "EMPTY", "No symbols on retry")
                    except Exception as e2:
                        with self.result_lock:
                            self.stats["fail"] += 1
                            self._log_error(rel, "FAIL", f"Retry failed: {e2}")
                except Exception:
                    with self.result_lock:
                        self.stats["fail"] += 1
                        self._log_error(rel, "FAIL", "clangd restart failed after crash")
            except Exception as e:
                with self.result_lock:
                    self.stats["fail"] += 1
                    self._log_error(rel, "FAIL", str(e))

            self.files_since_restart += 1
            self.work_queue.task_done()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Extract LSP context via clangd")
    parser.add_argument("--repo-root", required=True, help="Repository root directory")
    parser.add_argument("--target-dir", default=".", help="Subdirectory to scan")
    parser.add_argument("--output-dir", default=None,
                        help="Output directory for .serena_context.txt (default: architecture/.serena_context)")
    parser.add_argument("--clangd-path", default="clangd", help="Path to clangd binary")
    parser.add_argument("--jobs", type=int, default=2, help="clangd -j parallelism per instance")
    parser.add_argument("--workers", type=int, default=0,
                        help="Max parallel clangd instances (0=auto based on free RAM)")
    parser.add_argument("--file-list", default=None, help="File containing list of relative paths")
    parser.add_argument("--include-rx",
                        default=r"\.(cpp|cc|cxx|h|hpp|inl|c)$",
                        help="Include regex for file extensions")
    parser.add_argument("--exclude-rx",
                        default=r"[/\\](\.git|architecture|Binaries|Build|DerivedDataCache|Intermediate|Saved|\.vs|ThirdParty|GeneratedFiles|AutomationTool)([/\\]|$)",
                        help="Exclude regex for directories")
    parser.add_argument("--force", action="store_true", help="Re-extract even if context file exists")
    parser.add_argument("--skip-refs", action="store_true",
                        help="Skip reference queries (much faster, symbols only)")
    parser.add_argument("--compress", action="store_true",
                        help="Compress LSP context: top-15 symbols by ref count, collapse methods")
    parser.add_argument("--min-free-ram", type=float, default=6.0,
                        help="Minimum free RAM in GB to maintain (default: 6)")
    parser.add_argument("--ram-per-worker", type=float, default=5.0,
                        help="Estimated RAM per clangd instance in GB (default: 5)")
    args = parser.parse_args()

    repo_root = os.path.abspath(args.repo_root)

    # Snapshot existing PCH files so we only clean up ours, and register cleanup
    _snapshot_pch_baseline()
    atexit.register(cleanup_pch_files)

    output_dir = args.output_dir or os.path.join(repo_root, "architecture", ".serena_context")
    state_dir = os.path.join(output_dir, ".state")
    os.makedirs(output_dir, exist_ok=True)
    os.makedirs(state_dir, exist_ok=True)

    hash_db_path = os.path.join(state_dir, "hashes.tsv")
    hash_db = load_hash_db(hash_db_path)

    # Collect files
    files = collect_files(repo_root, args.target_dir, args.include_rx, args.exclude_rx, args.file_list)
    total = len(files)
    if total == 0:
        print("No matching source files found.")
        sys.exit(1)

    # Filter to files needing extraction
    file_queue = []
    skipped = 0
    for rel in files:
        src = os.path.join(repo_root, rel)
        out = os.path.join(output_dir, rel + ".serena_context.txt")
        if not args.force:
            sha = sha1_file(src)
            if hash_db.get(rel) == sha:
                # Hash matches — either context file exists (done) or was empty (no symbols)
                skipped += 1
                continue
        file_queue.append(rel)

    # Determine worker count
    free_ram = get_free_ram_gb()
    available = free_ram - args.min_free_ram
    auto_workers = max(1, int(available / args.ram_per_worker))
    if args.workers > 0:
        max_workers = args.workers
    else:
        max_workers = auto_workers

    print(f"serena_extract.py - Adaptive Parallel LSP Extraction")
    print(f"====================================================")
    print(f"Repo root:    {repo_root}")
    print(f"Target:       {args.target_dir}")
    print(f"clangd:       {args.clangd_path} (-j={args.jobs})")
    print(f"Files:        {total} total | skip: {skipped} | process: {len(file_queue)}")
    print(f"Free RAM:     {free_ram:.1f} GB | reserve: {args.min_free_ram} GB | per-worker: {args.ram_per_worker} GB")
    print(f"Workers:      {max_workers} max (auto={auto_workers})")
    print(f"Output:       {output_dir}")
    if args.skip_refs:
        print(f"Refs:         SKIPPED (symbols only)")
    print()

    if not file_queue:
        print("Nothing to do. All context files are up to date.")
        sys.exit(0)

    # Performance log
    perf_log = os.path.join(state_dir, "perf.log")
    with open(perf_log, "w", encoding="utf-8") as f:
        f.write("file\ttotal\topen\tsym\trefs\ttrim\tsyms\tlines\tslowest_refs\n")

    error_log = os.path.join(state_dir, "errors.log")
    with open(error_log, "w", encoding="utf-8") as f:
        f.write("timestamp\tworker\ttype\tfile\tmessage\n")
    print(f"Error log:    {error_log}")

    # Adaptive scaling constants
    RAM_CHECK_INTERVAL = 30         # Check RAM every N files processed
    RAM_SCALE_DOWN_THRESHOLD = 4.0  # GB free — shed a worker below this
    RAM_SCALE_UP_THRESHOLD = 10.0   # GB free — add a worker above this
    CLANGD_RESTART_INTERVAL = 1000

    # Shared state
    work_queue = queue.Queue()
    result_lock = threading.Lock()
    stats = {"done": 0, "fail": 0, "empty": 0}

    # Fill work queue
    for rel in file_queue:
        work_queue.put(rel)

    # Start initial workers
    free_ram = get_free_ram_gb()
    initial_workers = max(1, min(max_workers, int((free_ram - args.min_free_ram) / args.ram_per_worker)))
    workers = []

    print(f"Starting {initial_workers} worker(s)...")
    for i in range(initial_workers):
        w = ExtractionWorker(
            worker_id=i,
            clangd_path=args.clangd_path,
            repo_root=repo_root,
            jobs=args.jobs,
            work_queue=work_queue,
            result_lock=result_lock,
            output_dir=output_dir,
            hash_db_path=hash_db_path,
            skip_refs=args.skip_refs,
            compress=args.compress,
            perf_log=perf_log,
            stats=stats,
            error_log=error_log,
            restart_interval=CLANGD_RESTART_INTERVAL,
        )
        w.start()
        workers.append(w)
        print(f"  Worker {i} started")
    print()

    # Monitor loop
    start_time = time.time()
    last_processed = 0
    window_start = time.time()
    files_at_window = 0
    RATE_WINDOW_SEC = 30  # Compute instantaneous rate over last N seconds
    check_counter = 0

    try:
        while True:
            time.sleep(2)

            with result_lock:
                processed = stats["done"] + stats["fail"] + stats["empty"]
                done = stats["done"]
                fail = stats["fail"]
                empty = stats["empty"]

            remaining = len(file_queue) - processed
            if remaining <= 0 and work_queue.empty():
                break

            # Rates (based on done only — empty/failed are fast and would inflate rate)
            elapsed = time.time() - start_time
            avg_rate = done / elapsed if elapsed > 0 and done > 0 else 0

            window_elapsed = time.time() - window_start
            if window_elapsed >= RATE_WINDOW_SEC:
                inst_rate = (done - files_at_window) / window_elapsed if done > files_at_window else 0
                window_start = time.time()
                files_at_window = done
            else:
                inst_rate = (done - files_at_window) / window_elapsed if window_elapsed > 0 and done > files_at_window else avg_rate

            # ETA (remaining files at the rate of successfully done files)
            rate_for_eta = avg_rate if avg_rate > 0 else inst_rate
            if rate_for_eta > 0:
                eta_sec = int(remaining / rate_for_eta)
                eta_h, eta_rem = divmod(eta_sec, 3600)
                eta_m, eta_s = divmod(eta_rem, 60)
                eta = f"{eta_h}h{eta_m:02d}m{eta_s:02d}s" if eta_h > 0 else f"{eta_m}m{eta_s:02d}s"
            else:
                eta = "?"

            active = sum(1 for w in workers if w.is_alive())
            free_ram = get_free_ram_gb()

            # Adaptive scaling check
            scale_tag = ""
            check_counter += 1
            if check_counter >= RAM_CHECK_INTERVAL // 2:  # Every ~60s at 2s sleep
                check_counter = 0

                if free_ram < RAM_SCALE_DOWN_THRESHOLD and active > 1:
                    # Shed a worker
                    for w in reversed(workers):
                        if w.is_alive():
                            w.stop()
                            scale_tag = f"  [scaled down to {active-1}w, {free_ram:.1f}GB free]"
                            break

                elif free_ram > RAM_SCALE_UP_THRESHOLD and active < max_workers:
                    # Add a worker
                    new_id = len(workers)
                    w = ExtractionWorker(
                        worker_id=new_id,
                        clangd_path=args.clangd_path,
                        repo_root=repo_root,
                        jobs=args.jobs,
                        work_queue=work_queue,
                        result_lock=result_lock,
                        output_dir=output_dir,
                        hash_db_path=hash_db_path,
                        skip_refs=args.skip_refs,
                        compress=args.compress,
                        perf_log=perf_log,
                        stats=stats,
                        error_log=error_log,
                        restart_interval=CLANGD_RESTART_INTERVAL,
                    )
                    w.start()
                    workers.append(w)
                    scale_tag = f"  [scaled up to {active+1}w, {free_ram:.1f}GB free]"

            clangd_ram = get_clangd_ram_gb()
            line = (f"  {processed}/{len(file_queue)}  done={done} empty={empty} fail={fail}  "
                    f"avg={avg_rate:.1f}/s now={inst_rate:.1f}/s  w={active}  "
                    f"clangd={clangd_ram:.1f}GB free={free_ram:.1f}GB  eta={eta}{scale_tag}")
            # Pad/truncate to terminal width so line overwrites cleanly
            term_width = shutil.get_terminal_size((120, 24)).columns
            line = line[:term_width - 1].ljust(term_width - 1)
            print(f"\r{line}", end="", flush=True)

    except KeyboardInterrupt:
        print("\n\nInterrupted. Stopping workers...")

    # Shutdown all workers
    for w in workers:
        w.stop()

    # Clean up PCH files left by workers
    cleanup_pch_files()

    # Drain any remaining items
    while not work_queue.empty():
        try:
            work_queue.get_nowait()
            work_queue.task_done()
        except queue.Empty:
            break

    print()
    print()

    with result_lock:
        done = stats["done"]
        fail = stats["fail"]
        empty = stats["empty"]

    elapsed = time.time() - start_time
    eh, em_rem = divmod(int(elapsed), 3600)
    em, es = divmod(em_rem, 60)
    elapsed_str = f"{eh}h{em:02d}m{es:02d}s" if eh > 0 else f"{em}m{es:02d}s"

    print(f"Complete. {done} context files written, {empty} empty (no symbols), {fail} failed.")
    print(f"Elapsed: {elapsed_str}")
    print(f"Output: {output_dir}")
    if fail > 0 or empty > 0:
        print(f"Error log: {error_log}")


def run_tests():
    """Run unit tests for all pure functions. No clangd required."""
    import unittest

    class TestFlattenSymbols(unittest.TestCase):
        def test_empty(self):
            self.assertEqual(flatten_symbols([]), [])

        def test_single_function(self):
            syms = [{"name": "DoWork", "kind": 12,
                     "range": {"start": {"line": 10, "character": 0},
                               "end": {"line": 20, "character": 0}},
                     "selectionRange": {"start": {"line": 10, "character": 5},
                                        "end": {"line": 10, "character": 11}}}]
            result = flatten_symbols(syms)
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0]["name"], "DoWork")
            self.assertEqual(result[0]["kind_name"], "Function")
            self.assertEqual(result[0]["start_line"], 11)  # 1-indexed
            self.assertEqual(result[0]["end_line"], 21)
            self.assertEqual(result[0]["sel_line"], 10)  # 0-indexed for LSP
            self.assertEqual(result[0]["sel_char"], 5)
            self.assertEqual(result[0]["path"], "DoWork")

        def test_nested_class_with_methods(self):
            syms = [{"name": "MyClass", "kind": 5,
                     "range": {"start": {"line": 0}, "end": {"line": 50}},
                     "selectionRange": {"start": {"line": 0, "character": 6}},
                     "children": [
                         {"name": "Init", "kind": 6,
                          "range": {"start": {"line": 5}, "end": {"line": 10}},
                          "selectionRange": {"start": {"line": 5, "character": 0}}},
                         {"name": "Tick", "kind": 6,
                          "range": {"start": {"line": 15}, "end": {"line": 25}},
                          "selectionRange": {"start": {"line": 15, "character": 0}}},
                     ]}]
            result = flatten_symbols(syms)
            self.assertEqual(len(result), 3)
            self.assertEqual(result[0]["name"], "MyClass")
            self.assertEqual(result[0]["path"], "MyClass")
            self.assertEqual(result[1]["name"], "Init")
            self.assertEqual(result[1]["path"], "MyClass/Init")
            self.assertEqual(result[2]["path"], "MyClass/Tick")

        def test_all_symbol_kinds(self):
            for kind_id, kind_name in LSP_SYMBOL_KINDS.items():
                syms = [{"name": f"Sym{kind_id}", "kind": kind_id,
                         "range": {"start": {"line": 0}, "end": {"line": 1}},
                         "selectionRange": {"start": {"line": 0, "character": 0}}}]
                result = flatten_symbols(syms)
                self.assertEqual(result[0]["kind_name"], kind_name)

        def test_unknown_kind(self):
            syms = [{"name": "X", "kind": 999,
                     "range": {"start": {"line": 0}, "end": {"line": 1}},
                     "selectionRange": {"start": {"line": 0, "character": 0}}}]
            result = flatten_symbols(syms)
            self.assertEqual(result[0]["kind_name"], "Unknown(999)")

    class TestUriToRelpath(unittest.TestCase):
        def test_windows_uri(self):
            result = uri_to_relpath(
                "file:///C:/Coding/Repo/Engine/Source/foo.cpp",
                "C:\\Coding\\Repo")
            self.assertEqual(result, "Engine/Source/foo.cpp")

        def test_windows_uri_encoded_spaces(self):
            result = uri_to_relpath(
                "file:///C:/My%20Project/src/bar.cpp",
                "C:\\My Project")
            self.assertEqual(result, "src/bar.cpp")

        def test_non_file_uri(self):
            result = uri_to_relpath("https://example.com", "/repo")
            self.assertEqual(result, "https://example.com")

        def test_forward_slash_result(self):
            result = uri_to_relpath(
                "file:///C:/Repo/Engine/Core/Math.cpp",
                "C:\\Repo")
            self.assertNotIn("\\", result)

    class TestGenerateTrimmedSource(unittest.TestCase):
        def setUp(self):
            self.tmpdir = tempfile.mkdtemp()

        def tearDown(self):
            shutil.rmtree(self.tmpdir, ignore_errors=True)

        def test_small_file_returns_none(self):
            p = os.path.join(self.tmpdir, "small.cpp")
            Path(p).write_text("\n".join(f"line {i}" for i in range(100)))
            syms = [{"name": "F", "kind": 12, "path": "F",
                     "start_line": 10, "end_line": 20}]
            self.assertIsNone(generate_trimmed_source(p, syms, max_lines=800))

        def test_large_file_trimmed(self):
            p = os.path.join(self.tmpdir, "big.cpp")
            lines = [f"int line{i} = {i};" for i in range(2000)]
            Path(p).write_text("\n".join(lines))
            syms = [{"name": "FuncA", "kind": 12, "path": "FuncA",
                     "start_line": 100, "end_line": 110},
                    {"name": "FuncB", "kind": 12, "path": "FuncB",
                     "start_line": 500, "end_line": 510}]
            result = generate_trimmed_source(p, syms, max_lines=800)
            self.assertIsNotNone(result)
            self.assertIn("lines omitted", result)
            self.assertLessEqual(len(result.splitlines()), 800)

        def test_no_symbols_returns_none(self):
            p = os.path.join(self.tmpdir, "nosym.cpp")
            Path(p).write_text("\n".join(f"x{i}" for i in range(2000)))
            self.assertIsNone(generate_trimmed_source(p, [], max_lines=800))

        def test_empty_file_returns_none(self):
            p = os.path.join(self.tmpdir, "empty.cpp")
            Path(p).write_text("")
            syms = [{"name": "F", "kind": 12, "path": "F",
                     "start_line": 1, "end_line": 1}]
            self.assertIsNone(generate_trimmed_source(p, syms))

        def test_nested_symbols_skipped(self):
            """Symbols with / in path (nested) should be skipped in trimming."""
            p = os.path.join(self.tmpdir, "nested.cpp")
            lines = [f"int line{i} = {i};" for i in range(2000)]
            Path(p).write_text("\n".join(lines))
            syms = [{"name": "MyClass", "kind": 5, "path": "MyClass",
                     "start_line": 50, "end_line": 60},
                    {"name": "Method", "kind": 6, "path": "MyClass/Method",
                     "start_line": 55, "end_line": 58}]
            result = generate_trimmed_source(p, syms, max_lines=800)
            self.assertIsNotNone(result)

        def test_large_symbol_split(self):
            """Symbols >25 lines should be split into head+tail."""
            p = os.path.join(self.tmpdir, "large_sym.cpp")
            lines = [f"int line{i} = {i};" for i in range(2000)]
            Path(p).write_text("\n".join(lines))
            syms = [{"name": "BigFunc", "kind": 12, "path": "BigFunc",
                     "start_line": 100, "end_line": 200}]
            result = generate_trimmed_source(p, syms, max_lines=800)
            self.assertIsNotNone(result)
            # Should have omitted lines in the middle of BigFunc
            self.assertIn("lines omitted", result)

        def test_includes_first_30_lines(self):
            p = os.path.join(self.tmpdir, "header.cpp")
            lines = ["#include <stdio.h>"] + [f"int line{i} = {i};" for i in range(2000)]
            Path(p).write_text("\n".join(lines))
            syms = [{"name": "F", "kind": 12, "path": "F",
                     "start_line": 1000, "end_line": 1010}]
            result = generate_trimmed_source(p, syms, max_lines=800)
            self.assertIn("#include <stdio.h>", result)

    class TestSha1File(unittest.TestCase):
        def setUp(self):
            self.tmpdir = tempfile.mkdtemp()

        def tearDown(self):
            shutil.rmtree(self.tmpdir, ignore_errors=True)

        def test_deterministic(self):
            p = os.path.join(self.tmpdir, "test.txt")
            Path(p).write_text("hello world")
            h1 = sha1_file(p)
            h2 = sha1_file(p)
            self.assertEqual(h1, h2)
            self.assertEqual(len(h1), 40)
            self.assertTrue(all(c in "0123456789abcdef" for c in h1))

        def test_different_content(self):
            p1 = os.path.join(self.tmpdir, "a.txt")
            p2 = os.path.join(self.tmpdir, "b.txt")
            Path(p1).write_text("hello")
            Path(p2).write_text("world")
            self.assertNotEqual(sha1_file(p1), sha1_file(p2))

    class TestHashDb(unittest.TestCase):
        def setUp(self):
            self.tmpdir = tempfile.mkdtemp()
            self.db_path = os.path.join(self.tmpdir, "hashes.tsv")

        def tearDown(self):
            shutil.rmtree(self.tmpdir, ignore_errors=True)

        def test_load_empty(self):
            db = load_hash_db(self.db_path)  # file doesn't exist
            self.assertEqual(db, {})

        def test_save_and_load(self):
            save_hash_entry(self.db_path, "abc123", "src/foo.cpp")
            save_hash_entry(self.db_path, "def456", "src/bar.cpp")
            db = load_hash_db(self.db_path)
            self.assertEqual(db["src/foo.cpp"], "abc123")
            self.assertEqual(db["src/bar.cpp"], "def456")
            self.assertEqual(len(db), 2)

        def test_load_overwrites_dupes(self):
            save_hash_entry(self.db_path, "old", "src/foo.cpp")
            save_hash_entry(self.db_path, "new", "src/foo.cpp")
            db = load_hash_db(self.db_path)
            self.assertEqual(db["src/foo.cpp"], "new")

    class TestCollectFiles(unittest.TestCase):
        def setUp(self):
            self.tmpdir = tempfile.mkdtemp()
            # Create directory structure
            os.makedirs(os.path.join(self.tmpdir, "src"))
            os.makedirs(os.path.join(self.tmpdir, "src", "core"))
            os.makedirs(os.path.join(self.tmpdir, ".git", "objects"), exist_ok=True)
            os.makedirs(os.path.join(self.tmpdir, "Engine", "ThirdParty", "zlib"), exist_ok=True)
            # Create files
            Path(os.path.join(self.tmpdir, "src", "main.cpp")).write_text("int main() {}")
            Path(os.path.join(self.tmpdir, "src", "util.h")).write_text("#pragma once")
            Path(os.path.join(self.tmpdir, "src", "core", "math.cpp")).write_text("void f() {}")
            Path(os.path.join(self.tmpdir, "src", "readme.txt")).write_text("readme")
            Path(os.path.join(self.tmpdir, ".git", "objects", "abc")).write_text("git obj")
            Path(os.path.join(self.tmpdir, "Engine", "ThirdParty", "zlib", "zlib.c")).write_text("zlib")

        def tearDown(self):
            shutil.rmtree(self.tmpdir, ignore_errors=True)

        def test_include_cpp_h(self):
            files = collect_files(self.tmpdir, ".", r"\.(cpp|h|c)$",
                                  r"[/\\](\.git|ThirdParty)([/\\]|$)")
            names = [os.path.basename(f) for f in files]
            self.assertIn("main.cpp", names)
            self.assertIn("util.h", names)
            self.assertIn("math.cpp", names)

        def test_exclude_git(self):
            files = collect_files(self.tmpdir, ".", r"\.(cpp|h|c)$",
                                  r"[/\\](\.git|ThirdParty)([/\\]|$)")
            for f in files:
                self.assertNotIn(".git", f)

        def test_exclude_thirdparty(self):
            # ThirdParty under Engine/ has a leading separator, so the exclude pattern matches
            files = collect_files(self.tmpdir, ".", r"\.(cpp|h|c)$",
                                  r"[/\\](\.git|ThirdParty)([/\\]|$)")
            for f in files:
                self.assertNotIn("ThirdParty", f)

        def test_exclude_non_matching_ext(self):
            files = collect_files(self.tmpdir, ".", r"\.(cpp|h)$",
                                  r"[/\\](\.git)([/\\]|$)")
            names = [os.path.basename(f) for f in files]
            self.assertNotIn("readme.txt", names)

        def test_target_subdir(self):
            files = collect_files(self.tmpdir, "src/core", r"\.(cpp|h)$",
                                  r"[/\\](\.git)([/\\]|$)")
            self.assertEqual(len(files), 1)
            self.assertIn("math.cpp", files[0])

        def test_file_list(self):
            flist = os.path.join(self.tmpdir, "files.txt")
            Path(flist).write_text("src/main.cpp\nsrc/core/math.cpp\n")
            files = collect_files(self.tmpdir, ".", r"\.cpp$", r"\.git", file_list=flist)
            self.assertEqual(len(files), 2)

        def test_sorted_output(self):
            files = collect_files(self.tmpdir, ".", r"\.(cpp|h)$",
                                  r"[/\\](\.git|ThirdParty)([/\\]|$)")
            self.assertEqual(files, sorted(files))

    class TestPchCleanup(unittest.TestCase):
        def test_snapshot_baseline(self):
            _snapshot_pch_baseline()
            self.assertIsInstance(_pch_baseline, set)

        def test_cleanup_no_crash(self):
            _snapshot_pch_baseline()
            cleanup_pch_files()  # Should not crash even with no session PCH

    class TestSymbolKinds(unittest.TestCase):
        def test_known_kinds(self):
            self.assertEqual(LSP_SYMBOL_KINDS[5], "Class")
            self.assertEqual(LSP_SYMBOL_KINDS[6], "Method")
            self.assertEqual(LSP_SYMBOL_KINDS[12], "Function")
            self.assertEqual(LSP_SYMBOL_KINDS[23], "Struct")
            self.assertEqual(LSP_SYMBOL_KINDS[10], "Enum")

        def test_reference_worthy(self):
            self.assertIn(5, REFERENCE_WORTHY_KINDS)   # Class
            self.assertIn(6, REFERENCE_WORTHY_KINDS)   # Method
            self.assertIn(12, REFERENCE_WORTHY_KINDS)  # Function
            self.assertIn(23, REFERENCE_WORTHY_KINDS)  # Struct
            self.assertNotIn(13, REFERENCE_WORTHY_KINDS)  # Variable

    class TestFuture(unittest.TestCase):
        def test_set_and_wait(self):
            f = _Future()
            f.set_result({"id": 1, "result": "ok"})
            self.assertEqual(f.wait(1), {"id": 1, "result": "ok"})

        def test_timeout(self):
            f = _Future()
            self.assertIsNone(f.wait(0.01))

    # Run
    print("=" * 50)
    print("  serena_extract.py - Unit Tests")
    print("=" * 50)
    print()
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    for cls in [TestFlattenSymbols, TestUriToRelpath, TestGenerateTrimmedSource,
                TestSha1File, TestHashDb, TestCollectFiles, TestPchCleanup,
                TestSymbolKinds, TestFuture]:
        suite.addTests(loader.loadTestsFromTestCase(cls))
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    if "--test" in sys.argv:
        sys.argv.remove("--test")
        run_tests()
    else:
        main()
