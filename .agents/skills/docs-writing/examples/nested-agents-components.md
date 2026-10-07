# ui/components/

The shared components every screen builds from. Before changing a component, read `docs/architecture/design-system.md`.

- Preview a component with `npm run gallery`; test its renders with `npm test -- gallery`.

---

## Not this

> | Component | Height | Padding X | Gap | Radius |
> |---|---|---|---|---|
> | `Button` md | 32 | 12 | 8 | 0 |
> | `Button` sm | 24 | 8 | 4 | 0 |
> | `TextField` | 32 | 12 | 8 | 0 |

The values duplicate the token file and are wrong the day it changes; the folder's reading trigger leads to the principle doc that owns the token rule.
