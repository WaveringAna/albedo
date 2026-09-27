"""Image tool outputs reach the model without transporting invalid images."""
import json
import unittest

from harness import Albedo, Provider, python, text


PNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"


class ImageToolOutputTest(unittest.TestCase):
    def test_python_image_is_attached_and_invalid_image_is_reported(self):
        def reply(request):
            inputs = request["input"]
            if inputs[-1].get("type") == "function_call_output":
                return text("done")
            user = next(item["content"] for item in reversed(inputs)
                        if item.get("role") == "user")
            if user == "show a valid image":
                return python("import base64\nshow_image(base64.b64decode('" + PNG + "'))")
            return python("show_image(b'\\x89PNG\\r\\n\\x1a\\nnot a header')")

        def tool_output(provider):
            inputs = provider.requests[-1]["request"]["input"]
            return next(item for item in inputs
                        if item.get("type") == "function_call_output")

        provider = Provider(reply)
        try:
            with Albedo(provider, protocol="responses") as app:
                session = app.session()
                app.prompt(session, "show a valid image").close()
                app.idle(session)
                output = tool_output(provider)
                self.assertIn("attached image/png", json.dumps(output))
                request = provider.requests[-1]["request"]
                self.assertIn(PNG, json.dumps(request))

                second = app.session()
                app.prompt(second, "show an invalid image").close()
                app.idle(second)
                output = tool_output(provider)
                self.assertIn("image_errors", json.dumps(output))
                self.assertNotIn(PNG, json.dumps(output))
        finally:
            provider.close()
