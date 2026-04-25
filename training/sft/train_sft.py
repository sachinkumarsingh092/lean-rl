#!/usr/bin/env python3
"""SFT fine-tune Qwen3-1.7B on seed_plans.jsonl via Unsloth + LoRA."""
from __future__ import annotations

import json
from pathlib import Path
from datasets import Dataset
from unsloth import FastLanguageModel
from trl import SFTTrainer, SFTConfig

MODEL = "unsloth/Qwen3-4B-unsloth-bnb-4bit"
SEED_FILE = Path(__file__).resolve().parent / "seed_plans.jsonl"
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


def to_chat(row: dict) -> dict:
    messages = [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": json.dumps({"state": row["state"], "goal": row["goal"]})},
        {"role": "assistant", "content": json.dumps(row["verbs"])},
    ]
    return {"text": tokenizer.apply_chat_template(messages, tokenize=False, enable_thinking=False)}


rows = [json.loads(l) for l in SEED_FILE.read_text().splitlines() if l.strip()]
ds = Dataset.from_list([to_chat(r) for r in rows])

trainer = SFTTrainer(
    model=model, tokenizer=tokenizer, train_dataset=ds,
    args=SFTConfig(
        output_dir=str(OUT_DIR), num_train_epochs=10,
        per_device_train_batch_size=2, learning_rate=1e-4,
        logging_steps=1, save_strategy="epoch",
    ),
)
trainer.train()
model.save_pretrained(OUT_DIR / "final")
tokenizer.save_pretrained(OUT_DIR / "final")
print(f"Saved to {OUT_DIR / 'final'}")
