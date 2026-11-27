package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestLoopbackAddress(t *testing.T) {
	for _, address := range []string{
		"http://localhost:4000", "http://127.0.0.1:4000/", "http://[::1]:4000",
	} {
		client, err := newDaemonClient(address)
		if err != nil {
			t.Fatal(err)
		}
		if client.baseURL.Hostname() == "localhost" {
			t.Fatal("the transport would have to resolve localhost")
		}
	}
	for _, address := range []string{
		"http://example.com", "http://192.168.1.21", "http://[::]", "https://127.0.0.1",
		"http://u:p@127.0.0.1", "http://127.0.0.1/?override=true",
		"http://127.0.0.1/api/v1/state", "http://127.0.0.1/#fragment",
	} {
		if _, err := newDaemonClient(address); err == nil {
			t.Errorf("accepted %s", address)
		}
	}
}

func TestDaemonGETContract(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet {
			t.Errorf("unexpected method %q", request.Method)
		}
		switch request.URL.Path {
		case "/api/v1/state":
			fmt.Fprint(w, `{"generated_at":"2026-11-26T15:30:00Z","running":[{"issue_identifier":"DEMO-17","provider":"gemini","model":"example","future":42}]}`)
		case "/api/v1/DEMO-17":
			fmt.Fprint(w, `{"issue_identifier":"DEMO-17","status":"running","recent_events":[{"event":"agent_progress","at":"2026-11-26T15:30:00Z"}]}`)
		default:
			t.Errorf("unexpected path %q", request.URL.Path)
			http.NotFound(w, request)
		}
	}))
	defer server.Close()
	client := clientFor(t, server.URL)
	result, err := client.state(context.Background())
	if err != nil || len(result.Running) != 1 || result.Running[0].Provider != "gemini" {
		t.Fatalf("state = %+v, %v", result, err)
	}
	detail, err := client.issue(context.Background(), "DEMO-17")
	if err != nil || len(detail.Events) != 1 || detail.Events[0].Type != "agent_progress" {
		t.Fatalf("issue = %+v, %v", detail, err)
	}
	for _, identifier := range []string{"../../effects", "refresh", "state", "%2f", "\x1bDEMO-17"} {
		if _, err := client.issue(context.Background(), identifier); err == nil {
			t.Fatalf("unsafe identifier accepted: %q", identifier)
		}
	}
}

func TestProjectQueueKeepsEqualIdentifiersSeparate(t *testing.T) {
	server := func(title string, offline bool) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodGet {
				t.Errorf("unexpected method %q", r.Method)
			}
			if offline {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			switch r.URL.Path {
			case "/api/v1/state":
				fmt.Fprintf(w, `{"generated_at":"2026-11-26T15:30:00Z","running":[{"issue_identifier":"DEMO-1","title":%q}]}`, title)
			case "/api/v1/DEMO-1":
				fmt.Fprintf(w, `{"issue_identifier":"DEMO-1","status":"Running","last_error":%q}`, title)
			default:
				http.NotFound(w, r)
			}
		}))
	}
	a := server("First project", false)
	defer a.Close()
	b := server("Second project", false)
	defer b.Close()
	c := server("Unavailable", true)
	defer c.Close()

	var client projectClient
	for _, source := range []string{"Alpha=" + a.URL, "Beta=" + b.URL, "Gamma=" + c.URL} {
		if err := client.add(source); err != nil {
			t.Fatal(err)
		}
	}
	ctx := context.Background()
	state, err := client.state(ctx)
	if err != nil || len(state.Projects) != 3 || state.Projects[2].Err == nil {
		t.Fatalf("project health = %+v, %v", state.Projects, err)
	}
	rows := sortedTickets(state)
	if len(rows) != 2 || rows[0].Project != "Alpha" || rows[1].Project != "Beta" {
		t.Fatalf("queue = %+v", rows)
	}
	for _, row := range rows {
		detail, err := client.issue(ctx, row.key())
		if err != nil || detail.Error != row.Title {
			t.Fatalf("detail for %s = %+v, %v", row.Project, detail, err)
		}
	}
}

func TestManagedDaemonProcessDiscovery(t *testing.T) {
	command := "/Users/demo/project with spaces/symphony -B -S 2:2 -- " + daemonAcknowledgement + " --port 4848 WORKFLOW.md"
	executable, port, ok := daemonProcess(command)
	if !ok || executable != "/Users/demo/project with spaces/symphony" || port != 4848 {
		t.Fatalf("detected executable %q and port %d (%v)", executable, port, ok)
	}
	for _, candidate := range []string{
		"python " + daemonAcknowledgement + " --port 4848",
		"/tmp/symphony -B --port 4848",
		"/tmp/symphony " + daemonAcknowledgement + " --port 65536",
	} {
		if _, _, ok := daemonProcess(candidate); ok {
			t.Errorf("accepted unrelated or invalid process %q", candidate)
		}
	}
}

func TestDaemonRedirectAndSnapshotErrors(t *testing.T) {
	var redirected atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		redirected.Add(1)
	}))
	defer target.Close()

	for _, test := range []struct {
		name, body, expected string
	}{
		{"redirect", "", "HTTP 302"},
		{"timeout", `{"generated_at":"2026-11-26T15:30:00Z","error":{"code":"snapshot_timeout"}}`, "timed out"},
		{"missing timestamp", `{"running":[]}`, "no snapshot timestamp"},
		{"large body", strings.Repeat(" ", maxResponseBytes+1), "size limit"},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
				if test.name == "redirect" {
					http.Redirect(w, request, target.URL, http.StatusFound)
					return
				}
				fmt.Fprint(w, test.body)
			}))
			defer server.Close()
			client := clientFor(t, server.URL)
			if _, err := client.state(context.Background()); err == nil || !strings.Contains(err.Error(), test.expected) {
				t.Errorf("state error = %v", err)
			}
		})
	}
	if redirected.Load() != 0 {
		t.Fatal("client followed redirect")
	}
}

func TestInFlightGETRespectsContext(t *testing.T) {
	requestStarted := make(chan struct{})
	requestEnded := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		close(requestStarted)
		<-request.Context().Done()
		close(requestEnded)
	}))
	defer server.Close()
	client := clientFor(t, server.URL)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	clientEnded := make(chan error, 1)
	go func() {
		_, err := client.state(ctx)
		clientEnded <- err
	}()
	<-requestStarted
	cancel()
	if err := <-clientEnded; err == nil {
		t.Fatal("cancelled request reported success")
	}
	<-requestEnded
}

func clientFor(t *testing.T, address string) *daemonClient {
	t.Helper()
	client, err := newDaemonClient(address)
	if err != nil {
		t.Fatal(err)
	}
	return client
}
