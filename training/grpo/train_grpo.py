#!/usr/bin/env python3
"""GRPO fine-tune SRE agent via TRL GRPOTrainer + in-process Lean env reward."""
from __future__ import annotations

import json
import sys
from pathlib import Path

from datasets import Dataset
from unsloth import FastLanguageModel
from trl import GRPOTrainer, GRPOConfig

ROOT = Path(__file__).resolve().parent.parent.parent

sys.path.insert(0, str(ROOT))
from lean_rl.server.lean_rl_environment import LeanRlEnvironment
from lean_rl.models import SREAction

MODEL = str(ROOT / "training" / "sft" / "output" / "final")
SEED_FILE = ROOT / "training" / "sft" / "seed_plans.jsonl"
OUT_DIR = Path(__file__).resolve().parent / "output"

SYSTEM = (
    "You are an SRE agent. Given a cluster state and a goal, "
    "output the JSON list of verbs that achieve the goal."
)

model, tokenizer = FastLanguageModel.from_pretrained(MODEL, max_seq_length=4096)
model = FastLanguageModel.get_peft_model(
    model, r=16, lora_alpha=16,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                     "gate_proj", "up_proj", "down_proj"],
)

# -- prompt dataset from seed plans ------------------------------------------

rows = [json.loads(l) for l in SEED_FILE.read_text().splitlines() if l.strip()]

def _make_prompt(row: dict) -> dict:
    msgs = [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": json.dumps({"state": row["state"], "goal": row["goal"]})},
    ]
    return {
        "prompt": tokenizer.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True, enable_thinking=False),
        "state": json.dumps(row["state"]),
        "goal": json.dumps(row["goal"]),
    }

dataset = Dataset.from_list([_make_prompt(r) for r in rows])

# -- reward via in-process env ------------------------------------------------

_env = LeanRlEnvironment()

def reward_fn(completions: list[str], state: list[str], goal: list[str], **kwargs) -> list[float]:
    rewards = []
    for text, s_json, g_json in zip(completions, state, goal):
        text = text.strip()
        start, end = text.find('['), text.rfind(']')
        if start == -1 or end == -1:
            rewards.append(-2.0)
            continue
        try:
            verbs = json.loads(text[start:end + 1])
            if not isinstance(verbs, list):
                verbs = [verbs]
        except (json.JSONDecodeError, TypeError):
            rewards.append(-2.0)
            continue

        s, g = json.loads(s_json), json.loads(g_json)
        _env._episode = {"initial_state": s, "goal": g, "max_steps": 8}
        _env._world.reset(s)
        _env._step_idx = 0
        _env._done = False

        total = 0.0
        for verb in verbs[:8]:
            if not isinstance(verb, dict):
                total += -1.0
                continue
            obs = _env.step(SREAction(verb=verb))
            total += obs.reward
            if obs.done:
                break
        rewards.append(max(min(total, 6.0), -3.0))
    return rewards

# -- train --------------------------------------------------------------------

trainer = GRPOTrainer(
    model=model,
    processing_class=tokenizer,
    reward_funcs=reward_fn,
    train_dataset=dataset,
    args=GRPOConfig(
        output_dir=str(OUT_DIR),
        num_train_epochs=1,
        per_device_train_batch_size=2,
        gradient_accumulation_steps=1,
        num_generations=4,
        max_completion_length=512,
        logging_steps=1,
        save_strategy="steps",
        save_steps=50,
        max_steps=200,
        beta=0.1,
        learning_rate=5e-6,
        warmup_steps=20,
        temperature=1.0,
        top_p=0.95,
    ),
)
trainer.train()
model.save_pretrained(OUT_DIR / "final")
tokenizer.save_pretrained(OUT_DIR / "final")
