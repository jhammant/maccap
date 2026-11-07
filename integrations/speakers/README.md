# Speakers call assist

`maccap_speakers.py` is a MacCap `assist_command` that recognises enrolled
voices on the **call side** and names their transcript lines live. It never
names the microphone stem. Unknown voices keep MacCap's **Them** label.

It reads MacCap's growing audio segments, embeds each sufficiently long
transcript line, and groups similar voices. After a group has at least six
seconds of speech and confidently matches an enrolled person, it sends
`speaker` spans for that group's earlier lines and each later line. A name
once sent never changes during the call: MacCap adds span overlap per name,
so sending a replacement would create competing votes.

The integration uses Python 3.10+, the standard library, NumPy, `ffmpeg`, and
one lazily loaded embedding backend. There is no transcription service or
language model in this assist.

## Install

Install `ffmpeg` and a Python version supported by your chosen backend's
PyTorch wheels (Python 3.12 is a useful choice). From this directory:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt speechbrain==1.1.2
command -v ffmpeg
```

This installs [SpeechBrain](https://pypi.org/project/speechbrain/), the default
backend. It uses
[`speechbrain/spkrec-ecapa-voxceleb`](https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb)
on the CPU. First use downloads the model; enroll before a call to warm the
cache. The assist's SpeechBrain cache is `~/.cache/maccap-speakers/ecapa`;
Hugging Face also maintains its own model cache.

After confirming the backend works on your Mac, save all resolved package
versions for recreating that environment:

```bash
python -m pip freeze > requirements.local.lock
```

The lock is local and ignored by Git. The offline tests exercise backend
adapters with fakes; they do not download or validate the real models.

## Enroll and list voices

Enroll only people who have agreed. Choose a clean passage with just that
person speaking. In a MacCap stereo recording, `right` is the call side;
`left` is the microphone. `mono` downmixes the input, useful for an already
isolated recording.

```bash
python maccap_speakers.py enroll "Priya Shah" call.m4a \
  --channel right --from 12:30 --to 13:10
python maccap_speakers.py list
```

Times accept seconds, `MM:SS`, or `HH:MM:SS`, including fractional seconds.
`--from` defaults to zero; omitting `--to` uses the rest of the file.
`--channel` defaults to `right`. Repeating enrollment appends a sample to
that person's file. Samples from different microphones or calls can help.

`--voiceprints DIR` overrides the default `~/.maccap/voiceprints`. Each person
has one JSON file with this format (the example vector is illustrative;
real embeddings have many more dimensions):

```json
{
  "name": "Priya Shah",
  "samples": [
    {
      "embedding": [0.6, 0.8],
      "embedding_model": "speechbrain/spkrec-ecapa-voxceleb",
      "enrolled_at": "2026-11-06T12:00:00+00:00"
    }
  ]
}
```

Only samples whose `embedding_model` exactly equals the selected backend's
model ID participate. Invalid samples and incompatible dimensions are
ignored. Matching uses the best compatible sample for each person, then
compares the two best **people**, so multiple samples for Priya do not count
as competing identities. Voiceprints are loaded when the first usable line
is processed; restart the assist to pick up enrollment changes.

## Try it on the demo call

The made-up call from `scripts/demo-call.py` has one voice on the call side,
Priya. Enroll her from its first 25 seconds, point MacCap at this assist
(next section), then replay the call:

```bash
python3 ../../scripts/demo-call.py --out demo-call.m4a
python maccap_speakers.py enroll "Priya Shah" demo-call.m4a --channel right --to 0:25
/Applications/MacCap.app/Contents/MacOS/MacCap demo demo-call.m4a
```

Her lines change from **Them** to **Priya Shah** a few seconds in, once she
has said enough to match. Lines under a second ("Perfect.") stay **Them**.

## Connect to MacCap

Add this to `~/.maccap/config.json`, replacing the example paths with absolute
paths on your Mac. Use the venv's Python, and the `ffmpeg` path printed during
setup: Finder-launched apps may not have your terminal's `PATH`.

```json
{
  "assist_command": [
    "/path/to/maccap/integrations/speakers/.venv/bin/python",
    "/path/to/maccap/integrations/speakers/maccap_speakers.py",
    "--ffmpeg", "/path/to/ffmpeg"
  ]
}
```

MacCap sends JSON lines on stdin. `start` supplies `session_dir`; each `line`
supplies `stem`, `start`, `end`, and `text`. A worker processes the audio while
the reader keeps consuming stdin. Output is flushed one message at a time:

```json
{"type":"speaker","stem":"system","start":12.5,"end":15.0,"name":"Priya Shah"}
```

Bad events and missing audio are logged to stderr and skipped; backend
initialisation failure also sends a `status`. MacCap puts stderr in its log.
On `end` or EOF the assist allows up to four seconds for outstanding work.
Pending model work can be abandoned at that deadline.

## Keep an existing assist with `--then`

MacCap runs one `assist_command`. Put Speakers first and append the existing
assist command after `--then`, which must be the last Speakers option:

```json
{
  "assist_command": [
    "/path/to/maccap/integrations/speakers/.venv/bin/python",
    "/path/to/maccap/integrations/speakers/maccap_speakers.py",
    "--ffmpeg", "/path/to/ffmpeg",
    "--then",
    "/usr/bin/python3",
    "/path/to/maccap/integrations/orbital-taxi/orbital_assist.py",
    "--config", "/path/to/orbital-taxi.json"
  ]
}
```

Every input line, including malformed input and `end`, is forwarded unchanged
to the child. Its stdout is copied as whole lines alongside speaker messages;
its stderr passes through. Input forwarding has its own thread, so a slow
child cannot block stdin. On `end` or EOF its stdin closes after queued lines
are forwarded, and it gets up to four seconds to exit before termination.
The child receives the original transcript events; speaker messages go to
MacCap, not back through the child's stdin.

## Backends and calibration

| Backend flag | Exact `embedding_model` ID | Cluster cosine | Match cosine |
| --- | --- | --- | --- |
| `speechbrain` | `speechbrain/spkrec-ecapa-voxceleb` | 0.55 | 0.70 |
| `pyannote` | `pyannote/speaker-diarization-community-1` | 0.55 | 0.70 |
| `module:attr` | The custom backend's `.model` | 0.55 | 0.70 |

The defaults come from replaying two real recorded calls, scored against a
full diarization of each. With voices enrolled from other calls, 92–93% of
the enrolled people's lines got their name, 1 line in 233 got the wrong
name, and 1 of about 270 lines from people who weren't enrolled was named.
Stricter thresholds (0.70/0.75) named only 73–84%. Your calls will differ,
so treat these as starting points and **calibrate** on your own audio,
including people you have not enrolled. A higher cluster threshold splits
voices more readily; a higher match threshold leaves more voices unnamed.
Naming also requires a cosine margin of at least **0.05** over the next person
and at least `min_cluster_seconds` of speech. Each cluster's centroid is the
mean of L2-normalised line embeddings; cosine normalises that mean again.

For pyannote, install the optional backend in the venv:

```bash
python -m pip install -r requirements.txt pyannote.audio==4.0.7
python maccap_speakers.py enroll "Sam" call.m4a --channel right \
  --from 2:00 --to 2:30 --backend pyannote
```

Accept the [Community-1 model conditions](https://huggingface.co/pyannote/speaker-diarization-community-1)
and authenticate with Hugging Face before downloading it. The adapter uses
`HF_TOKEN` if present, or Hugging Face's cached authentication. Keep tokens
out of JSON configs and command arguments. This adapter loads only the
pipeline's `embedding` subfolder through `PretrainedSpeakerEmbedding`, the
[same component used by Community-1](https://github.com/pyannote/pyannote-audio/blob/main/src/pyannote/audio/pipelines/speaker_diarization.py).
Its vectors can be compared with `speaker_embeddings` produced by that
pipeline. To import such a voiceprint, store the vector with the exact
Community-1 model ID in the table; do not relabel embeddings from other
models. A pipeline's averaged embeddings and individual live lines still
need threshold calibration. Library telemetry is disabled by this adapter.

A custom `--backend module:attr` can export an instance, class, or zero-argument
factory. It must expose `.model` (a nonempty string ID) and
`.embed(samples) -> list[float]`. Input is a one-dimensional NumPy `float32`
array of mono 16 kHz audio; return a finite, nonzero vector. Use a new model
ID when the embedding space changes. The module must be importable in the
venv. Help and `list` never import a model.

Every setting below can be set in a JSON file passed with `--config FILE`.
Flags override file values; replace underscores with hyphens for flags, for
example `--min-cluster-seconds 8`.

```json
{
  "backend": "speechbrain",
  "voiceprints": "~/.maccap/voiceprints",
  "cluster_threshold": 0.55,
  "match_threshold": 0.70,
  "min_line_seconds": 1.0,
  "min_cluster_seconds": 6.0,
  "audio_wait_seconds": 1.5,
  "ffmpeg": "/path/to/ffmpeg"
}
```

Without a config file, these defaults apply (`ffmpeg` is found on `PATH`).
Omit threshold keys to use the selected backend's defaults. The margin is
fixed at 0.05; there is no implicit config file and no shell command parsing.

## Audio and limits

The assist reads `system_segments` from `session.json`. It caches ADTS frame
boundaries in Python and extends the index as each mono 48 kHz segment grows,
ignoring an incomplete last frame. Decoded sample `n` has session time
`start_seconds + (n - 2112) / 48000`. For each line it sends only that span's
complete frames, with up to two frames of margin at each end, to `ffmpeg`,
then trims the 16 kHz output to the requested span (nearest sample).

- Overlapping talk or a speaker change inside one transcript line can produce
  a mixed embedding and an incorrect identity. This is online voice matching,
  not a full diarization or source-separation pipeline.
- Lines shorter than one second are skipped by default. Names may take several
  turns to appear, and voices that never accumulate enough speech stay **Them**.
- Audio may lag the transcript. The assist retries for 1.5 seconds by default,
  then skips unavailable spans. It skips lines crossing segment boundaries.
- Noise, music, similar voices, recording devices, and call compression affect
  matching. A wrong published name remains fixed for that call; calibrate
  conservatively. Slow model inference can build up a queue and delay names.
- Raw session segments must still exist. A final recording alone is suitable
  for enrollment, but cannot replace the session files for live matching.
  `MacCap demo` and `MacCap notes` replays write the call side as session
  segments too, so a replay is named like a live call.

## Privacy and deletion

**Voiceprints are biometric data.** Enroll only people who agreed. The built-in
backends process audio on your Mac; voiceprints stay on your Mac in the chosen
folder, created with mode `700`, with files written atomically at mode `600`.
Model downloads need network access initially; matching does not upload audio
or voiceprints. Custom backends and chained assists have their own behaviour.
Keep the voiceprint folder out of shared repositories and cloud-synced folders.

To delete a person, run `list`, find their JSON path, and delete that file:

```bash
python maccap_speakers.py list
rm /path/to/voiceprints/priya-shah-example.json
```

Use the actual path printed by `list`. Restart a running assist to clear its
in-memory copy. Deleting a voiceprint does not erase names already saved in
MacCap transcripts, or the source recording used for enrollment.

## Tests

```bash
cd integrations/speakers
python3 -m unittest -v
```

Tests use deterministic fake embeddings and generated audio: no network,
accounts, models, or real voices. The AAC and enrollment fixture tests skip
when `ffmpeg` is unavailable; the remaining tests still run.
