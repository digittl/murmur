-- BatchWhisper
-- Drag a folder of recordings (or the recordings themselves) onto this app.
-- It feeds each file into Whisper Transcription one at a time, in chronological
-- order (by the YYYY-MM-DD-HH-MM-SS timestamp in each filename), waiting for each
-- file's transcript to land in the export folder before sending the next — so
-- Whisper only ever holds one job and the list can't reorder.
--
-- Double-clicking the app (instead of dropping) prompts you to pick a folder.
--
-- Requires: MacWhisper set to auto-export transcripts to the folder below.

-- Max seconds to wait for a single file's transcript before giving up on it.
property maxWaitSeconds : 600
-- MacWhisper's auto-export folder (must match its settings). "~/.whisper-extracts".
property exportSubpath : ".whisper-extracts"

on run
	set chosenFolder to choose folder with prompt "Choose the folder of recordings to import into Whisper Transcription in chronological order:"
	handleItems({chosenFolder})
end run

on open droppedItems
	handleItems(droppedItems)
end open

on handleItems(theItems)
	set scriptPath to POSIX path of (path to resource "import.sh")
	set exportDir to (POSIX path of (path to home folder)) & exportSubpath

	set posixPaths to ""
	repeat with itm in theItems
		set posixPaths to posixPaths & (POSIX path of itm) & linefeed
	end repeat

	-- The wait-for-transcript loop can run for many minutes on a big batch, so
	-- give do shell script a very long timeout.
	with timeout of 86400 seconds
		set theOutput to do shell script "/bin/zsh " & quoted form of scriptPath & " " & (maxWaitSeconds as text) & " " & quoted form of exportDir & " <<'WCI_PATHS'
" & posixPaths & "WCI_PATHS"
	end timeout

	display notification theOutput with title "BatchWhisper"
end handleItems
