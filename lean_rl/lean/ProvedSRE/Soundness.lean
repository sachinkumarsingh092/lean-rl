import ProvedSRE.Api

namespace SRE

/-! ## Admission soundness

If the admission gate accepts a verb, the post-state respects every
invariant. We prove each invariant separately and combine them into
`admitSafe`. The proofs all follow the same shape: case-split on each
guard inside `postCheck` until the active branch yields the goal. -/

theorem postCheck_ok_pdb {s' : State} {v : ApiVerb}
    (h : postCheck s' v = .ok ()) : pdbRespected s' = true := by
  unfold postCheck at h
  cases hp : pdbRespected s' with
  | false => rw [hp] at h; simp at h
  | true  => rfl

theorem postCheck_ok_capacity {s' : State} {v : ApiVerb}
    (h : postCheck s' v = .ok ()) : capacityRespected s' = true := by
  unfold postCheck at h
  cases hp : pdbRespected s' with
  | false => rw [hp] at h; simp at h
  | true  =>
      rw [hp] at h; simp at h
      cases hc : capacityRespected s' with
      | false => rw [hc] at h; simp at h
      | true  => rfl

theorem postCheck_ok_antiAffinity {s' : State} {v : ApiVerb}
    (h : postCheck s' v = .ok ()) : antiAffinityRespected s' = true := by
  unfold postCheck at h
  cases hp : pdbRespected s' with
  | false => rw [hp] at h; simp at h
  | true  =>
      rw [hp] at h; simp at h
      cases hc : capacityRespected s' with
      | false => rw [hc] at h; simp at h
      | true  =>
          rw [hc] at h; simp at h
          cases ha : antiAffinityRespected s' with
          | false => rw [ha] at h; simp at h
          | true  => rfl

private theorem admitOk_postCheck {s : State} {v : ApiVerb}
    (h : admit s v = .ok ()) : postCheck (apply s v) v = .ok () := by
  unfold admit at h
  cases hpre : preCheck s v with
  | error _ => rw [hpre] at h; cases h
  | ok _    => rw [hpre] at h; exact h

theorem pdbAdmissionSound (s : State) (v : ApiVerb)
    (h : admit s v = .ok ()) : pdbRespected (apply s v) = true :=
  postCheck_ok_pdb (admitOk_postCheck h)

theorem capacityAdmissionSound (s : State) (v : ApiVerb)
    (h : admit s v = .ok ()) : capacityRespected (apply s v) = true :=
  postCheck_ok_capacity (admitOk_postCheck h)

theorem antiAffinityAdmissionSound (s : State) (v : ApiVerb)
    (h : admit s v = .ok ()) : antiAffinityRespected (apply s v) = true :=
  postCheck_ok_antiAffinity (admitOk_postCheck h)

theorem admitSafe (s : State) (v : ApiVerb)
    (h : admit s v = .ok ()) : safe (apply s v) = true := by
  unfold safe
  rw [pdbAdmissionSound s v h,
      capacityAdmissionSound s v h,
      antiAffinityAdmissionSound s v h]
  rfl

end SRE
