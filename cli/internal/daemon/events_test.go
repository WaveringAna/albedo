// A cell's trace reaches the client as JSON the client validates before
// drawing it; a kind it does not know drops the whole trace, which no daemon
// e2e sees because the daemon passes traces through untouched.
package daemon

import "testing"

func TestParseToolTraceKeepsEveryKindTheKernelRecords(t *testing.T) {
	trace := ParseToolTrace([]byte(`{"activities":[
		{"kind":"run","target":"go test","ms":1500,"ok":true},
		{"kind":"mcp","target":"fake/echo","ms":3,"ok":false},
		{"kind":"cua","target":"click"},
        {"kind":"artifact","target":"release timeline","artifact":{"id":"abc","version":2}}
	],"changes":[]}`))
	if trace == nil || len(trace.Activities) != 4 {
		t.Fatalf("trace dropped: %+v", trace)
	}
	if run := trace.Activities[0]; run.MS == nil || *run.MS != 1500 || run.OK == nil || !*run.OK {
		t.Fatalf("run lost its outcome: %+v", run)
	}
	if ParseToolTrace([]byte(`{"activities":[{"kind":"run","target":"x","ms":-1}],"changes":[]}`)) != nil {
		t.Fatal("a negative duration was accepted")
	}
}
