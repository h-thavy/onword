"""Scores a processed meeting against reference.json.

  python3 score.py <reference.json> <meeting.json>

- WER: word error rate of the whole transcript (words in time order), and per side (you vs. the call).
- Speaker accuracy: each reference word is matched to a hypothesis word (by alignment); counts it correct if
  that hypothesis word's speaker maps to the right person (remote speakers are mapped to the reference speaker
  they overlap most; "me" must be you).
- Missed lines: reference lines with no matched words. Inserted words: hypothesis words matching nothing.
"""
import json, re, sys
from collections import Counter, defaultdict

ref = json.load(open(sys.argv[1]))
hyp = json.load(open(sys.argv[2]))
NUM = {"zero":"0","one":"1","two":"2","three":"3","four":"4","five":"5","six":"6","seven":"7","eight":"8","nine":"9",
       "ten":"10","twelve":"12","fourteen":"14","twenty":"20","hundred":"100","thousand":"1000","first":"1st"}

def norm(text):
    text = text.lower().replace("-", " ").replace("’", "'")
    text = re.sub(r"[^a-z0-9' ]", " ", text)
    return [NUM.get(w, w) for w in text.split() if w not in ("um", "uh")]

ref_words = [(w, l["speaker"], i) for i, l in enumerate(ref["lines"]) for w in norm(l["text"])]
segs = sorted(hyp["segments"], key=lambda s: s["start"])
hyp_words = [(w, s["speaker"], s["start"], s["end"]) for s in segs for w in norm(s["text"])]

# Levenshtein alignment on words.
R, H = [w[0] for w in ref_words], [w[0] for w in hyp_words]
n, m = len(R), len(H)
d = [[0] * (m + 1) for _ in range(n + 1)]
for i in range(n + 1): d[i][0] = i
for j in range(m + 1): d[0][j] = j
for i in range(1, n + 1):
    for j in range(1, m + 1):
        d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (R[i-1] != H[j-1]))
i, j, pairs = n, m, []
while i > 0 or j > 0:
    if i > 0 and j > 0 and d[i][j] == d[i-1][j-1] + (R[i-1] != H[j-1]):
        pairs.append((i-1, j-1)); i, j = i-1, j-1
    elif i > 0 and d[i][j] == d[i-1][j] + 1:
        pairs.append((i-1, None)); i -= 1
    else:
        pairs.append((None, j-1)); j -= 1
pairs.reverse()
subs = sum(1 for a, b in pairs if a is not None and b is not None and R[a] != H[b])
dels = sum(1 for a, b in pairs if b is None)
ins = sum(1 for a, b in pairs if a is None)
wer = (subs + dels + ins) / max(1, n)

# Map hypothesis speakers to reference speakers by co-occurrence of aligned words.
co = defaultdict(Counter)
for a, b in pairs:
    if a is not None and b is not None:
        co[hyp_words[b][1]][ref_words[a][1]] += 1
mapping = {h: c.most_common(1)[0][0] for h, c in co.items()}
mapping["me"] = "me" if "me" in mapping else mapping.get("me", "me")
correct = total = 0
per_line = defaultdict(lambda: [0, 0])
for a, b in pairs:
    if a is None: continue
    total += 1
    line = ref_words[a][2]
    per_line[line][1] += 1
    if b is not None and mapping.get(hyp_words[b][1]) == ref_words[a][1] and R[a] == H[b]:
        correct += 1; per_line[line][0] += 1
missed = [l for idx, l in enumerate(ref["lines"]) if per_line[idx][0] == 0]

def side_wer(side):
    rs = [k for k, w in enumerate(ref_words) if (w[1] == "me") == side]
    e = sum(1 for a, b in pairs if a in rs and (b is None or R[a] != H[b]))
    return e / max(1, len(rs))

print(f"WER {wer:.1%}  (sub {subs}, del {dels}, ins {ins}, ref words {n})")
print(f"  you: {side_wer(True):.1%}   call: {side_wer(False):.1%}")
print(f"Speaker+word accuracy {correct / max(1, total):.1%}")
print(f"Hyp speakers -> ref: {dict(mapping)}  ({len(set(s['speaker'] for s in segs))} hyp speakers, {len(set(l['speaker'] for l in ref['lines']))} real)")
print(f"Missed lines: {len(missed)}" + "".join(f"\n  - [{l['speaker']}] {l['text']}" for l in missed))
inserted = [hyp_words[b][0] for a, b in pairs if a is None]
if inserted: print(f"Inserted words: {' '.join(inserted)}")
print("\nTranscript:")
for s in segs:
    print(f"  {s['start']:6.1f} [{hyp.get('speakerNames', {}).get(s['speaker'], s['speaker'])}] {s['text']}")
