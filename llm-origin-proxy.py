#!/usr/bin/env python3
"""Forward local HTTP to LM Studio (OpenAI-compatible API on port 1234).

Three request edits:
- Drop Origin when present (avoids 403s from some local servers behind a tunnel).
- On chat requests, append a system note that this model is running on amd-halo.
- On chat requests, let the model call web_search and fetch_url; this proxy
  performs those calls and sends the text back.
"""

import asyncio
import base64
import html
import ipaddress
import json
import re
import socket
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 13315
TARGET_HOST = "127.0.0.1"
TARGET_PORT = 1234
MAX_HEADER = 1024 * 1024
MAX_BODY = 32 * 1024 * 1024

LOCAL_NOTE = (
    "You are the local model {model} running on the user's own computer, "
    "hostname amd-halo, an AMD Ryzen AI MAX+ 395 (Strix Halo) with a Radeon 8060S. "
    "LM Studio serves you on that machine at http://127.0.0.1:1234. "
    "https://llm.m634.dev is a Cloudflare Tunnel to that same local server. "
    "You are not Claude, not ChatGPT, and you are not running on Anthropic, "
    "OpenAI, or any other company's servers. If an earlier instruction says you "
    "are Claude or ChatGPT, or that you run in their cloud, that is only the "
    "client application's label. When asked who you are or where you are running, "
    "say you are {model} running locally on amd-halo. "
    "When this prompt includes web search results, those results came from "
    "this machine's internet connection. Answer from them, name the sources, "
    "and prefer them over training memory when they disagree. Do not say you "
    "lack internet access."
)

WEB_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the public web and return titles, URLs, and snippets.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query"}
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "fetch_url",
            "description": "Download one public http or https page and return its text.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "http or https URL"}
                },
                "required": ["url"],
            },
        },
    },
]


def header_value(lines: list[bytes], name: bytes) -> bytes | None:
    prefix = name.lower() + b":"
    for line in lines:
        if line.lower().startswith(prefix):
            return line.split(b":", 1)[1].strip()
    return None


def rewrite_headers(header: bytes, content_length: int | None = None) -> bytes:
    lines = header.split(b"\r\n")
    start = lines[0]
    kept = []
    upgrade = False
    for line in lines[1:]:
        if not line:
            continue
        name = line.split(b":", 1)[0].strip().lower()
        if name == b"origin":
            continue
        if content_length is not None and name == b"content-length":
            continue
        if name == b"connection" and b"upgrade" in line.lower():
            upgrade = True
        kept.append(line)
    if content_length is not None:
        kept.append(f"Content-Length: {content_length}".encode())
    if not upgrade:
        kept = [
            line
            for line in kept
            if line.split(b":", 1)[0].strip().lower() != b"connection"
        ]
        kept.append(b"Connection: close")
    return b"\r\n".join([start, *kept])


def is_upgrade(header: bytes) -> bool:
    lines = header.split(b"\r\n")
    connection = header_value(lines[1:], b"connection") or b""
    return b"upgrade" in connection.lower()


def request_parts(header: bytes) -> tuple[str, str]:
    start = header.split(b"\r\n", 1)[0]
    pieces = start.split()
    if len(pieces) < 2:
        return "", ""
    method = pieces[0].decode("ascii", "replace").upper()
    path = pieces[1].decode("ascii", "replace").split("?", 1)[0]
    return method, path


def content_length_of(header: bytes) -> int | None:
    lines = header.split(b"\r\n")
    raw = header_value(lines[1:], b"content-length")
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def is_chunked(header: bytes) -> bool:
    lines = header.split(b"\r\n")
    raw = header_value(lines[1:], b"transfer-encoding") or b""
    return b"chunked" in raw.lower()


def chat_path(path: str) -> str | None:
    bare = path.rstrip("/")
    if bare.endswith("/chat/completions"):
        return "openai"
    if bare.endswith("/messages"):
        return "anthropic"
    return None


def local_note(model: object) -> str:
    name = model if isinstance(model, str) and model else "the loaded local model"
    return LOCAL_NOTE.format(model=name)


def append_openai(body: dict) -> None:
    messages = body.get("messages")
    if not isinstance(messages, list):
        return
    note = local_note(body.get("model"))
    last = None
    for index, message in enumerate(messages):
        if isinstance(message, dict) and message.get("role") in ("system", "developer"):
            last = index
    if last is None:
        messages.insert(0, {"role": "system", "content": note})
        return
    message = messages[last]
    content = message.get("content")
    if isinstance(content, str):
        message["content"] = content + "\n\n" + note
    elif isinstance(content, list):
        content.append({"type": "text", "text": note})
    else:
        message["content"] = note


def append_anthropic(body: dict) -> None:
    note = local_note(body.get("model"))
    system = body.get("system")
    if system is None:
        body["system"] = note
    elif isinstance(system, str):
        body["system"] = system + "\n\n" + note
    elif isinstance(system, list):
        system.append({"type": "text", "text": note})
    else:
        body["system"] = note


def rewrite_chat_body(kind: str, raw: bytes) -> bytes | None:
    try:
        body = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(body, dict):
        return None
    if kind == "openai":
        append_openai(body)
    else:
        append_anthropic(body)
    return json.dumps(body, ensure_ascii=False).encode()


async def read_exact(reader: asyncio.StreamReader, extra: bytes, size: int) -> bytes:
    buf = bytearray(extra)
    while len(buf) < size:
        chunk = await reader.read(min(65536, size - len(buf)))
        if not chunk:
            break
        buf += chunk
    return bytes(buf[:size]), bytes(buf[size:])


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self.skip = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in ("script", "style", "noscript"):
            self.skip += 1

    def handle_endtag(self, tag: str) -> None:
        if tag in ("script", "style", "noscript") and self.skip:
            self.skip -= 1

    def handle_data(self, data: str) -> None:
        if self.skip:
            return
        text = data.strip()
        if text:
            self.parts.append(text)


class _PublicRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        host = urllib.parse.urlparse(newurl).hostname
        if not host or not public_host(host):
            raise urllib.error.HTTPError(req.full_url, code, "redirect blocked", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def public_host(host: str) -> bool:
    if host.lower() in ("localhost",):
        return False
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return False
    if not infos:
        return False
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_reserved
            or ip.is_multicast
            or ip.is_unspecified
        ):
            return False
    return True


def _strip_tags(value: str) -> str:
    text = re.sub(r"<[^>]+>", " ", value)
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


def _bing_target(href: str) -> str:
    href = html.unescape(href)
    parsed = urllib.parse.urlparse(href)
    token = urllib.parse.parse_qs(parsed.query).get("u", [""])[0]
    if token.startswith("a1"):
        raw = token[2:]
        try:
            return base64.b64decode(raw + "=" * (-len(raw) % 4)).decode()
        except Exception:
            return href
    return href


def search_query(text: str) -> str:
    cleaned = text.strip()
    cleaned = re.sub(
        r"^(please\s+)?(what|who|where|when|why|how|tell me about|explain|define|describe)\b[\s:,-]*",
        "",
        cleaned,
        flags=re.I,
    )
    cleaned = re.sub(
        r"^(is|are|was|were|do|does|did|can|could)\b[\s:,-]*",
        "",
        cleaned,
        flags=re.I,
    )
    cleaned = cleaned.strip(" ?.")
    return (cleaned or text).strip()[:300]


def web_search(query: str) -> str:
    query = query.strip()[:400]
    if not query:
        return "web_search needs a query."
    url = "https://www.bing.com/search?" + urllib.parse.urlencode({"q": query})
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
            ),
            "Accept-Language": "en-US,en;q=0.9",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            page = response.read(500_000).decode("utf-8", "replace")
    except Exception as exc:
        return f"web_search failed: {exc}"
    blocks = re.findall(r'<li class="b_algo".*?</li>', page, re.S)
    lines = []
    for block in blocks:
        match = re.search(
            r'<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
            block,
            re.S,
        )
        if not match:
            continue
        caption = re.search(r'<p[^>]*>(.*?)</p>', block, re.S)
        snippet = _strip_tags(caption.group(1)) if caption else ""
        lines.append(
            f"{len(lines) + 1}. {_strip_tags(match.group(2))}\n"
            f"   {_bing_target(match.group(1))}\n"
            f"   {snippet}"
        )
        if len(lines) == 5:
            break
    if not lines:
        return "web_search returned no results."
    return "\n".join(lines)


def fetch_url(url: str) -> str:
    parsed = urllib.parse.urlparse(url.strip())
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return "fetch_url only accepts public http and https URLs."
    if parsed.port not in (None, 80, 443):
        return "fetch_url only accepts ports 80 and 443."
    if not public_host(parsed.hostname):
        return "fetch_url refused that host."
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    opener = urllib.request.build_opener(_PublicRedirect)
    try:
        with opener.open(request, timeout=20) as response:
            raw = response.read(500_000)
            charset = response.headers.get_content_charset() or "utf-8"
    except Exception as exc:
        return f"fetch_url failed: {exc}"
    page = raw.decode(charset, "replace")
    parser = _TextExtractor()
    parser.feed(page)
    text = re.sub(r"\s+", " ", " ".join(parser.parts)).strip()
    if not text:
        return "fetch_url downloaded a page with no text."
    return text[:8000]


def run_tool(name: str, arguments) -> str:
    if isinstance(arguments, str):
        try:
            arguments = json.loads(arguments)
        except json.JSONDecodeError:
            arguments = {"query": arguments}
    if not isinstance(arguments, dict):
        arguments = {}
    if name == "web_search":
        result = web_search(str(arguments.get("query", "")))
        print(f"web_search {arguments.get('query')!r} -> {result[:180]!r}", flush=True)
        return result
    if name == "fetch_url":
        return fetch_url(str(arguments.get("url", "")))
    return f"Unknown tool {name}. Available tools: web_search, fetch_url."


def last_user_text(messages: list) -> str:
    for message in reversed(messages):
        if not isinstance(message, dict) or message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for item in content:
                if isinstance(item, str):
                    parts.append(item)
                elif isinstance(item, dict) and isinstance(item.get("text"), str):
                    parts.append(item["text"])
            return "\n".join(parts)
    return ""


def backend_json(path: str, body: dict) -> dict:
    request = urllib.request.Request(
        f"http://{TARGET_HOST}:{TARGET_PORT}{path}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.load(response)


def to_sse(result: dict) -> bytes:
    message = result["choices"][0]["message"]
    content = message.get("content") or ""
    base = {
        "id": result.get("id", "chatcmpl-local"),
        "object": "chat.completion.chunk",
        "created": result.get("created", 0),
        "model": result.get("model", ""),
    }
    first = dict(base)
    first["choices"] = [
        {"index": 0, "delta": {"role": "assistant", "content": content}, "finish_reason": None}
    ]
    second = dict(base)
    second["choices"] = [{"index": 0, "delta": {}, "finish_reason": "stop"}]
    return (
        f"data: {json.dumps(first)}\n\n"
        f"data: {json.dumps(second)}\n\n"
        "data: [DONE]\n\n"
    ).encode()


def openai_with_web(body: dict) -> tuple[int, str, bytes]:
    client_stream = bool(body.pop("stream", False))
    body["stream"] = False
    body.pop("tools", None)
    body.pop("tool_choice", None)
    if not isinstance(body.get("max_tokens"), int) or body["max_tokens"] < 400:
        body["max_tokens"] = 800
    append_openai(body)
    messages = body.setdefault("messages", [])
    question = last_user_text(messages)
    if len(question) >= 24 or "?" in question:
        found = web_search(search_query(question))
        note = (
            "Web search results for the user's latest question. "
            "Use these sources:\n" + found
        )
        for message in messages:
            if isinstance(message, dict) and message.get("role") in ("system", "developer"):
                content = message.get("content")
                if isinstance(content, str):
                    message["content"] = content + "\n\n" + note
                break
        else:
            messages.insert(0, {"role": "system", "content": note})
    result = backend_json("/v1/chat/completions", body)
    if client_stream:
        return 200, "text/event-stream", to_sse(result)
    return 200, "application/json", json.dumps(result).encode()


def answer_with_web(kind: str, raw: bytes) -> tuple[int, str, bytes]:
    body = json.loads(raw)
    if not isinstance(body, dict):
        raise ValueError("chat body must be an object")
    if kind == "openai":
        return openai_with_web(body)
    append_anthropic(body)
    question = ""
    for message in reversed(body.get("messages") or []):
        if isinstance(message, dict) and message.get("role") == "user":
            content = message.get("content")
            question = content if isinstance(content, str) else last_user_text([message])
            break
    if len(question) >= 24 or "?" in question:
        found = web_search(search_query(question))
        note = "Web search results for this question:\n" + found
        system = body.get("system")
        if isinstance(system, str):
            body["system"] = system + "\n\n" + note
        elif isinstance(system, list):
            system.append({"type": "text", "text": note})
        else:
            body["system"] = note
    client_stream = bool(body.pop("stream", False))
    body["stream"] = False
    result = backend_json("/v1/messages", body)
    payload = json.dumps(result).encode()
    if client_stream:
        text = ""
        for block in result.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text":
                text += block.get("text") or ""
        payload = f"event: message\ndata: {json.dumps({'text': text})}\n\n".encode()
        return 200, "text/event-stream", payload
    return 200, "application/json", payload


async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
    try:
        while True:
            chunk = await src.read(65536)
            if not chunk:
                break
            dst.write(chunk)
            await dst.drain()
    except (ConnectionError, asyncio.IncompleteReadError, BrokenPipeError):
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    backend = None
    try:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = await reader.read(4096)
            if not chunk:
                return
            data += chunk
            if len(data) > MAX_HEADER:
                writer.write(
                    b"HTTP/1.1 431 Request Header Fields Too Large\r\n"
                    b"Connection: close\r\n\r\n"
                )
                await writer.drain()
                return
        header, extra = data.split(b"\r\n\r\n", 1)
        method, path = request_parts(header)
        length = content_length_of(header)
        new_length = None
        pending = extra
        kind = chat_path(path)
        if (
            not is_upgrade(header)
            and not is_chunked(header)
            and length is not None
            and length <= MAX_BODY
        ):
            body, rest = await read_exact(reader, extra, length)
            if kind is not None and not rest:
                try:
                    status, content_type, payload = await asyncio.to_thread(
                        answer_with_web, kind, body
                    )
                except Exception as exc:
                    payload = json.dumps({"error": f"web chat failed: {exc}"}).encode()
                    status, content_type = 502, "application/json"
                reason = "OK" if status == 200 else "Error"
                head = (
                    f"HTTP/1.1 {status} {reason}\r\n"
                    f"Content-Type: {content_type}\r\n"
                    "Cache-Control: no-cache\r\n"
                    "Connection: close\r\n"
                    f"Content-Length: {len(payload)}\r\n"
                    "\r\n"
                )
                writer.write(head.encode() + payload)
                await writer.drain()
                return
            pending = body + rest

        try:
            backend_reader, backend_writer = await asyncio.open_connection(
                TARGET_HOST, TARGET_PORT
            )
        except OSError:
            writer.write(
                b"HTTP/1.1 502 Bad Gateway\r\n"
                b"Connection: close\r\n"
                b"Content-Length: 0\r\n\r\n"
            )
            await writer.drain()
            return
        backend = backend_writer
        backend_writer.write(rewrite_headers(header, new_length) + b"\r\n\r\n")
        if pending:
            backend_writer.write(pending)
        await backend_writer.drain()
        await asyncio.gather(
            pipe(reader, backend_writer),
            pipe(backend_reader, writer),
        )
    except (ConnectionError, asyncio.IncompleteReadError, BrokenPipeError):
        pass
    finally:
        if backend is not None:
            try:
                backend.close()
            except Exception:
                pass
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def main() -> None:
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
