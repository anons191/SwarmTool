# Agent Swarms & Coordination — Class Notes

---

## Part 1: What Doesn't Work

### The Industry's Flawed Metaphor

- Industry models multi-agent systems on **human teams** — shared context, dynamic coordination, continuous operation
- Example: Google's agent development press releases showcase elaborate communication infrastructure
- These patterns are largely **unproductive and incorrect**
- The flaws become more visible as you scale

### Empirical Evidence

- **Cursor** and **Yagi** independently ran tests on running many agents without coordination overhead — arrived at the **same conclusion**
- **Google + MIT study**: Adding more agents can cause **actual performance degradation**, not just diminishing returns
- Past a certain threshold, **20 agents produce less than 3 ever would**

### Why More Agents = Worse Performance

- Adding agents = adding entities that need to coordinate
- Every coordination point creates: **waiting**, **duplication**, and **conflicts**
- Coordination overhead grows **superlinearly** (O(n²)) with agent count
- Agents spend more time coordinating than doing actual work

### Core Insight

> **Simplicity scales because complexity creates serial dependencies, which block the conversion of compute into capability.**

The entire point of multi-agent architecture is to convert compute into capability. Complex coordination destroys that conversion.

---

### The Community's Incorrect Guidelines

These are the prevailing "best practices" that fail at scale:

1. Multiple specialty agents should **collaborate in teams that mimic humans**
2. Agents should integrate **as many tools as useful**
3. Agents should **operate continuously**, accumulating context and learning the codebase
4. Agents should be **autonomous enough to set their own sub-goals**
5. You should be able to **scale by just adding more agents**

Each sounds reasonable at small scale. At large scale, each creates serial dependencies.

### The Failure Pattern

- Intuitive implementations create **serial dependencies** between agents
- A serial dependency is any point where one agent's work blocks another:
  - Waiting for a lock on a tool
  - Checking shared state
  - Coordinating on who handles what
- Frameworks don't warn you about this

---

## Part 2: Rules of Simplicity That Scale to Hundreds of Agents

---

### Rule 1: Two Tiers, Not Teams

**The Failed Approach — Flat Teams (Cursor Test):**

Cursor gave agents equal status and let them coordinate through a shared file. Each agent could claim tasks and update status.

Technical failures:
- Agents held locks too long
- Agents forgot to release locks
- Even working locks became bottlenecks
- Most system time was spent waiting

Behavioral failure:
- With no hierarchy, flat teams became **risk-averse**
- Agents gravitated to small, safe changes
- Hard problems sat unclaimed (claiming = responsibility for failure)
- Other agents racked up easy wins

**The Solution — Two-Tier Hierarchy:**

| Role        | Responsibility     |
|-------------|-------------------|
| **Planners** | Create tasks       |
| **Workers**  | Execute tasks      |
| **Judge**    | Evaluates results  |

**Critical design choice:** Workers do not coordinate with each other. They don't even know other workers exist.

**Worker lifecycle:** Pick up task → Execute in isolation → Push change → Terminate

**Implementation tool:** Git — branches enforce isolation naturally. Merge complexity goes to dedicated merge queue infrastructure, not to workers.

**Why exactly two tiers:** Deep hierarchies (3+ levels) accumulate drift as objectives mutate through delegation layers. Two tiers is the sweet spot — enough structure for clear delegation, not enough layers for goal drift.

---

### Rule 2: Workers Stay Ignorant

Workers work better when they don't know the full picture. When agents understand the broader project, they experience **scope creep** — deciding adjacent tasks need to be handled.

**Design Rule — Minimal Viable Context:**

> Workers receive exactly enough context to complete their assigned task and no more.

Enforce this through **information hiding**.

| Give the Worker       | Hide from the Worker        |
|----------------------|----------------------------|
| The specific task     | Broader project goals       |
| Relevant file(s)     | The full codebase           |
| Input/output spec    | Other workers' tasks        |
| Success criteria     | System architecture decisions|

The narrower the scope, the better:
- Eliminates coordination needs
- Enables true parallelism
- A worker that only knows its own function cannot decide to refactor the whole codebase

---

### Rule 3: No Shared State

**Google's finding:** In tool-heavy environments with more than 10 tools, multi-agent efficiency drops. Degradation curves appear past 30-50 tools even with unlimited context. Selection accuracy drops when agents face too many choices.

**Key insight:** Tools are shared state in multi-agent environments. Multiple agents accessing the same resources = contention. Contention requires coordination.

**Tool Strategy — Progressive Disclosure:**

| Layer                | Tools                                          |
|---------------------|-----------------------------------------------|
| **Always available** | 3-5 core tools                                 |
| **On demand**        | Additional tools discoverable as needed        |

**Coordination without shared state:**
- Code work → Git
- Non-technical tasks → Task queues

**The merge problem:** Isolated workers pushing changes will need merges. Merge complexity goes to **dedicated infrastructure** (a merge queue), not to workers.

---

### Rule 4: Plan for Endings

**The consensus (wrong):** Agents should operate continuously to accumulate context and sustain intent.

**The problem — Context Pollution:**
- As history grows, irrelevant information accumulates
- Causes drift and progressive degradation of decision quality
- Not just that the context window fills — **attention gets diluted**
- "Lost in the middle" phenomenon: models lose track of information buried in long context
- Context accumulation creates a serial dependency with the agent's own past

**The solution — Episodic Operation:**

> Run → Capture results to external storage → Kill → Next cycle starts fresh with clean context

Workers are like molecules — disposable, interchangeable units. Continuity lives in the **external task chain**, not inside the agent. When one session ends, the next picks up from external state.

**The fundamental question:**

> It's not whether an agent will stop working — it's whether your **architecture plans for endings** and designs workflows to **persist regardless**.

| Layer          | Persistence                              |
|---------------|------------------------------------------|
| **Agents**     | Ephemeral — born, execute, die           |
| **Workflows**  | Durable — survive any individual agent   |
| **State**      | External — stored in task queues, git    |

---

### Rule 5: Prompts Over Infrastructure

**The consensus (wrong):** Coordination infrastructure is where the hard engineering happens — state management, error handling, etc.

**What Cursor's project found:** A surprising amount of behavior comes down to how you prompt your agents.

**Where multi-agent failures actually come from:**
- **79%** — Spec and coordination issues
- **16%** — Infrastructure bugs
- **5%** — Other

The industry spends most effort on 16% of the problem.

**The takeaway:**

> Treat your prompts like **API contracts**. Ensure agents operate in settings simple enough that a clear spec alone allows the agent to perform well.

A prompt-as-contract defines:
- **Inputs** — what the agent receives
- **Outputs** — what the agent must produce
- **Boundaries** — what the agent must not do
- **Success criteria** — how the result is evaluated

Good prompts + good isolation = less infrastructure needed.

---

## The Apparent Contradiction: Where Complexity Lives

**The objection:** "You said simplicity scales — but this system sounds complex."

**The resolution:** Complexity can live in two places with very different scaling properties.

| Where Complexity Lives  | Small Scale      | Large Scale                     |
|------------------------|------------------|---------------------------------|
| **In the agents**       | Works fine       | Serial dependencies → breaks    |
| **In the orchestration**| Unnecessary      | Enables parallelism → scales    |

**The formula:**
- Complex agents + Simple orchestration → Breaks at scale
- Simple agents + Complex orchestration → Scales

**The investment implication:**

> Engineering investment should go into **orchestration**, not into **agent intelligence**.

| Invest Here            | Not Here                    |
|-----------------------|-----------------------------|
| Task distribution      | Smarter agents              |
| Merge queues           | More tools per agent        |
| Lifecycle management   | Longer context windows      |
| Evaluation systems     | Agent autonomy              |
| Prompt contracts       | Inter-agent communication   |

The industry has it backwards — pouring resources into making agents smarter, more autonomous, and more capable. The scalable path is **dumb workers, smart orchestration**.

---

## The 2026 Lesson (Summary)

> If you want to run 100 agents that actually produce results, you need to be **philosophically committed to simplicity** — and you arrive there because everything else fails.

**The five rules:**
1. **Two tiers, not teams** — Planners, workers, judges. Workers are isolated.
2. **Workers stay ignorant** — Minimal viable context. Information hiding.
3. **No shared state** — Small tool sets, progressive disclosure, dedicated merge infrastructure.
4. **Plan for endings** — Episodic operation. Agents are ephemeral, workflows persist.
5. **Prompts over infrastructure** — Treat prompts like API contracts. 79% of failures are spec issues.

**The heart of it:** Complexity in agents creates serial dependencies. Complexity in orchestration enables parallelism. Invest accordingly.
