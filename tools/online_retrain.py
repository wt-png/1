"""online_retrain.py — self-learning retrain loop for MSPB EA.

Reads ml_export_v2.csv, trains an XGBoost classifier with walk-forward
out-of-sample validation, then writes ml_thresholds.json when the
out-of-sample Sharpe-equivalent (win-rate * avg_R) meets the minimum
quality bar.  The EA reads that JSON file periodically via OnTimer().

Usage (manual or CI cron):
    python tools/online_retrain.py --csv ml_export_v2.csv \\
           --out ml_thresholds.json --min-trades 30

JSON output schema:
{
  "schema": "v1",
  "generated_utc": "2026-01-01T00:00:00Z",
  "global_cutoff": 0.55,          # min predicted win-prob to allow entry
  "kelly_fraction": 0.25,         # Kelly f from WFO win-rate / avg_R
  "per_symbol": {
    "EURUSD": {"cutoff": 0.54, "kelly": 0.26},
    ...
  },
  "wfo_sharpe": 0.72,
  "wfo_winrate": 0.58,
  "wfo_avg_r": 1.3,
  "n_train": 412,
  "n_oos": 87
}
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd

try:
    from xgboost import XGBClassifier
    _HAVE_XGB = True
except ImportError:  # pragma: no cover
    _HAVE_XGB = False

try:
    from sklearn.calibration import CalibratedClassifierCV
    from sklearn.preprocessing import LabelEncoder
    _HAVE_SKL = True
except ImportError:  # pragma: no cover
    _HAVE_SKL = False

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
FEATURE_COLS = [
    "atr_pips",
    "adx_trend",
    "adx_entry",
    "spread_pips",
    "body_pips",
    "hour",          # derived: entry hour of day
    "weekday",       # derived: 0=Mon … 4=Fri
]
MIN_SHARPE_TO_WRITE = 0.50   # WFO quality gate
MIN_WINRATE         = 0.40   # floor: must have positive edge
MIN_AVG_R           = 0.50   # floor: avg winner / avg loser >= 0.5
DEFAULT_CUTOFF      = 0.50   # neutral fallback when model is rejected


# ---------------------------------------------------------------------------
# Data loading / cleaning
# ---------------------------------------------------------------------------

def load_csv(path: str, delimiter: str = ";") -> pd.DataFrame:
    """Load ml_export_v2.csv; try common delimiters on failure."""
    for sep in (delimiter, ",", "\t"):
        try:
            df = pd.read_csv(path, sep=sep, dtype=str)
            if df.shape[1] > 5:
                break
        except Exception:
            continue
    else:
        raise ValueError(f"Cannot parse CSV: {path}")

    df.columns = [c.strip().lower() for c in df.columns]
    return df


def extract_trades(df: pd.DataFrame) -> pd.DataFrame:
    """Keep only completed exit rows and derive target + features."""
    # exit rows have event == "EXIT" and a numeric profit
    exits = df[df.get("event", pd.Series(dtype=str)).str.upper().str.strip() == "EXIT"].copy()

    if exits.empty:
        # Fallback: also accept rows where run_id == "exit"
        exits = df[df.get("run_id", pd.Series(dtype=str)).str.lower().str.strip() == "exit"].copy()

    if exits.empty:
        return pd.DataFrame()

    for col in ["profit_pips", "atr_pips", "adx_trend", "adx_entry",
                "spread_pips", "body_pips", "r_mult"]:
        if col in exits.columns:
            exits[col] = pd.to_numeric(exits[col], errors="coerce")

    # Target: 1 = win (r_mult > 0), 0 = loss
    if "r_mult" in exits.columns:
        exits["target"] = (exits["r_mult"] > 0).astype(int)
    elif "profit_pips" in exits.columns:
        exits["target"] = (exits["profit_pips"] > 0).astype(int)
    else:
        return pd.DataFrame()

    # Derived time features
    if "ts" in exits.columns:
        ts = pd.to_datetime(exits["ts"], errors="coerce", utc=True)
        exits["hour"]    = ts.dt.hour.fillna(12).astype(int)
        exits["weekday"] = ts.dt.weekday.fillna(2).astype(int)
    else:
        exits["hour"]    = 12
        exits["weekday"] = 2

    # Keep only rows with complete features
    feat_present = [c for c in FEATURE_COLS if c in exits.columns]
    exits = exits.dropna(subset=feat_present + ["target"])

    return exits


# ---------------------------------------------------------------------------
# Walk-forward validation
# ---------------------------------------------------------------------------

def wfo_validate(
    df: pd.DataFrame,
    n_folds: int = 3,
    train_frac: float = 0.75,
) -> dict:
    """Rolling-window WFO: train on first ``train_frac`` of each fold.

    Returns dict with keys: sharpe, winrate, avg_r, n_train, n_oos,
    per_symbol, global_cutoff, kelly_fraction, accepted (bool).
    """
    if not _HAVE_XGB or not _HAVE_SKL:
        raise RuntimeError("xgboost and scikit-learn are required")

    feat_present = [c for c in FEATURE_COLS if c in df.columns]
    if not feat_present:
        return _rejected_result(0, 0, "no features")

    df = df.copy().reset_index(drop=True)
    fold_size = len(df) // n_folds

    oos_targets: list[int] = []
    oos_probs:   list[float] = []
    oos_rmults:  list[float] = []
    oos_syms:    list[str] = []

    for fold in range(n_folds):
        start = fold * fold_size
        end   = start + fold_size
        train_end = start + int(fold_size * train_frac)

        train_df = df.iloc[start:train_end]
        oos_df   = df.iloc[train_end:end]

        if len(train_df) < 10 or len(oos_df) < 5:
            continue

        X_train = train_df[feat_present].values.astype(float)
        y_train = train_df["target"].values.astype(int)
        X_oos   = oos_df[feat_present].values.astype(float)

        # Quick guard: skip if only one class in training set
        if len(np.unique(y_train)) < 2:
            continue

        base = XGBClassifier(
            n_estimators=100,
            max_depth=3,
            learning_rate=0.1,
            subsample=0.8,
            colsample_bytree=0.8,
            eval_metric="logloss",
            use_label_encoder=False,
            verbosity=0,
        )
        model = CalibratedClassifierCV(base, cv=2, method="isotonic")
        try:
            model.fit(X_train, y_train)
        except Exception as exc:  # pragma: no cover
            logger.warning("Fold %d fit failed: %s", fold, exc)
            continue

        probs = model.predict_proba(X_oos)[:, 1]
        oos_probs.extend(probs.tolist())
        oos_targets.extend(oos_df["target"].tolist())
        oos_syms.extend(oos_df.get("symbol", pd.Series(["?"] * len(oos_df))).tolist())

        if "r_mult" in oos_df.columns:
            oos_rmults.extend(oos_df["r_mult"].tolist())
        else:
            r_proxy = [1.0 if t else -1.0 for t in oos_df["target"].tolist()]
            oos_rmults.extend(r_proxy)

    n_oos = len(oos_targets)
    n_train = len(df) - n_oos

    if n_oos < 5:
        return _rejected_result(n_train, 0, "too few OOS samples")

    oos_targets_arr = np.array(oos_targets)
    oos_probs_arr   = np.array(oos_probs)
    oos_rmults_arr  = np.array(oos_rmults)

    # Find optimal cutoff on OOS set (maximise win-rate * avg_R proxy)
    best_cutoff, best_score = DEFAULT_CUTOFF, -1.0
    for thresh in np.arange(0.40, 0.75, 0.02):
        mask   = oos_probs_arr >= thresh
        if mask.sum() < 3:
            continue
        wr     = oos_targets_arr[mask].mean()
        avg_r  = oos_rmults_arr[mask].mean()
        score  = wr * max(avg_r, 0)
        if score > best_score:
            best_score   = score
            best_cutoff  = thresh

    # Final metrics at best_cutoff
    mask_best   = oos_probs_arr >= best_cutoff
    if mask_best.sum() == 0:
        return _rejected_result(n_train, n_oos, "no OOS trades at cutoff")

    winrate = float(oos_targets_arr[mask_best].mean())
    avg_r   = float(oos_rmults_arr[mask_best].mean())

    # Simplified Sharpe approximation: mean R-multiple / std(R-multiple).
    # Not a traditional Sharpe (no risk-free rate), but comparable across WFO folds.
    r_std   = float(oos_rmults_arr[mask_best].std())
    sharpe  = (avg_r / r_std) if r_std > 1e-9 else 0.0

    # Kelly fraction: f* = (bp - q) / b  where b=avg_win/avg_loss, p=WR, q=1-WR
    wins  = oos_rmults_arr[mask_best & (oos_targets_arr == 1)]
    losses= oos_rmults_arr[mask_best & (oos_targets_arr == 0)]
    if len(wins) > 0 and len(losses) > 0:
        avg_win  = float(wins.mean())
        avg_loss = abs(float(losses.mean()))
        b        = avg_win / avg_loss if avg_loss > 0 else 1.0
        q        = 1.0 - winrate
        kelly    = max(0.0, min(0.5, (b * winrate - q) / b))
    else:
        # Conservative 1/4 Kelly fallback when win/loss split is unavailable —
        # avoids over-leveraging when there is insufficient data.
        kelly = 0.25

    # Per-symbol refinement
    per_symbol: dict[str, dict] = {}
    for sym in set(oos_syms):
        sym_mask = np.array([s == sym for s in oos_syms]) & mask_best
        if sym_mask.sum() < 3:
            continue
        sym_wr = float(oos_targets_arr[sym_mask].mean())
        sym_r  = float(oos_rmults_arr[sym_mask].mean())
        # simple per-symbol Kelly
        sw = oos_rmults_arr[sym_mask & (oos_targets_arr == 1)]
        sl = oos_rmults_arr[sym_mask & (oos_targets_arr == 0)]
        if len(sw) > 0 and len(sl) > 0:
            sb = sw.mean() / (abs(sl.mean()) or 1.0)
            sq = 1.0 - sym_wr
            sk = max(0.0, min(0.5, (sb * sym_wr - sq) / sb))
        else:
            sk = kelly
        per_symbol[sym] = {"cutoff": round(best_cutoff, 4),
                           "kelly": round(sk, 4)}

    accepted = (sharpe >= MIN_SHARPE_TO_WRITE
                and winrate >= MIN_WINRATE
                and avg_r >= MIN_AVG_R)

    return {
        "accepted":       accepted,
        "global_cutoff":  round(best_cutoff, 4),
        "kelly_fraction": round(kelly, 4),
        "per_symbol":     per_symbol,
        "wfo_sharpe":     round(sharpe, 4),
        "wfo_winrate":    round(winrate, 4),
        "wfo_avg_r":      round(avg_r, 4),
        "n_train":        n_train,
        "n_oos":          n_oos,
        "reject_reason":  "",
    }


def _rejected_result(n_train: int, n_oos: int, reason: str) -> dict:
    return {
        "accepted":       False,
        "global_cutoff":  DEFAULT_CUTOFF,
        "kelly_fraction": 0.25,
        "per_symbol":     {},
        "wfo_sharpe":     0.0,
        "wfo_winrate":    0.0,
        "wfo_avg_r":      0.0,
        "n_train":        n_train,
        "n_oos":          n_oos,
        "reject_reason":  reason,
    }


# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------

def write_thresholds(result: dict, out_path: str) -> None:
    payload = {
        "schema":         "v1",
        "generated_utc":  datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "global_cutoff":  result["global_cutoff"],
        "kelly_fraction": result["kelly_fraction"],
        "per_symbol":     result["per_symbol"],
        "wfo_sharpe":     result["wfo_sharpe"],
        "wfo_winrate":    result["wfo_winrate"],
        "wfo_avg_r":      result["wfo_avg_r"],
        "n_train":        result["n_train"],
        "n_oos":          result["n_oos"],
    }
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
    os.replace(tmp, out_path)
    logger.info("Wrote %s  (cutoff=%.3f  kelly=%.3f  sharpe=%.3f)",
                out_path, payload["global_cutoff"],
                payload["kelly_fraction"], payload["wfo_sharpe"])


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def run(
    csv_path: str,
    out_path: str,
    min_trades: int = 30,
    delimiter: str = ";",
    force: bool = False,
) -> int:
    """Return 0 on success, 1 on skip/failure."""
    if not os.path.exists(csv_path):
        logger.error("CSV not found: %s", csv_path)
        return 1

    df_raw = load_csv(csv_path, delimiter)
    trades  = extract_trades(df_raw)

    if len(trades) < min_trades:
        logger.warning("Only %d usable trades (need %d) — skipping retrain",
                       len(trades), min_trades)
        return 1

    logger.info("Loaded %d trades from %s", len(trades), csv_path)
    result = wfo_validate(trades)

    logger.info(
        "WFO: accepted=%s  sharpe=%.3f  winrate=%.3f  avg_r=%.3f  "
        "cutoff=%.3f  kelly=%.3f  n_oos=%d",
        result["accepted"], result["wfo_sharpe"], result["wfo_winrate"],
        result["wfo_avg_r"], result["global_cutoff"],
        result["kelly_fraction"], result["n_oos"],
    )

    if not result["accepted"] and not force:
        reason = result.get("reject_reason") or "quality gate not met"
        logger.warning("Model rejected (%s) — thresholds NOT updated", reason)
        return 1

    write_thresholds(result, out_path)
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    parser = argparse.ArgumentParser(description="Retrain MSPB entry-gate model")
    parser.add_argument("--csv",        default="ml_export_v2.csv",
                        help="Path to ml_export_v2.csv")
    parser.add_argument("--out",        default="ml_thresholds.json",
                        help="Output JSON path")
    parser.add_argument("--min-trades", type=int, default=30,
                        help="Minimum trades required to retrain")
    parser.add_argument("--delimiter",  default=";",
                        help="CSV field delimiter")
    parser.add_argument("--force",      action="store_true",
                        help="Write thresholds even when quality gate fails")
    args = parser.parse_args(argv)
    return run(args.csv, args.out, args.min_trades, args.delimiter, args.force)


if __name__ == "__main__":
    sys.exit(main())
