# Changelog

## 0.6.0 (beta)

- New: **EMS resistance** (part of Arc Resistance's Resistance choice). Electrical Conduit is never stunned by EMS; other arc-resistant armor recovers sooner after leaving an EMS field, by the passive's resistance (50%: 1.5 s instead of 3 s, Desert Stormer 1.8 s). The stamina drain inside an EMS field is unchanged.
- The mod now rests while you wear no armor it works on (or its options for that armor are off): it reads no statuses and only checks your armor every 2 seconds.
- Fewer memory reads per frame (statuses and the armor check are read in fewer, larger reads).
- Fixed: the EMS changes could turn themselves off until the game restarted when the first EMS stun was already part-run (for example after turning Arc Resistance on mid-stun); a shortening that failed to write is now tried again; a burn or gas already on you is no longer counted twice in the log after the mod rests and comes back.
- Fixed: gas (and any effect whose clock runs faster than real time) now wears off sooner once you are out of it, as the option says; it was never cut short.
- Grounded only changes an arc when it looks like one, and turns itself off (and says so in the log) if the game's arcs change; a new arc reusing an earlier one's slot and id is now grounded too.
- The arc damage boost is remembered per passive for the session, so it is never applied twice, and a reload that can't start still puts the game's values back. A reload in the same game session takes over from the copy loaded before.
- The status ids the mod uses are checked against what each status does; if a game update moves them, that element's status changes turn off and the log says "status ids moved".
- Smaller fixes: status entries are re-checked right before each write, failed armor weight lookups are retried every 10 s instead of 4 times a second, a flood of errors no longer rewrites the log every frame, and the release Tester no longer runs the research logging.

## 0.5.0 (beta)

- First release: fire (Harder to Ignite, Self-Extinguish), gas (Filtration Buffer, No Gas Slow) and arc (Resistance, Grounded), each scaled by the armor passive's own resistance and your armor's weight. Mod Options Menu support.
