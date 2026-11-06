#!/usr/bin/env python3
# Copyright (c) 2026 Jonathan Hammant. MIT License: see LICENSE at the repository root.
"""Orbital/Taxi call assist for MacCap.

MacCap starts this program for a call and writes the call to it as JSON lines
on stdin (see "Call assist" in MacCap's README). It spots people and company
names in what is said, looks each one up in Orbital with a TaxiQL query from
its config file, and answers on stdout with person and company cards. Ask and
Help get an answer card built from the same facts; no language model is
involved, so the same call gives the same cards.

Python 3.9+ standard library only.
"""

from __future__ import annotations

import argparse
import http.client
import io
import json
import os
import queue
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple

VERSION = "1.0.0"
DEFAULT_CONFIG = "~/.maccap/orbital-taxi.json"
# Tests only: a JSON file of canned Orbital replies, so nothing touches the network.
FAKE_ENV = "ORBITAL_TAXI_FAKE_RESPONSES"
SOURCE = "Orbital"
KINDS = ("person", "company")
MAX_RESPONSE_BYTES = 2_000_000
# MacCap stops the program 5 s after `end`; finish well inside that.
END_GRACE_SECONDS = 3.0
NAMES_PER_LINE = 3
NAMES_PER_REQUEST = 5

DEFAULT_LOOKUPS: List[Dict[str, Any]] = [
    {
        "kind": "person",
        "query": [
            "find { Person(PersonName == {name}) } as {",
            "  name: PersonName",
            "  role: JobTitle",
            "  company: CompanyName",
            "  email: EmailAddress",
            "}",
        ],
        "title": "name",
        "chips": ["role", "company"],
    },
    {
        "kind": "company",
        "query": [
            "find { Company(CompanyName == {name}) } as {",
            "  name: CompanyName",
            "  industry: Industry",
            "  city: CityName",
            "  website: WebsiteUrl",
            "}",
        ],
        "title": "name",
        "chips": ["industry", "city"],
        "link": "website",
    },
]

DEFAULTS: Dict[str, Any] = {
    "orbital_url": "http://localhost:9022",
    "token_env": "ORBITAL_TOKEN",
    "health_path": "/api/actuator/health",
    "timeout_seconds": 4,
    "retry_seconds": 30,
    "max_lookups": 40,
    "watchlist": [],
    "ignore": [],
    "lookups": DEFAULT_LOOKUPS,
}

# Capitalised words that start sentences or fill speech, not names.
STOP_WORDS = set(
    """
    i im i'm i'll i've i'd a an the this that these those there here it its we you your yours
    they them their he she him his her hers our ours my mine me us who whom whose what which
    when where why how and but or so if then because also just well now okay ok yes yeah yep
    no nope not oh hi hello hey thanks thank cheers bye goodbye sure right great good fine
    morning afternoon evening night please sorry maybe actually basically anyway alright cool
    perfect exactly totally really is are was were be been do does did can could would should
    will shall might must have has had let lets get got go going see look say said tell told
    think know mean like in on at for to from with about as by into over after before since
    until while during per via mr mrs ms miss dr prof sir madam monday tuesday wednesday
    thursday friday saturday sunday january february march july september october november
    december today tomorrow yesterday tonight next last every each all any some both either
    neither one two three first second third
    """.split()
)
# Lower-case words allowed inside a name: "Bank of Leeds", "Hollis & Vane".
CONNECTORS = {"of", "&", "de", "da", "di", "du", "del", "der", "van", "von", "la", "le"}
# A name holding one of these is probably a company: look it up as one first.
COMPANY_WORDS = set(
    """
    ltd limited inc llc llp plc gmbh corp corporation company co group holdings logistics
    bank capital partners labs systems technologies technology solutions software consulting
    ventures industries international services foods energy airlines motors media studio
    studios insurance pharma analytics networks
    """.split()
)

_WORD = re.compile(r"[^\W\d_][\w'’\-]*|&")
_STAMP = re.compile(r"^\[\d+:\d{2}(?::\d{2})?\]\s*(?:[^:\n]{1,40}:\s)?")
_PLACEHOLDER = re.compile(r"\{(name|first|last)\}")
_QUOTED_PLACEHOLDER = re.compile(r"""['"]\{(?:name|first|last)\}['"]""")
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")

Fetch = Callable[[str, str, Optional[bytes], Dict[str, str], float], Tuple[int, bytes]]
Emit = Callable[[Dict[str, Any]], None]


class ConfigError(ValueError):
    """The config file can't be used."""


class OrbitalUnavailable(Exception):
    """Orbital didn't answer, or refused the token."""


def log(message: str) -> None:
    """MacCap copies stderr into its log."""
    print(f"orbital-taxi: {message}", file=sys.stderr, flush=True)


# --- TaxiQL -----------------------------------------------------------------


def taxi_string(value: str) -> str:
    """`value` as a TaxiQL string literal, quotes included.

    Taxi keeps escape sequences as written (`\\'` reaches the service as two
    characters), so the literal uses whichever quote the value doesn't hold
    and ordinary names need no escaping: O'Brien goes in as "O'Brien". A
    backslash, or a value holding both quotes, is escaped so the literal can
    never end early. Line breaks can't appear in a literal; they become spaces.
    """
    text = " ".join(_CONTROL.sub(" ", str(value)).split())
    quote = "'" if '"' in text and "'" not in text else '"'
    text = text.replace("\\", "\\\\")
    if quote in text:
        text = text.replace(quote, "\\" + quote)
    return quote + text + quote


def render_query(template: str, name: str) -> str:
    """The template with {name}, {first} and {last} filled in as quoted literals."""
    words = name.split() or [name]
    values = {"name": name, "first": words[0], "last": words[-1]}
    return _PLACEHOLDER.sub(lambda match: taxi_string(values[match.group(1)]), template)


# --- Names ------------------------------------------------------------------


def name_key(name: str) -> str:
    """The same name however it is cased or spaced."""
    return " ".join(name.casefold().split())


def spot_names(text: str) -> List[str]:
    """Runs of two to five capitalised words: "Priya Shah", "Bank of Leeds"."""
    return [name for _, name in spotted(text)]


def spotted(text: str) -> List[Tuple[int, str]]:
    """spot_names, with where in `text` each name starts."""
    found: List[Tuple[int, str]] = []
    run: List[str] = []
    run_start = 0
    last_end = 0

    def close() -> None:
        while run and run[-1].lower() in CONNECTORS:
            run.pop()
        capitals = sum(1 for word in run if word.lower() not in CONNECTORS)
        name = " ".join(run)
        if capitals >= 2 and len(run) <= 5 and all(name != seen for _, seen in found):
            found.append((run_start, name))
        run.clear()

    for match in _WORD.finditer(text):
        if run and text[last_end:match.start()].strip():
            close()  # punctuation in between: "Priya, Shah" is two people
        last_end = match.end()
        word = match.group().replace("’", "'")
        possessive = word.lower().endswith("'s")
        word = (word[:-2] if possessive else word).rstrip("'-")
        lower = word.lower()
        if lower in CONNECTORS:
            if run:
                run.append(word)
            continue
        if word[:1].isupper() and lower not in STOP_WORDS:
            if not run:
                run_start = match.start()
            run.append(word)
            if possessive:
                close()  # "Priya Shah's team": the name ends there
        else:
            close()
    close()
    return found


def find_known(text: str, names: List[str]) -> List[Tuple[int, str]]:
    """Where each of `names` is mentioned in `text`, any case, whole words only."""
    hits = []
    for name in names:
        match = re.search(r"(?<!\w)" + re.escape(name) + r"(?!\w)", text, re.IGNORECASE)
        if match:
            hits.append((match.start(), name))
    return hits


def said(text: Any) -> List[str]:
    """The words of each transcript line, without its `[mm:ss] Who:` prefix."""
    if not isinstance(text, str):
        return []
    lines = (_STAMP.sub("", line).strip() for line in text.splitlines())
    return [line for line in lines if line]


def looks_like_company(name: str) -> bool:
    return any(word.strip(".,").lower() in COMPANY_WORDS for word in name.split())


def join_names(names: List[str]) -> str:
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def number(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


# --- Config -----------------------------------------------------------------


@dataclass
class Lookup:
    """One TaxiQL template and which of its projected fields go where on a card."""

    kind: str
    query: str
    title: str = "name"
    chips: List[str] = field(default_factory=list)
    link: Optional[str] = None


def _strings(value: Any, key: str) -> List[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) and item.strip() for item in value):
        raise ConfigError(f"{key} must be a list of non-empty strings")
    return [item.strip() for item in value]


def _lookup(raw: Any, index: int) -> Lookup:
    where = f"lookups[{index}]"
    if not isinstance(raw, dict):
        raise ConfigError(f"{where} must be an object")
    kind = raw.get("kind")
    if kind not in KINDS:
        raise ConfigError(f"{where}.kind must be one of {', '.join(KINDS)}")
    query = raw.get("query")
    if isinstance(query, list) and all(isinstance(line, str) for line in query):
        query = "\n".join(query)
    if not isinstance(query, str) or not _PLACEHOLDER.search(query):
        raise ConfigError(f"{where}.query must be a string (or list of lines) using {{name}}, {{first}} or {{last}}")
    if _QUOTED_PLACEHOLDER.search(query):
        raise ConfigError(f"{where}.query: write {{name}} bare, not in quotes; it is quoted for you")
    title = raw.get("title", "name")
    link = raw.get("link")
    if not isinstance(title, str) or not (link is None or isinstance(link, str)):
        raise ConfigError(f"{where}.title and .link must be field names")
    chips = _strings(raw.get("chips", []), f"{where}.chips")
    return Lookup(kind=kind, query=query, title=title, chips=chips, link=link)


def parse_config(raw: Dict[str, Any]) -> Dict[str, Any]:
    """Settings over the defaults, checked; `lookups` become Lookup objects."""
    if not isinstance(raw, dict):
        raise ConfigError("the config must be a JSON object")
    config = dict(DEFAULTS)
    config.update({key: value for key, value in raw.items() if not key.startswith("_")})
    unknown = set(config) - set(DEFAULTS)
    if unknown:
        log(f"ignoring unknown settings: {', '.join(sorted(unknown))}")
    url = config["orbital_url"]
    if not isinstance(url, str) or not re.match(r"https?://[^/\s]+", url):
        raise ConfigError("orbital_url must start with http:// or https://")
    config["orbital_url"] = url.rstrip("/")
    if not isinstance(config["health_path"], str) or not config["health_path"].startswith("/"):
        raise ConfigError("health_path must start with /")
    if config["token_env"] is not None and not isinstance(config["token_env"], str):
        raise ConfigError("token_env must be the name of an environment variable")
    for key, low, high in (("timeout_seconds", 0.1, 30), ("retry_seconds", 0, 3600), ("max_lookups", 0, 10_000)):
        value = number(config[key])
        if value is None or not low <= value <= high:
            raise ConfigError(f"{key} must be a number from {low} to {high}")
        config[key] = value
    config["watchlist"] = _strings(config["watchlist"], "watchlist")
    config["ignore"] = _strings(config["ignore"], "ignore")
    lookups = config["lookups"]
    if not isinstance(lookups, list) or not lookups:
        raise ConfigError("lookups must be a non-empty list")
    config["lookups"] = [_lookup(item, index) for index, item in enumerate(lookups)]
    return config


def load_config(path: str) -> Dict[str, Any]:
    """The settings in `path`; with no file there, the defaults."""
    expanded = os.path.expanduser(path)
    try:
        with open(expanded, encoding="utf-8") as handle:
            raw = json.load(handle)
    except FileNotFoundError:
        log(f"no config at {expanded}; using the defaults")
        raw = {}
    except (OSError, ValueError) as error:
        raise ConfigError(f"can't read {expanded}: {error}") from error
    return parse_config(raw)


# --- Orbital ----------------------------------------------------------------


def http_fetch(method: str, url: str, body: Optional[bytes], headers: Dict[str, str],
               timeout: float) -> Tuple[int, bytes]:
    """One HTTP request as (status, body). Raises OrbitalUnavailable when nothing answered."""
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read(MAX_RESPONSE_BYTES)
    except urllib.error.HTTPError as error:
        try:
            payload = error.read(MAX_RESPONSE_BYTES)
        except OSError:
            payload = b""
        return error.code, payload
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as error:
        raise OrbitalUnavailable(str(getattr(error, "reason", error)) or "no reply") from error


def _message(payload: str) -> Optional[str]:
    """The `message` of an Orbital error reply, if it has one."""
    try:
        data = json.loads(payload)
    except ValueError:
        return None
    message = data.get("message") if isinstance(data, dict) else None
    return message if isinstance(message, str) else None


def _records(data: Any) -> List[Dict[str, Any]]:
    """The objects in a reply that hold at least one value."""
    items = data if isinstance(data, list) else [data]
    return [item for item in items
            if isinstance(item, dict) and any(value not in (None, "", [], {}) for value in item.values())]


class Orbital:
    """Orbital's TaxiQL endpoint, through a fetch function (real HTTP or a test fake)."""

    def __init__(self, url: str, fetch: Fetch, token: Optional[str] = None, timeout: float = 4.0,
                 health_path: str = "/api/actuator/health") -> None:
        self.url = url.rstrip("/")
        self.fetch = fetch
        self.token = token
        self.timeout = timeout
        self.health_path = health_path

    @classmethod
    def from_config(cls, config: Dict[str, Any], fetch: Fetch, environ: Optional[Dict[str, str]] = None) -> "Orbital":
        environ = os.environ if environ is None else environ
        token = environ.get(config["token_env"] or "", "").strip() or None
        return cls(config["orbital_url"], fetch, token, config["timeout_seconds"], config["health_path"])

    def _headers(self, headers: Dict[str, str]) -> Dict[str, str]:
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return headers

    def health(self) -> Optional[str]:
        """None when Orbital answers, otherwise why not. Any reply below 500 counts as up."""
        try:
            status, _ = self.fetch("GET", self.url + self.health_path, None,
                                   self._headers({"Accept": "application/json"}), self.timeout)
        except OrbitalUnavailable as error:
            return str(error) or "no reply"
        if status in (401, 403):
            return f"token refused, HTTP {status}"
        return f"HTTP {status}" if status >= 500 else None

    def query(self, taxiql: str) -> List[Dict[str, Any]]:
        """The records a TaxiQL query found, [] for none. Raises OrbitalUnavailable."""
        headers = self._headers({"Content-Type": "application/taxiql", "Accept": "application/json"})
        status, payload = self.fetch("POST", self.url + "/api/taxiql", taxiql.encode("utf-8"), headers, self.timeout)
        text = payload.decode("utf-8", "replace")
        if status in (401, 403):
            raise OrbitalUnavailable(f"token refused, HTTP {status}")
        if status >= 300:
            message = _message(text)
            # A 5xx with a message is Orbital answering (often a query that doesn't
            # compile against the schema); without one, it is a gateway or an outage.
            if status >= 500 and message is None:
                raise OrbitalUnavailable(f"HTTP {status}")
            log(f"query found nothing (HTTP {status}): {(message or text)[:300]}")
            return []
        try:
            return _records(json.loads(text)) if text.strip() else []
        except ValueError:
            log("Orbital's reply was not JSON")
            return []


# --- Cards ------------------------------------------------------------------


def humanize(key: str) -> str:
    """jobTitle, job_title -> Job title."""
    words = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", key).replace("_", " ").replace("-", " ").split()
    text = " ".join(words).lower() or key
    return text[:1].upper() + text[1:]


def plain(value: Any) -> Optional[str]:
    """A field value as one line of text, or None when it is empty."""
    if value is None or value in ("", [], {}):
        return None
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, str):
        return " ".join(value.split()) or None
    if isinstance(value, list):
        parts = [part for part in (plain(item) for item in value[:10]) if part]
        if len(value) > 10:
            parts.append(f"{len(value) - 10} more")
        return "; ".join(parts) or None
    if isinstance(value, dict):
        parts = []
        for key, item in value.items():
            text = plain(item)
            if text:
                parts.append(f"{humanize(key)}: {text}")
        return ", ".join(parts) or None
    return str(value)


@dataclass
class Found:
    """What Orbital knows about one name."""

    name: str
    kind: str
    title: str
    chips: List[str]
    fields: List[Tuple[str, str]]
    link: Optional[str] = None
    link_label: str = "Link"
    more: int = 0


def to_found(lookup: Lookup, name: str, records: List[Dict[str, Any]]) -> Optional[Found]:
    """The record that best matches `name`, shaped for a card; None if there is none."""
    if not records:
        return None
    matching = (record for record in records if name_key(str(record.get(lookup.title) or "")) == name_key(name))
    best = next(matching, records[0])
    chips = [text[:40] for text in (plain(best.get(key)) for key in lookup.chips) if text]
    link = best.get(lookup.link) if lookup.link else None
    fields = []
    for key, value in best.items():
        text = plain(value)
        if text and key not in (lookup.title, lookup.link):
            fields.append((humanize(key), text))
    return Found(
        name=name,
        kind=lookup.kind,
        title=plain(best.get(lookup.title)) or name,
        chips=chips,
        fields=fields,
        link=link if isinstance(link, str) and re.match(r"https?://", link) else None,
        link_label=humanize(lookup.link) if lookup.link else "Link",
        more=len(records) - 1,
    )


def card_body(found: Found) -> str:
    lines = [f"- **{label}:** {text}" for label, text in found.fields]
    if found.more:
        lines.append(f"\n_{found.more} more {'match' if found.more == 1 else 'matches'} in Orbital._")
    return "\n".join(lines) or "In Orbital, with no other details."


def answer_section(found: Found) -> str:
    lines = [f"### {found.title}", " · ".join([found.kind.capitalize()] + found.chips), "", card_body(found)]
    if found.link:
        lines += ["", f"[{found.link_label}]({found.link})"]
    return "\n".join(lines)


def card_id(name: str) -> str:
    return "orbital-" + re.sub(r"\W+", "-", name_key(name)).strip("-")


# --- The assist -------------------------------------------------------------

UNAVAILABLE = object()  # Orbital couldn't be asked; unlike None ("nothing found"), not remembered


class Assist:
    """Follows one call: MacCap's events in, cards out through `emit`."""

    def __init__(self, config: Dict[str, Any], orbital: Orbital, emit: Emit,
                 clock: Callable[[], float] = time.monotonic, problem: Optional[str] = None) -> None:
        self.config = config
        self.orbital = orbital
        self.emit = emit
        self.clock = clock
        self.problem = problem  # a config error: nothing can be looked up this call
        self.offline: Optional[str] = None  # why Orbital can't be reached, while it can't
        self.checked_at: Optional[float] = None
        self.facts: Dict[str, Optional[Found]] = {}  # by name_key; None = Orbital has nothing
        self.carded: set = set()  # names that have had their card this call
        self.line_lookups = 0
        self.stopping = threading.Event()
        self.ignore = {name_key(name) for name in config["ignore"]}

    def handle(self, event: Dict[str, Any]) -> None:
        kind = event.get("type")
        if kind == "start":
            if self.problem:
                self.status(f"Orbital: {self.problem}")
            else:
                self.check()
        elif kind == "line":
            self.on_line(event)
        elif kind in ("ask", "help"):
            self.on_request(event)
        # moment, action, choose and anything newer need nothing from Orbital.

    def status(self, text: str) -> None:
        self.emit({"type": "status", "text": text})

    # Orbital's state: checked at the start, then again at most every
    # retry_seconds while it is away.

    def check(self) -> bool:
        reason = self.orbital.health()
        first = self.checked_at is None
        self.checked_at = self.clock()
        if reason is None:
            if first or self.offline is not None:
                self.status("Orbital: connected")
            self.offline = None
            return True
        self.went_offline(reason, first)
        return False

    def went_offline(self, reason: str, force: bool = False) -> None:
        self.checked_at = self.clock()
        if force or reason != self.offline:
            log(f"Orbital is offline: {reason}")
            self.status(f"Orbital: offline ({reason})")
        self.offline = reason

    def available(self) -> bool:
        if self.problem or self.stopping.is_set():
            return False
        if self.checked_at is None or (self.offline is not None
                                       and self.clock() - self.checked_at >= self.config["retry_seconds"]):
            return self.check()
        return self.offline is None

    def lookup(self, name: str) -> Any:
        """What Orbital knows about `name`: a Found, None for nothing, or UNAVAILABLE.

        Each name is asked about once a call; the answer, even "nothing", is kept.
        """
        key = name_key(name)
        if key in self.facts:
            return self.facts[key]
        if not self.available():
            return UNAVAILABLE
        guess = "company" if looks_like_company(name) else "person"
        for lookup in sorted(self.config["lookups"], key=lambda item: item.kind != guess):
            if self.stopping.is_set():
                return UNAVAILABLE
            try:
                records = self.orbital.query(render_query(lookup.query, name))
            except OrbitalUnavailable as error:
                self.went_offline(str(error))
                return UNAVAILABLE
            found = to_found(lookup, name, records)
            if found:
                self.facts[key] = found
                return found
        self.facts[key] = None
        return None

    def mentions(self, text: str) -> List[str]:
        """Names in `text` in the order said: spotted, on the watchlist, or already found."""
        known = self.config["watchlist"] + [found.name for found in self.facts.values() if found]
        hits = [(position, 0, name) for position, name in find_known(text, known)]
        hits += [(position, 1, name) for position, name in spotted(text)]
        names, keys = [], set()
        for _, _, name in sorted(hits):
            key = name_key(name)
            if key not in keys and key not in self.ignore:
                keys.add(key)
                names.append(name)
        return names

    # Lines: one card per name found, "looking" while Orbital is asked.

    def on_line(self, event: Dict[str, Any]) -> None:
        text = event.get("text")
        if not isinstance(text, str):
            return
        at = number(event.get("start"))
        for name in self.mentions(text)[:NAMES_PER_LINE]:
            key = name_key(name)
            if key in self.carded:
                continue
            if key in self.facts:  # found while answering a question
                self.carded.add(key)
                if self.facts[key]:
                    self.emit(self.card(name, self.facts[key], text, at))
                continue
            if self.line_lookups >= self.config["max_lookups"] or not self.available():
                return  # names said now are looked up when said again, once Orbital is back
            self.line_lookups += 1
            self.carded.add(key)
            self.emit(self.card(name, None, text, at))
            found = self.lookup(name)
            if found is UNAVAILABLE:
                self.carded.discard(key)
                self.emit({"type": "remove", "id": card_id(name)})
                return
            if found is None:
                self.emit({"type": "remove", "id": card_id(name)})
            else:
                self.emit(self.card(name, found, text, at))

    def card(self, name: str, found: Optional[Found], quote: str, at: Optional[float]) -> Dict[str, Any]:
        card: Dict[str, Any] = {"type": "card", "id": card_id(name)}
        if found is None:
            card.update(kind="company" if looks_like_company(name) else "person", title=name,
                        body=f"Looking up {name} in Orbital…", state="looking")
        else:
            card.update(kind=found.kind, title=found.title, body=card_body(found), state="ready")
            if found.chips:
                card["chips"] = found.chips
            if found.link:
                card["link"] = found.link
        if quote:
            card["quote"] = quote[:280]
        card["source"] = SOURCE
        if at is not None:
            card["at"] = at
        return card

    # Ask and Help: one answer card, its id the request's.

    def on_request(self, event: Dict[str, Any]) -> None:
        request_id = event.get("id")
        if not isinstance(request_id, str) or not request_id:
            return
        is_help = event.get("type") == "help"
        if is_help:
            part = event.get("part")
            if not event.get("focus"):
                title = "Help with what was just said"
            elif isinstance(part, str) and part:
                title = f"Help with “{part}”"
            else:
                title = "Help with the lines you picked"
        else:
            title = event.get("question") if isinstance(event.get("question"), str) else "Question"
        body, chips = self.answer(self.request_names(event, is_help))
        card: Dict[str, Any] = {"type": "card", "id": request_id, "kind": "answer", "title": title, "body": body,
                                "source": SOURCE, "state": "ready", "pinned": True}
        if chips:
            card["chips"] = chips
        at = number(event.get("at"))
        if at is not None:
            card["at"] = at
        self.emit(card)

    def request_names(self, event: Dict[str, Any], is_help: bool) -> List[str]:
        """Who a request is about: the first of these places that names anyone."""
        focus = said(event.get("focus"))
        recent = said(event.get("transcript"))

        def newest_first(lines: List[str]) -> List[str]:
            return [name for line in reversed(lines) for name in self.mentions(line)]

        if is_help:
            places = ([lambda: newest_first(focus)] if focus
                      else [lambda: newest_first(recent[-8:]), lambda: newest_first(recent[-20:])])
        else:
            question = event.get("question") if isinstance(event.get("question"), str) else ""
            places = [lambda: self.mentions(question), lambda: self.thread_names(event.get("thread")),
                      lambda: newest_first(focus), lambda: newest_first(recent[-20:])]
        for place in places:
            names, keys = [], set()
            for name in place():
                if name_key(name) not in keys:
                    keys.add(name_key(name))
                    names.append(name)
            if names:
                return names[:NAMES_PER_REQUEST]
        return []

    def thread_names(self, thread: Any) -> List[str]:
        """Names in a follow-up's earlier questions, and the ones its answers found."""
        if not isinstance(thread, list):
            return []
        found = [item.name for item in self.facts.values() if item]
        names: List[str] = []
        for turn in reversed(thread):
            if isinstance(turn, dict):
                names += self.mentions(str(turn.get("question") or ""))
                names += [name for _, name in sorted(find_known(str(turn.get("answer") or ""), found))]
        return names

    def answer(self, names: List[str]) -> Tuple[str, List[str]]:
        """The Markdown answer about `names`, and chips naming what was found."""
        if self.problem:
            return f"Orbital isn't set up ({self.problem}), so nothing could be looked up.", []
        if not names:
            return "I didn't catch a person or company name in that, so there was nothing to look up in Orbital.", []
        found: List[Found] = []
        missing: List[str] = []
        unasked: List[str] = []
        for name in names:
            result = self.lookup(name)
            if result is UNAVAILABLE:
                unasked.append(name)
            elif result is None:
                missing.append(name)
            elif all((item.kind, item.title) != (result.kind, result.title) for item in found):
                found.append(result)
        parts = [answer_section(item) for item in found]
        if missing:
            parts.append(f"Nothing in Orbital for {join_names(missing)}.")
        if unasked:
            why = ("the call ended first" if self.stopping.is_set()
                   else f"Orbital is offline: {self.offline or 'no reply'}")
            parts.append(f"Couldn't look up {join_names(unasked)} ({why}).")
        return "\n\n".join(parts), [item.title for item in found][:4]


# --- Running ----------------------------------------------------------------


class Emitter:
    """Writes one JSON message per line to MacCap, flushed at once."""

    def __init__(self, stream: Any) -> None:
        self.stream = stream
        self.lock = threading.Lock()

    def __call__(self, message: Dict[str, Any]) -> None:
        line = json.dumps(message, separators=(",", ":"))
        with self.lock:
            try:
                self.stream.write(line + "\n")
                self.stream.flush()
            except (OSError, ValueError):
                pass  # MacCap has stopped reading; the call is still recorded


def run(assist: Assist, stdin: Any, grace: float = END_GRACE_SECONDS) -> int:
    """Reads MacCap's events until `end` (or stdin closes) and returns the exit status.

    Lookups happen on a worker thread so `end` is seen at once. Events that
    came before it are still handled if that takes less than `grace` seconds
    (a replayed recording sends its lines and questions in a burst); after
    that the worker stops asking Orbital.
    """
    events: "queue.Queue[Optional[Dict[str, Any]]]" = queue.Queue()

    def work() -> None:
        while True:
            event = events.get()
            if event is None:
                return
            try:
                assist.handle(event)
            except Exception as error:  # one bad event must not end the assist
                log(f"skipped a {event.get('type')} event: {error!r}")

    worker = threading.Thread(target=work, name="orbital-lookups", daemon=True)
    worker.start()
    while True:
        line = stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            log(f"skipped a line that isn't JSON: {line[:120]}")
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "end":
            break
        events.put(event)
    events.put(None)
    worker.join(grace)
    assist.stopping.set()
    return 0


def fake_fetch(path: str) -> Fetch:
    """Canned Orbital replies from a JSON file, for tests only: no network.

    {"down": false, "health_status": 200,
     "replies": [{"contains": ["Person(", "Priya Shah"], "status": 200, "body": {...}}]}
    A query matching no reply gets an empty list.
    """
    with open(path, encoding="utf-8") as handle:
        script = json.load(handle)

    def fetch(method: str, url: str, body: Optional[bytes], headers: Dict[str, str],
              timeout: float) -> Tuple[int, bytes]:
        if script.get("down"):
            raise OrbitalUnavailable("connection refused")
        if method == "GET":
            return int(script.get("health_status", 200)), b'{"status":"UP"}'
        query = (body or b"").decode("utf-8")
        for reply in script.get("replies", []):
            if all(part in query for part in reply.get("contains", [])):
                return int(reply.get("status", 200)), json.dumps(reply.get("body")).encode("utf-8")
        return 200, b"[]"

    log(f"using canned Orbital replies from {path}")
    return fetch


def try_lookup(config: Dict[str, Any], orbital: Orbital, name: str) -> int:
    """--lookup: show each query sent, what came back and the card it makes."""
    reason = orbital.health()
    if reason:
        print(f"Orbital is offline ({reason})")
        return 1
    guess = "company" if looks_like_company(name) else "person"
    for lookup in sorted(config["lookups"], key=lambda item: item.kind != guess):
        query = render_query(lookup.query, name)
        print(f"--- {lookup.kind} query\n{query}")
        try:
            records = orbital.query(query)
        except OrbitalUnavailable as error:
            print(f"Orbital is offline ({error})")
            return 1
        print(f"--- {len(records)} record(s)")
        if records:
            print(json.dumps(records[0], indent=2, ensure_ascii=False))
        found = to_found(lookup, name, records)
        if found:
            assist = Assist(config, orbital, lambda message: None)
            print("--- card")
            print(json.dumps(assist.card(name, found, "", None), indent=2, ensure_ascii=False))
            return 0
    print("--- nothing found: the card would be removed")
    return 1


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="orbital_assist.py",
        description="MacCap call assist: looks up the people and companies said on a call in Orbital "
                    "(TaxiQL) and shows them as cards. MacCap runs it as assist_command and talks JSON "
                    "lines on stdin and stdout.",
        epilog="The bearer token, if Orbital needs one, is read from the environment variable named by "
               "token_env (default ORBITAL_TOKEN). Example config: examples/orbital-taxi.example.json.",
    )
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="settings file (default: %(default)s)")
    parser.add_argument("--check", action="store_true", help="check that Orbital answers, print the status and exit")
    parser.add_argument("--lookup", metavar="NAME", help="look NAME up, print the queries, replies and card, and exit")
    parser.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    args = parser.parse_args(argv)

    problem = None
    try:
        config = load_config(args.config)
    except ConfigError as error:
        log(f"config error: {error}")
        problem = f"config error: {error}"
        config = parse_config({})
    fetch = fake_fetch(os.environ[FAKE_ENV]) if os.environ.get(FAKE_ENV) else http_fetch
    orbital = Orbital.from_config(config, fetch)

    if args.check or args.lookup:
        if problem:
            print(problem, file=sys.stderr)
            return 2
        if args.lookup:
            return try_lookup(config, orbital, args.lookup)
        reason = orbital.health()
        print(f"Orbital: offline ({reason})" if reason else f"Orbital: connected ({orbital.url})")
        return 1 if reason else 0

    stdin = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace")
    emit = Emitter(sys.stdout)
    status = run(Assist(config, orbital, emit, problem=problem), stdin)
    with emit.lock:  # no message is cut in half by leaving
        try:
            sys.stdout.flush()
        except OSError:
            # MacCap closed the pipe: keep Python's exit flush from complaining.
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        if threading.active_count() > 1:
            # A lookup is still waiting on Orbital. Leave now rather than let the
            # interpreter's shutdown wait on, or trip over, that thread's stdout.
            os._exit(status)
    return status


if __name__ == "__main__":
    sys.exit(main())
