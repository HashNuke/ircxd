# ircxd

This is an Elixir IRC server and client library

## Project hygiene

Work in small, coherent checkpoints that leave the project usable and make
changes easy to review. Keep implementation, tests, and documentation for a
checkpoint together.

Follow test-driven development for behavior changes:

1. Add or adapt a focused test first and run it to confirm that it fails for the
   expected reason.
2. Implement the smallest coherent change that makes the test pass.
3. Run focused tests while iterating, then run the broader relevant test suite
   before completing the checkpoint.

Do not test functionality owned by a third-party library, or add obvious tests
for behavior guaranteed and tested by the API provider or platform. Test this
project's contract, integration boundaries, and project-owned behavior.

For research and implementation tasks, create a labnotes file with
`bin/create-labnotes` and a two-to-four-word hyphenated task name. Use the
resulting file under `labnotes/` as checkpoint labnotes. Record what worked,
what did not, barriers encountered, workarounds, decisions and their rationale,
and relevant test evidence. Do not create labnotes for simple status checks,
read-only inspection, or requests that only run an existing command or script.

Commit small, usable checkpoints. Include the checkpoint's tests,
implementation, and documentation in the same commit when applicable.
Labnotes are local working records and remain ignored; do not force-add them to
commits. Write a concise subject and a detailed commit description explaining
the motivation, important implementation decisions, and validation performed.

Do not undo commits or delete branches unless the user explicitly requests it.
Do not overwrite or discard unrelated changes in the working tree.
