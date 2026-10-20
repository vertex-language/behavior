// behavior/tree: composites, decorators, interruption.
package main

import (
    "behavior/tree"
)

var failures = 0

func check(_ ok: bool, _ what: string) {
    print(ok ? "ok    \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

/// Log records what actions did, in order.
final class Log {
    var lines: [string] = []
    func add(_ s: string) { lines.append(s) }
    var text: string {
        var s = ""
        for (i, l) in lines.enumerated() { s += (i > 0 ? " " : "") + l }
        return s
    }
}

/// steps is an action that runs for n ticks, then succeeds, logging each
/// start, tick and halt.
func steps(_ name: string, _ n: int, _ log: Log) -> tree.Node {
    var left = 0
    return tree.Action(name, start: { left = n; log.add("start:" + name) }, tick: { _ in
        left -= 1
        return left > 0 ? .running : .success
    }, halt: { log.add("halt:" + name) })
}

func main() -> int32 {
    // Sequence: in order, resuming the running child.
    do {
        let log = Log()
        var asked = 0
        let t = tree.Tree(tree.Sequence("seq", [tree.Condition("ok", { asked += 1; return true }), steps("a", 2, log), steps("b", 1, log)]))
        let s1 = t.Tick(0.1), s2 = t.Tick(0.1)
        check(s1 == .running && s2 == .success && log.text == "start:a halt:a start:b halt:b" && asked == 1,
              "a sequence runs its children in order and doesn't re-ask the condition before a running child (\(log.text))")
    }
    do {
        let log = Log()
        let t = tree.Tree(tree.Sequence("seq", [tree.Condition("no", { false }), steps("a", 1, log)]))
        check(t.Tick(0.1) == .failure && log.lines.isEmpty, "a sequence stops at the first failure")
    }

    // Selector: the first that succeeds.
    do {
        let log = Log()
        let t = tree.Tree(tree.Selector("sel", [tree.Condition("no", { false }), steps("a", 1, log), steps("b", 1, log)]))
        check(t.Tick(0.1) == .success && log.text == "start:a halt:a", "a selector stops at the first success")
    }

    // Priority: a more important child interrupts a running one.
    do {
        let log = Log()
        var scared = false
        let t = tree.Tree(tree.Priority("mob", [
            tree.Sequence("panic", [tree.Condition("hurt", { scared }), steps("run", 3, log)]),
            steps("wander", 10, log),
        ]))
        _ = t.Tick(0.1)
        _ = t.Tick(0.1)
        let wandering = t.Active
        scared = true
        _ = t.Tick(0.1)
        let panicking = t.Active
        scared = false
        _ = t.Tick(0.1)
        _ = t.Tick(0.1)
        _ = t.Tick(0.1)
        check(wandering == "mob › wander" && panicking == "mob › panic › run",
              "Active names the running branch (\(wandering); \(panicking))")
        check(log.text == "start:wander halt:wander start:run halt:run start:wander",
              "a priority halts a lower child when a higher one can run, and goes back after (\(log.text))")
    }

    // Parallel: walk and look at once.
    do {
        let log = Log()
        let t = tree.Tree(tree.Parallel("both", [steps("walk", 3, log), steps("look", 1, log)]))
        let a = t.Tick(0.1), b = t.Tick(0.1), c = t.Tick(0.1)
        let u = tree.Tree(tree.Parallel("both", [steps("walk", 5, Log()), tree.Priority("head", [steps("look", 5, Log())])]))
        _ = u.Tick(0.1)
        check(u.Active == "both › (walk | head › look)", "Active shows a parallel's branches (\(u.Active))")
        check(a == .running && b == .running && c == .success && log.text == "start:walk start:look halt:look halt:walk",
              "a parallel ticks every child and succeeds when all have (\(log.text))")
    }
    do {
        let log = Log()
        let t = tree.Tree(tree.Parallel("both", [steps("walk", 5, log), tree.Condition("no", { false })]))
        check(t.Tick(0.1) == .failure && log.text == "start:walk halt:walk", "one failure fails a parallel and halts the rest")
    }

    // Decorators.
    do {
        let t = tree.Tree(tree.Invert(tree.Condition("yes", { true })))
        check(t.Tick(0.1) == .failure, "Invert turns success into failure")
        let u = tree.Tree(tree.Succeed(tree.Condition("no", { false })))
        check(u.Tick(0.1) == .success, "Succeed turns failure into success")
    }
    do {
        let log = Log()
        let t = tree.Tree(tree.Cooldown(1, steps("eat", 1, log)))
        var answers: [tree.Status] = []
        for _ in 0..<12 { answers.append(t.Tick(0.25)) }
        let ran = log.lines.filter { $0 == "start:eat" }.count
        check(answers[0] == .success && answers[1] == .failure && ran == 3, "Cooldown keeps a child from running again too soon (ran \(ran) times in 3 s)")
    }
    do {
        let t = tree.Tree(tree.Wait("rest", 0.5))
        let a = t.Tick(0.2), b = t.Tick(0.2), c = t.Tick(0.2)
        check(a == .running && b == .running && c == .success, "Wait runs for its seconds, then succeeds")
    }
    do {
        let log = Log()
        let t = tree.Tree(tree.Timeout(0.3, steps("stuck", 100, log)))
        var last = tree.Status.running
        var ticks = 0
        while last == .running && ticks < 20 { last = t.Tick(0.1); ticks += 1 }
        check(last == .failure && ticks <= 4 && log.text == "start:stuck halt:stuck", "Timeout halts a child that runs too long, and fails")
    }
    do {
        let log = Log()
        var n = 0
        let t = tree.Tree(tree.Repeat(tree.Sequence("again", [tree.Condition("more", { n += 1; return n <= 3 }), steps("x", 1, log)])))
        var last = tree.Status.running
        var ticks = 0
        while last == .running && ticks < 10 { last = t.Tick(0.1); ticks += 1 }
        check(last == .failure && log.lines.filter({ $0 == "start:x" }).count == 3, "Repeat runs its child until it fails")
    }

    // Halting the tree halts the running action.
    do {
        let log = Log()
        let t = tree.Tree(tree.Priority("p", [steps("long", 50, log)]))
        _ = t.Tick(0.1)
        t.Halt()
        check(log.text == "start:long halt:long" && t.Active == "", "Halt stops what's running")
    }

    if failures == 0 { print("all passed") } else { print("\(failures) failed") }
    return failures == 0 ? 0 : 1
}
