# Copyright (c) 2026 Jonathan Hammant. MIT License: see LICENSE at the repository root.
"""Tests for orbital_assist.py. No sockets: Orbital is a fake fetch function.

Run: python3 -m unittest -v test_orbital_assist
"""

import io
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import orbital_assist as oa  # noqa: E402

SCRIPT = HERE / "orbital_assist.py"
EXAMPLE = HERE / "examples" / "orbital-taxi.example.json"

PRIYA = {"name": "Priya Shah", "role": "Head of Operations", "company": "Northwind Logistics",
         "email": "priya.shah@example.com"}
NORTHWIND = {"name": "Northwind Logistics", "industry": "Freight", "city": "Leeds",
             "website": "https://northwind.example.com"}
REPLIES = [
    (["Person(", '"Priya Shah"'], 200, PRIYA),
    (["Company(", '"Northwind Logistics"'], 200, NORTHWIND),
]

# What MacCap's AssistCard decodes (README "Call assist", Sources/Assist.swift).
CARD_KINDS = {"brief", "person", "company", "answer", "watchout", "commitment", "question", "screen", "coach", "note"}
CARD_FIELDS = {"type", "id", "kind", "title", "chips", "quote", "body", "detail", "link", "source", "at", "state",
               "pinned", "action", "parent"}
MESSAGE_TYPES = {"card", "remove", "status", "context", "speaker"}

# Taxi.g4's StringLiteral (single-line forms) and EscapeSequence.
TAXI_LITERAL = re.compile(r"""^(?:"(?:[^"\\\r\n]|\\[btnfr"'\\])*"|'(?:[^'\\\r\n]|\\[btnfr"'\\])*')$""")


class FakeFetch:
    """Stands in for HTTP: canned replies chosen by substrings of the query; every call recorded."""

    def __init__(self, replies=REPLIES, health=200, down=False):
        self.replies = list(replies)
        self.health = health
        self.down = down
        self.calls = []

    def __call__(self, method, url, body, headers, timeout):
        self.calls.append({"method": method, "url": url, "body": body, "headers": headers})
        if self.down:
            raise oa.OrbitalUnavailable("connection refused")
        if method == "GET":
            return self.health, b'{"status":"UP"}'
        query = body.decode("utf-8")
        for parts, status, payload in self.replies:
            if all(part in query for part in parts):
                return status, json.dumps(payload).encode("utf-8")
        return 200, b"[]"

    def queries(self):
        return [call["body"].decode("utf-8") for call in self.calls if call["method"] == "POST"]


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def make_assist(fetch=None, clock=None, environ=None, **settings):
    fetch = fetch or FakeFetch()
    config = oa.parse_config(settings)
    out = []
    orbital = oa.Orbital.from_config(config, fetch, environ=environ or {})
    assist = oa.Assist(config, orbital, out.append, clock=clock or Clock())
    return assist, out, fetch


def line(text, start=12.0, stem="system"):
    return {"type": "line", "stem": stem, "speaker": "Them", "text": text, "start": start, "end": start + 3}


class MessageShape:
    """Checks a message the way MacCap reads it."""

    def assert_message(self, message):
        self.assertIn(message.get("type"), MESSAGE_TYPES)
        json.loads(json.dumps(message))  # plain JSON values only
        if message["type"] == "card":
            self.assertLessEqual(set(message), CARD_FIELDS, "a field MacCap doesn't know")
            self.assertIsInstance(message["id"], str)
            self.assertIn(message["kind"], CARD_KINDS)
            self.assertIsInstance(message["title"], str)
            for key in ("quote", "body", "detail", "link", "source", "action", "parent"):
                if key in message:
                    self.assertIsInstance(message[key], str, key)
            if "chips" in message:
                self.assertTrue(all(isinstance(chip, str) for chip in message["chips"]))
            if "at" in message:
                self.assertIsInstance(message["at"], (int, float))
            if "state" in message:
                self.assertIn(message["state"], {"looking", "ready", "failed"})
            if "pinned" in message:
                self.assertIsInstance(message["pinned"], bool)
        elif message["type"] == "remove":
            self.assertIsInstance(message["id"], str)
        elif message["type"] == "status":
            self.assertIsInstance(message["text"], str)

    def cards(self, out, **match):
        return [m for m in out if m["type"] == "card" and all(m.get(k) == v for k, v in match.items())]

    def statuses(self, out):
        return [m["text"] for m in out if m["type"] == "status"]


class TaxiStringTest(unittest.TestCase):
    def test_plain_name_is_double_quoted(self):
        self.assertEqual(oa.taxi_string("Priya Shah"), '"Priya Shah"')

    def test_apostrophe_needs_no_escape_so_the_value_arrives_whole(self):
        # Taxi keeps escapes verbatim, so "O\'Brien" would reach the service with a backslash.
        self.assertEqual(oa.taxi_string("Dana O'Brien"), '"Dana O\'Brien"')

    def test_double_quotes_switch_to_single_quotes(self):
        self.assertEqual(oa.taxi_string('The "Northwind" Group'), "'The \"Northwind\" Group'")

    def test_both_quotes_are_escaped(self):
        self.assertEqual(oa.taxi_string("It's \"Northwind\""), '"It\'s \\"Northwind\\""')

    def test_backslashes_are_escaped(self):
        self.assertEqual(oa.taxi_string("North\\wind"), '"North\\\\wind"')
        self.assertEqual(oa.taxi_string("trailing\\"), '"trailing\\\\"')

    def test_line_breaks_become_spaces(self):
        self.assertEqual(oa.taxi_string("Priya\nShah\r\n\tLtd"), '"Priya Shah Ltd"')

    def test_hostile_values_stay_one_literal(self):
        values = ['") } find { Secret[] } //', "') } find { Secret[] }", '\\', '\\"', "\\'", 'a"b\'c\\d',
                  '"""', "\n\"", "Seán Ó Briain", ""]
        for value in values:
            with self.subTest(value=value):
                self.assertRegex(oa.taxi_string(value), TAXI_LITERAL)

    def test_render_fills_placeholders_and_leaves_taxiql_braces(self):
        template = ("given { FirstName = {first}  LastName = {last} } "
                    "find { Person(PersonName == {name}) } as { name: PersonName }")
        self.assertEqual(
            oa.render_query(template, 'Dana "DJ" Whitlock'),
            "given { FirstName = \"Dana\"  LastName = \"Whitlock\" } "
            "find { Person(PersonName == 'Dana \"DJ\" Whitlock') } as { name: PersonName }",
        )


class SpotNamesTest(unittest.TestCase):
    def test_capitalised_runs(self):
        self.assertEqual(oa.spot_names("I spoke to Priya Shah at Northwind Logistics yesterday."),
                         ["Priya Shah", "Northwind Logistics"])

    def test_sentence_starters_and_greetings_are_not_names(self):
        self.assertEqual(oa.spot_names("Yesterday Priya Shah called. Thanks Dana Whitlock."),
                         ["Priya Shah", "Dana Whitlock"])

    def test_possessive_ends_the_name(self):
        self.assertEqual(oa.spot_names("Priya Shah's team runs Tailspin Freight’s depot"),
                         ["Priya Shah", "Tailspin Freight"])

    def test_connectors_inside_a_name(self):
        self.assertEqual(oa.spot_names("money from the Bank of Leeds and Hollis & Vane"),
                         ["Bank of Leeds", "Hollis & Vane"])

    def test_punctuation_splits_runs(self):
        self.assertEqual(oa.spot_names("Priya, Shah, and Dana."), [])

    def test_single_words_and_lower_case_are_ignored(self):
        self.assertEqual(oa.spot_names("Priya said priya shah would call"), [])

    def test_long_runs_are_ignored(self):
        self.assertEqual(oa.spot_names("Northwind Logistics Freight Leeds Depot Operations"), [])

    def test_transcript_prefix_is_stripped(self):
        self.assertEqual(oa.said("[01:05] Them: Priya Shah here\n[123:45] You: hi\n"), ["Priya Shah here", "hi"])


class LineCardsTest(MessageShape, unittest.TestCase):
    def test_hit_sends_looking_then_ready_with_the_same_id(self):
        assist, out, _ = make_assist()
        assist.handle({"type": "start", "v": 1})
        assist.handle(line("I met Priya Shah last week.", start=42.5))
        for message in out:
            self.assert_message(message)
        self.assertEqual(self.statuses(out), ["Orbital: connected"])
        looking, ready = self.cards(out)
        self.assertEqual(looking["id"], ready["id"])
        self.assertEqual((looking["state"], ready["state"]), ("looking", "ready"))
        self.assertEqual(ready["kind"], "person")
        self.assertEqual(ready["title"], "Priya Shah")
        self.assertEqual(ready["chips"], ["Head of Operations", "Northwind Logistics"])
        self.assertEqual(ready["source"], "Orbital")
        self.assertEqual(ready["at"], 42.5)
        self.assertEqual(ready["quote"], "I met Priya Shah last week.")
        self.assertIn("- **Email:** priya.shah@example.com", ready["body"])

    def test_each_name_is_looked_up_once_per_call(self):
        assist, out, fetch = make_assist()
        assist.handle(line("Priya Shah joined."))
        posts = len(fetch.queries())
        for start in (20.0, 30.0, 40.0):
            assist.handle(line("As priya shah said, PRIYA SHAH is right.", start=start))
            assist.handle(line("Priya Shah again.", start=start + 1))
        self.assertEqual(len(fetch.queries()), posts)
        self.assertEqual(len(self.cards(out)), 2)  # one looking, one ready

    def test_nothing_found_removes_the_card(self):
        assist, out, fetch = make_assist()
        assist.handle(line("Dana Whitlock might join."))
        looking, removed = out[-2:]
        self.assertEqual(looking["state"], "looking")
        self.assertEqual(removed, {"type": "remove", "id": looking["id"]})
        self.assertEqual(len(fetch.queries()), 2)  # tried as a person, then as a company
        assist.handle(line("Dana Whitlock again."))
        self.assertEqual(len(fetch.queries()), 2)

    def test_company_looking_name_is_tried_as_a_company_first(self):
        assist, out, fetch = make_assist()
        assist.handle(line("We ship with Northwind Logistics."))
        self.assertIn("Company(", fetch.queries()[0])
        self.assertEqual(len(fetch.queries()), 1)
        self.assertEqual([c["kind"] for c in self.cards(out)], ["company", "company"])
        self.assertEqual(self.cards(out)[-1]["link"], "https://northwind.example.com")

    def test_a_miss_as_a_person_can_still_be_a_company(self):
        tailspin = {"name": "Tailspin Freight", "city": "York"}
        fetch = FakeFetch(replies=[(["Company(", "Tailspin Freight"], 200, tailspin)])
        assist, out, _ = make_assist(fetch)
        assist.handle(line("Tailspin Freight called."))
        looking, ready = self.cards(out)
        self.assertEqual((looking["kind"], ready["kind"]), ("person", "company"))

    def test_watchlist_names_match_any_case_even_one_word(self):
        fetch = FakeFetch(replies=[(["Company(", '"Tailspin"'], 200, {"name": "Tailspin", "industry": "Air"})])
        assist, out, _ = make_assist(fetch, watchlist=["Tailspin"])
        assist.handle(line("we fly tailspin to the depot"))
        self.assertEqual(self.cards(out)[-1]["title"], "Tailspin")

    def test_ignored_names_are_never_looked_up(self):
        assist, out, fetch = make_assist(ignore=["Alex Rivera"])
        assist.handle(line("This is Alex Rivera speaking."))
        self.assertEqual((out, fetch.queries()), ([], []))

    def test_max_lookups_caps_line_lookups(self):
        assist, out, fetch = make_assist(max_lookups=1)
        assist.handle(line("Dana Whitlock and Priya Shah."))
        self.assertEqual(len(self.cards(out, state="looking")), 1)

    def test_request_goes_out_as_taxiql_with_the_token(self):
        fetch = FakeFetch()
        assist, _, _ = make_assist(fetch, environ={"ORBITAL_TOKEN": "s3cret"})
        assist.handle(line("Priya Shah"))
        post = next(call for call in fetch.calls if call["method"] == "POST")
        self.assertEqual(post["url"], "http://localhost:9022/api/taxiql")
        self.assertEqual(post["headers"]["Content-Type"], "application/taxiql")
        self.assertEqual(post["headers"]["Accept"], "application/json")
        self.assertEqual(post["headers"]["Authorization"], "Bearer s3cret")
        self.assertTrue(post["body"].decode().startswith('find { Person(PersonName == "Priya Shah") } as {'))

    def test_no_token_no_authorization_header(self):
        fetch = FakeFetch()
        make_assist(fetch)[0].handle(line("Priya Shah"))
        self.assertTrue(all("Authorization" not in call["headers"] for call in fetch.calls))

    def test_list_replies_pick_the_matching_record(self):
        other = dict(PRIYA, name="Priya Shahani", role="Driver")
        fetch = FakeFetch(replies=[(["Person("], 200, [other, PRIYA])])
        assist, out, _ = make_assist(fetch)
        assist.handle(line("Priya Shah"))
        ready = self.cards(out)[-1]
        self.assertEqual(ready["chips"][0], "Head of Operations")
        self.assertIn("1 more match", ready["body"])


class RequestsTest(MessageShape, unittest.TestCase):
    def test_ask_is_answered_with_the_request_id(self):
        assist, out, _ = make_assist()
        assist.handle({"type": "ask", "id": "ask-1", "question": "Who is Priya Shah?", "at": 61.0,
                       "transcript": "", "topics": []})
        (answer,) = self.cards(out)
        self.assert_message(answer)
        self.assertEqual((answer["id"], answer["kind"], answer["state"]), ("ask-1", "answer", "ready"))
        self.assertEqual(answer["title"], "Who is Priya Shah?")
        self.assertIs(answer["pinned"], True)
        self.assertEqual(answer["chips"], ["Priya Shah"])
        self.assertIn("### Priya Shah\nPerson · Head of Operations · Northwind Logistics", answer["body"])

    def test_ask_in_lower_case_uses_names_already_found(self):
        assist, out, fetch = make_assist()
        assist.handle(line("Priya Shah from Northwind Logistics."))
        posts = len(fetch.queries())
        assist.handle({"type": "ask", "id": "ask-2", "question": "what does priya shah do?", "transcript": ""})
        self.assertIn("Head of Operations", out[-1]["body"])
        self.assertEqual(len(fetch.queries()), posts)

    def test_help_uses_what_was_just_said(self):
        assist, out, _ = make_assist()
        transcript = "[00:10] You: Morning.\n[00:12] Them: We moved freight to Northwind Logistics."
        assist.handle({"type": "help", "id": "help-1", "at": 14.0, "transcript": transcript, "topics": []})
        answer = out[-1]
        self.assert_message(answer)
        self.assertEqual((answer["id"], answer["kind"]), ("help-1", "answer"))
        self.assertEqual(answer["title"], "Help with what was just said")
        self.assertIn("### Northwind Logistics", answer["body"])
        self.assertIn("[Website](https://northwind.example.com)", answer["body"])

    def test_help_with_picked_lines_uses_only_them(self):
        assist, out, _ = make_assist()
        assist.handle({"type": "help", "id": "help-2", "transcript": "[00:01] Them: Priya Shah here.",
                       "focus": "[00:30] Them: Northwind Logistics wants a quote.", "part": "Pricing"})
        self.assertEqual(out[-1]["title"], "Help with “Pricing”")
        self.assertEqual(out[-1]["chips"], ["Northwind Logistics"])

    def test_nothing_found_is_said_plainly(self):
        assist, out, _ = make_assist()
        assist.handle({"type": "ask", "id": "ask-3", "question": "Is Dana Whitlock a customer?", "transcript": ""})
        self.assertEqual(out[-1]["body"], "Nothing in Orbital for Dana Whitlock.")
        self.assertNotIn("chips", out[-1])

    def test_no_names_is_said_plainly(self):
        assist, out, _ = make_assist()
        assist.handle({"type": "ask", "id": "ask-4", "question": "what did they say about pricing?",
                       "transcript": "[00:05] Them: pricing is fine"})
        self.assertIn("didn't catch a person or company name", out[-1]["body"])

    def test_follow_up_uses_the_thread(self):
        assist, out, _ = make_assist()
        assist.handle({"type": "ask", "id": "ask-5", "question": "Who is Priya Shah?", "transcript": ""})
        thread = [{"question": "Who is Priya Shah?", "answer": out[-1]["body"]}]
        assist.handle({"type": "ask", "id": "ask-6", "question": "and her email?", "follows": "ask-5",
                       "thread": thread, "transcript": ""})
        self.assertEqual(out[-1]["id"], "ask-6")
        self.assertIn("priya.shah@example.com", out[-1]["body"])

    def test_ask_without_an_id_is_ignored(self):
        assist, out, _ = make_assist()
        assist.handle({"type": "ask", "question": "Who is Priya Shah?"})
        self.assertEqual(out, [])

    def test_other_events_need_no_reply(self):
        assist, out, _ = make_assist()
        for event in ({"type": "moment", "id": "m1", "at": 3, "transcript": "", "auto": False},
                      {"type": "action", "id": "a1", "text": "Send Priya Shah the deck", "at": 4},
                      {"type": "choose", "id": None}, {"type": "something-new"}):
            assist.handle(event)
        self.assertEqual(out, [])


class OfflineTest(MessageShape, unittest.TestCase):
    def test_down_at_start_says_offline_and_carries_on(self):
        fetch = FakeFetch(down=True)
        assist, out, _ = make_assist(fetch)
        assist.handle({"type": "start", "v": 1})
        assist.handle(line("Priya Shah joined."))
        assist.handle({"type": "ask", "id": "ask-1", "question": "Who is Priya Shah?", "transcript": ""})
        for message in out:
            self.assert_message(message)
        self.assertEqual(self.statuses(out), ["Orbital: offline (connection refused)"])
        self.assertEqual(fetch.queries(), [])
        (answer,) = self.cards(out)
        self.assertEqual(answer["id"], "ask-1")
        self.assertIn("Couldn't look up Priya Shah (Orbital is offline: connection refused)", answer["body"])

    def test_refused_token_says_so(self):
        assist, out, _ = make_assist(FakeFetch(health=401))
        assist.handle({"type": "start", "v": 1})
        self.assertEqual(self.statuses(out), ["Orbital: offline (token refused, HTTP 401)"])

    def test_going_down_mid_lookup_removes_the_card(self):
        fetch = FakeFetch()
        assist, out, _ = make_assist(fetch)
        assist.handle({"type": "start", "v": 1})
        fetch.down = True
        assist.handle(line("Priya Shah joined."))
        looking, status, removed = out[-3:]
        self.assertEqual(looking["state"], "looking")
        self.assertEqual(status, {"type": "status", "text": "Orbital: offline (connection refused)"})
        self.assertEqual(removed, {"type": "remove", "id": looking["id"]})
        self.assertNotIn("priya shah", assist.facts)  # not remembered as "nothing found"

    def test_names_said_while_down_are_looked_up_once_it_is_back(self):
        fetch, clock = FakeFetch(down=True), Clock()
        assist, out, _ = make_assist(fetch, clock, retry_seconds=30)
        assist.handle({"type": "start", "v": 1})
        assist.handle(line("Priya Shah joined."))
        fetch.down = False
        clock.now += 10
        assist.handle(line("Priya Shah is here."))
        self.assertEqual(self.cards(out), [])  # not re-checked yet
        clock.now += 30
        assist.handle(line("Priya Shah, hello."))
        self.assertEqual(self.statuses(out)[-1], "Orbital: connected")
        self.assertEqual(self.cards(out)[-1]["state"], "ready")

    def test_error_with_a_message_is_nothing_found_not_offline(self):
        fetch = FakeFetch(replies=[([""], 500, {"message": "No data sources were found that can return Person"})])
        assist, out, _ = make_assist(fetch)
        with mock.patch.object(oa, "log"):
            assist.handle(line("Priya Shah"))
        self.assertEqual(out[-1]["type"], "remove")
        self.assertIsNone(assist.offline)

    def test_gateway_error_is_offline(self):
        fetch = FakeFetch(replies=[([""], 503, None)])
        assist, out, _ = make_assist(fetch)
        with mock.patch.object(oa, "log"):
            assist.handle(line("Priya Shah"))
        self.assertEqual(self.statuses(out), ["Orbital: connected", "Orbital: offline (HTTP 503)"])

    def test_http_fetch_turns_no_reply_into_orbital_unavailable(self):
        refused = urllib.error.URLError(ConnectionRefusedError(61, "Connection refused"))
        with mock.patch.object(oa.urllib.request, "urlopen", side_effect=refused):
            with self.assertRaises(oa.OrbitalUnavailable):
                oa.http_fetch("GET", "http://localhost:9022/api/actuator/health", None, {}, 1.0)

    def test_http_fetch_returns_error_statuses(self):
        error = urllib.error.HTTPError("http://localhost:9022/api/taxiql", 400, "Bad Request", {},
                                       io.BytesIO(b'{"message":"nope"}'))
        with mock.patch.object(oa.urllib.request, "urlopen", side_effect=error):
            self.assertEqual(oa.http_fetch("POST", "http://localhost:9022/api/taxiql", b"x", {}, 1.0),
                             (400, b'{"message":"nope"}'))


class ConfigTest(unittest.TestCase):
    def test_example_config_matches_the_built_in_templates(self):
        example = oa.load_config(str(EXAMPLE))
        self.assertEqual(example["lookups"], oa.parse_config({})["lookups"])

    def test_example_uses_only_safe_hosts(self):
        hosts = re.findall(r"https?://([^/:\"]+)", EXAMPLE.read_text())
        self.assertTrue(hosts)
        self.assertTrue(all(host == "localhost" or host.endswith("example.com") for host in hosts), hosts)

    def test_quoted_placeholder_is_refused(self):
        with self.assertRaisesRegex(oa.ConfigError, "bare"):
            oa.parse_config({"lookups": [{"kind": "person", "query": 'find { Person(PersonName == "{name}") }'}]})

    def test_bad_values_are_refused(self):
        for raw in ({"orbital_url": "localhost:9022"}, {"lookups": []},
                    {"lookups": [{"kind": "deal", "query": "{name}"}]},
                    {"timeout_seconds": 0}, {"watchlist": "Priya Shah"}):
            with self.subTest(raw=raw), self.assertRaises(oa.ConfigError):
                oa.parse_config(raw)

    def test_missing_file_means_defaults(self):
        with mock.patch.object(oa, "log"):
            config = oa.load_config("/nonexistent/orbital-taxi.json")
        self.assertEqual(config["orbital_url"], "http://localhost:9022")


class RunTest(unittest.TestCase):
    def test_end_stops_reading_and_returns_zero(self):
        assist, out, _ = make_assist()
        lines = [{"type": "start", "v": 1}, line("Priya Shah joined."), {"type": "end"}, line("Dana Whitlock")]
        stdin = io.StringIO("".join(json.dumps(event) + "\n" for event in lines))
        started = time.monotonic()
        self.assertEqual(oa.run(assist, stdin), 0)
        self.assertLess(time.monotonic() - started, 5)
        self.assertTrue(assist.stopping.is_set())
        self.assertNotIn("Dana Whitlock", json.dumps(out))
        self.assertEqual(stdin.readline(), json.dumps(lines[-1]) + "\n")  # nothing read after end

    def test_events_before_end_are_still_handled(self):
        # A replayed recording sends everything at once, then `end`.
        assist, out, _ = make_assist()
        lines = [{"type": "start", "v": 1}, line("Priya Shah joined."),
                 {"type": "ask", "id": "ask-1", "question": "Who is Priya Shah?", "transcript": ""}, {"type": "end"}]
        oa.run(assist, io.StringIO("".join(json.dumps(event) + "\n" for event in lines)))
        self.assertEqual([m.get("state") for m in out if m.get("id") == "orbital-priya-shah"], ["looking", "ready"])
        self.assertIn("### Priya Shah", next(m for m in out if m.get("id") == "ask-1")["body"])

    def test_slow_orbital_does_not_hold_up_the_end(self):
        release = threading.Event()
        self.addCleanup(release.set)
        fetch = FakeFetch()

        def slow(method, url, body, headers, timeout):
            if method == "POST":
                release.wait(10)
            return fetch(method, url, body, headers, timeout)

        assist, out, _ = make_assist(slow)
        events = ({"type": "start"}, line("Priya Shah"), {"type": "end"})
        stdin = io.StringIO("".join(json.dumps(event) + "\n" for event in events))
        started = time.monotonic()
        self.assertEqual(oa.run(assist, stdin, grace=0.2), 0)
        self.assertLess(time.monotonic() - started, 2)
        self.assertTrue(assist.stopping.is_set())

    def test_bad_lines_are_skipped(self):
        assist, out, _ = make_assist()
        stdin = io.StringIO('not json\n[1, 2]\n\n{"type": "start", "v": 1}\n')
        with mock.patch.object(oa, "log"):
            self.assertEqual(oa.run(assist, stdin), 0)
        self.assertEqual(out, [{"type": "status", "text": "Orbital: connected"}])

    def test_a_failing_event_does_not_stop_the_assist(self):
        assist, out, _ = make_assist()
        original = assist.on_line
        assist.on_line = mock.Mock(side_effect=[RuntimeError("boom"), None])
        stdin = io.StringIO(json.dumps(line("A B")) + "\n" + json.dumps({"type": "start"}) + "\n")
        with mock.patch.object(oa, "log") as logged:
            self.assertEqual(oa.run(assist, stdin), 0)
        assist.on_line = original
        self.assertIn("boom", logged.call_args_list[0].args[0])
        self.assertEqual(out[-1]["text"], "Orbital: connected")


class EndToEndTest(MessageShape, unittest.TestCase):
    """The script as MacCap runs it: JSON lines in, JSON lines out, Orbital canned."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.config = Path(self.dir.name) / "orbital-taxi.json"
        self.config.write_text(EXAMPLE.read_text())

    def fake(self, **script):
        path = Path(self.dir.name) / "fake.json"
        path.write_text(json.dumps(script))
        env = dict(os.environ, **{oa.FAKE_ENV: str(path)})
        env.pop("ORBITAL_TOKEN", None)
        return env

    def call(self, env, events, close_stdin=True):
        process = subprocess.Popen([sys.executable, str(SCRIPT), "--config", str(self.config)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=env, text=True)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        process.stdin.write("".join(json.dumps(event) + "\n" for event in events))
        process.stdin.flush()
        if close_stdin:
            process.stdin.close()
        started = time.monotonic()
        code = process.wait(timeout=10)
        elapsed = time.monotonic() - started
        if not close_stdin:
            process.stdin.close()
        stdout, stderr = process.stdout.read(), process.stderr.read()
        process.stdout.close()
        process.stderr.close()
        messages = [json.loads(text) for text in stdout.splitlines()]
        for message in messages:
            self.assert_message(message)
        return code, messages, stderr, elapsed

    def test_scripted_call(self):
        env = self.fake(replies=[
            {"contains": ["Person(", '"Priya Shah"'], "body": PRIYA},
            {"contains": ["Company(", '"Northwind Logistics"'], "body": NORTHWIND},
        ])
        transcript = "[00:12] Them: Priya Shah from Northwind Logistics here.\n[00:20] You: Great."
        events = [
            {"type": "start", "v": 1, "started_at": "2026-11-06T10:00:00Z", "session_dir": "/tmp/s", "apps": ["Zoom"]},
            line("Hi, Priya Shah from Northwind Logistics here.", start=12.0),
            line("Priya Shah again.", start=15.0),
            line("Dana Whitlock may join later.", start=18.0),
            {"type": "ask", "id": "ask-1", "question": "Who is Priya Shah?", "at": 25.0,
             "transcript": transcript, "topics": []},
            {"type": "help", "id": "help-2", "at": 30.0, "transcript": transcript, "topics": []},
            {"type": "end"},
        ]
        code, messages, stderr, elapsed = self.call(env, events)
        self.assertEqual(code, 0, stderr)
        self.assertLess(elapsed, 5)
        self.assertEqual(messages[0], {"type": "status", "text": "Orbital: connected"})
        by_id = {}
        for message in messages[1:]:
            by_id.setdefault(message.get("id"), []).append(message)
        self.assertEqual([m["state"] for m in by_id["orbital-priya-shah"]], ["looking", "ready"])
        self.assertEqual([m["state"] for m in by_id["orbital-northwind-logistics"]], ["looking", "ready"])
        self.assertEqual([m["type"] for m in by_id["orbital-dana-whitlock"]], ["card", "remove"])
        self.assertEqual(by_id["ask-1"][0]["kind"], "answer")
        self.assertIn("### Priya Shah", by_id["ask-1"][0]["body"])
        self.assertIn("### Northwind Logistics", by_id["help-2"][0]["body"])

    def test_offline_call_still_answers_and_exits_cleanly(self):
        env = self.fake(down=True)
        events = [{"type": "start", "v": 1}, line("Priya Shah joined."),
                  {"type": "ask", "id": "ask-1", "question": "Who is Priya Shah?", "transcript": ""},
                  {"type": "end"}]
        code, messages, stderr, _ = self.call(env, events)
        self.assertEqual(code, 0, stderr)
        self.assertEqual(messages[0], {"type": "status", "text": "Orbital: offline (connection refused)"})
        self.assertEqual([m["id"] for m in messages if m["type"] == "card"], ["ask-1"])

    def test_end_exits_even_while_stdin_stays_open(self):
        env = self.fake()
        code, messages, stderr, elapsed = self.call(env, [{"type": "start", "v": 1}, {"type": "end"}],
                                                    close_stdin=False)
        self.assertEqual(code, 0, stderr)
        self.assertLess(elapsed, 5)
        self.assertEqual(messages, [{"type": "status", "text": "Orbital: connected"}])

    def test_bad_config_is_a_status_not_a_crash(self):
        self.config.write_text("{not json")
        code, messages, stderr, _ = self.call(self.fake(), [{"type": "start", "v": 1}, line("Priya Shah"),
                                                             {"type": "end"}])
        self.assertEqual(code, 0, stderr)
        self.assertEqual(len(messages), 1)
        self.assertTrue(messages[0]["text"].startswith("Orbital: config error: can't read"))

    def test_help_flag(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertIn("usage: orbital_assist.py", result.stdout)
        self.assertIn("--config", result.stdout)

    def test_lookup_flag_shows_query_and_card(self):
        env = self.fake(replies=[{"contains": ["Person(", '"Priya Shah"'], "body": PRIYA}])
        result = subprocess.run([sys.executable, str(SCRIPT), "--config", str(self.config), "--lookup", "Priya Shah"],
                                capture_output=True, text=True, timeout=10, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('find { Person(PersonName == "Priya Shah") } as {', result.stdout)
        self.assertIn('"state": "ready"', result.stdout)


if __name__ == "__main__":
    unittest.main()
