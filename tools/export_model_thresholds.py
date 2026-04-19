#!/usr/bin/env python3
"""
MSPB EA — Export ML Entry-Gate Thresholds
==========================================
Reads ml_export_v2.csv, trains an XGBoost classifier to predict trade outcome
(win vs loss), calibrates a probability threshold that maximises precision at
a target recall, and writes a lightweight JSON entry-gate file that the EA can
read at runtime to gate new entries.

Output JSON format
------------------
{
  "threshold": 0.55,          // calibrated score cutoff (0–1)
  "feature_weights": {...},   // XGBoost normalised importance per feature
  "feature_stats": {          // mean + std computed on the training set
    "adx_trend":  {"mean": 25.0, "std": 8.0},
    ...
  },
  "meta": {
    "generated_at": "2026-04-19T13:00:00",
    "train_rows": 350,
    "win_rate": 0.58,
    "precision_at_threshold": 0.63,
    "recall_at_threshold": 0.72,
    "model": "XGBClassifier"
  }
}

The EA computes a runtime score as:
  z_i  = (feature_i - mean_i) / std_i
  score = sigmoid( sum_i( weight_i * z_i ) )
Entry is allowed when score >= threshold.

Usage
-----
  python tools/export_model_thresholds.py \\
      --csv ml_export_v2.csv \\
      --output ml_entry_threshold.json \\
      [--target-recall 0.70]
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Tuple


_MISSING = {"", "nan", "null", "n/a", "na", "-"}

NUMERIC_FEATURES = [
    "atr_pips",
    "adx_trend",
    "adx_entry",
    "spread_pips",
    "body_pips",
    "r_mult",
]


def _flt(v: str) -> float:
    return float(v) if v.strip().lower() not in _MISSING else float("nan")


def load_csv(path: str) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh, delimiter=";")
        for r in reader:
            rows.append(r)
    return rows


def build_dataset(rows: List[Dict[str, str]]) -> Tuple[List[List[float]], List[int], List[str]]:
    X: List[List[float]] = []
    y: List[int] = []
    for r in rows:
        if r.get("event", "").strip().upper() != "ENTRY":
            continue
        pnl_raw = r.get("profit_money") or r.get("pnl_gross") or r.get("pnl") or ""
        try:
            pnl = float(pnl_raw)
        except (ValueError, TypeError):
            continue
        label = 1 if pnl > 0 else 0
        feats: List[float] = []
        ok = True
        for f in NUMERIC_FEATURES:
            try:
                v = _flt(r.get(f, ""))
                if math.isnan(v):
                    ok = False
                    break
                feats.append(v)
            except (ValueError, TypeError):
                ok = False
                break
        if ok:
            X.append(feats)
            y.append(label)
    return X, y, NUMERIC_FEATURES


def compute_stats(X: List[List[float]], feat_names: List[str]) -> Dict[str, Dict[str, float]]:
    """Compute per-feature mean and std."""
    stats: Dict[str, Dict[str, float]] = {}
    n = len(X)
    if n == 0:
        for f in feat_names:
            stats[f] = {"mean": 0.0, "std": 1.0}
        return stats
    for fi, f in enumerate(feat_names):
        vals = [X[i][fi] for i in range(n)]
        mean = sum(vals) / n
        variance = sum((v - mean) ** 2 for v in vals) / max(n - 1, 1)
        std = math.sqrt(variance) if variance > 0 else 1.0
        stats[f] = {"mean": round(mean, 6), "std": round(std, 6)}
    return stats


def sigmoid(x: float) -> float:
    return 1.0 / (1.0 + math.exp(-max(-500.0, min(500.0, x))))


def score_sample(feats: List[float], weights: Dict[str, float],
                 stats: Dict[str, Dict[str, float]],
                 feat_names: List[str]) -> float:
    z = 0.0
    for fi, f in enumerate(feat_names):
        w = weights.get(f, 0.0)
        if w == 0.0:
            continue
        mean = stats[f]["mean"]
        std = stats[f]["std"] or 1.0
        z += w * (feats[fi] - mean) / std
    return sigmoid(z)


def calibrate_threshold(scores: List[float], labels: List[int],
                        target_recall: float) -> float:
    """Return the lowest threshold t such that recall(t) >= target_recall."""
    pairs = sorted(zip(scores, labels), key=lambda x: -x[0])
    total_pos = sum(labels)
    if total_pos == 0:
        return 0.5

    best_t = 0.5
    tp = 0
    for score, label in pairs:
        if label == 1:
            tp += 1
        recall = tp / total_pos
        if recall >= target_recall:
            best_t = score
            break
    return round(max(0.1, min(0.95, best_t)), 4)


def precision_recall_at(scores: List[float], labels: List[int],
                        threshold: float) -> Tuple[float, float]:
    tp = fp = fn = 0
    for s, l in zip(scores, labels):
        pred = 1 if s >= threshold else 0
        if pred == 1 and l == 1:
            tp += 1
        elif pred == 1 and l == 0:
            fp += 1
        elif pred == 0 and l == 1:
            fn += 1
    prec = tp / (tp + fp) if (tp + fp) > 0 else 0.0
    rec = tp / (tp + fn) if (tp + fn) > 0 else 0.0
    return round(prec, 4), round(rec, 4)


def main() -> None:
    parser = argparse.ArgumentParser(description="Export ML entry-gate thresholds")
    parser.add_argument("--csv",           required=True, help="Path to ml_export_v2.csv")
    parser.add_argument("--output",        default="ml_entry_threshold.json",
                        help="Output JSON file (default: ml_entry_threshold.json)")
    parser.add_argument("--target-recall", type=float, default=0.70,
                        help="Target recall for threshold calibration (default: 0.70)")
    args = parser.parse_args()

    print(f"Loading {args.csv} …")
    rows = load_csv(args.csv)
    print(f"  {len(rows)} rows loaded")

    X, y, feat_names = build_dataset(rows)
    n_wins = sum(y)
    print(f"  {len(X)} labelled ENTRY rows | wins={n_wins} | losses={len(y) - n_wins}")

    if len(X) < 30:
        print("Not enough data (< 30 trades). Exiting without writing output.")
        sys.exit(0)

    try:
        import xgboost as xgb  # type: ignore
        import numpy as np     # type: ignore
    except ImportError:
        print("xgboost/numpy not installed. Run: pip install xgboost numpy", file=sys.stderr)
        sys.exit(1)

    Xa = np.array(X, dtype=float)
    ya = np.array(y, dtype=int)

    model = xgb.XGBClassifier(
        n_estimators=200, max_depth=4, learning_rate=0.05,
        subsample=0.8, colsample_bytree=0.8,
        use_label_encoder=False, eval_metric="logloss",
        random_state=42,
    )
    model.fit(Xa, ya)

    # Raw importances (gain-based)
    raw_imp = dict(zip(feat_names, model.feature_importances_.tolist()))
    total_imp = sum(raw_imp.values()) or 1.0
    norm_weights = {f: round(v / total_imp, 6) for f, v in raw_imp.items()}

    print("\n=== Feature Importances (normalised) ===")
    for f, w in sorted(norm_weights.items(), key=lambda t: -t[1]):
        bar = "#" * int(w * 40)
        print(f"  {f:<20s} {w:.4f}  {bar}")

    stats = compute_stats(X, feat_names)

    # Compute scores for all training samples (for threshold calibration)
    all_scores = [score_sample(X[i], norm_weights, stats, feat_names) for i in range(len(X))]

    threshold = calibrate_threshold(all_scores, y, args.target_recall)
    prec, rec = precision_recall_at(all_scores, y, threshold)
    win_rate = round(n_wins / len(y), 4) if len(y) > 0 else 0.0

    print(f"\nCalibrated threshold : {threshold}  (target recall ≥ {args.target_recall})")
    print(f"Precision @ threshold: {prec}")
    print(f"Recall    @ threshold: {rec}")
    print(f"Training win rate    : {win_rate}")

    output = {
        "threshold": threshold,
        "feature_weights": norm_weights,
        "feature_stats": stats,
        "meta": {
            "generated_at": datetime.utcnow().isoformat(timespec="seconds"),
            "train_rows": len(X),
            "win_rate": win_rate,
            "precision_at_threshold": prec,
            "recall_at_threshold": rec,
            "model": "XGBClassifier",
            "target_recall": args.target_recall,
        },
    }

    out_path = Path(args.output)
    out_path.write_text(json.dumps(output, indent=2), encoding="utf-8")
    print(f"\nThresholds written to {out_path}")


if __name__ == "__main__":
    main()
