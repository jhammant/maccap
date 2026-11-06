#!/usr/bin/env python3
"""Make a made-up call to try MacCap with, without recording anyone.

Writes a stereo .m4a in MacCap's layout (left channel: you, right channel: the
call), spoken by the Mac's built-in voices with `say`, then joined with ffmpeg.
Everyone in it is fictional.

    python3 scripts/demo-call.py                  # writes demo-call.m4a
    MacCap.app/Contents/MacOS/MacCap demo demo-call.m4a

Options: --out FILE, --you VOICE, --them VOICE (any name from `say -v '?'`).
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

# (speaker, line): "you" is the left channel, "them" the right.
CALL = [
    ("them", "Hi, it's Priya from Northwind Logistics. Thanks for making time."),
    ("you", "Hi Priya, good to talk. How's the pilot going with the warehouse team?"),
    ("them", "Really well. We're scanning about twelve hundred orders a month through it now, "
             "up from four hundred in September."),
    ("you", "That's great. Is anything slowing the team down?"),
    ("them", "Two things. The label printer drops out every afternoon, and finance wants a monthly invoice "
             "instead of a card payment."),
    ("you", "The printer sounds like the driver timeout we fixed last week. Can you send me the model number?"),
    ("them", "Yes, I'll send that over today."),
    ("you", "Thanks. On invoicing, that's fine. Action point: I'll set up monthly invoicing and send you "
            "the paperwork by Friday."),
    ("them", "Perfect. One more question. Can we add the Leeds site in January? That's another twenty users."),
    ("you", "Yes. What date would they start?"),
    ("them", "The sixth of January, if we can do the training the week before."),
    ("you", "Let's do it. I'll follow up with two training slots for the week of the twenty-ninth."),
    ("them", "Great. And what happens to pricing with the extra users?"),
    ("you", "You'd move to the next band, which is a little cheaper per user. I'll put the numbers in the "
            "same email."),
    ("them", "Lovely. I think that's everything from me."),
    ("you", "Great. So: you send the printer model, I send invoicing, training slots and pricing by Friday. "
            "Thanks Priya."),
    ("them", "Thanks, bye."),
]

GAP = 0.6  # seconds of quiet between turns


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def duration(path, ffprobe):
    out = subprocess.run([ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                         check=True, capture_output=True, text=True).stdout
    return float(out.strip())


def main():
    parser = argparse.ArgumentParser(description="Make a fictional two-person call for `MacCap demo`.")
    parser.add_argument("--out", default="demo-call.m4a")
    parser.add_argument("--you", default="Daniel", help="voice for you (left channel)")
    parser.add_argument("--them", default="Samantha", help="voice for the other side (right channel)")
    args = parser.parse_args()
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not (ffmpeg and ffprobe and shutil.which("say")):
        sys.exit("needs `say` (macOS) and ffmpeg/ffprobe (brew install ffmpeg)")

    with tempfile.TemporaryDirectory() as tmp:
        sides = {"you": [], "them": []}
        for i, (who, text) in enumerate(CALL):
            voice = args.you if who == "you" else args.them
            aiff = os.path.join(tmp, f"{i:02d}.aiff")
            run("say", "-v", voice, "-o", aiff, text)
            wav = os.path.join(tmp, f"{i:02d}.wav")
            run(ffmpeg, "-y", "-i", aiff, "-ar", "48000", "-ac", "1", wav)
            length = duration(wav, ffprobe) + GAP
            quiet = os.path.join(tmp, f"{i:02d}-quiet.wav")
            run(ffmpeg, "-y", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", f"{length:.3f}", quiet)
            padded = os.path.join(tmp, f"{i:02d}-padded.wav")
            run(ffmpeg, "-y", "-i", wav, "-af", f"apad=whole_dur={length:.3f}", padded)
            sides[who].append(padded)
            sides["them" if who == "you" else "you"].append(quiet)
        tracks = {}
        for who, parts in sides.items():
            listing = os.path.join(tmp, f"{who}.txt")
            with open(listing, "w") as f:
                f.writelines(f"file '{p}'\n" for p in parts)
            tracks[who] = os.path.join(tmp, f"{who}.wav")
            run(ffmpeg, "-y", "-f", "concat", "-safe", "0", "-i", listing, "-c", "copy", tracks[who])
        run(ffmpeg, "-y", "-i", tracks["you"], "-i", tracks["them"],
            "-filter_complex", "[0:a][1:a]join=inputs=2:channel_layout=stereo[a]", "-map", "[a]",
            "-c:a", "aac", "-b:a", "128k", args.out)
    print(f"wrote {args.out} ({duration(args.out, ffprobe):.0f} s; left: you, right: them)")


if __name__ == "__main__":
    main()
