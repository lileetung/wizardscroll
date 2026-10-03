#!/usr/bin/env python3
"""Persistent newline-JSON bridge between the Swift app and Qwen models on MLX.

It runs Qwen3-ASR for speech recognition and a Qwen text model for polishing.
"""

from __future__ import annotations

import copy
import gc
import json
import sys
import traceback
import wave
from collections import OrderedDict
from typing import Any

import numpy as np
from mlx_qwen3_asr import Session

SAMPLE_RATE = 16_000


sessions: dict[str, Session] = {}
# Only the selected text model stays loaded; switching models frees the old one.
text_models: dict[str, tuple[Any, Any]] = {}
# Model state after the system prompt, keyed by its tokens. Every request for
# the same destination app shares that prompt, so it is computed only once.
# Qwen3.5 mixes in recurrent layers whose state cannot be rewound, so a cached
# prompt is reused only when it matches exactly, never partially.
prompt_caches: OrderedDict[tuple[int, ...], Any] = OrderedDict()
MAX_PROMPT_CACHES = 4


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def get_session(model: str) -> Session:
    session = sessions.get(model)
    if session is None:
        print(f"Loading {model}", file=sys.stderr, flush=True)
        session = Session(model=model)
        sessions[model] = session
    return session


def get_text_model(model: str) -> tuple[Any, Any]:
    entry = text_models.get(model)
    if entry is None:
        # Imported on first use, so speech recognition starts without it.
        import mlx.core as mx
        from mlx_lm import load

        text_models.clear()
        prompt_caches.clear()
        gc.collect()
        mx.clear_cache()
        print(f"Loading {model}", file=sys.stderr, flush=True)
        entry = load(model)
        text_models[model] = entry
    return entry


def chat_tokens(tokenizer: Any, messages: list[dict[str, str]]) -> list[int]:
    return tokenizer.apply_chat_template(
        messages,
        add_generation_prompt=True,
        enable_thinking=False,
    )


def system_prefix(tokenizer: Any, messages: list[dict[str, str]]) -> list[int]:
    """Tokens before the user's text: the system prompt and the user header."""
    system = [m for m in messages if m["role"] != "user"]
    first = chat_tokens(tokenizer, [*system, {"role": "user", "content": "A"}])
    second = chat_tokens(tokenizer, [*system, {"role": "user", "content": "B"}])
    length = next(i for i, (a, b) in enumerate(zip(first, second)) if a != b)
    return first[:length]


def prefilled_cache(model: Any, prefix: list[int]) -> Any:
    """A copy of the model state after `prefix`, computing it on a miss."""
    import mlx.core as mx
    from mlx_lm.models.cache import make_prompt_cache

    key = tuple(prefix)
    cache = prompt_caches.get(key)
    if cache is None:
        cache = make_prompt_cache(model)
        model(mx.array(prefix)[None], cache=cache)
        mx.eval([c.state for c in cache])
        prompt_caches[key] = cache
        while len(prompt_caches) > MAX_PROMPT_CACHES:
            prompt_caches.popitem(last=False)
    prompt_caches.move_to_end(key)
    return copy.deepcopy(cache)


def prepare(message: dict[str, Any]) -> None:
    model, tokenizer = get_text_model(str(message["model"]))
    if message.get("messages"):
        prefilled_cache(model, system_prefix(tokenizer, message["messages"]))


def polish(message: dict[str, Any]) -> str:
    from mlx_lm import generate
    from mlx_lm.sample_utils import make_sampler

    model, tokenizer = get_text_model(str(message["model"]))
    messages = message["messages"]
    tokens = chat_tokens(tokenizer, messages)
    prefix = system_prefix(tokenizer, messages)
    if tokens[: len(prefix)] == prefix and len(tokens) > len(prefix):
        cache = prefilled_cache(model, prefix)
        tokens = tokens[len(prefix):]
    else:
        cache = None
    return generate(
        model,
        tokenizer,
        prompt=tokens,
        max_tokens=int(message["max_tokens"]),
        sampler=make_sampler(temp=float(message.get("temperature", 0.1))),
        prompt_cache=cache,
    )


def load_audio(path: str) -> Any:
    """Read the app's 16 kHz mono 16-bit recordings without ffmpeg.

    Anything else is passed through as a path, which mlx_qwen3_asr decodes
    with ffmpeg when it is installed.
    """
    try:
        with wave.open(path, "rb") as recording:
            if (
                recording.getframerate() == SAMPLE_RATE
                and recording.getnchannels() == 1
                and recording.getsampwidth() == 2
            ):
                return np.frombuffer(recording.readframes(recording.getnframes()), dtype="<i2")
    except (wave.Error, EOFError):
        pass
    return path


def handle(message: dict[str, Any]) -> None:
    request_id = message.get("id")
    message_type = message.get("type")

    if message_type == "ping":
        emit({"id": request_id, "type": "ready"})
        return

    if message_type == "prepare_text_model":
        prepare(message)
        emit({"id": request_id, "type": "ready"})
        return

    if message_type == "polish":
        emit({"id": request_id, "type": "polished", "text": polish(message)})
        return

    if message_type != "transcribe":
        raise ValueError(f"Unsupported message type: {message_type}")

    model = str(message["model"])
    kwargs: dict[str, Any] = {"verbose": False}
    if message.get("language"):
        kwargs["language"] = message["language"]
    if message.get("context"):
        kwargs["context"] = message["context"]

    result = get_session(model).transcribe(load_audio(str(message["audio"])), **kwargs)
    emit(
        {
            "id": request_id,
            "type": "transcript",
            "text": result.text,
            "language": result.language,
        }
    )


def main() -> None:
    emit({"type": "ready"})
    for raw_line in sys.stdin:
        try:
            line = raw_line.strip()
            if not line:
                continue
            message = json.loads(line)
            handle(message)
        except Exception as error:  # Keep the worker alive after a bad request.
            traceback.print_exc(file=sys.stderr)
            emit(
                {
                    "id": message.get("id") if "message" in locals() else None,
                    "type": "error",
                    "error": str(error),
                }
            )


if __name__ == "__main__":
    main()
