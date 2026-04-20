from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Mapping, Optional, Protocol, Sequence, SupportsFloat, Union, Literal, cast

# --- Custom Exceptions --------------------------------------------------------

class TraderProError(Exception):
    """Base exception for TraderPro."""
    pass

class SignalParseError(TraderProError):
    """Raised when parsing a signal fails."""
    pass

# --- Core trading domain types -------------------------------------------------

#: Desired position side after strategy processing a bar ("flat", "long", or "short").
#: -1: Short
#:  0: Flat
#: +1: Long
PositionSide = Literal[-1, 0, 1]

#: Type for stop-level pending orders.
PendingSide = Literal["BUY_STOP", "SELL_STOP"]

#: Represents a live market position side.
LiveSide = Literal["BUY", "SELL"]

@dataclass(frozen=True)
class ResolvedSymbol:
    """Maps an abstract symbol (e.g., "EURUSD") to a broker-specific configuration."""
    broker: str        #: Broker-specific symbol (e.g., "EURUSD.ecn")
    pip_size: float    #: Smallest increment for a price change.
    point: float       #: Broker-defined multiplier for a "pip" in pricing.

@dataclass(frozen=True)
class StrategyDecision:
    """Simple strategy decision contract (target-only style)."""
    target: PositionSide
    sl_price: Optional[float] = None
    tp_price: Optional[float] = None
    comment: str = ""

@dataclass
class PendingOrder:
    """A simple stop pending order used in bar-level EA backtests."""
    symbol: str
    side: PendingSide
    volume: float
    entry: float
    sl: float
    tp: Optional[float]   # None/0.0 means no TP (runner)
    created_time: datetime
    expires_time: datetime
    comment: str = ""

@dataclass
class Position:
    """Open position state for EA-style backtests."""
    symbol: str
    side: LiveSide  # BUY/SELL
    volume: float
    entry_price: float              # price level (bid)
    entry_spread_points: float      # spread at entry in *points*
    entry_time: datetime
    sl: float
    tp: Optional[float]             # None means no TP (runner)
    init_sl: float                  # used for R calculation
    comment: str = ""
    open_bar_index: int = 0
    tp1_done: bool = False          # for netting partial-close or runner gate

# --- Market data / broker integration contracts --------------------------------

class Bar(Protocol):
    """OHLC bar."""
    time: datetime
    open: SupportsFloat
    high: SupportsFloat
    low: SupportsFloat
    close: SupportsFloat
    spread: SupportsFloat

class MarketDataFeed(Protocol):
    """Defines the interface for fetching market data (OHLC data, ticks, etc.)."""

    def bars_range(
        self, broker_symbol: str, timeframe: str, start: datetime, end: datetime
    ) -> Sequence[Bar]:
        """Retrieve market bars (OHLCV) for a given date range."""
        ...

    def bars(
        self, broker_symbol: str, timeframe: str, count: int, closed_only: bool = True
    ) -> Sequence[Bar]:
        """Retrieve the latest `count` market bars."""
        ...

    def tick(self, broker_symbol: str) -> Optional[Dict[str, float]]:
        """Retrieve the latest bid/ask price tick information for a symbol."""
        ...

class SymbolResolver(Protocol):
    def resolve(self, symbol: str) -> ResolvedSymbol:
        ...

# --- Strategy contracts --------------------------------------------------------

TimeframeLike = Union[str, Sequence[str]]

class Strategy(Protocol):
    def on_bar(self, i: int, bars: Sequence[Bar], position_side: PositionSide) -> Optional[StrategyDecision]:
        ...

class MTFStrategy(Protocol):
    def on_bar_mtf(
        self,
        i: int,
        bars_by_tf: Mapping[str, Sequence[Bar]],
        idx_by_tf: Mapping[str, int],
        position_side: PositionSide,
    ) -> Optional[StrategyDecision]:
        ...

class ResettableStrategy(Protocol):
    def reset(self) -> None:
        ...

# --- Signal validation and parsing ---------------------------------------------

def validate_signal(signal: Signal) -> None:
    """
    Perform validation checks on a `Signal` to ensure data integrity.

    Args:
        signal (Signal): The signal to validate.

    Raises:
        SignalParseError: If validation fails for any field.
    """
    if not signal.symbol:
        raise SignalParseError("The 'symbol' field is required.")
    if signal.action not in {"BUY", "SELL", "TEST"}:
        raise SignalParseError(f"Invalid action '{signal.action}' in signal.")
    if signal.volume is not None and signal.volume <= 0:
        raise SignalParseError("The 'volume' field must be positive if provided.")

def signal_from_json(obj: Mapping[str, Any]) -> Signal:
    """
    Parse raw JSON-like data into a Signal object. Include validation and normalization.

    Args:
        obj: The JSON-like data dictionary defining the signal.

    Returns:
        Signal: A normalized instance of the Signal class.

    Raises:
        SignalParseError: If mandatory fields are missing or invalid.
    """
    if not isinstance(obj, Mapping):
        raise SignalParseError(f"Expected a dictionary, got: {type(obj).__name__}")

    try:
        # Parse fields with fallback
        signal_id = _first_key(obj, ["id", "signal_id", "uuid"]) or _stable_id_from_obj(obj)
        symbol = str(_first_key(obj, ["symbol", "sym"])).strip()
        if not symbol:
            raise SignalParseError("Signal is missing the 'symbol' field.")

        action = str(_first_key(obj, ["action", "side", "type"])).upper()
        if action in {"LONG", "SHORT"}:
            action = "BUY" if action == "LONG" else "SELL"
        if action not in {"BUY", "SELL", "TEST"}:
            raise SignalParseError(f"Invalid action field: {action}")

        volume = float(_first_key(obj, ["volume", "vol", "lots"]) or 0.0)
        ts = parse_datetime(_first_key(obj, ["timestamp", "ts", "time"]) or utcnow())
        source = str(obj.get("source", "")).strip() or None

        # Meta field normalization
        meta = obj.get("meta", None)
        if not isinstance(meta, (dict, type(None))):
            meta = {"value": meta}

        comment = str(obj.get("comment", "")).strip() or None

        signal = Signal(
            id=signal_id,
            symbol=symbol,
            action=cast(SignalAction, action),
            volume=volume,
            timestamp=ts,
            source=source,
            meta=cast(Optional[Dict[str, Any]], meta),
            comment=comment,
        )
        validate_signal(signal)
        return signal
    except KeyError as e:
        raise SignalParseError(f"Missing key: {e}") from e
    except Exception as e:
        raise SignalParseError(f"Failed to parse signal: {e}") from e

# --- Utility functions ---------------------------------------------------------

def parse_datetime(value: Any) -> Optional[datetime]:
    """
    Parse a datetime object from various acceptable formats.

    Args:
        value: The input value for date conversion.

    Returns:
        datetime: A timezone-aware datetime object.

    Raises:
        ValueError: If the input cannot be parsed as a datetime.
    """
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc) if value.tzinfo else value.replace(tzinfo=timezone.utc)

    if isinstance(value, str):
        value = value.strip()
        try:
            # First, try ISO8601 parsing
            return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
        except ValueError:
            pass

    raise ValueError(f"Unsupported datetime input: {value}")

def _stable_id_from_obj(obj: Any, prefix: Optional[str] = None) -> str:
    """
    Create a stable 16-character ID for a given object.

    Args:
        obj: The object to generate an ID for.
        prefix: An optional prefix for debugging purposes.

    Returns:
        str: The generated ID.
    """
    payload = json.dumps(obj, ensure_ascii=False, sort_keys=True, default=str)
    hash_id = hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]
    return f"{prefix}_{hash_id}" if prefix else hash_id

def position_side_to_str(side: PositionSide) -> str:
    """Convert a PositionSide to a textual representation."""
    mapping = {-1: "SHORT", 0: "FLAT", 1: "LONG"}
    return mapping.get(side, "UNKNOWN")