# behavior

[![package: vs-package](https://img.shields.io/badge/package-vs--package-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language)
[![license: MIT](https://img.shields.io/badge/license-MIT-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](LICENSE)

Deciding what to do: the minds of characters, animals and opponents.
Named `behavior`, not `ai`, which is ambiguous next to `nn` and `llm`.

---

## Packages

| Package | What it is |
| :--- | :--- |
| **`behavior/tree`** | Behavior trees. Leaves are `Condition`s (a question) and `Action`s (something that takes time, with start, tick and halt). Composites: `Sequence` and `Selector` (resuming the running child), `Priority` (asked from the top every tick; a more important child that can run halts the running one *before* it starts, as Unreal's aborts do), `Parallel`. Decorators: `Invert`, `Succeed`, `Cooldown`, `Timeout`, `Repeat`, and `Wait`. A `Tree` ticks it on its own clock and says what it's doing (`Active`). |

Leaves are closures, so they capture whatever they act on (a mob, a
blackboard, a game) and the package needs no generic context type, which
also keeps clear of `vsc`'s cross-module generic problems (`vsc_TODO.md`
#2–#5). Each node keeps its own state: build a tree per character.

Later: `behavior/utility` (scored actions) and `behavior/plan` (GOAP), as
in `proposed_graphics_v3.md` §7.2.

---

## Example

```vertex
import "behavior/tree"

// A sheep: run when hurt, else now and then wander, else stand; and,
// all the while, look at the player when close.
let mind = tree.Tree(tree.Parallel("sheep", [
    tree.Priority("act", [
        tree.Sequence("panic", [tree.Condition("hurt", { sheep.Hurt > 0 }),
                                tree.Action("run", start: { sheep.Flee() }, tick: { _ in sheep.Arrived ? .success : .running },
                                            halt: { sheep.Stop() })]),
        tree.Sequence("stroll", [tree.Condition("restless", { chance(1.0 / 6) }),
                                 tree.Timeout(15, tree.Action("walk", start: { sheep.Wander() }, tick: { _ in sheep.Arrived ? .success : .running },
                                                              halt: { sheep.Stop() }))]),
        tree.Action("stand", tick: { _ in .running }),
    ]),
    tree.Priority("look", [
        tree.Sequence("watch", [tree.Condition("player near", { sheep.SeesPlayer }), tree.Action("stare", tick: { _ in sheep.Stare() })]),
        tree.Action("ahead", tick: { _ in .running }),
    ]),
]))

mind.Tick(dt)          // every frame
print(mind.Active)     // "sheep › (act › stroll › walk | look › ahead)"
```

---

## Testing

```bash
vsc run check    # composites, interruption order, parallels, decorators, halting
```

---

## License

[MIT](LICENSE)
