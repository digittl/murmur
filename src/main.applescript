-- Chronus
-- Drag a folder of recordings (or the recordings themselves) onto this app.
-- It feeds each file into Whisper Transcription one at a time, in chronological
-- order (by the YYYY-MM-DD-HH-MM-SS timestamp in each filename), so the app's
-- own "date added" list comes out sorted.
--
-- Double-clicking the app (instead of dropping) prompts you to pick a folder.

property gapSeconds : 2 -- seconds to wait between files; raise if the list still jumbles

on run
	set chosenFolder to choose folder with prompt "Choose the folder of recordings to import into Whisper Transcription in chronological order:"
	handleItems({chosenFolder})
end run

on open droppedItems
	handleItems(droppedItems)
end open

on handleItems(theItems)
	set scriptPath to POSIX path of (path to resource "import.sh")

	set posixPaths to ""
	repeat with itm in theItems
		set posixPaths to posixPaths & (POSIX path of itm) & linefeed
	end repeat

	set theOutput to do shell script "/bin/zsh " & quoted form of scriptPath & " " & (gapSeconds as text) & " <<'WCI_PATHS'
" & posixPaths & "WCI_PATHS"

	display notification theOutput with title "Chronus"
end handleItems
