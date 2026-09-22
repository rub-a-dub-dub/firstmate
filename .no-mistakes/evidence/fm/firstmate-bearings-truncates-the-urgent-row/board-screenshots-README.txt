board-before.png / board-after.png - the captain-facing /bearings board, rendered
from the shipped template (.agents/skills/bearings/assets/board-template.html) with
a fm-bearings-board.v1 payload composed from each digest above and screenshotted in
headless Chrome.

Both boards cap Charted Next at 12 rows, the truncation SKILL.md describes.

  before: composed from the BASE digest. The urgent row is not in the digest at
          all, so it cannot reach the board. "SHOWING 12 OF 20".

  after:  composed from the TARGET digest following the new SKILL.md rule - read
          gates_retained and carry every row it names, never truncating one away
          in favour of a newer-filed row. The retained row "Fix the unattended
          commit + timeout on the scheduled job" is the last row of Charted Next
          and is visible. "SHOWING 13 OF 21".

Provenance note: the payload composition is the step SKILL.md instructs a composing
agent to perform; it was performed by hand here (that instruction is prose, not
code). Everything below it - the digest, gates_retained, the template render - is
the real shipped code path.
