# ui/components/

The shared components every screen builds from. Before changing a component, read `docs/architecture/design-system.md`.

- Preview a component in every state with `npm run gallery`; `npm test -- gallery` fails a component missing a light, dark or reduced-motion render.
- Never export a component only one screen uses; keep it in that screen's file.

---

## Not this

> | Component | Height | Padding X | Gap | Radius |
> |---|---|---|---|---|
> | `Button` md | 32 | 12 | 8 | 0 |
> | `Button` sm | 24 | 8 | 4 | 0 |
> | `TextField` | 32 | 12 | 8 | 0 |

The values duplicate the token file and are wrong the day it changes; the folder's rule is where the values live, not what they are.
