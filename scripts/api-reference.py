#!/usr/bin/env python3
"""Generate a browsable reference from docs/openapi.yaml using Scalar."""

import argparse
import json
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=root / "docs" / "api-reference.html"
    )
    output = parser.parse_args().output.resolve()
    configuration = {
        "content": (root / "docs" / "openapi.yaml").read_text(),
        "modelsSectionLabel": "Schemas",
        "hideClientButton": True,
        "hideTestRequestButton": True,
        "defaultHttpClient": {"targetKey": "shell", "clientKey": "curl"},
    }
    # A schema description can contain HTML, including a closing script tag.
    encoded = json.dumps(configuration).replace("<", "\\u003c")
    document = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Albedo daemon API reference</title>
</head>
<body>
  <noscript>Enable JavaScript to read this API reference.</noscript>
  <div id="app"></div>
  <script type="module">
    import {{ createApiReference }} from
      'https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.72.4/esm.js';
    createApiReference('#app', {encoded});
  </script>
</body>
</html>
"""
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(document)
    print(output)


if __name__ == "__main__":
    main()
