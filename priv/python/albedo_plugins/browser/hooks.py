"""Kernel callbacks the browser modules read once something imports them."""

from __future__ import annotations

from collections.abc import Callable

attach_image: Callable[[bytes], str] | None = None
