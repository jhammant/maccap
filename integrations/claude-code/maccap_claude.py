#!/usr/bin/env python3
# MacCap + Claude Code. MIT licence, Copyright (c) 2026 Jonathan Hammant.
"""MacCap's after-call commands, run by Claude Code (`claude -p`).

    final-notes   MacCap's `final_notes_command`: when a call ends, rewrites the
                  next steps from the whole transcript into what Claude can do,
                  what only you can do, and what you're waiting on.
    follow-up     MacCap's `followup_command`: Hand off sends the ticked steps
                  here; Claude drafts each one (emails, messages, outlines) into
                  one Markdown file. Nothing is sent anywhere.

Both read MacCap's JSON on stdin. Claude runs with no tools, so it can only
write text back. Standard library only; needs Claude Code installed and
logged in.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

MAX_WORDS = 12000  # of transcript sent to Claude

FINAL_NOTES = """You decide the follow-ups from a call the user has just had. The user works AI-first: Claude does
the drafting and research, and the user only does what truly needs them. Transcript lines are labelled You (the
user), Them, or a person's name. Reply with one JSON object and nothing else:
{"ai_steps": [...], "your_steps": [...], "waiting_on": [...], "key_points": [...], "open_questions": [...]}
- ai_steps: AT MOST 4 tasks Claude can do because of this call, most valuable first, each left ready for the user to
  approve: draft a message (never send it), research something, prepare a document or brief. One short instruction
  starting with a verb, e.g. "Draft the follow-up email to Priya with the pricing bands and two training slots."
  Only work that clearly follows from what was agreed or asked. Fewer is better; empty is fine.
- your_steps: AT MOST 2 things only the user can do (a decision, a call, a meeting), each one short sentence.
- waiting_on: AT MOST 3 things the other side promised, named when known ("Priya will send the printer model.").
- key_points: 3 to 5 short sentences: what was decided, learned or agreed.
- open_questions: at most 3 questions raised and not answered.
Nothing vague, nothing that wasn't said. Transcription mistakes happen: leave garbled lines out rather than guess."""

FOLLOW_UP = """The user has just finished a call and ticked the next steps below. For every step that starts with
"Claude:", do the work now as text the user can use straight away: write the email or message in full (greeting,
body, sign-off with the placeholder [Your name]), or the outline, checklist or research notes it asks for. Use only
what the call and the notes say; mark anything you had to assume with [check]. Never claim anything was sent or
done. Steps that start with "You:" are the user's own: list them at the end under "## For you" as a checklist.
Reply in Markdown: one "## " heading per step, in the order given."""


def find_claude():
    """Apps opened from Finder get a short PATH, so look in the usual places too."""
    for candidate in [shutil.which("claude"), Path.home() / ".local/bin/claude", Path.home() / ".claude/local/claude",
                      "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]:
        if candidate and os.access(str(candidate), os.X_OK):
            return str(candidate)
    return None


def ask_claude(prompt, text, model, timeout, run=subprocess.run):
    """Claude's reply as text, or None (logged to stderr, which MacCap keeps in its log)."""
    claude = find_claude()
    if claude is None:
        print("maccap-claude: Claude Code not found (install it and run `claude` once to log in)", file=sys.stderr)
        return None
    try:
        done = run([claude, "-p", "--model", model, "--no-session-persistence", "--output-format", "text",
                    "--tools", "", "--append-system-prompt", prompt],
                   input=text, capture_output=True, text=True, timeout=timeout, cwd=str(Path.home()))
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"maccap-claude: claude failed: {type(exc).__name__}", file=sys.stderr)
        return None
    if done.returncode != 0:
        print(f"maccap-claude: claude exited {done.returncode}: {done.stderr.strip()[-300:]}", file=sys.stderr)
        return None
    return done.stdout.strip()


def parse_json(reply):
    """The first JSON object in a reply, even with a code fence or a sentence around it."""
    if not reply:
        return None
    start = reply.find("{")
    while start != -1:
        try:
            value, _ = json.JSONDecoder().raw_decode(reply[start:])
            if isinstance(value, dict):
                return value
        except ValueError:
            pass
        start = reply.find("{", start + 1)
    return None


def clean(items, limit):
    if not isinstance(items, list):
        return []
    return [str(item).strip() for item in items if str(item).strip()][:limit]


def last_words(text, limit=MAX_WORDS):
    words = text.split()
    return text if len(words) <= limit else "…" + " ".join(words[-limit:])


def meeting_header(meeting):
    minutes = round((meeting.get("duration_seconds") or 0) / 60)
    apps = ", ".join(meeting.get("apps") or []) or "a call"
    return f"Call: {meeting.get('title') or 'Untitled'} · {meeting.get('started_at', '')} · {minutes} min · {apps}"


def final_notes(meeting, model, run=subprocess.run):
    text = "\n\n".join([
        meeting_header(meeting),
        "Live notes so far:\n" + "\n".join(f"- {s}" for s in meeting.get("next_steps") or []),
        "Transcript:\n" + last_words(meeting.get("transcript") or ""),
    ])
    data = parse_json(ask_claude(FINAL_NOTES, text, model, timeout=150, run=run))
    if data is None:
        return None
    return {"ai_steps": clean(data.get("ai_steps"), 4), "your_steps": clean(data.get("your_steps"), 2),
            "waiting_on": clean(data.get("waiting_on"), 3), "key_points": clean(data.get("key_points"), 5),
            "open_questions": clean(data.get("open_questions"), 3), "model": f"Claude Code ({model})"}


def read_notes(meeting):
    path = meeting.get("notes_file")
    try:
        return Path(path).read_text(encoding="utf-8") if path else ""
    except OSError:
        return ""


def slug(text):
    return re.sub(r"[^A-Za-z0-9]+", "-", text or "call").strip("-")[:60] or "call"


def follow_up(meeting, model, out_dir, run=subprocess.run, now=None):
    steps = meeting.get("next_steps") or []
    if not steps:
        return {"status": "Nothing ticked to hand off"}
    text = "\n\n".join([
        meeting_header(meeting),
        "Ticked next steps:\n" + "\n".join(f"- {s}" for s in steps),
        "Key points:\n" + "\n".join(f"- {s}" for s in meeting.get("key_points") or []),
        "Notes and transcript:\n" + last_words(read_notes(meeting)),
    ])
    reply = ask_claude(FOLLOW_UP, text, model, timeout=170, run=run)
    if not reply:
        return {"status": "Claude Code didn't answer; see MacCap's log"}
    stamp = (now or datetime.now()).strftime("%Y%m%d %H%M%S")
    out_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = out_dir / f"{stamp} {slug(meeting.get('title'))}.md"
    path.write_text(f"# Follow-ups: {meeting.get('title') or 'call'}\n\n{meeting_header(meeting)}\n\n{reply}\n",
                    encoding="utf-8")
    os.chmod(path, 0o600)
    drafts = sum(1 for s in steps if s.startswith("Claude:"))
    return {"status": f"{drafts} draft{'s' if drafts != 1 else ''} ready" if drafts else "Checklist saved",
            "url": path.as_uri()}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["final-notes", "follow-up"])
    parser.add_argument("--model", default=os.environ.get("MACCAP_CLAUDE_MODEL", "sonnet"),
                        help="Claude model alias or id (default: sonnet)")
    home = Path(os.environ.get("MACCAP_HOME", Path.home() / ".maccap")).expanduser()
    parser.add_argument("--out", type=Path, default=home / "follow-ups", help="where follow-up drafts are written")
    args = parser.parse_args(argv)
    try:
        meeting = json.load(sys.stdin)
    except ValueError:
        print("maccap-claude: stdin was not MacCap's JSON", file=sys.stderr)
        return 2
    if args.command == "final-notes":
        result = final_notes(meeting, args.model)
        if result is None:
            return 1  # MacCap keeps the live notes' steps
        print(json.dumps(result))
    else:
        print(json.dumps(follow_up(meeting, args.model, args.out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
