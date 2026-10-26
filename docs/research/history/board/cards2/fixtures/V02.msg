Keep each container run's output in a private, bounded file in the machine's folder

The output of a container lived only in the log pane, so it was gone when the
app quit and no other reader could have it. Each container machine now also
keeps what its log shows, filtered the same way, in container-output.log in
its folder, with one previous file of the same size. A copy made with
Duplicate starts with no log, and deleting the machine removes it.

The file is written off the main actor: bytes wait in a bounded buffer, and a
drain on a queue shared by all files, so two runs never write at once, opens
the file, writes and closes it, so no descriptor stays open between drains and
the main actor never waits for the disk. When the disk is slower than the
container, new bytes are dropped and the next drain says how many; the note is
kept within the limit by cutting the oldest waiting bytes, never by losing
itself. The file is created exclusively with mode 0600, opened without
waiting (a pipe planted at the path cannot hold the writer) and never followed
through a link; a file that is not a regular file of this user, has another
name or is open to others is left alone, and each kind of refusal is logged
once per file. When a write would pass the limit, the file becomes the
previous one, replacing the older.

The log writes a marker line when the run starts and when the container and
the runner end, and the runner's own diagnostics stay out of the file. A
reader for the last bytes of both files, at a character boundary, is part of
the file type.

