#!/bin/zsh
# Called by the Whisper Chrono Import app. Reads newline-separated paths (files
# and/or folders) on stdin, expands folders to audio files, sorts them
# chronologically by the timestamp in each filename, then opens each into
# Whisper Transcription with a gap so its "date added" order comes out sorted.
#
# Arg 1: gap in seconds between files (default 2).

setopt null_glob

gap="${1:-2}"
app="Whisper Transcription"
exts=(m4a mp3 wav aac caf aiff flac ogg)

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

# Sort by basename — filenames are YYYY-MM-DD-HH-MM-SS, so lexical == chronological.
files=(${(f)"$(printf '%s\n' $files | awk -F/ '{print $NF"\t"$0}' | sort | cut -f2-)"})

for f in $files; do
  open -a "$app" "$f"
  sleep "$gap"
done

echo "Imported ${#files} recordings in order."
