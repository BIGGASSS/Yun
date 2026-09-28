#!/usr/bin/env python3
"""Real-TCP API contract/isolation smoke test, using only Python's standard library.

Run: python3 scripts/api_smoke.py [--no-build]
Creates two users and generated WAV audio in a temporary, disposable server.
No credentials, source audio, or existing server data are read or modified.
"""
import argparse
import hashlib
import http.client
import io
import json
import pathlib
import socket
import subprocess
import tempfile
import time
import uuid
import wave

ROOT = pathlib.Path(__file__).resolve().parents[1]
PASSWORD = "smoke-test-password-only"


def uid():
    return str(uuid.uuid4())


def wav_bytes():
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(8000)
        wav.writeframes(b"\0\0" * 8000 * 4)
    return output.getvalue()


class API:
    def __init__(self, port):
        self.port = port
        self.checks = 0

    def request(self, method, path, body=None, token=None, headers=None, status=200):
        headers = dict(headers or {})
        if token:
            headers["Authorization"] = "Bearer " + token
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        try:
            conn.request(method, path, body=body, headers=headers)
            response = conn.getresponse()
            data = response.read()
            result_headers = {k.lower(): v for k, v in response.getheaders()}
            assert response.status == status, (method, path, response.status, status, data)
            if result_headers.get("content-type", "").startswith("application/json") and data:
                data = json.loads(data)
            if status >= 400 and method != "HEAD":
                assert isinstance(data, dict) and isinstance(data.get("error"), str), data
            self.checks += 1
            return data, result_headers
        finally:
            conn.close()

    def json(self, *args, **kwargs):
        return self.request(*args, **kwargs)[0]


def exercise(api):
    device_a, device_b = uid(), uid()
    a = api.json("POST", "/api/v1/auth/login", {
        "username": "alice", "password": PASSWORD, "device_id": device_a})
    b = api.json("POST", "/api/v1/auth/login", {
        "username": "bob", "password": PASSWORD, "device_id": device_b})
    ta, tb = a["access_token"], b["access_token"]
    api.json("GET", "/api/v1/library", status=401)
    assert api.json("GET", "/api/v1/library", token=ta)["reset"] is True
    audio = wav_bytes()
    digest = hashlib.sha256(audio).hexdigest()
    upload = api.json("POST", "/api/v1/uploads", {
        "filename": "smoke.wav", "size_bytes": len(audio)}, token=ta)
    path = "/api/v1/uploads/" + upload["id"]
    for method in ["GET", "DELETE"]:
        api.json(method, path, token=tb, status=404)
    api.json("POST", path + "/complete", token=tb, status=404)
    api.json("PATCH", path, b"x", token=tb, headers={"Upload-Offset": "0"}, status=404)
    api.json("POST", path + "/complete", token=ta, status=409)
    first = 117
    assert api.json("PATCH", path, audio[:first], token=ta,
                    headers={"Upload-Offset": "0"})["offset"] == first
    api.json("PATCH", path, audio[:first], token=ta,
             headers={"Upload-Offset": "0"}, status=409)
    assert api.json("GET", path, token=ta)["offset"] == first
    api.json("PATCH", path, audio[first:], token=ta,
             headers={"Upload-Offset": str(first)})
    track = api.json("POST", path + "/complete", token=ta)
    assert track["sha256"] == digest and track["size_bytes"] == len(audio)
    assert track["track_number"] is None and track["disc_number"] is None
    assert track["duration_ms"] == 4000
    assert api.json("POST", path + "/complete", token=ta) == track, "lost completion ACK receipt"
    assert api.json("GET", path, token=ta)["offset"] == len(audio)
    track_path = "/api/v1/tracks/" + track["id"]
    for suffix in ["/audio", "/artwork"]:
        api.json("GET", track_path + suffix, token=tb, status=404)
    api.json("PATCH", track_path, {"revision": track["revision"], "title": "stolen"}, token=tb, status=404)
    api.json("DELETE", track_path, token=tb, status=404)
    body, headers = api.request("GET", track_path + "/audio", token=ta)
    assert body == audio and headers["etag"] == '"' + digest + '"'
    assert headers["accept-ranges"] == "bytes" and int(headers["content-length"]) == len(audio)
    body, headers = api.request("HEAD", track_path + "/audio", token=ta)
    assert body == b"" and int(headers["content-length"]) == len(audio)
    for value, expected in [("bytes=0-8", audio[:9]), ("bytes=-13", audio[-13:]),
                            ("bytes=117-", audio[117:])]:
        body, headers = api.request("GET", track_path + "/audio", token=ta,
            headers={"Range": value, "If-Range": '"' + digest + '"'}, status=206)
        assert body == expected and int(headers["content-length"]) == len(expected)
        assert headers["content-range"].endswith("/" + str(len(audio)))
    body, _ = api.request("GET", track_path + "/audio", token=ta,
        headers={"Range": "bytes=117-", "If-Range": '"stale"'})
    assert body == audio
    for value in ["bytes=-0", "bytes=999999-", "bytes=4-2", "bytes=0-1,3-4"]:
        _, headers = api.request("GET", track_path + "/audio", token=ta,
                                headers={"Range": value}, status=416)
        assert headers["content-range"] == "bytes */" + str(len(audio))
    track = api.json("PATCH", track_path, {"revision": track["revision"],
        "title": "Renamed", "track_number": 4, "disc_number": 1}, token=ta)
    api.json("PATCH", track_path, {"revision": track["revision"] - 1, "title": "stale"}, token=ta, status=409)
    track = api.json("PATCH", track_path, {"revision": track["revision"], "track_number": None}, token=ta)
    assert track["track_number"] is None and track["disc_number"] == 1
    playlist = api.json("POST", "/api/v1/playlists", {"name": "Duplicates"}, token=ta)
    pp = "/api/v1/playlists/" + playlist["id"]
    entries = [{"id": uid(), "track_id": track["id"]} for _ in range(2)]
    payload = {"revision": playlist["revision"], "name": "Duplicates", "entries": entries}
    api.json("PUT", pp, payload, token=tb, status=404)
    api.json("DELETE", pp + "?revision=" + str(playlist["revision"]), token=tb, status=404)
    playlist = api.json("PUT", pp, payload, token=ta)
    assert playlist["entries"] == entries
    api.json("PUT", pp, payload, token=ta, status=409)
    other_playlist = api.json("POST", "/api/v1/playlists", {"name": "Other"}, token=tb)
    api.json("PUT", "/api/v1/playlists/" + other_playlist["id"], {
        "revision": other_playlist["revision"], "name": "Other", "entries": entries}, token=tb, status=400)
    snapshot = api.json("GET", "/api/v1/library", token=ta)
    cursor = snapshot["cursor"]
    assert len(snapshot["tracks"]) == 1 and snapshot["playlists"][0]["entries"] == entries
    assert api.json("GET", "/api/v1/library", token=tb)["tracks"] == []
    assert api.json("GET", "/api/v1/library?cursor=" + str(cursor), token=ta)["tracks"] == []
    start = int(time.time() * 1000) - 20000
    session = uid()
    def event(started, listened=1000):
        return {"id": uid(), "device_id": device_a, "session_id": session,
                "track_id": track["id"], "started_at": started,
                "ended_at": started + listened, "listened_ms": listened,
                "timezone_offset_minutes": 0}
    events = [event(start), event(start + 1000)]
    ack = api.json("POST", "/api/v1/listening-events", {"events": events}, token=ta)
    assert ack["acknowledged_ids"] == [e["id"] for e in events]
    api.json("POST", "/api/v1/listening-events", {"events": list(reversed(events))}, token=ta)
    stats = api.json("GET", "/api/v1/stats", token=ta)
    assert stats["listened_ms"] == 2000 and stats["play_count"] == 1
    assert stats["history"][0]["counted_play"] is True
    assert stats["top_tracks"][0]["id"] == track["id"]
    assert stats["top_artists"][0]["name"] == "" and stats["top_albums"][0]["name"] == ""
    assert api.json("GET", "/api/v1/stats", token=tb)["listened_ms"] == 0
    api.json("POST", "/api/v1/listening-events", {"events": events}, token=tb, status=400)
    changed = dict(events[0], listened_ms=999)
    api.json("POST", "/api/v1/listening-events", {"events": [changed]}, token=ta, status=409)
    invalid = dict(event(start + 3000), device_id=uid())
    api.json("POST", "/api/v1/listening-events", {"events": [event(start + 2000), invalid]}, token=ta, status=400)
    assert api.json("GET", "/api/v1/stats", token=ta)["listened_ms"] == 2000, "batch must roll back"
    first = api.json("GET", f"/api/v1/stats?from={start}&to={start+1000}", token=ta)
    second = api.json("GET", f"/api/v1/stats?from={start+1000}&to={start+2000}", token=ta)
    assert first["play_count"] == 0 and second["play_count"] == 1
    api.json("DELETE", track_path, token=ta, status=204)
    delta = api.json("GET", "/api/v1/library?cursor=" + str(cursor), token=ta)
    assert delta["deleted_track_ids"] == [track["id"]] and delta["playlists"][0]["entries"] == []
    api.json("POST", "/api/v1/listening-events", {"events": [event(start + 2000)]}, token=ta)
    assert api.json("GET", "/api/v1/stats", token=ta)["listened_ms"] == 3000
    rotated = api.json("POST", "/api/v1/auth/refresh", {"refresh_token": a["refresh_token"]})
    api.json("POST", "/api/v1/auth/refresh", {"refresh_token": a["refresh_token"]}, status=401)
    api.json("GET", "/api/v1/library", token=ta, status=401)
    api.json("POST", "/api/v1/auth/logout", {"refresh_token": rotated["refresh_token"]},
             token=rotated["access_token"], status=204)
    api.json("POST", "/api/v1/auth/refresh", {"refresh_token": rotated["refresh_token"]}, status=401)
    api.json("GET", "/api/v1/library", token=tb)
    print(f"PASS: {api.checks} real TCP requests: WAV uploads/receipts, nullable metadata, ranges, "
          "checksums, cursor/tombstones, playlists, atomic events/stats, refresh/logout, two-user isolation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--binary", type=pathlib.Path, help="Use an already built server (skips cargo)")
    args = parser.parse_args()
    if not args.no_build and args.binary is None:
        subprocess.run(["cargo", "build", "--locked", "--manifest-path", str(ROOT / "server/Cargo.toml")], check=True)
    binary = (args.binary or ROOT / "server/target/debug/yun-server").resolve()
    with tempfile.TemporaryDirectory(prefix="yun-api-smoke-") as directory:
        for name in ["alice", "bob"]:
            subprocess.run([str(binary), "--data-dir", directory, "create-user", name,
                            "--password-stdin"], input=PASSWORD + "\n", text=True,
                           check=True, stdout=subprocess.DEVNULL)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        with tempfile.TemporaryFile() as log:
            server = subprocess.Popen([str(binary), "--data-dir", directory, "serve", "--bind",
                f"127.0.0.1:{port}", "--insecure-loopback"], stdout=log, stderr=log)
            try:
                api = API(port)
                for _ in range(100):
                    try:
                        api.json("GET", "/health")
                        break
                    except (OSError, http.client.HTTPException):
                        if server.poll() is not None:
                            raise RuntimeError("server exited before health check")
                        time.sleep(0.05)
                else:
                    raise RuntimeError("server did not become healthy")
                exercise(api)
            except BaseException:
                log.seek(0)
                print(log.read().decode(errors="replace"))
                raise
            finally:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == "__main__":
    main()
