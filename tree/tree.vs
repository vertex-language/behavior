// Package tree is behavior trees: what a character does, as a tree of
// small decisions ticked every frame. Leaves are conditions (a question)
// and actions (something that takes time: walk there, eat, look round);
// composites choose among their children; decorators change one child's
// answer or timing.
//
// Leaves are closures, so they capture whatever they act on (a mob, a
// blackboard, a game) and the tree needs no type for it. Every node keeps
// its own state, so build a tree per character.
//
// `Priority` is the composite games lean on: children in order of
// importance, the first that can run wins, and when a more important one
// becomes able to run the one running is halted. That is a mob's goal selector,
// and the root of most trees.
package tree

/// Status is how a node answers a tick.
public enum Status: Equatable {
    case success
    case failure
    /// Still going: tick it again next frame.
    case running
}

enum kind {
    case action
    case condition
    case sequence
    case selector
    case priority
    case parallel
    case invert
    case succeed
    case cooldown
    case wait
    case timeout
    case repeating
}

/// Node is one decision in a tree. Make them with the functions below.
public final class Node {
    public let Name: string
    let kind: kind
    let children: [Node]
    let start: (() -> Void)?
    let step: ((float32) -> Status)?
    let stop: (() -> Void)?
    let test: (() -> bool)?
    let seconds: float32
    /// Whether it was left running by its last tick.
    public private(set) var Running = false
    var current = -1
    var began: float64 = 0
    var readyAt: float64 = 0
    var finished: [int] = []
    var askedFrame = -1
    var answer = false

    init(name: string, kind: kind, children: [Node] = [], start: (() -> Void)? = nil,
         step: ((float32) -> Status)? = nil, stop: (() -> Void)? = nil, test: (() -> bool)? = nil, seconds: float32 = 0) {
        Name = name
        self.kind = kind
        self.children = children
        self.start = start
        self.step = step
        self.stop = stop
        self.test = test
        self.seconds = seconds
    }

    /// Tick runs the node for a frame of dt seconds ending at time now.
    func Tick(dt: float32, now: float64, frame: int) -> Status {
        let wasRunning = Running
        let s = run(dt, now, frame, wasRunning)
        Running = s == .running
        return s
    }

    // ask is a condition's answer this frame: asked once, so a condition
    // checked by Can and then by Tick (a dice roll, say) agrees with itself.
    func ask(frame: int) -> bool {
        if askedFrame != frame {
            answer = test!()
            askedFrame = frame
        }
        return answer
    }

    /// Can is whether the node could start now, judged by the conditions
    /// that guard it, without starting it: a sequence's leading
    /// conditions, a cooldown's clock. Actions can always start.
    func Can(now: float64, frame: int) -> bool {
        switch kind {
        case .condition:
            return ask(frame)
        case .sequence:
            for c in children {
                if c.kind != .condition { return c.Can(now, frame) }
                if !c.ask(frame) { return false }
            }
            return true
        case .selector, .priority:
            for c in children where c.Can(now, frame) { return true }
            return false
        case .cooldown:
            return now >= readyAt && children[0].Can(now, frame)
        case .invert:
            return children[0].kind == .condition ? !children[0].ask(frame) : true
        case .succeed, .timeout, .repeating:
            return children[0].Can(now, frame)
        case .action, .wait, .parallel:
            return true
        }
    }

    func run(dt: float32, now: float64, frame: int, resumed: bool) -> Status {
        switch kind {
        case .condition:
            return ask(frame) ? .success : .failure

        case .action:
            if !resumed, let f = start { f() }
            let s = step!(dt)
            if s != .running, let f = stop { f() }
            return s

        case .sequence, .selector:
            // Resume at the child left running; otherwise start over.
            let goOn: Status = kind == .sequence ? .success : .failure
            var i = resumed && current >= 0 ? current : 0
            while i < children.count {
                let s = children[i].Tick(dt, now, frame)
                if s == .running {
                    current = i
                    return .running
                }
                if s != goOn {
                    current = -1
                    return s
                }
                i += 1
            }
            current = -1
            return goOn

        case .priority:
            // Every tick from the top: the first child that can run and
            // doesn't fail wins. A more important child than the one
            // running halts it before it starts, so the halted one's
            // clean-up never undoes the new one's start.
            for i in 0..<children.count {
                let c = children[i]
                if i != current {
                    if !c.Can(now, frame) { continue }
                    if current > i {
                        children[current].Halt()
                        current = -1
                    }
                }
                let s = c.Tick(dt, now, frame)
                if s == .failure {
                    if current == i { current = -1 }
                    continue
                }
                if current >= 0 && current != i { children[current].Halt() }
                current = s == .running ? i : -1
                return s
            }
            if current >= 0 { children[current].Halt() }
            current = -1
            return .failure

        case .parallel:
            // Every child each tick until it finishes; one failure fails
            // the lot, and it succeeds once all have.
            if !resumed { finished = [int](repeating: 0, count: children.count) }
            var anyRunning = false
            for i in 0..<children.count where finished[i] == 0 {
                let s = children[i].Tick(dt, now, frame)
                if s == .failure {
                    for j in 0..<children.count where j != i { children[j].Halt() }
                    return .failure
                }
                if s == .success { finished[i] = 1 } else { anyRunning = true }
            }
            return anyRunning ? .running : .success

        case .invert:
            let s = children[0].Tick(dt, now, frame)
            return s == .running ? .running : (s == .success ? .failure : .success)

        case .succeed:
            let s = children[0].Tick(dt, now, frame)
            return s == .running ? .running : .success

        case .cooldown:
            if !resumed && now < readyAt { return .failure }
            let s = children[0].Tick(dt, now, frame)
            if s != .running { readyAt = now + float64(seconds) }
            return s

        case .wait:
            if !resumed { began = now - float64(dt) }
            return now - began >= float64(seconds) ? .success : .running

        case .timeout:
            if !resumed { began = now - float64(dt) }
            if now - began >= float64(seconds) {
                children[0].Halt()
                return .failure
            }
            return children[0].Tick(dt, now, frame)

        case .repeating:
            let s = children[0].Tick(dt, now, frame)
            return s == .failure ? .failure : .running
        }
    }

    /// Halt stops the node, and everything under it, where it is.
    public func Halt() {
        if !Running { return }
        Running = false
        current = -1
        if kind == .action, let f = stop { f() }
        for c in children where c.Running { c.Halt() }
    }

    /// Describe is the running branch as text: names joined by " › ", a
    /// parallel's branches in brackets between " | ".
    public func Describe() -> string {
        if !Running { return "" }
        var parts: [string] = []
        for c in children where c.Running {
            var d = c.Describe()
            // A decorator shares its child's name: say it once.
            if c.Name == Name && c.kind != .action && c.kind != .condition {
                let skip = Name + " › "
                if d.hasPrefix(skip) { d = string(d.dropFirst(skip.count)) } else if d == Name { d = "" }
            }
            if !d.isEmpty { parts.append(d) }
        }
        if parts.isEmpty { return Name }
        if parts.count == 1 { return Name + " › " + parts[0] }
        var s = Name + " › ("
        for (i, p) in parts.enumerated() { s += (i > 0 ? " | " : "") + p }
        return s + ")"
    }

    /// Active is the names along the running branch, root first.
    public func Active() -> [string] {
        if !Running { return [] }
        var out = [Name]
        for c in children where c.Running {
            // A decorator shares its child's name: say it once.
            for (i, n) in c.Active().enumerated() where !(i == 0 && n == Name) { out.append(n) }
        }
        return out
    }
}

/// Tree is a root node and the clock it runs on.
public final class Tree {
    public let Root: Node
    /// Seconds ticked so far.
    public private(set) var Now: float64 = 0
    var frame = 0

    public init(root: Node) {
        Root = root
    }

    /// Tick runs the tree for dt seconds.
    @discardableResult
    public func Tick(dt: float32) -> Status {
        Now += float64(dt)
        frame += 1
        return Root.Tick(dt, Now, frame)
    }

    /// Halt stops whatever is running.
    public func Halt() { Root.Halt() }

    /// Active is what the character is doing, for a debug line: the
    /// running branch's names, root first, " › " between, a parallel's
    /// branches in brackets.
    public var Active: string { return Root.Describe() }
}

// ---- leaves ----

/// Action is something that takes time. `start` runs when it begins,
/// `tick` each frame with the seconds passed (answer .running until it is
/// done), and `halt` when it ends for any reason: finished, failed, or
/// interrupted by something more important.
public func Action(name: string, start: (() -> Void)? = nil, tick: @escaping (float32) -> Status,
                   halt: (() -> Void)? = nil) -> Node {
    return Node(name, .action, start: start, step: tick, stop: halt)
}

/// Condition is a question: success when `test` is true.
public func Condition(name: string, test: @escaping () -> bool) -> Node {
    return Node(name, .condition, test: test)
}

/// Wait succeeds after `seconds`, running till then.
public func Wait(name: string, seconds: float32) -> Node {
    return Node(name, .wait, seconds: seconds)
}

// ---- composites ----

/// Sequence runs its children in order while they succeed: it fails at
/// the first that fails, and succeeds when all have. A child left running
/// is resumed next tick, so conditions before it aren't asked again.
public func Sequence(name: string, children: [Node]) -> Node {
    return Node(name, .sequence, children: children)
}

/// Selector tries its children in order until one succeeds, resuming a
/// running one next tick.
public func Selector(name: string, children: [Node]) -> Node {
    return Node(name, .selector, children: children)
}

/// Priority asks its children in order every tick: the first that
/// doesn't fail is its answer, and a lower one that was running is halted.
/// More important children interrupt less important ones the moment they
/// can run.
public func Priority(name: string, children: [Node]) -> Node {
    return Node(name, .priority, children: children)
}

/// Parallel ticks all its children every frame: a mob walking while it
/// looks around. It fails as soon as one fails and succeeds once all have.
public func Parallel(name: string, children: [Node]) -> Node {
    return Node(name, .parallel, children: children)
}

// ---- decorators ----

/// Invert swaps a child's success and failure.
public func Invert(child: Node) -> Node {
    return Node("not " + child.Name, .invert, children: [child])
}

/// Succeed answers success whenever its child finishes, either way.
public func Succeed(child: Node) -> Node {
    return Node(child.Name, .succeed, children: [child])
}

/// Cooldown fails for `seconds` after its child finishes, so the child
/// can't run again until then.
public func Cooldown(seconds: float32, child: Node) -> Node {
    return Node(child.Name, .cooldown, children: [child], seconds: seconds)
}

/// Timeout halts its child and fails if it runs longer than `seconds`.
public func Timeout(seconds: float32, child: Node) -> Node {
    return Node(child.Name, .timeout, children: [child], seconds: seconds)
}

/// Repeat runs its child again each time it succeeds, until it fails.
public func Repeat(child: Node) -> Node {
    return Node(child.Name, .repeating, children: [child])
}
