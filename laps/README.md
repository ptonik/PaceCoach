# Shared laps

A fast lap in here is offered to everyone who drives the same car on the same
track: the app looks for `laps/<track>__<car>.txt` a few seconds after it
starts and, if the file is there, uses the fastest lap in it as a benchmark
and as part of the limit lap.

To share one, copy your own lap file from
`Documents\Assetto Corsa\PaceCoach\<track>__<car>.txt` into this folder
without renaming it, and commit it. The file holds your best lap (and the
teacher lap, if there is one); nothing else.

A lap only fits the same track layout and the same car. Files for anything
else are ignored.
