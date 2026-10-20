"""Kernel callbacks the browser modules read once something imports them."""

from __future__ import annotations

from collections.abc import Callable
from contextlib import AbstractContextManager, nullcontext

attach_image: Callable[[bytes], str] | None = None
# Keeps the browser's own bookkeeping (profile locks, auto-named screenshots)
# out of a cell's file-change trace, where it is not the cell's work.
unobserved: Callable[[], AbstractContextManager[None]] = nullcontext
