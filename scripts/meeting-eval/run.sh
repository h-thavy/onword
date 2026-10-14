#!/bin/zsh
# Measures meeting-transcription accuracy on synthetic meetings (macOS voices, Opus call audio, mic echo).
#
#   scripts/meeting-eval/run.sh            # builds the test meetings once, then scores standup, oneonone, design
#
# Uses build/Onword.app (scripts/build-app.sh) with a throwaway data folder that links your downloaded models,
# and the ONWORD_TEST_MEETING hook. Prints word error rate (you / the call), speaker accuracy and missed lines.
set -e
cd "$(dirname "$0")"; HERE=$PWD; WORK=${TMPDIR:-/tmp}/onword-meeting-eval; mkdir -p $WORK
for s in standup oneonone design; do [ -d $WORK/$s ] || python3 make_meeting.py $WORK/$s $s; done
printf "Dara Sok\nMina Park\nLeo Chan\n" > $WORK/standup/attendees.txt
printf "Ana Ruiz\n" > $WORK/oneonone/attendees.txt
printf "Tessa Moore\nFred Lane\n" > $WORK/design/attendees.txt
for s in standup oneonone design; do
  D=$WORK/data-$s; rm -rf $D; mkdir -p $D; ln -s "$HOME/Library/Application Support/Onword/Models" $D/Models; cp dictionary.json $D/
  pkill -x Onword || true; while pgrep -x Onword >/dev/null; do sleep 0.3; done
  open --env ONWORD_TEST_DATA=$D --env ONWORD_TEST_MEETING=$WORK/$s "$HERE/../../build/Onword.app" --args -onboardingComplete YES
  for i in $(seq 1 300); do sleep 2; f=$(ls $D/Meetings/*/meeting.json 2>/dev/null | head -1); [ -n "$f" ] && grep -q '"status" : "ready"\|"status" : "failed"' $f && break; done
  echo "== $s"; python3 score.py $WORK/$s/reference.json $f | sed '/^Transcript:/,$d'
done
pkill -x Onword || true
