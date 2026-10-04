package daemon

import (
	"bufio"
	"context"
	"errors"
	"strings"
	"testing"
)

// Store publication can fail after commit, so reconnect must rebuild from the
// durable snapshot rather than consume incomplete canonical publication.
func TestHistoryPublicationFailureRequiresFreshSnapshot(t *testing.T) {
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: 1}, nil), "s")
	client.afterGeneration, client.afterSeq = "abcdefghijklmnopqrstuv", 7
	wire := `data: {"generation":"abcdefghijklmnopqrstuv","cursor":8,"events":[{"type":"error","sequence":8,"data":{"run_id":null,"code":"history_publication_failed","message":"temporarily unavailable"}}]}` + "\n\n"
	callbacks := 0
	err := client.readStream(context.Background(), bufio.NewScanner(strings.NewReader(wire)), nil, func(StreamEvent) error { callbacks++; return nil })
	var failure *StreamError
	if !errors.As(err, &failure) || failure.Kind != StreamTransient || callbacks != 0 || client.afterSeq != -1 || client.afterGeneration != "" {
		t.Fatalf("publication failure did not require a fresh snapshot: error=%v callbacks=%d cursor=%s/%d", err, callbacks, client.afterGeneration, client.afterSeq)
	}
}
