import ProvedSRE.Invariants

namespace SRE

/-! ## Episode goals

Pure boolean predicates over `State`. The orchestrator calls
`goalAchieved` after every step to decide episode termination and
goal-completion reward. -/

inductive Goal
  | drainNode    (n : NodeId)
  | rolloutImage (d : DeploymentId) (img : Image)
  | scaleTo      (d : DeploymentId) (replicas : Nat)
  deriving DecidableEq, Repr

def goalAchieved (s : State) : Goal → Bool
  | .drainNode n =>
      (s.pods.filter fun p => p.node = n ∧ p.phase ≠ .Failed).isEmpty
  | .rolloutImage d img =>
      (s.pods.filter fun p => p.deployment = d ∧ p.phase = .Running).all
        (fun p => decide (p.image = img))
  | .scaleTo d n =>
      decide (availableReplicas s d = n)

end SRE
