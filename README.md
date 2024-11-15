# Snake

- The snake lives on a GRID with CELLS
- CELLS are either occupied by a HEAD CELL, TAIL CELL, APPLE CELL, WALL CELL or are EMPTY
- The HEAD CELL has a rotation, which indicates the direction it will move in
- The rotation of the HEAD CELL may be changed by the player
- The snake has TAIL CELLS and one HEAD CELL
- TAIL CELLS have a time-to-live, after which they disappear so the snake moves
- If the snake tries to fill an occupied CELL other than an APPLE CELL, it dies
- If the snake tries to fill an APPLE CELL, it eats the apple and the SCORE increases
- As the SCORE increases, the time-to-live of TAIL CELLS also increases, so the snake appears longer
- WALL CELLS block the path of the snake, and can act to keep the snake from going over the EDGE
- If the snake goes over the EDGE, it wraps around as if on a torus (this could be blocked with WALL CELLS)

# Example game layout

| symbol | cell       |
| ------ | ---------- |
| w      | WALL CELL  |
| t      | TAIL CELL  |
| h      | HEAD CELL  |
| a      | APPLE CELL |

```
w t     w
w t     w
w h     w
w     a w
w t     w
```
