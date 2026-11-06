# Orbital/Taxi call assist

A MacCap `assist_command` that looks up the people and companies said on a
call in Orbital, through its Taxi semantic layer, and shows what it finds as
cards in MacCap's live window.

```text
"…Priya Shah from Northwind Logistics…"  →  TaxiQL find { Person(…) }  →  Person card
                                         →  TaxiQL find { Company(…) } →  Company card
```

It is one Python file, `orbital_assist.py`, standard library only (Python 3.9
or later). It needs no language model: the same call gives the same cards.

## What it does

- **Start.** It checks that Orbital answers and sets the window's status to
  `Orbital: connected` or `Orbital: offline (why)`. Offline is not fatal:
  MacCap keeps recording, and the assist tries again every 30 s.
- **Each line said.** It spots names: runs of two to five capitalised words
  ("Priya Shah", "Bank of Leeds"), plus any name on your watchlist in any
  case. Each name is looked up once per call. A card shows as `looking`, then
  turns `ready` with what Orbital knows, or is removed if Orbital has nothing.
- **Ask and Help me answer.** The answer card uses the request's id. It holds
  the Orbital facts for the names in the question. If the question names
  nobody, it uses the picked lines, then the last part of the call. If Orbital
  has nothing, the card says so.
- **End.** It finishes what is in hand and exits within 3 s.

It writes notes and errors to stderr, which MacCap copies into
`~/.maccap/maccap.log` with the prefix `assist: orbital-taxi:`.

## Setup

1. Copy the example config and point it at your Orbital:

   ```bash
   cp examples/orbital-taxi.example.json ~/.maccap/orbital-taxi.json
   chmod 600 ~/.maccap/orbital-taxi.json
   ```

   Then set `orbital_url` (default `http://localhost:9022`) and adapt the
   `lookups` to your schema (see below).

2. If Orbital needs a token, put it in the environment variable named by
   `token_env` (default `ORBITAL_TOKEN`). It is sent as
   `Authorization: Bearer <token>`. Never put the token in the config file.

   MacCap is opened from Finder, so it does not see variables exported in
   your shell. Either set it for apps until you log out:

   ```bash
   launchctl setenv ORBITAL_TOKEN "$(security find-generic-password -s orbital-taxi -w)"
   ```

   or start the assist through a small wrapper that reads the Keychain:

   ```bash
   #!/bin/sh
   ORBITAL_TOKEN="$(security find-generic-password -s orbital-taxi -w)"
   export ORBITAL_TOKEN
   exec /usr/bin/python3 /path/to/orbital_assist.py "$@"
   ```

   Store the token once with
   `security add-generic-password -s orbital-taxi -a "$USER" -w`.

3. Add the assist to `~/.maccap/config.json`. Use absolute paths. Apps opened
   from Finder find `/usr/bin/python3`, not a Homebrew one:

   ```json
   {
     "assist_command": [
       "/usr/bin/python3",
       "/path/to/integrations/orbital-taxi/orbital_assist.py",
       "--config",
       "/Users/you/.maccap/orbital-taxi.json"
     ]
   }
   ```

4. Check it from a terminal:

   ```bash
   python3 orbital_assist.py --check
   python3 orbital_assist.py --lookup "Priya Shah"
   ```

   `--check` prints the status the window would show. `--lookup` prints each
   query it sends, the first record Orbital returns and the card it makes.

## The config file

Every key is optional. With no file at all, the defaults below are used.

| Key | Default | What |
| --- | --- | --- |
| `orbital_url` | `http://localhost:9022` | Orbital's base URL. Queries go to `{orbital_url}/api/taxiql`. |
| `token_env` | `ORBITAL_TOKEN` | Environment variable holding the bearer token. Unset or empty: no token is sent. |
| `health_path` | `/api/actuator/health` | Fetched (GET) at the start. Any reply below 500 counts as up; 401 or 403 means the token was refused. |
| `timeout_seconds` | `4` | Per request. |
| `retry_seconds` | `30` | How often to check again while Orbital is offline. |
| `max_lookups` | `40` | Most names looked up from the transcript in one call. Ask and Help are not capped. |
| `watchlist` | `[]` | Names to always look for, matched in any case, one word allowed. |
| `ignore` | `[]` | Names never to look up, such as your own. |
| `lookups` | person, company | The TaxiQL templates (below). |

## Adapting the templates to your Taxi schema

Each entry in `lookups` is one TaxiQL query and a note of which projected
fields go where on the card:

```json
{
  "kind": "person",
  "query": [
    "find { Person(PersonName == {name}) } as {",
    "  name: PersonName",
    "  role: JobTitle",
    "  company: CompanyName",
    "  email: EmailAddress",
    "}"
  ],
  "title": "name",
  "chips": ["role", "company"],
  "link": "profileUrl"
}
```

- `kind` is `person` or `company`, the card type.
- `query` is a string, or a list of lines joined with newlines.
- `title` is the field used as the card's title (default `name`). Without it,
  the name as said is used.
- `chips` are fields shown as chips. `link` is a field holding an `http(s)` URL,
  shown as the card's Open button.
- Every other non-empty field is listed in the card's body, in projection order.

The default templates assume a schema like this one (HTTP annotations left
out):

```taxi
model Person {
  name: PersonName inherits String
  role: JobTitle inherits String
  company: CompanyName inherits String
  email: EmailAddress inherits String
}

service PeopleService {
  operation findPerson(@PathVariable name: PersonName): Person(...)
}
```

### Placeholders

`{name}` is the name as said. `{first}` and `{last}` are its first and last
words. Each becomes a complete TaxiQL string literal, quotes included, so
write it bare: `PersonName == {name}`, not `PersonName == "{name}"`. The config
is refused if a placeholder is quoted.

Taxi keeps escape sequences exactly as written: `'O\'Brien'` would reach your
service with the backslash. So the literal uses the quote the name doesn't
contain, and `O'Brien` is sent as `"O'Brien"`. Only a backslash, or a name
holding both kinds of quote, is escaped. Line breaks become spaces. A value
can never end the literal early.

### Pick the query shape your operation needs

Find the operation that returns your type and read its signature. It decides
how the name gets in:

| Operation | Template |
| --- | --- |
| `findPerson(PersonName): Person(...)`, with a contract | `find { Person(PersonName == {name}) } as { … }` |
| `findPerson(PersonName): Person`, no contract | `given { PersonName = {name} } find { Person } as { … }` |
| `searchPeople(PersonName): Person[]` | `given { PersonName = {name} } find { Person[] } as { … }[]` |
| `listPeople(): Person[]`, no input | `find { Person[].filter((PersonName) -> PersonName == {name}) } as { … }[]` |
| `findPerson(FirstName, LastName): Person(...)` | `find { Person(FirstName == {first} && LastName == {last}) } as { … }` |

A single result projects with `as { … }`. A collection projects with
`as { … }[]`. When a query returns several records, the card uses the one
whose `title` field matches the name, or else the first, and notes how many
more there were.

Fields from other services can go in the same projection: Orbital fetches
them by their types. For example, add `accountOwner: AccountManagerName` to the
company template if a CRM service returns it for a `CompanyName`.

On a large schema, pin the operation so the planner doesn't search the whole
graph. `using` goes after the query:

```taxiql
find { Person(PersonName == {name}) } as {
  name: PersonName
  role: JobTitle
}
using { PeopleService::findPerson }
```

### Order

Lookups run in config order until one finds something. A name holding a
company word (Ltd, Inc, Group, Logistics, Bank, Labs and so on) is tried
against the `company` templates first.

### When nothing shows

Run `--lookup "A Name"` and read the reply. A 4xx reply, or a 5xx reply with a
message, counts as "nothing found" and its message goes to the log. The
message is often `No data sources were found that can return Person`: the
query shape doesn't match an operation in the schema (see the table above).
A 5xx reply without a message, or no reply at all, sets the status to offline.

## Sample session

MacCap sends (one JSON object per line):

```json
{"type":"start","v":1,"started_at":"2026-11-06T10:00:00Z","session_dir":"/Users/you/.maccap/sessions/x","apps":["Zoom"]}
{"type":"line","stem":"system","speaker":"Them","text":"Hi, Priya Shah here.","start":3.0,"end":5.0}
{"type":"line","stem":"system","speaker":"Them","text":"Dana Whitlock joins later.","start":6.0,"end":8.0}
{"type":"ask","id":"ask-1","question":"Who is Priya Shah?","at":9.0,"transcript":"[00:03] Them: Hi, Priya Shah here.","topics":[]}
{"type":"end"}
```

The assist answers:

```json
{"type":"status","text":"Orbital: connected"}
{"type":"card","id":"orbital-priya-shah","kind":"person","title":"Priya Shah","body":"Looking up Priya Shah in Orbital…","state":"looking","quote":"Hi, Priya Shah here.","source":"Orbital","at":3.0}
{"type":"card","id":"orbital-priya-shah","kind":"person","title":"Priya Shah","body":"- **Role:** Head of Operations\n- **Company:** Northwind Logistics\n- **Email:** priya.shah@example.com","state":"ready","chips":["Head of Operations","Northwind Logistics"],"quote":"Hi, Priya Shah here.","source":"Orbital","at":3.0}
{"type":"card","id":"orbital-dana-whitlock","kind":"person","title":"Dana Whitlock","body":"Looking up Dana Whitlock in Orbital…","state":"looking","quote":"Dana Whitlock joins later.","source":"Orbital","at":6.0}
{"type":"remove","id":"orbital-dana-whitlock"}
{"type":"card","id":"ask-1","kind":"answer","title":"Who is Priya Shah?","body":"### Priya Shah\nPerson · Head of Operations · Northwind Logistics\n\n- **Role:** Head of Operations\n- **Company:** Northwind Logistics\n- **Email:** priya.shah@example.com","source":"Orbital","state":"ready","pinned":true,"chips":["Priya Shah"],"at":9.0}
```

The program exits after `end`. You can replay this yourself with canned
replies, without an Orbital, as the tests do: point the
`ORBITAL_TAXI_FAKE_RESPONSES` environment variable at a JSON file of replies
(see `fake_fetch` in the script). It is for tests only.

## Limits

- Name spotting is a rule, not a model. It misses names said in lower case
  and single-word names, unless they are on the watchlist. It sometimes
  catches capitalised phrases that aren't names. Orbital finds nothing for
  those, and their card is removed.
- Names from the speaker labels (`[00:03] Priya Shah: …`) are not used. Only
  the words said are.
- A name said while Orbital is offline is looked up when it is said again
  after Orbital is back.

## Tests

```bash
cd integrations/orbital-taxi
python3 -m unittest -v test_orbital_assist
```

The tests replace the HTTP layer with a fake fetch function and open no
sockets. The end-to-end tests run the script as MacCap does, piping a
scripted call through it.
