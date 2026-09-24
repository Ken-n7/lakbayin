"""Thin Supabase client for the classroom simulation.

Deliberately not the Godot client: the rules being tested live in Postgres --
the RPCs and the RLS policies -- and this reaches them by exactly the same HTTP
the game uses. The Godot layer has its own checks; forty Godot processes on a
5GB laptop is a memory test, not a game test.
"""
import json
import os
import time
import urllib.error
import urllib.request

URL = os.environ["SUPABASE_URL"].rstrip("/")
KEY = os.environ["SUPABASE_ANON_KEY"]


class Api:
    def __init__(self, label=""):
        self.token = None
        self.user = None
        self.label = label
        self.calls = []          # (what, seconds, ok)

    # --- plumbing ---------------------------------------------------------
    def _call(self, method, path, body=None, what=""):
        headers = {
            "apikey": KEY,
            "Authorization": f"Bearer {self.token or KEY}",
            "Content-Type": "application/json",
            "Prefer": "return=representation",
        }
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(URL + path, data=data, headers=headers, method=method)
        started = time.time()
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read().decode()
            took = time.time() - started
            self.calls.append((what or path, took, True))
            return json.loads(raw) if raw.strip() else None
        except urllib.error.HTTPError as e:
            took = time.time() - started
            self.calls.append((what or path, took, False))
            detail = e.read().decode()[:200]
            raise ApiError(f"{e.code} {detail}") from None
        except Exception as e:                       # timeouts, resets
            self.calls.append((what or path, time.time() - started, False))
            raise ApiError(str(e)) from None

    # --- auth -------------------------------------------------------------
    def sign_up(self, email, username, password, role):
        d = self._call("POST", "/auth/v1/signup", {
            "email": email, "password": password,
            "data": {"username": username, "role": role},
        }, what="sign_up")
        self.token = d.get("access_token")
        self.user = (d.get("user") or {}).get("id")
        return self.token is not None

    def sign_in(self, email, password):
        d = self._call("POST", "/auth/v1/token?grant_type=password",
                       {"email": email, "password": password}, what="sign_in")
        self.token = d.get("access_token")
        self.user = (d.get("user") or {}).get("id")
        return self.token is not None

    # --- rest -------------------------------------------------------------
    def get(self, path, what=""):
        return self._call("GET", "/rest/v1/" + path, what=what or path.split("?")[0])

    def post(self, path, body, what=""):
        return self._call("POST", "/rest/v1/" + path, body, what=what or path)

    def patch(self, path, body, what=""):
        return self._call("PATCH", "/rest/v1/" + path, body, what=what or path)

    def rpc(self, fn, args):
        return self._call("POST", "/rest/v1/rpc/" + fn, args, what=fn)


class ApiError(Exception):
    pass
