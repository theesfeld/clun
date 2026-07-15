# Clun Agent Instructions

The keyword `phase` is a complete execution request.

When the user's message is exactly `phase`, read `PHASE_PROMPT.md` and execute it for the current
phase or milestone recorded in `STATE.md`. When the message is `phase NN`, execute the same prompt
for Phase NN after verifying that its dependencies are complete. Do not require the user to paste
the long prompt again.

These instructions apply to the Clun repository, excluding nested directories with their own
`AGENTS.md` instructions.
