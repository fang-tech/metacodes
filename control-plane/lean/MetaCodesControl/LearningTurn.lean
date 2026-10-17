import Std

/-! # Learning turn: formal policy

The runtime (`src/core/learning_turn.zig`, wired in `agent_loop.zig`, and its
end-of-run form `src/core/learning_end_of_run.zig`) gives the model one
learning turn after a grounded host verdict: a distill pass that may write up
to four conditioned lessons under a host-bound header, then a reconcile pass
only when the distill pass accepted a lesson and stored lessons existed to
reconcile against. What counts as a lesson, how its header is bound and how
the verdict is graded stay engineering; the POLICY is proven here:

* no verdict, no lesson — an unchecked or unavailable verdict never decides a
  distill pass;
* a tainted verdict never teaches, in either mode;
* a grounded verdict with no ready store never spends a pass;
* a reconcile pass follows only a distill pass that accepted a lesson, with
  stored lessons to reconcile against;
* over ANY trace of loop events a run decides at most once, runs at most two
  passes and appends at most two host messages, each pass runs at most
  `passMaxTurns` model turns, and at most `maxPerTurn` lessons are accepted;
* observe mode decides and records but never appends a message;
* the attempt's answer is final before any learning message: a message is
  appended only after the terminal boundary closed the final segment.

Each theorem names the mirroring Zig test. -/

namespace MetaCodesControl.LearningTurn

/-- Mirrors the Zig `PASS_MAX_TURNS`. -/
def passMaxTurns : Nat := 6

/-- Mirrors the Zig `lesson.MAX_PER_TURN`. -/
def maxPerTurn : Nat := 4

inductive Mode where
  | enforce
  | observe
  deriving Repr, DecidableEq

inductive Grounding where
  | unchecked
  | passed
  | failed
  | tainted
  | unavailable
  deriving Repr, DecidableEq

inductive Decision where
  | noneUnfinished
  | noneUnchecked
  | noneUnavailable
  | noneTainted
  | noneUnstorable
  | distill
  deriving Repr, DecidableEq

/-- Transcription of `learning_turn.decide`. -/
def decide (g : Grounding) (storeReady : Bool) : Decision :=
  match g with
  | .unchecked => .noneUnchecked
  | .unavailable => .noneUnavailable
  | .tainted => .noneTainted
  | .passed => if storeReady then .distill else .noneUnstorable
  | .failed => if storeReady then .distill else .noneUnstorable

inductive Next where
  | reconcile
  | finish
  deriving Repr, DecidableEq

/-- Transcription of `learning_turn.afterDistill`. -/
def afterDistill (accepted existing : Nat) : Next :=
  if 0 < accepted ∧ 0 < existing then .reconcile else .finish

/-- No verdict, no lesson: an unchecked or unavailable boundary never decides
a distill pass, whatever the store.  Zig mirror: "unavailable_never_learns /
unchecked / tainted_never_learns". -/
theorem unavailable_never_learns (r : Bool) :
    decide .unavailable r ≠ .distill ∧ decide .unchecked r ≠ .distill := by
  simp [decide]

/-- A tainted verdict never teaches, in either mode (the decision does not read
the mode).  Zig mirror: "unavailable_never_learns / unchecked /
tainted_never_learns". -/
theorem tainted_never_learns (r : Bool) : decide .tainted r = .noneTainted := by
  simp [decide]

/-- A grounded verdict with no ready store spends no pass.  Zig mirror:
"unstorable_never_learns: a grounded verdict with no store runs no pass". -/
theorem unstorable_never_learns (g : Grounding) : decide g false ≠ .distill := by
  cases g <;> simp [decide]

/-- Exactly a passed or failed verdict with a ready store decides a distill
pass.  Zig mirror: "distill_iff: only a passed or failed verdict with a ready
store distills". -/
theorem distill_iff (g : Grounding) (r : Bool) :
    decide g r = .distill ↔ (g = .passed ∨ g = .failed) ∧ r = true := by
  cases g <;> cases r <;> simp [decide]

/-- A reconcile pass needs an accepted lesson and something stored to
reconcile against.  Zig mirror: "reconcile_requires_lesson: no lesson or
nothing stored means finish". -/
theorem reconcile_requires_lesson (accepted existing : Nat)
    (h : afterDistill accepted existing = .reconcile) : 0 < accepted ∧ 0 < existing := by
  unfold afterDistill at h
  by_cases hc : 0 < accepted ∧ 0 < existing
  · exact hc
  · simp [hc] at h

inductive Phase where
  | idle
  | distill
  | reconcile
  deriving Repr, DecidableEq

structure State where
  /-- The terminal boundary decided (`State.decision != null`). -/
  decided : Bool
  /-- The attempt's final segment is closed (`output_channel.close(.final)`). -/
  finalClosed : Bool
  phase : Phase
  passes : Nat
  passTurns : Nat
  /-- Host learning messages appended to the conversation. -/
  messages : Nat
  /-- Lessons accepted in this learning turn (`Binding.accepted`). -/
  accepted : Nat
  /-- Lessons accepted when the distill pass ended (`distill_accepted`). -/
  distillAccepted : Nat
  deriving Repr, DecidableEq

def fresh : State :=
  { decided := false, finalClosed := false, phase := .idle, passes := 0, passTurns := 0,
    messages := 0, accepted := 0, distillAccepted := 0 }

/-- What the loop does. `terminal` is the run's terminal boundary with the
grounding the check gate left; `turn` starts a model turn (`beginPassTurn`);
`accept` is a `KgRemember` of kind `lesson` that passed the header binding
(`Binding.reserve`); `passEnd` is a turn group that ended without tool calls,
with the number of stored lessons the distill message listed. -/
inductive Event where
  | terminal (g : Grounding)
  | turn
  | accept
  | passEnd (existing : Nat)
  deriving Repr, DecidableEq


def stepTerminal (mode : Mode) (storeReady : Bool) (s : State) (g : Grounding) : State :=
  if s.decided = true then s
  else if decide g storeReady = .distill ∧ mode = .enforce then
    { s with decided := true, finalClosed := true, phase := .distill, passes := s.passes + 1,
             passTurns := 0, messages := s.messages + 1 }
  else
    { s with decided := true, finalClosed := true }

def stepTurn (s : State) : State :=
  if s.phase = .idle then s
  else if s.passTurns < passMaxTurns then { s with passTurns := s.passTurns + 1 }
  else { s with phase := .idle }

def stepAccept (s : State) : State :=
  if s.phase ≠ .idle ∧ s.accepted < maxPerTurn then { s with accepted := s.accepted + 1 } else s

def stepPassEnd (s : State) (existing : Nat) : State :=
  if s.phase = .distill then
    if afterDistill s.accepted existing = .reconcile then
      { s with phase := .reconcile, passes := s.passes + 1, passTurns := 0,
               messages := s.messages + 1, distillAccepted := s.accepted }
    else
      { s with phase := .idle, distillAccepted := s.accepted }
  else if s.phase = .reconcile then { s with phase := .idle }
  else s

/-- Line-for-line transcription of the learning-turn transitions in
`agent_loop`. The terminal boundary is reached once: it closes the final
segment, decides, and in enforce mode appends the distill message. A pass turn
beyond the cap ends the pass (`truncated`). An accepted lesson takes a slot
while one is free. A distill pass that ends either earns the reconcile
message or finishes; a reconcile pass that ends finishes. -/
def step (mode : Mode) (storeReady : Bool) (s : State) : Event → State
  | .terminal g => stepTerminal mode storeReady s g
  | .turn => stepTurn s
  | .accept => stepAccept s
  | .passEnd existing => stepPassEnd s existing

def run (mode : Mode) (storeReady : Bool) : List Event → State → State
  | [], s => s
  | e :: rest, s => run mode storeReady rest (step mode storeReady s e)

/-- The trace invariant. -/
def Inv (s : State) : Prop :=
  s.messages = s.passes ∧ s.passes ≤ 2 ∧ s.passTurns ≤ passMaxTurns ∧
    s.accepted ≤ maxPerTurn ∧
    (s.decided = false → s.passes = 0 ∧ s.phase = .idle ∧ s.finalClosed = false) ∧
    (0 < s.passes → s.decided = true ∧ s.finalClosed = true) ∧
    (s.phase = .distill → s.passes = 1) ∧
    (s.phase = .reconcile → s.passes = 2) ∧
    (2 ≤ s.passes → 0 < s.distillAccepted)

theorem fresh_inv : Inv fresh := by
  simp [Inv, fresh, passMaxTurns, maxPerTurn]

theorem terminal_inv (mode : Mode) (storeReady : Bool) (s : State) (g : Grounding) (h : Inv s) :
    Inv (stepTerminal mode storeReady s g) := by
  obtain ⟨hm, hp, ht, ha, hfresh, hdone, hdist, hrec, hacc⟩ := h
  unfold stepTerminal
  split
  · exact ⟨hm, hp, ht, ha, hfresh, hdone, hdist, hrec, hacc⟩
  · rename_i hd
    have hd' : s.decided = false := by simpa using hd
    obtain ⟨hp0, hidle, _⟩ := hfresh hd'
    split
    · refine ⟨?_, ?_, ?_, ha, ?_, ?_, ?_, ?_, ?_⟩
      · show s.messages + 1 = s.passes + 1
        rw [hm]
      · show s.passes + 1 ≤ 2
        omega
      · show 0 ≤ passMaxTurns
        exact Nat.zero_le _
      · intro hf; simp at hf
      · intro _; exact ⟨rfl, rfl⟩
      · intro _; show s.passes + 1 = 1; omega
      · intro hph; simp at hph
      · intro h2; show 0 < s.distillAccepted; simp only at h2; omega
    · refine ⟨hm, hp, ht, ha, ?_, ?_, ?_, ?_, hacc⟩
      · intro hf; simp at hf
      · intro _; exact ⟨rfl, rfl⟩
      · intro hph; simp only at hph; rw [hidle] at hph; simp at hph
      · intro hph; simp only at hph; rw [hidle] at hph; simp at hph

theorem turn_inv (s : State) (h : Inv s) : Inv (stepTurn s) := by
  obtain ⟨hm, hp, ht, ha, hfresh, hdone, hdist, hrec, hacc⟩ := h
  unfold stepTurn
  split
  · exact ⟨hm, hp, ht, ha, hfresh, hdone, hdist, hrec, hacc⟩
  · rename_i hni
    split
    · rename_i hlt
      exact ⟨hm, hp, Nat.succ_le_of_lt hlt, ha, hfresh, hdone, hdist, hrec, hacc⟩
    · refine ⟨hm, hp, ht, ha, ?_, hdone, ?_, ?_, hacc⟩
      · intro hf
        exact absurd (hfresh hf).2.1 hni
      · intro hph; simp at hph
      · intro hph; simp at hph

theorem accept_inv (s : State) (h : Inv s) : Inv (stepAccept s) := by
  obtain ⟨hm, hp, ht, ha, hfresh, hdone, hdist, hrec, hacc⟩ := h
  unfold stepAccept
  split
  · rename_i hc
    exact ⟨hm, hp, ht, Nat.succ_le_of_lt hc.2, hfresh, hdone, hdist, hrec, hacc⟩
  · exact ⟨hm, hp, ht, ha, hfresh, hdone, hdist, hrec, hacc⟩

theorem passEnd_inv (s : State) (existing : Nat) (h : Inv s) : Inv (stepPassEnd s existing) := by
  obtain ⟨hm, hp, ht, ha, hfresh, hdone, hdist, hrec, hacc⟩ := h
  unfold stepPassEnd
  split
  · rename_i hph
    have hp1 : s.passes = 1 := hdist hph
    have hdec : s.decided = true ∧ s.finalClosed = true := hdone (by omega)
    split
    · rename_i hnext
      have hpos := reconcile_requires_lesson s.accepted existing hnext
      refine ⟨?_, ?_, ?_, ha, ?_, ?_, ?_, ?_, ?_⟩
      · show s.messages + 1 = s.passes + 1
        rw [hm]
      · show s.passes + 1 ≤ 2
        omega
      · show 0 ≤ passMaxTurns
        exact Nat.zero_le _
      · intro hf; simp only at hf; rw [hdec.1] at hf; simp at hf
      · intro _; exact hdec
      · intro hph'; simp at hph'
      · intro _; show s.passes + 1 = 2; omega
      · intro _; exact hpos.1
    · refine ⟨hm, hp, ht, ha, ?_, hdone, ?_, ?_, ?_⟩
      · intro hf; simp only at hf; rw [hdec.1] at hf; simp at hf
      · intro hph'; simp at hph'
      · intro hph'; simp at hph'
      · intro h2; simp only at h2; omega
  · split
    · rename_i _ hph
      refine ⟨hm, hp, ht, ha, ?_, hdone, ?_, ?_, hacc⟩
      · intro hf
        have hi := (hfresh hf).2.1
        rw [hph] at hi
        simp at hi
      · intro hph'; simp at hph'
      · intro hph'; simp at hph'
    · exact ⟨hm, hp, ht, ha, hfresh, hdone, hdist, hrec, hacc⟩

theorem step_inv (mode : Mode) (storeReady : Bool) (s : State) (e : Event) (h : Inv s) :
    Inv (step mode storeReady s e) := by
  cases e with
  | terminal g => exact terminal_inv mode storeReady s g h
  | turn => exact turn_inv s h
  | accept => exact accept_inv s h
  | passEnd existing => exact passEnd_inv s existing h

theorem run_inv (mode : Mode) (storeReady : Bool) (trace : List Event) (s : State)
    (h : Inv s) : Inv (run mode storeReady trace s) := by
  induction trace generalizing s with
  | nil => exact h
  | cons e rest ih => exact ih _ (step_inv mode storeReady s e h)

/-- One learning turn per run: over ANY trace a fresh run runs at most two
passes and appends at most two host messages.  Zig mirror: "pass turns are
capped per pass and counted per phase" (`passes`) and the component test
"with stored lessons an accepted lesson earns one reconcile pass". -/
theorem turns_bounded (mode : Mode) (storeReady : Bool) (trace : List Event) :
    (run mode storeReady trace fresh).passes ≤ 2 ∧ (run mode storeReady trace fresh).messages ≤ 2 := by
  obtain ⟨hm, hp, _⟩ := run_inv mode storeReady trace fresh fresh_inv
  exact ⟨hp, hm ▸ hp⟩

/-- A pass never runs more than `passMaxTurns` model turns.  Zig mirror: "pass
turns are capped per pass and counted per phase". -/
theorem pass_turns_bounded (mode : Mode) (storeReady : Bool) (trace : List Event) :
    (run mode storeReady trace fresh).passTurns ≤ passMaxTurns :=
  (run_inv mode storeReady trace fresh fresh_inv).2.2.1

/-- At most `maxPerTurn` lessons are accepted in a learning turn.  Zig mirror:
"binding: header is exact, mismatches are refused, slots are bounded". -/
theorem lessons_bounded (mode : Mode) (storeReady : Bool) (trace : List Event) :
    (run mode storeReady trace fresh).accepted ≤ maxPerTurn :=
  (run_inv mode storeReady trace fresh fresh_inv).2.2.2.1

/-- Over any trace, a second pass (reconcile) only follows a distill pass that
accepted a lesson.  Zig mirror: "reconcile_requires_lesson: no lesson or
nothing stored means finish". -/
theorem reconcile_follows_accepted_lesson (mode : Mode) (storeReady : Bool) (trace : List Event)
    (h : 2 ≤ (run mode storeReady trace fresh).passes) :
    0 < (run mode storeReady trace fresh).distillAccepted :=
  (run_inv mode storeReady trace fresh fresh_inv).2.2.2.2.2.2.2.2 h

/-- The answer is final before any learning message: a run that appended one
has closed its final segment at the terminal boundary.  Zig mirror (component):
"a failed verdict gets one distill pass, the lesson is stored, the answer stays
final". -/
theorem answer_is_final (mode : Mode) (storeReady : Bool) (trace : List Event)
    (h : 0 < (run mode storeReady trace fresh).messages) :
    (run mode storeReady trace fresh).finalClosed = true := by
  obtain ⟨hm, _, _, _, _, hdone, _⟩ := run_inv mode storeReady trace fresh fresh_inv
  exact (hdone (hm ▸ h)).2

/-- In observe mode no transition appends a message or starts a pass. -/
theorem observe_step_quiet (storeReady : Bool) (s : State) (e : Event)
    (hidle : s.phase = .idle) :
    (step .observe storeReady s e).phase = .idle ∧
      (step .observe storeReady s e).messages = s.messages := by
  cases e with
  | terminal g =>
    show (stepTerminal .observe storeReady s g).phase = .idle ∧
      (stepTerminal .observe storeReady s g).messages = s.messages
    unfold stepTerminal
    split
    · exact ⟨hidle, rfl⟩
    · split
      · rename_i _ hc; exact absurd hc.2 (by decide)
      · exact ⟨hidle, rfl⟩
  | turn =>
    show (stepTurn s).phase = .idle ∧ (stepTurn s).messages = s.messages
    unfold stepTurn
    rw [if_pos hidle]
    exact ⟨hidle, rfl⟩
  | accept =>
    show (stepAccept s).phase = .idle ∧ (stepAccept s).messages = s.messages
    unfold stepAccept
    split
    · exact ⟨hidle, rfl⟩
    · exact ⟨hidle, rfl⟩
  | passEnd existing =>
    show (stepPassEnd s existing).phase = .idle ∧ (stepPassEnd s existing).messages = s.messages
    unfold stepPassEnd
    rw [if_neg (by rw [hidle]; decide), if_neg (by rw [hidle]; decide)]
    exact ⟨hidle, rfl⟩

/-- Observe mode decides and records but never appends a learning message,
over ANY trace.  Zig mirror (component): "observe mode decides and injects
nothing". -/
theorem observe_never_injects (storeReady : Bool) (trace : List Event) :
    (run .observe storeReady trace fresh).messages = 0 := by
  have key : ∀ (t : List Event) (s : State), s.phase = .idle → s.messages = 0 →
      (run .observe storeReady t s).messages = 0 := by
    intro t
    induction t with
    | nil => intro s _ hm; exact hm
    | cons e rest ih =>
      intro s hidle hm
      obtain ⟨hidle', hm'⟩ := observe_step_quiet storeReady s e hidle
      exact ih _ hidle' (hm'.trans hm)
  exact key trace fresh rfl rfl

end MetaCodesControl.LearningTurn
