#!/usr/bin/env python3
"""
Standardize SnowPro Q&A Knowledge Base YAML files to the required format.

Usage:
    python standardize_kb.py <input_file.yml> [output_file.yml]

If no output file is specified, the standardized file is saved as:
    <input_file>_standardized.yml
"""

import sys
import os
import re
import yaml
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants – canonical field names (output schema)
# ---------------------------------------------------------------------------

OUT_TOPIC          = "Topic Name"
OUT_SUBTOPIC       = "Sub Topic Name"
OUT_TOTAL          = "Total Question Count"
OUT_QUESTIONS      = "all questions"

OUT_Q_NO           = "Question No"
OUT_Q_TEXT         = "question"
OUT_Q_OPTIONS      = "their_options"
OUT_Q_ANSWER       = "correct Answer"
OUT_Q_EXPLANATION  = "explanation"
OUT_Q_DIFFICULTY   = "difficulty level"
OUT_Q_TOPIC        = "topic"
OUT_Q_SUBTOPIC     = "sub topic"
OUT_Q_EXAM         = "exam"

VALID_DIFFICULTIES = {"Easy", "Medium", "Hard"}
VALID_EXAMS        = {"Core", "DataEngineer", "DataAnalyst", "Architect"}
OPTION_LABELS      = ["option A", "option B", "option C", "option D", "option E"]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _first_value(d: dict, *keys):
    """Return the first value from a dict whose key (case-insensitive) matches."""
    lower_map = {k.lower().strip(): v for k, v in d.items()}
    for key in keys:
        val = lower_map.get(key.lower().strip())
        if val is not None:
            return val
    return None


def normalize_difficulty(raw) -> str:
    if not raw:
        return "Medium"
    raw = str(raw).strip().capitalize()
    # Accept partial matches
    for d in VALID_DIFFICULTIES:
        if raw.lower().startswith(d.lower()):
            return d
    return "Medium"


def normalize_exam(raw) -> str:
    """Accept a string or list and return comma-separated canonical exam tags."""
    if not raw:
        return "Core"
    if isinstance(raw, list):
        tags = [str(t).strip() for t in raw]
    else:
        tags = [t.strip() for t in str(raw).split(",")]

    normalized = []
    for tag in tags:
        matched = next(
            (e for e in VALID_EXAMS if e.lower() == tag.lower()), None
        )
        if matched:
            normalized.append(matched)
    return ", ".join(normalized) if normalized else "Core"


def normalize_options(raw_options) -> dict:
    """
    Accepts many formats:
      - dict with keys like 'option A', 'optionA', 'A', 'a', etc.
      - list of strings (assumed A, B, C …)
    Returns a dict with canonical keys 'option A' … 'option E'.
    Missing options are omitted.
    """
    result = {}
    if isinstance(raw_options, dict):
        key_map = {}
        for k in raw_options:
            # normalise key: strip spaces, lowercase, remove 'option'
            clean = re.sub(r'\s+', '', str(k).lower()).replace('option', '')
            if clean in ('a','b','c','d','e'):
                key_map[clean] = raw_options[k]
        for label in OPTION_LABELS:
            letter = label.split()[-1].lower()
            if letter in key_map:
                result[label] = str(key_map[letter]).strip()
    elif isinstance(raw_options, list):
        for i, val in enumerate(raw_options[:5]):
            result[OPTION_LABELS[i]] = str(val).strip()
    return result


def normalize_answer(raw) -> str:
    """
    Accepts 'option B', 'B', 'b', 'optionB', or a list for multi-answer.
    Returns canonical form like 'option B' or 'option B, option D'.
    """
    if not raw:
        return ""
    if isinstance(raw, list):
        answers = [normalize_answer(a) for a in raw]
        return ", ".join(answers)
    raw = str(raw).strip()
    # Already canonical?
    if re.fullmatch(r'option [A-Ea-e](,\s*option [A-Ea-e])*', raw, re.I):
        parts = [p.strip() for p in raw.split(',')]
        return ", ".join(f"option {p.split()[-1].upper()}" for p in parts)
    # Single letter
    m = re.fullmatch(r'[A-Ea-e]', raw)
    if m:
        return f"option {raw.upper()}"
    # optionB style
    m = re.search(r'option\s*([A-Ea-e])', raw, re.I)
    if m:
        return f"option {m.group(1).upper()}"
    return raw  # return as-is if we can't parse


def pad_question_no(n) -> str:
    try:
        return str(int(str(n).strip().lstrip('0') or '0')).zfill(3)
    except ValueError:
        return str(n).strip()


# ---------------------------------------------------------------------------
# Flexible YAML key resolution for top-level fields
# ---------------------------------------------------------------------------

TOPIC_KEYS     = ["Topic Name", "topic name", "Topic", "topic"]
SUBTOPIC_KEYS  = ["Sub Topic Name", "sub topic name", "Sub Topic", "subtopic", "sub_topic"]
TOTAL_KEYS     = ["Total Question Count", "total question count", "total_questions", "question_count"]
QUESTIONS_KEYS = ["all questions", "all_questions", "questions", "Questions"]

Q_NO_KEYS      = ["Question No", "question no", "question_no", "Q No", "id"]
Q_TEXT_KEYS    = ["question", "Question", "q", "Q"]
Q_OPTIONS_KEYS = ["their_options", "their options", "options", "Options"]
Q_ANSWER_KEYS  = ["correct Answer", "correct answer", "correct_answer", "answer", "Answer"]
Q_EXPL_KEYS    = ["explanation", "Explanation"]
Q_DIFF_KEYS    = ["difficulty level", "difficulty_level", "difficulty", "Difficulty"]
Q_TOPIC_KEYS   = ["topic", "Topic"]
Q_SUBTOPIC_KEYS= ["sub topic", "sub_topic", "subtopic", "Sub Topic"]
Q_EXAM_KEYS    = ["exam", "Exam", "exams", "Exams"]


# ---------------------------------------------------------------------------
# Core standardisation logic
# ---------------------------------------------------------------------------

def standardize_question(raw_q: dict, idx: int) -> dict:
    """Convert a raw question dict to the canonical schema."""
    q_no = _first_value(raw_q, *Q_NO_KEYS) or str(idx + 1)
    q_no = pad_question_no(q_no)

    question  = _first_value(raw_q, *Q_TEXT_KEYS) or ""
    raw_opts  = _first_value(raw_q, *Q_OPTIONS_KEYS) or {}
    options   = normalize_options(raw_opts)
    answer    = normalize_answer(_first_value(raw_q, *Q_ANSWER_KEYS))
    explanation = _first_value(raw_q, *Q_EXPL_KEYS) or ""
    difficulty  = normalize_difficulty(_first_value(raw_q, *Q_DIFF_KEYS))
    topic       = _first_value(raw_q, *Q_TOPIC_KEYS) or ""
    subtopic    = _first_value(raw_q, *Q_SUBTOPIC_KEYS) or ""
    exam        = normalize_exam(_first_value(raw_q, *Q_EXAM_KEYS))

    return {
        OUT_Q_NO:          f'"{q_no}"',   # stored as string with quotes for YAML
        OUT_Q_TEXT:        str(question).strip(),
        OUT_Q_OPTIONS:     options,
        OUT_Q_ANSWER:      answer,
        OUT_Q_EXPLANATION: str(explanation).strip(),
        OUT_Q_DIFFICULTY:  difficulty,
        OUT_Q_TOPIC:       str(topic).strip(),
        OUT_Q_SUBTOPIC:    str(subtopic).strip(),
        OUT_Q_EXAM:        exam,
    }


def standardize(data: dict) -> dict:
    """
    Accept a raw parsed YAML dict and return a standardized dict
    matching the required output schema.
    """
    topic    = _first_value(data, *TOPIC_KEYS) or "Unknown Topic"
    subtopic = _first_value(data, *SUBTOPIC_KEYS) or ""
    raw_qs   = _first_value(data, *QUESTIONS_KEYS) or []

    if not isinstance(raw_qs, list):
        raise ValueError("Could not find a list of questions in the input file.")

    questions = [standardize_question(q, i) for i, q in enumerate(raw_qs)]

    return {
        OUT_TOPIC:     str(topic).strip(),
        OUT_SUBTOPIC:  str(subtopic).strip(),
        OUT_TOTAL:     len(questions),
        OUT_QUESTIONS: questions,
    }


# ---------------------------------------------------------------------------
# Custom YAML dumper to preserve desired formatting
# ---------------------------------------------------------------------------

class LiteralStr(str):
    pass


class QuotedStr(str):
    pass


def _literal_representer(dumper, data):
    return dumper.represent_scalar('tag:yaml.org,2002:str', data, style='>')


def _quoted_representer(dumper, data):
    # strip surrounding quote chars we added manually
    val = str(data).strip('"')
    return dumper.represent_scalar('tag:yaml.org,2002:str', val, style='"')


def build_dumper():
    dumper = yaml.Dumper
    dumper.add_representer(LiteralStr, _literal_representer)
    dumper.add_representer(QuotedStr, _quoted_representer)
    return dumper


def to_serializable(obj):
    """Recursively convert our custom types for YAML serialization."""
    if isinstance(obj, dict):
        return {k: to_serializable(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [to_serializable(i) for i in obj]
    return obj


def format_for_yaml(std: dict) -> dict:
    """
    Wrap certain string values in custom YAML types for nice output.
    """
    formatted = {
        OUT_TOPIC:    std[OUT_TOPIC],
        OUT_SUBTOPIC: std[OUT_SUBTOPIC],
        OUT_TOTAL:    std[OUT_TOTAL],
        OUT_QUESTIONS: [],
    }
    for q in std[OUT_QUESTIONS]:
        fq = dict(q)
        fq[OUT_Q_NO]          = QuotedStr(q[OUT_Q_NO].strip('"'))
        fq[OUT_Q_EXPLANATION] = LiteralStr(q[OUT_Q_EXPLANATION])
        formatted[OUT_QUESTIONS].append(fq)
    return formatted


# ---------------------------------------------------------------------------
# File I/O
# ---------------------------------------------------------------------------

def load_yaml(path: str) -> dict:
    with open(path, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f)


def save_yaml(data: dict, path: str):
    """
    Write YAML with clean formatting:
      - Block style (not inline/flow)
      - 2-space indent
      - UTF-8 encoded
      - No default_flow_style
    """
    with open(path, 'w', encoding='utf-8') as f:
        yaml.dump(
            data,
            f,
            allow_unicode=True,
            default_flow_style=False,
            sort_keys=False,
            indent=2,
            width=120,
            Dumper=build_dumper(),
        )


# ---------------------------------------------------------------------------
# Validation / reporting
# ---------------------------------------------------------------------------

def validate(std: dict):
    issues = []
    for q in std[OUT_QUESTIONS]:
        qno = q[OUT_Q_NO]
        if not q[OUT_Q_TEXT]:
            issues.append(f"Q{qno}: missing question text")
        if not q[OUT_Q_OPTIONS]:
            issues.append(f"Q{qno}: no options found")
        if not q[OUT_Q_ANSWER]:
            issues.append(f"Q{qno}: missing correct answer")
        if q[OUT_Q_DIFFICULTY] not in VALID_DIFFICULTIES:
            issues.append(f"Q{qno}: invalid difficulty '{q[OUT_Q_DIFFICULTY]}'")
    return issues


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    input_path = sys.argv[1]
    if len(sys.argv) >= 3:
        output_path = sys.argv[2]
    else:
        base = Path(input_path).stem
        output_path = str(Path(input_path).parent / f"{base}_standardized.yml")

    print(f"Loading   : {input_path}")
    raw = load_yaml(input_path)

    print("Standardizing ...")
    std = standardize(raw)

    issues = validate(std)
    if issues:
        print(f"\n⚠  {len(issues)} validation issue(s) found:")
        for i in issues:
            print(f"   • {i}")
    else:
        print("✓ Validation passed – no issues found.")

    formatted = format_for_yaml(std)
    save_yaml(to_serializable(formatted), output_path)

    print(f"\n✓ Standardized file saved to: {output_path}")
    print(f"  Topic    : {std[OUT_TOPIC]}")
    print(f"  Sub-Topic: {std[OUT_SUBTOPIC]}")
    print(f"  Questions: {std[OUT_TOTAL]}")


if __name__ == "__main__":
    main()
