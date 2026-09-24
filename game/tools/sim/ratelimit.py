#!/usr/bin/env python3
"""How many auth requests does this project actually allow in a window?

The dashboard value cannot be read with the project keys -- that needs a
management token -- so this measures it instead. It signs IN repeatedly with
one existing account, which the same limit covers ("sign-up and sign-in
requests") while creating no new users, and counts how many land before 429.

    SUPABASE_URL=... SUPABASE_ANON_KEY=... python3 ratelimit.py <email>
"""
import sys
import time

from api import Api, ApiError

email = sys.argv[1] if len(sys.argv) > 1 else "device@numxventure-test.dev"
password = "letmein123"
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 400

print(f"signing in as {email} until refused (cap {limit})")
ok = 0
for i in range(limit):
    try:
        Api().sign_in(email, password)
        ok += 1
    except ApiError as e:
        if "429" in str(e):
            print(f"\nrefused after {ok} successful sign-ins")
            print("that is the live limit for this 5-minute window")
            sys.exit(0)
        print(f"\nunexpected failure after {ok}: {e}")
        sys.exit(1)
    if ok % 25 == 0:
        print(f"  {ok} ok", flush=True)
print(f"\n{ok} sign-ins all succeeded without a 429 -- the limit is at least {ok}")
