import ProvedSRE.Api

namespace SRE

private theorem foldlM_ok_all {α ε : Type _} (xs : List α) (f : α → Except ε Unit) :
    xs.foldlM (init := ()) (fun _ a => f a) = .ok () ↔ ∀ a ∈ xs, f a = .ok () := by
  induction xs with
  | nil => simp [List.foldlM, pure, Except.pure]
  | cons x xs ih =>
    rw [List.foldlM_cons]
    constructor
    · intro h a ha
      cases hfx : f x with
      | error _ => rw [hfx] at h; cases h
      | ok _ =>
        rw [hfx] at h
        rcases List.mem_cons.mp ha with rfl | hmem
        · exact hfx
        · exact (ih.mp h) a hmem
    · intro h
      have hx := h x (List.mem_cons.mpr (Or.inl rfl))
      rw [hx]
      exact ih.mpr fun a ha => h a (List.mem_cons.mpr (Or.inr ha))

theorem postCheck_iff {s' : State} {v : ApiVerb} :
    postCheck s' v = .ok () ↔ ∀ p ∈ invariants, p.2 s' = true := by
  unfold postCheck
  rw [foldlM_ok_all]
  constructor <;> intro h ⟨ik, p⟩ hmem
  · have := h ⟨ik, p⟩ hmem
    by_cases hp : p s' = true
    · exact hp
    · simp [hp] at this
  · have hp := h ⟨ik, p⟩ hmem
    show (if p s' then _ else _) = _
    rw [if_pos hp]

theorem admitSafe (s : State) (v : ApiVerb) (h : admit s v = .ok ()) :
    safe (apply s v) = true := by
  unfold safe; rw [List.all_eq_true]
  unfold admit at h
  cases hpre : preCheck s v with
  | error _ => rw [hpre] at h; cases h
  | ok _ => rw [hpre] at h; exact postCheck_iff.mp h

theorem admit_ok_of_safe (s : State) (v : ApiVerb)
    (hpre : preCheck s v = .ok ()) (hsafe : safe (apply s v) = true) :
    admit s v = .ok () := by
  unfold admit; rw [hpre]
  exact postCheck_iff.mpr (List.all_eq_true.mp hsafe)

def runApiPlan : State → List ApiVerb → Except Reject State
  | s, []      => .ok s
  | s, v :: vs =>
    match admit s v with
    | .error r => .error r
    | .ok _   => runApiPlan (apply s v) vs

theorem runApiPlan_safe : ∀ (s : State) (vs : List ApiVerb) (sf : State),
    safe s = true → runApiPlan s vs = .ok sf → safe sf = true := by
  intro s vs
  induction vs generalizing s with
  | nil => intro sf hs h; simp [runApiPlan] at h; cases h; exact hs
  | cons v vs ih =>
    intro sf hs h
    simp [runApiPlan] at h
    cases hadm : admit s v with
    | error _ => rw [hadm] at h; cases h
    | ok _ => rw [hadm] at h; exact ih (apply s v) sf (admitSafe s v hadm) h

end SRE
