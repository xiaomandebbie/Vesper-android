"""Android MCP bridge - VPS edition.

Based on Chronos & Kairos's tested 2026-11-11 local_mcp.py.
VPS adaptation: binds 127.0.0.1 only; TLS terminates at the gateway (Caddy or Nginx).

Do NOT bind to 0.0.0.0 or to the public IP directly.
"""

import asyncio
import base64
import hmac
import json
import os
import uuid
from http import HTTPStatus

import uvicorn
from websockets.asyncio.server import serve
from mcp.server.fastmcp import FastMCP, Image
from mcp.server.transport_security import TransportSecuritySettings

HOST = "127.0.0.1"
PUBLIC_HOST = os.environ.get("ANDROID_MCP_PUBLIC_HOST", "android.vesperphosphor.online").strip()
WS_PORT = int(os.environ.get("ANDROID_MCP_WS_PORT", "18765"))
HTTP_PORT = int(os.environ.get("ANDROID_MCP_HTTP_PORT", "18766"))
MAX_WS_BYTES = max(1, int(os.environ.get("ANDROID_MCP_MAX_WS_MB", "16"))) * 1024 * 1024
PHONE_TIMEOUT = float(os.environ.get("ANDROID_MCP_PHONE_TIMEOUT", "30"))
TOKEN = os.environ.get("ANDROID_MCP_TOKEN", "").strip()


def token_is_sane(value: str) -> bool:
    if len(value) < 16 or not value.isascii():
        return False
    return all(33 <= ord(c) <= 126 for c in value)


if not token_is_sane(TOKEN):
    raise SystemExit(
        "ANDROID_MCP_TOKEN is missing or invalid (need 16+ printable ASCII chars). "
        "Set it in /opt/android-mcp/.env"
    )

EXPECTED_AUTH = ("Bearer " + TOKEN).encode("ascii")

phone = None
pending: dict = {}

mcp = FastMCP(
    "Android Bridge",
    host=HOST,
    port=HTTP_PORT,
    stateless_http=True,
    json_response=True,
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=[
            PUBLIC_HOST,
            PUBLIC_HOST + ":443",
            HOST,
            "{0}:{1}".format(HOST, HTTP_PORT),
        ],
        allowed_origins=[
            "https://" + PUBLIC_HOST,
            "https://" + PUBLIC_HOST + ":443",
        ],
    ),
)


def phone_auth(connection, request):
    """Reject the WebSocket handshake before any phone session starts."""
    if request.path != "/android/join":
        return connection.respond(HTTPStatus.NOT_FOUND, "Not found\n")
    actual = request.headers.get("Authorization", "").encode("utf-8")
    if not hmac.compare_digest(actual, EXPECTED_AUTH):
        return connection.respond(HTTPStatus.UNAUTHORIZED, "Unauthorized\n")
    return None


async def handle_phone(ws):
    global phone
    if phone is not None:
        await ws.close(code=1008, reason="A phone is already connected")
        return
    phone = ws
    print("PHONE CONNECTED", flush=True)
    try:
        async for message in ws:
            if not isinstance(message, str):
                continue
            try:
                data = json.loads(message)
            except (ValueError, TypeError):
                continue
            if not isinstance(data, dict):
                continue
            request_id = data.get("id")
            if not isinstance(request_id, str):
                continue
            future = pending.get(request_id)
            if future is not None and not future.done():
                future.set_result(data)
    finally:
        phone = None
        for f in list(pending.values()):
            if not f.done():
                f.set_exception(ConnectionError("Phone disconnected"))
        print("PHONE DISCONNECTED", flush=True)


async def phone_request(method: str, params: dict = None):
    ws = phone
    if ws is None:
        raise RuntimeError("Phone is not connected")
    request_id = str(uuid.uuid4())
    future = asyncio.get_running_loop().create_future()
    pending[request_id] = future
    try:
        await ws.send(json.dumps({"id": request_id, "method": method, "params": params or {}}))
        reply = await asyncio.wait_for(future, timeout=PHONE_TIMEOUT)
        if reply.get("status") != "success":
            raise RuntimeError(str(reply.get("error", "Phone request failed")))
        return reply.get("result")
    finally:
        pending.pop(request_id, None)


@mcp.tool()
async def android_connection_status() -> dict:
    """Read whether the phone is connected; no phone actions."""
    return {"connected": phone is not None}


@mcp.tool()
async def android_version() -> dict:
    """Read Portal version; no screenshots or control."""
    return {"result": await phone_request("version")}


@mcp.tool()
async def android_open_messenger(app: str) -> dict:
    """Open installed WeChat or QQ. Does not send messages."""
    packages = {"wechat": "com.tencent.mm", "qq": "com.tencent.mobileqq"}
    if app not in packages:
        raise ValueError("app must be wechat or qq")
    result = await phone_request("app", {"package": packages[app], "stopBeforeLaunch": False})
    return {"app": app, "result": result}


@mcp.tool()
async def android_screenshot():
    """Read the screen image. May contain private information. No taps."""
    result = await phone_request("screenshot", {"hideOverlay": True})
    if not isinstance(result, str):
        raise RuntimeError("Unexpected screenshot format")
    if result.startswith("data:"):
        result = result.split(",", 1)[1]
    return Image(data=base64.b64decode(result, validate=True), format="png")


@mcp.tool()
async def android_ui_state() -> dict:
    """Read the UI tree. May contain private information. No taps."""
    return {"result": await phone_request("state", {"filter": False})}


@mcp.tool()
async def android_tap(x: int, y: int) -> dict:
    """Tap original-screenshot coordinates. May hit Send; inspect the screen first."""
    if x < 0 or y < 0:
        raise ValueError("Coordinates must be nonnegative")
    return {"result": await phone_request("tap", {"x": x, "y": y})}


@mcp.tool()
async def android_input_text(text: str, clear: bool = True) -> dict:
    """Type through Mobilerun Keyboard. Does not press Send."""
    if not text or len(text) > 10000:
        raise ValueError("Text must contain 1 to 10000 characters")
    encoded = base64.b64encode(text.encode("utf-8")).decode("ascii")
    return {"result": await phone_request("keyboard/input", {"base64_text": encoded, "clear": clear})}


@mcp.tool()
async def android_press_key(key_code: int) -> dict:
    """Press an Android key. Enter=66 may send; Back=4, Backspace=67."""
    if key_code not in {3, 4, 19, 20, 21, 22, 61, 66, 67, 111}:
        raise ValueError("Unsupported key code")
    return {"result": await phone_request("keyboard/key", {"key_code": key_code})}


@mcp.tool()
async def android_back() -> dict:
    """Android accessibility Back."""
    return {"result": await phone_request("global", {"action": 1})}


@mcp.tool()
async def android_swipe(start_x: int, start_y: int, end_x: int, end_y: int, duration: int = 400) -> dict:
    """Swipe using original-screenshot coordinates; duration in ms."""
    if min(start_x, start_y, end_x, end_y) < 0 or not 100 <= duration <= 3000:
        raise ValueError("Invalid coordinates or duration")
    return {
        "result": await phone_request(
            "swipe",
            {
                "startX": start_x,
                "startY": start_y,
                "endX": end_x,
                "endY": end_y,
                "duration": duration,
            },
        )
    }


class RequireToken:
    """Bearer-token gate in front of the MCP ASGI app."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            headers = dict(scope.get("headers", []))
            actual = headers.get(b"authorization", b"")
            if not hmac.compare_digest(actual, EXPECTED_AUTH):
                await send(
                    {
                        "type": "http.response.start",
                        "status": 401,
                        "headers": [(b"content-type", b"text/plain")],
                    }
                )
                await send({"type": "http.response.body", "body": b"Unauthorized"})
                return
        await self.app(scope, receive, send)


async def main():
    app = RequireToken(mcp.streamable_http_app())
    server = uvicorn.Server(uvicorn.Config(app, host=HOST, port=HTTP_PORT, log_level="info"))
    async with serve(
        handle_phone,
        HOST,
        WS_PORT,
        process_request=phone_auth,
        max_size=MAX_WS_BYTES,
    ):
        print("PHONE (via gateway WSS): wss://{0}/android/join".format(PUBLIC_HOST), flush=True)
        print("MCP   (via gateway HTTPS): https://{0}/mcp".format(PUBLIC_HOST), flush=True)
        print(
            "Internal ports: WS={0} HTTP={1} max_ws={2}MB".format(
                WS_PORT, HTTP_PORT, MAX_WS_BYTES // (1024 * 1024)
            ),
            flush=True,
        )
        await server.serve()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("Stopped.")
