"""Values crossing a kernel connection; process and reference ownership stay with callers."""

from __future__ import annotations

import base64
import dataclasses
import importlib
from typing import Any

import albedo_api


class InvalidValue(ValueError):
    """A peer supplied an invalid encoded value."""


class Unencodable(Exception):
    """The value cannot cross the connection; it stays a live remote reference."""


def encode(value: object, depth: int = 0) -> object:
    """One value as connection-crossable JSON; Unencodable means a live reference.

    Dataclasses and list subclasses carry their class so the owner rebuilds the
    real object and remote results read exactly like local ones.
    """
    if depth > 32:
        raise Unencodable
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, (bytes, bytearray, memoryview)):
        return {"__bytes__": base64.b64encode(bytes(value)).decode("ascii")}
    if isinstance(value, dict) and type(value) is dict:
        return {str(key): encode(item, depth + 1) for key, item in value.items()}
    if isinstance(value, albedo_api.Record):
        cls = type(value)
        return {
            "__record__": cls.__module__ + "." + cls.__qualname__,
            "fields": {
                str(key): encode(item, depth + 1) for key, item in value.items()
            },
        }
    if isinstance(value, (list, tuple)):
        try:
            if type(value) is not list:
                cls = type(value)
                return {
                    "__list__": cls.__module__ + "." + cls.__qualname__,
                    "items": [encode(item, depth + 1) for item in value],
                }
        except Unencodable:
            raise
        except (TypeError, ValueError):
            raise Unencodable from None
        return [encode(item, depth + 1) for item in value]
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        cls = type(value)
        try:
            return {
                "__class__": cls.__module__ + "." + cls.__qualname__,
                "fields": {
                    field.name: encode(getattr(value, field.name), depth + 1)
                    for field in dataclasses.fields(value)
                },
            }
        except (TypeError, ValueError, AttributeError):
            raise Unencodable from None
    raise Unencodable


def _load_class(marker: str) -> type:
    """The class a wire marker names; both bundles are identical, so it exists."""
    module, _, qualified = marker.rpartition(".")
    obj: Any = importlib.import_module(module)
    for part in qualified.split("."):
        obj = getattr(obj, part)
    return obj


def decode(value: Any) -> Any:
    """Rebuild real objects from wire values, so remote results read like local ones."""
    if isinstance(value, dict):
        if set(value) == {"__bytes__"} and isinstance(value.get("__bytes__"), str):
            try:
                return base64.b64decode(value["__bytes__"], validate=True)
            except ValueError as error:
                raise InvalidValue("invalid remote byte encoding") from error
        if set(value) == {"__class__", "fields"} and isinstance(
            value.get("__class__"), str
        ):
            try:
                return _load_class(value["__class__"])(
                    **{key: decode(item) for key, item in value["fields"].items()}
                )
            except Exception:
                return {key: decode(item) for key, item in value["fields"].items()}
        if set(value) == {"__record__", "fields"} and isinstance(
            value.get("__record__"), str
        ):
            fields = {key: decode(item) for key, item in value["fields"].items()}
            try:
                return _load_class(value["__record__"])(fields)
            except Exception:
                return fields
        if set(value) == {"__list__", "items"} and isinstance(
            value.get("__list__"), str
        ):
            items = [decode(item) for item in value["items"]]
            try:
                return _load_class(value["__list__"])(items)
            except Exception:
                return items
        return {key: decode(item) for key, item in value.items()}
    if isinstance(value, list):
        return [decode(item) for item in value]
    return value
