"""Builds a test meeting: mic.wav (you) and system.wav (the call), plus reference.json with who said what when.

  python3 make_meeting.py <out_dir> [scenario]

Remote voices are sent through Opus at 24 kbps (like a call); the mic gets room noise and some echo of the
call (laptop speakers). Lines can overlap slightly, and short replies ("Yeah.") are included.
"""
import json, os, subprocess, sys, tempfile, wave
import numpy as np

SR = 16000
out = sys.argv[1]
scenario = sys.argv[2] if len(sys.argv) > 2 else "standup"
os.makedirs(out, exist_ok=True)

ME = ("me", "Samantha")
SCRIPTS = {
 "standup": [
  # (speaker, voice, text, gap_before_seconds)  negative gap = overlap with previous line
  (("s_dara", "Daniel"), "Morning everyone. Let's start with the launch plan for the Kampot release.", 1.0),
  (ME, "Sounds good. I finished the onboarding flow yesterday, and the new permissions screen is ready for review.", 0.6),
  (("s_mina", "Karen"), "Nice. Did you fix the bug where the shortcut stopped working after an update?", 0.5),
  (ME, "Yes. The fix shipped in version one point zero point three on Tuesday.", 0.4),
  (("s_leo", "Rishi"), "Great. On my side, the sync service handles about twelve thousand requests per minute now.", 0.8),
  (("s_dara", "Daniel"), "Yeah.", 0.2),
  (("s_leo", "Rishi"), "But latency jumped to four hundred milliseconds on Friday, so I need another day to profile it.", 0.3),
  (("s_mina", "Karen"), "Could we move the analytics dashboard to next sprint, then?", 0.9),
  (ME, "I think so. Let's ask Sokha from design before we decide.", 0.5),
  (("s_dara", "Daniel"), "Okay. Decision: the dashboard moves to sprint fourteen, and Leo owns the latency fix.", -0.4),
  (("s_leo", "Rishi"), "Got it. I'll send an update by Thursday at three pm.", 0.6),
  (ME, "And I'll draft the release notes and share them in the channel tomorrow morning.", 0.5),
  (("s_mina", "Karen"), "Perfect. One more thing, the customer from Phnom Penh asked about Khmer support.", 1.2),
  (("s_dara", "Daniel"), "Let's add that to the roadmap review on the twenty first. Thanks everyone.", 0.7),
  (ME, "Thanks, bye.", 0.4),
 ],
 "oneonone": [
  (("s_ana", "Moira"), "Hi! Thanks for making time. I wanted to go through the hiring plan before Friday.", 1.0),
  (ME, "Of course. Where are we on the backend role?", 0.5),
  (("s_ana", "Moira"), "We have three candidates in the final round. Chanthavy, Marco and Priya. Priya did the best in the system design interview.", 0.6),
  (ME, "Agreed. Her answer on caching was really strong. What about compensation?", 0.5),
  (("s_ana", "Moira"), "Finance approved a range of ninety five to one hundred and ten thousand dollars.", 0.7),
  (ME, "Okay.", 0.3),
  (("s_ana", "Moira"), "I'll send the offer on Monday if you agree.", 0.4),
  (ME, "Yes, please go ahead. And let's schedule the onboarding buddy as well.", 0.5),
  (("s_ana", "Moira"), "Will do. I'll pair her with Dara for the first two weeks.", 0.6),
  (ME, "Perfect. Anything else?", 0.4),
  (("s_ana", "Moira"), "Just a reminder that the offsite in Siem Reap is on November the third.", 0.8),
  (ME, "Got it. Talk soon.", 0.4),
 ],
 "design": [
  (("s_tessa", "Tessa"), "Can everyone see my screen? This is the new checkout flow.", 1.0),
  (ME, "Yes, I can see it.", 0.4),
  (("s_fred", "Fred"), "The payment step still has three fields too many.", 0.7),
  (("s_tessa", "Tessa"), "Right. We could drop the billing address when it matches shipping.", 0.4),
  (ME, "I like that. What does the data say about drop off on that page?", 0.6),
  (("s_fred", "Fred"), "About thirty two percent of people leave at the payment step, compared to eighteen percent last quarter.", 0.7),
  (("s_tessa", "Tessa"), "That's a big jump. I think the new address validation is too strict.", -0.3),
  (ME, "Let's test a relaxed version with ten percent of traffic next week.", 0.6),
  (("s_fred", "Fred"), "Sure. I'll set up the experiment in LaunchDarkly by Wednesday.", 0.5),
  (("s_tessa", "Tessa"), "And I'll update the Figma file with the shorter form tonight.", 0.5),
  (ME, "Great work, both of you. Let's review results on the eighth.", 0.6),
 ],
}
ECHO = {"standup": 0.06, "oneonone": 0.05, "design": 0.12}

def tts(voice, text):
    f = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
    subprocess.run(["say", "-v", voice, "--data-format=LEI16@16000", "-o", f, text], check=True)
    with wave.open(f) as w:
        a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    os.unlink(f)
    # Trim the voice's own leading/trailing silence so timings are the speech.
    idx = np.where(np.abs(a) > 0.01)[0]
    return a[idx[0]:idx[-1] + 1] if len(idx) else a

def opus(x):
    """Round-trip through Opus at 24 kbps, like call audio."""
    d = tempfile.mkdtemp()
    raw, enc, dec = f"{d}/a.wav", f"{d}/a.ogg", f"{d}/b.wav"
    write(raw, x)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-c:a", "libopus", "-b:a", "24k", enc], check=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", enc, "-ar", str(SR), "-ac", "1", dec], check=True)
    y = read(dec)
    return np.pad(y, (0, max(0, len(x) - len(y))))[:len(x)]

def write(path, x):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes())

def read(path):
    with wave.open(path) as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768

lines, t = [], 1.5
clips = []
for (speaker, voice), text, gap in SCRIPTS[scenario]:
    clip = tts(voice, text)
    start = max(0.0, t + gap)
    clips.append((speaker, start, clip))
    lines.append({"speaker": speaker, "text": text, "start": round(start, 2), "end": round(start + len(clip) / SR, 2)})
    t = start + len(clip) / SR
total = int((t + 2.0) * SR)
mic, system = np.zeros(total, np.float32), np.zeros(total, np.float32)
for speaker, start, clip in clips:
    i = int(start * SR)
    target = mic if speaker == "me" else system
    target[i:i + len(clip)] += clip * (0.8 if speaker == "me" else 0.7)
system = opus(system)
rng = np.random.default_rng(7)
mic += 0.004 * rng.standard_normal(total).astype(np.float32)          # room noise
echo = np.concatenate([np.zeros(int(0.05 * SR), np.float32), system])[:total]
mic += ECHO[scenario] * echo                                                    # the call leaking from the speakers
write(f"{out}/mic.wav", mic)
write(f"{out}/system.wav", system)
json.dump({"scenario": scenario, "lines": lines}, open(f"{out}/reference.json", "w"), indent=1)
print(f"{scenario}: {len(lines)} lines, {total / SR:.0f} s -> {out}")
