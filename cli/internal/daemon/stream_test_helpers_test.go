package daemon

import (
	"net/http"
)

func serveNormalizedProgressHealth(writer http.ResponseWriter, request *http.Request) bool {
	if request.URL.Path != "/health" {
		return false
	}
	writer.Header().Set("Content-Type", "application/json")
	_, _ = writer.Write([]byte(`{"ok":true,"version":2,"capabilities":["normalized_tool_progress"]}`))
	return true
}
