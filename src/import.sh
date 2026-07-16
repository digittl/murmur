#!/bin/zsh
# Called by the BatchWhisper app. Reads newline-separated paths (files and/or
# folders) on stdin, expands folders to audio files, sorts them chronologically
# by the timestamp in each filename, then feeds them into Whisper Transcription
# ONE AT A TIME — waiting for each file's transcript to appear in the export
# folder before sending the next. That makes ordering race-proof: MacWhisper
# only ever holds one job, so it can't reorder them.
#
# Arg 1: max seconds to wait for a single file's transcript before giving up.
# Arg 2: export folder MacWhisper auto-saves transcripts into.

setopt null_glob

maxWait="${1:-600}"
exportDir="${2:-$HOME/.whisper-extracts}"
app="Whisper Transcription"
exts=(m4a mp3 wav aac caf aiff flac ogg)
pollInterval=0.1
stabilitySleep=0.15 # gap between the two size reads that confirm a transcript is fully written
settleSeconds=0.5 # absorb sibling files when MacWhisper exports multiple formats per transcript

# Collect dropped paths from stdin.
typeset -a items
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  items+="$line"
done

# Expand folders → audio files; keep dropped audio files as-is.
typeset -a files
for p in $items; do
  if [[ -d "$p" ]]; then
    for e in $exts; do
      for f in "$p"/*.$e(N) "$p"/*.${e:u}(N); do
        files+="$f"
      done
    done
  elif [[ -f "$p" ]]; then
    files+="$p"
  fi
done

if (( ${#files} == 0 )); then
  echo "No audio files found."
  exit 0
fi

# Sort ascending by basename (oldest first) — filenames are YYYY-MM-DD-HH-MM-SS,
# so a plain ascending lexical sort is chronological, oldest → newest.
files=(${(f)"$(printf '%s\n' $files | awk -F/ '{print $NF"\t"$0}' | sort | cut -f2-)"})

mkdir -p "$exportDir"

done_count=0
for f in $files; do
  # Snapshot the export folder before sending this file.
  typeset -A before
  before=()
  for x in "$exportDir"/*(N.); do
    before[$x]=1
  done

  open -a "$app" "$f"

  # Wait until a NEW file appears in the export folder and its size is stable
  # (guards against advancing on a half-written transcript).
  waited=0
  found=0
  while (( waited < maxWait )); do
    sleep $pollInterval
    (( waited += pollInterval ))

    for x in "$exportDir"/*(N.); do
      if [[ -z "${before[$x]}" ]]; then
        s1=$(stat -f%z "$x" 2>/dev/null || echo 0)
        sleep $stabilitySleep
        (( waited += stabilitySleep ))
        s2=$(stat -f%z "$x" 2>/dev/null || echo 0)
        if (( s1 > 0 && s1 == s2 )); then
          found=1
          break
        fi
      fi
    done

    (( found )) && break
  done

  if (( found )); then
    (( done_count += 1 ))
    sleep $settleSeconds # let any sibling-format exports for this file land before the next snapshot
  else
    echo "Timed out after ${maxWait}s on ${f:t}. Stopping so the order stays correct."
    break
  fi
done

echo "Transcribed ${done_count} of ${#files} recordings in order."
