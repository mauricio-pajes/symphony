package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode"
)

const maxResponseBytes = 2 << 20

type tokenUsage struct {
	Input  *int64 `json:"input_tokens"`
	Output *int64 `json:"output_tokens"`
	Total  *int64 `json:"total_tokens"`
}

type ticket struct {
	ID          string      `json:"issue_identifier"`
	Title       string      `json:"title"`
	State       string      `json:"state"`
	Provider    string      `json:"provider"`
	Model       string      `json:"model"`
	Effort      string      `json:"effort"`
	Profile     string      `json:"profile_alias"`
	Session     string      `json:"session_id"`
	Attempt     int         `json:"attempt"`
	TurnCount   int         `json:"turn_count"`
	Started     time.Time   `json:"started_at"`
	Blocked     time.Time   `json:"blocked_at"`
	Due         time.Time   `json:"due_at"`
	LastEvent   string      `json:"last_event"`
	LastEventAt time.Time   `json:"last_event_at"`
	Reason      string      `json:"error"`
	Tokens      *tokenUsage `json:"tokens"`
	Status      string      `json:"-"`
}

type apiError struct {
	Code string `json:"code"`
}

type snapshot struct {
	GeneratedAt time.Time       `json:"generated_at"`
	Running     []ticket        `json:"running"`
	Retrying    []ticket        `json:"retrying"`
	Blocked     []ticket        `json:"blocked"`
	CodexTotals *tokenUsage     `json:"codex_totals"`
	RateLimits  json.RawMessage `json:"rate_limits"`
	Error       *apiError       `json:"error"`
}

type event struct {
	At       time.Time `json:"at"`
	Type     string    `json:"event"`
	Provider string    `json:"provider"`
	Message  string    `json:"message"`
}

type ticketDetail struct {
	ID      string  `json:"issue_identifier"`
	Status  string  `json:"status"`
	Running *ticket `json:"running"`
	Retry   *ticket `json:"retry"`
	Blocked *ticket `json:"blocked"`
	Events  []event `json:"recent_events"`
	Error   string  `json:"last_error"`
}

type daemonClient struct {
	baseURL *url.URL
	http    *http.Client
}

func newDaemonClient(address string) (*daemonClient, error) {
	base, err := url.Parse(address)
	if err != nil || base.Scheme != "http" || base.Host == "" || base.User != nil ||
		base.RawQuery != "" || base.ForceQuery || base.Fragment != "" ||
		(base.EscapedPath() != "" && base.EscapedPath() != "/") {
		return nil, errors.New("use an HTTP loopback URL with no path, credentials or query")
	}

	host := base.Hostname()
	if strings.EqualFold(host, "localhost") {
		host = "127.0.0.1"
		if base.Port() == "" {
			base.Host = host
		} else {
			base.Host = net.JoinHostPort(host, base.Port())
		}
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return nil, errors.New("the daemon URL must use a loopback address")
	}

	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	return &daemonClient{
		baseURL: base,
		http: &http.Client{
			Timeout:   5 * time.Second,
			Transport: transport,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}, nil
}

func (c *daemonClient) state(ctx context.Context) (snapshot, error) {
	var result snapshot
	if err := c.get(ctx, "state", &result); err != nil {
		return snapshot{}, err
	}
	if result.Error != nil {
		switch result.Error.Code {
		case "snapshot_timeout":
			return snapshot{}, errors.New("the daemon timed out creating a snapshot")
		default:
			return snapshot{}, errors.New("the daemon could not create a snapshot")
		}
	}
	if result.GeneratedAt.IsZero() {
		return snapshot{}, errors.New("the daemon response has no snapshot timestamp")
	}
	return result, nil
}

func (c *daemonClient) issue(ctx context.Context, identifier string) (ticketDetail, error) {
	if !validIssueIdentifier(identifier) {
		return ticketDetail{}, errors.New("the ticket identifier is not supported by the detail endpoint")
	}
	var result ticketDetail
	if err := c.get(ctx, identifier, &result); err != nil {
		return ticketDetail{}, err
	}
	if result.ID != identifier {
		return ticketDetail{}, errors.New("the daemon returned a different ticket")
	}
	return result, nil
}

func validIssueIdentifier(value string) bool {
	if len(value) == 0 || len(value) > 160 || value == "." || value == ".." || value == "state" || value == "refresh" {
		return false
	}
	for _, r := range value {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) && !strings.ContainsRune("._-", r) {
			return false
		}
	}
	return true
}

func (c *daemonClient) get(ctx context.Context, endpoint string, target any) error {
	address := *c.baseURL
	address.Path = "/api/v1/" + endpoint
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address.String(), nil)
	if err != nil {
		return errors.New("could not construct the daemon request")
	}
	request.Header.Set("Accept", "application/json")
	response, err := c.http.Do(request)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return errors.New("the daemon did not respond in time")
		}
		return errors.New("could not reach the local daemon")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		switch response.StatusCode {
		case http.StatusUnauthorized, http.StatusForbidden:
			return errors.New("access denied by the local daemon")
		case http.StatusNotFound:
			return errors.New("the endpoint or ticket is unavailable")
		default:
			return fmt.Errorf("the local daemon returned HTTP %d", response.StatusCode)
		}
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes+1))
	if err != nil || len(body) > maxResponseBytes {
		return errors.New("the daemon response could not be read within the size limit")
	}
	if err := json.Unmarshal(body, target); err != nil {
		return errors.New("the daemon response does not match the expected JSON")
	}
	return nil
}
